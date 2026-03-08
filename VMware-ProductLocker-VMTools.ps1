<#
.SYNOPSIS
    VMware ESXi ProductLocker & VMTools Audit/Configure Tool
    ---------------------------------------------------------
    - Saves vCenter credentials securely next to the script
    - Interactive audit menu: choose ProductLocker and/or VMTools audit
    - Audit and interactively set ProductLocker per cluster
    - Reset ProductLocker to local OS volume default (VMFSOS UUID via ESXCLI)
    - Upload VMtools ISO/ZIP to a target datastore
    - Copy VMtools package between datastores
    - Report VMware Tools versions, version status and management mode per VM

.DESCRIPTION
    This script provides the following functions:
      1. Secure credential save/load (Export-Clixml, encrypted to current Windows user)
      2. Interactive audit menu to select which audits to run
      3. Audit ProductLocker location on all ESXi hosts
      4. Interactively set ProductLocker per cluster via datastore picker menu
      5. Reset ProductLocker to local OS volume default per host (VMFSOS UUID via ESXCLI)
      6. Upload VMware Tools packages (local ISO/ZIP to a datastore)
      7. Copy VMware Tools packages between datastores
      8. Full VMware Tools audit: run status, version currency, management mode

.PARAMETER vCenterServer
    FQDN or IP of the vCenter Server

.PARAMETER Cluster
    (Optional) Target cluster name. If omitted, all clusters are processed.

.PARAMETER SetProductLocker
    (Optional) Interactively set ProductLocker per cluster via datastore menu.

.PARAMETER UploadVMTools
    (Optional) Upload a local VMware Tools ISO or ZIP to a target datastore.

.PARAMETER UploadSourcePath
    Full local path of the VMTools ISO or ZIP to upload.

.PARAMETER CopyVMTools
    (Optional) Copy VMware Tools package folder between datastores.

.PARAMETER CopySourceDatastore
    Name of the source datastore to copy VMTools from.

.PARAMETER CopySourcePath
    Folder path on the source datastore (e.g. /locker/packages/vmtoolsRepo).

.PARAMETER ExportReport
    (Optional) Export results to CSV files in the current directory.

.PARAMETER ResetProductLocker
    (Optional) Reset ProductLocker on all hosts to their local OS volume default path.
    Resolves the VMFSOS volume UUID per host via esxcli storage filesystem list and
    builds the full path as /vmfs/volumes/<VMFSOS-UUID>/locker/packages/<subfolder>:
      ESXi 7.x / 8.x -> vmtoolsd
      ESXi 9.x+      -> vmtoolsRepo

.PARAMETER ResetCredentials
    (Optional) Force a new credential prompt even if a saved credential file exists.

.EXAMPLE
    # First run - prompts for credentials and saves them, then shows audit menu
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local

.EXAMPLE
    # Force new credential prompt
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local -ResetCredentials

.EXAMPLE
    # Interactively set ProductLocker per cluster
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local -SetProductLocker

.EXAMPLE
    # Upload local VMTools ISO to a datastore
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local `
        -UploadVMTools -UploadSourcePath "C:\vmtools\VMware-tools-12.4.0.iso"

.EXAMPLE
    # Copy VMTools from one datastore to others
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local `
        -CopyVMTools -CopySourceDatastore "DS-Site-A" -CopySourcePath "/locker/packages/vmtoolsRepo"

.EXAMPLE
    # Full run with CSV export
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local -SetProductLocker -ExportReport

.EXAMPLE
    # Reset ProductLocker to factory default on all hosts
    .\VMware-ProductLocker-VMTools.ps1 -vCenterServer vc01.lab.local -ResetProductLocker

.NOTES
    Author   : Paul van Dieen
    Blog     : https://www.hollebollevsan.nl
    Requires : VMware PowerCLI 12+ (vSphere 7/8) or VCF PowerCLI 9.0+ (vSphere 9)
    Tested   : vSphere 7.x / 8.x / 9.x

    vSphere 9 / VCF PowerCLI 9.0 compatibility notes:
    - VMware PowerCLI was renamed to VCF PowerCLI starting with version 9.0
    - Install on vSphere 9: Install-Module -Name VCF.PowerCLI -Scope CurrentUser
    - Classic high-level cmdlets (Get-VM, Get-VMHost, Get-Cluster etc.) are unchanged
    - VIM/SOAP API via ExtensionData is still fully supported alongside new REST APIs
    - Guest.ToolsStatus and Guest.ToolsVersionStatus2 properties are unchanged
    - Module check detects both VMware.VimAutomation.Core (vSphere 7/8)
      and VCF.PowerCLI (vSphere 9) and imports whichever is available

    Credential storage:
    - Saved as <vCenterServer>.cred in the same folder as the script
    - Encrypted via Export-Clixml to the current Windows user account
    - Cannot be decrypted on a different machine or by a different user
    - Use -ResetCredentials to force a new prompt and overwrite the saved file

.CHANGELOG
    v1.3.2  2026-03-08  Paul van Dieen
        - Cleanup: collapsed 13-entry iterative dev changelog into 3 clean entries
        - Cleanup: fixed stale synopsis and description (still referenced ESXi version
          based default; now correctly describes VMFSOS UUID via ESXCLI approach)
        - Bugfix: UpdateProductLockerLocation() in Invoke-ProductLockerAudit now uses
          $null = to suppress pipeline output, consistent with reset function
        - Bugfix: $pathVerified initialised to $null before conditional block to prevent
          uninitialized variable reference in result object when DatastoreName is empty
        - Bugfix: Test-ProductLockerPath now skips gracefully when path is not on a
          vCenter-registered datastore (local VMFSOS volumes are not in vmstore:\)

    v1.1.0  2026-03-07  Paul van Dieen
        - Per-cluster interactive datastore picker for ProductLocker path
        - VMTools upload: local ISO/ZIP to target datastore via Copy-DatastoreItem
        - VMTools copy: replicate package folder between datastores interactively
        - VMTools audit: run status, version currency, management mode per VM
        - Credential saving: encrypted .cred file per vCenter, bound to Windows user
        - Interactive audit menu: ProductLocker, VMTools, Both, or Skip
        - vSphere 9 / VCF PowerCLI 9.0 module detection and auto-import
        - Post-set path verification with warning if locker folder not found
        - Reset ProductLocker to default: VMFSOS UUID resolved per host via ESXCLI
          storage filesystem list - works when local volume is not a vCenter datastore

    v1.0.0  2026-03-07  Paul van Dieen
        - Initial release
        - ProductLocker audit via ExtensionData.QueryProductLockerLocation()
        - ProductLocker set via ExtensionData.UpdateProductLockerLocation()
        - VMware Tools audit: run status, version status, management mode per VM
        - Colour-coded console output with per-status summary
        - Optional CSV export for ProductLocker and VMTools results
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$vCenterServer,

    [string]$Cluster,

    [switch]$SetProductLocker,
    [switch]$ResetProductLocker,

    [switch]$UploadVMTools,
    [string]$UploadSourcePath    = "",

    [switch]$CopyVMTools,
    [string]$CopySourceDatastore = "",
    [string]$CopySourcePath      = "",

    [switch]$ExportReport,

    [switch]$ResetCredentials
)

# --- PowerCLI Module Check ----------------------------------------------------
# Supports both VMware PowerCLI (vSphere 7/8) and VCF PowerCLI 9.0 (vSphere 9)
$vcfModule    = Get-Module -Name VCF.PowerCLI                  -ListAvailable
$legacyModule = Get-Module -Name VMware.VimAutomation.Core     -ListAvailable

if (-not $vcfModule -and -not $legacyModule) {
    Write-Host "  [ERROR] No compatible PowerCLI module found." -ForegroundColor Red
    Write-Host "          vSphere 9 : Install-Module -Name VCF.PowerCLI          -Scope CurrentUser" -ForegroundColor Yellow
    Write-Host "          vSphere 8 : Install-Module -Name VMware.PowerCLI       -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

if ($vcfModule) {
    if (-not (Get-Module -Name VCF.PowerCLI)) {
        Write-Host "  [INFO] Loading VCF.PowerCLI (vSphere 9)..." -ForegroundColor Cyan
        Import-Module VCF.PowerCLI -ErrorAction Stop
    }
}
else {
    if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
        Write-Host "  [INFO] Loading VMware.VimAutomation.Core (vSphere 7/8)..." -ForegroundColor Cyan
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    }
}

# --- Parameter Validation -----------------------------------------------------
if ($UploadVMTools -and [string]::IsNullOrWhiteSpace($UploadSourcePath)) {
    Write-Host "  [ERROR] -UploadSourcePath is required when using -UploadVMTools." -ForegroundColor Red
    exit 1
}
if ($UploadVMTools -and -not (Test-Path $UploadSourcePath)) {
    Write-Host "  [ERROR] File not found: $UploadSourcePath" -ForegroundColor Red
    exit 1
}
if ($CopyVMTools -and ([string]::IsNullOrWhiteSpace($CopySourceDatastore) -or [string]::IsNullOrWhiteSpace($CopySourcePath))) {
    Write-Host "  [ERROR] -CopySourceDatastore and -CopySourcePath are both required when using -CopyVMTools." -ForegroundColor Red
    exit 1
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Add-ToList {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$List,
        $Items
    )
    if ($null -eq $Items) { return }
    foreach ($item in @($Items)) {
        if ($null -ne $item) { $List.Add($item) }
    }
}

# --- Colour Palette ----------------------------------------------------------
$ESC   = [char]27
$RESET = "$ESC[0m"
$BOLD  = "$ESC[1m"
$CYAN  = "$ESC[36m"
$GREEN = "$ESC[32m"
$YELL  = "$ESC[33m"
$RED   = "$ESC[31m"
$BLUE  = "$ESC[34m"
$DIM   = "$ESC[2m"
$MAG   = "$ESC[35m"

function Show-Banner {
    Write-Host ""
    Write-Host "${BOLD}${CYAN}  +==========================================================+${RESET}"
    Write-Host "${BOLD}${CYAN}  |   VMware ProductLocker & VMTools Audit Tool              |${RESET}"
    Write-Host "${BOLD}${CYAN}  |   vSphere Host & Cluster Configuration Inspector         |${RESET}"
    Write-Host "${BOLD}${CYAN}  +==========================================================+${RESET}"
    Write-Host ""
}

function Write-Section ($title) {
    Write-Host ""
    Write-Host "${BOLD}${BLUE}  +--- $title ${RESET}"
    Write-Host ""
}

function Write-OK   ($msg) { Write-Host "  ${GREEN}[OK]${RESET}  $msg" }
function Write-Warn ($msg) { Write-Host "  ${YELL}[!]${RESET}   $msg" }
function Write-Err  ($msg) { Write-Host "  ${RED}[X]${RESET}  $msg" }
function Write-Info ($msg) { Write-Host "  ${CYAN}->${RESET}  $msg" }
function Write-Step ($msg) { Write-Host "  ${DIM}$msg${RESET}" }

# =============================================================================
# CREDENTIAL MANAGEMENT
# =============================================================================

function Get-SavedCredential {
    param([string]$vCenterServer)

    # Credential file lives next to the script, named after the vCenter host
    $safeName  = $vCenterServer -replace '[\\/:*?"<>|]', '_'
    $credFile  = Join-Path $PSScriptRoot "$safeName.cred"

    if ($ResetCredentials -and (Test-Path $credFile)) {
        Remove-Item $credFile -Force
        Write-Info "Saved credentials removed. Prompting for new credentials..."
    }

    if (Test-Path $credFile) {
        try {
            $cred = Import-Clixml -Path $credFile -ErrorAction Stop
            Write-OK "Loaded saved credentials for $($cred.UserName) from $safeName.cred"
            return $cred
        }
        catch {
            Write-Warn "Could not load saved credentials ($credFile): $_"
            Write-Info "Prompting for new credentials..."
        }
    }
    else {
        Write-Info "No saved credentials found - prompting..."
    }

    $cred = Get-Credential -Message "Enter credentials for $vCenterServer"
    if (-not $cred) {
        Write-Err "No credentials provided."
        exit 1
    }

    try {
        $cred | Export-Clixml -Path $credFile -Force -ErrorAction Stop
        Write-OK "Credentials saved to $credFile"
    }
    catch {
        Write-Warn "Could not save credentials: $_"
    }

    return $cred
}

# =============================================================================
# AUDIT MENU
# =============================================================================

function Show-AuditMenu {
    Write-Host ""
    Write-Host "  ${BOLD}${CYAN}Select audit(s) to perform:${RESET}"
    Write-Host ""
    Write-Host "  ${BOLD}[1]${RESET}  ProductLocker Audit  - check ProductLocker location on all ESXi hosts"
    Write-Host "  ${BOLD}[2]${RESET}  VMware Tools Audit   - check tools version, status and management mode"
    Write-Host "  ${BOLD}[3]${RESET}  Both"
    Write-Host "  ${BOLD}[0]${RESET}  Skip audits (configuration actions only)"
    Write-Host ""

    $choice = Read-Host "  Enter selection"

    switch ($choice.Trim()) {
        "1" { return @{ RunLocker = $true;  RunTools = $false } }
        "2" { return @{ RunLocker = $false; RunTools = $true  } }
        "3" { return @{ RunLocker = $true;  RunTools = $true  } }
        "0" { return @{ RunLocker = $false; RunTools = $false } }
        default {
            Write-Warn "Invalid selection '$choice' - running both audits."
            return @{ RunLocker = $true; RunTools = $true }
        }
    }
}

function Get-ToolsStatusLabel {
    param([string]$Status)
    switch ($Status) {
        "toolsOk"           { return @{ Label = "Running/OK";     Color = $GREEN } }
        "toolsOld"          { return @{ Label = "Outdated";       Color = $YELL  } }
        "toolsNotRunning"   { return @{ Label = "Not Running";    Color = $YELL  } }
        "toolsNotInstalled" { return @{ Label = "Not Installed";  Color = $RED   } }
        "toolsNeedUpgrade"  { return @{ Label = "Upgrade Needed"; Color = $YELL  } }
        "toolsUnmanaged"    { return @{ Label = "Unmanaged";      Color = $CYAN  } }
        default             { return @{ Label = "Unknown";        Color = $DIM   } }
    }
}

function Get-ToolsVersionLabel {
    # ToolsVersionStatus2: version currency relative to the ESXi host
    param([string]$VersionStatus)
    switch ($VersionStatus) {
        "guestToolsCurrent"       { return @{ Label = "Current";         Color = $GREEN } }
        "guestToolsNeedUpgrade"   { return @{ Label = "Needs Upgrade";   Color = $YELL  } }
        "guestToolsNotInstalled"  { return @{ Label = "Not Installed";   Color = $RED   } }
        "guestToolsBlacklisted"   { return @{ Label = "Blacklisted";     Color = $RED   } }
        "guestToolsSupportedNew"  { return @{ Label = "Newer than host"; Color = $CYAN  } }
        "guestToolsSupportedOld"  { return @{ Label = "Older supported"; Color = $YELL  } }
        "guestToolsTooNew"        { return @{ Label = "Too New";         Color = $MAG   } }
        "guestToolsTooOld"        { return @{ Label = "Too Old";         Color = $RED   } }
        "guestToolsUnmanaged"     { return @{ Label = "Unmanaged (OSP)"; Color = $CYAN  } }
        default                   { return @{ Label = "Unknown";         Color = $DIM   } }
    }
}

function Get-ToolsMgmtLabel {
    # Determine who manages the VMTools installation
    # guestToolsUnmanaged / toolsUnmanaged = open-vm-tools via guest OS package manager
    param([string]$VersionStatus, [string]$Status)
    if ($VersionStatus -eq "guestToolsUnmanaged" -or $Status -eq "toolsUnmanaged") {
        return @{ Label = "Guest Managed";    Color = $CYAN  }
    }
    elseif ($Status -eq "toolsNotInstalled") {
        return @{ Label = "N/A";              Color = $DIM   }
    }
    else {
        return @{ Label = "vCenter/ESX Mgd";  Color = $GREEN }
    }
}

# =============================================================================
# INTERACTIVE DATASTORE PICKER
# =============================================================================

function Select-Datastore {
    param(
        [string]$ClusterName,
        [string]$Prompt = "Select target datastore"
    )

    $datastores = Get-Datastore -RelatedObject (Get-Cluster -Name $ClusterName) | Sort-Object Name

    if (-not $datastores) {
        Write-Warn "No datastores found for cluster '$ClusterName'."
        return $null
    }

    Write-Host ""
    Write-Host "  ${BOLD}${CYAN}$Prompt  [Cluster: $ClusterName]${RESET}"
    Write-Host ""

    $i = 1
    foreach ($ds in $datastores) {
        $freeGB = [math]::Round($ds.FreeSpaceGB, 1)
        $capGB  = [math]::Round($ds.CapacityGB,  1)
        Write-Host ("  ${BOLD}[{0,2}]${RESET}  {1,-40} {2,8} GB free / {3,8} GB total" -f $i, $ds.Name, $freeGB, $capGB)
        $i++
    }

    Write-Host ""
    $choice = Read-Host "  Enter number (or 0 to skip / audit only)"

    if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) {
        Write-Warn "Skipped - cluster '$ClusterName' will be audited only."
        return $null
    }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $datastores.Count) {
        Write-Err "Invalid selection '$choice' - skipping cluster '$ClusterName'."
        return $null
    }

    return $datastores[$idx]
}

function Read-LockerSubPath {
    Write-Host ""
    Write-Host "  ${DIM}Enter the sub-path within the datastore for the ProductLocker folder.${RESET}"
    Write-Host "  ${DIM}Example: /locker/packages/vmtoolsRepo${RESET}"
    $sub = Read-Host "  Sub-path (blank = /locker/packages/vmtoolsRepo)"
    if ([string]::IsNullOrWhiteSpace($sub)) { $sub = "/locker/packages/vmtoolsRepo" }
    return $sub
}

# =============================================================================
# PRODUCTLOCKER PATH VERIFICATION
# =============================================================================

function Test-ProductLockerPath {
    # Verifies the locker path exists via the vmstore:\ provider.
    # Only works for paths on vCenter-registered datastores.
    # Local VMFSOS volumes (used by -ResetProductLocker) are not in vCenter
    # inventory and will not be found - returns $null in that case to signal
    # "not applicable" rather than $false which would mean "missing".
    param(
        [string]$TargetPath,
        [string]$DatastoreName
    )

    if (-not $DatastoreName) { return $null }

    try {
        $ds = Get-Datastore -Name $DatastoreName -ErrorAction Stop

        # Strip the /vmfs/volumes/<uuid> prefix to get the relative folder path
        $subPath     = ($TargetPath -replace '^/vmfs/volumes/[^/]+', '').TrimStart('/')
        $vmstorePath = "vmstore:\$($ds.Datacenter.Name)\$($ds.Name)\$subPath"

        return (Test-Path $vmstorePath)
    }
    catch {
        # Datastore not found in vCenter inventory - local volume, skip verification
        return $null
    }
}

# =============================================================================
# PRODUCTLOCKER RESET TO DEFAULT
# =============================================================================

function Get-ProductLockerDefault {
    # Finds the local OS volume (Type = VMFSOS) via ESXCLI storage.filesystem.list
    # and builds the full locker path from its UUID.
    # VMFSOS is the host-local OS partition - always exactly one per host.
    # The subfolder is version-dependent:
    #   ESXi 7.x / 8.x -> vmtoolsd
    #   ESXi 9.x+      -> vmtoolsRepo
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )

    # Version-based subfolder
    $major = [int]($VMHost.Version.Split(".")[0])
    if ($major -ge 9) { $subFolder = "vmtoolsRepo" } else { $subFolder = "vmtoolsd" }

    try {
        $esxcli  = Get-EsxCli -VMHost $VMHost -V2 -ErrorAction Stop
        $allVols = @($esxcli.storage.filesystem.list.Invoke())
        $osVol   = $allVols | Where-Object { $_.Type -eq "VMFSOS" } | Select-Object -First 1

        if (-not $osVol) {
            Write-Warn "$($VMHost.Name) - No VMFSOS volume found."
            return $null
        }

        $path = [string]"/vmfs/volumes/$($osVol.UUID)/locker/packages/$subFolder"
        return $path
    }
    catch {
        Write-Warn "$($VMHost.Name) - Could not query filesystem list: $_"
        return $null
    }
}

function Invoke-ResetProductLockerToDefault {
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost[]]$Hosts
    )

    Write-Section "Reset ProductLocker to Default"
    Write-Step "Default resolved from VMFSOS volume UUID via esxcli storage filesystem list"
    Write-Step "Subfolder: vmtoolsd (ESXi 7/8) or vmtoolsRepo (ESXi 9+)"
    Write-Host ""

    $resetCount = 0; $errCount = 0

    foreach ($vmhost in ($Hosts | Sort-Object Name)) {

        $currentVal = ""
        try {
            $currentVal = $vmhost.ExtensionData.QueryProductLockerLocation()
        }
        catch {
            Write-Err "$($vmhost.Name) - QueryProductLockerLocation() failed: $_"
            $errCount++; continue
        }

        $defaultPath = $null
        $defaultPath = Get-ProductLockerDefault -VMHost $vmhost | Select-Object -Last 1

        if (-not $defaultPath) {
            Write-Err "$($vmhost.Name) - Skipped: could not resolve default path."
            $errCount++; continue
        }

        if ($currentVal -eq $defaultPath) {
            Write-OK  "$($vmhost.Name)  already at default -> $currentVal"
            continue
        }

        Write-Info "$($vmhost.Name)"
        Write-Step "     Current : $currentVal"
        Write-Step "     Default : $defaultPath"

        if ($PSCmdlet.ShouldProcess($vmhost.Name, "Reset ProductLockerLocation to '$defaultPath'")) {
            try {
                $null = $vmhost.ExtensionData.UpdateProductLockerLocation($defaultPath)
                $newVal = $vmhost.ExtensionData.QueryProductLockerLocation()
                Write-OK  "$($vmhost.Name) - Reset complete"
                Write-Step "     Confirmed : $newVal"
                Write-Step "     Note      : Change is live immediately - no reboot required."
                $resetCount++
            }
            catch {
                Write-Err "$($vmhost.Name) - Reset failed: $_"
                $errCount++
            }
        }
    }

    Write-Host ""
    Write-Step "--------------------------------------------"
    Write-Info "Hosts reset : $resetCount   Errors : $errCount"
}

function Invoke-ProductLockerAudit {
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost[]]$Hosts,
        [bool]$SetValue,
        [string]$TargetPath,
        [string]$DatastoreName = ""
    )

    Write-Section "ProductLocker Audit"
    Write-Step "Method: ExtensionData.QueryProductLockerLocation() / UpdateProductLockerLocation()"
    if ($SetValue -and $TargetPath) { Write-Step "Target : $TargetPath" }
    Write-Host ""

    $results  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $setCount = 0; $okCount = 0; $warnCount = 0

    foreach ($vmhost in ($Hosts | Sort-Object Name)) {

        $currentVal = ""
        try {
            $currentVal = $vmhost.ExtensionData.QueryProductLockerLocation()
        }
        catch {
            Write-Warn "$($vmhost.Name) - QueryProductLockerLocation() failed: $_"
            continue
        }

        # Determine status
        if (-not $TargetPath) {
            $status = "AUDIT"
        }
        elseif ($currentVal -eq $TargetPath) {
            $status = "OK"
        }
        else {
            $status = "MISMATCH"
        }

        if ($SetValue -and $status -eq "MISMATCH") {
            if ($PSCmdlet.ShouldProcess($vmhost.Name, "UpdateProductLockerLocation('$TargetPath')")) {
                try {
                    $null = $vmhost.ExtensionData.UpdateProductLockerLocation($TargetPath)
                    $newVal     = $vmhost.ExtensionData.QueryProductLockerLocation()
                    Write-OK  "$($vmhost.Name)"
                    Write-Step "     Before : $currentVal"
                    Write-Step "     After  : $newVal"
                    Write-Step "     Note   : Change is live immediately - no reboot required."
                    $currentVal = $newVal; $status = "SET"; $setCount++

                    # Initialise before conditional - stays $null if no DatastoreName
                    # (Test-ProductLockerPath returns $null for non-vCenter volumes)
                    $pathVerified = $null

                    # Verify the path actually exists on the datastore.
                    # The host does not validate at set time - a missing path causes
                    # silent failures when VMTools installs/upgrades are triggered.
                    if ($DatastoreName) {
                        $pathVerified = Test-ProductLockerPath -TargetPath $TargetPath -DatastoreName $DatastoreName
                        if ($pathVerified -eq $true) {
                            Write-OK  "$($vmhost.Name) - Path verified: $TargetPath exists on $DatastoreName"
                        }
                        elseif ($null -eq $pathVerified) {
                            Write-Step "     Verify : Local volume - path verification not available via vCenter"
                        }
                        else {
                            Write-Warn "$($vmhost.Name) - Path NOT found on datastore '$DatastoreName': $TargetPath"
                            Write-Warn "  VMTools installs/upgrades will fail until the folder and contents are in place."
                            Write-Warn "  Use -UploadVMTools or -CopyVMTools to populate the locker folder."
                            $status = "SET_PATH_MISSING"
                        }
                    }
                }
                catch {
                    Write-Err "$($vmhost.Name) - UpdateProductLockerLocation() failed: $_"
                    $status = "ERROR"; $warnCount++
                }
            }
        }
        else {
            switch ($status) {
                "OK"      {
                    $sfx = if ($SetValue) { "  ${DIM}(already correct)${RESET}" } else { "" }
                    Write-OK   "$($vmhost.Name)  ${DIM}-> $currentVal${RESET}$sfx"; $okCount++
                }
                "MISMATCH" {
                    Write-Warn "$($vmhost.Name)  ${DIM}-> $currentVal  (expected: $TargetPath)${RESET}"; $warnCount++
                }
                "AUDIT"   {
                    Write-Info "$($vmhost.Name)  ${DIM}-> $currentVal${RESET}"; $okCount++
                }
            }
        }

        $results.Add([PSCustomObject]@{
            Hostname        = $vmhost.Name
            ConnectionState = $vmhost.ConnectionState
            CurrentValue    = $currentVal
            ExpectedValue   = $TargetPath
            Status          = $status
            PathVerified    = if   ($status -eq "SET" -and $null -ne $pathVerified) { $pathVerified }
                              elseif ($status -eq "SET" -and $null -eq $pathVerified) { "N/A (local vol)" }
                              elseif ($status -eq "SET_PATH_MISSING")                { $false }
                              else                                                    { "N/A" }
            Timestamp       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }

    Write-Host ""
    Write-Step "--------------------------------------------"
    if ($SetValue) {
        Write-Info "Hosts updated : $setCount   Already correct : $okCount   Errors : $warnCount"
    }
    else {
        Write-Info "Hosts audited : $($okCount + $warnCount)   Mismatches : $warnCount"
    }

    return $results
}

# =============================================================================
# VMTOOLS UPLOAD (local file -> datastore)
# =============================================================================

function Invoke-VMToolsUpload {
    param([string]$SourceFilePath)

    Write-Section "VMware Tools Upload"
    Write-Info "Source file : $SourceFilePath"

    $allDS = Get-Datastore | Sort-Object Name
    if (-not $allDS) { Write-Err "No datastores found."; return }

    Write-Host ""
    Write-Host "  ${BOLD}${CYAN}Select target datastore for upload:${RESET}"
    Write-Host ""
    $i = 1
    foreach ($ds in $allDS) {
        $freeGB = [math]::Round($ds.FreeSpaceGB, 1)
        $capGB  = [math]::Round($ds.CapacityGB,  1)
        Write-Host ("  ${BOLD}[{0,2}]${RESET}  {1,-40} {2,8} GB free / {3,8} GB total" -f $i, $ds.Name, $freeGB, $capGB)
        $i++
    }

    Write-Host ""
    $choice = Read-Host "  Enter number (or 0 to cancel)"
    if ($choice -eq "0" -or [string]::IsNullOrWhiteSpace($choice)) { Write-Warn "Upload cancelled."; return }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $allDS.Count) { Write-Err "Invalid selection."; return }
    $targetDS = $allDS[$idx]

    Write-Host ""
    Write-Host "  ${DIM}Enter the destination folder path on the datastore.${RESET}"
    Write-Host "  ${DIM}Example: /locker/packages/vmtoolsRepo  (blank = datastore root)${RESET}"
    $destFolder = Read-Host "  Destination folder"
    if ([string]::IsNullOrWhiteSpace($destFolder)) { $destFolder = "" }

    # Strip leading slash for vmstore path construction
    $destPath = "vmstore:\$($targetDS.Datacenter.Name)\$($targetDS.Name)\$($destFolder.TrimStart('/'))"
    $fileName = Split-Path $SourceFilePath -Leaf

    Write-Host ""
    Write-Info "Destination : $destPath"
    Write-Info "File        : $fileName"

    if ($PSCmdlet.ShouldProcess($destPath, "Upload $fileName")) {
        try {
            if (-not (Test-Path $destPath)) {
                Write-Step "Creating destination folder..."
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }
            Write-Step "Uploading... (this may take a while for large files)"
            Copy-DatastoreItem -Item $SourceFilePath -Destination $destPath -ErrorAction Stop
            Write-OK "Upload complete -> $destPath\$fileName"
        }
        catch {
            Write-Err "Upload failed: $_"
        }
    }
}

# =============================================================================
# VMTOOLS COPY (datastore folder -> one or more datastores)
# =============================================================================

function Invoke-VMToolsCopy {
    param(
        [string]$SrcDatastoreName,
        [string]$SrcPath
    )

    Write-Section "VMware Tools Datastore Copy"

    try {
        $srcDS = Get-Datastore -Name $SrcDatastoreName -ErrorAction Stop
    }
    catch {
        Write-Err "Source datastore '$SrcDatastoreName' not found: $_"
        return
    }

    $srcFull = "vmstore:\$($srcDS.Datacenter.Name)\$($srcDS.Name)\$($SrcPath.TrimStart('/'))"
    Write-Info "Source : $srcFull"

    if (-not (Test-Path $srcFull)) {
        Write-Err "Source path does not exist on datastore: $srcFull"
        return
    }

    $otherDS = Get-Datastore | Where-Object { $_.Name -ne $SrcDatastoreName } | Sort-Object Name
    if (-not $otherDS) { Write-Err "No other datastores found in inventory."; return }

    Write-Host ""
    Write-Host "  ${BOLD}${CYAN}Select target datastore(s) - comma-separated numbers:${RESET}"
    Write-Host ""
    $i = 1
    foreach ($ds in $otherDS) {
        $freeGB = [math]::Round($ds.FreeSpaceGB, 1)
        $capGB  = [math]::Round($ds.CapacityGB,  1)
        Write-Host ("  ${BOLD}[{0,2}]${RESET}  {1,-40} {2,8} GB free / {3,8} GB total" -f $i, $ds.Name, $freeGB, $capGB)
        $i++
    }

    Write-Host ""
    $choices = Read-Host "  Enter number(s) comma-separated (or 0 to cancel)"
    if ($choices -eq "0" -or [string]::IsNullOrWhiteSpace($choices)) { Write-Warn "Copy cancelled."; return }

    $selectedDS = foreach ($c in ($choices -split ",")) {
        $c   = $c.Trim()
        $idx = [int]$c - 1
        if ($idx -ge 0 -and $idx -lt $otherDS.Count) { $otherDS[$idx] }
        else { Write-Warn "Skipping invalid selection: $c" }
    }

    Write-Host ""
    Write-Host "  ${DIM}Enter destination path on target datastore(s).${RESET}"
    $destSub = Read-Host "  Destination path (blank = same as source: $SrcPath)"
    if ([string]::IsNullOrWhiteSpace($destSub)) { $destSub = $SrcPath }

    foreach ($tDS in $selectedDS) {
        $destFull = "vmstore:\$($tDS.Datacenter.Name)\$($tDS.Name)\$($destSub.TrimStart('/'))"
        Write-Info "Copying to $($tDS.Name) -> $destFull"

        if ($PSCmdlet.ShouldProcess($destFull, "Copy from $srcFull")) {
            try {
                if (-not (Test-Path $destFull)) {
                    New-Item -Path $destFull -ItemType Directory -Force | Out-Null
                }
                Copy-DatastoreItem -Item $srcFull -Destination $destFull -Recurse -Force -ErrorAction Stop
                Write-OK "Copy complete -> $($tDS.Name)"
            }
            catch {
                Write-Err "Copy to $($tDS.Name) failed: $_"
            }
        }
    }
}

# =============================================================================
# VMTOOLS AUDIT (run status + version status + management mode)
# =============================================================================

function Invoke-VMToolsAudit {
    param(
        [string]$ClusterName
    )

    Write-Section "VMware Tools Audit - Cluster: $ClusterName"

    $vms = Get-VM -Location (Get-Cluster -Name $ClusterName) -ErrorAction SilentlyContinue |
           Where-Object { $_.PowerState -eq "PoweredOn" } |
           Sort-Object Name

    if (-not $vms) {
        Write-Warn "No powered-on VMs found in cluster '$ClusterName'."
        return [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    Write-Step "Scanning $($vms.Count) powered-on VMs..."
    Write-Host ""

    # Column widths
    $c1 = 30; $c2 = 15; $c3 = 18; $c4 = 17; $c5 = 9
    $hdr = "  {0,-$c1} {1,-$c2} {2,-$c3} {3,-$c4} {4,-$c5}" -f "VM Name", "Run Status", "Version Status", "Managed By", "Version"
    Write-Host "${BOLD}$hdr${RESET}"
    Write-Host "  $('-' * ($c1 + $c2 + $c3 + $c4 + $c5 + 4))"

    $summary = @{
        Status        = [ordered]@{}
        VersionStatus = [ordered]@{}
        MgmtMode      = [ordered]@{}
    }
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($vm in $vms) {
        $guest         = $vm.ExtensionData.Guest
        $runStatus     = $guest.ToolsStatus
        $verStatus     = $guest.ToolsVersionStatus2
        $toolsVersion  = if ($guest.ToolsVersion) { $guest.ToolsVersion } else { "N/A" }

        $runLbl  = Get-ToolsStatusLabel  -Status        $runStatus
        $verLbl  = Get-ToolsVersionLabel -VersionStatus $verStatus
        $mgmtLbl = Get-ToolsMgmtLabel   -VersionStatus $verStatus -Status $runStatus

        # Tallies
        if (-not $summary.Status.Contains($runLbl.Label))        { $summary.Status[$runLbl.Label] = 0 }
        if (-not $summary.VersionStatus.Contains($verLbl.Label)) { $summary.VersionStatus[$verLbl.Label] = 0 }
        if (-not $summary.MgmtMode.Contains($mgmtLbl.Label))     { $summary.MgmtMode[$mgmtLbl.Label] = 0 }
        $summary.Status[$runLbl.Label]++
        $summary.VersionStatus[$verLbl.Label]++
        $summary.MgmtMode[$mgmtLbl.Label]++

        $vmName = if ($vm.Name.Length -gt $c1 - 1) { $vm.Name.Substring(0, $c1 - 2) + ".." } else { $vm.Name }
        $row    = "  {0,-$c1} {1,-$c2} {2,-$c3} {3,-$c4} {4,-$c5}" -f `
                    $vmName, $runLbl.Label, $verLbl.Label, $mgmtLbl.Label, $toolsVersion

        # Row colour driven by run status
        Write-Host "$($runLbl.Color)$row${RESET}"

        $results.Add([PSCustomObject]@{
            VMName             = $vm.Name
            PowerState         = $vm.PowerState
            Host               = $vm.VMHost.Name
            Cluster            = $ClusterName
            RunStatus          = $runStatus
            RunStatusLabel     = $runLbl.Label
            VersionStatus      = $verStatus
            VersionStatusLabel = $verLbl.Label
            ManagedBy          = $mgmtLbl.Label
            ToolsVersion       = $toolsVersion
            GuestOS            = $guest.GuestFullName
            Timestamp          = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        })
    }

    # Three-section summary
    Write-Host ""
    Write-Step "--------------------------------------------"

    Write-Host "  ${BOLD}Run Status:${RESET}"
    foreach ($k in $summary.Status.Keys) {
        $pct = [math]::Round(($summary.Status[$k] / $vms.Count) * 100, 1)
        $bar = "#" * [math]::Round($pct / 5)
        Write-Host ("    {0,-22} {1,4} VMs  {2,-18} {3,5}%" -f $k, $summary.Status[$k], $bar, $pct)
    }

    Write-Host ""
    Write-Host "  ${BOLD}Version Status:${RESET}"
    foreach ($k in $summary.VersionStatus.Keys) {
        $pct = [math]::Round(($summary.VersionStatus[$k] / $vms.Count) * 100, 1)
        $bar = "#" * [math]::Round($pct / 5)
        Write-Host ("    {0,-22} {1,4} VMs  {2,-18} {3,5}%" -f $k, $summary.VersionStatus[$k], $bar, $pct)
    }

    Write-Host ""
    Write-Host "  ${BOLD}Management Mode:${RESET}"
    foreach ($k in $summary.MgmtMode.Keys) {
        $pct = [math]::Round(($summary.MgmtMode[$k] / $vms.Count) * 100, 1)
        $bar = "#" * [math]::Round($pct / 5)
        Write-Host ("    {0,-22} {1,4} VMs  {2,-18} {3,5}%" -f $k, $summary.MgmtMode[$k], $bar, $pct)
    }

    return $results
}

# =============================================================================
#  MAIN
# =============================================================================
Show-Banner

# -- Credentials --------------------------------------------------------------
Write-Section "Credentials"
$credential = Get-SavedCredential -vCenterServer $vCenterServer

# -- Connect ------------------------------------------------------------------
Write-Section "Connecting to vCenter"
Write-Info "Target: $vCenterServer"

try {
    $null = Connect-VIServer -Server $vCenterServer -Credential $credential -ErrorAction Stop
    Write-OK "Connected to $vCenterServer"
}
catch {
    Write-Err "Connection failed: $_"
    exit 1
}

# -- Resolve clusters ---------------------------------------------------------
Write-Section "Resolving Scope"

try {
    if ($Cluster) {
        $clusters = @(Get-Cluster -Name $Cluster -ErrorAction Stop)
        Write-Info "Cluster filter : $Cluster"
    }
    else {
        $clusters = @(Get-Cluster -ErrorAction Stop)
        Write-Info "No cluster filter - scanning all $($clusters.Count) cluster(s)"
    }
}
catch {
    Write-Err "Could not resolve clusters: $_"
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
    exit 1
}

# -- Audit Menu ---------------------------------------------------------------
Write-Section "Audit Selection"
$auditChoice = Show-AuditMenu

# -- VMTools Upload -----------------------------------------------------------
if ($UploadVMTools) {
    Invoke-VMToolsUpload -SourceFilePath $UploadSourcePath
}

# -- VMTools Copy -------------------------------------------------------------
if ($CopyVMTools) {
    Invoke-VMToolsCopy -SrcDatastoreName $CopySourceDatastore -SrcPath $CopySourcePath
}

# -- ProductLocker (per cluster, interactive picker when -SetProductLocker) ---
$allLockerResults = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($auditChoice.RunLocker -or $SetProductLocker -or $ResetProductLocker) {
    foreach ($cl in $clusters) {
        Write-Host ""
        Write-Host "  ${BOLD}${CYAN}Cluster: $($cl.Name)${RESET}"

        $hosts = Get-VMHost -Location $cl | Where-Object { $_.ConnectionState -eq "Connected" }
        if (-not $hosts) {
            Write-Warn "No connected hosts in cluster '$($cl.Name)'."
            continue
        }
        Write-Step "  Found $($hosts.Count) connected host(s)"

        # -- Reset to default takes priority over set if both are somehow passed --
        if ($ResetProductLocker) {
            Invoke-ResetProductLockerToDefault -Hosts $hosts
            continue
        }

        $targetPath = ""
        $targetDS   = ""
        $doSet      = $false

        if ($SetProductLocker) {
            $ds = Select-Datastore -ClusterName $cl.Name -Prompt "Select ProductLocker datastore"
            if ($ds) {
                $sub = Read-LockerSubPath

                # Resolve datastore UUID from the datastore URL
                # URL format: ds:///vmfs/volumes/<uuid>/
                $dsURL  = $ds.ExtensionData.Info.Url
                $dsUUID = if ($dsURL -match '/vmfs/volumes/([^/]+)') { $Matches[1] } else { $ds.Name }

                $targetPath = "/vmfs/volumes/$dsUUID$sub"
                $targetDS   = $ds.Name
                Write-Info "ProductLocker path : $targetPath"
                $doSet = $true
            }
            else {
                Write-Warn "No datastore selected for '$($cl.Name)' - running audit only."
            }
        }

        $lockerRes = Invoke-ProductLockerAudit -Hosts $hosts -SetValue $doSet -TargetPath $targetPath -DatastoreName $targetDS
        $lockerRes | ForEach-Object {
            $_.PSObject.Properties.Add([psnoteproperty]::new("Cluster", $cl.Name))
        }
        Add-ToList -List $allLockerResults -Items $lockerRes
    }
}

# -- VMTools Audit ------------------------------------------------------------
$allToolsResults = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($auditChoice.RunTools) {
    foreach ($cl in $clusters) {
        $toolsRes = Invoke-VMToolsAudit -ClusterName $cl.Name
        Add-ToList -List $allToolsResults -Items $toolsRes
    }
}

# -- Export -------------------------------------------------------------------
if ($ExportReport) {
    Write-Section "Exporting Reports"
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    if ($allLockerResults.Count -gt 0) {
        $loc = "ProductLocker_${ts}.csv"
        $allLockerResults | Export-Csv -Path $loc -NoTypeInformation -Encoding UTF8
        Write-OK "ProductLocker report : $loc"
    }
    if ($allToolsResults.Count -gt 0) {
        $tool = "VMTools_${ts}.csv"
        $allToolsResults | Export-Csv -Path $tool -NoTypeInformation -Encoding UTF8
        Write-OK "VMTools report       : $tool"
    }
}

# -- Disconnect ---------------------------------------------------------------
Write-Section "Done"
Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
Write-OK "Disconnected from $vCenterServer"
Write-Host ""