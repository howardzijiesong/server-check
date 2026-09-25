<#
.SYNOPSIS
    Reads every *.jsonl log produced by the kit (Proxmox + Windows + VPN) and writes an
    easy-to-read summary: what was tested, what failed, where the time goes, verdicts,
    and a prioritized list of next steps.
.DESCRIPTION
    Works in Windows PowerShell 5.1 and PowerShell 7 (Windows, Linux, macOS).
    Collect all results folders into one place first (e.g. copy proxmox/results from
    the host with scp), or pass several folders to -Path.
    -Redact replaces host names, the AD domain, IP addresses, share names and user
    folders with placeholders so the summary can be shared (chat, GitHub issue).
.EXAMPLE
    .\Analyze-Results.ps1 -Path .\windows\results, .\proxmox\results
.EXAMPLE
    pwsh ./Analyze-Results.ps1 -Path ./collected -Redact
#>
[CmdletBinding()]
param(
    [string[]]$Path = @($PSScriptRoot),
    [switch]$Redact,
    [string]$OutFile
)
$ErrorActionPreference = 'Continue'
$inv = [Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------------ load
$files = @()
foreach ($p in $Path) {
    if (Test-Path -LiteralPath $p) { $files += @(Get-ChildItem -LiteralPath $p -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) }
    else { Write-Warning "Path not found: $p" }
}
$files = @($files | Sort-Object FullName -Unique)
if ($files.Count -eq 0) {
    Write-Host 'No *.jsonl logs found. Pass the folder(s) that contain the results, e.g.:' -ForegroundColor Yellow
    Write-Host '  .\Analyze-Results.ps1 -Path .\windows\results, .\proxmox\results'
    exit 1
}
$recs = New-Object System.Collections.Generic.List[object]
$badLines = 0
foreach ($f in $files) {
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
        $t = $line.Trim([char]0xFEFF, ' ', "`t")
        if (-not $t) { continue }
        try { $r = $t | ConvertFrom-Json -ErrorAction Stop } catch { $badLines++; continue }
        $d = [DateTimeOffset]::MinValue
        [void][DateTimeOffset]::TryParse([string]$r.ts, $inv, [Globalization.DateTimeStyles]::None, [ref]$d)
        $r | Add-Member -NotePropertyName tsd -NotePropertyValue $d -Force
        $r | Add-Member -NotePropertyName run -NotePropertyValue $f.FullName -Force
        $recs.Add($r)
    }
}
$Metrics = @($recs | Where-Object { $_.level -eq 'METRIC' })
$Facts = @($recs | Where-Object { $_.level -eq 'FACT' })

function Num($v) { $d = 0.0; if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d } return $null }
function MetricV([string]$Cat, [string]$Key) {
    $m = $Metrics | Where-Object { $_.cat -like $Cat -and $_.key -eq $Key } | Sort-Object tsd | Select-Object -Last 1
    if ($m) { return (Num $m.value) } return $null
}
function Fct([string]$Key, [string]$Cat = '*') {
    $x = $Facts | Where-Object { $_.cat -like $Cat -and $_.key -eq $Key } | Sort-Object tsd | Select-Object -Last 1
    if ($x) { return [string]$x.value } return $null
}
function Fmt($v, [int]$d = 2) { if ($null -eq $v) { return 'n/a' } return [string]([math]::Round([double]$v, $d)) }
function FirstNum { foreach ($a in $args) { if ($null -ne $a) { return $a } } return $null }

$out = New-Object System.Collections.Generic.List[string]
function L([string]$s = '') { $out.Add($s) }
function Table($rows, [string[]]$cols) {
    $rows = @($rows)
    if ($rows.Count -eq 0) { return }
    L ('| ' + ($cols -join ' | ') + ' |')
    L ('|' + ((@($cols | ForEach-Object { '---' })) -join '|') + '|')
    foreach ($r in $rows) { L ('| ' + ((@($cols | ForEach-Object { ("$($r.$_)" -replace '\|', '/') })) -join ' | ') + ' |') }
    L ''
}
$Actions = New-Object System.Collections.Generic.List[object]
function Act([int]$P, [string]$Action, [string]$Why, [string]$Effort) {
    if (@($Actions | Where-Object { $_.Action -eq $Action }).Count -gt 0) { return }
    $Actions.Add([pscustomobject]@{ P = $P; Action = $Action; Why = $Why; Effort = $Effort })
}
$Warn = @($recs | Where-Object { $_.level -eq 'WARN' })
function HasWarn([string]$Pattern) { return (@($Warn | Where-Object { $_.msg -match $Pattern }).Count -gt 0) }
function WarnText([string]$Pattern) { $w = $Warn | Where-Object { $_.msg -match $Pattern } | Select-Object -First 1; if ($w) { return ($w.msg -split '\. ')[0] } return '' }

# ------------------------------------------------------------------ runs + errors
$runRows = foreach ($g in ($recs | Group-Object run)) {
    $st = $g.Group | Where-Object level -eq 'START' | Select-Object -First 1
    $en = $g.Group | Where-Object level -eq 'END' | Select-Object -First 1
    $errs = @($g.Group | Where-Object level -eq 'ERROR').Count
    $first = $g.Group | Select-Object -First 1
    $status = 'finished'
    if (-not $en) { $status = 'DID NOT FINISH (interrupted or crashed)' } elseif ($errs -gt 0) { $status = "finished with $errs error(s)" }
    $when = ''
    if ($st) { $when = $st.tsd.ToString('yyyy-MM-dd HH:mm') }
    [pscustomobject]@{ Script = $first.script; Host = $first.host; Started = $when; Status = $status; Args = $(if ($st) { $st.msg } else { '' }) }
}
$runRows = @($runRows | Sort-Object Started)
$Errors = @($recs | Where-Object { $_.level -eq 'ERROR' })
$incomplete = @($runRows | Where-Object { $_.Status -like 'DID NOT*' })

# ------------------------------------------------------------------ small-file ladder
$sfCats = @($Metrics | Where-Object { $_.cat -like 'smallfile/*' } | Select-Object -ExpandProperty cat -Unique)
$ladder = foreach ($c in $sfCats) {
    $lab = $c.Substring(10)
    $read = FirstNum (MetricV $c 'Read-cold.ms_per_file') (MetricV $c 'Read.ms_per_file') (MetricV $c 'Real-Read.ms_per_file')
    [pscustomobject]@{
        Label = $lab
        ReadMsPerFile = Fmt $read 3
        OpenCloseMs = Fmt (FirstNum (MetricV $c 'OpenClose-cold.ms_per_file') (MetricV $c 'OpenClose.ms_per_file')) 3
        StatMs = Fmt (FirstNum (MetricV $c 'Stat-cold.ms_per_file') (MetricV $c 'Stat.ms_per_file') (MetricV $c 'Real-Stat.ms_per_file')) 3
        CreateMs = Fmt (MetricV $c 'Create.ms_per_file') 3
        CommitMs = Fmt (MetricV $c 'Modify-WriteThrough.ms_per_file') 3
        RoundTrips = Fmt (FirstNum (MetricV $c 'Read-cold.roundtrips_per_file') (MetricV $c 'Read.roundtrips_per_file') (MetricV $c 'Real-Read.roundtrips_per_file')) 1
        SecPer1000Files = Fmt $read 1
        _read = $read
    }
}
$ladder = @($ladder | Sort-Object Label)
function LadderVal([string]$Label) { $x = $ladder | Where-Object { $_.Label -eq $Label } | Select-Object -First 1; if ($x) { return $x._read } return $null }
$vLocal = LadderVal 'server-local'; $vAv = LadderVal 'server-local+AVexcl'; $vLoop = LadderVal 'server-loopback'
$vLan = LadderVal 'lan-client'; $vVpn = LadderVal 'vpn-client'

# ------------------------------------------------------------------ key numbers
$prodDb = @($Metrics | Where-Object { $_.cat -like 'diskbench/*' -and $_.cat -notmatch '(?i)hdd|ssd|native|usb|test' } | Sort-Object tsd | Select-Object -ExpandProperty cat -Unique)
$vmCat = 'diskbench/*'
if ($prodDb.Count -gt 0) { $vmCat = $prodDb[-1] }
$vmWtMs   = MetricV $vmCat 'rw4k_qd1_wt.WriteAvgMs'
$vmReadMs = MetricV $vmCat 'rr4k_qd1.ReadAvgMs'
$pvb = Fct 'primary_volblocksize' 'pvebench/pool'
$hostSyncUs = $null; $hostReadUs = $null; $hostOffUs = $null
if ($pvb) {
    $hostSyncUs = MetricV 'pvebench/pool' "zvol-$pvb-randwrite-4k-qd1-sync.w_lat_avg_us"
    $hostReadUs = MetricV 'pvebench/pool' "zvol-$pvb-randread-4k-qd1.r_lat_avg_us"
    $hostOffUs  = MetricV 'pvebench/pool' "zvol-$pvb-randwrite-4k-qd1-SYNCOFF.w_lat_avg_us"
}
$virtRatio = $null
if ($vmWtMs -and $hostSyncUs) { $virtRatio = ($vmWtMs * 1000) / $hostSyncUs }
$diskP95 = MetricV 'perf/server*' 'disk_worst_p95_ms'
$smbSrvP95 = MetricV 'perf/server*' 'smb_server_p95_ms'
$ev1020 = MetricV '*' 'smb_slow_fs_events_1020'
$evReset = MetricV '*' 'storage_reset_events'
$devSync = MetricV 'pvebench/device' 'zfs_overhead_sync_write_x'
$devRead = MetricV 'pvebench/device' 'zfs_overhead_read_x'
$syncOffX = MetricV 'pvebench/pool' 'syncoff_speedup_x'

# ------------------------------------------------------------------ verdicts
$storageVerdict = 'Not enough data yet: run Server-DiskBench.ps1 and Perf-Monitor.ps1 -Role Server while a user reproduces the slowness.'
$storageOk = $null
if ($null -ne $diskP95 -or $null -ne $vmWtMs) {
    if (($null -ne $diskP95 -and $diskP95 -ge 10) -or ($ev1020 -gt 0)) {
        $storageOk = $false
        if ($virtRatio -and $virtRatio -gt 4 -and $vmWtMs -gt 0.3) { $storageVerdict = ("Storage is slow INSIDE the VM, but the host zvol is fine (VM is {0}x slower than the host): fix the VM configuration first; rebuilding the pool would not help." -f (Fmt $virtRatio 1)) }
        else { $storageVerdict = 'Storage is a real contributor during real use. Try the volblocksize / sync steps (README 5D) before considering any pool rebuild.' }
    } elseif ($null -ne $diskP95 -and $diskP95 -ge 2) {
        $storageOk = $true
        $storageVerdict = ("Storage is acceptable (disk P95 {0} ms during real use). Rebuilding FastPool as plain NTFS is NOT justified; tuning may shave a little." -f (Fmt $diskP95 1))
    } else {
        $storageOk = $true
        $v = 'VM DiskSpd results'
        if ($null -ne $diskP95) { $v = "disk P95 $(Fmt $diskP95 2) ms during real use" }
        $storageVerdict = "Storage is NOT the bottleneck ($v). Rebuilding FastPool as plain NTFS is NOT justified."
    }
}
$remoteVerdict = 'Not enough data: run SmallFile-Test.ps1 on an office PC (lan-client) and over the VPN (vpn-client).'
$vpnShare = $null
if ($vVpn -and $vLan) {
    $vpnShare = 100 * ($vVpn - $vLan) / $vVpn
    $remoteVerdict = ("Over the VPN each file takes {0} ms vs {1} ms in the office ({2}x slower); {3}% of the remote time is the VPN/internet path, which no storage change can reduce." -f (Fmt $vVpn 1), (Fmt $vLan 2), (Fmt ($vVpn / [math]::Max($vLan, 0.001)) 0), (Fmt $vpnShare 0))
} elseif ($vVpn) {
    $remoteVerdict = ("Over the VPN each file takes {0} ms." -f (Fmt $vVpn 1))
}

# ------------------------------------------------------------------ next-step rules
if ($Errors.Count -gt 0 -or $incomplete.Count -gt 0) { Act 0 'Fix and re-run the tests that failed or did not finish (see "Problems during the runs")' ("{0} error(s), {1} unfinished run(s)" -f $Errors.Count, $incomplete.Count) 'minutes' }
if (HasWarn 'VBS is RUNNING|nested virtualization available') { Act 1 'Stop VBS in the VM: set the Proxmox CPU type to x86-64-v3, or host with flags=-nested-virt (VM shutdown needed)' (WarnText 'VBS is RUNNING|nested virtualization available') '10 min + reboot' }
if (HasWarn 'AES-NI|hides AES') { Act 1 'Expose AES-NI: change the VM CPU type (x86-64-v3)' (WarnText 'AES-NI|hides AES') '10 min + reboot' }
if (HasWarn 'emulated (IDE|SATA|ATA)|attached through an emulated|No VirtIO storage driver|SCSI controller is') { Act 1 'Move the VM disks to VirtIO SCSI single with iothread=1 (install vioscsi first; README 5A)' (WarnText 'emulated (IDE|SATA|ATA)|attached through an emulated|No VirtIO storage driver|SCSI controller is') '30 min + reboot' }
if (HasWarn 'iothread not enabled') { Act 1 'Enable iothread=1 on the VM disks (with scsihw=virtio-scsi-single)' (WarnText 'iothread not enabled') '10 min + reboot' }
if (HasWarn 'emulated NIC|emulated adapter') { Act 1 'Switch the VM NIC to VirtIO (re-enter the DC static IP afterwards)' (WarnText 'emulated NIC|emulated adapter') '20 min' }
if (($evReset -gt 0) -or (HasWarn 'event 129|retried I/O')) { Act 1 'Investigate storage stalls (events 129/153): line their times up with syncoid (04:00), backups, scrubs, snapshots' ("{0} reset/retry events" -f (Fmt $evReset 0)) '30 min' }
if ($ev1020 -gt 0) { Act 1 'SMB event 1020 (storage stalled under the share): check pve-monitor/Perf-Monitor at those times' ("{0} events" -f (Fmt $ev1020 0)) '30 min' }
if ($virtRatio -and $virtRatio -gt 4 -and $vmWtMs -gt 0.3) { Act 1 'VM layer is the storage bottleneck: fix controller/iothread/CPU type before touching ZFS' ("VM 4K sync write {0} ms vs host zvol {1} us ({2}x)" -f (Fmt $vmWtMs 3), (Fmt $hostSyncUs 0), (Fmt $virtRatio 1)) '30 min' }
if ($null -ne $diskP95 -and $diskP95 -ge 10) { Act 1 'Storage latency is high in real use: try a new zvol with the best volblocksize from pve-bench (README 5D)' ("disk P95 {0} ms" -f (Fmt $diskP95 1)) '1-2 h' }
if ($vpnShare -and $vpnShare -ge 70) { Act 1 'Remote users: run CaseWare/TaxCycle next to the data - a Remote Desktop session host VM (separate from the DC); pilot within the 120-day RDS grace period' ("{0}% of remote time is the VPN path ({1} ms/file vs {2} in office)" -f (Fmt $vpnShare 0), (Fmt $vVpn 1), (Fmt $vLan 2)) 'half day pilot' }
$bh = @($Facts | Where-Object { $_.key -eq 'pmtu_blackhole' -and $_.value -eq 'True' })
if ($bh.Count -gt 0 -or (HasWarn 'black hole')) { Act 1 'Fix the VPN MTU black hole: set mssfix (e.g. 1360) on the OpenVPN server / MSS clamping on the firewall' 'oversized packets are silently dropped -> hangs on larger reads/writes' '15 min' }
$loss = MetricV 'netcheck/vpn' 'ping_loss_pct'
if (($loss -and $loss -gt 0.5) -or (HasWarn '% packet loss to the server')) { Act 1 'Packet loss on the remote path: check the office uplink, the VPN endpoint CPU and the users'' home connections' ("loss {0}%" -f (Fmt $loss 1)) '30 min' }
$retr = MetricV 'perf/client*' 'tcp_retransmit_pct'
if ($retr -and $retr -gt 2) { Act 1 'High TCP retransmits on the client: loss or MTU problems on the path' ("{0}% retransmits" -f (Fmt $retr 1)) '30 min' }
if (HasWarn 'proto tcp') { Act 2 'Switch OpenVPN to proto udp (keep TCP 443 only as a fallback profile)' (WarnText 'proto tcp') '30 min' }
if (HasWarn 'disables DCO|topology is|CBC|legacy OpenVPN TAP|older than 2\.6|disable-dco') { Act 2 'Enable OpenVPN data channel offload: 2.6+ both ends, AES-GCM/ChaCha20, topology subnet, no compression' (WarnText 'disables DCO|topology is|CBC|legacy OpenVPN TAP|older than 2\.6|disable-dco') '1 h' }
if (HasWarn 'No Kerberos ticket|mapped by IP|Cannot resolve|dhcp-option DNS') { Act 2 'Fix name resolution over the VPN: push the DC as DNS + domain suffix; map drives by server name' (WarnText 'No Kerberos ticket|mapped by IP|Cannot resolve|dhcp-option DNS') '30 min' }
if (HasWarn 'vmgenid is NOT set') { Act 2 'Add vmgenid to the DC VM before relying on snapshot rollback (qm set <vmid> --vmgenid 1)' 'AD rollback protection' '5 min + stop/start' }
if (HasWarn 'discard not enabled|TRIM is disabled') { Act 2 'Enable discard=on (and ssd=1) on the VM disks, then Optimize-Volume -ReTrim in Windows' (WarnText 'discard not enabled|TRIM is disabled') '10 min + reboot' }
if (HasWarn '% full') { Act 2 'Free space on the pool (keep ZFS below ~80% full)' (WarnText '% full') 'varies' }
if (HasWarn 'swap') { Act 2 'Host is swapping: reduce VM RAM overcommit or cap the ZFS ARC' (WarnText 'swap') '15 min' }
if ($vLocal -and $vAv) {
    $save = 100 * ($vLocal - $vAv) / $vLocal
    if ($save -ge 20) { Act 2 'Add Defender exclusions for the CaseWare/TaxCycle data folders + processes (server and workstations)' ("A/B test: {0}% faster per file without scanning" -f (Fmt $save 0)) '20 min' }
} elseif (@($recs | Where-Object { $_.level -eq 'INFO' -and $_.msg -match 'Defender real-time protection scans the data folder' }).Count -gt 0) {
    Act 3 'Measure the antivirus cost: SmallFile-Test.ps1 -Path <local data path> -Label server-local -DefenderAB' 'Defender scans every file open on the server' '5 min'
}
if (HasWarn 'Domain Controller') { Act 3 'Plan to move the shares off the DC to a member file-server VM (required anyway for a Remote Desktop host)' 'DC + file server on one VM' 'half day' }
if ($syncOffX -and $syncOffX -gt 3) { Act 3 'sync=disabled on the data zvol would speed durable writes, but only after the enterprise UPS with automatic shutdown (NUT) is in place' ("{0}x faster sync writes in pve-bench" -f (Fmt $syncOffX 1)) '5 min (later)' }
$infoMsgs = @($recs | Where-Object { $_.level -eq 'INFO' } | Select-Object -ExpandProperty msg)
if (@($infoMsgs | Where-Object { $_ -match '8\.3 short names' }).Count) { Act 3 'Disable 8.3 short-name creation on the data volume (fsutil 8dot3name set D: 1)' 'extra work per file create in big folders' '2 min' }
if (@($infoMsgs | Where-Object { $_ -match 'last-access-time updates are ENABLED' }).Count) { Act 3 'Disable NTFS last-access updates (fsutil behavior set disablelastaccess 1)' 'reads also cause metadata writes' '2 min' }
if (@($infoMsgs | Where-Object { $_ -match 'access-based enumeration' }).Count) { Act 3 'Turn off access-based enumeration on the data share if not needed' 'permission check on every folder entry' '2 min' }
if (@($infoMsgs | Where-Object { $_ -match 'shadow copies' }).Count) { Act 3 'Move Windows shadow copies outside business hours' 'brief write freezes during snapshots' '5 min' }
if (@($infoMsgs | Where-Object { $_ -match 'governor|Power plan' }).Count) { Act 3 'Set the host CPU governor / Windows power plan to performance' 'lower latency on bursty small I/O' '5 min' }
if (@($infoMsgs | Where-Object { $_ -match 'multiqueue|RSS is disabled' }).Count) { Act 3 'Enable NIC multiqueue (queues=<vCPUs>) + RSS in Windows' 'spreads SMB traffic over vCPUs' '10 min + reboot' }
if ($storageOk -eq $true) { Act 3 'Do NOT rebuild FastPool as plain NTFS - it would break the syncoid backup chain for no measurable gain' $storageVerdict 'n/a' }

# ------------------------------------------------------------------ report
$now = Get-Date
L '# Server bottleneck analysis'
L ''
L ("Generated {0} from {1} log file(s), {2} records{3}." -f $now.ToString('yyyy-MM-dd HH:mm'), $files.Count, $recs.Count, $(if ($badLines) { ", $badLines unreadable line(s) skipped" } else { '' }))
L ''
L '## Plain-English summary'
L ''
$testsLine = 'All test runs finished cleanly.'
if ($Errors.Count -or $incomplete.Count) { $testsLine = ("{0} error(s) and {1} unfinished run(s) - some conclusions below may be incomplete." -f $Errors.Count, $incomplete.Count) }
L "- **Tests:** $testsLine"
L "- **Storage:** $storageVerdict"
$cfgWarn = @($Warn | Where-Object { $_.script -in 'pve-audit', 'Server-Audit' }).Count
L ("- **Server configuration:** {0} warning(s) from the Proxmox and Windows audits; the important ones are in the next-steps list." -f $cfgWarn)
L "- **Remote users:** $remoteVerdict"
if ($vLocal -and $vLoop -and $vLan -and $vVpn) {
    $sStor = $vLocal; $sSmb = [math]::Max(0, $vLoop - $vLocal); $sLan = [math]::Max(0, $vLan - $vLoop); $sVpn = [math]::Max(0, $vVpn - $vLan)
    L ("- **Where a remote file read's {0} ms goes:** disk + NTFS + antivirus {1} ms ({2}%), SMB stack {3} ms ({4}%), office LAN + client {5} ms ({6}%), VPN + internet {7} ms ({8}%)." -f (Fmt $vVpn 1), (Fmt $sStor 2), (Fmt (100 * $sStor / $vVpn) 0), (Fmt $sSmb 2), (Fmt (100 * $sSmb / $vVpn) 0), (Fmt $sLan 2), (Fmt (100 * $sLan / $vVpn) 0), (Fmt $sVpn 1), (Fmt (100 * $sVpn / $vVpn) 0))
}
L ''
L '## Next steps (in order)'
L ''
if ($Actions.Count -eq 0) { L 'No actions derived yet - run more of the kit (see README run order).' }
else {
    $i = 0
    foreach ($a in ($Actions | Sort-Object P)) {
        $i++
        $pr = @('P0 now', 'P1 high', 'P2 medium', 'P3 low')[[math]::Min($a.P, 3)]
        L ("{0}. **[{1}] {2}**  " -f $i, $pr, $a.Action)
        L ("   why: {0}; effort: {1}" -f $a.Why, $a.Effort)
    }
}
L ''
if ($Errors.Count -gt 0) {
    L '## Problems during the runs'
    L ''
    foreach ($e in ($Errors | Sort-Object tsd)) { L ("- {0} on {1}: {2}" -f $e.script, $e.host, $e.msg) }
    L ''
}
L '## Test runs'
L ''
Table $runRows @('Script', 'Host', 'Started', 'Status')
if ($ladder.Count -gt 0) {
    L '## Small-file workload by layer (ms per file; lower is better)'
    L ''
    L 'SecPer1000Files = seconds an app needs to open and read 1,000 such files at that location.'
    L ''
    Table $ladder @('Label', 'ReadMsPerFile', 'OpenCloseMs', 'StatMs', 'CreateMs', 'CommitMs', 'RoundTrips', 'SecPer1000Files')
    if ($vLocal -and $vAv) { L ("Antivirus A/B on the server: {0} ms/file with Defender scanning vs {1} ms/file with a temporary exclusion." -f (Fmt $vLocal 3), (Fmt $vAv 3)); L '' }
    $hddV = LadderVal 'vpn-client-hdd'
    if ($vVpn -and $hddV) { L ("Same VPN test against the old HDD share: {0} ms/file vs {1} ms/file on the NVMe/ZFS share - the storage medium barely matters over the VPN." -f (Fmt $hddV 1), (Fmt $vVpn 1)); L '' }
}
$dbCats = @($Metrics | Where-Object { $_.cat -like 'diskbench/*' } | Select-Object -ExpandProperty cat -Unique)
if ($dbCats.Count -gt 0) {
    L '## Disk benchmark inside the VM (DiskSpd)'
    L ''
    $dbRows = foreach ($c in $dbCats) {
        [pscustomobject]@{
            Label = $c.Substring(10)
            SyncWrite4kMs = Fmt (MetricV $c 'rw4k_qd1_wt.WriteAvgMs') 3
            AsyncWrite4kMs = Fmt (MetricV $c 'rw4k_qd1_c.WriteAvgMs') 3
            Read4kMs = Fmt (MetricV $c 'rr4k_qd1.ReadAvgMs') 3
            MixedIOPS = Fmt (MetricV $c 'rrw4k_qd8x4.IOPS') 0
            SeqReadMBps = Fmt (MetricV $c 'sr1m_qd8.MBps') 0
        }
    }
    Table $dbRows @('Label', 'SyncWrite4kMs', 'AsyncWrite4kMs', 'Read4kMs', 'MixedIOPS', 'SeqReadMBps')
    L 'Rule of thumb for NVMe-backed disks: 4K sync write under 0.3 ms excellent, 0.3-1 ms good, over 3 ms poor. An HDD will show several ms - expected.'
    L ''
}
if ($pvb -or $null -ne $devSync) {
    L '## Host storage (fio on Proxmox)'
    L ''
    if ($pvb) {
        L ("- Pool zvol (volblocksize {0}): 4K sync write {1} us, 4K read from flash {2} us, with sync=disabled {3} us; best volblocksize for sync 4K: {4}." -f $pvb, (Fmt $hostSyncUs 0), (Fmt $hostReadUs 0), (Fmt $hostOffUs 0), (FirstNum ((Fct 'best_vbs_sync4k') -replace '^zvol-([^-]+)-.*$', '$1') 'n/a'))
        if ($virtRatio) { L ("- Virtualization layer: the VM's 4K sync write is {0}x the host zvol's (well-configured VMs are typically 2-4x; much more means the VM configuration is costing performance)." -f (Fmt $virtRatio 1)) }
    }
    if ($null -ne $devSync) { L ("- Same-SSD comparison (no ZFS vs ZFS zvol): ZFS costs {0}x on 4K sync writes and {1}x on 4K reads. (Consumer SSDs without power-loss protection exaggerate the sync cost vs the CD6.)" -f (Fmt $devSync 1), (Fmt $devRead 1)) }
    L ''
}
$perfCats = @($Metrics | Where-Object { $_.cat -like 'perf/*' } | Select-Object -ExpandProperty cat -Unique)
if ($perfCats.Count -gt 0) {
    L '## During real use (Perf-Monitor)'
    L ''
    $pRows = foreach ($c in $perfCats) {
        [pscustomobject]@{ Recording = $c.Substring(5); DiskP95ms = Fmt (MetricV $c 'disk_worst_p95_ms') 2; SmbServerP95ms = Fmt (MetricV $c 'smb_server_p95_ms') 2; SmbClientP95ms = Fmt (MetricV $c 'smb_client_p95_ms') 2; RetransPct = Fmt (MetricV $c 'tcp_retransmit_pct') 2; CpuP95 = Fmt (MetricV $c 'cpu_p95_pct') 0 }
    }
    Table $pRows @('Recording', 'DiskP95ms', 'SmbServerP95ms', 'SmbClientP95ms', 'RetransPct', 'CpuP95')
    L 'SMB client time minus SMB server time = time spent on the network/VPN.'
    L ''
}
$pm = MetricV 'pvemonitor' 'disk_wait-write_avg_us'
if ($null -ne $pm) {
    L ("Host ZFS during real use: write disk_wait avg {0} us, write total_wait avg {1} us (max {2} us), {3} sample(s) with >10 ms write waits, host I/O pressure max {4}%." -f (Fmt $pm 0), (Fmt (MetricV 'pvemonitor' 'total_wait-write_avg_us') 0), (Fmt (MetricV 'pvemonitor' 'total_wait-write_max_us') 0), (Fmt (MetricV 'pvemonitor' 'write_wait_spikes_over_10ms') 0), (Fmt (MetricV 'pvemonitor' 'io_pressure_max_pct') 1))
    L ''
}
$ncCats = @($recs | Where-Object { $_.cat -like 'netcheck/*' } | Select-Object -ExpandProperty cat -Unique)
if ($ncCats.Count -gt 0) {
    L '## Network paths (Client-NetCheck)'
    L ''
    $nRows = foreach ($c in $ncCats) {
        [pscustomobject]@{ Location = $c.Substring(9); RttMs = Fmt (MetricV $c 'rtt_ms') 1; LossPct = Fmt (MetricV $c 'ping_loss_pct') 1; JitterMs = Fmt (MetricV $c 'jitter_ms') 1; PathMtu = Fmt (MetricV $c 'path_mtu') 0; BlackHole = (Fct 'pmtu_blackhole' $c); Kerberos = (Fct 'kerberos_ticket' $c); Adapter = (Fct 'route_adapter' $c) }
    }
    Table $nRows @('Location', 'RttMs', 'LossPct', 'JitterMs', 'PathMtu', 'BlackHole', 'Kerberos', 'Adapter')
}
if ($Warn.Count -gt 0) {
    L '## All warnings'
    L ''
    foreach ($g in ($Warn | Group-Object msg)) { $w = $g.Group[0]; L ("- [{0} / {1}] {2}" -f $w.script, $w.cat, $w.msg) }
    L ''
}
$factRows = foreach ($g in ($Facts | Where-Object { $_.script -in 'pve-audit', 'Server-Audit', 'openvpn-check' -and $_.cat -ne 'run' } | Group-Object script, key)) {
    $x = $g.Group | Sort-Object tsd | Select-Object -Last 1
    [pscustomobject]@{ Source = $x.script; Key = $x.key; Value = $x.value }
}
if (@($factRows).Count -gt 0) {
    L '## Configuration facts collected'
    L ''
    Table ($factRows | Sort-Object Source, Key) @('Source', 'Key', 'Value')
}

$text = ($out -join "`n")

# ------------------------------------------------------------------ redaction
if ($Redact) {
    $map = [ordered]@{}
    $n = 0
    $names = @($recs | Select-Object -ExpandProperty host -Unique) + @($Facts | Where-Object { $_.key -in 'server_name', 'server' } | Select-Object -ExpandProperty value -Unique)
    foreach ($h in (@($names | Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique) | Sort-Object Length -Descending)) { if (-not $map.Contains($h)) { $n++; $map[$h] = "HOST$n" } }
    $dom = Fct 'domain'
    if ($dom -and $dom.Length -ge 3) { $map[$dom] = 'AD-DOMAIN'; $short = $dom.Split('.')[0]; if ($short.Length -ge 3 -and -not $map.Contains($short)) { $map[$short] = 'AD-DOMAIN' } }
    $n = 0
    foreach ($s in (@($Facts | Where-Object { $_.key -like 'share.*' } | ForEach-Object { $_.key.Substring(6) } | Select-Object -Unique) | Sort-Object Length -Descending)) { if ($s.Length -ge 3 -and -not $map.Contains($s)) { $n++; $map[$s] = "SHARE$n" } }
    foreach ($k in $map.Keys) { $text = [regex]::Replace($text, [regex]::Escape($k), $map[$k], 'IgnoreCase') }
    $ipMap = @{}
    $text = [regex]::Replace($text, '\b(?:\d{1,3}\.){3}\d{1,3}\b', { param($m) if (-not $ipMap.ContainsKey($m.Value)) { $ipMap[$m.Value] = "IP$($ipMap.Count + 1)" }; $ipMap[$m.Value] })
    $text = [regex]::Replace($text, '(?i)(\\Users\\|/home/)[^\\/\s|]+', '${1}USER')
    $text = $text + "`n`n_Redacted: host names, AD domain, share names, IPv4 addresses and user folders were replaced with placeholders._`n"
}

# ------------------------------------------------------------------ output
if (-not $OutFile) {
    $dir = $Path[0]
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $dir = (Get-Location).Path }
    $suffix = ''
    if ($Redact) { $suffix = '-redacted' }
    $OutFile = Join-Path $dir ("analysis-summary-{0}{1}.md" -f $now.ToString('yyyyMMdd-HHmmss'), $suffix)
}
[System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host $text
Write-Host ''
Write-Host "Summary written to: $OutFile" -ForegroundColor Green
if (-not $Redact) { Write-Host 'To share it safely (chat, GitHub issue), re-run with -Redact.' }
