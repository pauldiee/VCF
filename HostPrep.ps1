<#
.SYNOPSIS
    Prepares ESXi hosts for commissioning into SDDC Manager / VCF 9.

.DESCRIPTION
    When run, the script will interactively prompt for all required input —
    no pre-configuration needed. The following steps are performed for each host:

      1. Connect to the ESXi host using the root account
      2. Ensure NTP servers are configured and the NTP service is running
      3. Apply the required SDDC Manager advanced setting (allowSelfSigned)
      4. Check if the certificate CN matches the host FQDN; if not, enable
         SSH temporarily, regenerate the certificate via
         /sbin/generate-certificates, disable SSH again, then reboot and
         wait for the host to return online
      5. Optionally reset the root account password (asked interactively)

    After all hosts are processed, an HTML report is generated in the same
    folder as the script containing the SHA-256 SSL thumbprint for each host,
    ready to use when commissioning hosts into SDDC Manager.

    Host List File (.txt)
    ---------------------
    The script will prompt for the full path to a plain text file containing
    one ESXi host FQDN per line. Example file contents:

        esxi01.vcf.lab
        esxi02.vcf.lab
        esxi03.vcf.lab

    Lines starting with # are treated as comments and ignored.
    Blank lines are also ignored.
    The path can be typed or pasted — surrounding quotes are stripped automatically.

    Prerequisites
    -------------
    One-time PowerCLI setup (run once per user account, then never again):

        Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false

    This permanently suppresses the VMware CEIP warning that PowerCLI emits
    on first use. Without it the warning will appear every time a new terminal
    is opened, and no script can suppress it reliably from within.

    The Posh-SSH PowerShell module is optional but recommended. Without it,
    certificate regeneration will be skipped and must be performed manually
    on each host. To install it, run:

        Install-Module -Name Posh-SSH -Scope CurrentUser

    If Posh-SSH is not available, the script will print per-host instructions
    at runtime telling you to run /sbin/generate-certificates followed by a
    reboot of the host.

    Password Requirements (VCF 9)
    ------------------------------
    If a password reset is requested, the new password is validated against
    VCF 9 requirements before any host is contacted:
      - 15 to 40 characters
      - At least 1 lowercase letter
      - At least 1 uppercase letter (not as the first character)
      - At least 1 digit (not as the last character)
      - At least 1 special character from: @ ! # $ % ? ^
      - Only letters, digits, and @ ! # $ % ? ^ are permitted
      - At least 3 of the 4 character classes must be present

.PARAMETER NtpServers
    One or more NTP server addresses. Defaults to 'pool.ntp.org'.

.PARAMETER LogPath
    Path to write a transcript log. Defaults to the Desktop.

.PARAMETER DryRun
    If set, no changes are made to any host. All actions are logged as
    [DRY RUN] so you can validate the script flow without a real ESXi host.
    Credentials and the host list are still prompted but never used.

.EXAMPLE
    .\HostPrep.ps1

.EXAMPLE
    .\HostPrep.ps1 -NtpServers "ntp1.example.com","ntp2.example.com"

.EXAMPLE
    .\HostPrep.ps1 -DryRun

.NOTES
    Script  : HostPrep.ps1
    Version : 2.9.1
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Date    : 2026-03-07

    Changelog:
        1.0.0 - Initial release
        1.1.0 - Genericised parameters, improved NTP/SSH checks, added error
                handling, colorised summary table, added versioning metadata
        1.2.0 - Added -DryRun switch for safe pre-flight testing
        1.3.0 - Hardened password reset: input validation, single plaintext
                extraction with immediate clear, throw-on-failure, stale
                session warning, and processed-host tracking
        1.4.0 - Replaced -ResetPassword switch with interactive Y/N prompt
        1.5.0 - Removed -ApplyAdvancedSettings switch; retained only
                allowSelfSigned setting applied by default
        1.6.0 - Added VCF 9 password compliance validation with detailed
                per-rule feedback; new password prompt loops until a
                compliant password is entered
        1.7.0 - Removed -EsxiUsername parameter; hardcoded to 'root'
        1.8.0 - Moved helper functions before credential gathering; replaced
                Get-Credential popup with Read-Host console prompts; added
                password confirmation; Reset-ESXiAccountPassword now accepts
                SecureString instead of PSCredential
        1.9.0 - Replaced file browser popup with command line Read-Host
                prompt; password reset step moved to run last per host
        2.0.0 - Expanded comment block: usage instructions, host list file
                format, password requirements
        2.1.0 - Added certificate regeneration and conditional reboot with
                port 443 polling; added CertRegen and Rebooted summary columns
        2.2.0 - Removed SSH enable/check; all operations use VMware API
        2.3.0 - Fixed Get-EsxCli null error by using VMHost objects throughout
                instead of plain strings
        2.4.0 - Certificate regeneration switched to temporary SSH via
                Posh-SSH running /sbin/generate-certificates
        2.5.0 - Added certificate check before regen (issuer vs subject)
        2.6.0 - Simplified cert check to CN vs hostname only
        2.7.0 - Posh-SSH made optional; missing module warns at startup and
                prints per-host manual instructions; 'Manual' summary state
        2.8.0 - PowerCLI CEIP opt-out persisted to User scope on first run;
                InvalidCertificateAction set to Ignore for the session;
                removed unused Windows.Forms assembly; cleaned up description
        2.9.0 - Test-ESXiCertificateNeedsRegen now returns a structured
                object including SHA-256 thumbprint, CN and expiry;
                thumbprint re-read after cert regen to reflect new cert;
                HTML report generated after run with thumbprints ready for
                SDDC Manager commissioning; added -ReportPath parameter
        2.9.1 - Fixed HTML report Successful count (Measure-Object + [int]
                cast prevents single-result .Count returning empty);
                moved Add-Type System.Web to Initialisation region
#>

[CmdletBinding()]
param (
    [string[]]$NtpServers = @("pool.ntp.org"),

    [switch]$DryRun,

    [string]$LogPath = [System.IO.Path]::Combine(
        [Environment]::GetFolderPath('Desktop'),
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    ),

    [string]$ReportPath = [System.IO.Path]::Combine(
        $PSScriptRoot,
        "HostPrep_$(Get-Date -Format 'yyyyMMdd_HHmmss')_Report.html"
    )
)

#region --- Script Metadata ---

$ScriptMeta = @{
    Name    = "HostPrep.ps1"
    Version = "2.9.1"
    Author  = "Paul van Dieen"
    Blog    = "https://www.hollebollevsan.nl"
    Date    = "2026-03-08"
}

#endregion

#region --- Initialisation ---

# Suppress PowerCLI CEIP nag. The warning fires on first module load in any
# new session, so we persist the opt-out to the User scope once and silently
# apply it to the current session. After the first run it will never appear.
$ceipConfig = Get-PowerCLIConfiguration -Scope User -WarningAction SilentlyContinue
if ($null -eq $ceipConfig.ParticipateInCEIP) {
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -WarningAction SilentlyContinue | Out-Null
}
Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -InvalidCertificateAction Ignore -Confirm:$false -WarningAction SilentlyContinue | Out-Null

$bannerWidth = 62
Write-Host ""
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ("  {0,-30} {1}" -f $ScriptMeta.Name, ("v" + $ScriptMeta.Version)) -ForegroundColor Cyan
Write-Host ("  Author : {0}" -f $ScriptMeta.Author) -ForegroundColor Cyan
Write-Host ("  Blog   : {0}" -f $ScriptMeta.Blog) -ForegroundColor Cyan
Write-Host ("  Date   : {0}" -f $ScriptMeta.Date) -ForegroundColor DarkGray
Write-Host ("=" * $bannerWidth) -ForegroundColor DarkCyan
Write-Host ""

if ($DryRun) {
    Write-Host "  *** DRY RUN MODE - No changes will be made ***" -ForegroundColor Yellow
    Write-Host ""
}

# Start transcript for audit logging
Start-Transcript -Path $LogPath -Append
Write-Host "HostPrep started at $(Get-Date)" -ForegroundColor Cyan

# Verify optional modules
$script:PoshSSHAvailable = $false
if (-not (Get-Module -ListAvailable -Name "Posh-SSH")) {
    Write-Host ""
    Write-Host "  WARNING: The 'Posh-SSH' module is not installed." -ForegroundColor Yellow
    Write-Host "  Certificate regeneration will be skipped for all hosts." -ForegroundColor Yellow
    Write-Host "  To enable it, run: Install-Module -Name Posh-SSH -Scope CurrentUser" -ForegroundColor Yellow
    Write-Host ""
} else {
    Import-Module Posh-SSH -ErrorAction Stop
    $script:PoshSSHAvailable = $true
}

# Required for HTML entity encoding in the commissioning report
Add-Type -AssemblyName System.Web

#endregion
#region --- Helper Functions ---

function Test-VCF9PasswordCompliance {
    <#
    .SYNOPSIS
        Validates a plaintext password against VCF 9 ESXi root password requirements.

    .DESCRIPTION
        VCF 9 enforces the following rules on ESXi root passwords:
          - Minimum 15 characters, maximum 40 characters
          - At least 1 uppercase letter (not as the very first character)
          - At least 1 lowercase letter
          - At least 1 digit (not as the very last character)
          - At least 1 special character from the set: @ ! # $ % ? ^
          - No characters outside letters, digits, and @ ! # $ % ? ^
          - At least 3 of the 4 character classes must be present
          - Dictionary words should be avoided (cannot be enforced client-side)

    .PARAMETER Password
        The plaintext password string to test.

    .OUTPUTS
        PSCustomObject with:
          .Passed  [bool]   - $true if all rules pass
          .Failures [string[]] - list of failed rule descriptions

    .NOTES
        Source: VCF 9 / ESX 9 password policy documentation and installer validation.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Password
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    # Rule 1: Length 15-40
    if ($Password.Length -lt 15) {
        $failures.Add("Too short: minimum 15 characters (current: $($Password.Length))")
    }
    if ($Password.Length -gt 40) {
        $failures.Add("Too long: maximum 40 characters (current: $($Password.Length))")
    }

    # Rule 2: Only permitted characters (letters, digits, @ ! # $ % ? ^)
    if ($Password -match '[^a-zA-Z0-9@!#$%\?\^]') {
        $failures.Add("Contains forbidden characters. Only letters, digits, and @ ! # `$ % ? ^ are allowed.")
    }

    # Rule 3: At least 1 lowercase letter
    if ($Password -notmatch '[a-z]') {
        $failures.Add("Must contain at least 1 lowercase letter.")
    }

    # Rule 4: At least 1 uppercase letter, and NOT as the very first character
    if ($Password -notmatch '[A-Z]') {
        $failures.Add("Must contain at least 1 uppercase letter.")
    } elseif ($Password[0] -cmatch '[A-Z]') {
        $failures.Add("Uppercase letter must not be the first character.")
    }

    # Rule 5: At least 1 digit, and NOT as the very last character
    if ($Password -notmatch '[0-9]') {
        $failures.Add("Must contain at least 1 digit.")
    } elseif ($Password[-1] -match '[0-9]') {
        $failures.Add("A digit must not be the last character.")
    }

    # Rule 6: At least 1 special character from the allowed set
    if ($Password -notmatch '[@!#$%\?\^]') {
        $failures.Add("Must contain at least 1 special character from: @ ! # `$ % ? ^")
    }

    # Rule 7: At least 3 of 4 character classes present
    $classCount = 0
    if ($Password -cmatch '[a-z]')       { $classCount++ }
    if ($Password -cmatch '[A-Z]')       { $classCount++ }
    if ($Password -match '[0-9]')        { $classCount++ }
    if ($Password -match '[@!#$%\?\^]') { $classCount++ }

    if ($classCount -lt 3) {
        $failures.Add("Must use at least 3 of 4 character classes: lowercase, uppercase, digits, special characters (currently using $classCount).")
    }

    return [PSCustomObject]@{
        Passed   = ($failures.Count -eq 0)
        Failures = $failures
    }
}

function Test-ESXiCertificateNeedsRegen {
    <#
    .SYNOPSIS
        Checks whether the ESXi host certificate CN matches the host's FQDN
        and captures the SHA-256 thumbprint for use in the HTML report.

    .DESCRIPTION
        Connects to port 443 and reads the TLS certificate. If the CN in the
        Subject does not match the supplied hostname, the certificate needs
        regenerating. No credentials or SSH required.

    .PARAMETER VMHost
        FQDN or hostname of the ESXi host.

    .OUTPUTS
        PSCustomObject with:
          .NeedsRegen  [bool]   - $true if CN does not match hostname
          .Thumbprint  [string] - SHA-256 thumbprint formatted with colons
          .CN          [string] - CN extracted from the certificate Subject
          .Expiry      [string] - Certificate expiry date
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost
    )

    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient($VMHost, 443)
        $sslStream  = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(), $false,
            { param($s, $cert, $chain, $errors) $true }   # accept any cert
        )
        $sslStream.AuthenticateAsClient($VMHost)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $sslStream.RemoteCertificate
        )
        $sslStream.Close()
        $tcpClient.Close()

        # Extract CN from Subject (e.g. "CN=esxi01.vcf.lab, O=VMware...")
        $cnMatch = $cert.Subject -match 'CN=([^,]+)'
        $cn      = if ($cnMatch) { $Matches[1].Trim() } else { "" }

        # Compute SHA-256 thumbprint formatted with colons (as SDDC Manager expects)
        $sha256      = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes   = $sha256.ComputeHash($cert.RawData)
        $thumbprint  = ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

        $expiry = $cert.NotAfter.ToString("yyyy-MM-dd HH:mm:ss")

        Write-Host "  Certificate CN  : $cn" -ForegroundColor DarkGray
        Write-Host "  Host FQDN       : $VMHost" -ForegroundColor DarkGray
        Write-Host "  Expires         : $expiry" -ForegroundColor DarkGray
        Write-Host "  SHA-256         : $thumbprint" -ForegroundColor DarkGray

        $needsRegen = $cn -ne $VMHost
        if ($needsRegen) {
            Write-Host "  CN does not match hostname. Regeneration needed." -ForegroundColor Yellow
        } else {
            Write-Host "  CN matches hostname. Regeneration not needed." -ForegroundColor Green
        }

        return [PSCustomObject]@{
            NeedsRegen  = $needsRegen
            Thumbprint  = $thumbprint
            CN          = $cn
            Expiry      = $expiry
        }

    } catch {
        Write-Warning "  Could not read certificate from $VMHost port 443: $_"
        Write-Warning "  Proceeding with regeneration to be safe."
        return [PSCustomObject]@{
            NeedsRegen  = $true
            Thumbprint  = "N/A"
            CN          = "N/A"
            Expiry      = "N/A"
        }
    }
}

function Invoke-ESXiCertificateRegen {
    <#
    .SYNOPSIS
        Regenerates the ESXi host certificate via a temporary SSH session.

    .DESCRIPTION
        - Enables SSH on the host via PowerCLI (Set-VMHostServiceConfig)
        - Opens an SSH session using Posh-SSH with the supplied root credentials
        - Runs /sbin/generate-certificates
        - Disables SSH again regardless of outcome (try/finally)
        - Returns $true on success, throws on failure

    .PARAMETER VMHost
        FQDN or hostname of the ESXi host (string - needed for SSH connection).

    .PARAMETER VMHostObj
        VMHost object returned by Get-VMHost, used for PowerCLI service control.

    .PARAMETER Credential
        PSCredential for the root account, used to authenticate the SSH session.
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost,
        [Parameter(Mandatory)]$VMHostObj,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    # Enable SSH temporarily
    Write-Host "  Enabling SSH temporarily for certificate regeneration..." -ForegroundColor Yellow
    Set-VMHostServiceConfig -VMHost $VMHostObj -ServiceKey "TSM-SSH"

    $sshSession = $null
    try {
        # Connect via SSH
        Write-Host "  Connecting via SSH to run /sbin/generate-certificates..." -ForegroundColor Cyan
        $sshSession = New-SSHSession -ComputerName $VMHost -Credential $Credential `
                        -AcceptKey -ErrorAction Stop

        $sshResult = Invoke-SSHCommand -SessionId $sshSession.SessionId `
                        -Command "/sbin/generate-certificates" -ErrorAction Stop

        if ($sshResult.ExitStatus -ne 0) {
            throw "/sbin/generate-certificates exited with code $($sshResult.ExitStatus). Output: $($sshResult.Output -join ' ')"
        }

        Write-Host "  Certificate regenerated successfully on $VMHost." -ForegroundColor Green
        return $true

    } finally {
        # Always close SSH session and disable the service
        if ($sshSession) {
            Remove-SSHSession -SessionId $sshSession.SessionId -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "  Disabling SSH..." -ForegroundColor Yellow
        $svc = Get-VMHostService -VMHost $VMHostObj | Where-Object { $_.Key -eq "TSM-SSH" }
        if ($svc) {
            $svc | Set-VMHostService -Policy "off" -Confirm:$false | Out-Null
            if ($svc.Running) {
                $svc | Stop-VMHostService -Confirm:$false | Out-Null
            }
        }
        Write-Host "  SSH disabled." -ForegroundColor Green
    }
}

function Wait-ESXiHostOnline {
    <#
    .SYNOPSIS
        Waits for an ESXi host to come back online after a reboot by polling
        TCP port 443 until it responds or the timeout is reached.

    .PARAMETER VMHost
        FQDN or name of the ESXi host to poll.

    .PARAMETER TimeoutSeconds
        Maximum number of seconds to wait. Defaults to 600 (10 minutes).

    .PARAMETER PollIntervalSeconds
        Seconds between each poll attempt. Defaults to 15.
    #>
    param (
        [Parameter(Mandatory)][string]$VMHost,
        [int]$TimeoutSeconds    = 600,
        [int]$PollIntervalSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Host "  Waiting for $VMHost to come back online (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Cyan

    # Brief initial pause to allow the host to begin its shutdown sequence
    Start-Sleep -Seconds 30

    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $connect = $tcp.BeginConnect($VMHost, 443, $null, $null)
            $wait    = $connect.AsyncWaitHandle.WaitOne(3000, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.Close()
                Write-Host "  $VMHost is back online." -ForegroundColor Green
                # Brief extra pause to let services fully initialise
                Start-Sleep -Seconds 15
                return $true
            }
            $tcp.Close()
        } catch {
            # Connection refused or timed out — host still rebooting
        }
        Write-Host "  Still waiting... ($(
            [int]($deadline - (Get-Date)).TotalSeconds)s remaining)" -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for $VMHost to come back online after ${TimeoutSeconds}s."
}

function Set-VMHostServiceConfig {
    <#
    .SYNOPSIS
        Ensures a VMHost service is set to the given policy and is running.
    #>
    param (
        [Parameter(Mandatory)]$VMHost,
        [string]$ServiceKey,
        [string]$Policy = "on"
    )

    $svc = Get-VMHostService -VMHost $VMHost | Where-Object { $_.Key -eq $ServiceKey }

    if (-not $svc) {
        Write-Warning "  Service '$ServiceKey' not found on host."
        return
    }

    if ($svc.Policy -ne $Policy) {
        Write-Host "  Setting '$ServiceKey' startup policy to '$Policy'..." -ForegroundColor Yellow
        $svc | Set-VMHostService -Policy $Policy -Confirm:$false | Out-Null
    }

    if (-not $svc.Running) {
        Write-Host "  Starting service '$ServiceKey'..." -ForegroundColor Yellow
        $svc | Start-VMHostService -Confirm:$false | Out-Null
    } else {
        Write-Host "  Service '$ServiceKey' is already running with policy '$Policy'." -ForegroundColor Green
    }
}

function Reset-ESXiAccountPassword {
    <#
    .SYNOPSIS
        Resets an ESXi account password via ESXCLI v2 with hardened handling.

    .DESCRIPTION
        - Validates inputs before touching the host
        - Extracts the plaintext password exactly once then immediately clears it
        - Throws a terminating error on any non-true result so the caller's
          catch block always handles failures consistently
        - Warns that the active session credential is now stale after a
          successful reset of the connected account
        - Records the host in the script-scoped processed list for run tracking

    .PARAMETER VMHost
        VMHost object returned by Get-VMHost (not a plain string).

    .PARAMETER NewPassword
        SecureString containing the new password to set for the root account.

    .PARAMETER ConnectedUsername
        The username used for the current VI session. If it matches 'root',
        a stale-session warning is emitted.
    #>
    param (
        [Parameter(Mandatory)]$VMHost,
        [Parameter(Mandatory)][System.Security.SecureString]$NewPassword,
        [string]$ConnectedUsername = ""
    )

    # Guard: password must not be empty
    if ($NewPassword.Length -eq 0) {
        throw "Cannot reset password: new password is empty."
    }

    # Extract plaintext password exactly once into a local variable,
    # use it immediately, then overwrite with empty string to limit
    # the window it exists as cleartext in memory.
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))

    try {
        $esxcli     = Get-EsxCli -VMHost $VMHost -V2
        $esxcliArgs = $esxcli.system.account.set.CreateArgs()

        $esxcliArgs.id                   = "root"
        $esxcliArgs.password             = $plainPassword
        $esxcliArgs.passwordconfirmation = $plainPassword

        $result = $esxcli.system.account.set.Invoke($esxcliArgs)
    }
    finally {
        # Immediately overwrite - limits cleartext lifetime regardless of
        # whether Invoke succeeded or threw
        $plainPassword = [string]::new('*', 16)
        Remove-Variable plainPassword -ErrorAction SilentlyContinue
    }

    # ESXCLI v2 returns $true on success; anything else is a failure
    if ($result -ne $true) {
        throw "ESXCLI returned unexpected result '$result' - password may not have changed."
    }

    Write-Host "  Password reset successfully for 'root' on $($VMHost.Name)." -ForegroundColor Green

    # Warn if root is the same account used for the active session -
    # the current connection credential is now stale for any subsequent reconnects
    if ($ConnectedUsername -eq "root") {
        Write-Warning ("  The reset account 'root' is the same as the active session credential. " +
                       "Any reconnection attempt on this host will fail until credentials are updated.")
    }

    # Record this host so the operator can audit which hosts were processed
    if ($script:PasswordResetCompleted) {
        $script:PasswordResetCompleted.Add($VMHost)
        Write-Host ("  Hosts with password reset completed this run: " +
                    ($script:PasswordResetCompleted -join ', ')) -ForegroundColor DarkGray
    }
}

#endregion
#region --- Credential Gathering ---

Write-Host "`nGathering credentials..." -ForegroundColor Cyan

$esxiPassword    = Read-Host "Enter the 'root' password used to connect to the ESXi hosts" -AsSecureString
$esxiCredentials = New-Object System.Management.Automation.PSCredential("root", $esxiPassword)

# Ask interactively whether to reset the root account password
Write-Host ""
$resetAnswer = $null
while ($resetAnswer -notin @('Y','N')) {
    $resetAnswer = (Read-Host "  Do you want to reset the root account password on all hosts? [Y/N]").Trim().ToUpper()
    if ($resetAnswer -notin @('Y','N')) {
        Write-Host "  Please enter Y or N." -ForegroundColor Yellow
    }
}
$ResetPassword = ($resetAnswer -eq 'Y')

if ($ResetPassword) {
    Write-Host "  Password reset: ENABLED" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  New password must meet VCF 9 requirements:" -ForegroundColor Cyan
    Write-Host "    - 15 to 40 characters" -ForegroundColor DarkGray
    Write-Host "    - At least 1 lowercase letter" -ForegroundColor DarkGray
    Write-Host "    - At least 1 uppercase letter (not as the first character)" -ForegroundColor DarkGray
    Write-Host "    - At least 1 digit (not as the last character)" -ForegroundColor DarkGray
    Write-Host "    - At least 1 special character from: @ ! # `$ % ? ^" -ForegroundColor DarkGray
    Write-Host "    - Only letters, digits, and @ ! # `$ % ? ^ are permitted" -ForegroundColor DarkGray
    Write-Host "    - At least 3 of the 4 character classes must be present" -ForegroundColor DarkGray
    Write-Host ""

    $NewPassword       = $null
    $passwordCompliant = $false

    while (-not $passwordCompliant) {
        $NewPassword = Read-Host "  Enter NEW root password" -AsSecureString

        if ($NewPassword.Length -eq 0) {
            Write-Host "  Password cannot be empty. Please try again." -ForegroundColor Yellow
            continue
        }

        # Extract plaintext briefly for validation only, then clear immediately
        $plainForValidation = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))
        $validation = Test-VCF9PasswordCompliance -Password $plainForValidation
        $plainForValidation = [string]::new('*', 16)
        Remove-Variable plainForValidation -ErrorAction SilentlyContinue

        if ($validation.Passed) {
            # Confirm entry to catch typos
            $NewPasswordConfirm = Read-Host "  Confirm NEW root password" -AsSecureString
            $plainConfirm = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPasswordConfirm))
            $plainOriginal = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($NewPassword))
            $match = ($plainConfirm -ceq $plainOriginal)
            $plainConfirm  = [string]::new('*', 16)
            $plainOriginal = [string]::new('*', 16)
            Remove-Variable plainConfirm, plainOriginal -ErrorAction SilentlyContinue

            if ($match) {
                $passwordCompliant = $true
                Write-Host "  Password meets all VCF 9 requirements." -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Host "  Passwords do not match. Please try again." -ForegroundColor Yellow
                Write-Host ""
            }
        } else {
            Write-Host ""
            Write-Host "  Password does not meet VCF 9 requirements:" -ForegroundColor Red
            foreach ($failure in $validation.Failures) {
                Write-Host "    x $failure" -ForegroundColor Yellow
            }
            Write-Host "  Please enter a new password." -ForegroundColor Cyan
            Write-Host ""
        }
    }

    # Track which hosts have already had their password reset this run.
    # Useful if the script is interrupted and re-run - the operator can
    # see in the log which hosts were already changed.
    $script:PasswordResetCompleted = [System.Collections.Generic.List[string]]::new()
} else {
    Write-Host "  Password reset: SKIPPED" -ForegroundColor DarkGray
}
Write-Host ""

#endregion
#region --- Host List Selection ---

$hostFilePath = $null
while (-not $hostFilePath) {
    $raw = (Read-Host "  Enter full path to the host list .txt file").Trim()

    # Strip surrounding quotes that Windows sometimes adds when copy-pasting paths
    $raw = $raw.Trim('"').Trim("'")

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "  Path cannot be empty. Please try again." -ForegroundColor Yellow
        continue
    }

    if (-not (Test-Path -LiteralPath $raw -PathType Leaf)) {
        Write-Host "  File not found: '$raw'" -ForegroundColor Yellow
        Write-Host "  Please check the path and try again." -ForegroundColor Yellow
        continue
    }

    $hostFilePath = $raw
}

$targetEsxiHosts = Get-Content -LiteralPath $hostFilePath |
    Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }

if (-not $targetEsxiHosts) {
    Write-Warning "Host list is empty. Exiting."
    Stop-Transcript
    exit 1
}

Write-Host "  Loaded $($targetEsxiHosts.Count) host(s) from: $hostFilePath" -ForegroundColor Cyan

#endregion
#region --- Per-Host Processing ---

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($esxiHost in $targetEsxiHosts) {

    Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
    Write-Host "Processing host: $esxiHost" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    $hostResult = [PSCustomObject]@{
        Host              = $esxiHost
        Connected         = $false
        NTP               = "Skipped"
        AdvancedSettings  = "Skipped"
        CertRegen         = "Skipped"
        Rebooted          = "Skipped"
        PasswordReset     = "Skipped"
        Thumbprint        = "N/A"
        Error             = ""
    }

    try {
        # --- Connect ---
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would connect to $esxiHost as 'root'." -ForegroundColor DarkYellow
            $hostResult.Connected = $true
        } else {
            Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
            $hostResult.Connected = $true
            Write-Host "  Connected to $esxiHost." -ForegroundColor Green
            $vmHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
        }

        # --- NTP ---
        Write-Host "`n  [NTP]" -ForegroundColor Cyan
        try {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would verify/add NTP server(s): $($NtpServers -join ', ')." -ForegroundColor DarkYellow
                Write-Host "  [DRY RUN] Would ensure ntpd policy=on and service running." -ForegroundColor DarkYellow
            } else {
                $currentNtp     = @(Get-VMHostNtpServer -VMHost $vmHostObj)
                $missingServers = $NtpServers | Where-Object { $_ -notin $currentNtp }

                if ($missingServers) {
                    Write-Host "  Adding missing NTP server(s): $($missingServers -join ', ')" -ForegroundColor Yellow
                    Add-VMHostNtpServer -VMHost $vmHostObj -NtpServer $missingServers -Confirm:$false -ErrorAction Stop | Out-Null
                } else {
                    Write-Host "  All required NTP server(s) already configured." -ForegroundColor Green
                }

                Set-VMHostServiceConfig -VMHost $vmHostObj -ServiceKey "ntpd"
            }
            $hostResult.NTP = "OK"
        } catch {
            $hostResult.NTP = "FAILED: $_"
            Write-Warning "  NTP configuration failed: $_"
        }

        # --- Advanced Settings (SDDC Manager) ---
        Write-Host "`n  [Advanced Settings]" -ForegroundColor Cyan
        try {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would set 'Config.HostAgent.ssl.keyStore.allowSelfSigned' = True" -ForegroundColor DarkYellow
            } else {
                Get-AdvancedSetting -Entity $vmHostObj -Name "Config.HostAgent.ssl.keyStore.allowSelfSigned" |
                    Set-AdvancedSetting -Value $true -Confirm:$false | Out-Null
                Write-Host "  Set 'Config.HostAgent.ssl.keyStore.allowSelfSigned' = True" -ForegroundColor Green
            }
            $hostResult.AdvancedSettings = "OK"
        } catch {
            $hostResult.AdvancedSettings = "FAILED: $_"
            Write-Warning "  Advanced settings failed: $_"
        }

        # --- Certificate Regeneration ---
        Write-Host "`n  [Certificate Regeneration]" -ForegroundColor Cyan
        try {
            if ($DryRun) {
                Write-Host "  [DRY RUN] Would check if certificate CN matches hostname." -ForegroundColor DarkYellow
                Write-Host "  [DRY RUN] Would regenerate host certificate if needed." -ForegroundColor DarkYellow
                Write-Host "  [DRY RUN] Would reboot host and wait for it to come back online." -ForegroundColor DarkYellow
                $hostResult.CertRegen = "OK"
                $hostResult.Rebooted  = "OK"
            } elseif (-not $script:PoshSSHAvailable) {
                Write-Host "  Posh-SSH not available. Certificate regeneration skipped." -ForegroundColor Yellow
                Write-Host "  ACTION REQUIRED: Manually run on this host and then reboot:" -ForegroundColor Yellow
                Write-Host "    /sbin/generate-certificates" -ForegroundColor Cyan
                $hostResult.CertRegen = "Manual"
                $hostResult.Rebooted  = "Manual"
            } else {
                $certCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
                $hostResult.Thumbprint = $certCheck.Thumbprint

                if (-not $certCheck.NeedsRegen) {
                    $hostResult.CertRegen = "Skipped"
                    $hostResult.Rebooted  = "Skipped"
                } else {
                    $certRegenSuccess = Invoke-ESXiCertificateRegen `
                        -VMHost     $esxiHost `
                        -VMHostObj  $vmHostObj `
                        -Credential $esxiCredentials

                    if ($certRegenSuccess) {
                        $hostResult.CertRegen = "OK"

                        # Disconnect cleanly before reboot
                        Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  Disconnected. Initiating reboot of $esxiHost..." -ForegroundColor Yellow

                        # Reconnect temporarily to issue the reboot command
                        Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
                        $rebootHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
                        Restart-VMHost -VMHost $rebootHostObj -Confirm:$false -Force -ErrorAction Stop | Out-Null
                        Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
                        Write-Host "  Reboot issued. Waiting for host to come back online..." -ForegroundColor Yellow

                        # Wait for the host to come back
                        Wait-ESXiHostOnline -VMHost $esxiHost
                        $hostResult.Rebooted = "OK"

                        # Reconnect for remaining steps (password reset)
                        Write-Host "  Reconnecting to $esxiHost..." -ForegroundColor Cyan
                        Connect-VIServer -Server $esxiHost -Credential $esxiCredentials -ErrorAction Stop | Out-Null
                        $vmHostObj = Get-VMHost -Name $esxiHost -ErrorAction Stop
                        Write-Host "  Reconnected to $esxiHost." -ForegroundColor Green

                        # Re-read thumbprint from the newly regenerated certificate
                        Write-Host "  Reading new certificate thumbprint..." -ForegroundColor Cyan
                        $newCertCheck = Test-ESXiCertificateNeedsRegen -VMHost $esxiHost
                        $hostResult.Thumbprint = $newCertCheck.Thumbprint
                    }
                }
            }
        } catch {
            $hostResult.CertRegen = "FAILED: $_"
            Write-Warning "  Certificate regeneration/reboot failed: $_"
        }

        # --- Password Reset (always last) ---
        if ($ResetPassword) {
            Write-Host "`n  [Password Reset]" -ForegroundColor Cyan
            try {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would reset password for 'root'." -ForegroundColor DarkYellow
                    $hostResult.PasswordReset = "OK"
                } else {
                    Reset-ESXiAccountPassword `
                        -VMHost            $vmHostObj `
                        -NewPassword       $NewPassword `
                        -ConnectedUsername "root"
                    $hostResult.PasswordReset = "OK"
                }
            } catch {
                $hostResult.PasswordReset = "FAILED: $_"
                Write-Warning "  Password reset failed: $_"
            }
        }

    } catch {
        $hostResult.Error = $_.Exception.Message
        Write-Warning "  Failed to process host '$esxiHost': $_"
    } finally {
        if ($hostResult.Connected -and -not $DryRun) {
            Disconnect-VIServer -Server $esxiHost -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "`n  Disconnected from $esxiHost." -ForegroundColor Gray
        } elseif ($DryRun) {
            Write-Host "`n  [DRY RUN] Would disconnect from $esxiHost." -ForegroundColor DarkYellow
        }
    }

    $results.Add($hostResult)
}

#endregion

#region --- Summary ---

function Write-ColorSummaryTable {
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data
    )

    # Column definitions: header label and width
    $columns = [ordered]@{
        Host             = 34
        Connected        = 11
        NTP              = 6
        AdvancedSettings = 17
        CertRegen        = 10
        Rebooted         = 10
        PasswordReset    = 15
        Error            = 28
    }

    $divider = "+" + (($columns.Values | ForEach-Object { "-" * ($_ + 2) }) -join "+") + "+"

    # Helper: colour a cell value
    function Get-CellColor ($value) {
        if ($value -eq $true  -or $value -eq "OK")        { return "Green"    }
        if ($value -eq $false -or $value -like "FAILED*")  { return "Red"      }
        if ($value -eq "Skipped")                          { return "DarkGray" }
        if ($value -eq "Manual")                           { return "Yellow"   }
        if ($value -like "Unexpected*")                    { return "Yellow"   }
        return "White"
    }

    Write-Host ""
    Write-Host $divider -ForegroundColor DarkCyan

    # Header row
    $headerLine = "|"
    foreach ($col in $columns.GetEnumerator()) {
        $headerLine += " {0,-$($col.Value)} |" -f $col.Key
    }
    Write-Host $headerLine -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor DarkCyan

    # Data rows
    foreach ($row in $Data) {
        $line = "|"
        foreach ($col in $columns.GetEnumerator()) {
            $val   = $row.($col.Key)
            $display = if ($null -eq $val) { "" } else { "$val" }
            # Truncate if too wide
            if ($display.Length -gt $col.Value) { $display = $display.Substring(0, $col.Value - 1) + "~" }
            $line += " {0,-$($col.Value)} |" -f $display
        }

        # Determine row base colour from Connected + Error
        $rowColor = if ($row.Error) { "Red" } elseif ($row.Connected) { "White" } else { "DarkYellow" }

        # Write the row, then rewrite individual cells with colour
        # PowerShell can't inline per-cell colour in a single Write-Host,
        # so we print cell by cell
        Write-Host "|" -ForegroundColor DarkCyan -NoNewline
        foreach ($col in $columns.GetEnumerator()) {
            $val     = $row.($col.Key)
            $display = if ($null -eq $val) { "" } else { "$val" }
            if ($display.Length -gt $col.Value) { $display = $display.Substring(0, $col.Value - 1) + "~" }
            $padded  = " {0,-$($col.Value)} " -f $display
            $color   = Get-CellColor $val
            if ($color -eq "White") { $color = $rowColor }
            Write-Host $padded -ForegroundColor $color -NoNewline
            Write-Host "|" -ForegroundColor DarkCyan -NoNewline
        }
        Write-Host ""  # newline
    }

    Write-Host $divider -ForegroundColor DarkCyan
}

function Write-HtmlReport {
    param (
        [System.Collections.Generic.List[PSCustomObject]]$Data,
        [string]$ReportPath
    )

    $totalCount   = [int]$Data.Count
    $successCount = [int]($Data | Where-Object { (-not $_.Error) -and ($_.Connected -eq $true) } | Measure-Object).Count
    $failCount    = [int]($Data | Where-Object { $_.Error -or ($_.Connected -ne $true) } | Measure-Object).Count

    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build table rows
    $rows = foreach ($row in $Data) {
        $overallOk = (-not $row.Error) -and
                     ($row.Connected -eq $true) -and
                     ($row.NTP -eq "OK") -and
                     ($row.AdvancedSettings -eq "OK")

        $rowClass = if ($row.Error) { "fail" } elseif ($overallOk) { "ok" } else { "warn" }

        $thumbCell = if ($row.Thumbprint -eq "N/A") {
            "<td class='na'>N/A</td>"
        } else {
            "<td class='thumbprint'>$([System.Web.HttpUtility]::HtmlEncode($row.Thumbprint))</td>"
        }

        $statusIcon = if ($row.Error) { "&#10008;" } elseif ($overallOk) { "&#10004;" } else { "&#9888;" }

        "
        <tr class='$rowClass'>
            <td>$([System.Web.HttpUtility]::HtmlEncode($row.Host))</td>
            $thumbCell
            <td>$(if ($row.CertRegen -eq 'OK') { 'Regenerated' } elseif ($row.CertRegen -eq 'Skipped') { 'Not needed' } elseif ($row.CertRegen -eq 'Manual') { 'Manual required' } else { [System.Web.HttpUtility]::HtmlEncode($row.CertRegen) })</td>
            <td>$(if ($row.Rebooted -eq 'OK') { 'Yes' } elseif ($row.Rebooted -eq 'Skipped') { 'Not needed' } elseif ($row.Rebooted -eq 'Manual') { 'Manual required' } else { [System.Web.HttpUtility]::HtmlEncode($row.Rebooted) })</td>
            <td>$(if ($row.NTP -eq 'OK') { 'OK' } else { [System.Web.HttpUtility]::HtmlEncode($row.NTP) })</td>
            <td>$(if ($row.AdvancedSettings -eq 'OK') { 'OK' } else { [System.Web.HttpUtility]::HtmlEncode($row.AdvancedSettings) })</td>
            <td>$(if ($row.PasswordReset -eq 'OK') { 'Reset' } elseif ($row.PasswordReset -eq 'Skipped') { 'Not requested' } else { [System.Web.HttpUtility]::HtmlEncode($row.PasswordReset) })</td>
            <td class='status'>$statusIcon $(if ($row.Error) { [System.Web.HttpUtility]::HtmlEncode($row.Error) } else { '' })</td>
        </tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HostPrep Report</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #0d1117; color: #c9d1d9; padding: 32px; }
  header { margin-bottom: 28px; border-bottom: 2px solid #1f6feb; padding-bottom: 16px; }
  header h1 { font-size: 1.6rem; color: #58a6ff; letter-spacing: 0.5px; }
  header p  { font-size: 0.85rem; color: #8b949e; margin-top: 4px; }
  .meta { display: flex; gap: 32px; margin-bottom: 24px; }
  .meta-item { background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 20px; }
  .meta-item .label { font-size: 0.75rem; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
  .meta-item .value { font-size: 1.1rem; font-weight: 600; color: #c9d1d9; margin-top: 2px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; background: #161b22; border-radius: 8px; overflow: hidden; border: 1px solid #30363d; }
  thead th { background: #1f2937; color: #58a6ff; padding: 10px 14px; text-align: left; font-weight: 600; letter-spacing: 0.4px; white-space: nowrap; border-bottom: 2px solid #1f6feb; }
  tbody tr { border-bottom: 1px solid #21262d; transition: background 0.15s; }
  tbody tr:hover { background: #1c2128; }
  tbody tr:last-child { border-bottom: none; }
  td { padding: 10px 14px; vertical-align: top; }
  td.thumbprint { font-family: 'Consolas', 'Courier New', monospace; font-size: 0.72rem; color: #79c0ff; word-break: break-all; max-width: 420px; }
  td.na { color: #6e7681; font-style: italic; }
  td.status { white-space: nowrap; }
  tr.ok  td.status { color: #3fb950; }
  tr.fail td.status { color: #f85149; }
  tr.warn td.status { color: #d29922; }
  tr.ok  td:first-child { border-left: 3px solid #3fb950; }
  tr.fail td:first-child { border-left: 3px solid #f85149; }
  tr.warn td:first-child { border-left: 3px solid #d29922; }
  .note { margin-top: 20px; font-size: 0.8rem; color: #8b949e; background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 12px 16px; }
  .note strong { color: #c9d1d9; }
  footer { margin-top: 28px; font-size: 0.75rem; color: #6e7681; text-align: center; }
</style>
</head>
<body>

<header>
  <h1>&#128196; HostPrep &mdash; VCF Commissioning Report</h1>
  <p>Generated by HostPrep.ps1 v$($ScriptMeta.Version) &bull; $generatedAt</p>
</header>

<div class="meta">
  <div class="meta-item">
    <div class="label">Hosts processed</div>
    <div class="value">$totalCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Successful</div>
    <div class="value" style="color:#3fb950">$successCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Failed</div>
    <div class="value" style="color:#f85149">$failCount</div>
  </div>
  <div class="meta-item">
    <div class="label">Thumbprint algorithm</div>
    <div class="value">SHA-256</div>
  </div>
</div>

<table>
  <thead>
    <tr>
      <th>Host FQDN</th>
      <th>SSL Thumbprint (SHA-256)</th>
      <th>Cert Regen</th>
      <th>Rebooted</th>
      <th>NTP</th>
      <th>Advanced Settings</th>
      <th>Password Reset</th>
      <th>Status</th>
    </tr>
  </thead>
  <tbody>
    $($rows -join "`n")
  </tbody>
</table>

<div class="note">
  <strong>Note:</strong> The SSL thumbprint shown is the SHA-256 fingerprint of the certificate
  present on each host at the time this script ran. Use these values to verify host identity
  when adding hosts to SDDC Manager during VCF commissioning.
  Thumbprints for hosts where certificate regeneration was performed reflect the <em>new</em> certificate.
</div>

<footer>HostPrep.ps1 &bull; $($ScriptMeta.Author) &bull; $($ScriptMeta.Blog)</footer>

</body>
</html>
"@

    $html | Out-File -FilePath $ReportPath -Encoding UTF8
    Write-Host ("  HTML report written to: {0}" -f $ReportPath) -ForegroundColor Cyan
}


Write-Host ""
Write-Host ("=" * $summaryWidth) -ForegroundColor DarkCyan
Write-Host ("  SUMMARY  -  {0} host(s) processed" -f $results.Count) -ForegroundColor Cyan
Write-Host ("=" * $summaryWidth) -ForegroundColor DarkCyan

Write-ColorSummaryTable -Data $results

# Legend
Write-Host ""
Write-Host "  Legend: " -NoNewline -ForegroundColor White
Write-Host "OK  "      -NoNewline -ForegroundColor Green
Write-Host "FAILED  "  -NoNewline -ForegroundColor Red
Write-Host "Skipped  " -NoNewline -ForegroundColor DarkGray
Write-Host "Manual  "  -NoNewline -ForegroundColor Yellow
Write-Host "Warning"               -ForegroundColor Yellow
Write-Host ""
Write-Host ("  Log written to    : {0}" -f $LogPath) -ForegroundColor DarkGray

Write-HtmlReport -Data $results -ReportPath $ReportPath

Write-Host ("=" * $summaryWidth) -ForegroundColor DarkCyan
Write-Host ""

Stop-Transcript

#endregion
