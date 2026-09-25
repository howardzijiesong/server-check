# =============================================================================
# KitCommon.ps1 - shared logging and error helpers, dot-sourced by the kit scripts.
# Windows PowerShell 5.1 and PowerShell 7 compatible. ASCII only.
#
# Every run writes into its results folder:
#   <Script>-<COMPUTER>-<timestamp>.txt    human transcript (where the script uses one)
#   <Script>-<COMPUTER>-<timestamp>.jsonl  machine log: one JSON record per finding, fact,
#                                          metric or error - read by Analyze-Results.ps1
# Record levels: START END OK INFO WARN ERROR FACT METRIC
# =============================================================================

$script:KitVersion = '2026.09.25'
$script:KitErrors = 0
$script:KitCat = 'run'
$script:KitJsonl = $null
$script:KitFailed = $false
$script:Findings = New-Object System.Collections.Generic.List[object]

function Initialize-KitLog([string]$ScriptName, [string]$OutDir, $BoundParameters) {
    try {
        New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null
        $probe = Join-Path $OutDir '.kit-write-test'
        Set-Content -Path $probe -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -ErrorAction SilentlyContinue
    } catch {
        Write-Host "ERROR: cannot write to $OutDir" -ForegroundColor Red
        Write-Host '  hint: the kit is probably on read-only media or a protected folder. Copy the kit to C:\kit and run it from there.' -ForegroundColor Yellow
        exit 2
    }
    $script:KitScript = $ScriptName
    $script:KitStart = Get-Date
    $script:KitStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:KitBase = Join-Path $OutDir ("{0}-{1}-{2}" -f $ScriptName, $env:COMPUTERNAME, $script:KitStamp)
    $script:KitJsonl = $script:KitBase + '.jsonl'
    $script:KitLog = $script:KitBase + '.txt'
    $script:KitUtf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:KitJsonl, '', $script:KitUtf8)
    $argText = ''
    if ($BoundParameters) { $argText = (@($BoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' ') }
    Write-KitRecord 'START' 'run' 'args' $argText
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    if ($os) { Write-KitRecord 'FACT' 'run' 'os' '' ("{0} build {1}" -f $os.Caption, $os.BuildNumber) }
    Write-KitRecord 'FACT' 'run' 'powershell' '' ("{0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
    Write-KitRecord 'FACT' 'run' 'elevated' '' (Test-KitAdmin)
}

function Write-KitRecord([string]$Level, [string]$Category, [string]$Key, [string]$Message, $Value = $null, [string]$Unit = '') {
    if (-not $script:KitJsonl) { return }
    $v = ''
    if ($null -ne $Value) { $v = [string]$Value }
    $o = [pscustomobject][ordered]@{
        ts = (Get-Date).ToString('o'); script = $script:KitScript; ver = $script:KitVersion; host = $env:COMPUTERNAME
        level = $Level; cat = $Category; key = $Key; msg = $Message; value = $v; unit = $Unit
    }
    try { [System.IO.File]::AppendAllText($script:KitJsonl, ($o | ConvertTo-Json -Compress) + "`r`n", $script:KitUtf8) } catch { }
}

function Add-Finding([string]$Level, [string]$Message, [string]$Key = '') {
    $script:Findings.Add([pscustomobject]@{ Level = $Level; Message = $Message })
    Write-KitRecord $Level $script:KitCat $Key $Message
}
function Write-KitFact([string]$Key, $Value, [string]$Message = '') { Write-KitRecord 'FACT' $script:KitCat $Key $Message $Value }
function Write-KitMetric([string]$Key, $Value, [string]$Unit = '', [string]$Message = '') { Write-KitRecord 'METRIC' $script:KitCat $Key $Message $Value $Unit }

function Section([string]$Title) {
    $script:KitCat = (($Title.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_'))
    if ($script:KitCat.Length -gt 40) { $script:KitCat = $script:KitCat.Substring(0, 40) }
    Write-Host ''
    Write-Host ('=' * 18 + " $Title " + '=' * 18) -ForegroundColor Cyan
}
function Show($Object) { if ($null -ne $Object) { $Object | Format-Table -AutoSize -Wrap | Out-String -Width 230 | Write-Host } }
function ShowList($Object) { if ($null -ne $Object) { $Object | Format-List | Out-String -Width 230 | Write-Host } }
function Select-Existing($Object, [string[]]$Property) {
    $first = @($Object)[0]
    if ($null -eq $first) { return $null }
    $names = $first.PSObject.Properties.Name
    $Object | Select-Object -Property @($Property | Where-Object { $names -contains $_ })
}

function Test-KitAdmin {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { return $false }
}
function Assert-KitAdmin {
    if (-not (Test-KitAdmin)) {
        Write-KitError 'This script must run elevated.' 'Right-click Windows PowerShell > Run as administrator, then run the script again.'
        Complete-KitLog
        exit 2
    }
}

function Get-KitErrorHint($ErrorRecord) {
    $m = ''
    if ($ErrorRecord) { $m = "$($ErrorRecord.Exception.Message) $($ErrorRecord.FullyQualifiedErrorId)" }
    switch -Regex ($m) {
        'running scripts is disabled|execution polic' { return 'Execution policy: run  powershell -ExecutionPolicy Bypass -File <script>  and Unblock-File the kit folder.' }
        'Access (to the path .*)?is denied|UnauthorizedAccess|0x80070005' { return 'Access denied: use an elevated PowerShell (server scripts) and check NTFS + share permissions on the path. Remember UAC: admin-group membership alone is not enough in a non-elevated window.' }
        'network (name|path) (cannot be found|was not found)|0x80070035|0x80070043|BadNetPath' { return 'Share not reachable: check the \\server\share spelling, that the VPN is connected, and that it opens in Explorer.' }
        'user name or password is incorrect|logon failure|0x8007052E' { return 'Credentials rejected: open the share once in Explorer and log in as DOMAIN\user.' }
        'not enough (free )?space|disk is full|0x80070070' { return 'Not enough free space on the target volume.' }
        'being used by another process|0x80070020' { return 'File in use: close programs using it or wait for the antivirus scan, then retry.' }
        'is not recognized as the name of a cmdlet|CommandNotFoundException' { return 'Cmdlet missing: run in Windows PowerShell 5.1 on Windows 10/11 or Server 2016+ (SMB, Storage and Defender modules).' }
        '0x800106ba|MpComputerStatus|MpPreference' { return 'Defender cmdlets unavailable (third-party AV active or Defender off) - that part is skipped.' }
        'Could not find a part of the path|Cannot find path|DirectoryNotFound|PathNotFound' { return 'Path does not exist: check the drive letter / folder / share name.' }
        'timed out|timeout|semaphore' { return 'Timeout: the network/VPN path is unstable or the server is busy; compare with Client-NetCheck.ps1.' }
        'Invalid class|WMI|CIM' { return 'WMI/CIM query failed: repair WMI or run on a supported Windows version.' }
        default { return '' }
    }
}

function Write-KitError([string]$Message, [string]$Hint = '', $ErrorRecord = $null) {
    $script:KitErrors++
    $where = ''
    if ($ErrorRecord -and $ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
        $where = " (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    }
    if (-not $Hint -and $ErrorRecord) { $Hint = Get-KitErrorHint $ErrorRecord }
    Write-Host "ERROR: $Message$where" -ForegroundColor Red
    if ($Hint) { Write-Host "  hint: $Hint" -ForegroundColor Yellow }
    $full = "$Message$where"
    if ($Hint) { $full = "$full | hint: $Hint" }
    Write-KitRecord 'ERROR' $script:KitCat 'error' $full
}

function Complete-KitLog {
    if (-not $script:KitJsonl) { return }
    $secs = [int]((Get-Date) - $script:KitStart).TotalSeconds
    Write-KitRecord 'END' 'run' 'status' ("errors={0} duration={1}s" -f $script:KitErrors, $secs) $script:KitErrors
    Write-Host ''
    Write-Host "Machine log: $($script:KitJsonl)"
    Write-Host 'Analyze all results with:  .\Analyze-Results.ps1 -Path <results folder(s)>'
    if ($script:KitErrors -gt 0) { Write-Host "$($script:KitErrors) error(s) were logged - look for 'ERROR:' and 'hint:' above." -ForegroundColor Yellow }
    $script:KitJsonl = $null
}
