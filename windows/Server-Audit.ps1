<#
.SYNOPSIS
    READ-ONLY configuration audit of the Windows Server file-server VM (Proxmox guest).
.DESCRIPTION
    Collects OS/role, VBS, virtual hardware and VirtIO drivers, disks/NTFS settings,
    SMB server and share settings, antivirus/EDR, shadow copies/backup agents and recent
    storage/SMB event-log errors, then prints a list of findings (WARN / INFO).
    Makes NO changes.
.PARAMETER DataPath
    Optional. Local folder that holds the CaseWare / TaxCycle data (e.g. D:\Shares\Data).
    Enables a file/folder census: counts, biggest folders, extensions, local enumeration speed.
.PARAMETER EventDays
    Days of event logs to scan (default 7).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Server-Audit.ps1 -DataPath D:\Shares\Data
#>
[CmdletBinding()]
param(
    [string]$DataPath,
    [int]$EventDays = 7,
    [int]$CensusMaxFiles = 300000,
    [string]$OutDir = (Join-Path $PSScriptRoot 'results')
)

$ErrorActionPreference = 'Continue'
$kitLib = Join-Path $PSScriptRoot 'lib\KitCommon.ps1'
if (-not (Test-Path -LiteralPath $kitLib)) { Write-Host "ERROR: $kitLib is missing - copy the whole 'windows' folder of the kit, not single scripts." -ForegroundColor Red; exit 2 }
. $kitLib
Initialize-KitLog 'Server-Audit' $OutDir $PSBoundParameters
Assert-KitAdmin
$ts = $script:KitStamp
$report = $script:KitLog
Start-Transcript -Path $report | Out-Null
# any unexpected error: log it with a hint and continue with the next step (read-only audit)
trap { Write-KitError "Step failed: $($_.Exception.Message)" '' $_; continue }
try {

# ------------------------------------------------------------------ SYSTEM
Section 'SYSTEM'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$roles = @{ 0 = 'Standalone workstation'; 1 = 'Member workstation'; 2 = 'Standalone server'; 3 = 'Member server'; 4 = 'Backup domain controller'; 5 = 'Primary domain controller' }
Write-Host ("{0} {1} (build {2}.{3})" -f $os.Caption, $cv.DisplayVersion, $os.BuildNumber, $cv.UBR)
Write-Host ("Uptime: {0:N1} days   Domain: {1}   Role: {2}" -f ((Get-Date) - $os.LastBootUpTime).TotalDays, $cs.Domain, $roles[[int]$cs.DomainRole])
Write-Host ("Hardware: {0} {1}   Hypervisor present: {2}" -f $cs.Manufacturer, $cs.Model, $cs.HypervisorPresent)
Write-KitFact os_build ("{0}.{1}" -f $os.BuildNumber, $cv.UBR); Write-KitFact domain_role $roles[[int]$cs.DomainRole]
Write-KitFact is_dc ([int]$cs.DomainRole -ge 4); Write-KitFact server_name $env:COMPUTERNAME; Write-KitFact domain $cs.Domain
if ([int]$cs.DomainRole -ge 4) {
    Add-Finding 'WARN' 'This file server is also a Domain Controller. DCs require SMB signing on every inbound connection (Default Domain Controllers Policy) and AD disables write caching on the disk holding its database (matters if shares live on that virtual disk). A separate member-server VM for the shares avoids both; trade-off: one more Windows license/VM to maintain.'
}
Write-Host 'Last updates:'
Show (Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 3 HotFixID, Description, InstalledOn)
$pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pendingReboot) { Add-Finding 'INFO' 'A reboot is pending (Windows Update / servicing). Reboot before benchmarking.' }

# ------------------------------------------------------------------ CPU / RAM
Section 'CPU AND MEMORY'
$cpus = @(Get-CimInstance Win32_Processor)
$logical = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
Write-Host ("CPU: {0}   sockets: {1}   logical processors: {2}   {3} MHz" -f $cpus[0].Name.Trim(), $cpus.Count, $logical, $cpus[0].MaxClockSpeed)
$aesType = 'System.Runtime.Intrinsics.X86.Aes' -as [type]
if ($aesType) {
    $aes = $aesType::IsSupported
    Write-Host "AES-NI visible to this VM: $aes"
    Write-KitFact aes_ni $aes
    if (-not $aes) { Add-Finding 'WARN' 'AES-NI is NOT exposed to this VM (Proxmox CPU type kvm64/qemu64?). SMB signing/encryption and BitLocker fall back to slow software crypto. Set the VM CPU type to x86-64-v3 (or x86-64-v2-AES).' }
} else {
    Write-Host 'AES-NI visible to this VM: unknown in Windows PowerShell 5.1 (run this script in PowerShell 7 to test, or check the CPU type in pve-audit.sh)'
}
$totGB = $cs.TotalPhysicalMemory / 1GB
$freeGB = $os.FreePhysicalMemory * 1KB / 1GB
Write-Host ("RAM: {0:N1} GB total, {1:N1} GB free" -f $totGB, $freeGB)
Write-KitFact vcpus $logical; Write-KitFact ram_gb ([math]::Round($totGB, 1)); Write-KitFact cpu_name $cpus[0].Name.Trim()
if ($logical -lt 4) { Add-Finding 'INFO' "Only $logical vCPUs: SMB signing, Defender scanning and many simultaneous client requests all compete for CPU." }
if ($totGB -lt 12) { Add-Finding 'INFO' ("Only {0:N0} GB RAM: the Windows file cache that keeps hot CaseWare/TaxCycle files in memory is limited by this." -f $totGB) }

# ------------------------------------------------------------------ VBS
Section 'VIRTUALIZATION-BASED SECURITY (VBS)'
try {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    $vbsNames = @{ 0 = 'Off'; 1 = 'Enabled but not running'; 2 = 'Running' }
    $svcNames = @{ 1 = 'Credential Guard'; 2 = 'Memory integrity (HVCI)'; 3 = 'System Guard Secure Launch'; 4 = 'SMM firmware measurement'; 5 = 'Kernel-mode HW stack protection'; 7 = 'Hypervisor-enforced paging translation' }
    $running = @($dg.SecurityServicesRunning | Where-Object { $_ -ne 0 } | ForEach-Object { if ($svcNames.ContainsKey([int]$_)) { $svcNames[[int]$_] } else { "service $_" } })
    $runText = 'none'
    if ($running.Count -gt 0) { $runText = $running -join ', ' }
    Write-Host ("VBS status: {0}" -f $vbsNames[[int]$dg.VirtualizationBasedSecurityStatus])
    Write-Host ("Security services running: {0}" -f $runText)
    Write-KitFact vbs_status $vbsNames[[int]$dg.VirtualizationBasedSecurityStatus]; Write-KitFact vbs_services $runText
    if ([int]$dg.VirtualizationBasedSecurityStatus -eq 2) {
        Add-Finding 'WARN' ("VBS is RUNNING ({0}). Inside a Proxmox VM this means Windows runs on nested Hyper-V: noticeably more CPU per I/O and interrupt. Fix on the host: CPU type x86-64-v3, or keep 'host' and add flags=-nested-virt. Trade-off: you lose Credential Guard / memory-integrity protection." -f $runText)
    }
} catch { Write-Host "Could not query Win32_DeviceGuard: $($_.Exception.Message)" }

# ------------------------------------------------------------------ POWER
Section 'POWER PLAN'
$plan = (powercfg /getactivescheme) | Out-String
Write-Host $plan.Trim()
Write-KitFact power_plan_high_perf ($plan -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c|e9a42b02-d5df-448d-aa00-03f14749eb61')
if ($plan -notmatch '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c|e9a42b02-d5df-448d-aa00-03f14749eb61') {
    Add-Finding 'INFO' 'Power plan is not High/Ultimate performance. Effect inside a VM is small, but it avoids idle-state/timer latency. Command: powercfg /setactive SCHEME_MIN'
}

# ------------------------------------------------------------------ VIRTUAL HW
Section 'VIRTUAL HARDWARE AND VIRTIO DRIVERS'
$drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'VirtIO|Red Hat|QEMU|Balloon' -or $_.Manufacturer -match 'Red Hat' } |
    Select-Object DeviceName, DriverVersion, @{ n = 'DriverDate'; e = { if ($_.DriverDate) { ([datetime]$_.DriverDate).ToString('yyyy-MM-dd') } } }, InfName |
    Sort-Object DeviceName -Unique
Show $drv
Write-KitFact virtio_storage_driver ([bool]($drv | Where-Object { $_.DeviceName -match 'VirtIO SCSI|VirtIO Block' }))
if (-not ($drv | Where-Object { $_.DeviceName -match 'VirtIO SCSI|VirtIO Block' })) {
    Add-Finding 'WARN' 'No VirtIO storage driver is loaded: disks are on emulated IDE/SATA/LSI controllers. Install virtio-win and move the disks to VirtIO SCSI single + iothread.'
}
Write-Host 'Storage controllers:'
Show (Get-CimInstance Win32_SCSIController | Select-Object Name, DriverName, Status)
Show (Get-CimInstance Win32_IDEController -ErrorAction SilentlyContinue | Select-Object Name, Status)

Write-Host 'Disks:'
$disks = @(Get-Disk | Sort-Object Number)
Show ($disks | Select-Object Number, FriendlyName, BusType, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } }, PartitionStyle, IsBoot, IsSystem, OperationalStatus)
foreach ($d in $disks) {
    Write-KitFact ("disk{0}.bus" -f $d.Number) ([string]$d.BusType) ("{0} {1:N0} GB" -f $d.FriendlyName, ($d.Size / 1GB))
    if ([string]$d.BusType -in 'ATA', 'SATA', 'IDE') {
        Add-Finding 'WARN' ("Disk {0} ({1}) is attached through an emulated {2} controller. Move it to VirtIO SCSI (scsihw=virtio-scsi-single, iothread=1) after installing the vioscsi driver." -f $d.Number, $d.FriendlyName, $d.BusType)
    }
}
$pd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
Show ($pd | Select-Object DeviceId, FriendlyName, MediaType, BusType, LogicalSectorSize, PhysicalSectorSize)
foreach ($p in $pd) {
    if ([string]$p.MediaType -ne 'SSD') { Add-Finding 'INFO' ("Disk {0} reports MediaType '{1}'. Set ssd=1 on the Proxmox virtual disk so Windows treats it as SSD (ReTrim instead of defrag)." -f $p.DeviceId, $p.MediaType) }
}
try { Show ($pd | Get-StorageAdvancedProperty -ErrorAction Stop | Select-Object FriendlyName, IsDeviceCacheEnabled, IsPowerProtected) } catch { }

# ------------------------------------------------------------------ NETWORK
Section 'NETWORK ADAPTERS'
$nics = @(Get-NetAdapter | Where-Object Status -eq 'Up')
Show ($nics | Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress, @{ n = 'MTU'; e = { (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu } })
foreach ($n in $nics) {
    Write-KitFact ("nic.{0}" -f $n.Name) ("{0} {1}" -f $n.InterfaceDescription, $n.LinkSpeed)
    if ($n.InterfaceDescription -match 'PRO/1000|82574|82540|RTL8139|vmxnet3') {
        Add-Finding 'WARN' ("NIC '{0}' is an emulated adapter ({1}): more CPU per packet and higher latency. Switch the Proxmox NIC model to VirtIO (install NetKVM first)." -f $n.Name, $n.InterfaceDescription)
    }
    if ($n.InterfaceDescription -match 'VirtIO') {
        $rss = Get-NetAdapterRss -Name $n.Name -ErrorAction SilentlyContinue
        if ($rss -and -not $rss.Enabled) { Add-Finding 'INFO' "RSS is disabled on '$($n.Name)'. Enable it (and set queues=<vCPUs> on the Proxmox NIC) to spread SMB traffic across vCPUs." }
        Write-Host "Advanced properties of $($n.Name):"
        Show (Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue | Select-Object DisplayName, DisplayValue)
    }
    if ([string]$n.LinkSpeed -match '^(10|100) Mbps') { Add-Finding 'WARN' "NIC '$($n.Name)' reports only $($n.LinkSpeed)." }
}
Write-Host 'DNS servers:'
Show (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | Select-Object InterfaceAlias, ServerAddresses)

# ------------------------------------------------------------------ VOLUMES
Section 'VOLUMES AND NTFS SETTINGS'
$vols = @(Get-Volume | Where-Object { $_.DriveLetter -and [string]$_.FileSystemType -in 'NTFS', 'ReFS' } | Sort-Object DriveLetter)
Show ($vols | Select-Object DriveLetter, FileSystemLabel, FileSystemType,
    @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
    @{ n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } },
    @{ n = 'Free%'; e = { if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 0) } } }, HealthStatus)
foreach ($v in $vols) {
    $L = "$($v.DriveLetter):"
    if ([string]$v.FileSystemType -eq 'NTFS') {
        $info = fsutil fsinfo ntfsinfo $L 2>$null
        $clusterLine = $info | Select-String -Pattern 'Bytes Per Cluster' | Select-Object -First 1
        $cluster = $null
        if ($clusterLine -and ($clusterLine.Line -match '(\d+)')) { $cluster = [int]$Matches[1] }
        $s83 = (fsutil 8dot3name query $L 2>$null) -join ' '
        Write-Host ("{0} NTFS cluster size: {1} bytes  (compare with the zvol volblocksize from pve-audit.sh)" -f $L, $cluster)
        Write-Host ("{0} 8.3 short names: {1}" -f $L, $s83)
        Write-KitFact ("vol.{0}.cluster_bytes" -f $v.DriveLetter) $cluster; Write-KitFact ("vol.{0}.8dot3_enabled" -f $v.DriveLetter) ($s83 -match 'is enabled on')
        if ($s83 -match 'is enabled on') {
            Add-Finding 'INFO' "$L generates 8.3 short names for every new file. In folders with thousands of files this slows creates and lookups. Disable for new files: fsutil 8dot3name set $L 1 (confirm no legacy tool depends on short names first)."
        }
    }
    if ($v.Size -gt 0 -and ($v.SizeRemaining / $v.Size) -lt 0.15) { Add-Finding 'WARN' ("Volume {0} has less than 15% free space." -f $L) }
}
$la = (fsutil behavior query disablelastaccess) -join ' '
$dn = (fsutil behavior query DisableDeleteNotify) -join ' '
Write-Host "Last-access time updates: $la"
Write-Host "TRIM: $dn"
Write-KitFact lastaccess_enabled ($la -match '=\s*(0|3)\b'); Write-KitFact trim_disabled ($dn -match 'NTFS DisableDeleteNotify\s*=\s*1')
if ($la -match '=\s*(0|3)\b') { Add-Finding 'INFO' 'NTFS last-access-time updates are ENABLED: reads also generate metadata writes. Disable: fsutil behavior set disablelastaccess 1' }
if ($dn -match 'NTFS DisableDeleteNotify\s*=\s*1') { Add-Finding 'WARN' 'TRIM is disabled in Windows (DisableDeleteNotify=1): deleted space is never returned to the thin zvol.' }
Show (Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -ErrorAction SilentlyContinue | Select-Object TaskName, State)

# ------------------------------------------------------------------ DATA CENSUS
if ($DataPath) {
    Section "DATA FOLDER CENSUS: $DataPath"
    if (Test-Path -LiteralPath $DataPath) {
        $root = (Resolve-Path -LiteralPath $DataPath).ProviderPath
        $dirCounts = @{}; $extCounts = @{}; $files = 0; $bytes = [int64]0; $truncated = $false
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($root)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($stack.Count -gt 0 -and -not $truncated) {
            $dir = $stack.Pop()
            try {
                $di = New-Object System.IO.DirectoryInfo $dir
                $n = 0
                foreach ($fi in $di.EnumerateFiles()) {
                    $n++; $files++; $bytes += $fi.Length
                    $ext = $fi.Extension.ToLowerInvariant()
                    $extCounts[$ext] = 1 + [int]$extCounts[$ext]
                    if ($files -ge $CensusMaxFiles) { $truncated = $true; break }
                }
                $dirCounts[$dir] = $n
                foreach ($sub in $di.EnumerateDirectories()) {
                    if (-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub.FullName) }
                }
            } catch { }
        }
        $sw.Stop()
        $note = ''
        if ($truncated) { $note = '  [stopped at -CensusMaxFiles]' }
        Write-Host ("Files: {0:N0}   Folders: {1:N0}   Size: {2:N1} GB   Local enumeration: {3:N1} s ({4:N0} files/s){5}" -f $files, $dirCounts.Count, ($bytes / 1GB), $sw.Elapsed.TotalSeconds, ($files / [math]::Max($sw.Elapsed.TotalSeconds, 0.001)), $note)
        Write-KitMetric data_files $files count; Write-KitMetric data_folders $dirCounts.Count count; Write-KitMetric data_gb ([math]::Round($bytes / 1GB, 1)) GB
        Write-KitMetric local_enum_files_per_sec ([math]::Round($files / [math]::Max($sw.Elapsed.TotalSeconds, 0.001), 0)) 'files/s'
        Write-Host 'Folders with the most files:'
        Show ($dirCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 @{ n = 'Files'; e = { $_.Value } }, @{ n = 'Folder'; e = { $_.Key } })
        Write-Host 'Most common extensions (useful for vendor AV exclusions):'
        Show ($extCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 @{ n = 'Files'; e = { $_.Value } }, @{ n = 'Extension'; e = { $_.Key } })
        $big = @($dirCounts.GetEnumerator() | Where-Object { $_.Value -ge 5000 })
        if ($big.Count -gt 0) { Add-Finding 'INFO' ("{0} folder(s) hold 5,000+ files. Large flat folders are slow to list and look up over SMB (worse with 8.3 names and access-based enumeration)." -f $big.Count) }
    } else { Write-Host "DataPath '$DataPath' not found." }
}

# ------------------------------------------------------------------ SMB SERVER
Section 'SMB SERVER CONFIGURATION'
$smb = Get-SmbServerConfiguration
ShowList (Select-Existing $smb @('RequireSecuritySignature', 'EnableSecuritySignature', 'EncryptData', 'RejectUnencryptedAccess',
        'EnableSMB1Protocol', 'EnableSMB2Protocol', 'EnableLeasing', 'EnableOplocks', 'EnableMultiChannel', 'AsynchronousCredits',
        'Smb2CreditsMin', 'Smb2CreditsMax', 'MaxThreadsPerQueue', 'DisableCompression', 'EnableStrictNameChecking', 'AuditSmb1Access'))
$smbNames = $smb.PSObject.Properties.Name
Write-KitFact smb_require_signing $smb.RequireSecuritySignature; Write-KitFact smb_encrypt_all $smb.EncryptData; Write-KitFact smb1_enabled $smb.EnableSMB1Protocol
if ($smb.RequireSecuritySignature) { Add-Finding 'INFO' 'SMB server REQUIRES signing. Windows 11 24H2 / Server 2025 sign by default anyway. Signing costs throughput on every request (Microsoft cites roughly 15% on file operations) but blocks relay/tampering attacks. Measure (Signed column in SmallFile-Test results) before considering any change.' }
if ($smb.EncryptData) { Add-Finding 'INFO' 'SMB encryption is ON server-wide: extra CPU per request (cheap with AES-NI, expensive without).' }
if ($smb.EnableSMB1Protocol) { Add-Finding 'WARN' 'SMB1 is enabled on the server: a security risk and slow. Disable unless an old device requires it.' }
if ($smbNames -contains 'EnableLeasing' -and -not $smb.EnableLeasing) { Add-Finding 'WARN' 'SMB leasing is DISABLED: clients cannot cache file data/handles, so every open goes to the server - very costly over VPN.' }
if ($smbNames -contains 'EnableOplocks' -and -not $smb.EnableOplocks) { Add-Finding 'WARN' 'Oplocks are DISABLED: same effect as disabling leasing.' }

Section 'SHARES'
$shares = @(Get-SmbShare -Special $false -ErrorAction SilentlyContinue)
Show (Select-Existing $shares @('Name', 'Path', 'FolderEnumerationMode', 'CachingMode', 'EncryptData', 'ContinuouslyAvailable', 'CompressData', 'LeasingMode', 'ScopeName'))
foreach ($s in $shares) {
    $sn = $s.PSObject.Properties.Name
    Write-KitFact ("share.{0}" -f $s.Name) ("{0} ABE={1} CA={2} Encrypt={3}" -f $s.Path, $s.FolderEnumerationMode, $s.ContinuouslyAvailable, $s.EncryptData)
    if ([string]$s.FolderEnumerationMode -eq 'AccessBased') { Add-Finding 'INFO' "Share '$($s.Name)' uses access-based enumeration: the server checks permissions on every entry of every folder listing. Slows big folders; disable if not needed." }
    if ($s.ContinuouslyAvailable) { Add-Finding 'WARN' "Share '$($s.Name)' is Continuously Available: forces write-through on every write (meant for clusters/Hyper-V/SQL, not user files)." }
    if ($sn -contains 'LeasingMode' -and $s.LeasingMode -and [string]$s.LeasingMode -ne 'Full') { Add-Finding 'WARN' "Share '$($s.Name)' has LeasingMode=$($s.LeasingMode): client caching reduced." }
    if ($s.EncryptData) { Add-Finding 'INFO' "Share '$($s.Name)' requires SMB encryption." }
}
Write-Host 'Share permissions:'
Show ($shares | ForEach-Object { Get-SmbShareAccess -Name $_.Name -ErrorAction SilentlyContinue } | Select-Object Name, AccountName, AccessControlType, AccessRight)

Section 'CURRENT SMB SESSIONS'
$sess = @(Get-SmbSession -ErrorAction SilentlyContinue)
if ($sess.Count -gt 0) { Show (Select-Existing $sess @('ClientComputerName', 'ClientUserName', 'Dialect', 'NumOpens', 'SecondsExists', 'SecondsIdle', 'Encrypted', 'Signed')) }
else { Write-Host 'No active sessions.' }
Write-Host ("Open files: {0}" -f @(Get-SmbOpenFile -ErrorAction SilentlyContinue).Count)

# ------------------------------------------------------------------ ANTIVIRUS
Section 'ANTIVIRUS / EDR / FILE-SYSTEM FILTERS'
$mp = $null
try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
if ($mp) {
    ShowList ($mp | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled, OnAccessProtectionEnabled, IoavProtectionEnabled, IsTamperProtected, AMProductVersion)
    $pref = Get-MpPreference
    Write-Host ("Exclusion paths     : {0}" -f (@($pref.ExclusionPath) -join '; '))
    Write-Host ("Exclusion processes : {0}" -f (@($pref.ExclusionProcess) -join '; '))
    Write-Host ("Exclusion extensions: {0}" -f (@($pref.ExclusionExtension) -join '; '))
    Write-Host ("DisableScanningNetworkFiles: {0}   ScanAvgCPULoadFactor: {1}" -f $pref.DisableScanningNetworkFiles, $pref.ScanAvgCPULoadFactor)
    Write-KitFact defender_realtime ($mp.RealTimeProtectionEnabled -and [string]$mp.AMRunningMode -eq 'Normal'); Write-KitFact defender_exclusion_paths (@($pref.ExclusionPath) -join '; ')
    if ($mp.RealTimeProtectionEnabled -and [string]$mp.AMRunningMode -eq 'Normal') {
        $excluded = $false
        if ($DataPath -and $pref.ExclusionPath) {
            foreach ($e in @($pref.ExclusionPath)) { if ($e -and $DataPath.TrimEnd('\') -like ($e.TrimEnd('\') + '*')) { $excluded = $true } }
        }
        Write-KitFact defender_data_path_excluded $excluded
        if (-not $excluded) { Add-Finding 'INFO' 'Defender real-time protection scans the data folder: every file open/close on the share is scanned on the server. CaseWare recommends AV exclusions for its files and executables. Measure with SmallFile-Test.ps1 -DefenderAB before deciding. Trade-off: excluded files are not scanned on access (scheduled scans still cover them).' }
    }
} else { Write-Host 'Microsoft Defender not present or not queryable.' }
$avRegex = 'Sophos|SentinelOne|CrowdStrike|Falcon|ESET|Bitdefender|Webroot|Trend Micro|Symantec|McAfee|Trellix|Malwarebytes|Huntress|Datto|Cylance|Kaspersky|Carbon Black|Cortex XDR|Avast|AVG|Norton|ThreatLocker|Blackpoint|Arctic Wolf|Todyl|Heimdal|Emsisoft|WithSecure|F-Secure|Cybereason|Deep Instinct|Coro'
$av3 = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $avRegex })
if ($av3.Count -gt 0) {
    Show ($av3 | Select-Object Status, Name, DisplayName)
    Write-KitFact third_party_security ((@($av3.DisplayName) | Select-Object -Unique) -join ', ')
    Add-Finding 'INFO' ('Third-party security agents found: {0}. AV/EDR/allow-listing filter drivers (ThreatLocker storage control in particular) add latency to every file open; review their exclusion/performance settings for the data folder.' -f ((@($av3.DisplayName) | Select-Object -Unique) -join ', '))
}
Write-Host 'File-system minifilter drivers (fltmc):'
fltmc filters 2>&1 | Out-String | Write-Host

# ------------------------------------------------------------------ VSS / BACKUP
Section 'SHADOW COPIES, BACKUP AGENTS, OTHER FILE-TOUCHING SERVICES'
vssadmin list shadowstorage 2>&1 | Out-String | Write-Host
$shadowCount = @(vssadmin list shadows 2>&1 | Select-String 'Shadow Copy ID').Count
Write-Host "Existing shadow copies: $shadowCount"
Write-KitFact shadow_copies $shadowCount
$scTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'ShadowCopyVolume*' })
Write-KitFact shadow_copy_schedules $scTasks.Count
if ($scTasks.Count -gt 0) {
    Show ($scTasks | Select-Object TaskName, State, @{ n = 'Times'; e = { (@($_.Triggers) | ForEach-Object { if ($_.StartBoundary) { ([datetime]$_.StartBoundary).ToString('HH:mm') } }) -join ', ' } })
    Add-Finding 'INFO' 'Windows Previous Versions (shadow copies) are scheduled. Each snapshot briefly freezes writes and adds copy-on-write overhead. If ZFS snapshots / Proxmox backups already cover restores, consider moving them outside business hours.'
}
$bk = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Veeam|Acronis|Datto|Cove|N-able|Carbonite|Macrium|Altaro|Nakivo|Arcserve|Backup Exec|Axcient|Unitrends|Commvault|Barracuda|Windows Server Backup' })
if ($bk.Count -gt 0) { Write-Host 'Backup agents:'; Show ($bk | Select-Object Status, Name, DisplayName) }
$ga = Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue
if (-not $ga -or $ga.Status -ne 'Running') { Add-Finding 'INFO' 'QEMU guest agent service is not running: Proxmox backups cannot quiesce NTFS (crash-consistent only).' }
else { Write-Host 'QEMU guest agent: running' }
$other = @(Get-Service -Name WSearch, SrmSvc, DFSR -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
if ($other.Count -gt 0) { Write-Host 'Other services that touch files:'; Show ($other | Select-Object Status, Name, DisplayName) }

# ------------------------------------------------------------------ EVENTS
Section "EVENT LOGS (last $EventDays days)"
$since = (Get-Date).AddDays(-$EventDays)
$sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Id = 7, 11, 15, 50, 51, 55, 98, 129, 140, 153, 157, 2004 } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'disk|vioscsi|viostor|storport|stornvme|Ntfs|atapi|storahci|volmgr|Resource-Exhaustion|lsi' })
Write-KitMetric storage_reset_events (@($sys | Where-Object { $_.Id -in 129, 153 }).Count) count ("last $EventDays days")
if ($sys.Count -gt 0) {
    Show ($sys | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object Count, Name)
    Show ($sys | Select-Object -First 15 TimeCreated, ProviderName, Id, @{ n = 'Message'; e = { ($_.Message -split "`r?`n")[0] } })
    if ($sys | Where-Object { $_.Id -in 129, 153 }) { Add-Finding 'WARN' 'Storage resets (event 129) or retried I/O (event 153) were logged: the virtual disk stopped responding for seconds at a time - matches the "app hangs" symptom. Correlate the timestamps with backups, replication, scrubs or snapshots on the Proxmox host.' }
    if ($sys | Where-Object { $_.Id -in 50, 55, 98, 140 }) { Add-Finding 'WARN' 'NTFS flush failures or corruption events were logged. Run chkdsk /scan and check host storage health.' }
    if ($sys | Where-Object { $_.Id -eq 2004 }) { Add-Finding 'WARN' 'Resource-exhaustion (low memory) events were logged.' }
} else { Write-Host 'No storage-related System events.' }
$smbEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-SMBServer/Operational'; StartTime = $since; Level = 1, 2, 3 } -ErrorAction SilentlyContinue)
Write-KitMetric smb_slow_fs_events_1020 (@($smbEv | Where-Object Id -eq 1020).Count) count ("last $EventDays days")
if ($smbEv.Count -gt 0) {
    Write-Host 'SMB server warnings/errors:'
    Show ($smbEv | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 10 Count, Name, @{ n = 'Example'; e = { ($_.Group[0].Message -split "`r?`n")[0] } })
    if ($smbEv | Where-Object Id -eq 1020) { Add-Finding 'WARN' 'SMB server event 1020 was logged: a file-system operation on a share took longer than expected, i.e. the storage underneath stalled. This points at the disk stack, not the network.' }
} else { Write-Host 'No SMB server warnings/errors.' }

Section 'TIME SYNC'
w32tm /query /status 2>&1 | Select-Object -First 8 | Out-String | Write-Host

# ------------------------------------------------------------------ SUMMARY
Section 'FINDINGS'
foreach ($lvl in 'WARN', 'INFO') {
    foreach ($f in @($Findings | Where-Object Level -eq $lvl)) {
        $color = 'Gray'
        if ($lvl -eq 'WARN') { $color = 'Yellow' }
        Write-Host ("[{0}] {1}" -f $f.Level, $f.Message) -ForegroundColor $color
        Write-Host ''
    }
}
if ($Findings.Count -eq 0) { Write-Host 'No findings.' }
$Findings | Export-Csv -Path ($script:KitBase + '-findings.csv') -NoTypeInformation
} finally {
    Complete-KitLog
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Report saved: $report"
}
