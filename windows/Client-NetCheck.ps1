<#
.SYNOPSIS
    Client-side network + SMB check: run on an office PC (LAN) and on a remote PC (VPN).
.DESCRIPTION
    Measures latency/jitter/loss to the file server, TCP 445 connect time, path MTU
    (detects VPN MTU "black holes" that make larger SMB transfers stall), which interface
    the traffic uses, the OpenVPN adapter type (legacy TAP vs DCO), SMB client settings,
    negotiated SMB dialect / signing / encryption, Kerberos vs NTLM, mapped drives,
    Offline Files and client antivirus. Makes NO changes.
    Run it NON-elevated (normal user PowerShell) so the user's mapped drives are visible.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Client-NetCheck.ps1 -Server FS01 -Share Data
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$Share,
    [string]$Label,          # lan / vpn (auto-detected from the route if omitted)
    [int]$PingCount = 50,
    [string]$OutDir = (Join-Path $PSScriptRoot 'results')
)

$ErrorActionPreference = 'Continue'
$kitLib = Join-Path $PSScriptRoot 'lib\KitCommon.ps1'
if (-not (Test-Path -LiteralPath $kitLib)) { Write-Host "ERROR: $kitLib is missing - copy the whole 'windows' folder of the kit, not single scripts." -ForegroundColor Red; exit 2 }
. $kitLib
Initialize-KitLog 'Client-NetCheck' $OutDir $PSBoundParameters
$report = $script:KitLog
Start-Transcript -Path $report | Out-Null
trap { Write-KitError "Step failed: $($_.Exception.Message)" '' $_; continue }
$script:NcLabel = $Label
function NcMetric([string]$Key, $Value, [string]$Unit = '') { Write-KitRecord 'METRIC' "netcheck/$($script:NcLabel)" $Key '' $Value $Unit }
function NcFact([string]$Key, $Value) { Write-KitRecord 'FACT' "netcheck/$($script:NcLabel)" $Key '' $Value }

function Get-PingStats([string]$Target, [int]$Count, [int]$Size) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $buf = New-Object byte[] $Size
    $opt = New-Object System.Net.NetworkInformation.PingOptions(64, $false)
    $t = New-Object System.Collections.Generic.List[double]; $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try { $r = $p.Send($Target, 2000, $buf, $opt); if ($r.Status -eq 'Success') { $t.Add($r.RoundtripTime) } else { $lost++ } } catch { $lost++ }
        Start-Sleep -Milliseconds 100
    }
    $o = [ordered]@{ Size = $Size; Sent = $Count; LossPct = [math]::Round(100 * $lost / $Count, 1); MinMs = $null; AvgMs = $null; MaxMs = $null; JitterMs = $null }
    if ($t.Count -gt 0) {
        $m = $t | Measure-Object -Average -Minimum -Maximum
        $o.MinMs = $m.Minimum; $o.AvgMs = [math]::Round($m.Average, 1); $o.MaxMs = $m.Maximum
        $var = ($t | ForEach-Object { ($_ - $m.Average) * ($_ - $m.Average) } | Measure-Object -Average).Average
        $o.JitterMs = [math]::Round([math]::Sqrt($var), 1)
    }
    [pscustomobject]$o
}

function Find-PathMtu([string]$Target) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $opt = New-Object System.Net.NetworkInformation.PingOptions(64, $true)
    $lo = 548; $hi = 1472; $best = $null; $failStatus = $null
    while ($lo -le $hi) {
        $mid = [int][math]::Floor(($lo + $hi) / 2)
        $ok = $false; $st = $null
        for ($k = 0; $k -lt 2 -and -not $ok; $k++) {
            try { $r = $p.Send($Target, 1500, (New-Object byte[] $mid), $opt); $st = [string]$r.Status; if ($st -eq 'Success') { $ok = $true } } catch { $st = 'Exception' }
        }
        if ($ok) { $best = $mid; $lo = $mid + 1 } else { $failStatus = $st; $hi = $mid - 1 }
    }
    $mtu = $null
    if ($best) { $mtu = $best + 28 }
    [pscustomobject]@{ MaxPayload = $best; PathMtu = $mtu; FirstFailureStatus = $failStatus }
}

function Measure-TcpConnect([string]$Target, [int]$Port, [int]$Count) {
    $tt = New-Object System.Collections.Generic.List[double]; $fail = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $iar = $c.BeginConnect($Target, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(3000)) { $c.EndConnect($iar); $sw.Stop(); $tt.Add($sw.Elapsed.TotalMilliseconds) } else { $fail++ }
        } catch { $fail++ } finally { $c.Close() }
    }
    $avg = $null
    if ($tt.Count -gt 0) { $avg = [math]::Round(($tt | Measure-Object -Average).Average, 2) }
    [pscustomobject]@{ Port = $Port; Attempts = $Count; Failed = $fail; AvgConnectMs = $avg }
}

try {
# ------------------------------------------------------------------ CLIENT
Section 'CLIENT'
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host ("{0} {1} (build {2}.{3})   computer {4}   user {5}\{6}" -f $os.Caption, $cv.DisplayVersion, $os.BuildNumber, $cv.UBR, $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME)
if ([int]$os.BuildNumber -ge 26100) { Write-Host 'Windows 11 24H2 or later: SMB signing is required on all outbound connections by default.' }
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($elevated) { Write-Host 'NOTE: running elevated - mapped drives of the normal user session may not be visible.' -ForegroundColor Yellow }

# ------------------------------------------------------------------ NAME + ROUTE
Section "NAME RESOLUTION AND ROUTE TO $Server"
$sw = [Diagnostics.Stopwatch]::StartNew()
$ips = @()
try { $ips = @(Resolve-DnsName -Name $Server -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress) }
catch { try { $ips = @([System.Net.Dns]::GetHostAddresses($Server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { } }
$sw.Stop()
Write-Host ("Resolved {0} -> {1}  in {2:N0} ms" -f $Server, ($ips -join ', '), $sw.Elapsed.TotalMilliseconds)
if ($ips.Count -eq 0) { Add-Finding 'WARN' "Cannot resolve '$Server'. Over VPN this usually means the VPN does not push the office DNS server / AD domain suffix (split DNS)."; $ips = @($Server) }
if ($ips.Count -gt 1) { Add-Finding 'INFO' "'$Server' resolves to several addresses ($($ips -join ', ')). If one is unreachable from here (a second NIC or VPN adapter registered in DNS), connections stall while Windows tries it first." }
if ($sw.Elapsed.TotalMilliseconds -gt 500) { Add-Finding 'INFO' ("Name resolution took {0:N0} ms; slow DNS over the VPN delays every new connection." -f $sw.Elapsed.TotalMilliseconds) }
$ip = $ips[0]
$ifMtu = $null
$routeAdapter = ''
try {
    $fr = @(Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop)
    $rt = $fr | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
    $src = $fr | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetIPAddress' } | Select-Object -First 1
    if ($rt) {
        $ifMtu = (Get-NetIPInterface -InterfaceIndex $rt.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu
        Write-Host ("Traffic to {0} leaves via '{1}' (source {2}, next hop {3}, interface MTU {4})" -f $ip, $rt.InterfaceAlias, $src.IPAddress, $rt.NextHop, $ifMtu)
        $ad = Get-NetAdapter -InterfaceIndex $rt.InterfaceIndex -IncludeHidden -ErrorAction SilentlyContinue
        if ($ad) {
            $routeAdapter = $ad.InterfaceDescription
            Write-Host ("Adapter: {0}  link {1}" -f $ad.InterfaceDescription, $ad.LinkSpeed)
            if ($ad.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11') { Add-Finding 'INFO' 'This PC reaches the server over Wi-Fi: extra latency, jitter and retransmissions compared with a cable.' }
            if ([string]$ad.LinkSpeed -match '^(10|100) Mbps') { Add-Finding 'WARN' "The adapter used to reach the server is linked at $($ad.LinkSpeed)." }
            if ($ad.InterfaceDescription -match 'TAP-Windows') { Add-Finding 'WARN' 'Traffic uses the legacy OpenVPN TAP-Windows adapter (userspace data path). OpenVPN 2.6+ with the DCO driver (UDP, AES-GCM or ChaCha20-Poly1305, topology subnet, no compression) is much faster - the server must support it too.' }
            elseif ($ad.InterfaceDescription -match 'Wintun') { Add-Finding 'INFO' 'Traffic uses the Wintun adapter. If this is OpenVPN, the DCO driver is the faster option (needs OpenVPN 2.6+ on both ends, AEAD cipher, no compression).' }
            elseif ($ad.InterfaceDescription -match 'Data Channel Offload|ovpn-dco') { Write-Host 'OpenVPN Data Channel Offload driver in use (good).' }
        }
    }
} catch { Write-Host "Find-NetRoute failed: $($_.Exception.Message)" }
if (-not $script:NcLabel) {
    $script:NcLabel = 'lan'
    if ("$routeAdapter $($rt.InterfaceAlias)" -match 'WireGuard|Wintun|TAP-Windows|OpenVPN|Data Channel Offload|Fortinet|FortiClient|SonicWall|PANGP|GlobalProtect|AnyConnect|WatchGuard|Tailscale|ZeroTier|Zscaler|PPP|VPN') { $script:NcLabel = 'vpn' }
    Write-Host "Location label (auto): $($script:NcLabel)   (override with -Label)"
}
NcFact server $Server; NcFact server_ip $ip; NcFact route_adapter $routeAdapter; NcFact if_mtu $ifMtu; NcFact os_build $os.BuildNumber
NcMetric dns_ms ([math]::Round($sw.Elapsed.TotalMilliseconds, 0)) ms

# ------------------------------------------------------------------ LATENCY
Section 'LATENCY, JITTER, LOSS'
$small = Get-PingStats $ip $PingCount 32
$large = Get-PingStats $ip ([math]::Min($PingCount, 20)) 1200
Show @($small, $large)
$tcp = Measure-TcpConnect $ip 445 10
Show $tcp
if ($tcp.Failed -eq $tcp.Attempts) { Add-Finding 'WARN' 'TCP port 445 (SMB) is not reachable from here.' }
$rtt = $tcp.AvgConnectMs
if (-not $rtt) { $rtt = $small.AvgMs }
NcMetric rtt_ms $rtt ms; NcMetric ping_avg_ms $small.AvgMs ms; NcMetric ping_loss_pct $small.LossPct pct; NcMetric jitter_ms $small.JitterMs ms; NcMetric ping1200_avg_ms $large.AvgMs ms
NcFact tcp445_reachable ($tcp.Failed -lt $tcp.Attempts)
if ($small.LossPct -gt 0) { Add-Finding 'WARN' ("{0}% packet loss to the server. Each loss forces a TCP retransmission; SMB stalls for hundreds of ms each time (far worse if the VPN itself runs over TCP)." -f $small.LossPct) }
if ($small.JitterMs -and $small.JitterMs -gt 10) { Add-Finding 'INFO' ("High jitter ({0} ms): unstable path (Wi-Fi, congested uplink, or a CPU-bound VPN endpoint)." -f $small.JitterMs) }
if ($large.AvgMs -and $small.AvgMs -and ($large.AvgMs - $small.AvgMs) -gt 15) { Add-Finding 'INFO' ("1200-byte pings are {0:N0} ms slower than small ones: a narrow or congested link somewhere on the path (often the office upload)." -f ($large.AvgMs - $small.AvgMs)) }
if ($rtt) {
    Write-Host ("Round trip ~{0} ms. A small-file open/read/close costs roughly 2-4 SMB round trips, so 1,000 such files spend about {1:N0}-{2:N0} s just waiting on the network." -f $rtt, ($rtt * 2), ($rtt * 4))
}

# ------------------------------------------------------------------ MTU
Section 'PATH MTU (DF-bit ping search)'
$pm = Find-PathMtu $ip
Show $pm
NcMetric path_mtu $pm.PathMtu bytes
NcFact pmtu_blackhole ([bool]($pm.PathMtu -and $ifMtu -and $pm.PathMtu -lt $ifMtu -and $pm.FirstFailureStatus -eq 'TimedOut'))
if (-not $pm.PathMtu) {
    Write-Host 'ICMP appears blocked; path MTU could not be measured from here.'
} elseif ($ifMtu -and $pm.PathMtu -lt $ifMtu) {
    if ($pm.FirstFailureStatus -eq 'TimedOut') {
        Add-Finding 'WARN' ("Path MTU is {0} but the interface MTU is {1}, and oversized packets are silently DROPPED (no 'fragmentation needed' reply): a PMTU black hole. Symptom: small operations work, larger reads/writes hang. Fix: mssfix / MSS clamping on the VPN server or firewall, or lower the VPN adapter MTU." -f $pm.PathMtu, $ifMtu)
    } else {
        Add-Finding 'INFO' ("Path MTU is {0} (interface MTU {1}); 'packet too big' replies come back, so PMTU discovery can work. mssfix on the VPN is still recommended." -f $pm.PathMtu, $ifMtu)
    }
} else { Write-Host ("Full-size packets pass (path MTU {0})." -f $pm.PathMtu) }

# ------------------------------------------------------------------ SMB CLIENT
Section 'SMB CLIENT CONFIGURATION'
try {
    $cc = Get-SmbClientConfiguration -ErrorAction Stop
    Select-Existing $cc @('RequireSecuritySignature', 'EnableSecuritySignature', 'DirectoryCacheLifetime', 'FileInfoCacheLifetime', 'FileNotFoundCacheLifetime',
        'DirectoryCacheEntriesMax', 'FileInfoCacheEntriesMax', 'EnableLargeMtu', 'EnableBandwidthThrottling', 'EnableMultiChannel', 'RequestCompression',
        'SessionTimeout', 'ExtendedSessionTimeout', 'EnableInsecureGuestLogons') | Format-List | Out-String | Write-Host
    if ($cc.DirectoryCacheLifetime -eq 0) { Add-Finding 'WARN' 'SMB client directory cache is disabled (DirectoryCacheLifetime=0): every folder listing goes to the server.' }
    if ($cc.FileInfoCacheLifetime -eq 0) { Add-Finding 'WARN' 'SMB client file-info cache is disabled (FileInfoCacheLifetime=0): every metadata query goes to the server.' }
} catch { Write-Host "Get-SmbClientConfiguration failed: $($_.Exception.Message)" }

# ------------------------------------------------------------------ SMB SESSION
Section 'SMB CONNECTION TO THE SERVER'
if ($Share) {
    $unc = "\\$Server\$Share"
    $sw = [Diagnostics.Stopwatch]::StartNew(); $okShare = Test-Path -LiteralPath $unc; $sw.Stop()
    Write-Host ("Access {0}: {1} in {2:N0} ms (includes session setup/auth if this is the first connection)" -f $unc, $okShare, $sw.Elapsed.TotalMilliseconds)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Get-ChildItem -LiteralPath $unc -ErrorAction SilentlyContinue | Select-Object -First 200; $sw.Stop()
    Write-Host ("Listing the share root: {0:N0} ms" -f $sw.Elapsed.TotalMilliseconds)
}
try {
    $conn = @(Get-SmbConnection -ErrorAction Stop | Where-Object { $_.ServerName -like "$Server*" -or $_.ServerName -eq $ip })
    if ($conn.Count -gt 0) {
        Show (Select-Existing $conn @('ServerName', 'ShareName', 'UserName', 'Dialect', 'Signed', 'Encrypted', 'NumOpens', 'Redirected'))
        F smb_dialect $conn[0].Dialect; if ($conn[0].PSObject.Properties.Name -contains 'Signed') { NcFact smb_signed $conn[0].Signed }
        foreach ($c in $conn) { if ($c.Dialect -and ([string]$c.Dialect) -match '^(1|2\.0)') { Add-Finding 'WARN' "Connection to $($c.ShareName) negotiated old SMB dialect $($c.Dialect) (no leasing / large MTU)." } }
    } else { Write-Host 'No SMB connection to the server in this session (use -Share, or open the share first).' }
} catch { Write-Host "Get-SmbConnection failed (try an elevated prompt for this part): $($_.Exception.Message)" }

$short = $Server.Split('.')[0]
$kl = (klist 2>&1) -join "`n"
NcFact kerberos_ticket ([bool]($kl -match ("cifs/" + [regex]::Escape($short))))
if ($kl -match ("cifs/" + [regex]::Escape($short))) { Write-Host "Kerberos ticket for cifs/$short present -> Kerberos authentication." }
else { Add-Finding 'INFO' "No Kerberos ticket for cifs/$short. The client is probably using NTLM (mapped by IP address, name/SPN mismatch, or the domain controller not reachable/resolvable over the VPN). NTLM adds round trips per connection." }

# ------------------------------------------------------------------ MAPPINGS
Section 'MAPPED DRIVES'
$maps = @(Get-SmbMapping -ErrorAction SilentlyContinue)
if ($maps.Count -gt 0) {
    Show ($maps | Select-Object LocalPath, RemotePath, Status)
    foreach ($m in $maps) {
        if ($m.RemotePath -match '^\\\\\d{1,3}(\.\d{1,3}){3}\\') { Add-Finding 'INFO' "Drive $($m.LocalPath) is mapped by IP ($($m.RemotePath)): forces NTLM instead of Kerberos. Map by server name." }
    }
} else { Write-Host 'No mapped drives visible in this session.' }
try {
    $csc = Get-CimInstance -ClassName Win32_OfflineFilesCache -ErrorAction Stop
    Write-Host ("Offline Files: enabled={0} active={1}" -f $csc.Enabled, $csc.Active)
    if ($csc.Enabled) { Add-Finding 'INFO' 'Offline Files (CSC) is enabled on this client. Fine for documents on slow links, but not for multi-user CaseWare/TaxCycle data; make sure the data share is not made available offline.' }
} catch { }

# ------------------------------------------------------------------ AV
Section 'CLIENT ANTIVIRUS / EDR'
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Write-Host ("Defender: mode={0} realtime={1} tamperProtected={2}" -f $mp.AMRunningMode, $mp.RealTimeProtectionEnabled, $mp.IsTamperProtected)
    if ($mp.RealTimeProtectionEnabled -and [string]$mp.AMRunningMode -eq 'Normal') { Add-Finding 'INFO' 'Defender real-time protection on this client scans files as the apps open them from the share (extra work per file on top of the network round trips). CaseWare recommends AV exclusions on workstations too.' }
} catch { Write-Host 'Defender status not available.' }
$avRegex = 'Sophos|SentinelOne|CrowdStrike|Falcon|ESET|Bitdefender|Webroot|Trend Micro|Symantec|McAfee|Trellix|Malwarebytes|Huntress|Datto|Cylance|Kaspersky|Carbon Black|Cortex XDR|Avast|AVG|Norton|ThreatLocker|Blackpoint|Arctic Wolf|Todyl|Heimdal|Emsisoft|WithSecure|F-Secure|Cybereason|Deep Instinct|Coro'
$av3 = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $avRegex })
if ($av3.Count -gt 0) { Show ($av3 | Select-Object Status, Name, DisplayName) }

# ------------------------------------------------------------------ ADAPTERS
Section 'NETWORK ADAPTERS (VPN adapters included)'
$ads = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
Show ($ads | Select-Object Name, InterfaceDescription, Status, LinkSpeed, @{ n = 'MTU'; e = { (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu } })
$vpnRegex = 'WireGuard|Wintun|TAP-Windows|OpenVPN|Data Channel Offload|Fortinet|FortiClient|SonicWall|PANGP|GlobalProtect|AnyConnect|Cisco Secure|WatchGuard|Sophos|Tailscale|ZeroTier|Check Point|Zscaler'
$vpn = @($ads | Where-Object { $_.InterfaceDescription -match $vpnRegex -or $_.Name -match $vpnRegex })
if ($vpn.Count -gt 0) { Write-Host ("VPN adapter(s) detected: {0}" -f (($vpn | ForEach-Object { $_.InterfaceDescription }) -join '; ')) }
$ovpnGui = Get-ItemProperty 'HKLM:\SOFTWARE\OpenVPN' -ErrorAction SilentlyContinue
if ($ovpnGui) { Write-Host ("OpenVPN (community) installed: {0}" -f (@($ovpnGui.PSObject.Properties | Where-Object { $_.Name -match 'version|exe_path' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')) }
Show (Get-VpnConnection -ErrorAction SilentlyContinue | Select-Object Name, ServerAddress, TunnelType, ConnectionStatus, SplitTunneling)

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
} finally {
    Complete-KitLog
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Report saved: $report"
}
