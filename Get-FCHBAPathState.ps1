<#
.SYNOPSIS
    Get-FCHBAPathState — Reports Fibre Channel HBA path states across all connected ESXi hosts.

.DESCRIPTION
    Connects to a user-specified vCenter server and audits all Fibre Channel HBAs on every
    connected ESXi host. Auto-detects HBAs per host by default; optionally filter to specific
    devices via -HBAFilter. Reports Active, Dead, and Standby path counts per HBA.
    Supports credential save/load, optional HBA rescan, and CSV export.

.PARAMETER HBAFilter
    Optional. Comma-separated list of HBA device names to check (e.g. "vmhba4,vmhba5").
    If omitted, ALL Fibre Channel HBAs on each host are checked automatically.
    Can also be passed at runtime when prompted.

.PARAMETER ExportPath
    Optional. Full path to export results as a CSV file.
    Example: -ExportPath "C:\Reports\FCHBAPathState.csv"

.PARAMETER Rescan
    Optional switch. If specified, triggers a rescan of all HBAs before collecting data.

.EXAMPLE
    .\Get-FCHBAPathState.ps1
    .\Get-FCHBAPathState.ps1 -HBAFilter "vmhba4,vmhba5"
    .\Get-FCHBAPathState.ps1 -ExportPath "C:\Reports\FCHBAPathState.csv" -Rescan

.NOTES
    Author  : Paul van Dieen
    Blog    : https://www.hollebollevsan.nl
    Version : 2.4  (2026-03-06) — Output split into per-cluster tables with individual
                                   cluster summaries and an overall total summary.
              2.3  (2026-03-06) — Colored output table with dynamic column widths,
                                   per-row health coloring, summary line, and legend.
              2.2  (2026-03-06) — Replaced #Requires with runtime PowerCLI check for
                                   compatibility with PowerCLI 13.x module structure.
              2.1  (2026-03-06) — Auto-detect all FC HBAs; added -HBAFilter parameter
                                   and interactive filter prompt at runtime.
              2.0  (2026-03-06) — Rewrite: vCenter prompt, credential save/load,
                                   PSCustomObject collection, dead-path alerting,
                                   error handling, CSV export, -Rescan switch.
              1.0  (initial)    — Original: hardcoded vCenter, basic FC path check.
#>
param(
    [string]$HBAFilter  = "",
    [string]$ExportPath = "",
    [switch]$Rescan
)

# ─────────────────────────────────────────────
#  POWERCLI VERSION CHECK
# ─────────────────────────────────────────────
$powercli = Get-Module -ListAvailable -Name VMware.VimAutomation.Core | Sort-Object Version -Descending | Select-Object -First 1
if (-not $powercli) {
    Write-Error "VMware PowerCLI does not appear to be installed. Please install it with: Install-Module VMware.PowerCLI"
    exit 1
}
Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue

# ─────────────────────────────────────────────
#  CREDENTIAL STORE HELPERS
# ─────────────────────────────────────────────
$credStorePath = "$env:USERPROFILE\.vcenter_creds"

function Save-VCenterCredential {
    param([PSCredential]$Credential)
    $export = [PSCustomObject]@{
        Username = $Credential.UserName
        Password = $Credential.Password | ConvertFrom-SecureString
    }
    $export | Export-Clixml -Path $credStorePath
    Write-Host "  Credentials saved to $credStorePath" -ForegroundColor DarkGray
}

function Load-VCenterCredential {
    if (Test-Path $credStorePath) {
        try {
            $import = Import-Clixml -Path $credStorePath
            $securePass = $import.Password | ConvertTo-SecureString
            return New-Object System.Management.Automation.PSCredential($import.Username, $securePass)
        } catch {
            Write-Warning "Saved credentials could not be loaded. You will be prompted."
            return $null
        }
    }
    return $null
}

# ─────────────────────────────────────────────
#  VCENTER SERVER PROMPT
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Get-FCHBAPathState  v2.4              ║" -ForegroundColor Cyan
Write-Host "║     Paul van Dieen - hollebollevsan.nl    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$vCenter = Read-Host "  Enter vCenter FQDN or IP"
if ([string]::IsNullOrWhiteSpace($vCenter)) {
    Write-Error "No vCenter specified. Exiting."
    exit 1
}

# ─────────────────────────────────────────────
#  CREDENTIAL HANDLING
# ─────────────────────────────────────────────
$savedCred = Load-VCenterCredential

if ($savedCred) {
    Write-Host ""
    Write-Host "  Found saved credentials for: " -NoNewline
    Write-Host $savedCred.UserName -ForegroundColor Yellow
    $useSaved = Read-Host "  Use saved credentials? (Y/N) [Y]"

    if ($useSaved -eq "" -or $useSaved -match "^[Yy]") {
        $cred = $savedCred
        Write-Host "  Using saved credentials." -ForegroundColor Green
    } else {
        $cred = Get-Credential -Message "Enter vCenter credentials for $vCenter"
        $saveNew = Read-Host "  Save these credentials for next time? (Y/N) [N]"
        if ($saveNew -match "^[Yy]") { Save-VCenterCredential -Credential $cred }
    }
} else {
    Write-Host ""
    $cred = Get-Credential -Message "Enter vCenter credentials for $vCenter"
    $saveNew = Read-Host "  Save these credentials for next time? (Y/N) [N]"
    if ($saveNew -match "^[Yy]") { Save-VCenterCredential -Credential $cred }
}

# ─────────────────────────────────────────────
#  CONNECT TO VCENTER
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "  Connecting to $vCenter ..." -ForegroundColor Cyan

try {
    Connect-VIServer -Server $vCenter -Credential $cred -ErrorAction Stop | Out-Null
    Write-Host "  Connected successfully." -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to $vCenter : $_"
    exit 1
}

# ─────────────────────────────────────────────
#  MAIN LOGIC
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "  Gathering ESXi hosts..." -ForegroundColor Cyan

$VMHosts = Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" } | Sort-Object Name

if (-not $VMHosts) {
    Write-Warning "No connected hosts found. Disconnecting."
    Disconnect-VIServer * -Confirm:$false
    exit 0
}

Write-Host "  Found $($VMHosts.Count) connected host(s). Checking HBAs...`n" -ForegroundColor Cyan

# ─────────────────────────────────────────────
#  HBA FILTER — auto-detect, then optionally narrow
# ─────────────────────────────────────────────

# Collect all unique FC HBA device names across all hosts
$allFCHBAs = $VMHosts | Get-VMHostHba -Type FibreChannel |
             Select-Object -ExpandProperty Device -Unique | Sort-Object

if (-not $allFCHBAs) {
    Write-Warning "No Fibre Channel HBAs found on any connected host. Disconnecting."
    Disconnect-VIServer * -Confirm:$false
    exit 0
}

Write-Host "  Fibre Channel HBAs detected in this environment:" -ForegroundColor Cyan
$allFCHBAs | ForEach-Object { Write-Host "    - $_" -ForegroundColor White }
Write-Host ""

# If -HBAFilter was not passed as a parameter, prompt interactively
if ([string]::IsNullOrWhiteSpace($HBAFilter)) {
    $filterInput = Read-Host "  Filter to specific HBAs? (comma-separated, e.g. vmhba4,vmhba5) [Leave blank for ALL]"
    $HBAFilter = $filterInput.Trim()
}

# Build the final list of HBAs to check
if ([string]::IsNullOrWhiteSpace($HBAFilter)) {
    $HBASelection = $allFCHBAs
    Write-Host "  Checking ALL $($HBASelection.Count) FC HBA(s)." -ForegroundColor Green
} else {
    $HBASelection = $HBAFilter -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    # Warn about any requested HBAs not found in the environment
    $notFound = $HBASelection | Where-Object { $_ -notin $allFCHBAs }
    if ($notFound) {
        Write-Warning "  The following HBAs were not detected in this environment: $($notFound -join ', ')"
    }
    $HBASelection = $HBASelection | Where-Object { $_ -in $allFCHBAs }
    if (-not $HBASelection) {
        Write-Error "  No valid HBAs remain after filtering. Exiting."
        Disconnect-VIServer * -Confirm:$false
        exit 1
    }
    Write-Host "  Checking HBA(s): $($HBASelection -join ', ')" -ForegroundColor Green
}
Write-Host ""

$results = [System.Collections.Generic.List[PSObject]]::new()

foreach ($VMHost in $VMHosts) {

    if ($Rescan) {
        Write-Host "  [$($VMHost.Name)] Rescanning HBAs..." -ForegroundColor DarkGray
        Get-VMHostStorage -RescanAllHba -VMHost $VMHost | Out-Null
    }

    $HBAs = $VMHost | Get-VMHostHba -Type FibreChannel |
            Where-Object { $_.Device -in $HBASelection }

    if (-not $HBAs) {
        Write-Host "  [$($VMHost.Name)] No matching HBAs found — skipping." -ForegroundColor DarkYellow
        continue
    }

    foreach ($HBA in $HBAs) {
        try {
            $pathGroups = $HBA | Get-ScsiLun | Get-ScsiLunPath | Group-Object -Property State

            $active  = [int]($pathGroups | Where-Object Name -eq "Active"  | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue)
            $dead    = [int]($pathGroups | Where-Object Name -eq "Dead"    | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue)
            $standby = [int]($pathGroups | Where-Object Name -eq "Standby" | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue)

            $results.Add([PSCustomObject]@{
                VMHost  = $VMHost.Name
                HBA     = $HBA.Device
                Cluster = [string]$VMHost.Parent
                Active  = $active
                Dead    = $dead
                Standby = $standby
            })

        } catch {
            Write-Warning "  [$($VMHost.Name)][$($HBA.Device)] Error reading paths: $_"
        }
    }
}

# ─────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────
Write-Host ""

if ($results.Count -eq 0) {
    Write-Warning "No results collected."
} else {

    # ── Dynamic column widths (global, so all cluster tables align) ──
    $w_host    = [Math]::Max(6,  ($results | ForEach-Object { $_.VMHost.Length } | Measure-Object -Maximum).Maximum)
    $w_hba     = [Math]::Max(3,  ($results | ForEach-Object { $_.HBA.Length   } | Measure-Object -Maximum).Maximum)
    $w_active  = 6
    $w_dead    = 4
    $w_standby = 7

    # ── Border / header helpers (no Cluster column — grouped by cluster instead) ──
    $div = "  +" + ("-" * ($w_host    + 2)) + "+" +
                   ("-" * ($w_hba     + 2)) + "+" +
                   ("-" * ($w_active  + 2)) + "+" +
                   ("-" * ($w_dead    + 2)) + "+" +
                   ("-" * ($w_standby + 2)) + "+"

    $header = "  | " + "VMHost".PadRight($w_host)    + " | " +
                        "HBA".PadRight($w_hba)         + " | " +
                        "Active".PadRight($w_active)   + " | " +
                        "Dead".PadRight($w_dead)       + " | " +
                        "Standby".PadRight($w_standby) + " |"

    # ── Group results by cluster and print one table per cluster ──
    $clusters = $results | Select-Object -ExpandProperty Cluster -Unique | Sort-Object

    foreach ($cluster in $clusters) {
        $clusterRows = $results | Where-Object { $_.Cluster -eq $cluster } | Sort-Object VMHost, HBA

        # Cluster header banner
        $clusterLabel = "  Cluster: $cluster"
        Write-Host ""
        Write-Host $clusterLabel -ForegroundColor Magenta

        Write-Host $div    -ForegroundColor DarkGray
        Write-Host $header -ForegroundColor Cyan
        Write-Host $div    -ForegroundColor DarkGray

        foreach ($row in $clusterRows) {
            $line = "  | " + $row.VMHost.PadRight($w_host)               + " | " +
                              $row.HBA.PadRight($w_hba)                   + " | " +
                              ([string]$row.Active).PadRight($w_active)   + " | " +
                              ([string]$row.Dead).PadRight($w_dead)       + " | " +
                              ([string]$row.Standby).PadRight($w_standby) + " |"

            if ($row.Dead -gt 0) {
                Write-Host $line -ForegroundColor Red
            } elseif ($row.Standby -gt 0 -and $row.Active -eq 0) {
                Write-Host $line -ForegroundColor Yellow
            } elseif ($row.Active -gt 0) {
                Write-Host $line -ForegroundColor Green
            } else {
                Write-Host $line -ForegroundColor DarkYellow
            }
        }

        Write-Host $div -ForegroundColor DarkGray

        # Per-cluster summary
        $clusterDead = ($clusterRows | Where-Object { $_.Dead -gt 0 }).Count
        if ($clusterDead -gt 0) {
            Write-Host ("  [!] {0} HBA(s) with dead paths in this cluster." -f $clusterDead) -ForegroundColor Red
        } else {
            Write-Host "  [OK] All HBAs healthy in this cluster." -ForegroundColor Green
        }
    }

    Write-Host ""

    # ── Overall summary ────────────────────────
    $totalDead = ($results | Where-Object { $_.Dead -gt 0 }).Count
    if ($totalDead -gt 0) {
        Write-Host ("  [!!] TOTAL: {0} HBA(s) across all clusters have dead paths." -f $totalDead) -ForegroundColor Red
    } else {
        Write-Host "  [OK] All HBAs across all clusters reporting healthy paths." -ForegroundColor Green
    }
    Write-Host ""

    # ── Legend ─────────────────────────────────
    Write-Host "  Legend: " -NoNewline
    Write-Host "Green" -ForegroundColor Green   -NoNewline; Write-Host " = Active paths OK   " -NoNewline
    Write-Host "Yellow" -ForegroundColor Yellow -NoNewline; Write-Host " = Standby only   " -NoNewline
    Write-Host "Red" -ForegroundColor Red       -NoNewline; Write-Host " = Dead paths detected"
    Write-Host ""

    if ($ExportPath -ne "") {
        try {
            $results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
            Write-Host "  Results exported to: $ExportPath" -ForegroundColor Green
        } catch {
            Write-Warning "  Export failed: $_"
        }
    }
}

# ─────────────────────────────────────────────
#  DISCONNECT
# ─────────────────────────────────────────────
Disconnect-VIServer * -Confirm:$false
Write-Host ""
Write-Host "  Disconnected from $vCenter." -ForegroundColor DarkGray
Write-Host ""
