<#
.SYNOPSIS
    Record performance counters while a user reproduces the slowness (server or client side).
.DESCRIPTION
    Server role: per-volume disk latency, SMB server per-share latency (server-side time
    only - network excluded), CPU, memory, NIC throughput, TCP retransmits.
    Client role: SMB client per-share latency (end-to-end, what the app experiences),
    CPU, NIC, TCP retransmits.
    Client "Avg. sec/Data Request" minus server "Avg. sec/Data Request" ~= network + VPN.
    Uses a temporary logman collector (removed at the end, also on Ctrl+C), writes a .blg
    (open in PerfMon) and a .csv, and prints avg / P95 / max for the key counters.
    Run in Windows PowerShell 5.1 (powershell.exe) - Import-Counter is not in PowerShell 7.
.EXAMPLE
    .\Perf-Monitor.ps1 -Role Server -Minutes 0          # stops when you press Enter
.EXAMPLE
    .\Perf-Monitor.ps1 -Role Client -Minutes 5
.EXAMPLE
    .\Perf-Monitor.ps1 -Summarize .\results\perf-server-FS01-20260927-101500_000001.blg
#>
[CmdletBinding()]
param(
    [ValidateSet('Server', 'Client')][string]$Role = 'Server',
    [int]$Minutes = 10,
    [int]$IntervalSeconds = 2,
    [string]$Label,          # e.g. lan / vpn - which situation you recorded
    [string]$Summarize,
    [string]$OutDir = (Join-Path $PSScriptRoot 'results')
)
$ErrorActionPreference = 'Continue'
$kitLib = Join-Path $PSScriptRoot 'lib\KitCommon.ps1'
if (-not (Test-Path -LiteralPath $kitLib)) { Write-Host "ERROR: $kitLib is missing - copy the whole 'windows' folder of the kit, not single scripts." -ForegroundColor Red; exit 2 }
. $kitLib
Initialize-KitLog 'Perf-Monitor' $OutDir $PSBoundParameters
$script:PerfCat = "perf/$($Role.ToLower())"
if ($Label) { $script:PerfCat = "$($script:PerfCat)/$Label" }
function PerfMetric([string]$Key, $Value, [string]$Unit = '') { Write-KitRecord 'METRIC' $script:PerfCat $Key '' $Value $Unit }

function Write-Verdict([string]$Text, [string]$Level) {
    $color = 'Green'
    if ($Level -eq 'WARN') { $color = 'Yellow' } elseif ($Level -eq 'BAD') { $color = 'Red' }
    Write-Host ("  [{0}] {1}" -f $Level, $Text) -ForegroundColor $color
}

function Show-Summary([string]$BlgPath) {
    if (-not (Get-Command Import-Counter -ErrorAction SilentlyContinue)) {
        Write-Host 'Import-Counter is not available here (PowerShell 7?). Open the .blg in PerfMon or the .csv in Excel, or re-run with -Summarize in powershell.exe.'
        return
    }
    Write-Host "Summarizing $BlgPath ..."
    $data = Import-Counter -Path $BlgPath -ErrorAction Stop
    $acc = @{}
    foreach ($s in $data) {
        foreach ($c in $s.CounterSamples) {
            if ($c.Status -ne 0) { continue }
            $p = $c.Path -replace '^\\\\[^\\]+', ''
            if (-not $acc.ContainsKey($p)) { $acc[$p] = New-Object System.Collections.Generic.List[double] }
            $acc[$p].Add([double]$c.CookedValue)
        }
    }
    $keep = 'avg\. (disk )?sec/|disk queue|% processor time|% privileged time|available mbytes|segments|bytes total/sec|current pending requests|data requests/sec|metadata requests/sec|processor queue'
    $rows = foreach ($k in $acc.Keys) {
        if ($k -notmatch $keep) { continue }
        $v = $acc[$k].ToArray()
        if ($v.Count -eq 0) { continue }
        [Array]::Sort($v)
        $mult = 1; $unit = ''
        if ($k -match 'avg\. (disk )?sec/') { $mult = 1000; $unit = 'ms' }
        [pscustomobject]@{
            Counter = $k
            Unit    = $unit
            Avg     = [math]::Round(($v | Measure-Object -Average).Average * $mult, 3)
            P95     = [math]::Round($v[[int][math]::Floor(0.95 * ($v.Count - 1))] * $mult, 3)
            Max     = [math]::Round($v[$v.Count - 1] * $mult, 3)
            Samples = $v.Count
        }
    }
    $rows = @($rows | Sort-Object Counter)
    $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    $rows | Export-Csv -Path ($BlgPath -replace '\.blg$', '-summary.csv') -NoTypeInformation

    Write-Host 'Verdicts:'
    $disk = @($rows | Where-Object { $_.Counter -match 'logicaldisk\([a-z]:\)\\avg\. disk sec/' })
    if ($disk.Count -gt 0) {
        $w = $disk | Sort-Object P95 -Descending | Select-Object -First 1
        $msg = "Worst disk latency: {0} P95 {1} ms (max {2} ms)." -f $w.Counter, $w.P95, $w.Max
        PerfMetric disk_worst_p95_ms $w.P95 ms; PerfMetric disk_worst_max_ms $w.Max ms
        if ($w.P95 -lt 2) { Write-Verdict "$msg Storage is NOT the bottleneck; rebuilding the pool will not help." 'OK' }
        elseif ($w.P95 -lt 10) { Write-Verdict "$msg Storage contributes but is unlikely to be the main cause." 'WARN' }
        else { Write-Verdict "$msg Storage is a real contributor: compare with pve-bench.sh / Server-DiskBench.ps1 to find which layer." 'BAD' }
    }
    $srv = @($rows | Where-Object { $_.Counter -match 'smb server shares\(.*\)\\avg\. sec/data request' -and $_.Counter -notmatch '_total' })
    if ($srv.Count -gt 0) { PerfMetric smb_server_p95_ms (($srv | Measure-Object P95 -Maximum).Maximum) ms; PerfMetric smb_server_avg_ms (($srv | Measure-Object Avg -Maximum).Maximum) ms }
    foreach ($r in $srv) {
        $msg = "SMB server-side time {0}: avg {1} ms, P95 {2} ms (excludes the network)." -f $r.Counter, $r.Avg, $r.P95
        if ($r.P95 -lt 5) { Write-Verdict "$msg The server answers quickly; slowness users feel is network/client-side." 'OK' }
        elseif ($r.P95 -lt 20) { Write-Verdict $msg 'WARN' } else { Write-Verdict "$msg The server itself is slow to answer (storage, AV, CPU)." 'BAD' }
    }
    $cli = @($rows | Where-Object { $_.Counter -match 'smb client shares\(.*\)\\avg\. sec/data request' -and $_.Counter -notmatch '_total' })
    if ($cli.Count -gt 0) { PerfMetric smb_client_p95_ms (($cli | Measure-Object P95 -Maximum).Maximum) ms; PerfMetric smb_client_avg_ms (($cli | Measure-Object Avg -Maximum).Maximum) ms }
    foreach ($r in $cli) {
        Write-Verdict ("SMB end-to-end time from this client {0}: avg {1} ms, P95 {2} ms. Subtract the server-side figure to get network/VPN time." -f $r.Counter, $r.Avg, $r.P95) 'OK'
    }
    $sent = $rows | Where-Object { $_.Counter -match 'tcpv4\\segments sent/sec' } | Select-Object -First 1
    $retr = $rows | Where-Object { $_.Counter -match 'tcpv4\\segments retransmitted/sec' } | Select-Object -First 1
    if ($sent -and $retr -and $sent.Avg -gt 0) {
        $pct = [math]::Round(100 * $retr.Avg / $sent.Avg, 2)
        PerfMetric tcp_retransmit_pct $pct pct
        if ($pct -lt 0.5) { Write-Verdict "TCP retransmits: $pct% of segments." 'OK' }
        elseif ($pct -lt 2) { Write-Verdict "TCP retransmits: $pct% of segments - some loss (VPN, Wi-Fi, MTU)." 'WARN' }
        else { Write-Verdict "TCP retransmits: $pct% of segments - significant loss; every retransmit stalls SMB." 'BAD' }
    }
    $cpu = $rows | Where-Object { $_.Counter -match 'processor\(_total\)\\% processor time' } | Select-Object -First 1
    if ($cpu) {
        PerfMetric cpu_p95_pct $cpu.P95 pct
        if ($cpu.P95 -gt 85) { Write-Verdict ("CPU P95 {0}% - CPU-bound (check VBS, AV scanning, vCPU count)." -f $cpu.P95) 'BAD' }
        else { Write-Verdict ("CPU P95 {0}%." -f $cpu.P95) 'OK' }
    }
}

try {
if ($Summarize) {
    if (-not (Test-Path -LiteralPath $Summarize)) { throw "Cannot find path $Summarize" }
    Show-Summary (Resolve-Path -LiteralPath $Summarize).ProviderPath
    return
}
Assert-KitAdmin
if ($PSVersionTable.PSEdition -eq 'Core') { Write-KitError 'Running in PowerShell 7: collection works, but the summary needs Windows PowerShell 5.1.' 'Start it with powershell.exe (not pwsh), or later run: powershell -File .\Perf-Monitor.ps1 -Summarize <file.blg>' }

$common = @('\Processor(_Total)\% Processor Time', '\Processor(_Total)\% Privileged Time', '\System\Processor Queue Length',
    '\Memory\Available MBytes', '\Network Interface(*)\Bytes Total/sec', '\TCPv4\Segments Sent/sec', '\TCPv4\Segments Retransmitted/sec')
$serverSet = @('\LogicalDisk(*)\Avg. Disk sec/Read', '\LogicalDisk(*)\Avg. Disk sec/Write', '\LogicalDisk(*)\Disk Reads/sec',
    '\LogicalDisk(*)\Disk Writes/sec', '\LogicalDisk(*)\Current Disk Queue Length', '\SMB Server Shares(*)\*', '\SMB Server Sessions(*)\*')
$clientSet = @('\SMB Client Shares(*)\*', '\LogicalDisk(C:)\Avg. Disk sec/Read', '\LogicalDisk(C:)\Avg. Disk sec/Write')
$wanted = $common + $(if ($Role -eq 'Server') { $serverSet } else { $clientSet })

$counters = New-Object System.Collections.Generic.List[string]
foreach ($c in $wanted) {
    $set = ($c -split '\\')[1] -replace '\(.*\)$', ''
    if (Get-Counter -ListSet $set -ErrorAction SilentlyContinue) { $counters.Add($c) }
    else { Write-KitRecord 'INFO' $script:PerfCat 'counter_missing' "counter set '$set' not present - skipped (non-English Windows uses translated counter names)"; Write-Host "  counter set '$set' not present on this machine - skipped" }
}

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$name = "BottleneckKit_$Role"
$null = & logman stop $name 2>&1
$null = & logman delete $name 2>&1
$cfg = Join-Path $env:TEMP "$name-counters.txt"
Set-Content -Path $cfg -Value $counters -Encoding ASCII
$base = Join-Path $OutDir ("perf-{0}-{1}-{2}" -f $Role.ToLower(), $env:COMPUTERNAME, $ts)
$out = & logman create counter $name -cf $cfg -si $IntervalSeconds -f bin -o $base -ow 2>&1
if ($LASTEXITCODE -ne 0) {
    $txt = ($out | Out-String).Trim()
    $script:KitHint = 'Run elevated. If it says the collector exists, run: logman delete BottleneckKit_Server (or _Client).'
    throw "logman create failed: $txt"
}
$out = & logman start $name 2>&1
if ($LASTEXITCODE -ne 0) { $out | Out-String | Write-Host; $null = & logman delete $name 2>&1; throw 'logman start failed' }

$started = Get-Date
try {
    Write-Host ''
    Write-Host ">>> Recording ($Role, every $IntervalSeconds s). Have a user reproduce the slowness NOW:" -ForegroundColor Green
    Write-Host '>>> open the CaseWare engagement / TaxCycle return, navigate, save - note the clock time of each hang.' -ForegroundColor Green
    if ($Minutes -le 0) { $null = Read-Host '>>> Press Enter to stop' }
    else {
        $end = $started.AddMinutes($Minutes)
        while ((Get-Date) -lt $end) {
            $left = [int]($end - (Get-Date)).TotalSeconds
            Write-Progress -Activity 'Collecting performance counters' -Status "$left s left - reproduce the slowness now (Ctrl+C stops early; data is kept)" -PercentComplete ([math]::Max(0, [math]::Min(100, 100 * (1 - $left / ($Minutes * 60.0)))))
            Start-Sleep -Seconds 1
        }
        Write-Progress -Activity 'Collecting performance counters' -Completed
    }
} finally {
    $null = & logman stop $name 2>&1
    $null = & logman delete $name 2>&1
    Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue
    Write-Host 'Collector stopped and removed.'
}

$blg = Get-ChildItem -Path $OutDir -Filter ((Split-Path $base -Leaf) + '*.blg') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $blg) { throw "No .blg file found for $base" }
$csv = $blg.FullName -replace '\.blg$', '.csv'
$null = & relog $blg.FullName -f csv -o $csv -y 2>&1
Write-Host "Raw data: $($blg.FullName)  (and $csv)"
Show-Summary $blg.FullName
} catch {
    $script:KitFailed = $true
    $h = ''
    if (Get-Variable -Name KitHint -Scope Script -ErrorAction SilentlyContinue) { $h = $script:KitHint }
    Write-KitError $_.Exception.Message $h $_
} finally {
    Complete-KitLog
}
if ($script:KitFailed) { exit 1 }
