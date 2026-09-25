<#
.SYNOPSIS
    Small-file workload test that mimics CaseWare / TaxCycle style access (many small files).
.DESCRIPTION
    Run the SAME script at each layer and compare ms-per-file to see where time is lost:
      server-local    on the server, local path (D:\...)            -> NTFS + AV + virtual disk + ZFS
      server-loopback on the server, \\<server>\<share>             -> + SMB stack (signing etc.), no network
      lan-client      office PC,    \\<server>\<share>              -> + LAN + client-side AV
      vpn-client      remote PC over the VPN, \\<server>\<share>    -> + VPN latency
    Phases:  Create, Stat (per-file metadata query), OpenClose, Read, Modify (4 KB
    write-through + flush = a durable "commit"), Enumerate (folder listing), Delete.
    Stat / OpenClose / Read use disjoint quarters of the files, so one phase does not
    warm the client cache for the next.
    Modes:
      Full      create a private test set, run all phases, delete it (default)
      Seed      create a shared read-only test set once (run on the server, local path)
      ReadSeed  read-only phases against the shared set: a cold pass, then a warm pass
    -RealDataPath additionally times a READ-ONLY walk + read of an existing folder
    (e.g. one CaseWare engagement folder). Nothing is ever written there.
    Results are appended to results\smallfile-results.csv so all layers line up.
    Creates files only under <Path>\_smallfile_bench\.
.EXAMPLE
    .\SmallFile-Test.ps1 -Path D:\Shares\Data -Label server-local -DefenderAB
.EXAMPLE
    .\SmallFile-Test.ps1 -Path \\FS01\Data -Label lan-client
.EXAMPLE
    .\SmallFile-Test.ps1 -Path \\FS01\Data -Label vpn-client -Mode ReadSeed -RealDataPath '\\FS01\Data\CaseWare\ClientX'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label,
    [ValidateSet('Full', 'Seed', 'ReadSeed')][string]$Mode = 'Full',
    [int]$FileCount = 2000,
    [int]$Folders = 20,
    [int]$MinKB = 1,
    [int]$MaxKB = 64,
    [int]$ModifyCount = 200,
    [string]$RealDataPath,
    [int]$RealDataMaxFiles = 5000,
    [int]$RealDataMaxMB = 500,
    [switch]$DefenderAB,
    [switch]$KeepFiles,
    [string]$OutDir = (Join-Path $PSScriptRoot 'results')
)

$ErrorActionPreference = 'Continue'
$kitLib = Join-Path $PSScriptRoot 'lib\KitCommon.ps1'
if (-not (Test-Path -LiteralPath $kitLib)) { Write-Host "ERROR: $kitLib is missing - copy the whole 'windows' folder of the kit, not single scripts." -ForegroundColor Red; exit 2 }
. $kitLib
Initialize-KitLog 'SmallFile-Test' $OutDir $PSBoundParameters
$script:KitCat = "smallfile/$Label"
$script:KitHint = ''
function Fail([string]$Message, [string]$Hint) { $script:KitHint = $Hint; throw $Message }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$csvPath = Join-Path $OutDir 'smallfile-results.csv'
$Results = New-Object System.Collections.Generic.List[object]

$FM_Open = [System.IO.FileMode]::Open
$FM_CreateNew = [System.IO.FileMode]::CreateNew
$FA_Read = [System.IO.FileAccess]::Read
$FA_Write = [System.IO.FileAccess]::Write
$FA_RW = [System.IO.FileAccess]::ReadWrite
$FS_All = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
$FS_None = [System.IO.FileShare]::None
$FS_Read = [System.IO.FileShare]::Read
$FO_WT = [System.IO.FileOptions]::WriteThrough

# ------------------------------------------------------------------ helpers

function Measure-Rtt([string]$Target) {
    $res = [ordered]@{ PingAvgMs = $null; PingMinMs = $null; PingLossPct = $null; TcpConnectMs = $null }
    $ping = New-Object System.Net.NetworkInformation.Ping
    $times = New-Object System.Collections.Generic.List[double]; $lost = 0
    for ($i = 0; $i -lt 20; $i++) {
        try { $r = $ping.Send($Target, 2000); if ($r.Status -eq 'Success') { $times.Add($r.RoundtripTime) } else { $lost++ } } catch { $lost++ }
        Start-Sleep -Milliseconds 50
    }
    if ($times.Count -gt 0) {
        $res.PingAvgMs = [math]::Round(($times | Measure-Object -Average).Average, 1)
        $res.PingMinMs = ($times | Measure-Object -Minimum).Minimum
    }
    $res.PingLossPct = [math]::Round(100 * $lost / 20, 0)
    $tt = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt 10; $i++) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $iar = $c.BeginConnect($Target, 445, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(3000)) { $c.EndConnect($iar); $sw.Stop(); $tt.Add($sw.Elapsed.TotalMilliseconds) }
        } catch { } finally { $c.Close() }
    }
    if ($tt.Count -gt 0) { $res.TcpConnectMs = [math]::Round(($tt | Measure-Object -Average).Average, 2) }
    [pscustomobject]$res
}

function Get-SmbInfo([string]$Target) {
    $info = [pscustomobject]@{ Dialect = $null; Signed = $null; Encrypted = $null }
    try {
        $c = Get-SmbConnection -ServerName $Target -ErrorAction Stop | Select-Object -First 1
        if ($c) {
            $n = $c.PSObject.Properties.Name
            $info.Dialect = $c.Dialect
            if ($n -contains 'Signed') { $info.Signed = $c.Signed }
            if ($n -contains 'Encrypted') { $info.Encrypted = $c.Encrypted }
        }
    } catch { }
    $info
}

function Add-Result([string]$Phase, [int]$Ops, [double]$Seconds, [int64]$Bytes, [string]$Lab) {
    $ms = 0.0
    if ($Ops -gt 0) { $ms = 1000.0 * $Seconds / $Ops }
    $rtPerOp = $null
    if ($script:Rtt -and $script:Rtt -gt 0 -and $Phase -notmatch 'Enumerate') { $rtPerOp = [math]::Round($ms / $script:Rtt, 1) }
    $script:Results.Add([pscustomobject]@{
            Timestamp       = (Get-Date).ToString('s')
            Computer        = $env:COMPUTERNAME
            Label           = $Lab
            Mode            = $Mode
            Path            = $Path
            Phase           = $Phase
            Files           = $Ops
            MB              = [math]::Round($Bytes / 1MB, 1)
            Seconds         = [math]::Round($Seconds, 2)
            OpsPerSec       = [math]::Round($Ops / [math]::Max($Seconds, 0.000001), 1)
            MsPerOp         = [math]::Round($ms, 3)
            RttMs           = $script:Rtt
            PingLossPct     = $script:Net.PingLossPct
            RoundTripsPerOp = $rtPerOp
            Dialect         = $script:Smb.Dialect
            Signed          = $script:Smb.Signed
            Encrypted       = $script:Smb.Encrypted
        })
    Write-KitRecord 'METRIC' "smallfile/$Lab" "$Phase.ms_per_file" ("{0} files" -f $Ops) ([math]::Round($ms, 3)) 'ms'
    if ($null -ne $rtPerOp) { Write-KitRecord 'METRIC' "smallfile/$Lab" "$Phase.roundtrips_per_file" '' $rtPerOp 'x' }
    Write-Host ("    {0,-24} {1,6} files  {2,8:N2} s  {3,9:N3} ms/file" -f $Phase, $Ops, $Seconds, $ms)
}

function Get-Subset($Files, [int]$Quarter) {
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = $Quarter; $i -lt $Files.Count; $i += 4) { $out.Add($Files[$i]) }
    , $out
}

function New-TestSet([string]$Root, [int]$Count) {
    $rng = New-Object System.Random 4242
    $buf = New-Object byte[] ($MaxKB * 1024)
    $rng.NextBytes($buf)
    for ($f = 0; $f -lt $Folders; $f++) { [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($Root, ('d{0:D3}' -f $f))) }
    $list = New-Object System.Collections.Generic.List[string]
    $bytes = [int64]0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Count; $i++) {
        $size = [int](($MinKB + ($MaxKB - $MinKB) * [math]::Pow($rng.NextDouble(), 3)) * 1024)
        $file = [System.IO.Path]::Combine($Root, ('d{0:D3}' -f ($i % $Folders)), ('f{0:D6}.dat' -f $i))
        $fs = [System.IO.FileStream]::new($file, $FM_CreateNew, $FA_Write, $FS_None, 65536)
        try { $fs.Write($buf, 0, $size) } finally { $fs.Dispose() }
        $list.Add($file); $bytes += $size
    }
    $sw.Stop()
    @{ Files = $list; Seconds = $sw.Elapsed.TotalSeconds; Bytes = $bytes }
}

function Invoke-Stat($Files) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $Files) { [void][System.IO.File]::GetLastWriteTimeUtc($f) }
    $sw.Stop(); $sw.Elapsed.TotalSeconds
}

function Invoke-OpenClose($Files) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $Files) { try { $fs = [System.IO.FileStream]::new($f, $FM_Open, $FA_Read, $FS_All, 4096); $fs.Dispose() } catch { } }
    $sw.Stop(); $sw.Elapsed.TotalSeconds
}

function Invoke-Read($Files, [int64]$MaxBytes = [int64]::MaxValue) {
    $buf = New-Object byte[] 65536; $total = [int64]0; $n = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $Files) {
        try {
            $fs = [System.IO.FileStream]::new($f, $FM_Open, $FA_Read, $FS_All, 65536)
            try { while (($r = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $total += $r } } finally { $fs.Dispose() }
            $n++
        } catch { }
        if ($total -ge $MaxBytes) { break }
    }
    $sw.Stop()
    @{ Seconds = $sw.Elapsed.TotalSeconds; Bytes = $total; Count = $n }
}

function Invoke-Modify($Files) {
    $buf = New-Object byte[] 4096
    (New-Object System.Random 7).NextBytes($buf)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $Files) {
        $fs = [System.IO.FileStream]::new($f, $FM_Open, $FA_RW, $FS_Read, 4096, $FO_WT)
        try { $fs.Write($buf, 0, $buf.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    }
    $sw.Stop(); $sw.Elapsed.TotalSeconds
}

function Invoke-Enumerate([string]$Root) {
    $n = 0; $bytes = [int64]0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $di = New-Object System.IO.DirectoryInfo $Root
    foreach ($fi in $di.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) { $n++; $bytes += $fi.Length }
    $sw.Stop()
    @{ Seconds = $sw.Elapsed.TotalSeconds; Bytes = $bytes; Count = $n }
}

function Invoke-Delete($Files, [string]$Root) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $Files) { try { [System.IO.File]::Delete($f) } catch { } }
    $sw.Stop()
    try { [System.IO.Directory]::Delete($Root, $true) } catch { }
    $sw.Elapsed.TotalSeconds
}

function Invoke-ReadPhases($Files, [string]$Root, [string]$Suffix, [string]$Lab) {
    $A = Get-Subset $Files 0; $B = Get-Subset $Files 1; $C = Get-Subset $Files 2
    Add-Result "Stat$Suffix" $A.Count (Invoke-Stat $A) 0 $Lab
    Add-Result "OpenClose$Suffix" $B.Count (Invoke-OpenClose $B) 0 $Lab
    $r = Invoke-Read $C
    Add-Result "Read$Suffix" $r.Count $r.Seconds $r.Bytes $Lab
    $e = Invoke-Enumerate $Root
    Add-Result "Enumerate$Suffix" $e.Count $e.Seconds $e.Bytes $Lab
}

function Invoke-FullRun([string]$Lab) {
    $safe = $Lab -replace '[^\w\-\+]', '_'
    $root = [System.IO.Path]::Combine($script:BenchRoot, ("{0}-{1}-{2}" -f $safe, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')))
    [void][System.IO.Directory]::CreateDirectory($root)
    Write-Host ""
    Write-Host "  [$Lab] Full run in $root ($FileCount files, $MinKB-$MaxKB KB, $Folders folders)"
    try {
        $c = New-TestSet $root $FileCount
        Add-Result 'Create' $FileCount $c.Seconds $c.Bytes $Lab
        Invoke-ReadPhases $c.Files $root '' $Lab
        $D = New-Object System.Collections.Generic.List[string]
        foreach ($f in (Get-Subset $c.Files 3)) { if ($D.Count -ge $ModifyCount) { break }; $D.Add($f) }
        Add-Result 'Modify-WriteThrough' $D.Count (Invoke-Modify $D) ([int64]4096 * $D.Count) $Lab
        if (-not $KeepFiles) { Add-Result 'Delete' $c.Files.Count (Invoke-Delete $c.Files $root) 0 $Lab }
    } catch {
        Write-Warning "Run failed: $($_.Exception.Message)"
    } finally {
        if (-not $KeepFiles -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-FileListSafe([string]$Root, [int]$Max) {
    $list = New-Object System.Collections.Generic.List[string]; $bytes = [int64]0; $dirs = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($stack.Count -gt 0 -and $list.Count -lt $Max) {
        $d = $stack.Pop(); $dirs++
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($fi in $di.EnumerateFiles()) { $list.Add($fi.FullName); $bytes += $fi.Length; if ($list.Count -ge $Max) { break } }
            foreach ($s in $di.EnumerateDirectories()) { if (-not ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) } }
        } catch { }
    }
    $sw.Stop()
    @{ Files = $list; Seconds = $sw.Elapsed.TotalSeconds; Bytes = $bytes; Dirs = $dirs }
}

# ------------------------------------------------------------------ setup
try {
if (-not (Test-Path -LiteralPath $Path)) {
    if ($Path.StartsWith('\\')) { Fail "Share not reachable: $Path" 'Check the \\server\share spelling, that the VPN is connected, and that the share opens in Explorer (log in as DOMAIN\user). Do not run this elevated on a client: elevated sessions do not see the user''s connections.' }
    else { Fail "Path not found: $Path" 'Check the drive letter and folder name (e.g. D:\Shares\Data).' }
}
$isUnc = $Path.StartsWith('\\')
$server = $null
if ($isUnc -and $Path -match '^\\\\([^\\]+)\\') { $server = $Matches[1] }
$script:BenchRoot = [System.IO.Path]::Combine($Path, '_smallfile_bench')
$seedRoot = [System.IO.Path]::Combine($script:BenchRoot, 'seed')

$script:Net = [pscustomobject]@{ PingAvgMs = $null; PingMinMs = $null; PingLossPct = $null; TcpConnectMs = $null }
$script:Rtt = $null
if ($server) {
    Write-Host "Measuring latency to $server (20 pings + 10 TCP/445 connects) ..."
    $script:Net = Measure-Rtt $server
    $script:Rtt = $script:Net.TcpConnectMs
    if (-not $script:Rtt) { $script:Rtt = $script:Net.PingAvgMs }
    $script:Smb = Get-SmbInfo $server
} else {
    $script:Smb = [pscustomobject]@{ Dialect = 'local'; Signed = $null; Encrypted = $null }
}

if ($isUnc -and $script:Rtt -and $script:Rtt -gt 10 -and $Mode -ne 'ReadSeed' -and -not $PSBoundParameters.ContainsKey('FileCount')) {
    $FileCount = 500
    $ModifyCount = [math]::Min($ModifyCount, 100)
    Write-Host "High latency ($($script:Rtt) ms): using -FileCount 500 to keep the run short (ms per file stays comparable)."
}

Write-Host ""
Write-Host ("SmallFile-Test  label={0}  mode={1}  path={2}" -f $Label, $Mode, $Path)
Write-Host ("  computer={0}  RTT(TCP 445)={1} ms  ping avg={2} ms  loss={3}%  SMB dialect={4} signed={5} encrypted={6}" -f $env:COMPUTERNAME, $script:Net.TcpConnectMs, $script:Net.PingAvgMs, $script:Net.PingLossPct, $script:Smb.Dialect, $script:Smb.Signed, $script:Smb.Encrypted)
Write-KitFact path_type $(if ($isUnc) { 'UNC' } else { 'local' }); Write-KitFact mode $Mode
Write-KitFact smb_dialect $script:Smb.Dialect; Write-KitFact smb_signed $script:Smb.Signed; Write-KitFact smb_encrypted $script:Smb.Encrypted
if ($script:Rtt) { Write-KitMetric rtt_ms $script:Rtt ms 'TCP 445 connect'; Write-KitMetric ping_loss_pct $script:Net.PingLossPct pct }
try { [void][System.IO.Directory]::CreateDirectory($script:BenchRoot) }
catch { Fail "Cannot create $($script:BenchRoot): $($_.Exception.Message)" 'You need write (Modify) permission on the share AND in NTFS for this folder. On the server, use an elevated window.' }

# ------------------------------------------------------------------ run
switch ($Mode) {
    'Seed' {
        if (Test-Path -LiteralPath $seedRoot) { Fail "A seed set already exists at $seedRoot." 'Delete that folder first, or use -Mode ReadSeed to read the existing set.' }
        [void][System.IO.Directory]::CreateDirectory($seedRoot)
        Write-Host "  Creating shared seed set: $FileCount files in $seedRoot"
        $c = New-TestSet $seedRoot $FileCount
        Add-Result 'Seed-Create' $FileCount $c.Seconds $c.Bytes $Label
        @("FileCount=$FileCount", "Folders=$Folders", "MinKB=$MinKB", "MaxKB=$MaxKB", "Created=$((Get-Date).ToString('s'))", "By=$env:COMPUTERNAME") |
            Set-Content -Path ([System.IO.Path]::Combine($seedRoot, '_manifest.txt')) -Encoding ASCII
        Write-Host "  Seed set ready. Clients can now run -Mode ReadSeed. Delete $seedRoot when finished."
    }
    'ReadSeed' {
        $manifest = [System.IO.Path]::Combine($seedRoot, '_manifest.txt')
        if (-not (Test-Path -LiteralPath $manifest)) { Fail "No seed set found at $seedRoot." 'Run  .\SmallFile-Test.ps1 -Path <local data path> -Label seed -Mode Seed  on the server first.' }
        $man = @{}
        Get-Content -LiteralPath $manifest | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { $man[$Matches[1]] = $Matches[2] } }
        $cnt = [int]$man['FileCount']; $fold = [int]$man['Folders']
        if ($PSBoundParameters.ContainsKey('FileCount')) { $cnt = [math]::Min($cnt, $FileCount) }
        $files = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $cnt; $i++) { $files.Add([System.IO.Path]::Combine($seedRoot, ('d{0:D3}' -f ($i % $fold)), ('f{0:D6}.dat' -f $i))) }
        Write-Host ""
        Write-Host "  [$Label] cold pass ($cnt seed files)"
        Invoke-ReadPhases $files $seedRoot '-cold' $Label
        Write-Host "  [$Label] warm pass (client caches populated)"
        Invoke-ReadPhases $files $seedRoot '-warm' $Label
    }
    'Full' {
        Invoke-FullRun $Label
        if ($DefenderAB) {
            if ($isUnc) { Write-Warning '-DefenderAB only works with a LOCAL path on the server; skipped.' }
            elseif (-not (Test-KitAdmin)) { Write-Warning '-DefenderAB needs an elevated PowerShell; skipped.' }
            else {
                try {
                    Add-MpPreference -ExclusionPath $script:BenchRoot -ErrorAction Stop
                    Write-Host "  Temporary Defender exclusion added for $($script:BenchRoot)"
                    Start-Sleep -Seconds 3
                    Invoke-FullRun ($Label + '+AVexcl')
                } catch { Write-Warning "Defender A/B failed: $($_.Exception.Message)" }
                finally {
                    Remove-MpPreference -ExclusionPath $script:BenchRoot -ErrorAction SilentlyContinue
                    Write-Host '  Temporary Defender exclusion removed.'
                }
            }
        }
    }
}

if ($RealDataPath) {
    Write-Host ""
    Write-Host "  [$Label] READ-ONLY real-data test: $RealDataPath (max $RealDataMaxFiles files / $RealDataMaxMB MB)"
    if (Test-Path -LiteralPath $RealDataPath) {
        $w = Get-FileListSafe $RealDataPath $RealDataMaxFiles
        Add-Result 'Real-Enumerate' $w.Files.Count $w.Seconds $w.Bytes "$Label-real"
        $A = Get-Subset $w.Files 0
        Add-Result 'Real-Stat' $A.Count (Invoke-Stat $A) 0 "$Label-real"
        $r = Invoke-Read $w.Files ([int64]$RealDataMaxMB * 1MB)
        Add-Result 'Real-Read' $r.Count $r.Seconds $r.Bytes "$Label-real"
    } else { Write-Warning "RealDataPath not reachable: $RealDataPath" }
}

# ------------------------------------------------------------------ output
if (($Mode -eq 'Full') -and -not $KeepFiles) {
    try { if (-not (Get-ChildItem -LiteralPath $script:BenchRoot -Force -ErrorAction Stop | Select-Object -First 1)) { Remove-Item -LiteralPath $script:BenchRoot -Force } } catch { }
}
Write-Host ""
$Results | Format-Table Label, Phase, Files, Seconds, OpsPerSec, MsPerOp, RoundTripsPerOp, Signed -AutoSize | Out-String -Width 200 | Write-Host
$Results | Export-Csv -Path $csvPath -NoTypeInformation -Append

$read = $Results | Where-Object { $_.Phase -in 'Read', 'Read-cold' } | Select-Object -First 1
if ($read) {
    Write-Host ("At this location, opening + reading 1,000 files like these takes about {0:N1} s." -f ($read.MsPerOp))
    if ($read.RoundTripsPerOp) {
        Write-Host ("Each file read costs about {0} network round trips of {1} ms." -f $read.RoundTripsPerOp, $script:Rtt)
        if ($script:Rtt -gt 5) { Write-Host 'Time per file is dominated by network round trips: faster disks cannot fix this; fewer round trips (app next to the data) can.' }
    }
}
Write-Host "Appended to $csvPath"
} catch {
    $script:KitFailed = $true
    if ($script:KitHint) { Write-KitError $_.Exception.Message $script:KitHint } else { Write-KitError $_.Exception.Message '' $_ }
} finally {
    Complete-KitLog
}
if ($script:KitFailed) { exit 1 }
