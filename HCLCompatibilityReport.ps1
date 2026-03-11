<#
.SYNOPSIS
    HCLCompatibilityReport.ps1
    Collects hardware inventory from ESXi hosts in a vSphere cluster and validates
    each device against the Broadcom Hardware Compatibility Guide (HCL).

.DESCRIPTION
    Connects to vCenter, iterates over all hosts in a specified cluster,
    and gathers:
      - CPU (model, vendor, sockets, cores)
      - NICs (vendor, model, driver, driver version, firmware, PCI IDs)
      - HBAs / Storage Controllers (vendor, model, driver, driver version, firmware, PCI IDs)
      - GPUs (vendor, model, driver, PCI IDs)

    If -TargetESXiVersion is specified, each NIC/HBA/GPU is checked against
    the Broadcom Compatibility Guide (BCG) API. Results include HCL status and
    the required driver/firmware combinations for the target ESXi release.

    Output: per-host CSV + cluster summary CSV + HCL check CSV + HTML report

.PARAMETER vCenterServer
    FQDN or IP of your vCenter Server

.PARAMETER ClusterName
    Name of the vSphere cluster to inventory (leave empty to scan all clusters)

.PARAMETER OutputPath
    Directory to save reports (default: current directory)

.PARAMETER Credential
    PSCredential object for vCenter login (prompted if not provided)

.PARAMETER TargetESXiVersion
    Target ESXi release to validate against on the Broadcom HCL.
    Use the release string as it appears on the HCL, e.g. "ESXi 8.0 U3" or "9.0".
    If omitted, HCL checking is skipped.

.EXAMPLE
    .\HCLCompatibilityReport.ps1 -vCenterServer vcenter.lab.local -ClusterName "Prod-Cluster-01"

.EXAMPLE
    .\HCLCompatibilityReport.ps1 -vCenterServer vcenter.lab.local -TargetESXiVersion "ESXi 8.0 U3" -OutputPath "C:\HCL_Reports"

.NOTES
    Broadcom HCL URL : https://compatibilityguide.broadcom.com/
    BCG API          : Unofficial/undocumented - subject to change without notice.
    Required         : VMware.PowerCLI module (Install-Module VMware.PowerCLI)
    Author           : Paul van Dieen
    Blog             : https://www.hollebollevsan.nl
    Original Idea    : Kabir Ali
    Blog             : https://whatkabirwrites.nl/

.CHANGELOG
    1.0.0 - Initial release. Hardware inventory (CPU, NIC, HBA, GPU) from vCenter.
    1.1.0 - Added Broadcom HCL check via BCG API (apigw.broadcom.com).
    1.2.0 - Fixed BCG API endpoint to use compatibilityguide.broadcom.com/compguide.
            Resolved 0x prefix issue in PCI ID lookups.
            Added driver/firmware detail lookup per device.
            Added dark mode HTML report output.
    1.2.1 - Fixed PowerShell 5 compatibility (inline if expressions).
            Fixed viewDetails endpoint to POST with query string params.
            Added BCG session cookie initialisation for authenticated detail calls.
            Filtered driver/firmware combos to installed driver only.
    1.3.0 - Added CPU HCL check via keyword search against BCG cpu program.
            CPU family extracted from model string and matched against HCL series.
            Fixed CPU series matching by model number prefix (e.g. 6348 -> 6300/5300 Ice-Lake-SP).
            Fixed cpuSeries and supportedReleases field parsing for CPU search response.
            CPU rows rendered separately in HTML report (no PCI IDs / driver columns).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$TargetESXiVersion = ""
)

# -----------------------------------------------------------------------------
# Check PowerCLI is available (it installs as sub-modules, not "VMware.PowerCLI")
# -----------------------------------------------------------------------------
$PowerCLICheck = Get-Module -ListAvailable -Name "VMware.VimAutomation.Core" -ErrorAction SilentlyContinue
if (-not $PowerCLICheck) {
    Write-Error "VMware PowerCLI does not appear to be installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser"
    exit 1
}
Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# Helper: suppress certificate warnings (lab/self-signed environments)
# -----------------------------------------------------------------------------
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null

# -----------------------------------------------------------------------------
# Connect to vCenter
# -----------------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  vSphere HCL Hardware Inventory Tool" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter vCenter credentials for $vCenterServer"
}

try {
    Write-Host "[*] Connecting to vCenter: $vCenterServer ..." -ForegroundColor Yellow
    Connect-VIServer -Server $vCenterServer -Credential $Credential -ErrorAction Stop | Out-Null
    Write-Host "[+] Connected successfully.`n" -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to vCenter: $_"
    exit 1
}

# -----------------------------------------------------------------------------
# Get target hosts
# -----------------------------------------------------------------------------
if ($ClusterName -ne "") {
    Write-Host "[*] Fetching hosts in cluster: $ClusterName" -ForegroundColor Yellow
    try {
        $Cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
        $Hosts = Get-VMHost -Location $Cluster | Sort-Object Name
    } catch {
        Write-Error "Cluster '$ClusterName' not found: $_"
        Disconnect-VIServer -Confirm:$false | Out-Null
        exit 1
    }
} else {
    Write-Host "[*] No cluster specified -- fetching ALL hosts in vCenter" -ForegroundColor Yellow
    $Hosts = Get-VMHost | Sort-Object Name
}

Write-Host "[+] Found $($Hosts.Count) host(s) to inventory.`n" -ForegroundColor Green

# -----------------------------------------------------------------------------
# Ensure output directory exists
# -----------------------------------------------------------------------------
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

$Timestamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$SummaryRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

# -----------------------------------------------------------------------------
# Main loop: iterate over each host
# -----------------------------------------------------------------------------
foreach ($VMHost in $Hosts) {

    Write-Host "-----------------------------------------" -ForegroundColor DarkGray
    Write-Host " Host: $($VMHost.Name)  |  ESXi: $($VMHost.Version) build-$($VMHost.Build)" -ForegroundColor White
    Write-Host " State: $($VMHost.ConnectionState)  |  Model: $($VMHost.Model)" -ForegroundColor Gray
    Write-Host "-----------------------------------------" -ForegroundColor DarkGray

    # Skip hosts that are not connected/accessible
    if ($VMHost.ConnectionState -notin @("Connected", "Maintenance")) {
        Write-Warning "Skipping $($VMHost.Name) -- state is '$($VMHost.ConnectionState)'"
        continue
    }

    $HostRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $EsxCli   = Get-EsxCli -VMHost $VMHost -V2

    # -- Build PCI lookup tables -----------------------------------------------
    # esxcli hardware pci list has VID/DID/SVID/SDID for every device.
    # VMkernelName is populated for HBAs but is often blank for NICs.
    # For NICs we cross-reference via the bus address returned by 'network nic get'.
    $PciByVmkName = @{}   # key = VMKernelName  (vmhba*)
    $PciByAddress = @{}   # key = PCI bus address (0000:xx:xx.x) -- used for NICs
    $AllPciDevices = $null
    try {
        $AllPciDevices = $EsxCli.hardware.pci.list.Invoke()
        foreach ($p in $AllPciDevices) {
            if ($p.VMkernelName -and $p.VMkernelName -ne "") {
                $PciByVmkName[$p.VMkernelName] = $p
            }
            if ($p.Address -and $p.Address -ne "") {
                $PciByAddress[$p.Address] = $p
            }
        }
        Write-Verbose "  PCI table built: $($PciByVmkName.Count) vmk-named, $($PciByAddress.Count) by address"
    } catch {
        Write-Warning "  Could not retrieve PCI device list for $($VMHost.Name): $_"
    }

    # Helper: format a raw integer PCI ID as 0xNNNN hex string
    function Format-PciId($val) {
        if ($null -eq $val) { return "N/A" }
        try { return ("0x{0:X4}" -f [int]$val) } catch { return $val.ToString() }
    }

    # -- 1. CPU ----------------------------------------------------------------
    Write-Host "  [CPU] Collecting CPU info..." -ForegroundColor Yellow
    try {
        $CpuInfo = $VMHost.ExtensionData.Hardware.CpuInfo
        $CpuPkg  = $VMHost.ExtensionData.Hardware.CpuPkg
        $CpuModel = if ($CpuPkg -and $CpuPkg.Count -gt 0) { $CpuPkg[0].Description.Trim() } else { $VMHost.ProcessorType }

        $CpuObj = [PSCustomObject]@{
            HostName         = $VMHost.Name
            ESXiVersion      = $VMHost.Version
            ESXiBuild        = $VMHost.Build
            HardwareCategory = "CPU"
            Vendor           = $VMHost.Manufacturer
            Model            = $CpuModel
            DeviceID         = "N/A"
            SubDeviceID      = "N/A"
            VendorID         = "N/A"
            SubVendorID      = "N/A"
            Driver           = "N/A"
            DriverVersion    = "N/A"
            FirmwareVersion  = "N/A"
            ExtraInfo        = "Sockets:$($CpuInfo.NumCpuPackages) Cores/Socket:$($CpuInfo.NumCpuCores / $CpuInfo.NumCpuPackages) Threads:$($CpuInfo.NumCpuThreads)"
            HCL_URL          = ("https://compatibilityguide.broadcom.com/search?program=server" + [char]38 + "keyword=" + [uri]::EscapeDataString($CpuModel))
        }
        $HostRows.Add($CpuObj)
        Write-Host "       CPU: $CpuModel" -ForegroundColor Green
    } catch {
        Write-Warning "  CPU collection failed for $($VMHost.Name): $_"
    }

    # -- 2. NICs ---------------------------------------------------------------
    Write-Host "  [NIC] Collecting NIC info..." -ForegroundColor Yellow
    try {
        $Nics = $EsxCli.network.nic.list.Invoke()
        foreach ($Nic in $Nics) {
            # Detailed NIC info (firmware version)
            $NicDetail = $null
            try { $NicDetail = $EsxCli.network.nic.get.Invoke(@{ nicname = $Nic.Name }) } catch {}
            $FwVer     = if ($NicDetail -and $NicDetail.DriverInfo.FirmwareVersion) { $NicDetail.DriverInfo.FirmwareVersion } else { "N/A" }
            $NicDrvVer = if ($NicDetail -and $NicDetail.DriverInfo.Version)         { $NicDetail.DriverInfo.Version }         `
                         elseif ($Nic.DriverVersion -and $Nic.DriverVersion -ne "")  { $Nic.DriverVersion }                   `
                         else { "N/A" }

            # PCI IDs -- 'nic get' returns a PCIDevices list with the bus address;
            # cross-reference that address into the full pci list for VID/DID/SVID/SDID.
            $NicPci = $null

            # Path 1: address from esxcli network nic get -> PCIDevices
            if ($NicDetail -and $NicDetail.PCIDevices) {
                $NicBusAddr = ($NicDetail.PCIDevices | Select-Object -First 1).Address
                if ($NicBusAddr) { $NicPci = $PciByAddress[$NicBusAddr] }
            }

            # Path 2: VMkernelName match (works on some ESXi builds)
            if (-not $NicPci) { $NicPci = $PciByVmkName[$Nic.Name] }

            # Path 3: scan all PCI devices for a DeviceName that contains the NIC driver name
            if (-not $NicPci -and $Nic.Driver) {
                $NicPci = $AllPciDevices | Where-Object {
                    $_.ModuleName -eq $Nic.Driver -or $_.DeviceName -like "*$($Nic.Driver)*"
                } | Select-Object -First 1
            }

            $NicVenId   = if ($NicPci) { Format-PciId $NicPci.VendorID    } else { "N/A" }
            $NicDevId   = if ($NicPci) { Format-PciId $NicPci.DeviceID    } else { "N/A" }
            $NicSubVen  = if ($NicPci) { Format-PciId $NicPci.SubVendorID  } else { "N/A" }
            $NicSubDev  = if ($NicPci) { Format-PciId $NicPci.SubDeviceID  } else { "N/A" }
            $NicVendor  = if ($NicPci -and $NicPci.VendorName) { $NicPci.VendorName } else { $Nic.Description.Split(" ")[0] }

            $NicObj = [PSCustomObject]@{
                HostName         = $VMHost.Name
                ESXiVersion      = $VMHost.Version
                ESXiBuild        = $VMHost.Build
                HardwareCategory = "NIC"
                Vendor           = $NicVendor
                Model            = $Nic.Description
                DeviceID         = $NicDevId
                SubDeviceID      = $NicSubDev
                VendorID         = $NicVenId
                SubVendorID      = $NicSubVen
                Driver           = $Nic.Driver
                DriverVersion    = $NicDrvVer
                FirmwareVersion  = $FwVer
                ExtraInfo        = "Interface:$($Nic.Name) PCIAddr:$($NicPci.Address) LinkSpeed:$($Nic.LinkSpeed)Mbps MAC:$($Nic.MACAddress)"
                HCL_URL          = ("https://compatibilityguide.broadcom.com/search?program=io" + [char]38 + "keyword=" + [uri]::EscapeDataString($Nic.Description))
            }
            $HostRows.Add($NicObj)
            Write-Host "       NIC: $($Nic.Name) | $($Nic.Description) | VID:$NicVenId DID:$NicDevId | Driver: $($Nic.Driver) $NicDrvVer | FW: $FwVer" -ForegroundColor Green
            if ($NicVenId -eq "N/A") {
                Write-Verbose "         [diag] NIC $($Nic.Name): NicDetail.PCIDevices=$($NicDetail.PCIDevices | ConvertTo-Json -Compress -Depth 2 -ErrorAction SilentlyContinue)"
            }
        }
    } catch {
        Write-Warning "  NIC collection failed for $($VMHost.Name): $_"
    }

    # -- 3. HBAs / Storage Controllers ----------------------------------------
    Write-Host "  [HBA] Collecting HBA/Storage controller info..." -ForegroundColor Yellow
    try {
        $HbaList = Get-VMHostHba -VMHost $VMHost
        foreach ($Hba in $HbaList) {

            # PCI IDs -- look up by VMkernel name (vmhba0, vmhba1, ...)
            # $Hba.Device is the vmhba name; it appears as VMkernelName in pci list
            $HbaPci = $PciByVmkName[$Hba.Device]

            # Fallback 1: try matching by PCI address from $Hba.PciId
            if (-not $HbaPci -and $Hba.PciId) {
                $HbaPci = $PciByAddress[$Hba.PciId]
            }

            # Fallback 2: exact DeviceName match (most accurate — avoids wrong vendor matches)
            if (-not $HbaPci -and $Hba.Model) {
                $HbaPci = $AllPciDevices | Where-Object {
                    $_.DeviceName -and $_.DeviceName.Trim() -eq $Hba.Model.Trim()
                } | Select-Object -First 1
            }

            # Fallback 3: match by driver module name scoped to devices without a VMkernelName
            if (-not $HbaPci -and $Hba.Driver) {
                $HbaPci = $AllPciDevices | Where-Object {
                    ($_.ModuleName -eq $Hba.Driver) -and (-not $_.VMkernelName -or $_.VMkernelName -eq "")
                } | Select-Object -First 1
            }

            # Fallback 4: partial model match using significant words (3+ chars), longest match first
            if (-not $HbaPci -and $Hba.Model) {
                $modelWords = ($Hba.Model -split '\s+' | Where-Object { $_.Length -gt 3 } | Select-Object -First 4) -join ' '
                if ($modelWords) {
                    $HbaPci = $AllPciDevices | Where-Object {
                        $_.DeviceName -and $_.DeviceName -like "*$modelWords*"
                    } | Select-Object -First 1
                }
            }

            # Fallback 5: last resort — two-word prefix match (avoids single-word false positives)
            if (-not $HbaPci -and $Hba.Model) {
                $twoWords = ($Hba.Model -split '\s+' | Select-Object -First 2) -join ' '
                $HbaPci = $AllPciDevices | Where-Object {
                    $_.DeviceName -and $_.DeviceName -like "*$twoWords*"
                } | Select-Object -First 1
            }

            $HbaVenId  = if ($HbaPci) { Format-PciId $HbaPci.VendorID    } else { "N/A" }
            $HbaDevId  = if ($HbaPci) { Format-PciId $HbaPci.DeviceID    } else { "N/A" }
            $HbaSubVen = if ($HbaPci) { Format-PciId $HbaPci.SubVendorID  } else { "N/A" }
            $HbaSubDev = if ($HbaPci) { Format-PciId $HbaPci.SubDeviceID  } else { "N/A" }
            $HbaVendor = if ($HbaPci -and $HbaPci.VendorName) { $HbaPci.VendorName } else { $Hba.Model.Split(" ")[0] }

            # Firmware version via storage adapter list
            $HbaFw = "N/A"
            try {
                $StorageAdapters = $EsxCli.storage.core.adapter.list.Invoke()
                $MatchedAdapter  = $StorageAdapters | Where-Object { $_.HBAName -eq $Hba.Device }
                if ($MatchedAdapter) { $HbaFw = $MatchedAdapter.UID }
            } catch {}

            # Real driver version via module list -- use $Hba.Driver directly
            $HbaDriverV = "N/A"
            try {
                $HbaMod = $EsxCli.system.module.get.Invoke(@{ module = $Hba.Driver })
                if ($HbaMod) { $HbaDriverV = $HbaMod.Version }
            } catch {
                # Fallback: search loaded modules
                try {
                    $HbaMod = $EsxCli.system.module.list.Invoke() | Where-Object {
                        $_.Name -eq $Hba.Driver -and $_.IsLoaded
                    } | Select-Object -First 1
                    if ($HbaMod) { $HbaDriverV = $HbaMod.Version }
                } catch {}
            }

            $HbaObj = [PSCustomObject]@{
                HostName         = $VMHost.Name
                ESXiVersion      = $VMHost.Version
                ESXiBuild        = $VMHost.Build
                HardwareCategory = "HBA/$($Hba.Type)"
                Vendor           = $HbaVendor
                Model            = $Hba.Model
                DeviceID         = $HbaDevId
                SubDeviceID      = $HbaSubDev
                VendorID         = $HbaVenId
                SubVendorID      = $HbaSubVen
                Driver           = $Hba.Driver
                DriverVersion    = $HbaDriverV
                FirmwareVersion  = $HbaFw
                ExtraInfo        = "Device:$($Hba.Device) PCIAddr:$($HbaPci.Address) Type:$($Hba.Type) Status:$($Hba.Status)"
                HCL_URL          = ("https://compatibilityguide.broadcom.com/search?program=storage" + [char]38 + "keyword=" + [uri]::EscapeDataString($Hba.Model))
            }
            $HostRows.Add($HbaObj)
            Write-Host "       HBA: $($Hba.Device) | $($Hba.Model) | VID:$HbaVenId DID:$HbaDevId | Driver: $($Hba.Driver) $HbaDriverV" -ForegroundColor Green
        }
    } catch {
        Write-Warning "  HBA collection failed for $($VMHost.Name): $_"
    }

    # -- 4. GPUs ---------------------------------------------------------------
    Write-Host "  [GPU] Collecting GPU info..." -ForegroundColor Yellow
    try {
        $GpuList = $VMHost.ExtensionData.Hardware.PciDevice | Where-Object {
            # PCI class 0x03 = Display / GPU
            $_.ClassId -ge 0x0300 -and $_.ClassId -le 0x03FF
        }

        if ($GpuList) {
            foreach ($Gpu in $GpuList) {
                # Try to get driver module info
                $GpuDriverName = "N/A"
                $GpuDriverVer  = "N/A"
                try {
                    $GpuModules = $EsxCli.system.module.list.Invoke() | Where-Object {
                        ($_.Name -match "nvidia|amd|radeon|gpu|vgpu") -and $_.IsLoaded
                    }
                    if ($GpuModules) {
                        $GpuDriverName = ($GpuModules | Select-Object -First 1).Name
                        $GpuDriverVer  = ($GpuModules | Select-Object -First 1).Version
                    }
                } catch {}

                # Format Vendor/Device IDs as HCL-friendly hex
                $VenIdHex = "0x{0:X4}" -f $Gpu.VendorId
                $DevIdHex = "0x{0:X4}" -f $Gpu.DeviceId
                $SubVenHex = "0x{0:X4}" -f $Gpu.SubVendorId
                $SubDevHex = "0x{0:X4}" -f $Gpu.SubDeviceId

                $VendorName = switch ($Gpu.VendorId) {
                    0x10DE { "NVIDIA" }
                    0x1002 { "AMD" }
                    0x8086 { "Intel" }
                    default { "Unknown (VID: $VenIdHex)" }
                }

                $GpuObj = [PSCustomObject]@{
                    HostName         = $VMHost.Name
                    ESXiVersion      = $VMHost.Version
                    ESXiBuild        = $VMHost.Build
                    HardwareCategory = "GPU"
                    Vendor           = $VendorName
                    Model            = $Gpu.DeviceName
                    DeviceID         = $DevIdHex
                    SubDeviceID      = $SubDevHex
                    VendorID         = $VenIdHex
                    SubVendorID      = $SubVenHex
                    Driver           = $GpuDriverName
                    DriverVersion    = $GpuDriverVer
                    FirmwareVersion  = "N/A (use nvidia-smi or vendor tools)"
                    ExtraInfo        = "BusAddress:$($Gpu.Bus):$($Gpu.Slot).$($Gpu.Function) ClassID:0x$("{0:X4}" -f $Gpu.ClassId)"
                    HCL_URL          = ("https://compatibilityguide.broadcom.com/search?program=gpu" + [char]38 + "keyword=" + [uri]::EscapeDataString($Gpu.DeviceName))
                }
                $HostRows.Add($GpuObj)
                Write-Host "       GPU: $($Gpu.DeviceName) | VID: $VenIdHex DID: $DevIdHex | Driver: $GpuDriverName $GpuDriverVer" -ForegroundColor Green
            }
        } else {
            Write-Host "       GPU: No GPU/display devices found on this host." -ForegroundColor Gray
        }
    } catch {
        Write-Warning "  GPU collection failed for $($VMHost.Name): $_"
    }

    # -- Save per-host CSV -----------------------------------------------------
    $SafeHostName = $VMHost.Name -replace '[^a-zA-Z0-9_\-\.]', '_'
    $HostCsvPath  = Join-Path $OutputPath "HCL_${SafeHostName}_${Timestamp}.csv"
    $HostRows | Export-Csv -Path $HostCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n  [+] Host CSV saved: $HostCsvPath" -ForegroundColor Cyan

    # Add to summary
    $SummaryRows.AddRange($HostRows)
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Save cluster-wide summary CSV
# -----------------------------------------------------------------------------
$SummaryCsvPath = Join-Path $OutputPath "HCL_ClusterSummary_${Timestamp}.csv"
$SummaryRows | Export-Csv -Path $SummaryCsvPath -NoTypeInformation -Encoding UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Summary Report: $SummaryCsvPath" -ForegroundColor Cyan
Write-Host " Total devices inventoried: $($SummaryRows.Count)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# HCL Check against Broadcom Compatibility Guide API
# (runs only if -TargetESXiVersion was specified)
#
# Uses the same REST endpoint the BCG portal uses, with headers that match
# a real browser request to avoid gateway rejections.
# One API call per unique VID+DID combination; results cached in-memory.
# -----------------------------------------------------------------------------

# TLS fix for PS 5.x
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# Obtain session cookies from the BCG portal (required for viewDetails API)
Write-Host "[*] Initialising BCG session..." -ForegroundColor Yellow
$BcgSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
try {
    $initParams = @{
        Uri             = "https://compatibilityguide.broadcom.com/"
        Method          = "GET"
        SessionVariable = "BcgSession"
        TimeoutSec      = 30
        ErrorAction     = "Stop"
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $initParams["SkipCertificateCheck"] = $true }
    Invoke-WebRequest @initParams | Out-Null
    Write-Host "[+] BCG session initialised.`n" -ForegroundColor Green
} catch {
    Write-Warning "Could not initialise BCG session: $_. Driver/firmware details may not be available."
}

# Normalise a hex ID string to plain 4-char lowercase (strip 0x, pad)
function Normalize-HexId($h) {
    if ($null -eq $h -or $h -eq "N/A" -or $h -eq "") { return $null }
    $h = ($h -replace '^0x', '').ToLower().TrimStart('0')
    if ($h -eq '') { $h = '0' }
    return $h.PadLeft(4, '0')
}

# Extract a searchable CPU keyword from a full CPU model string
# Returns the tier keyword (e.g. "Xeon Gold", "EPYC") for the initial search
# and the model number for post-search series matching
function Get-CpuSearchKeyword($modelString) {
    if (-not $modelString) { return $null }
    # Strip noise
    $clean = $modelString -replace '\(R\)|\(TM\)|\(tm\)|CPU|@\s*[\d\.]+\s*GHz|[\d]+-Core Processor','
' -replace '\s+',' '
    $clean = $clean.Trim()

    if ($clean -match 'Xeon\s+(Platinum|Gold|Silver|Bronze)') { return "Xeon $($Matches[1])" }
    if ($clean -match 'Xeon\s+W')   { return "Xeon W" }
    if ($clean -match 'Xeon\s+D')   { return "Xeon D" }
    if ($clean -match 'Xeon')       { return "Xeon" }
    if ($clean -match 'EPYC')       { return "EPYC" }
    if ($clean -match 'Core\s+i')   { return "Core" }
    # Fallback - first 2 words
    $words = $clean -split '\s+' | Where-Object { $_ }
    return ($words | Select-Object -First 2) -join ' '
}

# Extract numeric model number from CPU string e.g. "Gold 6348" -> 6348
function Get-CpuModelNumber($modelString) {
    if ($modelString -match '(?:Gold|Platinum|Silver|Bronze|EPYC)\s+(\d{4})') {
        return [int]$Matches[1]
    }
    return $null
}

# Find the best matching CPU series entry from search results
# Matches by checking if the model number falls within the series number range
function Find-BestCpuSeriesMatch($results, $modelNumber, $release) {
    if (-not $modelNumber) { 
        # No model number - just return release-matched entry or first
        if ($release) {
            $m = $results | Where-Object { $_.supportedReleases -contains $release -or ($_.supportedReleases | Where-Object { $_ -like "*$release*" }) } | Select-Object -First 1
            if ($m) { return $m }
        }
        return $results[0]
    }

    # Try to find series whose number range contains our model number
    # e.g. "6300/5300" series matches model 6348 because 6348 starts with 63xx
    $modelPrefix = [string]([int]($modelNumber / 100))  # 6348 -> "63"

    $bestMatch = $results | Where-Object {
        $seriesName = if ($_.cpuSeries -and $_.cpuSeries.Count -gt 0) { $_.cpuSeries[0].name } else { "" }
        # Check if series name contains the prefix number range
        $seriesName -match $modelPrefix
    } | Select-Object -First 1

    if (-not $bestMatch) {
        # Fall back to release match
        if ($release) {
            $bestMatch = $results | Where-Object {
                $_.supportedReleases -contains $release -or ($_.supportedReleases | Where-Object { $_ -like "*$release*" })
            } | Select-Object -First 1
        }
    }
    if (-not $bestMatch) { $bestMatch = $results[0] }
    return $bestMatch
}

function Invoke-BCGCpuQuery {
    param(
        [string]$CpuModel,
        [string]$Release
    )

    $keyword = Get-CpuSearchKeyword $CpuModel
    $modelNum = Get-CpuModelNumber $CpuModel

    if (-not $keyword) {
        return [PSCustomObject]@{ Status = "Skipped"; Details = "Could not determine CPU family"; Releases = "" }
    }

    $payload = [ordered]@{
        programId = "cpu"
        filters   = @()
        keyword   = @($keyword)
        date      = [ordered]@{ startDate = ""; endDate = "" }
    } | ConvertTo-Json -Depth 5 -Compress

    $headers = @{
        "Accept"          = "application/json, text/plain, */*"
        "Accept-Language" = "en-US,en;q=0.9"
        "Origin"          = "https://compatibilityguide.broadcom.com"
        "Referer"         = "https://compatibilityguide.broadcom.com/"
        "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    $searchParams = @{
        Uri         = "https://compatibilityguide.broadcom.com/compguide/programs/viewResults?limit=25&page=1&sortBy=&sortType=ASC"
        Method      = "POST"
        Headers     = $headers
        Body        = $payload
        ContentType = "application/json"
        WebSession  = $BcgSession
        TimeoutSec  = 45
        ErrorAction = "Stop"
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $searchParams["SkipCertificateCheck"] = $true }

    try { $resp = Invoke-BCGRestMethod -Params $searchParams }
    catch { return [PSCustomObject]@{ Status = "Error"; Details = "$_"; Releases = "" } }

    if (-not $resp.success -or -not $resp.data) {
        return [PSCustomObject]@{ Status = "Error"; Details = "Unexpected API response"; Releases = "" }
    }

    $results = $resp.data.fieldValues
    $total   = $resp.data.count

    if ($total -eq 0 -or -not $results) {
        return [PSCustomObject]@{ Status = "Not Found"; Details = "CPU '$keyword' not on HCL"; Releases = "" }
    }

    # Find best matching series entry based on model number
    $bestEntry = Find-BestCpuSeriesMatch -results $results -modelNumber $modelNum -release $Release

    # supportedReleases is a plain string array in the CPU search response
    $allReleases = $bestEntry.supportedReleases | Where-Object { $_ } | Sort-Object -Unique

    $matchedRelease = if ($Release -ne "") {
        $allReleases | Where-Object { $_ -like "*$Release*" }
    } else { $allReleases }

    $statusStr = if ($Release -ne "" -and -not $matchedRelease) { "Not Supported" } else { "Supported" }

    # cpuSeries is an array of objects with .name property
    $seriesName = if ($bestEntry.cpuSeries -and $bestEntry.cpuSeries.Count -gt 0) {
        $bestEntry.cpuSeries[0].name
    } else { $keyword }

    $releasesStr = $allReleases -join "; "

    return [PSCustomObject]@{
        Status   = $statusStr
        Details  = $seriesName
        Releases = $releasesStr
    }
}

function Invoke-BCGRestMethod {
    param($Params)
    $attempt = 0
    do {
        $attempt++
        try {
            return Invoke-RestMethod @Params
        } catch {
            $errMsg = $_.Exception.Message
            if ($attempt -ge 3) { throw $errMsg }
            Write-Verbose "    BCG attempt $attempt failed: $errMsg  Retrying in 3s..."
            Start-Sleep -Seconds 3
        }
    } while ($attempt -lt 3)
}

function Invoke-BCGQuery {
    param(
        [string]$Program,        # "io" (NICs/HBAs), "gpu"
        [string]$VendorId,
        [string]$DeviceId,
        [string]$SubVendorId,
        [string]$SubDeviceId,
        [string]$Release,
        [string]$InstalledDriver # Filter driver/fw combos to only this driver name
    )

    $vid  = Normalize-HexId $VendorId
    $did  = Normalize-HexId $DeviceId
    $svid = Normalize-HexId $SubVendorId
    $sdid = Normalize-HexId $SubDeviceId

    if (-not $vid -or -not $did) {
        return [PSCustomObject]@{ Status = "Skipped"; Details = "Missing VID or DID"; Releases = ""; DriverFirmwareCombos = @() }
    }

    # Build filters using VID+DID only -- SVID is used client-side for bestEntry selection
    # Including SVID in the API call can exclude chip-vendor entries that list the correct drivers
    $filters = @(
        @{ displayKey = "vid"; filterValues = @($vid, $vid) }
        @{ displayKey = "did"; filterValues = @($did, $did) }
    )

    $payload = [ordered]@{
        programId = $Program
        filters   = $filters
        keyword   = @()
        date      = [ordered]@{ startDate = $null; endDate = $null }
    } | ConvertTo-Json -Depth 10 -Compress

    # Headers that match what the BCG portal browser sends
    $headers = @{
        "Accept"          = "application/json, text/plain, */*"
        "Accept-Language" = "en-US,en;q=0.9"
        "Origin"          = "https://compatibilityguide.broadcom.com"
        "Referer"         = "https://compatibilityguide.broadcom.com/"
        "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    $searchParams = @{
        Uri         = "https://compatibilityguide.broadcom.com/compguide/programs/viewResults?limit=25&page=1&sortBy=&sortType=ASC"
        Method      = "POST"
        Headers     = $headers
        Body        = $payload
        ContentType = "application/json"
        WebSession  = $BcgSession
        TimeoutSec  = 45
        ErrorAction = "Stop"
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $searchParams["SkipCertificateCheck"] = $true }

    try { $resp = Invoke-BCGRestMethod -Params $searchParams }
    catch { return [PSCustomObject]@{ Status = "Error"; Details = $_; Releases = ""; DriverFirmwareCombos = @() } }

    if (-not $resp.success -or -not $resp.data) {
        return [PSCustomObject]@{ Status = "Error"; Details = "Unexpected response from HCL API"; Releases = ""; DriverFirmwareCombos = @() }
    }

    $results = $resp.data.fieldValues
    $total   = $resp.data.count

    if ($total -eq 0 -or -not $results) {
        return [PSCustomObject]@{ Status = "Not Found"; Details = "VID:$vid DID:$did not on HCL"; Releases = ""; DriverFirmwareCombos = @() }
    }

    # Narrow by SVID client-side for status/release matching
    # But keep full results available for bestEntry selection (driver/fw lookup)
    $matched = $results
    $svidMatched = $null
    if ($svid) {
        $svidMatched = $results | Where-Object {
            $svidEntry = $_.hoverData | Where-Object { $_.displayName -eq "SVID" }
            $svidEntry -and (Normalize-HexId $svidEntry.value) -eq $svid
        }
        if ($svidMatched) { $matched = $svidMatched }
    }

    # Collect all supported release names across matched entries
    $allReleases = $matched | ForEach-Object {
        $_.supportedReleases | ForEach-Object { $_.name }
    } | Where-Object { $_ } | Sort-Object -Unique

    $matchedRelease = if ($Release -ne "") {
        $allReleases | Where-Object { $_ -like "*$Release*" }
    } else { $allReleases }

    $statusStr = if ($Release -ne "" -and -not $matchedRelease) { "Not Supported" } else { "Supported" }

    # Build details from brand name and model of best matching entry
    $bestEntry = if ($matchedRelease) {
        $matched | Where-Object {
            $_.supportedReleases | Where-Object { $_.name -like "*$Release*" }
        } | Select-Object -First 1
    } else { $matched[0] }

    $details = if ($bestEntry) {
        "$($bestEntry.brandName) - $($bestEntry.model[0].name)"
    } else { "See HCL_URL" }

    # -------------------------------------------------------------------------
    # Fetch driver/firmware combinations for the target release from detail API
    # -------------------------------------------------------------------------
    $driverFirmwareCombos = @()
    if ($statusStr -eq "Supported" -and $bestEntry -and $bestEntry.uuid) {
        $firstRelease = $matchedRelease | Select-Object -First 1
        if ($Release -ne "" -and $firstRelease) { $releaseFilter = [uri]::EscapeDataString($firstRelease) } else { $releaseFilter = "" }
        $detailParams = @{
            Uri         = "https://compatibilityguide.broadcom.com/compguide/programs/viewDetails?programId=$Program&id=$($bestEntry.uuid)&filterBy=$releaseFilter"
            Method      = "POST"
            Headers     = $headers
            Body        = $null
            ContentType = "application/json"
            WebSession  = $BcgSession
            TimeoutSec  = 45
            ErrorAction = "Stop"
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $detailParams["SkipCertificateCheck"] = $true }

        # Try each matched entry until we get driver/fw combos (handles branded cards with no driver data)
        $candidateEntries = @($bestEntry)
        $otherEntries = $matched | Where-Object { $_.uuid -ne $bestEntry.uuid }
        if ($otherEntries) { $candidateEntries += $otherEntries }

        foreach ($candidate in $candidateEntries) {
            if ($driverFirmwareCombos.Count -gt 0) { break }
            $detailParams.Uri = "https://compatibilityguide.broadcom.com/compguide/programs/viewDetails?programId=$Program&id=$($candidate.uuid)&filterBy=$releaseFilter"
            try {
                $detailResp = Invoke-BCGRestMethod -Params $detailParams
                if ($detailResp.success -and $detailResp.data) {
                    $tableSection = $detailResp.data.details | ForEach-Object { $_.subsections } |
                        Where-Object { $_.type -eq "table" -and $_.fieldValues } |
                        Select-Object -First 1

                    if ($tableSection) {
                        $rows = @($tableSection.fieldValues)
                        # Filter to installed driver name if known
                        if ($InstalledDriver -and $InstalledDriver -ne "N/A") {
                            $filtered = @($rows | Where-Object { $_.driverName -eq $InstalledDriver })
                            if ($filtered.Count -gt 0) { $rows = $filtered }
                        }
                        $driverFirmwareCombos = @($rows | ForEach-Object {
                            $fwVer  = if ($_.firmwareVersion)           { $_.firmwareVersion }           else { "N/A" }
                            $addlFw = if ($_.additionalFirmwareVersion) { $_.additionalFirmwareVersion } else { "" }
                            [PSCustomObject]@{
                                Release                   = $_.release
                                DriverName                = $_.driverName
                                DriverVersion             = $_.driverVersion
                                FirmwareVersion           = $fwVer
                                AdditionalFirmwareVersion = $addlFw
                                Type                      = $_.type
                            }
                        })
                    }
                }
            } catch {
                Write-Verbose "  [BCG] Detail API error for uuid $($candidate.uuid): $_"
            }
        }
    }

    return [PSCustomObject]@{
        Status               = $statusStr
        Details              = $details
        Releases             = ($allReleases -join "; ")
        DriverFirmwareCombos = $driverFirmwareCombos
    }
}


if ($TargetESXiVersion -ne "") {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " BCG HCL Check -- Target: $TargetESXiVersion" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Map hardware category to BCG program name
    function Get-BcgProgram($category) {
        if ($category -like "NIC*")   { return "io"  }
        if ($category -like "HBA*")   { return "io"  }
        if ($category -like "GPU*")   { return "gpu" }
        return $null
    }

    $HclResults   = [System.Collections.Generic.List[PSCustomObject]]::new()
    $checked      = 0
    $supported    = 0
    $notFound     = 0
    $notSupported = 0
    $errors       = 0
    $seen         = @{}   # key = "program|vid|did" -- deduplicates across hosts

    foreach ($row in $SummaryRows) {
        # CPU check - uses keyword search against cpu program
        if ($row.HardwareCategory -eq "CPU") {
            $cpuKey = "cpu|$($row.Model)"
            if (-not $seen.ContainsKey($cpuKey)) {
                Write-Host "  [CHK] CPU | $($row.Model)" -ForegroundColor Yellow -NoNewline

                $result = Invoke-BCGCpuQuery -CpuModel $row.Model -Release $TargetESXiVersion
                $seen[$cpuKey] = $result
                $checked++

                $statusColor = switch ($result.Status) {
                    "Supported"     { "Green"  }
                    "Not Supported" { "Red"    }
                    "Not Found"     { "Yellow" }
                    default         { "Gray"   }
                }
                Write-Host "  --> $($result.Status)" -ForegroundColor $statusColor

                switch ($result.Status) {
                    "Supported"     { $supported++ }
                    "Not Supported" { $notSupported++ }
                    "Not Found"     { $notFound++ }
                    "Error"         { $errors++ }
                }
                Start-Sleep -Milliseconds 500
            }

            $cached = $seen[$cpuKey]
            $HclResults.Add([PSCustomObject]@{
                HostName           = $row.HostName
                HardwareCategory   = $row.HardwareCategory
                Vendor             = $row.Vendor
                Model              = $row.Model
                VendorID           = "N/A"
                DeviceID           = "N/A"
                SubVendorID        = "N/A"
                SubDeviceID        = "N/A"
                Driver             = "N/A"
                DriverVersion      = "N/A"
                FirmwareVersion    = "N/A"
                TargetRelease      = $TargetESXiVersion
                HCL_Status         = $cached.Status
                HCL_Details        = $cached.Details
                HCL_Releases       = $cached.Releases
                HCL_DriverFWCombos = ""
                HCL_URL            = $row.HCL_URL
                _DriverFirmwareCombos = @()
            })
            continue
        }
        if ($row.VendorID -eq "N/A" -or $row.DeviceID -eq "N/A") {
            Write-Host "  [SKIP] $($row.HardwareCategory) $($row.Model) -- missing PCI IDs" -ForegroundColor DarkGray
            continue
        }

        $prog = Get-BcgProgram $row.HardwareCategory
        if (-not $prog) { continue }

        # Deduplicate by program+VID+DID -- SVID/SDID handled client-side inside Invoke-BCGQuery
        $dedupeKey = "$prog|$(Normalize-HexId $row.VendorID)|$(Normalize-HexId $row.DeviceID)"

        if (-not $seen.ContainsKey($dedupeKey)) {
            Write-Host "  [CHK] $($row.HardwareCategory) | $($row.Model) | VID:$($row.VendorID) DID:$($row.DeviceID) SVID:$($row.SubVendorID)" -ForegroundColor Yellow -NoNewline

            $result = Invoke-BCGQuery `
                -Program         $prog `
                -VendorId        $row.VendorID `
                -DeviceId        $row.DeviceID `
                -SubVendorId     $row.SubVendorID `
                -SubDeviceId     $row.SubDeviceID `
                -Release         $TargetESXiVersion `
                -InstalledDriver $row.Driver

            $seen[$dedupeKey] = $result
            $checked++

            $statusColor = switch ($result.Status) {
                "Supported"     { "Green"  }
                "Not Supported" { "Red"    }
                "Not Found"     { "Yellow" }
                default         { "Gray"   }
            }
            Write-Host "  --> $($result.Status)" -ForegroundColor $statusColor

            switch ($result.Status) {
                "Supported"     { $supported++ }
                "Not Supported" { $notSupported++ }
                "Not Found"     { $notFound++ }
                "Error"         { $errors++ }
            }

            # Polite delay between unique API calls
            Start-Sleep -Milliseconds 500
        }

        $cached = $seen[$dedupeKey]
        # Flatten driver/firmware combos into a readable string for CSV
        $dfCsv = if ($cached.DriverFirmwareCombos) {
            ($cached.DriverFirmwareCombos | ForEach-Object {
                $addlPart = if ($_.AdditionalFirmwareVersion) { " or $($_.AdditionalFirmwareVersion)" } else { "" }
                "$($_.DriverName) $($_.DriverVersion) / FW:$($_.FirmwareVersion)$addlPart"
            }) -join " | "
        } else { "" }

        $HclResults.Add([PSCustomObject]@{
            HostName           = $row.HostName
            HardwareCategory   = $row.HardwareCategory
            Vendor             = $row.Vendor
            Model              = $row.Model
            VendorID           = $row.VendorID
            DeviceID           = $row.DeviceID
            SubVendorID        = $row.SubVendorID
            SubDeviceID        = $row.SubDeviceID
            Driver             = $row.Driver
            DriverVersion      = $row.DriverVersion
            FirmwareVersion    = $row.FirmwareVersion
            TargetRelease      = $TargetESXiVersion
            HCL_Status         = $cached.Status
            HCL_Details        = $cached.Details
            HCL_Releases       = $cached.Releases
            HCL_DriverFWCombos = $dfCsv
            HCL_URL            = $row.HCL_URL
            # Keep full combos object for HTML (not exported to CSV)
            _DriverFirmwareCombos = @($cached.DriverFirmwareCombos)
        })
    }

    $HclCsvPath = Join-Path $OutputPath "HCL_Check_${TargetESXiVersion -replace '[^a-zA-Z0-9]','_'}_${Timestamp}.csv"
    $HclResults | Select-Object -ExcludeProperty _DriverFirmwareCombos |
        Export-Csv -Path $HclCsvPath -NoTypeInformation -Encoding UTF8

    # -------------------------------------------------------------------------
    # HTML Report - Tab per host, collapsible driver/fw rows
    # -------------------------------------------------------------------------
    $HclHtmlPath = Join-Path $OutputPath "HCL_Check_${TargetESXiVersion -replace '[^a-zA-Z0-9]','_'}_${Timestamp}.html"
    $totalChecked = $checked
    $groupedByHost = $HclResults | Group-Object HostName

    # Build tab buttons and tab content panels
    $tabButtonsHtml = ""
    $tabPanelsHtml  = ""
    $tabIndex = 0

    foreach ($hostGroup in $groupedByHost) {
        $hostName    = $hostGroup.Name
        $safeId      = $hostName -replace '[^a-zA-Z0-9]','-'
        $activeBtn   = if ($tabIndex -eq 0) { " active" } else { "" }
        $activePanel = if ($tabIndex -eq 0) { " active" } else { "" }

        $hostOk   = ($hostGroup.Group | Where-Object { $_.HCL_Status -eq "Supported" }).Count
        $hostFail = ($hostGroup.Group | Where-Object { $_.HCL_Status -eq "Not Supported" }).Count
        $hostWarn = ($hostGroup.Group | Where-Object { $_.HCL_Status -eq "Not Found" }).Count

        $tabBadge = "<span class='tab-ok'>$hostOk</span>"
        if ($hostFail -gt 0) { $tabBadge += " <span class='tab-fail'>$hostFail</span>" }
        if ($hostWarn -gt 0) { $tabBadge += " <span class='tab-warn'>$hostWarn</span>" }

        $tabButtonsHtml += "<button class='tab-btn$activeBtn' onclick='showTab(this,`"$safeId`")'>$hostName $tabBadge</button>`n"

        $rowsHtml = ""
        foreach ($r in $hostGroup.Group) {
            $statusClass = switch ($r.HCL_Status) {
                "Supported"     { "status-ok" }
                "Not Supported" { "status-fail" }
                "Not Found"     { "status-warn" }
                default         { "status-error" }
            }

            if ($r.HardwareCategory -eq "CPU") {
                $rowsHtml += "<tr><td><span class='cat-badge'>CPU</span></td><td>$($r.Vendor)</td><td>$($r.Model)</td><td><span class='pci-id'>$($r.HCL_Details)</span></td><td colspan='2'><span class='version'>$($r.HCL_Releases)</span></td><td><span class='badge $statusClass'>$($r.HCL_Status)</span></td><td><span class='no-data'>-</span></td></tr>`n"
            } else {
                $dfInner = ""
                if ($r._DriverFirmwareCombos -and $r._DriverFirmwareCombos.Count -gt 0) {
                    $dfCount = $r._DriverFirmwareCombos.Count
                    $dfInner = "<div class='df-toggle' onclick='toggleDf(this)'>&#9654; $dfCount combination(s)</div><div class='df-body'><table class='df-table'><thead><tr><th>Driver</th><th>Version</th><th>Firmware</th><th>Type</th></tr></thead><tbody>"
                    foreach ($df in $r._DriverFirmwareCombos) {
                        $fwDisplay = $df.FirmwareVersion
                        if ($df.AdditionalFirmwareVersion) { $fwDisplay += " / $($df.AdditionalFirmwareVersion)" }
                        $dfInner += "<tr><td>$($df.DriverName)</td><td>$($df.DriverVersion)</td><td>$fwDisplay</td><td>$($df.Type)</td></tr>"
                    }
                    $dfInner += "</tbody></table></div>"
                } else {
                    $dfInner = "<span class='no-data'>-</span>"
                }
                $rowsHtml += "<tr><td><span class='cat-badge'>$($r.HardwareCategory)</span></td><td>$($r.Vendor)</td><td>$($r.Model)</td><td><span class='pci-id'>VID:$($r.VendorID) DID:$($r.DeviceID)<br>SVID:$($r.SubVendorID)</span></td><td>$($r.Driver)<br><span class='version'>$($r.DriverVersion)</span></td><td><span class='version'>$($r.FirmwareVersion)</span></td><td><span class='badge $statusClass'>$($r.HCL_Status)</span></td><td>$dfInner</td></tr>`n"
            }
        }

        $tabPanelsHtml += "<div id='tab-$safeId' class='tab-panel$activePanel'><table class='main'><thead><tr><th>Type</th><th>Vendor</th><th>Model</th><th>PCI IDs</th><th>Installed Driver</th><th>Installed FW</th><th>HCL Status</th><th>Required Driver &amp; FW</th></tr></thead><tbody>$rowsHtml</tbody></table></div>`n"
        $tabIndex++
    }

    $htmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>HCL Report - $TargetESXiVersion</title>
<style>
  :root {
    --bg:#0f1117;--surface:#1a1d27;--surface2:#22263a;--surface3:#2a2f45;
    --border:#2e3352;--text:#e2e8f0;--text-muted:#64748b;--text-dim:#94a3b8;
    --ok:#22c55e;--ok-bg:rgba(34,197,94,.12);--ok-border:rgba(34,197,94,.3);
    --fail:#ef4444;--fail-bg:rgba(239,68,68,.12);--fail-border:rgba(239,68,68,.3);
    --warn:#f59e0b;--warn-bg:rgba(245,158,11,.12);--warn-border:rgba(245,158,11,.3);
    --error-bg:rgba(100,116,139,.12);--error-border:rgba(100,116,139,.3);--accent:#3b82f6;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--bg);color:var(--text)}
  header{background:linear-gradient(135deg,#0d1b3e,#1e3a8a);border-bottom:1px solid var(--border);padding:22px 32px}
  header h1{font-size:20px;font-weight:700;color:#fff}
  header p{margin-top:4px;color:#93c5fd;font-size:12px}
  .summary{display:flex;gap:12px;padding:16px 32px;flex-wrap:wrap}
  .card{background:var(--surface);border-radius:8px;padding:14px 20px;flex:1;min-width:110px;border:1px solid var(--border);border-top:3px solid var(--border)}
  .card.ok{border-top-color:var(--ok)}.card.fail{border-top-color:var(--fail)}.card.warn{border-top-color:var(--warn)}
  .card .count{font-size:28px;font-weight:800;line-height:1;color:var(--text-dim)}
  .card.ok .count{color:var(--ok)}.card.fail .count{color:var(--fail)}.card.warn .count{color:var(--warn)}
  .card .label{font-size:11px;color:var(--text-muted);margin-top:3px}
  .tabs{display:flex;gap:2px;padding:0 32px;border-bottom:1px solid var(--border);flex-wrap:wrap;overflow-x:auto}
  .tab-btn{background:transparent;border:none;border-bottom:2px solid transparent;color:var(--text-muted);padding:10px 14px;cursor:pointer;font-size:12px;font-family:inherit;margin-bottom:-1px;transition:all .15s;white-space:nowrap}
  .tab-btn:hover{color:var(--text)}.tab-btn.active{color:var(--accent);border-bottom-color:var(--accent)}
  .tab-ok{background:var(--ok-bg);color:var(--ok);border:1px solid var(--ok-border);border-radius:9999px;padding:1px 5px;font-size:10px;font-weight:700}
  .tab-fail{background:var(--fail-bg);color:var(--fail);border:1px solid var(--fail-border);border-radius:9999px;padding:1px 5px;font-size:10px;font-weight:700}
  .tab-warn{background:var(--warn-bg);color:var(--warn);border:1px solid var(--warn-border);border-radius:9999px;padding:1px 5px;font-size:10px;font-weight:700}
  .tab-panel{display:none;padding:16px 32px 32px}.tab-panel.active{display:block}
  table.main{width:100%;border-collapse:collapse;background:var(--surface);border-radius:8px;overflow:hidden;border:1px solid var(--border)}
  table.main thead tr{background:var(--surface3)}
  table.main thead th{padding:9px 11px;text-align:left;font-size:10px;color:var(--text-dim);font-weight:600;text-transform:uppercase;letter-spacing:.06em;white-space:nowrap;border-bottom:1px solid var(--border)}
  table.main tbody tr{border-bottom:1px solid var(--border);transition:background .1s}
  table.main tbody tr:hover{background:var(--surface2)}
  table.main tbody td{padding:8px 11px;font-size:12px;vertical-align:top;color:var(--text)}
  .cat-badge{display:inline-block;background:var(--surface3);color:var(--text-dim);border:1px solid var(--border);border-radius:4px;padding:1px 5px;font-size:9px;font-weight:700;text-transform:uppercase;white-space:nowrap}
  .pci-id{font-family:'Courier New',monospace;font-size:10px;color:var(--text-muted)}
  .version{font-size:10px;color:var(--text-muted)}
  .badge{display:inline-block;padding:2px 8px;border-radius:9999px;font-size:11px;font-weight:600;white-space:nowrap}
  .status-ok{background:var(--ok-bg);color:var(--ok);border:1px solid var(--ok-border)}
  .status-fail{background:var(--fail-bg);color:var(--fail);border:1px solid var(--fail-border)}
  .status-warn{background:var(--warn-bg);color:var(--warn);border:1px solid var(--warn-border)}
  .status-error{background:var(--error-bg);color:var(--text-muted);border:1px solid var(--error-border)}
  .df-toggle{cursor:pointer;font-size:11px;color:var(--accent);user-select:none;padding:2px 0}
  .df-toggle:hover{text-decoration:underline}
  .df-body{display:none;margin-top:6px}
  table.df-table{width:100%;border-collapse:collapse;border-radius:4px;overflow:hidden;border:1px solid var(--border)}
  table.df-table th{background:var(--surface3);font-size:9px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--text-dim);padding:4px 7px;text-align:left;border-bottom:1px solid var(--border)}
  table.df-table td{font-size:10px;padding:4px 7px;border-top:1px solid var(--border);font-family:'Courier New',monospace;color:#a5b4fc}
  table.df-table tr:hover td{background:var(--surface3)}
  .no-data{color:var(--text-muted);font-size:11px}
  footer{text-align:center;padding:14px;font-size:11px;color:var(--text-muted);border-top:1px solid var(--border)}
  footer a{color:var(--accent);text-decoration:none}
</style>
</head>
<body>
<header>
  <h1>vSphere HCL Compatibility Report</h1>
  <p>Target: <strong>$TargetESXiVersion</strong> &bull; Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm") &bull; Cluster: $ClusterName</p>
</header>
<div class="summary">
  <div class="card"><div class="count">$totalChecked</div><div class="label">Devices Checked</div></div>
  <div class="card ok"><div class="count">$supported</div><div class="label">Supported</div></div>
  <div class="card fail"><div class="count">$notSupported</div><div class="label">Not Supported</div></div>
  <div class="card warn"><div class="count">$notFound</div><div class="label">Not Found</div></div>
  <div class="card"><div class="count">$errors</div><div class="label">Errors</div></div>
</div>
<div class="tabs">
$tabButtonsHtml</div>
$tabPanelsHtml
<footer>Broadcom HCL &bull; <a href="https://compatibilityguide.broadcom.com">compatibilityguide.broadcom.com</a></footer>
<script>
function showTab(btn,id){
  document.querySelectorAll('.tab-panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
  document.getElementById('tab-'+id).classList.add('active');
  btn.classList.add('active');
}
function toggleDf(el){
  var b=el.nextElementSibling;
  var open=b.style.display==='block';
  b.style.display=open?'none':'block';
  el.innerHTML=(open?'&#9654;':'&#9660;')+el.innerHTML.substring(1);
}
</script>
</body>
</html>
"@
    $htmlReport | Out-File -FilePath $HclHtmlPath -Encoding UTF8

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " HCL Check Summary" -ForegroundColor Cyan
    Write-Host "   Unique devices checked : $checked" -ForegroundColor White
    Write-Host "   Supported              : $supported" -ForegroundColor Green
    Write-Host "   Not Supported          : $notSupported" -ForegroundColor Red
    Write-Host "   Not Found in HCL       : $notFound" -ForegroundColor Yellow
    Write-Host "   Errors                 : $errors" -ForegroundColor Gray
    Write-Host " CSV saved  : $HclCsvPath" -ForegroundColor Cyan
    Write-Host " HTML saved : $HclHtmlPath" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}


Write-Host "HOW TO CHECK BROADCOM HCL:" -ForegroundColor Yellow
Write-Host "-----------------------------------------------------------------"
Write-Host "  HCL Portal:   https://compatibilityguide.broadcom.com/"
Write-Host "  Server HCL:   https://compatibilityguide.broadcom.com/search?program=server"
Write-Host "  I/O NIC HCL:  https://compatibilityguide.broadcom.com/search?program=io"
Write-Host "  Storage HCL:  https://compatibilityguide.broadcom.com/search?program=storage"
Write-Host "  GPU HCL:      https://compatibilityguide.broadcom.com/search?program=gpu"
Write-Host ""
Write-Host "  For each device, search using:"
Write-Host "    - Vendor + Model name"
Write-Host "    - VendorID + DeviceID (most accurate for NICs/HBAs/GPUs)"
Write-Host "    - ESXi version you are targeting"
Write-Host "  The HCL will show: required driver name, driver version, and firmware version."
Write-Host "-----------------------------------------------------------------`n"

# -----------------------------------------------------------------------------
# Disconnect
# -----------------------------------------------------------------------------
Disconnect-VIServer -Server $vCenterServer -Confirm:$false
Write-Host "[*] Disconnected from vCenter. Done!`n" -ForegroundColor Gray
