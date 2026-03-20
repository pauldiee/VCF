#requires -Version 5.1

<#
.SYNOPSIS
    Retrieves and decrypts stored passwords from VMware Cloud Foundation (VCF) Fleet Manager.
.DESCRIPTION
    This script authenticates to a VCF Fleet Manager instance, retrieves password metadata,
    and decrypts each password using the provided root password. Designed for home lab use.
.NOTES
    Author: Kabir Ali - info@whatkabirwrites.nl
    Date: February 2026
    Environment: Trusted home lab – SSL validation bypassed.
#>

#region Parameters
Param (
    [Parameter(Mandatory = $true)][string]$VcfFqdn,
    [Parameter(Mandatory = $true)][string]$Username,
    [Parameter(Mandatory = $true)][string]$Password,
    [Parameter(Mandatory = $true)][string]$RootPassword
)
#endregion

#region SSL Bypass (Home Lab Only!)
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#endregion


#region Configuration
$Config = @{
    VcfFqdn      = $VcfFqdn
    Username     = $Username
    Password     = $Password
    RootPassword = $RootPassword
}
#endregion

#region Helper Functions

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $ColorMap = @{ Info = 'White'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$Timestamp] [$Level] $Message" -ForegroundColor $ColorMap[$Level]
}

function Get-VcfAuthToken {
    param(
        [string]$VcfFqdn,
        [string]$Username,
        [string]$Password
    )
    try {
        $pair = "$($Username):$($Password)"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
        $headers = @{
            "Accept"        = "application/json"
            "Authorization" = "Basic $encoded"
            "Content-Type"   = "application/json"
        }

        $authUrl = "https://$VcfFqdn/lcm/authzn/api/login"
        $response = Invoke-RestMethod -Method POST -Uri $authUrl -Headers $headers -Body "" -ErrorAction Stop

        if ($response -eq "Login succeessfully") {  # Note: VCF has typo
            Write-Log "Authentication successful." -Level Success
            return $headers
        } else {
            throw "Unexpected authentication response: $response"
        }
    } catch {
        Write-Log "Authentication failed: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Get-VcfPasswordMetadata {
    param(
        [string]$VcfFqdn,
        [hashtable]$AuthHeaders
    )
    try {
        $url = "https://$VcfFqdn/lcm/locker/api/passwords"
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers $AuthHeaders -ErrorAction Stop
        Write-Log "Retrieved $($response.Count) password entries." -Level Info
        return $response
    } catch {
        Write-Log "Failed to retrieve password metadata: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Decrypt-VcfPassword {
    param(
        [string]$VcfFqdn,
        [hashtable]$AuthHeaders,
        [string]$PasswordId,
        [string]$RootPassword
    )
    try {
        $url = "https://$VcfFqdn/lcm/locker/api/v2/passwords/$PasswordId/decrypted"
        # Use exact string format as in original working script
        $body = ' { "rootPassword": "VMware123!VMware123!" } '
        $response = Invoke-RestMethod -Method POST -Uri $url -Headers $AuthHeaders -Body $body -ErrorAction Stop
        return $response
    } catch {
        Write-Log "Failed to decrypt password ID '$PasswordId': $($_.Exception.Message)" -Level Warning
        return $null
    }
}

#endregion

#region Main Execution

try {
    Write-Log "Starting VCF Fleet Manager password extraction..." -Level Info

    # Authenticate
    $authHeaders = Get-VcfAuthToken -VcfFqdn $Config.VcfFqdn -Username $Config.Username -Password $Config.Password

    # Fetch password metadata
    $passwordMetadata = Get-VcfPasswordMetadata -VcfFqdn $Config.VcfFqdn -AuthHeaders $authHeaders

    if (-not $passwordMetadata -or $passwordMetadata.Count -eq 0) {
        Write-Log "No passwords found in locker." -Level Warning
        exit
    }

    # Decrypt each password
    $decryptedPasswords = @()
    foreach ($entry in $passwordMetadata) {
        Write-Log "Decrypting password: $($entry.Alias) (ID: $($entry.vmid))" -Level Info
        $plainText = Decrypt-VcfPassword -VcfFqdn $Config.VcfFqdn -AuthHeaders $authHeaders `
                                        -PasswordId $entry.vmid -RootPassword $Config.RootPassword
        if ($plainText) {
            $decryptedPasswords += [PSCustomObject]@{
                Name     = $entry.Alias
                Tenant   = $entry.tenant
                Password = $plainText.password
                Id       = $entry.vmid
            }
        }
    }

    # Final Reporting
    Write-Log "Extraction complete. Found $($decryptedPasswords.Count) decrypted passwords." -Level Success

    if ($decryptedPasswords.Count -gt 0) {
        Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
        Write-Host "DECRYPTED PASSWORDS REPORT" -ForegroundColor Cyan
        Write-Host ("=" * 60) -ForegroundColor Cyan
        $decryptedPasswords | Format-Table -Property Name, Id, Tenant, Password -AutoSize
    } else {
        Write-Log "No passwords were successfully decrypted." -Level Warning
    }

} catch {
    Write-Log "Script terminated due to error: $($_.Exception.Message)" -Level Error
    exit 1
}
