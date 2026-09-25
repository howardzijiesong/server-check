<#
.SYNOPSIS
    DiskSpd benchmark of the data disk from INSIDE the Windows VM.
.DESCRIPTION
    Writes a test file filled with incompressible data (so thin-zvol holes and ZFS
    compression cannot inflate the results), runs a fixed set of DiskSpd tests and
    prints IOPS, MB/s, average and 99th-percentile latency.

    Compare "4K random write, QD1, write-through" here with pve-bench.sh
    "zvol-<vbs>-randwrite-4k-qd1-sync" on the host: the difference is the cost of the
    virtualization layer (VirtIO controller, iothread, CPU type / VBS).
    Note: reads here can be served from the host's ZFS ARC (RAM) - that is real-world
    behaviour for hot files, but it is not a flash measurement.

    Run while users are off the system. Needs about FileSizeGB + 20% free space.
.EXAMPLE
    .\Server-DiskBench.ps1 -TestPath D:\_bench
.EXAMPLE
    .\Server-DiskBench.ps1 -TestPath D:\_bench -Quick
.EXAMPLE
    .\Server-DiskBench.ps1 -TestPath E:\_bench -Label hdd-native -Quick     # the directly attached NTFS HDD
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TestPath,
    [string]$Label,
    [string]$DiskSpdPath,
    [int]$Duration = 30,
    [int]$FileSizeGB = 4,
    [switch]$Quick,
    [switch]$KeepTestFile,
    [string]$OutDir = (Join-Path $PSScriptRoot 'results')
)

$ErrorActionPreference = 'Continue'   # native-exe stderr + 'Stop' is fatal in Windows PowerShell 5.1
$kitLib = Join-Path $PSScriptRoot 'lib\KitCommon.ps1'
if (-not (Test-Path -LiteralPath $kitLib)) { Write-Host "ERROR: $kitLib is missing - copy the whole 'windows' folder of the kit, not single scripts." -ForegroundColor Red; exit 2 }
. $kitLib
Initialize-KitLog 'Server-DiskBench' $OutDir $PSBoundParameters
Assert-KitAdmin

function Find-DiskSpd {
    if ($DiskSpdPath -and (Test-Path -LiteralPath $DiskSpdPath)) { return (Resolve-Path -LiteralPath $DiskSpdPath).ProviderPath }
    $all = @(Get-ChildItem -Path $PSScriptRoot -Recurse -Filter 'diskspd.exe' -ErrorAction SilentlyContinue)
    $pick = $all | Where-Object { $_.FullName -match '\\amd64\\' } | Select-Object -First 1
    if (-not $pick) { $pick = $all | Select-Object -First 1 }
    if ($pick) { return $pick.FullName }
    Write-Host 'diskspd.exe not found next to this script - downloading from https://aka.ms/getdiskspd ...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $env:TEMP 'DiskSpd.zip'
        Invoke-WebRequest -Uri 'https://aka.ms/getdiskspd' -OutFile $zip -UseBasicParsing
        $dest = Join-Path $env:TEMP 'diskspd'
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        $pick = Get-ChildItem -Path $dest -Recurse -Filter 'diskspd.exe' | Where-Object { $_.FullName -match '\\amd64\\' } | Select-Object -First 1
        if ($pick) { return $pick.FullName }
    } catch { Write-Warning "Download failed: $($_.Exception.Message)" }
    throw 'DiskSpd not available. Download DiskSpd.zip from https://github.com/microsoft/diskspd/releases, extract it into windows\tools\ next to this script and re-run.'
}

function Fmt($v, [int]$digits = 3) { if ($null -eq $v -or "$v" -eq '') { return '' } return [math]::Round([double]$v, $digits) }

try {
if ($TestPath.StartsWith('\\')) { throw 'Run this ON the server against a local path (e.g. D:\_bench). Use SmallFile-Test.ps1 for network paths.' }
$diskspd = Find-DiskSpd
Write-Host "Using $diskspd"

New-Item -ItemType Directory -Path $TestPath -Force | Out-Null
$drive = (Get-Item -LiteralPath $TestPath).PSDrive.Name
$vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
if (-not $Label) { $Label = "vm-$drive" }
$script:KitCat = "diskbench/$Label"
Write-KitFact label $Label; Write-KitFact test_path $TestPath; Write-KitFact volume ("{0}: {1} {2:N0} GB free" -f $drive, $vol.FileSystemType, ($vol.SizeRemaining / 1GB))
$need = [int64]$FileSizeGB * 1GB * 1.2
if ($vol.SizeRemaining -lt $need) { throw ("Not enough free space on {0}: need {1:N1} GB" -f $drive, ($need / 1GB)) }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutDir ("diskbench-{0}-{1}" -f $env:COMPUTERNAME, $ts)
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$testFile = Join-Path $TestPath 'diskspd-testfile.dat'

# ---- prefill with incompressible data (DiskSpd -c may leave the file sparse/unwritten)
Write-Host ("Writing {0} GB of incompressible data to {1} ..." -f $FileSizeGB, $testFile)
$buf = New-Object byte[] (1MB)
(New-Object System.Random).NextBytes($buf)
$sw = [Diagnostics.Stopwatch]::StartNew()
$fs = New-Object System.IO.FileStream($testFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
try { for ($i = 0; $i -lt ($FileSizeGB * 1024); $i++) { $fs.Write($buf, 0, $buf.Length) }; $fs.Flush($true) } finally { $fs.Dispose() }
$sw.Stop()
Write-Host ("  done in {0:N1} s ({1:N0} MB/s buffered sequential write)" -f $sw.Elapsed.TotalSeconds, ($FileSizeGB * 1024 / $sw.Elapsed.TotalSeconds))

$tests = @(
    [pscustomobject]@{ Id = 'rr4k_qd1';     Name = '4K random read, QD1 (latency)';             Args = '-b4K -r -o1 -t1 -w0 -Sh' }
    [pscustomobject]@{ Id = 'rw4k_qd1_wt';  Name = '4K random write, QD1, write-through (sync)'; Args = '-b4K -r -o1 -t1 -w100 -Sh' }
    [pscustomobject]@{ Id = 'rw4k_qd1_c';   Name = '4K random write, QD1, no FUA (async)';      Args = '-b4K -r -o1 -t1 -w100 -Su' }
    [pscustomobject]@{ Id = 'rrw4k_qd8x4';  Name = '4K random 70/30, QD8 x 4 threads';          Args = '-b4K -r -o8 -t4 -w30 -Sh' }
    [pscustomobject]@{ Id = 'rrw64k_qd4x2'; Name = '64K random 70/30, QD4 x 2 threads';         Args = '-b64K -r -o4 -t2 -w30 -Sh' }
    [pscustomobject]@{ Id = 'sr1m_qd8';     Name = '1M sequential read, QD8';                   Args = '-b1M -o8 -t1 -w0 -Sh' }
    [pscustomobject]@{ Id = 'sw1m_qd8';     Name = '1M sequential write, QD8';                  Args = '-b1M -o8 -t1 -w100 -Sh' }
)
if ($Quick) {
    $Duration = 15
    $tests = @($tests | Where-Object { $_.Id -in 'rr4k_qd1', 'rw4k_qd1_wt', 'rw4k_qd1_c', 'rrw4k_qd8x4' })
}
Write-Host ("Running {0} tests x ({1} s + 5 s warm-up) ..." -f $tests.Count, $Duration)

$rows = New-Object System.Collections.Generic.List[object]
try {
    foreach ($t in $tests) {
        Write-Host ("  {0,-44}" -f $t.Name) -NoNewline
        $argList = @($t.Args -split ' ') + @("-d$Duration", '-W5', '-C2', '-L', '-Z1M', '-Rxml', $testFile)
        $errFile = Join-Path $runDir "$($t.Id).err"
        $out = & $diskspd @argList 2> $errFile
        $xmlText = ($out | Out-String)
        Set-Content -Path (Join-Path $runDir "$($t.Id).xml") -Value $xmlText -Encoding UTF8
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -or $xmlText -notmatch '<Results') {
            $errText = ((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) -join ' ').Trim()
            Write-Host ' FAILED'
            $hint = 'See the .err and .xml files in the results folder.'
            if ($errText -match 'Access is denied|privilege') { $hint = 'Run elevated; antivirus/EDR may also block diskspd.exe - allow it temporarily.' }
            elseif ($errText -match 'not enough space|disk.*full') { $hint = 'Not enough free space - use -FileSizeGB 2.' }
            elseif ($errText -match 'cannot find|not found') { $hint = 'Test file missing - is -TestPath on a local, writable volume?' }
            Write-KitError ("DiskSpd test '{0}' failed (exit {1}) {2}" -f $t.Name, $exitCode, $errText) $hint
            continue
        }
        try { [xml]$x = $xmlText } catch { Write-KitError "Could not parse DiskSpd output for '$($t.Name)'" 'See the .xml file in the results folder.' $_; continue }
        $span = $x.Results.TimeSpan
        $secs = [double]$span.TestTimeSeconds
        $rb = 0.0; $rc = 0.0; $wb = 0.0; $wc = 0.0
        foreach ($th in @($span.Thread)) { foreach ($tg in @($th.Target)) { $rb += [double]$tg.ReadBytes; $rc += [double]$tg.ReadCount; $wb += [double]$tg.WriteBytes; $wc += [double]$tg.WriteCount } }
        $lat = $span.Latency
        $p99 = @($lat.Bucket) | Where-Object { $_.Percentile -eq '99' } | Select-Object -First 1
        $row = [pscustomobject]@{
            Id         = $t.Id
            Test       = $t.Name
            IOPS       = [math]::Round(($rc + $wc) / [math]::Max($secs, 0.001), 0)
            MBps       = [math]::Round(($rb + $wb) / 1MB / [math]::Max($secs, 0.001), 1)
            ReadAvgMs  = Fmt $lat.AverageReadMilliseconds
            ReadP99Ms  = Fmt $p99.ReadMilliseconds
            WriteAvgMs = Fmt $lat.AverageWriteMilliseconds
            WriteP99Ms = Fmt $p99.WriteMilliseconds
            CpuPct     = Fmt $span.CpuUtilization.Average.UsagePercent 1
        }
        $rows.Add($row)
        foreach ($f in 'IOPS', 'MBps', 'ReadAvgMs', 'ReadP99Ms', 'WriteAvgMs', 'WriteP99Ms') { if ("$($row.$f)" -ne '') { Write-KitMetric ("{0}.{1}" -f $t.Id, $f) $row.$f } }
        Write-Host (" {0,9:N0} IOPS {1,8:N1} MB/s  rd avg {2} ms p99 {3} ms  wr avg {4} ms p99 {5} ms" -f $row.IOPS, $row.MBps, $row.ReadAvgMs, $row.ReadP99Ms, $row.WriteAvgMs, $row.WriteP99Ms)
    }
} finally {
    if (-not $KeepTestFile) { Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue }
}

$rows | Format-Table Test, IOPS, MBps, ReadAvgMs, ReadP99Ms, WriteAvgMs, WriteP99Ms, CpuPct -AutoSize | Out-String -Width 200 | Write-Host
$rows | Export-Csv -Path (Join-Path $runDir 'diskbench.csv') -NoTypeInformation

# ---- interpretation
$rr = $rows | Where-Object Id -eq 'rr4k_qd1'
$wt = $rows | Where-Object Id -eq 'rw4k_qd1_wt'
$wc = $rows | Where-Object Id -eq 'rw4k_qd1_c'
Write-Host 'Interpretation (NVMe-backed virtual disk):'
if ($wt -and $wt.WriteAvgMs -ne '') {
    $v = [double]$wt.WriteAvgMs
    $verdict = 'poor - storage/virtualization layer is slowing every durable write'
    if ($v -lt 0.3) { $verdict = 'excellent' } elseif ($v -lt 1) { $verdict = 'good' } elseif ($v -lt 3) { $verdict = 'fair' }
    Write-Host ("  4K write-through (sync) latency: {0} ms -> {1}" -f $v, $verdict)
    if ($wc -and $wc.WriteAvgMs -ne '' -and [double]$wc.WriteAvgMs -gt 0) {
        Write-Host ("  Sync writes cost {0:N1}x an async write (ZFS intent log + flush path)." -f ($v / [double]$wc.WriteAvgMs))
    }
}
if ($rr -and $rr.ReadAvgMs -ne '') {
    $v = [double]$rr.ReadAvgMs
    $verdict = 'slow for NVMe'
    if ($v -lt 0.2) { $verdict = 'excellent' } elseif ($v -lt 0.5) { $verdict = 'good' } elseif ($v -lt 1.5) { $verdict = 'fair' }
    Write-Host ("  4K random read latency: {0} ms -> {1}" -f $v, $verdict)
}
Write-Host '  Context: one SMB round trip over a typical VPN is 15-50 ms, i.e. 50-500x these disk latencies.'
Write-Host "Results: $runDir"
} catch {
    $script:KitFailed = $true
    Write-KitError $_.Exception.Message '' $_
} finally {
    Complete-KitLog
}
if ($script:KitFailed) { exit 1 }
