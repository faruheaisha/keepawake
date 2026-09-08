<#
.SYNOPSIS
    tests/ka-tests.ps1 - the behavioural test suite for the keep-awake tool.

.DESCRIPTION
    These are not smoke tests. Each one targets a failure this project actually had, or
    a claim the product makes to the user that would be expensive to get wrong:

      * the heartbeat must really reset the system idle timer, and the mouse variant must
        put the cursor back exactly where it found it;
      * the powercfg parser must return the *current* AC/DC setting, not the setting's
        minimum/maximum - the first build read the bounds and reported every timeout as
        "never";
      * a stopped worker must leave nothing behind (no process, no stop.flag);
      * the localhost API must refuse a request from another origin's page, checked over
        a raw socket because that is the only way to forge a Host header.

    The suite runs against the real install directory and the real Windows power API.
    Everything it touches (config.json, intent.json, state.json, ka.log, .server.json) is
    backed up first and restored in a finally block, and any worker it starts is stopped,
    so a crash mid-run cannot leave this machine accidentally protected or unprotected.
    The installed KeepAwake-* watchdog tasks are parked for the duration and put back in the
    same finally block: the guard reconciles against the very intent.json and state.json these
    tests rewrite, and it will reap a worker the suite owns.

    Lifecycle tests share one worker on purpose (starting one costs ~3s), so a few of them
    depend on the one before. Use -Only to select a group, not a single mid-chain test.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-tests.ps1
          powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'tests\ka-tests.ps1' -Only 心跳,parser"
          ... -LeaveOutputs          (keep the temp copies for inspection)

    -Only is a substring match on test names. It has to be passed through -Command: via
    -File, cmd/Git Bash hands "a,b" over as one argv token and PowerShell binds that single
    string, so nothing matches and the run reports 「通过 0」 - which looks like a clean
    run if you are not watching the count.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\ka-tests.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Only = @(),
    [switch]$LeaveOutputs,
    [int]$PortProbeTries = 6
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $root 'ka-core.ps1')

# Pin the UI language. Several assertions compare against the Chinese the tool authors
# wrote, and `auto` follows the display language of whatever machine runs the suite - on an
# English Windows those comparisons would fail against perfectly correct English output.
# KA_LANG is the documented override, so pinning it also exercises it.
$env:KA_LANG = 'zh'

# An independent cursor reader: verifying that the nudge restores the position must not
# reuse the same P/Invoke wrapper that did the moving.
if (-not ('KaTestCursor' -as [type])) {
    Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KaTestCursor {
    [StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out P p);
    public static string Get() { P p; return GetCursorPos(out p) ? p.X + "," + p.Y : ""; }
}
'@
}

$paths = Get-KaPath
$script:Pass = 0
$script:Failures = @()
$script:Skipped = @()
$script:Temps = @()
$script:Backups = @{}
$script:Guarded = @('config', 'intent', 'state', 'stopFlag', 'log', 'serverInfo')
$script:SrvPort = 0
$script:SrvPid = $null

function It {
    param([string]$Name, [scriptblock]$Body)
    if ($Only.Count -and -not ($Only | Where-Object { $Name -like "*$_*" })) { return }
    try {
        $out = & $Body
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
        if ($out) { foreach ($l in @($out)) { if ($l) { Write-Host ("        {0}" -f $l) -ForegroundColor DarkGray } } }
    } catch {
        $msg = "$($_.Exception.Message)"
        if ($msg -like 'KA-SKIP:*') {
            $why = $msg.Substring(9)   # past "KA-SKIP: "
            $script:Skipped += ("{0}  ({1})" -f $Name, $why)
            Write-Host ("  SKIP  {0} - {1}" -f $Name, $why) -ForegroundColor DarkYellow
        } else {
            $script:Failures += ("{0}  ->  {1}" -f $Name, $msg)
            Write-Host ("  FAIL  {0}`n        {1}" -f $Name, $msg) -ForegroundColor Red
        }
    }
}
function Skip {
    # Call inside an It body when this machine has nothing the case could verify
    # (no battery, no standby history, a VM firmware lie). It throws so the case is
    # counted neither as a pass nor as a failure; the marker lets It's catch tell
    # the two apart.
    param([string]$Why)
    throw "KA-SKIP: $Why"
}
function Assert {
    # Untyped on purpose: callers pass strings, hashtables and bare expressions. A [bool]
    # constraint makes the conversion throw before the assertion ever runs.
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-KaInputGate {
    <#
        "SendInput returned true but the idle timer did not move" has two very different
        causes, and only one of them is our bug. Reuse the product's own gate so a test
        cannot disagree with the worker about whether input can land at all.
        Measured on this box: while idle, the foreground window belongs to
        ScreenSaverPlayer at High IL (0x3000) while the worker and the tests run at Medium
        (0x2000) - UIPI drops lower -> higher, so every injected event is swallowed.
    #>
    $probe = Get-KaForegroundIntegrity
    $self = [Ka.Native]::SelfIntegrityRid()
    $fg = [int]$probe.fgIl
    $name = ''
    try { $name = (Get-Process -Id ([int]$probe.fgPid) -ErrorAction SilentlyContinue).ProcessName } catch { }
    return [PSCustomObject]@{
        selfIl  = $self
        fgIl    = $fg
        fgPid   = [int]$probe.fgPid
        fgName  = $name
        blocked = (Test-KaInputBlocked -SelfIl $self -ForegroundIl $fg)
    }
}
function Format-KaIl { param($Rid) '0x{0:X}' -f [int]$Rid }
function Assert-Eq {
    param($Actual, $Expected, [string]$Label)
    if ("$Actual" -ne "$Expected") { throw "$Label : 期望 '$Expected'，实际 '$Actual'" }
}

# ---------------------------------------------------------------- backup / restore
function Protect-Files {
    foreach ($k in $script:Guarded) {
        $f = $paths.$k
        if ($f -and (Test-Path -LiteralPath $f)) {
            $tmp = Join-Path $env:TEMP ("ka-test-{0}-{1}" -f $k, [guid]::NewGuid().ToString('N').Substring(0, 8))
            Copy-Item -LiteralPath $f -Destination $tmp -Force
            $script:Backups[$k] = $tmp
        }
    }
    $rot = "$($paths.log).1"
    if (Test-Path -LiteralPath $rot) {
        $tmp = Join-Path $env:TEMP ("ka-test-log1-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        Copy-Item -LiteralPath $rot -Destination $tmp -Force
        $script:Backups['log.1'] = $tmp
    }
}

function Restore-Files {
    foreach ($k in @($script:Backups.Keys)) {
        $src = $script:Backups[$k]
        $dest = if ($k -eq 'log.1') { "$($paths.log).1" } elseif ($paths.$k) { $paths.$k } else { $null }
        try { if ($dest) { Copy-Item -LiteralPath $src -Destination $dest -Force } } catch { }
        if (-not $LeaveOutputs) { try { Remove-Item -LiteralPath $src -Force } catch { } }
    }
}

$script:TaskWasEnabled = @{}
function Protect-GuardTasks {
    <#
        The installed watchdog reconciles every 10 minutes against the *real* intent.json and
        state.json, and these tests rewrite both files and own the worker. Measured cost of
        ignoring that: a full run lost a suite-owned worker mid-test - "STOPPED pid=15212
        reason=stopped", i.e. the guard's stop request - and a panel start timed out while the
        guard's own worker launch competed for the same window. Neither was a product bug, and
        both read as one.
        Nothing here unregisters a task: the enabled state is captured so the run cannot leave
        this machine less guarded than it found it.
    #>
    foreach ($n in $script:KaTaskNames) {
        try {
            $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
            if (-not $t) { continue }
            $script:TaskWasEnabled[$n] = ("$($t.State)" -ne 'Disabled')
            if ("$($t.State)" -ne 'Disabled') {
                [void](Disable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue)
            }
        } catch { }
    }
}
function Restore-GuardTasks {
    foreach ($n in @($script:TaskWasEnabled.Keys)) {
        if ($script:TaskWasEnabled[$n]) {
            try { [void](Enable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) } catch { }
        }
    }
    $script:TaskWasEnabled = @{}
}

function New-TempFile {
    param([string]$Suffix = '.json')
    $f = Join-Path $env:TEMP ("ka-test-{0}{1}" -f [guid]::NewGuid().ToString('N').Substring(0, 8), $Suffix)
    $script:Temps += $f
    return $f
}

function Get-FreePort {
    for ($i = 0; $i -lt $PortProbeTries; $i++) {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        try {
            $l.Start()
            $p = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
            $l.Stop()
            if ($p -gt 1024) { return $p }
        } catch { } finally { try { $l.Stop() } catch { } }
    }
    throw '找不到可用端口'
}

# Hand-written HTTP: Invoke-WebRequest refuses to send a foreign Host header, and a
# foreign Host header is exactly what the DNS-rebinding defence has to survive.
function Invoke-RawHttp {
    param(
        [int]$Port,
        [string]$Path = '/',
        [string]$Method = 'GET',
        [string]$HostHeader = '127.0.0.1',
        [hashtable]$Headers = @{},
        [string]$Body = '',
        [int]$TimeoutSec = 8
    )
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
    try {
        $client.SendTimeout = $TimeoutSec * 1000
        $client.ReceiveTimeout = $TimeoutSec * 1000
        $stream = $client.GetStream()
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("$Method $Path HTTP/1.1")
        [void]$sb.AppendLine("Host: $HostHeader")
        [void]$sb.AppendLine('Connection: close')
        foreach ($k in $Headers.Keys) { [void]$sb.AppendLine("$k`: $($Headers[$k])") }
        if ($Body) {
            [void]$sb.AppendLine('Content-Type: application/json')
            [void]$sb.AppendLine("Content-Length: $([Text.Encoding]::UTF8.GetByteCount($Body))")
        }
        [void]$sb.AppendLine('')
        $bytes = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
        $stream.Write($bytes, 0, $bytes.Length)
        if ($Body) {
            $bb = [Text.Encoding]::UTF8.GetBytes($Body)
            $stream.Write($bb, 0, $bb.Length)
        }
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 4096
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            try {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
            } catch { break }     # the listener aborts the socket on 403 - that is the answer
        }
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        $status = 0
        if ($text -match '^HTTP/\d(?:\.\d)? (\d{3})') { $status = [int]$Matches[1] }
        # Text keeps the raw response (that is what the header assertions read); Body is
        # the payload after the header block, for anything that needs ConvertFrom-Json.
        $body = $text
        $sep = $text.IndexOf("`r`n`r`n")
        if ($sep -ge 0) { $body = $text.Substring($sep + 4) }
        # A stray BOM makes ConvertFrom-Json fail with a message about the JSON, not the BOM.
        $body = $body.TrimStart([char]0xFEFF)
        return @{ Status = $status; Text = $text; Body = $body }
    } finally {
        try { $client.Close() } catch { }
    }
}

function Wait-WorkerGone {
    param([int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-KaWorker).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return (@(Get-KaWorker).Count -eq 0)
}

function Ensure-Worker {
    <#
        Tests that only need "a worker is running" must not depend on the previous test
        having left one behind, or -Only selection would report phantom failures.
    #>
    if (@(Get-KaWorker).Count -gt 0) { return $true }
    $r = Start-KaProtection -Minutes 0
    return [bool]$r.Ok
}

function Get-LogTail {
    param([int]$Count = 60)
    try { return @(Get-Content -LiteralPath $paths.log -Tail $Count -ErrorAction SilentlyContinue | ForEach-Object { "$_" }) }
    catch { return @() }
}

# ---------------------------------------------------------------- run
Protect-Files
Protect-GuardTasks
if ($script:TaskWasEnabled.Count) {
    Write-Host "看门狗计划任务已暂时停用（$($script:TaskWasEnabled.Count) 个），跑完自动还原" -ForegroundColor DarkGray
}
try {
    Write-Host "`n== 纯函数 ==" -ForegroundColor Cyan

    It 'Get-KaBounded 夹住越界值并回退非数值' {
        Assert-Eq (Get-KaBounded 5 10 20 15) 10 '低于下限'
        Assert-Eq (Get-KaBounded 99 10 20 15) 20 '高于上限'
        Assert-Eq (Get-KaBounded 'abc' 10 20 15) 15 '非数值'
        Assert-Eq (Get-KaBounded $null 10 20 15) 15 'null'
        Assert-Eq (Get-KaBounded 12 10 20 15) 12 '区间内'
    }

    It 'Format-KaSeconds 区分 0=从不 与 空=未知（两种语言各测一遍）' {
        # -Lang is passed explicitly everywhere: these assertions used to read the ambient UI
        # language, so the suite passed on a Chinese box and failed on an English one.
        Assert-Eq (Format-KaSeconds $null -Lang 'zh') '未知' 'null'
        Assert-Eq (Format-KaSeconds 0 -Lang 'zh') '从不' 'zero'
        Assert-Eq (Format-KaSeconds 45 -Lang 'zh') '45 秒' 'seconds'
        Assert ((Format-KaSeconds 90 -Lang 'zh') -like '*分钟*') '90 秒应显示为分钟'
        Assert ((Format-KaSeconds 7200 -Lang 'zh') -like '*小时*') '7200 秒应显示为小时'
        Assert-Eq (Format-KaSeconds $null -Lang 'en') 'Unknown' 'en null'
        Assert-Eq (Format-KaSeconds 0 -Lang 'en') 'Never' 'en zero'
        Assert-Eq (Format-KaSeconds 45 -Lang 'en') '45 s' 'en seconds'
        Assert-Eq (Format-KaSeconds 90 -Lang 'en') "$([math]::Round(1.5, 1)) min" 'en minutes'
        Assert-Eq (Format-KaSeconds 7200 -Lang 'en') (('{0:N1}' -f 2) + ' h') 'en hours'
    }

    It 'Format-KaDuration：0 秒是实测值，负数是读取失败' {
        Assert-Eq (Format-KaDuration $null -Lang 'zh') '未知' 'null'
        Assert-Eq (Format-KaDuration 0 -Lang 'zh') '0 秒' '刚发生过输入'
        Assert-Eq (Format-KaDuration -1 -Lang 'zh') '未知' 'Get-KaIdleSeconds 的失败哨兵'
        Assert ((Format-KaDuration -1 -Lang 'zh') -notlike '*-1*') '失败哨兵不能显示成 -1 秒'
        Assert-Eq (Format-KaDuration '-1' -Lang 'zh') '未知' '字符串形式的哨兵（裸 -1 字面量就是这样绑定的）'
        Assert-Eq (Format-KaDuration 'abc' -Lang 'zh') '未知' '非数值'
        Assert-Eq (Format-KaDuration '45' -Lang 'zh') '45 秒' '字符串数值'
        Assert-Eq (Format-KaDuration 45 -Lang 'zh') '45 秒' 'seconds'
        Assert ((Format-KaDuration 90 -Lang 'zh') -like '*分钟*') '90 秒应显示为分钟'
        Assert ((Format-KaDuration 7200 -Lang 'zh') -like '*小时*') '7200 秒应显示为小时'
        Assert-Eq (Format-KaDuration -1 -Lang 'en') 'Unknown' 'en 失败哨兵'
        Assert-Eq (Format-KaDuration 45 -Lang 'en') '45 s' 'en seconds'
        Assert-Eq (Format-KaDuration 7200 -Lang 'en') (('{0:N1}' -f 2) + ' h') 'en hours delegates to Format-KaSeconds'
    }

    It 'Get-KaMinutesUntil：时刻→时长，已过的裸时刻顺延到明天' {
        $now = Get-Date '2026-08-29 10:00:00'
        $r = Get-KaMinutesUntil -Text '18:30' -Now $now
        Assert ($r.Ok) "18:30 应被接受：$($r.Reason)"
        Assert-Eq ([math]::Round($r.Minutes)) 510 '18:30 分钟数'
        Assert-Eq ($r.At.ToString('MM-dd HH:mm')) '08-29 18:30' '18:30 落点'

        $p = Get-KaMinutesUntil -Text '09:00' -Now $now
        Assert ($p.Ok) "09:00 应顺延而不是报错：$($p.Reason)"
        Assert-Eq ([math]::Round($p.Minutes)) 1380 '09:00 已过 → 顺延到明天 09:00'
        Assert-Eq ($p.At.ToString('MM-dd HH:mm')) '08-30 09:00' '顺延落点'

        $d = Get-KaMinutesUntil -Text '2026-08-30 07:30' -Now $now
        Assert ($d.Ok) "完整日期时间应被接受：$($d.Reason)"
        Assert-Eq ([math]::Round($d.Minutes)) 1290 '完整日期分钟数'

        $past = Get-KaMinutesUntil -Text '2020-01-01 00:00' -Now $now
        Assert (-not $past.Ok) '过去的完整日期必须拒绝（当成无限期是反的）'

        $junk = Get-KaMinutesUntil -Text 'not-a-time' -Now $now
        Assert (-not $junk.Ok) '垃圾输入必须拒绝'
        Assert ($junk.Reason) '拒绝必须给原因'

        $empty = Get-KaMinutesUntil -Text '' -Now $now
        Assert (-not $empty.Ok) '空串应被拒绝（交给 -Minutes 判断）'
    }

    It 'Format-KaTaskResult 把计划任务的 DWORD 结果按无符号读' {
        # 3221225786 = 0xC000013A，本机 11:38 那次被打断的看门狗运行就是这个值。
        # 旧代码用 [int] 读它，直接抛异常。
        Assert-Eq (Format-KaTaskResult -Value 3221225786 -NeverRun $false -Lang 'zh') '0xC000013A · 非零退出' 'NTSTATUS 溢出值'
        Assert-Eq (Format-KaTaskResult -Value 0 -NeverRun $false -Lang 'zh') '0x0 · 成功' '成功'
        Assert-Eq (Format-KaTaskResult -Value 267011 -NeverRun $false -Lang 'zh') '0x41303 · 非零退出' '小值也走无符号'
        Assert-Eq (Format-KaTaskResult -Value 0 -NeverRun $true -Lang 'zh') '从未运行' '从未运行的哨兵优先'
        Assert-Eq (Format-KaTaskResult -Value 3221225786 -NeverRun $false -Lang 'en') '0xC000013A · non-zero exit' 'en 溢出值'
        Assert-Eq (Format-KaTaskResult -Value 0 -NeverRun $false -Lang 'en') '0x0 · success' 'en 成功'
        Assert-Eq (Format-KaTaskResult -Value 0 -NeverRun $true -Lang 'en') 'Never ran' 'en 从未运行'
        Assert-Eq (Format-KaTaskResult -Value $null -NeverRun $false) '-' '读不到结果'
        Assert ((Format-KaTaskResult -Value 'abc' -NeverRun $false -Lang 'en') -like '*abc*') '解析不了要把原值带出来，不能编一个'
    }

    It 'Write-KaJson/Read-KaJson 往返且不留下临时文件' {
        $f = New-TempFile
        $dir = Split-Path -Parent $f
        $before = @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -ErrorAction SilentlyContinue).Count
        [void](Write-KaJson $f @{ a = 1; b = '中文'; c = $true; d = 1.5 } -Depth 3)
        $back = Read-KaJson $f
        Assert-Eq $back.b '中文' 'unicode 往返'
        Assert-Eq $back.a 1 'int 往返'
        Assert ($back.c -eq $true) 'bool 往返'
        Assert ((Get-Item -LiteralPath $f).Length -gt 0) '写入后文件为空'
        $after = @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -ErrorAction SilentlyContinue).Count
        Assert ($after -le $before) "留下了临时文件（$before -> $after）"
    }

    It 'Read-KaJson 对损坏或缺失的文件返回 null 而不抛出' {
        $f = New-TempFile
        Set-Content -LiteralPath $f -Value '{ this is not json' -Encoding UTF8
        Assert-Eq (Read-KaJson $f) $null '损坏文件'
        Assert-Eq (Read-KaJson (Join-Path $env:TEMP 'definitely-missing-ka.json')) $null '不存在文件'
    }

    It 'ConvertFrom-KaEpoch 对 0 与负值返回 null' {
        Assert-Eq (ConvertFrom-KaEpoch 0) $null 'zero'
        Assert-Eq (ConvertFrom-KaEpoch -5) $null 'negative'
        Assert ((ConvertFrom-KaEpoch (Get-KaEpoch)) -match '^\d{4}-\d{2}-\d{2}') 'epoch 应格式化成本地时间'
    }

    It '默认配置覆盖 worker 消费的每一个参数' {
        $cfg = Get-KaDefaultConfig
        foreach ($k in @('keepDisplayOn', 'antiLock', 'awayMode', 'batteryAllowDisplayOff',
                         'antiLockMethod', 'antiLockIntervalSec', 'reassertSec',
                         'batteryFloorPercent', 'port', 'logMaxKb')) {
            Assert ($cfg.ContainsKey($k)) "默认配置缺少 $k"
        }
    }

    It 'worker 的参数没有一个从配置里缺席' {
        # The worker's own parameter metadata, not a regex over its text. A knob that
        # exists in config but not in the worker (or the other way round) is a control
        # that looks alive in the dashboard and silently does nothing.
        # Get-Command -LiteralPath is useless here: on a .ps1 it reports only the generic
        # script parameters (InputObject/Begin/Process/End + common), never the declared
        # ones - so every real parameter looked "missing". Read the AST param block instead.
        $workerAst = [System.Management.Automation.Language.Parser]::ParseFile($paths.worker, [ref]$null, [ref]$null)
        $params = @($workerAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert ($params.Count -gt 0) 'AST 没读到 worker 的任何参数 —— 测试本身失效了'
        $map = @{ KeepDisplayOn = 'keepDisplayOn'; AntiLock = 'antiLock'; AwayMode = 'awayMode'
                  BatteryAllowDisplayOff = 'batteryAllowDisplayOff'; AntiLockMethod = 'antiLockMethod'
                  AntiLockIntervalSec = 'antiLockIntervalSec'; ReassertSec = 'reassertSec'
                  BatteryFloorPercent = 'batteryFloorPercent'; Minutes = 'Minutes' }
        $cfg = Get-KaDefaultConfig
        $missing = @()
        foreach ($n in $map.Keys) {
            if ($params -notcontains $n) { $missing += "worker 不再接受 -$n" }
            $k = $map[$n]
            if ($k -ne 'Minutes' -and -not $cfg.ContainsKey($k)) { $missing += "默认配置里没有 $k" }
        }
        # The reverse direction matters just as much: a worker parameter that config
        # cannot express is one nobody can tune. StatePath/SliceMs are wiring used by
        # Start-KaWorker, not knobs, so they are excluded deliberately - and so is
        # DataDir, which says where the record lives rather than what gets protected.
        foreach ($p in $params) {
            if ($p -in @('Minutes', 'StatePath', 'SliceMs', 'DataDir')) { continue }
            $camel = [string]$p.Substring(0, 1).ToLower() + $p.Substring(1)
            if (-not $cfg.ContainsKey($camel)) { $missing += "配置里没有 $camel（worker 却有 -$p）" }
        }
        Assert ($missing.Count -eq 0) ($missing -join '；')
        "已对齐 $($map.Count) 个参数（worker 共 $($params.Count) 个）"
    }

    It 'Get-KaConfig 把垃圾值夹回合法区间' {
        $orig = Read-KaJson $paths.config
        try {
            Set-Content -LiteralPath $paths.config -Encoding UTF8 -Value (@'
{ "antiLockMethod": "banana", "port": 1, "batteryFloorPercent": 500,
  "antiLockIntervalSec": 0, "reassertSec": -9 }
'@)
            $cfg = Get-KaConfig
            Assert-Eq $cfg.antiLockMethod 'key' '非法方法必须回落到 key'
            Assert ($cfg.port -ge 1024 -and $cfg.port -le 65534) "端口未被夹住：$($cfg.port)"
            Assert ($cfg.batteryFloorPercent -le 90) "电池阈值未被夹住：$($cfg.batteryFloorPercent)"
            Assert ($cfg.antiLockIntervalSec -ge 10) "心跳间隔未被夹住：$($cfg.antiLockIntervalSec)"
            Assert ($cfg.reassertSec -ge 15) "重声明间隔未被夹住：$($cfg.reassertSec)"
        } finally {
            if ($orig) { [void](Write-KaJson $paths.config $orig -Depth 4) }
        }
    }

    It 'config.language 只认 auto|zh|en，其余一律回落 auto' {
        $orig = Read-KaJson $paths.config
        try {
            foreach ($pair in @(@('zh', 'zh'), @('EN', 'en'), @('  en  ', 'en'),
                                @('de', 'auto'), @('', 'auto'), @('auto', 'auto'))) {
                Set-Content -LiteralPath $paths.config -Encoding UTF8 `
                            -Value ('{ "language": "' + $pair[0] + '" }')
                Assert-Eq (Get-KaConfig).language $pair[1] "语言值 $($pair[0]) 的处理不对"
            }
            Set-Content -LiteralPath $paths.config -Encoding UTF8 -Value '{ "port": 8791 }'
            Assert-Eq (Get-KaConfig).language 'auto' '旧 config.json 没有 language 键时必须回落 auto'
        } finally {
            if ($orig) { [void](Write-KaJson $paths.config $orig -Depth 4) }
        }
    }

    It 'Set-KaConfig 在写入口拒绝词典外的枚举值，读入口仍然宽容' {
        if (-not (Test-Path -LiteralPath $paths.config)) { [void](Set-KaConfig -Patch @{}) }
        $orig = Read-KaJson $paths.config
        try {
            foreach ($pair in @(@('language', 'de'), @('antiLockMethod', 'keyboard'))) {
                $k = $pair[0]; $v = $pair[1]; $msg = ''
                $before = (Get-FileHash -LiteralPath $paths.config).Hash
                $threw = $false
                try { [void](Set-KaConfig -Patch @{ $k = $v }) } catch { $threw = $true; $msg = "$($_.Exception.Message)" }
                Assert ($threw) "$k=$v 被写入口默默收下：调用方收到「成功」，实际跑的却是默认值"
                Assert ($msg -match [regex]::Escape($k)) "拒绝信息里没点名是哪个键：$msg"
                Assert-Eq (Get-FileHash -LiteralPath $paths.config).Hash $before "$k=$v 被拒绝了却还是写了 config.json"
                # The reader stays tolerant on purpose: a config.json that was hand-edited,
                # synced from another machine or written by an older version must still run.
                Set-Content -LiteralPath $paths.config -Encoding UTF8 -Value ('{ "' + $k + '": "' + $v + '" }')
                Assert ((Get-KaConfig).$k -in @('auto', 'zh', 'en', 'key', 'mouse')) "$k 的读入口不再宽容"
            }
            [void](Set-KaConfig -Patch @{ language = 'EN' })
            Assert-Eq (Get-KaConfig).language 'en' '写入口应把大小写归一之后再落盘'
        } finally {
            if ($orig) { [void](Write-KaJson $paths.config $orig -Depth 4) }
        }
    }

    It 'worker 能发出的每个 note/error 标记，三本词典里都有措辞' {
        # Tokens are invented in ka-worker.ps1 and rendered in three other places. Only a
        # check that reads the emitter can tell that the wording for a new token is missing.
        $src = [IO.File]::ReadAllText((Join-Path $root 'ka-worker.ps1'))
        $tokens = @([regex]::Matches($src, "\`$note\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } |
                    Where-Object { $_ } | Sort-Object -Unique)
        $codes = @([regex]::Matches($src, '"(settes-[a-z]+):') | ForEach-Object { $_.Groups[1].Value } |
                   Sort-Object -Unique)
        Assert ($tokens.Count -ge 2) "只从 ka-worker.ps1 找到 $($tokens.Count) 个 note 标记 —— 正则失配，本测试已失去意义"
        Assert ($codes.Count -ge 1) '只从 ka-worker.ps1 找到 0 个 error 标记 —— 正则失配，本测试已失去意义'
        $js = [IO.File]::ReadAllText((Join-Path $root 'dashboard\i18n.js'))
        foreach ($t in $tokens) {
            Assert ($script:KaUi.zh.ContainsKey("worker.note.$t")) "服务端词典缺 worker.note.$t"
            Assert ($script:KaUi.en.ContainsKey("worker.note.$t")) "英文词典缺 worker.note.$t"
            Assert-Eq ([regex]::Matches($js, [regex]::Escape("'pill.note.$t'"))).Count 2 `
                "面板词典里 pill.note.$t 不是恰好两次（zh 与 en 各一次），要么漏了语言要么写了重复键"
        }
        foreach ($c in $codes) {
            Assert ($script:KaUi.zh.ContainsKey("worker.error.$c")) "服务端词典缺 worker.error.$c"
            Assert ($script:KaUi.en.ContainsKey("worker.error.$c")) "英文词典缺 worker.error.$c"
            Assert-Eq ([regex]::Matches($js, [regex]::Escape("'pill.error.$c'"))).Count 2 `
                "面板词典里 pill.error.$c 不是恰好两次（zh 与 en 各一次）"
        }
    }

    It '日志调用点只写 ASCII：Add-KaLog 里没有汉字' {
        # README promises the log is machine vocabulary. That is only true if nobody writes a
        # sentence into it, and a regex over lines misses the `Add-KaLog ('...' -f ...)` calls
        # that continue onto a second line - so this reads the syntax tree instead.
        $bad = @()
        foreach ($f in @('ka-core.ps1', 'ka-server.ps1', 'ka-worker.ps1', 'ka-guard.ps1', 'ka-tray.ps1', 'ka.ps1')) {
            $tok = $null; $err = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $root $f), [ref]$tok, [ref]$err)
            Assert ($err.Count -eq 0) "$f 语法有 $($err.Count) 个错误，AST 检查不可信"
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ("$($c.CommandElements[0].Extent.Text)" -ne 'Add-KaLog') { continue }
                $n2 = ([regex]::Matches($c.Extent.Text, '\p{IsCJKUnifiedIdeographs}')).Count
                if ($n2) { $bad += ('{0}:{1} 有 {2} 个汉字' -f $f, $c.Extent.StartLineNumber, $n2) }
            }
        }
        Assert ($bad.Count -eq 0) ('日志里混进了句子：' + ($bad -join '；'))
    }

    It '交给面板的 Reason 不能是硬编码句子（面板会原样显示）' {
        # app.js turns any ok:false response's reason straight into an Error the user reads,
        # so a Chinese literal here is an untranslated error bubble on an English panel.
        $bad = @()
        $q = [string][char]34 + [char]39          # both quote characters, without nesting them in the literal
        $pat = "(Reason|reason)\s*=\s*\(?\s*[$q][^$q(]*\p{IsCJKUnifiedIdeographs}"
        foreach ($f in @('ka-core.ps1', 'ka-server.ps1', 'ka-worker.ps1', 'ka.ps1', 'ka-lid.ps1')) {
            $i = 0
            foreach ($line in [IO.File]::ReadAllLines((Join-Path $root $f))) {
                $i++
                if ($line -match '^\s*#') { continue }
                if ($line -match $pat) { $bad += ('{0}:{1}' -f $f, $i) }
            }
        }
        Assert ($bad.Count -eq 0) ('Reason 里写死了汉字，英文界面上翻不出来：' + ($bad -join '；'))
    }

    It '面板启动失败时，只引用本次进程自己说过的话' {
        # Measured failure: a slow start reported 「…日志最后一行：2026-08-29 13:57:30  SERVER
        # pid=25720 port=8791」 - the *previous* panel's success line, handed over as the
        # reason the new panel had supposedly failed. Attribution is by pid, and a startup
        # line is never a reason, so both cases are written out here against a synthetic log.
        $log = Join-Path $env:TEMP ('ka-server-log-' + [guid]::NewGuid().ToString('N') + '.log')
        try {
            @(
                '2026-08-29 13:57:30  SERVER pid=25720 port=8791 url=http://127.0.0.1:8791/'
                '2026-08-29 13:57:31  REJECT /api/x GET : origin'
                '2026-08-29 13:57:35  server start failed pid=31337 port=8791 msg=Address already in use'
                '2026-08-29 13:57:36  SERVER pid=31337 port=8792 url=http://127.0.0.1:8792/'
            ) | Set-Content -LiteralPath $log -Encoding UTF8
            Assert-Eq (Get-KaServerLastLine -LogPath $log -ServerPid 31337) `
                '2026-08-29 13:57:35  server start failed pid=31337 port=8791 msg=Address already in use' `
                '应当引用自己那行失败，而不是自己随后的成功行'
            Assert-Eq (Get-KaServerLastLine -LogPath $log -ServerPid 25720) '' '别的 pid 的话不能当本进程失败的原因'
            Assert-Eq (Get-KaServerLastLine -LogPath $log -ServerPid 99999) '' '日志里没有这个 pid 时不能编造原因'
        } finally {
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Resolve-KaLanguage：显式 > KA_LANG > config > 界面文化' {
        # Measured on this box: CurrentUICulture is en-US while InstalledUICulture is zh-CN.
        # auto must follow the culture Windows renders for THIS user, and any non-Chinese
        # machine must land on English rather than Chinese. KA_LANG exists so a user can try
        # the English CLI without editing config.json - and so this test can force it.
        $savedEnv = $env:KA_LANG
        try {
            Remove-Item Env:KA_LANG -ErrorAction SilentlyContinue
            Assert-Eq (Resolve-KaLanguage -Configured 'zh') 'zh' 'config 指定中文'
            Assert-Eq (Resolve-KaLanguage -Configured 'EN') 'en' '大小写不敏感'
            Assert-Eq (Resolve-KaLanguage -Explicit 'zh' -Configured 'en') 'zh' '显式参数最高'
            Assert-Eq (Resolve-KaLanguage -Configured 'de') (Resolve-KaLanguage) '词典外的语言必须回落到自动检测'
            $env:KA_LANG = 'en'
            Assert-Eq (Resolve-KaLanguage -Configured 'zh') 'en' 'KA_LANG 应压过 config'
            Assert-Eq (Resolve-KaLanguage -Explicit 'zh' -Configured 'zh') 'zh' '显式参数应压过环境变量'
            Remove-Item Env:KA_LANG
            $auto = Resolve-KaLanguage
            Assert ($auto -in @('zh', 'en')) "自动检测给出了语言集之外的值：$auto"
            # Ground truth read straight from the registry, not through our own helper.
            $mui = @()
            try {
                $mui = @((Get-ItemProperty 'HKCU:\Control Panel\Desktop\MuiCached' `
                                          -Name MachinePreferredUILanguages -ErrorAction Stop).MachinePreferredUILanguages)
            } catch { $mui = @() }
            $uc = ''
            try { $uc = [Globalization.CultureInfo]::CurrentUICulture.Name } catch { }
            if ($mui.Count) {
                Assert-Eq $auto $(if ("$($mui[0])".ToLowerInvariant() -like 'zh*') { 'zh' } else { 'en' }) `
                             "auto 未跟随 Windows 显示语言（首项 $($mui[0])）"
            }
            if ($mui.Count -and ("$($mui[0])".ToLowerInvariant() -like 'zh*') -and $uc -notlike 'zh*') {
                # This box is exactly in that state, so the claim is actually checked here
                # rather than merely written down: display language beats process culture.
                Assert-Eq $auto 'zh' "MuiCached=$($mui[0]) 与 CurrentUICulture=$uc 冲突时应以前者为准"
            }
            "MuiCached=$($mui -join ',') CurrentUICulture=$uc -> auto=$auto"
        } finally {
            if ($null -eq $savedEnv) { Remove-Item Env:KA_LANG -ErrorAction SilentlyContinue }
            else { $env:KA_LANG = $savedEnv }
        }
    }

    It '消息词典：两种语言键集一致、占位符对得上、缺键看得见' {
        # A translation layer fails silently in two directions: a key present in one
        # language only, and a {placeholder} renamed in one of them. Both are checked here
        # because neither shows up as a crash - the UI just goes blank or leaks braces.
        $zk = @($script:KaUi.zh.Keys | Sort-Object)
        $ek = @($script:KaUi.en.Keys | Sort-Object)
        $diff = @($zk | Where-Object { $ek -notcontains $_ }) + @($ek | Where-Object { $zk -notcontains $_ })
        Assert ($diff.Count -eq 0) ("两种语言的键集不一致：" + ($diff -join '、'))
        Assert ($zk.Count -ge 1) '消息词典是空的'
        foreach ($k in $zk) {
            foreach ($lang in @('zh', 'en')) {
                $s = "$($script:KaUi[$lang][$k])"
                Assert ($s.Trim().Length -gt 0) "$lang 的 $k 是空串"
                if ($lang -eq 'en') {
                    $cjk = ([regex]::Matches($s, '\p{IsCJKUnifiedIdeographs}')).Count
                    Assert ($cjk -eq 0) "en 的 $k 里还有 $($cjk) 个汉字没翻"
                }
            }
            $zp = @([regex]::Matches($script:KaUi.zh[$k], '\{\w+\}') | ForEach-Object { $_.Value } | Sort-Object)
            $ep = @([regex]::Matches($script:KaUi.en[$k], '\{\w+\}') | ForEach-Object { $_.Value } | Sort-Object)
            $pd = @($zp | Where-Object { $ep -notcontains $_ }) + @($ep | Where-Object { $zp -notcontains $_ })
            Assert ($pd.Count -eq 0) "$k 两种语言的占位符对不上：$(($pd -join ','))"
        }
        Assert-Eq (Get-KaText 'no.such.key') 'no.such.key' '缺键必须把键本身打出来，不能变空串'
        Assert-Eq (Get-KaNoteText 'brand-new-token') 'brand-new-token' '未知 note 要原样显示'
        Assert-Eq (Get-KaNoteText '') '' '空 note 不该被换成任何词'
        Assert-Eq (Get-KaText 'guard.defFail' @{ msg = 'boom' } -Lang 'en') 'Could not read the task definition: boom' '占位符替换不对'
        Assert ((Get-KaText 'guard.path.current' -Lang 'zh') -ne (Get-KaText 'guard.path.current' -Lang 'en')) `
               '同一键在两种语言下给出同一串，词典多半没生效'
        "词典 $($zk.Count) 键 x 2 语言"
    }

    It '缓存里的文案必须跟着语言走（换语言不能等 25 秒）' {
        # Get-KaGuardStatus caches for 25s because Get-ScheduledTask costs about a second,
        # and its `detail` is now catalog prose. A cache that ignores the language would
        # keep answering an English panel in Chinese after the visitor switched. Driven
        # through the same per-request override the server sets, not a made-up argument.
        if (-not (Get-ScheduledTask -TaskName $script:KaTaskNames[0] -ErrorAction SilentlyContinue)) {
            # detail is only prose when the first guard task exists. On a machine that
            # never registered the watchdog both languages legitimately come back empty,
            # and there is nothing here to compare.
            Skip -Why '这台机器没有登记看门狗任务，detail 在两种语言下都只能是空，无从比较'
        }
        $prevReq = $script:KaReqLang
        try {
            $script:KaReqLang = 'zh'
            $zh = Get-KaGuardStatus -CacheSeconds 999
            $script:KaReqLang = 'en'
            $en = Get-KaGuardStatus -CacheSeconds 999
            Assert ($zh.detail -and $en.detail) "有一边没给出文案：zh=[$($zh.detail)] en=[$($en.detail)]"
            Assert ($zh.detail -ne $en.detail) "切换语言后 detail 没变：两边都是 $($zh.detail)"
            Assert (([regex]::Matches($en.detail, '\p{IsCJKUnifiedIdeographs}')).Count -eq 0) "英文 detail 里还有汉字：$($en.detail)"
            # Same language twice inside the TTL must be served from the cache, not re-probed.
            $en2 = Get-KaGuardStatus -CacheSeconds 999
            Assert ($en2.detail -eq $en.detail) '同语言重复读取应当命中缓存'
        } finally {
            $script:KaReqLang = $prevReq
            # This test filled the cache with a 999-second English entry; leave no residue
            # for the tests that run after it in the same process.
            $script:KaGuardCache = $null
        }
    }

    It 'Get-KaIntent 把到期的一次性运行归零（不是故障）' {
        $orig = Read-KaJson $paths.intent
        try {
            [void](Write-KaJson $paths.intent @{ desired = 'awake'; expiresEpoch = ((Get-KaEpoch) - 60); minutes = 30; updatedAt = (Get-KaEpoch) } -Depth 3)
            $i = Get-KaIntent
            Assert-Eq $i.desired 'off' '到期后应视为已关闭'
            Assert-Eq $i.expired $true 'expired 标记'
            [void](Write-KaJson $paths.intent @{ desired = 'awake'; expiresEpoch = ((Get-KaEpoch) + 600); minutes = 30; updatedAt = (Get-KaEpoch) } -Depth 3)
            $j = Get-KaIntent
            Assert-Eq $j.desired 'awake' '未到期应仍为 awake'
            Assert-Eq $j.expired $false '未到期不应标记 expired'
        } finally {
            if ($orig) { [void](Write-KaJson $paths.intent $orig -Depth 3) }
        }
    }

    It 'worker 归属判定 只认路径本身，不认前缀' {
        $r = 'C:\ka 防休眠'
        Assert-Eq (Get-KaWorkerRoot "powershell.exe -File `"$r\ka-worker.ps1`" -Minutes 0") ($r) '带引号的 -File'
        Assert-Eq (Get-KaWorkerRoot "powershell.exe -File $r\ka-worker.ps1") ($r) '不带引号的 -File'
        Assert (Test-KaOwnWorker -CommandLine "powershell -File $r\ka-worker.ps1" -Root $r) '自己的 worker 被判成外部'
        Assert (-not (Test-KaOwnWorker -CommandLine 'powershell -File C:\ka\ka-worker.ps1' -Root $r)) '无关目录被判成了自己'
        # 旧实现用 -like "*$root*"，于是防休眠-v2 这种同前缀目录会被认成自己人
        Assert (-not (Test-KaOwnWorker -CommandLine "powershell -File $r-v2\ka-worker.ps1" -Root $r)) '同前缀的另一个目录被判成了自己 —— 会重复启动且停不掉'
        Assert (-not (Test-KaOwnWorker -CommandLine 'powershell -File C:\other\ka-worker.ps1' -Root $r)) '明确的外部目录被判成了自己'
        # 归因失败时必须倒向「我的」：空扫描会被每个界面读成「保护已关闭」
        Assert (Test-KaOwnWorker -CommandLine 'powershell -File ka-worker.ps1 -Minutes 0' -Root $r) '相对路径无法归因时应视为自己的'
        Assert (Test-KaOwnWorker -CommandLine 'powershell -File C:\x\ka-worker.ps1' -Root '') 'root 解析不出来时不能把 worker 全部丢掉'
        Assert (Test-KaOwnWorker -CommandLine 'powershell -File C:\x\ka-worker.ps1' -Root $null) 'root 为 null 同上'
    }

    It '电池策略 临界位只有在拔掉电源时才算数（本机实测踩过）' {
        function St { param($pct, $ac, $crit = $false, $has = $true)
            @{ known = $true; percent = $pct; acOnline = $ac; critical = $crit; low = $false; hasBattery = $has } }
        # 本机固件在 99% 且插着电时把 critical 置了 1，旧策略当场把保护判成"电池临界"退出
        $crit = Get-KaBatteryAction -Status (St 99 $true $true) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false
        Assert-Eq $crit.Abort '' 'critical + 交流电在 = 不中止'
        $crit2 = Get-KaBatteryAction -Status (St 3 $false $true) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false
        Assert-Eq $crit2.Abort 'battery-critical' 'critical + 拔电 = 必须中止并释放请求'
        # 降级（放弃熄屏保护）只发生在真的用电池时
        $d = Get-KaBatteryAction -Status (St 15 $false) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false
        Assert ($d.Downgrade) '电池 15% 低于阈值应降级为只保系统'
        $dAc = Get-KaBatteryAction -Status (St 15 $true) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false
        Assert (-not $dAc.Downgrade) '插着电就不该降级，即便电量低于阈值'
        Assert (-not (Get-KaBatteryAction -Status (St 15 $false) -KeepDisplayOn $false `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false).Downgrade) '本来就不保屏幕，无需降级'
        Assert (-not (Get-KaBatteryAction -Status (St 15 $false) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $false -FloorPercent 20 -Downgraded $false).Downgrade) '用户明确允许熄屏关闭时不降级'
        Assert (-not (Get-KaBatteryAction -Status (St -1 $false) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false).Downgrade) '电量未知不能当成低电量'
        # 迟滞：回到阈值以上 10 个点，或者重新插电，才恢复
        Assert (-not (Get-KaBatteryAction -Status (St 25 $false) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $true).Restore) '25% 距阈值不足 10 个点，不该恢复（会在阈值附近反复抖动）'
        Assert (Get-KaBatteryAction -Status (St 30 $false) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $true).Restore '30% 应该恢复完整请求'
        Assert (Get-KaBatteryAction -Status (St 5 $true) -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $true).Restore '重新插电应立刻恢复'
        $u = Get-KaBatteryAction -Status @{ known = $false } -KeepDisplayOn $true `
            -BatteryAllowDisplayOff $true -FloorPercent 20 -Downgraded $false
        Assert (-not $u.Abort -and -not $u.Downgrade -and -not $u.Restore) '读不到电源状态时不能动任何请求'
    }

    It 'Get-KaWorkerLastLine 只回它确实看到的那一行' {
        $f = New-TempFile -Suffix '.log'
        @('2026-01-01 00:00:00  STARTED pid=111 flags=0x1',
          '2026-01-01 00:00:01  STARTED pid=222 flags=0x1',
          '2026-01-01 00:00:02  EXIT pid=222 某种原因',
          '2026-01-01 00:00:03  GUARD action=none') | Set-Content -LiteralPath $f -Encoding UTF8
        $line = Get-KaWorkerLastLine -LogPath $f -WorkerPid 222
        Assert ($line -like '*EXIT pid=222*') "没取到 222 的最后一条：$line"
        Assert ($line.GetType().Name -eq 'String') "返回的必须是纯字符串（否则 JSON 里会变成对象）：$($line.GetType().Name)"
        Assert-Eq (Get-KaWorkerLastLine -LogPath $f -WorkerPid 999) '' '日志里没有这个 pid 时必须回空，不能编造原因'
        Assert-Eq (Get-KaWorkerLastLine -LogPath (Join-Path $env:TEMP 'no-such-ka-file.log') -WorkerPid 1) '' '日志文件不存在时回空而不抛'
    }

    Write-Host "`n== powercfg 解析 ==" -ForegroundColor Cyan

    It 'requestsoverride 解析：保守逐行保留 + 自镜像点名' {
        # Writing an override needs elevation (verified), so a populated real list could
        # not be sampled on this machine - the parser is pinned against a synthetic
        # sample instead, and the self-match is exercised exactly as report/requests
        # use it. Entries are kept verbatim; the consumers show the raw line.
        $sample = @'
[SERVICE]

[PROCESS]
powershell.exe    DISPLAY SYSTEM
ka-test-other.exe AWAYMODE

[DRIVER]
some-driver.sys   SYSTEM
'@
        $ovr = @(Read-KaRequestOverrides -Text $sample)
        Assert-Eq @($ovr).Count 3 '条目数应为 3'
        Assert-Eq "$($ovr[0].scope)" 'PROCESS' '作用域归属不对'
        Assert ($ovr[0].line -match '^powershell\.exe\s+DISPLAY SYSTEM$') "原始行应逐字保留：$($ovr[0].line)"
        $self = @(Get-KaSelfOverrides $ovr)
        Assert-Eq @($self).Count 1 '自镜像命中应为 1'
        Assert ($self[0].line -match '^powershell\.exe') '命中的应是 powershell.exe 那行'
        # pwsh.exe (PS7 host) must also match, and an empty list yields no hit.
        $pwshOnly = @(Read-KaRequestOverrides -Text "[PROCESS]`npwsh.exe DISPLAY")
        Assert-Eq @(Get-KaSelfOverrides $pwshOnly).Count 1 'pwsh.exe 也应命中'
        Assert-Eq @(Get-KaSelfOverrides @()).Count 0 '空列表不应命中'
        # Live: readable without elevation; on this box it is empty.
        $live = @(Get-KaRequestOverrides)
        "parsed=3 self-matches=1 live=$($live.Count)"
    }

    It 'GetPwrCapabilities 解码：合成缓冲逐位钉死偏移表' {
        # Layout per the SDK's own um/winnt.h (flattened, one byte per BOOLEAN). A
        # synthetic buffer pins every offset this product consumes, so a future header
        # change or a bad index shows up here instead of as a wrong machine report.
        $buf = New-Object byte[] 76
        foreach ($i in @(2, 5, 6, 8, 18, 20, 30)) { $buf[$i] = 1 }
        $c = Read-KaPowerCaps -Bytes $buf
        Assert-Eq $c.lidPresent $true 'LidPresent=offset2'
        Assert-Eq $c.s1 $false 'S1=offset3 未置位'
        Assert-Eq $c.s3 $true 'S3=offset5'
        Assert-Eq $c.s4 $true 'S4=offset6'
        Assert-Eq $c.s5 $false 'S5=offset7 未置位'
        Assert-Eq $c.hiberFilePresent $true 'HiberFilePresent=offset8'
        Assert-Eq $c.hiberboot $true 'Hiberboot=offset18'
        Assert-Eq $c.aoAc $true 'AoAc=offset20'
        Assert-Eq $c.hiberFileType 0 'HiberFileType=offset22'
        Assert-Eq $c.aoAcConnectivity $false 'AoAcConnectivity=offset23 未置位'
        Assert-Eq $c.batteriesPresent $true 'SystemBatteriesPresent=offset30'
        Assert ($null -eq (Read-KaPowerCaps -Bytes (New-Object byte[] 16))) '过短缓冲必须回 null 而不是读越界'
        $caps2 = Get-KaPowerCaps
        if ($caps2.source -ne 'api') { throw "本机 GetPwrCapabilities 应可用（Win10/11 必有 PowrProf.dll），实际 source=$($caps2.source)" }
        "offsets ok; live source=$($caps2.source)"
    }

    It 'GetPwrCapabilities 与 powercfg /a 互相印证（内核 vs 本地化文本）' {
        # Two independent sources for the same facts. The kernel bit needs no text, the
        # text parse needs no struct layout - if they disagree, either the offset table
        # or the localized section parser is broken. Both cannot be wrong the same way.
        $caps = Get-KaPowerCaps
        if ($caps.source -ne 'api') { throw "本机应走 API 主源，实际 source=$($caps.source)" }
        $s = Get-KaSleepStates
        if ($caps.s3 -ne $s.s3) {
            # VM firmware reports capabilities the hypervisor then refuses, so on guests
            # the two sources can legitimately disagree. First seen on the CI runner
            # 2026-09-08: kernel s3=False, powercfg text s3=True. Physical machines must
            # still agree - that is the parser bug this case exists to catch.
            $model = try { "$((Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10).Model)" } catch { '' }
            if ($model -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Xen|HVM domU|Bochs') {
                Skip -Why "虚机（model=$model）固件能力位与 powercfg 文本各说各话：内核 s3=$($caps.s3) 文本 s3=$($s.s3)"
            }
        }
        Assert-Eq $caps.s3 $s.s3 'S3：内核位与文本解析必须一致'
        if ($caps.aoAc) {
            Assert $s.s0 'AoAc=1：文本应把 S0 低电量待机列为可用'
            if (-not $caps.s3) { Assert $s.modernStandby 'AoAc=1 且无 S3：文本应判为现代待机' }
        } else {
            Assert (-not $s.modernStandby) 'AoAc=0：文本不应判出 S0 低电量待机'
        }
        "aoAc=$($caps.aoAc) s3=$($caps.s3) s4=$($caps.s4) hiberFile=$($caps.hiberFilePresent) hibType=$($caps.hiberFileType) lid=$($caps.lidPresent) bat=$($caps.batteriesPresent)"
    }

    It '合盖风险判定：无盖不报、隐藏诚实、AC/DC 分开点名' {
        Assert-Eq @(Get-KaLidRisk -LidAc $null -LidDc $null -LidPresent $false).Count 0 '没有盖子的机器不该有合盖风险'
        $hidden = @(Get-KaLidRisk -LidAc $null -LidDc $null -LidPresent $true)
        Assert-Eq $hidden.Count 1 '读不到合盖设置必须诚实报 lid-hidden'
        Assert-Eq "$($hidden[0].id)" 'report.risk.lid-hidden' '标记应为 lid-hidden'
        Assert-Eq @(Get-KaLidRisk -LidAc 0 -LidDc 0 -LidPresent $true).Count 0 '合盖不采取动作 = 无风险'
        $both = @(Get-KaLidRisk -LidAc 1 -LidDc 2 -LidPresent $true)
        Assert-Eq $both.Count 1 'AC/DC 都有动作应合并为一条'
        Assert-Eq "$($both[0].value)" 'ac=1/dc=2' 'AC/DC 值都要出现'
        Assert-Eq "$(@(Get-KaLidRisk -LidAc 0 -LidDc 3 -LidPresent $true)[0].value)" 'dc=3' '只有电池档有动作也要点名'
        Assert-Eq "$(@(Get-KaLidRisk -LidAc 2 -LidDc $null -LidPresent $true)[0].value)" 'ac=2' '只读得到 AC 档时报 AC 档'
    }

    function Get-OraclePowerSetting {
        <#
            A deliberately separate reading of the same powercfg text, keyed only on the
            当前交流/当前直流 labels. The shipped parser works by dropping the 可能* lines;
            if the two ever disagree, the historic "read the bounds as the value" bug is
            back. Both cannot be wrong in the same way by construction.
        #>
        param([string]$Subgroup, [string]$Setting)
        $o = @{ Ac = $null; Dc = $null; Min = $null; Max = $null }
        $out = try { ((& powercfg /q SCHEME_CURRENT $Subgroup $Setting 2>$null) | ForEach-Object { "$_" }) -join "`n" } catch { '' }
        foreach ($line in ($out -split "`n")) {
            if ($line -notmatch '0x([0-9A-Fa-f]{8})') { continue }
            $v = [Convert]::ToInt64($Matches[1], 16)
            if     ($line -match '当前交流|Current AC') { $o.Ac = $v }
            elseif ($line -match '当前直流|Current DC') { $o.Dc = $v }
            elseif ($line -match '可能最小|Minimum Possible') { $o.Min = $v }
            elseif ($line -match '可能最大|Maximum Possible') { $o.Max = $v }
        }
        return $o
    }

    foreach ($probe in @(
            @{ label = '睡眠超时'; sub = 'SUB_SLEEP'; set = 'STANDBYIDLE' },
            @{ label = '熄屏超时'; sub = 'SUB_VIDEO'; set = 'VIDEOIDLE' })) {

        It "解析 $(${probe}.label) 当前值 = 按标签独立解析的结果" {
            $o = Get-OraclePowerSetting -Subgroup $probe.sub -Setting $probe.set
            if ($null -eq $o.Ac) { throw "powercfg 输出里找不到「当前交流」标签，oracle 失效（$($probe.set)）" }
            $r = Get-PowerSetting $probe.sub $probe.set
            Assert-Eq $r.Ac $o.Ac 'AC 值'
            if ($null -ne $o.Dc) { Assert-Eq $r.Dc $o.Dc 'DC 值' }
            Assert ($r.Found) 'Found 应为 true'
            "ac=$($r.Ac) dc=$($r.Dc)"
        }

        It "$(${probe}.label) 不会把设置的下限当成当前值" {
            $o = Get-OraclePowerSetting -Subgroup $probe.sub -Setting $probe.set
            $r = Get-PowerSetting $probe.sub $probe.set
            if ($null -ne $o.Min -and $o.Min -ne $o.Ac) {
                Assert ($r.Ac -ne $o.Min) "返回了可能最小值 $($o.Min) —— 这正是历史上把边界读成当前值的 bug"
            }
            if ($null -ne $o.Max -and $o.Max -ne $o.Ac) {
                Assert ($r.Ac -ne $o.Max) "返回了可能最大值 $($o.Max)"
            }
            "ac=$($r.Ac) min=$($o.Min) max=$($o.Max)"
        }
    }

    # 别的语言版本的 Windows 上 powercfg 的标签不认识，但缩进结构不变。这里用真机 dump 的
    # 字节结构做夹具：只换标签文字，缩进保持原样（当前值 4 空格、属性行 6 空格）。
    $fxBody = @(
        '    电源设置 GUID: 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e  (在此时间后关闭显示)'
        '      {0}: 0x00000000'
        '      {1}: 0xffffffff'
        '      {2}: 0x00000001'
        '    {3}: 0x00000258'
        '    {4}: 0x000000b4'
    )
    $fxZh = ($fxBody -join "`n") -f '最小可能的设置', '最大可能的设置', '可能的设置增量', '当前交流电源设置索引', '当前直流电源设置索引'
    $fxEn = ($fxBody -join "`n") -f 'Minimum Possible Setting', 'Maximum Possible Setting', 'Possible Setting Increment', 'Current AC Power Setting Index', 'Current DC Power Setting Index'
    $fxDe = ($fxBody -join "`n") -f 'Mögliche Mindesteinstellung', 'Mögliche Maximaleinstellung', 'Mögliche Einstellungsschrittweite', 'Aktuelle Netzbetrieb Einstellung', 'Aktuelle Akku Betrieb Einstellung'

    It '中英以外的标签靠缩进读对（开源到别的语言版本 Windows 的关键）' {
        $zh = Get-PowerSetting -Text $fxZh
        $en = Get-PowerSetting -Text $fxEn
        $de = Get-PowerSetting -Text $fxDe
        Assert-Eq $zh.Source 'label' '中文夹具应命中标签'
        Assert-Eq $en.Source 'label' '英文夹具应命中标签'
        Assert-Eq $de.Source 'indent' '德文夹具应退回缩进规则'
        foreach ($pair in @(@($zh, 'zh'), @($en, 'en'), @($de, 'de'))) {
            Assert-Eq $pair[0].Ac 600 "$($pair[1]) AC"
            Assert-Eq $pair[0].Dc 180 "$($pair[1]) DC"
            Assert ($pair[0].Found) "$($pair[1]) Found"
        }
        "de ac=$($de.Ac) de dc=$($de.Dc) source=$($de.Source)"
    }

    It '标签和缩进都对不上时报未知，不把边界当成当前值' {
        $flat = ($fxDe -split "`n" | ForEach-Object { $_ -replace '^    ', '      ' }) -join "`n"
        $r = Get-PowerSetting -Text $flat
        Assert (-not $r.Found) "Found=$($r.Found) ac=$($r.Ac) —— 结构变了必须认不出，不能猜"
        Assert-Eq $null $r.Ac 'AC 必须为 null'
        Assert-Eq '' $r.Source '认不出时不应留下来源标记'
        $empty = Get-PowerSetting -Text ''
        Assert (-not $empty.Found) '空输入应返回未知'
        $onlyMin = Get-PowerSetting -Text '      Mögliche Mindesteinstellung: 0x00000000'
        Assert (-not $onlyMin.Found) '只有边界行时必须未知'
    }

    It '-Text 解析与直接查询本机得到同一个数' {
        $live = Get-PowerSetting 'SUB_VIDEO' 'VIDEOIDLE'
        $dump = ((& powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null) | ForEach-Object { "$_" }) -join "`n"
        $r = Get-PowerSetting -Text $dump
        Assert ($live.Found -and $r.Found) '本机读不到熄屏超时，无法比对'
        Assert-Eq $r.Ac $live.Ac '离线解析 AC'
        Assert-Eq $r.Dc $live.Dc '离线解析 DC'
        "videoAc=$($r.Ac) videoDc=$($r.Dc)"
    }

    It 'Get-KaPlan 返回报告需要的全部分组' {
        $p = Get-KaPlan
        foreach ($k in @('sleepAcSec', 'sleepDcSec', 'videoAcSec', 'videoDcSec', 'lidAc', 'lidDc',
                         'unattendedAcSec', 'consoleLockAc', 'hybridSleep', 'screensaver',
                         'inactivityPolicySec')) {
            Assert ($p.ContainsKey($k)) "缺少 $k"
        }
        $s = Get-KaSleepStates
        Assert ($s.ContainsKey('s0') -and $s.ContainsKey('s3') -and $s.ContainsKey('raw')) '睡眠状态结构不完整'
        "s0=$($s.s0) s3=$($s.s3) hibernate=$($s.hibernate) sleepAc=$($p.sleepAcSec)s videoAc=$($p.videoAcSec)s"
    }

    It 'Get-KaSleepStates 按结构分段，不靠被翻译的段落标题' {
        # The section a state is listed in IS the answer, and the old code found that
        # boundary by matching the zh/en "not available" heading. On any other language the
        # split matched nothing, so the unavailable section leaked in - and its reason lines
        # name S0/S3 too, which is how a German desktop got read as a Modern-Standby laptop.
        # Headings are unindented and colon-terminated in every locale; state lines are
        # indented 4 spaces; reason lines are tab-indented.
        $de = @(
            'Die folgenden Energiesparzustände sind auf diesem Computer verfügbar:'
            '    Ruhezustand (S3)'
            ''
            'Die folgenden Energiesparzustände sind auf diesem Computer nicht verfügbar:'
            '    Standby (S0 Low Power Idle)'
            "`tDer Computer unterstützt S3, daher ist S0 nicht verfügbar."
        ) -join "`n"
        $d = Get-KaSleepStates -Text $de
        Assert-Eq $d.known $true '德语输出应识别出段落标题'
        Assert-Eq $d.s3 $true '应识别出可用的 S3'
        Assert-Eq $d.s0 $false '不可用段的原因行里提到的 S0 不该被当成支持'
        Assert-Eq $d.modernStandby $false 'S3 台式机不该被判成现代待机'

        $ja = @(
            'このコンピューターでは次のスリープ状態を使用できます：'
            '    スタンバイ (S0 低電力アイドル) ネットワークに接続'
            '    休止状態'
            ''
            'このコンピューターでは次のスリープ状態を使用できません：'
            '    スタンバイ (S1)'
            "`tファームウェアはこのスタンバイ状態をサポートしていません。"
        ) -join "`n"
        $j = Get-KaSleepStates -Text $ja
        Assert-Eq $j.s0 $true '全角冒号的段落标题也要认'
        Assert-Eq $j.s3 $false '日语 S0 机器不该被读出 S3'
        Assert-Eq $j.modernStandby $true 'S0 且无 S3 = 现代待机'
        # Honest limitation: the label fallback only knows the zh/en words, so 休止状態 is
        # invisible to it. That is precisely why a live machine answers hibernation from the
        # registry - a key name is the only thing here that is never translated.
        Assert-Eq $j.hibernate $false '标签回落只认中英两种写法'
        Assert-Eq $j.hibSource 'label' '-Text 时不该去读本机注册表，结果才与测试所在机器无关'

        $en = @(
            'The following sleep states are available on this computer:'
            '    Standby (S0 Low Power Idle) Network Connected'
            '    Hibernate'
            ''
            'The following sleep states are not available on this computer:'
            '    Standby (S1)'
            "`tThe firmware does not support this standby state."
        ) -join "`n"
        $e = Get-KaSleepStates -Text $en
        Assert-Eq $e.hibernate $true '英文 Hibernate 写在可用段里应判为支持休眠'
        Assert-Eq $e.s3 $false '不可用段的固件说明里不含 S3，但结构上它也不在可用段'

        # Live: hibernation is read from a registry key name precisely because key names are
        # never localized. Compare against the value directly, not through our own reader.
        $live = Get-KaSleepStates
        $hib = $null
        try { $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled } catch { }
        if ($null -ne $hib) {
            Assert-Eq $live.hibSource 'registry' '注册表能读时不该退到标签匹配'
            Assert-Eq $live.hibernate ([bool]([int]$hib -ne 0)) "休眠判定与 HibernateEnabled=$hib 不一致"
        }
        Assert-Eq $live.known $true '真实 powercfg 输出解析不出任何段落'
        "live s0=$($live.s0) s3=$($live.s3) modern=$($live.modernStandby) hib=$($live.hibernate)/$($live.hibSource)"
    }

    It 'Get-KaReport 给出建议、把锁屏与休眠计时分开、且只发数据不发句子' {
        $r = Get-KaReport
        Assert ($r.ContainsKey('lockTightestSec') -and $r.ContainsKey('powerTightestSec')) '缺少锁屏/休眠分组'
        Assert ("$($r.recommendedWhy.id)" -like 'report.why.*') '建议理由必须是个 id，不是句子'
        Assert ($r.ContainsKey('idleSec')) '报告不再带显示行，CLI 需要的 idleSec 就得显式给'
        Assert ($r.recommendedIntervalSec -ge 10 -and $r.recommendedIntervalSec -le 3600) `
               "建议的心跳间隔不合理：$($r.recommendedIntervalSec)"
        foreach ($x in @($r.risk)) {
            Assert ("$($x.id)" -like 'report.risk.*') "风险条目没带 id：$(ConvertTo-Json $x -Compress)"
        }
        # The whole point of moving the wording out: anything the panel or the CLI is handed
        # can be translated. Windows names its own SKU in the OS language, so `os` is data
        # from the machine, not prose from us, and it is the one field carved out here.
        $bare = $r.Clone(); $bare.Remove('os')
        $json = ConvertTo-Json $bare -Depth 8
        $cjk = ([regex]::Matches($json, '\p{IsCJKUnifiedIdeographs}')).Count
        Assert-Eq $cjk 0 "报告载荷里还有 $cjk 个汉字，它们到了英文界面上翻不出来"
        "lock=$($r.lockTightestSec)s power=$($r.powerTightestSec)s recommend=$($r.recommendedIntervalSec)s risk=$(@($r.risk).Count)"
    }

    It '发出的每个 id（报告风险、提醒、同类软件），三本词典都有措辞且占位符拿得到数' {
        # Read from the emitter, not from a list someone maintains by hand: the day a new id
        # appears in ka-core.ps1 without wording, this fails at the source. Whole hashtable
        # literals are matched rather than "id first", because the alert entries lead with level.
        $src = [IO.File]::ReadAllText((Join-Path $root 'ka-core.ps1'))
        $js  = [IO.File]::ReadAllText((Join-Path $root 'dashboard\i18n.js'))
        $ns = 'report\.(?:risk|why)|alert|competitor'
        $emit = @{}
        foreach ($b in [regex]::Matches($src, '@\{([^}]*)\}')) {
            $body = $b.Groups[1].Value
            $idMatch = [regex]::Match($body, "\bid\s*=\s*'(($ns)\.[\w.-]+)'")
            if (-not $idMatch.Success) { continue }
            $emit[$idMatch.Groups[1].Value] = @([regex]::Matches($body, '(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        }
        Assert ($emit.Count -ge 14) "只从 ka-core.ps1 认出 $($emit.Count) 个 id，提取正则大概已经失效"
        foreach ($id in $emit.Keys) {
            foreach ($lang in @('zh', 'en')) {
                Assert ($script:KaUi[$lang].ContainsKey($id)) "$lang 词典缺 $id"
                $need = @([regex]::Matches($script:KaUi[$lang][$id], '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value })
                $miss = @($need | Where-Object { $emit[$id] -notcontains $_ })
                Assert ($miss.Count -eq 0) "$id 的 $lang 措辞要用 $($miss -join '、')，但发出端没把这些数带上"
            }
            $inJs = ([regex]::Matches($js, "'" + [regex]::Escape($id) + "'")).Count
            Assert-Eq $inJs 2 "$id 在面板词典里出现 $inJs 次，应当恰好两次（zh、en 各一次）"
        }
    }

    It '英文界面上不会有中文：Get-KaFullState 的每个字符串叶子' {
        # /api/state is the payload the panel polls every 2s. Its alert list and competitor
        # labels used to arrive as Chinese sentences, so an English page pasted Chinese into
        # the red band - the same defect the report payload had, hiding in the fields nobody
        # thought to check. Paths are excluded on purpose: this project's own folder name is
        # Chinese, and a path is the user's data, not our prose.
        $saved = $script:KaReqLang
        try {
            $script:KaReqLang = 'en'
            $json = (Get-KaFullState -Quiet) | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $walk = {
                param($node)
                if ($null -eq $node) { return @() }
                if ($node -is [string]) { return @($node) }
                if ($node -is [System.Collections.IEnumerable]) {
                    $acc = @(); foreach ($x in $node) { $acc += & $walk $x }; return $acc
                }
                $acc2 = @()
                foreach ($p in $node.PSObject.Properties) { $acc2 += & $walk $p.Value }
                return $acc2
            }
            $pp = Get-KaPath
            $roots = @($pp.root, $pp.data, $pp.machineRoot) | Where-Object { $_ }
            $leaves = & $walk $json
            $bad = @($leaves | Where-Object {
                $leaf = $_
                ($_ -match '\p{IsCJKUnifiedIdeographs}') -and
                -not (@($roots | Where-Object { $leaf -like "*$_*" }).Count)
            })
            Assert ($bad.Count -eq 0) ("英文状态里还有 $($bad.Count) 处中文：$(($bad | Select-Object -First 4) -join ' | ')")
            "strings=$(@($leaves | Where-Object { $_ }).Count) cjk=$($bad.Count)"
        } finally { $script:KaReqLang = $saved }
    }

    It '英文界面上不会有中文：ka.ps1 status 的真实输出' {
        # The CLI is a separate process with its own surface: every label, mode part,
        # balloon-style sentence and guard detail has to resolve through the dictionary.
        # History this test buries: 「看门狗 已安装（The scheduled task points at this
        # folder）」 - the detail was translated, the label around it was not.
        # Paths are exempt (the project folder name is the user's data, not our prose).
        #
        # The exit code and the "rendered to the bottom" checks are here because of a
        # crash this test used to wave through: activeFlags grew ES_CONTINUOUS
        # (0x80000003), `[int]$w.activeFlags` overflowed, and status died after the State
        # line. The error text carried the install path, so the CJK exemption swallowed
        # it and the 'State running' regex still matched the partial screen.
        $env:KA_LANG = 'en'
        try {
            $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $paths.cli status 2>&1 |
                     ForEach-Object { "$_" }) -join "`n"
            $rc = $LASTEXITCODE
        } finally { $env:KA_LANG = 'zh' }
        Assert-Eq $rc 0 "status 子进程非零退出：$(($out -split "`n" | Select-Object -First 4) -join ' / ')"
        Assert ($out -notmatch 'Cannot convert|RuntimeException|FullyQualifiedErrorId|InvalidArgument:|ParentContainsErrorRecord') "status 输出里混进了 PowerShell 报错：$(($out -split "`n" | Where-Object { $_ -match 'Cannot convert|RuntimeException|FullyQualifiedErrorId|InvalidArgument:|ParentContainsErrorRecord' } | Select-Object -First 2) -join ' | ')"
        Assert ($out -match 'State\s+running|State\s+not running') "英文 status 没有跑起来：$(($out -split "`n" | Select-Object -First 3) -join ' / ')"
        $running = $out -match 'State\s+running'
        if ($running) {
            # 从 flags=0x… 一路到底部的 Watchdog 行，少一行就是中途崩了。
            Assert ($out -match 'flags=0x[0-9a-f]{8}') "状态行没画出标志位：$(($out -split "`n" | Select-Object -First 3) -join ' | ')"
            Assert ($out -match 'Watchdog\s') 'status 没渲染到底部（Watchdog 行缺失，中途抛异常？）'
        }
        $pp = Get-KaPath
        $roots = @($pp.root, $pp.data, $pp.machineRoot) | Where-Object { $_ }
        $bad = @(($out -split "`n") | Where-Object {
            $line = $_
            ($_ -match '\p{IsCJKUnifiedIdeographs}') -and
            -not (@($roots | Where-Object { $line -like "*$_*" }).Count)
        })
        Assert ($bad.Count -eq 0) ("英文 status 还有 $($bad.Count) 行中文：$(($bad | Select-Object -First 4) -join ' | ')")
        "lines=$(@($out -split "`n").Count) cjk=$($bad.Count) rc=$rc"
    }

    It '待机原因码：506/566 Reason → 机器标记（MS 文档枚举，未知码回落原始）' {
        # 每个键都有出处，不是猜的：0/2/3/8/11/12/15/20/21/31/32/33 取自微软公开的
        # POWER_MONITOR_REQUEST_REASON（与 SleepStudy 的 exit reason 表一致），本机实测
        # 交叉验证过 3（我两次主动用 SC_MONITORPOWER 造出来）、12（视频空闲超时）、15
        # （每一条都同时带 LidOpenState=false，别的原因码没有）。11 的枚举名有文档，
        # 调用方是谁微软没说，所以名字照抄文档、不做额外解释。
        # 未知码回落 code-N：可 grep，绝不伪装成已知原因。
        # 用成对数组而不是 [ordered]@{}：PowerShell 对有序字典按位置索引，$map[2] 取到的是
        # 「第 3 项」而不是「键 2」，比较会静默错位。
        $js = [IO.File]::ReadAllText((Join-Path $root 'dashboard\i18n.js'))
        $pairs = @(
            @(0,  'unknown'),
            @(2,  'remote-connection'),
            @(3,  'sc-monitorpower'),
            @(8,  'sets'),
            @(11, 'screen-off-request'),
            @(12, 'video-idle'),
            @(15, 'lid'),
            @(20, 'sx-transition'),
            @(21, 'system-idle'),
            @(31, 'input-keyboard'),
            @(32, 'input-mouse'),
            @(33, 'input-touchpad')
        )
        foreach ($p in $pairs) {
            Assert-Eq (Get-KaStandbyReasonToken -Code $p[0]) $p[1] "原因码 $($p[0]) 应为 $($p[1])"
            $tok = $p[1]
            Assert ($script:KaUi.zh.ContainsKey("st.reason.$tok")) "服务端词典缺 st.reason.$tok"
            Assert ($script:KaUi.en.ContainsKey("st.reason.$tok")) "英文词典缺 st.reason.$tok"
            Assert-Eq ([regex]::Matches($js, [regex]::Escape("'ev.reason.$tok'"))).Count 2 `
                "面板词典里 ev.reason.$tok 不是恰好两次（zh 与 en 各一次）"
        }
        # 「事件里没有 Reason 字段」是第三种答案，和枚举自带的 0（内核明说不知道）不同源，
        # 它同样会被打进 reasons 汇总，所以三本词典都得有措辞。
        Assert ($script:KaUi.zh.ContainsKey('st.reason.no-reason')) '服务端词典缺 st.reason.no-reason'
        Assert ($script:KaUi.en.ContainsKey('st.reason.no-reason')) '英文词典缺 st.reason.no-reason'
        Assert-Eq ([regex]::Matches($js, [regex]::Escape("'ev.reason.no-reason'"))).Count 2 '面板词典里 ev.reason.no-reason 不是恰好两次'
        Assert-Eq (Get-KaReasonText 'no-reason') (Get-KaText 'st.reason.no-reason') 'no-reason 应走词典而不是原样吐标记'
        Assert-Eq (Get-KaReasonText 'code-77') 'code-77' '未知标记必须原样显示，可 grep'
        Assert-Eq (Get-KaStandbyReasonToken -Code 999) 'code-999' '999 应原样回落'
        Assert-Eq (Get-KaStandbyReasonToken -Code 0x1000001) 'code-16777217' 'PDC Task Client 的 excursion 码原样回落'
        # -Code $null 经 [int] 转换就是 0，也就是「内核没说原因」。字段缺失由调用方用
        # -match '^\d+$' 挡在门外，保持 ''（读不到 != 原因未知），这里只钉住类型边界。
        Assert-Eq (Get-KaStandbyReasonToken -Code $null) 'unknown' '$null → 0 → unknown'
    }

    It '休眠与熄屏分开计数：566 会话类型 + LidOpenState（近 14 天真实事件日志）' {
        # 506 只说明「进入低功耗会话」，单纯熄屏也算 506。本机 14 天实测 40 次 506、
        # 只有 4 次真睡到 session type 2 —— 把两者混为一谈就是这块面板原来的错。
        # 真睡眠的判据是 566 的 NextSessionType=2；合盖判据是事件自带的命名属性
        # LidOpenState（普通用户权限可读，不需要 admin）。
        $ev = Get-KaSleepEvidence -Since ((Get-Date).AddDays(-14))
        Assert $ev.queriesOk "事件日志查询失败：$($ev.reason)"
        if ([int]$ev.enters -lt 1) {
            # A fresh machine (or one that never enters standby) has no history to read.
            # The taxonomy itself is pinned by the pure-function truth tables further down.
            Skip -Why '这台机器近 14 天没有 506 低功耗会话事件，真实日志无从验证（分类由纯函数真值表钉住）'
        }
        Assert ($ev.enters -ge 1) "14 天窗口内应至少有 1 条 506，got $($ev.enters)"
        Assert $ev.sessionKnown '本机应有 566 会话事件；读不到时不得把「未知」当「没睡」'
        $ok = @('unknown','remote-connection','sc-monitorpower','sets','screen-off-request','video-idle',
                'lid','sx-transition','system-idle','input-keyboard','input-mouse','input-touchpad')
        # reason='' 是「这条 506 没带 Reason 字段」，属于合法答案（汇总里落到 no-reason 桶），
        # 不能算词汇表外的标记。
        $bad = @($ev.events | Where-Object {
            $_.kind -eq 'standbyEnter' -and "$($_.reason)" -and
            "$($_.reason)" -notmatch '^(code-\d+)$' -and ($ok -notcontains "$($_.reason)") })
        Assert ($bad.Count -eq 0) "有 $($bad.Count) 个 standbyEnter 的 reason 标记不在文档枚举内：$(($bad | Select-Object -First 3 | ForEach-Object { $_.reason }) -join ' | ')"
        $badTok = @($ev.reasons.Keys | Where-Object { $_ -ne 'no-reason' -and "$_" -notmatch '^(code-\d+)$' -and ($ok -notcontains "$_") })
        Assert ($badTok.Count -eq 0) "reasons 汇总里出现了字典无从措辞的标记：$(($badTok | Select-Object -First 3) -join ' | ')"
        $badLid = @($ev.events | Where-Object { @('', 'open', 'closed') -notcontains "$($_.lid)" })
        Assert ($badLid.Count -eq 0) "有 $($badLid.Count) 个事件的 lid 标记不是 open/closed/空：$(($badLid | Select-Object -First 3 | ForEach-Object { $_.lid }) -join ' | ')"
        $badExt = @($ev.events | Where-Object { @('', 'true', 'false') -notcontains "$($_.extMon)" })
        Assert ($badExt.Count -eq 0) "有 $($badExt.Count) 个事件的 extMon 标记不是 true/false/空：$(($badExt | Select-Object -First 3 | ForEach-Object { $_.extMon }) -join ' | ')"
        # 只有真正的进会话才计入 reasons，sum == enters 是面板所有汇总的可信底座。
        $sum = 0
        foreach ($k in @($ev.reasons.Keys)) { $sum += [int]$ev.reasons[$k] }
        Assert-Eq $sum ([int]$ev.enters) 'reasons 计数之和应等于 enters'
        # 聚合数字必须能从事件流本身重算出来 —— 谁改了分类或累加顺序就会被抓到。
        $off = @($ev.events | Where-Object { $_.kind -eq 'session' -and [int]$_.to -eq 1 }).Count
        $sleep = @($ev.events | Where-Object { $_.kind -eq 'session' -and [int]$_.to -eq 2 }).Count
        Assert-Eq $off ([int]$ev.screenOffs) 'screenOffs 与事件流里 to=1 的会话数对不上'
        Assert-Eq $sleep ([int]$ev.realSleeps) 'realSleeps 与事件流里 to=2 的会话数对不上'
        Assert ([int]$ev.realSleeps -le [int]$ev.enters) "真睡眠($($ev.realSleeps))不可能多于低功耗会话($($ev.enters))"
        # 熄屏→真睡眠的配对：独立重算一遍，若哪天把升序排序退回 Get-WinEvent 的倒序，
        # 这个数会立刻变成 0（时间差变负数），这里就是抓它的地方。
        Assert ([int]$ev.screenOffToSleep -le [int]$ev.realSleeps) '配对数不可能多于真睡眠数'
        $sorted = @($ev.events | Where-Object { $_.kind -eq 'session' } | Sort-Object epoch)
        $expect = 0; $prevOff = 0
        foreach ($s in $sorted) {
            if ($null -eq $s.to) { continue }
            if ([int]$s.to -eq 1) { $prevOff = [long]$s.epoch }
            elseif ([int]$s.to -eq 2) {
                $d = [long]$s.epoch - $prevOff
                if ($prevOff -gt 0 -and $d -ge 0 -and $d -le 120) { $expect += 1 }
                $prevOff = 0
            }
            else { $prevOff = 0 }
        }
        Assert-Eq $expect ([int]$ev.screenOffToSleep) '熄屏→真睡眠的配对数与事件流对不上（扫描顺序或配对窗口被动过）'
        if ([int]$ev.screenOffToSleep -gt 0) {
            Assert ($ev.lastScreenOffToSleepSecs -ge 1 -and $ev.lastScreenOffToSleepSecs -le 120) "最近一次熄屏到真睡眠的间隔应落在 1..120s，got $($ev.lastScreenOffToSleepSecs)"
        } else { Assert-Eq ([int]$ev.lastScreenOffToSleepSecs) 0 '没有配对时不应留下假的间隔' }
        # 事件流必须按时间升序 —— 时间轴与「最近一次」的语义都建立在这上面。
        $prevE = -1; $outOrder = 0
        foreach ($e in @($ev.events)) { if ([long]$e.epoch -lt $prevE) { $outOrder += 1 }; $prevE = [long]$e.epoch }
        Assert-Eq $outOrder 0 '事件流不是时间升序（Get-WinEvent 默认倒序，排序被去掉了）'
        # 归属三态必须把真睡眠数完整分完：漏一类，面板就能拿「剩下的那类」冒充清白。
        $placed = [int]$ev.bypasses + [int]$ev.unprotectedSleeps + [int]$ev.spanUnknown
        Assert-Eq $placed ([int]$ev.realSleeps) 'bypasses + unprotectedSleeps + spanUnknown 应等于 realSleeps'
        $bypEv = @($ev.events | Where-Object { $_.kind -eq 'session' -and [int]$_.to -eq 2 -and [int]$_.prot -eq 1 }).Count
        Assert-Eq $bypEv ([int]$ev.bypasses) 'bypasses 与事件流里 prot=1 的真睡眠对不上'
        $badProt = @($ev.events | Where-Object { @(-1, 0, 1) -notcontains [int]$_.prot })
        Assert ($badProt.Count -eq 0) "prot 只能是 -1/0/1，有 $($badProt.Count) 个事件不是"
        "enters=$($ev.enters) screenOffs=$($ev.screenOffs) realSleeps=$($ev.realSleeps) bypass=$($ev.bypasses) out=$($ev.unprotectedSleeps) unknown=$($ev.spanUnknown) offToSleep=$($ev.screenOffToSleep)($($ev.lastScreenOffToSleepSecs)s) truncated=$($ev.truncated) reasons=$(($ev.reasons.Keys | Sort-Object | ForEach-Object { "$_=$($ev.reasons[$_])" }) -join ',')"
    }

    It '事件预算：Max 命中时必须如实上报截断，不得静默少算' {
        # Get-WinEvent -MaxEvents 是整条查询的记录预算，不是每种 ID 的预算：只按
        # ProviderName 过滤时，无关的 Kernel-Power 记录会把 506 挤出窗口（实测 37→25）。
        # 结论只能建立在「没漏」上，所以漏了必须说出来。
        $probe = Get-KaSleepEvidence -Since ((Get-Date).AddDays(-14))
        if ([int]$probe.enters -le 5) {
            # Max=5 only bites when more than five relevant records exist; on a machine
            # with a thin event history the truncation argument cannot be staged at all.
            Skip -Why "这台机器 14 天内只有 $($probe.enters) 条 506，Max=5 撞不到预算"
        }
        $ev = Get-KaSleepEvidence -Since ((Get-Date).AddDays(-14)) -Max 5
        Assert $ev.queriesOk "小预算查询失败：$($ev.reason)"
        Assert $ev.truncated 'Max=5 必然撞预算，truncated 却为假说明它没在真的判定'
        Assert-Eq ([int]$ev.max) 5 'max 应回显实际生效的预算'
        $full = Get-KaSleepEvidence -Since ((Get-Date).AddDays(-14))
        Assert ([int]$full.enters -gt [int]$ev.enters) "默认预算下应比 Max=5 看到更多 506（$($full.enters) vs $($ev.enters)）"
        Assert ($full.truncated -eq $false) "默认预算($($full.max))都被截断，说明该预算已经不够用了"
    }

    It '保护区间判定：区间内 / 区间外 / 够不到，是三件不同的事' {
        # 把「不知道」压成「没请求」，工具就开始相信自己从没睡过。所以 -1 必须是第一个
        # 被检查的条件，而且 coveredFrom 之前与之后要给出不一样答案。
        $spans = @(
            [PSCustomObject]@{ from = 1000; to = 2000 },
            [PSCustomObject]@{ from = 3000; to = 4000 }
        )
        Assert-Eq (Get-KaSpanMatch -Epoch 1000 -Spans $spans -CoveredFrom 900) 1 '区间起点算被持有'
        Assert-Eq (Get-KaSpanMatch -Epoch 2000 -Spans $spans -CoveredFrom 900) 1 '区间终点算被持有'
        Assert-Eq (Get-KaSpanMatch -Epoch 1500 -Spans $spans -CoveredFrom 900) 1 '区间中间'
        Assert-Eq (Get-KaSpanMatch -Epoch 3500 -Spans $spans -CoveredFrom 900) 1 '第二段中间'
        Assert-Eq (Get-KaSpanMatch -Epoch 2500 -Spans $spans -CoveredFrom 900) 0 '两段之间的空档就是当时没请求'
        Assert-Eq (Get-KaSpanMatch -Epoch 5000 -Spans $spans -CoveredFrom 900) 0 '最后一段之后'
        Assert-Eq (Get-KaSpanMatch -Epoch 899 -Spans $spans -CoveredFrom 900) -1 '保留日志够不到的时间必须报未知'
        Assert-Eq (Get-KaSpanMatch -Epoch 900 -Spans $spans -CoveredFrom 900) 0 'coveredFrom 那一刻起算已覆盖'
        Assert-Eq (Get-KaSpanMatch -Epoch 1500 -Spans @() -CoveredFrom 900) 0 '一段都没有时，覆盖期内就是没请求，不是未知'
        Assert-Eq (Get-KaSpanMatch -Epoch 1500 -Spans $spans -CoveredFrom 0) 1 'coveredFrom=0 不得把已有区间误判成未知'
    }

    It '保护区间来自 ka.log：STARTED 打开、释放关闭，释放之后不得再算被持有' {
        # 这一条盯着的是本批次要消灭的那类谎：面板曾在「我主动 stop 之后 12 秒机器睡了」
        # 的事件上打出「电源请求被平台绕过」。测试自己解析一遍 ka.log，独立重算，
        # 不复用被测代码的判断。
        $p = Get-KaPath
        $lines = @()
        foreach ($f in @("$($p.log).1", $p.log)) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $lines += @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue)
        }
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $started = @{}; $released = @{}; $globalStop = @()
        foreach ($line in $lines) {
            if ("$line" -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$') { continue }
            $ep = 0
            try {
                $dt = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $culture)
                $ep = [DateTimeOffset]::new($dt).ToUnixTimeSeconds()
            } catch { continue }
            $body = $Matches[2]
            if ($body -match '^STOP\s') { $globalStop += [long]$ep; continue }
            if ($body -match '^STARTED\b.*\bpid=(\d+)') {
                $who = [int]$Matches[1]
                if (-not $started.ContainsKey($who)) { $started[$who] = [long]$ep }
                continue
            }
            if ($body -match '^(STOPPED|EXIT|EARLY-EXIT)\b.*\bpid=(\d+)') {
                $who = [int]$Matches[2]
                if ($started.ContainsKey($who) -and -not $released.ContainsKey($who)) { $released[$who] = [long]$ep }
            }
        }
        if ($started.Count -lt 2) {
            # Distinguish "this machine has no history" (skip honestly) from "the log
            # has STARTED lines and the regex lost them" (the parser bug this case
            # exists to catch - that must stay a failure).
            $anyStart = $false
            foreach ($f in @("$($p.log).1", $p.log)) {
                if ((Test-Path -LiteralPath $f) -and (@(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue) -match 'STARTED')) { $anyStart = $true; break }
            }
            if (-not $anyStart) {
                Skip -Why 'ka.log 里没有任何 STARTED 行（全新数据根），保护区间无从独立重算'
            }
        }
        Assert ($started.Count -ge 2) "ka.log 有 STARTED 行却只解析出 $($started.Count) 个 pid —— 正则失配，本测试已失去意义"
        $sp = Get-KaProtectedSpan
        Assert $sp.known 'ka.log 明明有 STARTED，重建结果却说无从判断'
        $spans = @($sp.spans)
        Assert ($spans.Count -ge 1) '一条保护区间都没重建出来'
        $prevTo = -1; $prevFrom = -1
        foreach ($s in $spans) {
            Assert ([long]$s.from -le [long]$s.to) "区间方向反了：$($s.from) -> $($s.to)"
            Assert ([long]$s.from -ge $prevTo) "区间没有升序或不互不重叠：$($s.from) 早于上一段的 $($prevTo)"
            $prevTo = [long]$s.to; $prevFrom = [long]$s.from
        }
        # 日志说「这一刻开始请求」，重建结果就必须认为这一刻被持有。
        foreach ($who in @($started.Keys)) {
            $m = Get-KaSpanMatch -Epoch ([long]$started[$who]) -Spans $spans -CoveredFrom ([long]$sp.coveredFrom)
            Assert-Eq $m 1 "pid=$who 的 STARTED 时刻应算保护区间内（got $m）"
        }
        # 释放之后 30 秒，若没有别的 worker 还开着，就绝不能再算被持有。
        $checked = 0
        foreach ($who in @($released.Keys)) {
            $t = [long]$released[$who] + 30
            $otherOpen = $false
            foreach ($q in @($started.Keys)) {
                if ([int]$q -eq [int]$who) { continue }
                if ([long]$started[$q] -gt $t) { continue }
                $relQ = $(if ($released.ContainsKey($q)) { [long]$released[$q] } else { [long]$t + 1 })
                $stopQ = 0
                foreach ($g in $globalStop) { if ($g -ge [long]$started[$q] -and $g -lt $relQ) { $stopQ = $g } }
                if ($stopQ -gt 0) { continue }
                if ($relQ -ge $t) { $otherOpen = $true }
            }
            if ($otherOpen) { continue }   # 另一个 worker 确实还持有，跳过才是对的
            $m = Get-KaSpanMatch -Epoch $t -Spans $spans -CoveredFrom ([long]$sp.coveredFrom)
            Assert ($m -ne 1) "pid=$who 已释放，$($t) 却被判为保护区间内（prot=$m）—— 面板就会在这种时刻喊被绕过"
            $checked += 1
        }
        Assert ($checked -ge 1) "解析到 $($released.Count) 个释放事件却一个都没检查到，本测试已失去意义"
        "spans=$($spans.Count) coveredFrom=$($sp.coveredFrom) pids=$($started.Count) released=$($checked)"
    }

    $panelVerdictName = '面板结论判定：问号、混合窗口与 506 代理，逐例钉住（node 实跑 app.js）'
    It $panelVerdictName {
        # 计数在 PowerShell 里算、也被上面那些测试钉住了；但「面板挑哪句话」此前一行测试都没有，
        # 而两个真实缺陷恰好都藏在那一层：刚启动的 worker 把无从归因的 0 次打成问号，
        # 同一个窗口里既有区间外又有够不到时只报了后者。所以这里跑的是出厂代码本身。
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) { Skip $panelVerdictName '本机没有 node，面板 JS 无法离线执行'; return }
        $src = [IO.File]::ReadAllText((Join-Path $root 'dashboard\app.js'))
        $fns = @()
        foreach ($fn in @('kaRealSleeps', 'kaRunKind', 'kaSleepsShown', 'kaVerdictKind')) {
            $m = [regex]::Match($src, "(?m)^function $fn\(ev\) \{[\s\S]*?^\}")
            Assert ($m.Success) "app.js 里找不到纯函数 $fn —— 判定被搬回渲染层了，这条测试会漏过一切"
            $fns += $m.Value
        }
        $cases = @(
            @{ name = 'fresh';      expect = @('clean', 'clean', '0', '0'); ev = @{ queriesOk = $true; sessionKnown = $false; enters = 0; realSleeps = 0; bypasses = 0; unprotectedSleeps = 0; spanUnknown = 0 } },
            @{ name = 'bypass';     expect = @('bypass', 'bypass', '1', '1'); ev = @{ queriesOk = $true; sessionKnown = $true; enters = 5; realSleeps = 1; bypasses = 1; unprotectedSleeps = 0; spanUnknown = 0 } },
            @{ name = 'out';        expect = @('unprotected', 'slept', '3', '3'); ev = @{ queriesOk = $true; sessionKnown = $true; enters = 6; realSleeps = 3; bypasses = 0; unprotectedSleeps = 3; spanUnknown = 0 } },
            @{ name = 'mixed';      expect = @('mixed', 'slept', '4', '4'); ev = @{ queriesOk = $true; sessionKnown = $true; enters = 4; realSleeps = 4; bypasses = 0; unprotectedSleeps = 3; spanUnknown = 1 } },
            @{ name = 'unplace';    expect = @('unknown', 'slept', '2', '2'); ev = @{ queriesOk = $true; sessionKnown = $true; enters = 3; realSleeps = 2; bypasses = 0; unprotectedSleeps = 0; spanUnknown = 2 } },
            @{ name = 'screenOnly'; expect = @('screenOnly', 'clean', '0', '0'); ev = @{ queriesOk = $true; sessionKnown = $true; enters = 4; realSleeps = 0; bypasses = 0; unprotectedSleeps = 0; spanUnknown = 0 } },
            @{ name = 'no566out';   expect = @('unprotected', 'slept', '?', '2'); ev = @{ queriesOk = $true; sessionKnown = $false; enters = 2; realSleeps = 0; bypasses = 0; unprotectedSleeps = 2; spanUnknown = 0 } },
            @{ name = 'no566byp';   expect = @('bypass', 'bypass', '?', '1'); ev = @{ queriesOk = $true; sessionKnown = $false; enters = 1; realSleeps = 0; bypasses = 1; unprotectedSleeps = 0; spanUnknown = 0 } },
            @{ name = 'failed';     expect = @('failed', 'unreadable', '0', '0'); ev = @{ queriesOk = $false; reason = 'x'; sessionKnown = $false; enters = 0; realSleeps = 0; bypasses = 0; unprotectedSleeps = 0; spanUnknown = 0 } },
            @{ name = 'strings';    expect = @('bypass', 'bypass', '1', '1'); ev = @{ queriesOk = $true; sessionKnown = $true; enters = '3'; realSleeps = '1'; bypasses = '1'; unprotectedSleeps = '0'; spanUnknown = '0' } },
            @{ name = 'null';       expect = @('failed', 'unreadable', '-', '-'); ev = $null }
        )
        $js = @($fns) + @(
            'const cases = ' + (ConvertTo-Json $cases -Compress -Depth 6) + ';'
            'for (const c of cases) {'
            '  const ev = c.ev;'
            '  const runKind = (ev && ev.queriesOk) ? kaRunKind(ev) : ''unreadable'';'
            '  console.log([c.name, kaVerdictKind(ev), runKind, ev ? kaSleepsShown(ev) : ''-'', ev ? kaRealSleeps(ev) : ''-''].join(''|''));'
            '}'
        )
        $harness = Join-Path $env:TEMP ('ka-panel-verdict-' + [guid]::NewGuid().ToString('N') + '.js')
        try {
            [IO.File]::WriteAllText($harness, ($js -join [Environment]::NewLine), [Text.Encoding]::ASCII)
            $rows = @(& $node.Source $harness 2>&1 | ForEach-Object { "$_" })
            Assert-Eq $LASTEXITCODE 0 "node 退出码 $LASTEXITCODE ：$(($rows | Select-Object -First 3) -join ' / ')"
            # 每个用例一行，少一行就是没跑起来 —— 空输出绝不能读成通过。
            Assert-Eq $rows.Count $cases.Count "只有 $($rows.Count) 行输出，应有 $($cases.Count) 行"
            $bad = @()
            foreach ($row in $rows) {
                $f = @($row -split '\|')
                if ($f.Count -ne 5) { $bad += "输出格式不对：$row"; continue }
                $case = $cases | Where-Object { $_.name -eq $f[0] }
                if (-not $case) { $bad += "陌生的用例名：$f[0]"; continue }
                $got = @($f[1], $f[2], $f[3], $f[4])
                for ($i = 0; $i -lt 4; $i++) {
                    if ($got[$i] -ne $case.expect[$i]) {
                        $bad += ('{0} 的 {1} 应为 {2}，实为 {3}' -f $f[0], @('verdict', 'run', 'sleepsShown', 'realSleeps')[$i], $case.expect[$i], $got[$i])
                    }
                }
            }
            Assert ($bad.Count -eq 0) (($bad -join '；'))
            ($rows -join ' ')
        } finally {
            Remove-Item -LiteralPath $harness -Force -ErrorAction SilentlyContinue
        }
    }

    It '启动预览标志：纯函数真值表（镜像 ka-worker.ps1 的标志规则，node 实跑）' {
        # 预览卡上的十六进制是「将要发送什么」的唯一出处。规则必须与 ka-worker.ps1:85-88
        # 完全一致：ES_SYSTEM_REQUIRED 恒在，keepDisplayOn 加 ES_DISPLAY_REQUIRED，
        # awayMode 加 ES_AWAYMODE_REQUIRED，ES_CONTINUOUS 恒并。电池阈值是运行时降级，
        # 不进标志 —— 谁把它塞进来，这条测试立刻抓到多出的位。
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) { Skip '启动预览标志：纯函数真值表' '本机没有 node，面板 JS 无法离线执行'; return }
        $src = [IO.File]::ReadAllText((Join-Path $root 'dashboard\app.js'))
        $m = [regex]::Match($src, "(?m)^function kaPreviewFlags\(p\) \{[\s\S]*?^\}")
        Assert ($m.Success) 'app.js 里找不到纯函数 kaPreviewFlags —— 预览逻辑搬回渲染层了'
        $cases = @(
            @{ name = 'base';     expectHex = '0x80000001'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED'; p = @{} },
            @{ name = 'dispBool'; expectHex = '0x80000003'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED+ES_DISPLAY_REQUIRED'; p = @{ keepDisplayOn = $true } },
            @{ name = 'dispStr';  expectHex = '0x80000003'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED+ES_DISPLAY_REQUIRED'; p = @{ keepDisplayOn = '1' } },
            @{ name = 'away';     expectHex = '0x80000041'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED+ES_AWAYMODE_REQUIRED'; p = @{ awayMode = 1 } },
            @{ name = 'both';     expectHex = '0x80000043'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED+ES_DISPLAY_REQUIRED+ES_AWAYMODE_REQUIRED'; p = @{ keepDisplayOn = 1; awayMode = $true } },
            @{ name = 'zeros';    expectHex = '0x80000001'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED'; p = @{ keepDisplayOn = 0; awayMode = '0' } },
            @{ name = 'null';     expectHex = '0x80000001'; expectNames = 'ES_CONTINUOUS+ES_SYSTEM_REQUIRED'; p = $null }
        )
        $js = @($m.Value) + @(
            'const cases = ' + (ConvertTo-Json $cases -Compress -Depth 6) + ';'
            'for (const c of cases) {'
            '  const r = kaPreviewFlags(c.p);'
            '  console.log([c.name, r.hex, r.names.join("+")].join("|"));'
            '}'
        )
        $harness = Join-Path $env:TEMP ('ka-preview-flags-' + [guid]::NewGuid().ToString('N') + '.js')
        try {
            [IO.File]::WriteAllText($harness, ($js -join [Environment]::NewLine), [Text.Encoding]::ASCII)
            $rows = @(& $node.Source $harness 2>&1 | ForEach-Object { "$_" })
            Assert-Eq $LASTEXITCODE 0 "node 退出码 $LASTEXITCODE ：$(($rows | Select-Object -First 3) -join ' / ')"
            Assert-Eq $rows.Count $cases.Count "只有 $($rows.Count) 行输出，应有 $($cases.Count) 行"
            $bad = @()
            foreach ($row in $rows) {
                $f = @($row -split '\|')
                if ($f.Count -ne 3) { $bad += "输出格式不对：$row"; continue }
                $case = $cases | Where-Object { $_.name -eq $f[0] }
                if (-not $case) { $bad += "陌生的用例名：$f[0]"; continue }
                if ($f[1] -ne $case.expectHex) { $bad += "$($f[0]) 的 hex 应为 $($case.expectHex)，实为 $($f[1])" }
                if ($f[2] -ne $case.expectNames) { $bad += "$($f[0]) 的标志名单应为 $($case.expectNames)，实为 $($f[2])" }
            }
            Assert ($bad.Count -eq 0) (($bad -join '；'))
            ($rows -join ' ')
        } finally {
            Remove-Item -LiteralPath $harness -Force -ErrorAction SilentlyContinue
        }
    }

    It '证据筛选判定：纯函数真值表（芯片×标记×搜索，node 实跑）' {
        # 筛选是透镜不是统计：芯片挑的是渲染层预标注的 mark（真睡眠/仅熄屏来自全表
        # 配对，不是单事件属性），搜索是大小写不敏感的子串。未知名片的芯片必须什么都
        # 不匹配 —— 「不认识」默认放行是筛选类 UI 最经典的谎言。
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) { Skip '证据筛选判定：纯函数真值表' '本机没有 node，面板 JS 无法离线执行'; return }
        $src = [IO.File]::ReadAllText((Join-Path $root 'dashboard\app.js'))
        $m = [regex]::Match($src, "(?m)^function kaEventMatches\(e, f\) \{[\s\S]*?^\}")
        Assert ($m.Success) 'app.js 里找不到纯函数 kaEventMatches —— 筛选逻辑搬回渲染层了'
        $enter = @{ kind = 'standbyEnter'; mark = 'enter'; prot = 1; lid = 'closed'; extMon = ''; reason = 'lid'; id = 506; clock = '01:02:03' }
        $cases = @(
            @{ name = 'all';        expect = 1; e = $enter; f = @{ chip = 'all'; q = '' } },
            @{ name = 'sleepRed';   expect = 1; e = $enter; f = @{ chip = 'sleep'; q = '' } },
            @{ name = 'sleepOut';   expect = 1; e = @{ kind = 'standbyEnter'; mark = 'enter enter--out'; prot = 0; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'sleep'; q = '' } },
            @{ name = 'sleepDim';   expect = 0; e = @{ kind = 'standbyEnter'; mark = 'dim'; prot = 0; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'sleep'; q = '' } },
            @{ name = 'sleepExit';  expect = 0; e = @{ kind = 'standbyExit'; mark = 'exit'; prot = ''; lid = ''; reason = ''; id = 507; clock = '' }; f = @{ chip = 'sleep'; q = '' } },
            @{ name = 'offDim';     expect = 1; e = @{ kind = 'standbyEnter'; mark = 'dim'; prot = 0; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'screenOff'; q = '' } },
            @{ name = 'offEnter';   expect = 0; e = $enter; f = @{ chip = 'screenOff'; q = '' } },
            @{ name = 'lidExit';    expect = 1; e = @{ kind = 'standbyExit'; mark = 'exit'; prot = ''; lid = 'closed'; reason = ''; id = 507; clock = '' }; f = @{ chip = 'lid'; q = '' } },
            @{ name = 'lidOpen';    expect = 0; e = @{ kind = 'standbyEnter'; mark = 'enter'; prot = 1; lid = 'open'; reason = ''; id = 506; clock = '' }; f = @{ chip = 'lid'; q = '' } },
            @{ name = 'lidEmpty';   expect = 0; e = @{ kind = 'standbyEnter'; mark = 'enter'; prot = 1; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'lid'; q = '' } },
            @{ name = 'bypassOne';  expect = 1; e = $enter; f = @{ chip = 'bypass'; q = '' } },
            @{ name = 'bypassZero'; expect = 0; e = @{ kind = 'standbyEnter'; mark = 'enter enter--out'; prot = 0; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'bypass'; q = '' } },
            @{ name = 'outZero';    expect = 1; e = @{ kind = 'standbyEnter'; mark = 'enter enter--out'; prot = 0; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'out'; q = '' } },
            @{ name = 'outUnknown'; expect = 0; e = @{ kind = 'standbyEnter'; mark = 'enter enter--unknown'; prot = -1; lid = ''; reason = ''; id = 506; clock = '' }; f = @{ chip = 'out'; q = '' } },
            @{ name = 'badChip';    expect = 0; e = $enter; f = @{ chip = 'nonsense'; q = '' } },
            @{ name = 'qUpper';     expect = 1; e = $enter; f = @{ chip = 'all'; q = 'LID' } },
            @{ name = 'qClock';     expect = 1; e = $enter; f = @{ chip = 'all'; q = '01:02' } },
            @{ name = 'qId';        expect = 1; e = $enter; f = @{ chip = 'all'; q = '506' } },
            @{ name = 'qMiss';      expect = 0; e = $enter; f = @{ chip = 'all'; q = 'zzz' } },
            @{ name = 'qAndChip';   expect = 0; e = $enter; f = @{ chip = 'bypass'; q = 'video' } },
            @{ name = 'qAndChipOk'; expect = 1; e = $enter; f = @{ chip = 'bypass'; q = 'closed' } },
            @{ name = 'nullEvent';  expect = 0; e = $null; f = @{ chip = 'all'; q = '' } }
        )
        $js = @($m.Value) + @(
            'const cases = ' + (ConvertTo-Json $cases -Compress -Depth 6) + ';'
            'for (const c of cases) { console.log([c.name, kaEventMatches(c.e, c.f) ? 1 : 0].join("|")); }'
        )
        $harness = Join-Path $env:TEMP ('ka-evf-' + [guid]::NewGuid().ToString('N') + '.js')
        try {
            [IO.File]::WriteAllText($harness, ($js -join [Environment]::NewLine), [Text.Encoding]::ASCII)
            $rows = @(& $node.Source $harness 2>&1 | ForEach-Object { "$_" })
            Assert-Eq $LASTEXITCODE 0 "node 退出码 $LASTEXITCODE ：$(($rows | Select-Object -First 3) -join ' / ')"
            Assert-Eq $rows.Count $cases.Count "只有 $($rows.Count) 行输出，应有 $($cases.Count) 行"
            $bad = @()
            foreach ($row in $rows) {
                $f = @($row -split '\|')
                if ($f.Count -ne 2) { $bad += "输出格式不对：$row"; continue }
                $case = $cases | Where-Object { $_.name -eq $f[0] }
                if (-not $case) { $bad += "陌生的用例名：$f[0]"; continue }
                if ([int]$f[1] -ne [int]$case.expect) { $bad += "$($f[0]) 应为 $($case.expect)，实为 $($f[1])" }
            }
            Assert ($bad.Count -eq 0) (($bad -join '；'))
            ($rows -join ' ')
        } finally {
            Remove-Item -LiteralPath $harness -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "`n== 原生调用 ==" -ForegroundColor Cyan

    It 'UIPI 输入拦截判定：纯函数真值表' {
        # UIPI only blocks lower -> higher. -1 (unmeasured) and 0 (no foreground) must
        # NOT read as blocked: an unknown state neither fakes a skip nor discards a
        # pulse that may well have landed.
        Assert-Eq (Test-KaInputBlocked -SelfIl 0x2000 -ForegroundIl 0x3000) $true '中→高 必须判拦截'
        Assert-Eq (Test-KaInputBlocked -SelfIl 0x3000 -ForegroundIl 0x2000) $false '高→中 不拦'
        Assert-Eq (Test-KaInputBlocked -SelfIl 0x2000 -ForegroundIl 0x2000) $false '同级 不拦'
        Assert-Eq (Test-KaInputBlocked -SelfIl 0x1000 -ForegroundIl 0x4000) $true '低→系统 必须判拦截'
        Assert-Eq (Test-KaInputBlocked -SelfIl -1 -ForegroundIl 0x3000) $false '自身未知 → 不判拦截'
        Assert-Eq (Test-KaInputBlocked -SelfIl 0x2000 -ForegroundIl -1) $false '前台未知 → 不判拦截'
        Assert-Eq (Test-KaInputBlocked -SelfIl 0x2000 -ForegroundIl 0) $false '无前台窗口 → 不判拦截'
    }

    It '完整性读取：同一令牌两条路一致，前台探测形状正确' {
        $self = [Ka.Native]::SelfIntegrityRid()
        Assert ($self -ge 0x1000 -and $self -le 0x4000) "自进程 IL 不在已知 RID 范围：0x$('{0:X}' -f $self)"
        # Oracle: OpenProcess(自己)→token 与直开自己令牌是两条独立路径，必须同一答案。
        $viaPid = [Ka.Native]::ProcessIntegrityRid([uint32]$PID)
        Assert-Eq $viaPid $self '两条完整性读取路径结果不同'
        $probe = Get-KaForegroundIntegrity
        Assert ($probe.fgPid -ge 0) "fgPid 不应为负：$($probe.fgPid)"
        Assert ($probe.fgIl -eq -1 -or ($probe.fgIl -ge 0x1000 -and $probe.fgIl -le 0x4000)) "fgIl 既非未知也不在已知范围：$($probe.fgIl)"
        $expect = Test-KaInputBlocked -SelfIl $probe.selfIl -ForegroundIl $probe.fgIl
        Assert-Eq $probe.blocked $expect 'blocked 必须与纯函数一致'
        "selfIl=0x$('{0:X4}' -f $self) fgPid=$($probe.fgPid) fgIl=$($probe.fgIl) blocked=$($probe.blocked)"
    }

    $f15Name = '心跳 F15 真的重置系统空闲计时器'
    It $f15Name {
        # UIPI can make this unmeasurable: SendInput succeeds, the events die at the
        # integrity boundary, and the idle timer keeps climbing. That is the product
        # behaving as documented (the worker records it as skipped:il-mismatch), not a
        # regression - so say so and skip instead of failing the run.
        $gate = Get-KaInputGate
        if ($gate.blocked) {
            $selfIl = Format-KaIl $gate.selfIl
            $fgIl = Format-KaIl $gate.fgIl
            Skip $f15Name "前台是更高完整性进程（$($gate.fgName) pid=$($gate.fgPid) $fgIl > 自身 $selfIl），UIPI 丢弃注入的输入"
            return
        }
        $before = [Ka.Native]::SecondsSinceInput()
        Assert ($before -ge 0) "读不到空闲时间：$before"
        $ok = [Ka.Native]::PulseF15()
        Assert-Eq $ok $true 'SendInput 拒绝了 F15'
        Start-Sleep -Milliseconds 300
        $after = [Ka.Native]::SecondsSinceInput()
        Assert ($after -lt 5) "心跳后空闲时间仍为 $([math]::Round($after,1)) 秒（应接近 0）"
        if ($before -gt 5) { Assert ($after -lt $before) "空闲计时未被重置：$before -> $after" }
        "before=$([math]::Round($before,1))s -> after=$([math]::Round($after,1))s"
    }

    $nudgeName = '心跳 鼠标微动重置空闲计时'
    It $nudgeName {
        $gate = Get-KaInputGate
        if ($gate.blocked) {
            $selfIl = Format-KaIl $gate.selfIl
            $fgIl = Format-KaIl $gate.fgIl
            Skip $nudgeName "前台是更高完整性进程（$($gate.fgName) pid=$($gate.fgPid) $fgIl > 自身 $selfIl），UIPI 丢弃注入的输入"
            return
        }
        $ok = [Ka.Native]::NudgeMouse()
        Assert ($ok -eq $true -or $ok -eq $false) "NudgeMouse 未返回布尔值：$ok"
        Start-Sleep -Milliseconds 300
        Assert ([Ka.Native]::SecondsSinceInput() -lt 5) '鼠标心跳没有重置空闲计时'
        "restored=$ok"
    }

    It '心跳 鼠标微动把指针放回原位（区分我们的排队事件与别人在动鼠标）' {
        # NudgeMouse 的自检只说明「注入的那一刻」位置是对的。SendInput 是排队的，
        # 我们自己的还原事件理论上可能晚落地，所以即时读一次、120ms 后再读一次：
        #   即时读不等   -> 还原丢了，真故障，立刻失败
        #   晚读偏 ≤2px  -> 量级正好是我们那 1px，仍然算我们的责任
        #   晚读偏 >2px  -> 只可能是第三方输入（手在触摸板上），换一次尝试
        $tries = 0; $good = $false; $noise = 0; $detail = ''
        while ($tries -lt 6 -and -not $good) {
            $tries++
            $start = [KaTestCursor]::Get()
            if (-not $start) { throw 'GetCursorPos 失败，无法验证还原' }
            $ok = [Ka.Native]::NudgeMouse()
            $imm = [KaTestCursor]::Get()
            Start-Sleep -Milliseconds 120
            $late = [KaTestCursor]::Get()
            $detail = "attempt=$tries start=$start imm=$imm late=$late nativeSaid=$ok"
            $sx = $start -split ','; $lx = $late -split ','
            $drift = [math]::Abs([int]$lx[0] - [int]$sx[0]) + [math]::Abs([int]$lx[1] - [int]$sx[1])
            if ($start -ne $imm) { throw "微动后光标没有立刻回到原位（还原事件丢了）：$detail" }
            if ($start -eq $late) { $good = $true }
            elseif ($drift -le 2) { throw "还原事件迟到、偏移量级指向我们自己：$detail drift=$drift" }
            else { $noise++; Start-Sleep -Milliseconds 400 }
        }
        Assert $good "6 次尝试期间都有外部输入在移动光标（$detail）—— 机器正被人使用，测不了；请在无人使用时重跑 -Only 放回原位。20 次连测的即时读与 120ms 读全部精确还原，所以这通常是环境问题不是产品问题"
        "attempts=$tries thirdPartyMoves=$noise $detail"
    }

    It '心跳 SecondsSinceInput 对 32 位 tick 回绕安全' {
        # Regression: (GetTickCount64() - (uint)dwTime) as a signed 64-bit subtraction
        # drifts to 49.7 days once the 32-bit counter wraps.
        # A pulse from any live worker — or the mouse tests just above this one — resets
        # the idle timer, which is the product working, not the arithmetic failing. Retry
        # until a sample pair lands with nothing intervening.
        $a = 0.0; $b = 0.0; $quiet = $false
        for ($try = 1; $try -le 5 -and -not $quiet; $try++) {
            $a = [Ka.Native]::SecondsSinceInput()
            Start-Sleep -Milliseconds 1500
            $b = [Ka.Native]::SecondsSinceInput()
            $quiet = ($b -ge $a)
            if (-not $quiet) { Start-Sleep -Milliseconds 3000 }
        }
        Assert $quiet "5 次采样窗口内都有输入进来，测不了单调增长（$a -> $b）"
        Assert (($b - $a) -lt 5) "两次读取差值异常：$a -> $b"
        "delta=$([math]::Round($b - $a, 2))s"
    }

    It '电源请求 SetThreadExecutionState 确实登记（用下一次调用读回）' {
        # Measured on this machine: SetThreadExecutionState returns the mask that was in
        # effect BEFORE the call. Asserting the return echoes the flags just passed can
        # therefore only fail right after a clear — the real proof a request landed is
        # that the next call reports it.
        #   clear -> apply(SYSTEM) returns 0x80000000
        #   apply(SYSTEM|DISPLAY) returns 0x80000001   <- the SYSTEM bit we asked for
        #   apply(0)                returns 0x80000003   <- the DISPLAY bit too
        $hex = { param($v) '0x' + ('{0:X8}' -f ([uint32]$v)) }
        [Ka.Native]::ClearPowerRequest()
        $g1 = [uint32][Ka.Native]::ApplyPowerRequest([uint32]1)      # ask: ES_SYSTEM_REQUIRED
        Assert ($g1 -ne 0) ('首次调用返回 0 —— 请求被内核拒绝（返回 ' + (& $hex $g1) + '）')
        $g2 = [uint32][Ka.Native]::ApplyPowerRequest([uint32]3)      # ask: + ES_DISPLAY_REQUIRED
        Assert ((($g2 -band ([uint32]1)) -ne 0) -and (($g2 -band ([uint32]2)) -eq 0)) `
            ("上一次的 ES_SYSTEM_REQUIRED 未被读回：返回 $(& $hex $g2)，期望 0x80000001")
        $g3 = [uint32][Ka.Native]::ApplyPowerRequest([uint32]0)      # ask: clear (ES_CONTINUOUS only)
        Assert ((($g3 -band ([uint32]1)) -ne 0) -and (($g3 -band ([uint32]2)) -ne 0)) `
            ("上一次的显示保护未被读回：返回 $(& $hex $g3)，期望同时含 SYSTEM|DISPLAY")
        $g4 = [uint32][Ka.Native]::ApplyPowerRequest([uint32]64)     # ask: ES_AWAYMODE_REQUIRED
        Assert (($g4 -band ([uint32]3)) -eq 0) ("清除后仍有残留请求位：返回 $(& $hex $g4)")
        [Ka.Native]::ClearPowerRequest()
        "masks: $(& $hex $g1) -> $(& $hex $g2) -> $(& $hex $g3) -> $(& $hex $g4)"
    }

    It '掩码位不串位：常量值与 ES_USER_PRESENT 陷阱钉死' {
        # Doc (learn.microsoft.com SetThreadExecutionState): ES_USER_PRESENT is "not
        # supported" and combining it with other flags makes THE WHOLE CALL FAIL - one
        # wrong bit in a mask does not weaken protection, it removes it entirely. The
        # worker builds masks only from the three constants below, so pin their values
        # (a typo shifts bits silently) and measure the doc claim on this kernel.
        Assert-Eq ([int][Ka.Native]::ES_SYSTEM_REQUIRED) 1 'ES_SYSTEM_REQUIRED 值不对'
        Assert-Eq ([int][Ka.Native]::ES_DISPLAY_REQUIRED) 2 'ES_DISPLAY_REQUIRED 值不对'
        Assert-Eq ([int][Ka.Native]::ES_AWAYMODE_REQUIRED) 0x40 'ES_AWAYMODE_REQUIRED 值不对'
        Assert (-not ([Ka.Native].GetField('ES_USER_PRESENT'))) 'native 类不应定义 ES_USER_PRESENT（未支持的值，只配当陷阱存在）'
        $r = [Ka.Native]::ApplyPowerRequest([uint32]4)
        Assert-Eq ([uint32]$r) ([uint32]0) `
            ("ES_USER_PRESENT 混入掩码竟被内核接受（返回 0x{0:X8}）——文档的『整次调用失败』在本机不成立，停止路径要重查" -f ([uint32]$r))
        [void][Ka.Native]::ClearPowerRequest()
        'constants pinned; 0x4-contaminated call rejected as documented'
    }

    It '电源请求只允许 worker 主线程发起（per-thread 所有权）' {
        # SetThreadExecutionState requests are PER-THREAD: one made by an HTTP listener
        # thread or a CLI process dies the moment that thread moves on, which reads to
        # the user as flaky protection. The invariant is structural, so scan the tree:
        # only the worker (plus ka-core, which owns the natives, and this suite, which
        # clears up after itself) may name them.
        $allowed = @('ka-worker.ps1', 'ka-core.ps1', 'ka-tests.ps1', 'probe-wow64.ps1')
        # probe-wow64 makes one real ApplyPowerRequest/ClearPowerRequest round trip per
        # leg - that round trip is how it proves 32-bit and 64-bit behave the same; it
        # clears at once and holds nothing. The v1 engine keep-awake.ps1 made power
        # requests too; it was archived into _legacy/ on 2026-09-03, and this scan does
        # not descend into subdirectories.
        $root = (Get-KaPath).root
        $files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' | ForEach-Object { $_ }) +
                 @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1' | ForEach-Object { $_ })
        $bad = @()
        foreach ($f in $files) {
            if ($allowed -contains $f.Name) { continue }
            $txt = Get-Content -LiteralPath $f.FullName -Raw
            # Call sites only: ka-lid.ps1 mentions SetThreadExecutionState in prose
            # ("has no say in it") and that is not a request.
            if ($txt -match '(ApplyPowerRequest|ClearPowerRequest|SetThreadExecutionState)\s*\(') { $bad += $f.Name }
        }
        Assert ($bad.Count -eq 0) "这些文件不该发起电源请求（per-thread 所有权）：$($bad -join ', ')"
        "scanned=$($files.Count) holders=worker-only"
    }

    It '会话 Get-KaSession 报告可信的状态而不是永远 unknown' {
        $s = Get-KaSession
        Assert ($s.state -in @('Active', 'OtherSession', 'NoConsole', 'unreadable', 'unknown')) "未知 state: $($s.state)"
        Assert ($s.state -ne 'unknown') 'state 永远是 unknown —— 说明判断逻辑没跑起来'
        Assert ($s.sessionId -ge 0) "自身会话 id 非法：$($s.sessionId)"
        Assert ($s.ContainsKey('consoleActive')) '缺少 consoleActive'
        "state=$($s.state) mine=$($s.sessionId) console=$($s.consoleSessionId) lock=$($s.lockScreen)"
    }

    It '电源 Get-KaBattery 字段自洽' {
        $b = [Ka.Native]::PowerStatus()
        Assert ($b.ContainsKey('known')) '缺少 known 字段'
        if ($b.known) {
            if ($b.hasBattery) {
                Assert ($b.percent -ge 0 -and $b.percent -le 100) "电量越界：$($b.percent)"
            } else {
                # No battery (CI runner, desktop): BatteryLifePercent reads 255 and the
                # mapping must surface that as -1, not invent a number.
                Assert-Eq ([int]$b.percent) -1 '没有电池时电量应如实报 -1，而不是编一个数'
            }
            $b.ContainsKey('acOnline') | Out-Null
        }
        "known=$($b.known) ac=$($b.acOnline) pct=$($b.percent) hasBattery=$($b.hasBattery)"
    }

    Write-Host "`n== worker 生命周期 ==" -ForegroundColor Cyan

    It '启动后恰好一个 worker，重复启动收敛' {
        [void](Stop-KaProtection -Reason 'test-preclean')
        Assert (Wait-WorkerGone) '前置清理后仍有 worker'
        $a = Start-KaProtection -Minutes 0
        Assert ($a.Ok) "首次启动失败：$($a.Reason)"
        $b = Start-KaProtection -Minutes 0
        Assert ($b.Ok -and $b.AlreadyRunning) "重复启动未报告 AlreadyRunning：$($b | ConvertTo-Json -Compress)"
        # "Ok" 只有在进程还活着时才算数。这台机器上真实发生过：worker 上报完状态就因
        # 固件把电池临界位置 1 而自行退出，而每个界面都在说「保护运行中」。
        Start-Sleep -Seconds 6
        Assert (Get-Process -Id $a.Pid -ErrorAction SilentlyContinue) "启动成功后 6 秒内进程消失（pid=$($a.Pid)）"
        Start-Sleep -Seconds 2
        Assert-Eq (@(Get-KaWorker).Count) 1 'worker 数量'
    }

    It 'worker 如实上报生效的标志位而不是请求的标志位' {
        Assert (Ensure-Worker) '无法保证有 worker 在跑'
        Start-Sleep -Seconds 2
        $st = Get-KaWorkerState
        Assert ($st) '读不到 worker 状态'
        $flags = [long]$st.activeFlags
        Assert (($flags -band 1) -ne 0) "系统请求未生效：0x{0:X8}"
        # The bit this test exists for: ApplyPowerRequest sends ES_CONTINUOUS | flags, so a
        # reported mask without it is the *argument*, not the registration. That read as
        # "ES_CONTINUOUS 未登记" in the panel's per-bit table on a machine that was in fact
        # registered continuously - the one surface that is supposed to be pure fact.
        Assert (($flags -band [long][Ka.Native]::ES_CONTINUOUS) -ne 0) `
            "上报的掩码缺 ES_CONTINUOUS（请求的掩码冒充生效的掩码）：0x$('{0:X8}' -f $flags)"
        Assert (($st.PSObject.Properties['baseFlags']) -and (([long]$st.baseFlags -band [long][Ka.Native]::ES_CONTINUOUS) -ne 0) ) `
            "baseFlags 也没带上真正发送的 ES_CONTINUOUS：0x$('{0:X8}' -f [long]$st.baseFlags)"
        Assert ($st.PSObject.Properties['pulses']) '缺少 pulses 字段'
        Assert ($st.PSObject.Properties['lastPulseResult']) '缺少 lastPulseResult 字段'
        # ka.log 的 STARTED 行必须报同一个生效掩码。曾经它报的是请求值 0x00000003，而
        # state.json 报 0x80000003 —— 取证时两个现场各说一套，等于没有现场。
        $started = @(Get-Content -LiteralPath $paths.log -Tail 400 -ErrorAction SilentlyContinue |
                     Where-Object { $_ -match "STARTED pid=$([int]$st.pid) " }) | Select-Object -Last 1
        Assert ($started -and "$started" -match 'flags=0x([0-9a-fA-F]{8})') "ka.log 里找不到该 worker 的 STARTED 行（pid=$($st.pid)）"
        Assert-Eq "0x$($Matches[1].ToUpperInvariant())" ("0x{0:X8}" -f $flags) 'ka.log 的 STARTED flags 与 state.json 的 activeFlags 不一致'
        $age = (Get-KaEpoch) - [long]$st.lastTickEpoch
        Assert ($age -le 15) "状态上报已过期 ${age}s（worker 可能卡死）"
        "flags=0x$('{0:X8}' -f $flags) pulses=$([int]$st.pulses) 上次=$($st.lastPulseResult) tick=${age}s前"
    }

    It '锁屏当场可知：安全桌面期间发 sessionLocked 提醒，worker 记下被锁的时间戳' {
        # Get-KaSession decides "locked" from the logonui.exe process name, so a copy of
        # cmd.exe renamed to logonui.exe exercises the shipped rule end to end. Forging
        # state.json instead is not an option: a live worker rewrites that file within a
        # second (measured while hand-verifying the lid alert), which is exactly why that
        # branch could never become a test and this one can.
        # History: the only trace of the 23:13 lock was lockSkips=1 inside a HEARTBEAT line
        # written afterwards - neither ka.log nor the panel could answer 「我是什么时候
        # 被锁掉的」.
        if (@(Get-Process -Name logonui -ErrorAction SilentlyContinue).Count -gt 0) {
            # Someone really is at the lock screen; the negative half cannot be measured.
            Assert (Ensure-Worker) '无法保证有 worker 在跑'
            $s0 = Get-KaFullState -Quiet
            Assert (@($s0.alert | Where-Object { $_.id -eq 'alert.sessionLocked' }).Count -eq 1) '会话锁着却没有 sessionLocked 提醒'
            'session already locked; positive case only'
            return
        }
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('ka-lock-' + [Guid]::NewGuid().ToString('N'))
        $exe = Join-Path $dir 'logonui.exe'
        $fixture = $null
        $seen = $null
        try {
            New-Item -ItemType Directory -Path $dir | Out-Null
            Copy-Item -LiteralPath (Join-Path $env:Windir 'System32\cmd.exe') -Destination $exe
            $fixture = Start-Process $exe -ArgumentList @('/c', 'ping', '-n', '40', '-w', '1', '127.0.0.1') -WindowStyle Hidden -PassThru
            Assert ((Get-KaSession).lockScreen) 'fixture 没能让锁屏判定为真（进程名匹配规则变了？）'
            # 10s heartbeat: engine 2 pulses on the first tick, so the skip lands at once.
            $r = Start-KaProtection -Minutes 0 -Override @{ antiLockIntervalSec = 10 }
            Assert ($r.Ok) "启动 worker 失败：$($r.Reason)"
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Milliseconds 500
                $st = Get-KaWorkerState
                if ($st -and [long]$st.lastLockEpoch -gt 0) { $seen = $st; break }
            }
            Assert ($seen) '安全桌面下跑了 15 秒，worker 仍未记下 lastLockEpoch'
            Assert ([int]$seen.lockSkips -ge 1) "lockSkips 没有增加：$([int]$seen.lockSkips)"
            Assert-Eq "$($seen.note)" 'lock-screen' 'note 标记'
            Assert ([long]$seen.lastLockEpoch -le [long]$seen.lastTickEpoch) 'lastLockEpoch 在未来'
            $log = @(Get-Content -LiteralPath $paths.log -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { "$_" })
            Assert (@($log | Where-Object { $_ -match "PULSE-SKIP pid=$($seen.pid) reason=lock-screen" }).Count -ge 1) 'ka.log 里没有带时间戳的锁屏跳过行'
            $s = Get-KaFullState -Quiet
            $a = @($s.alert | Where-Object { $_.id -eq 'alert.sessionLocked' })
            Assert-Eq $a.Count 1 '锁屏期间的 sessionLocked 提醒条数'
            Assert ([int]$a[0].count -ge 1) "提醒自带的跳过数应为正数：$($a[0].count)"
            Assert ((Get-KaProse $a[0]) -notmatch 'alert\.') '提醒没能解析成文案（词典缺键？）'
            Stop-Process -Id $fixture.Id -Force -ErrorAction SilentlyContinue
            $fixture = $null
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-KaSession).lockScreen) { break }
                Start-Sleep -Milliseconds 300
            }
            Assert (-not (Get-KaSession).lockScreen) 'fixture 已停，锁屏判定还是真'
            Assert (@((Get-KaFullState -Quiet).alert | Where-Object { $_.id -eq 'alert.sessionLocked' }).Count -eq 0) '解锁后 sessionLocked 提醒没有收回'
            "lastLockEpoch=$([long]$seen.lastLockEpoch) lockSkips=$([int]$seen.lockSkips) log=line"
        } finally {
            if ($fixture) { try { Stop-Process -Id $fixture.Id -Force -ErrorAction SilentlyContinue } catch { } }
            try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            [void](Start-KaProtection -Minutes 0)   # back to the configured heartbeat
        }
    }

    It 'UIPI 阻塞告警可行动：worker 与告警用同一 note token，双语都翻得出计数' {
        # This alert cannot be exercised end-to-end from a non-elevated test run: UIPI only
        # bites when a genuinely higher-integrity window owns the foreground, and High IL
        # cannot be forged without a UAC prompt. The live firing path was hand-verified by
        # forging note=il-mismatch into a running worker's state.json (alert appeared,
        # level=bad). What is fragile here is the two ends drifting apart, so pin it
        # statically: the token the worker writes and the string the alert matches must be
        # identical, and both dictionaries must word it - a missing 'en' key would hand the
        # panel a raw id exactly where an actionable sentence is the whole point.
        $worker = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ka-worker.ps1') -Raw
        Assert ($worker -match "note\s*=\s*'il-mismatch'") 'worker 心跳写入的 note token 不再是 il-mismatch'
        $core = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\ka-core.ps1') -Raw
        Assert ($core -match "'il-mismatch'") 'ka-core 的 uipiBlocked 告警分支不再匹配 il-mismatch'
        Assert ($core -match 'alert\.uipiBlocked') 'ka-core 里找不到 alert.uipiBlocked'
        $o = [PSCustomObject]@{ level = 'bad'; id = 'alert.uipiBlocked'; count = 3 }
        foreach ($L in 'zh', 'en') {
            $p = Get-KaProse $o -Lang $L
            Assert ($p -notmatch 'alert\.') "$L 词典翻不出 alert.uipiBlocked（原样吐 id）"
            Assert ($p -notmatch '\{count\}') "$L 的 {count} 占位符没有被替换"
            Assert ($p -match '3') "$L 解析结果里没有把计数渲染成 3"
        }
    }

    It '看门狗 把 intent=awake 而 worker 缺失的情况补上' {
        [void](Stop-KaWorker -Reason 'test')
        Assert (Wait-WorkerGone) '未能停掉 worker'
        [void](Set-KaIntent -Desired 'awake' -Minutes 0)
        $r = Reconcile-KaProtection
        Assert-Eq $r.action 'started' '应启动一个 worker'
        Assert (@(Get-KaWorker).Count -gt 0) '看门狗声称 started 但没有 worker'
    }

    It '看门狗 卡死的 worker 会被换掉（不是报告 started 就算了）' {
        # A live worker rewrites state.json every 5s, so a forged stale tick would be
        # clobbered before the reconcile read it. The decoy makes the wedge real and
        # deterministic: its command line matches the worker marker, but it never reports.
        [void](Stop-KaWorker -Reason 'test')
        Assert (Wait-WorkerGone) '前置清理失败'
        $root = (Get-KaPath).root
        $cmd = "`$null = 'ka-worker.ps1 $root'; Start-Sleep -Seconds 180"
        $decoy = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', $cmd)
        Start-Sleep -Seconds 2
        $seen = @(Get-KaWorker | ForEach-Object { $_.Pid })
        Assert ($decoy.Id -in $seen) "Get-KaWorker 没发现诱饵进程（seen=$($seen -join ',')）—— 测试前提失效"
        [void](Write-KaJson $paths.state @{
            pid = $decoy.Id; startedEpoch = ((Get-KaEpoch) - 900); expiresEpoch = 0
            lastTickEpoch = ((Get-KaEpoch) - 500); baseFlags = 3; activeFlags = 3
            keepDisplayOn = $true; displayActive = $true; antiLock = $true
            antiLockMethod = 'key'; antiLockInterval = 240; batteryFloor = 20
        } -Depth 4)
        [void](Set-KaIntent -Desired 'awake' -Minutes 0)
        try {
            $r = Reconcile-KaProtection -StaleTickSec 90
            Assert-Eq $r.action 'started' "卡死的 worker 未被更换（action=$($r.action)）"
        } finally {
            try { Stop-Process -Id $decoy.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Seconds 2
        Assert (-not (Get-Process -Id $decoy.Id -ErrorAction SilentlyContinue)) '诱饵进程仍在运行 —— 只报告了 started，没有真的更换'
        $after = @(Get-KaWorker)
        Assert-Eq $after.Count 1 '更换后 worker 数量'
        Assert ($after[0].Pid -ne $decoy.Id) '剩下的仍是诱饵进程'
        "decoy=$($decoy.Id) replaced_by=$($after[0].Pid)"
    }

    It '看门狗 尊重 intent=off（stop 必须能赢）' {
        Assert (@(Get-KaWorker).Count -gt 0) '前置条件不成立：上一个用例应留下一个 worker'
        [void](Set-KaIntent -Desired 'off')
        $r = Reconcile-KaProtection
        Assert-Eq $r.action 'stopped' 'intent=off 时应停掉 worker'
        Assert (Wait-WorkerGone) 'worker 未被停止'
        $r2 = Reconcile-KaProtection
        Assert-Eq $r2.action 'none' '第二次不应再动手'
    }

    It '协作停止不留孤儿进程与 stop.flag' {
        $a = Start-KaProtection -Minutes 0
        Assert ($a.Ok) "启动失败：$($a.Reason)"
        Start-Sleep -Seconds 2
        $r = Stop-KaProtection -Reason 'test'
        Assert (Wait-WorkerGone) "仍有 worker：$((@(Get-KaWorker) | ForEach-Object { $_.Pid }) -join ',')"
        Assert (-not (Test-Path -LiteralPath $paths.stopFlag)) 'stop.flag 未被清掉'
        Assert-Eq ([int]$r.Forced) 0 '不应走到强杀'
        $log = Get-LogTail
        Assert (@($log | Where-Object { $_ -match 'STOPPED pid=.* reason=stopped' }).Count -gt 0) `
               '日志里没有 finally 释放电源请求的记录 —— 强杀路径会让请求泄漏'
    }

    It '定时到期自行释放（不依赖人来停）' {
        $a = Start-KaProtection -Minutes 0.15     # 9 秒
        Assert ($a.Ok) "启动失败：$($a.Reason)"
        $deadline = (Get-Date).AddSeconds(50)
        while ((Get-Date) -lt $deadline -and @(Get-KaWorker).Count -gt 0) { Start-Sleep -Milliseconds 500 }
        Assert-Eq (@(Get-KaWorker).Count) 0 '到期后 worker 仍在运行'
        $log = Get-LogTail
        Assert (@($log | Where-Object { $_ -match 'STOPPED pid=.* reason=expired' }).Count -gt 0) `
               '到期退出未在日志中留下 reason=expired'
        [void](Set-KaIntent -Desired 'off')
    }

    It '其他目录的 worker 会被点名（不再对着它报「未运行」）' {
        # 每个数据目录 + 每个用户的 worker 互斥体是按哈希命名的，所以两份 clone 会各自起一个
        # 进程、各自持有电源请求。以前扫描只认本目录，另一份的存在完全看不见：这里报「已停止」，
        # 电脑却照样不睡，而且 ka.ps1 stop 对它无能为力。
        # -DataDir 必须显式给：否则这份 copy 会去哈希真实的 %LOCALAPPDATA%\KeepAwake，
        # 与测试进程自己的互斥体同名（当场在互斥门上早退，本测试就变成「没发现外部 worker」），
        # 还会把 state.json 写进开发机的真数据目录。
        $tmp = Join-Path $env:TEMP ('ka-alien-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $alienData = Join-Path $tmp 'data'
        Copy-Item -LiteralPath (Join-Path $paths.root 'ka-core.ps1') -Destination $tmp
        Copy-Item -LiteralPath $paths.worker -Destination $tmp
        try {
            $job = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f (Join-Path $tmp 'ka-worker.ps1')),
                '-KeepDisplayOn', '1', '-AntiLock', '0', '-Minutes', '5',
                '-DataDir', ('"{0}"' -f $alienData))
            $deadline = (Get-Date).AddSeconds(20)
            $alien = @()
            while ((Get-Date) -lt $deadline) {
                $alien = @(Get-KaWorker -AnyPath | Where-Object { ($_.Root -or $_.Data) -and -not $_.Mine })
                if ($alien.Count) { break }
                Start-Sleep -Milliseconds 400
            }
            Assert-Eq (@(Get-KaWorker).Count) 0 '本目录把别的目录的 worker 认成了自己的 —— 之后既停不掉也会重复启动'
            Assert-Eq $alien.Count 1 "外部 worker 没被发现（发现 $($alien.Count) 个）—— 面板会报「未运行」而电脑其实不会休眠"
            Assert ($alien[0].Root -ieq $tmp) "外部 worker 的目录没报对：$($alien[0].Root)"
            Assert ($alien[0].Data -ieq $alienData) "外部 worker 的数据目录没报对：$($alien[0].Data)（-DataDir 归属判据没被走到）"
            $fs = Get-KaFullState -Quiet
            Assert-Eq (@($fs.foreignWorkers).Count) 1 'fullState 缺少 foreignWorkers，面板与 CLI 都拿不到这个事实'
            Assert-Eq (@($fs.workerCount)) 0 '本目录的 workerCount 被外部 worker 污染了'
            $foreign = @($fs.alert | Where-Object { $_.id -eq 'alert.foreignWorkers' })
            Assert ($foreign.Count -gt 0) '外部 worker 没有生成任何提醒'
            Assert ((Get-KaProse $foreign[0] -Lang 'zh') -like '*别的目录*') 'alert.foreignWorkers 在中文词典里翻不出句子'
            Assert ((Get-KaProse $foreign[0] -Lang 'en') -notmatch '\p{IsCJKUnifiedIdeographs}') "英文提醒里混了中文：$(Get-KaProse $foreign[0] -Lang 'en')"
            "pid=$($alien[0].Pid)"
        } finally {
            try { Stop-Process -Id $job.Id -Force -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Seconds 1
            try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    It '并发启动只有一个 worker（互斥体而不是 PID 文件）' {
        $jobs = 1..3 | ForEach-Object {
            Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $paths.worker),
                '-KeepDisplayOn', '1', '-AntiLock', '1', '-Minutes', '0')
        }
        Start-Sleep -Seconds 7
        $live = @(Get-KaWorker)
        Assert-Eq $live.Count 1 "并发启动后剩 $($live.Count) 个 worker"
        [void](Stop-KaWorker -Reason 'test')
        Assert (Wait-WorkerGone) '并发测试未能清理干净'
        "spawned=$($jobs.Count)"
    }

    It '日志超过上限时轮转且不丢当前内容' {
        $cap = 4096
        $old = $script:KaLogMaxBytes
        try {
            $script:KaLogMaxBytes = $cap
            1..300 | ForEach-Object { Add-KaLog ("test-rotation {0} {1}" -f $_, (New-Object string 'x', 60)) }
            $len = (Get-Item -LiteralPath $paths.log).Length
            Assert ($len -le $cap) "日志未轮转：$len > $cap"
            Assert (Test-Path -LiteralPath "$($paths.log).1") '轮转后没有 .1 备份'
            Assert (@(Get-Content -LiteralPath "$($paths.log).1").Count -gt 0) '.1 备份是空的'
            "size=$len cap=$cap"
        } finally { $script:KaLogMaxBytes = $old }
    }

    Write-Host "`n== 面板服务端 ==" -ForegroundColor Cyan

    It 'ka-server.ps1 -SelfTest 通过' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $paths.server -SelfTest 2>&1
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        Assert ($text -match 'SELFTEST OK') "自测输出：$text"
    }

    It '服务端 在空闲端口上起来' {
        $script:SrvPort = Get-FreePort
        $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $paths.server), '-Port', "$($script:SrvPort)")
        $script:SrvPid = $p.Id
        $deadline = (Get-Date).AddSeconds(30)
        $up = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $r = Invoke-RawHttp -Port $script:SrvPort -Path '/api/ping' -Headers @{ 'X-Ka-Client' = 'ka-dashboard' }
            if ($r.Status -eq 200) { $up = $true; break }
        }
        Assert $up "面板进程未能监听 $($script:SrvPort)"
        "port=$($script:SrvPort) pid=$($p.Id)"
    }

    It '服务端 缺少 X-Ka-Client 的 /api 请求被拒（跨站页面发不出这个头）' {
        Assert ($script:SrvPort) '面板进程未起来'
        $r = Invoke-RawHttp -Port $script:SrvPort -Path '/api/state'
        Assert-Eq $r.Status 403 '无自定义头的请求'
        # The log stays machine vocabulary: a deny code, never the localized sentence -
        # otherwise the requester's language leaks into ka.log (which is ASCII forever).
        $line = @(Get-LogTail -Count 6 | Where-Object { $_ -like '*REJECT /api/state*deny=client*' })
        Assert ($line.Count -ge 1) '日志里没有 deny=client 记录'
        $hit = [regex]::Matches($line[0], '[\u4e00-\u9fff]').Count
        Assert-Eq $hit 0 '拒绝日志行混入中文'
    }

    It '服务端 伪造 Host 头（DNS rebinding）被拒' {
        Assert ($script:SrvPort) '面板进程未起来'
        $r = Invoke-RawHttp -Port $script:SrvPort -Path '/api/state' -HostHeader 'attacker.example' `
                            -Headers @{ 'X-Ka-Client' = 'ka-dashboard' }
        Assert-Eq $r.Status 403 '外站 Host'
    }

    It '服务端 外站 Origin 被拒，本机 Origin 放行' {
        Assert ($script:SrvPort) '面板进程未起来'
        $bad = Invoke-RawHttp -Port $script:SrvPort -Path '/api/state' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard'; 'Origin' = 'http://evil.example' }
        Assert-Eq $bad.Status 403 '外站 Origin'
        $good = Invoke-RawHttp -Port $script:SrvPort -Path '/api/state' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard'; 'Origin' = "http://127.0.0.1:$($script:SrvPort)" }
        Assert-Eq $good.Status 200 '本机 Origin + 正确头'
    }

    It '服务端 静态文件白名单只认那几个名字，路径遍历无效' {
        Assert ($script:SrvPort) '面板进程未起来'
        foreach ($name in @('/', '/index.html', '/app.js', '/i18n.js', '/styles.css', '/favicon.svg')) {
            $r = Invoke-RawHttp -Port $script:SrvPort -Path $name
            Assert-Eq $r.Status 200 "静态文件 $name"
        }
        $miss = Invoke-RawHttp -Port $script:SrvPort -Path '/ka-core.ps1'
        Assert ($miss.Status -in @(403, 404)) "源码路径返回了 $($miss.Status)"
        $trav = Invoke-RawHttp -Port $script:SrvPort -Path '/../../Windows/win.ini'
        Assert ($trav.Status -ne 200) '路径遍历读到了文件'
        $enc = Invoke-RawHttp -Port $script:SrvPort -Path '/%2e%2e%2f%2e%2e%2fwindows%2fwin.ini'
        Assert ($enc.Status -ne 200) '编码后的路径遍历读到了文件'
    }

    It '服务端 后端文案跟着 X-Ka-Lang 走，也不跟着上一个请求走' {
        Assert ($script:SrvPort) '面板进程未起来'
        # A value the write boundary refuses is the one request that always returns prose,
        # and refusing it writes nothing - so this can probe the language without touching
        # anyone's config.json.
        $body = (@{ patch = @{ language = 'de' } } | ConvertTo-Json -Compress)
        $before = (Get-FileHash -LiteralPath (Get-KaPath).config).Hash
        $en = Invoke-RawHttp -Port $script:SrvPort -Path '/api/config' -Method 'POST' -HostHeader '127.0.0.1' `
              -Headers @{ 'X-Ka-Client' = 'ka-dashboard'; 'X-Ka-Lang' = 'en' } -Body $body
        Assert-Eq $en.Status 400 '非法配置值该是 400（访问者的错），不是 500（服务器的错）'
        $enReason = "$((ConvertFrom-Json $en.Body).reason)"
        Assert ($enReason -match 'language') "英文拒绝里看不到是哪个键：$enReason"
        Assert (-not ($enReason -match '\p{IsCJKUnifiedIdeographs}')) "面板要的是英文，后端仍回中文：$enReason"
        $zh = Invoke-RawHttp -Port $script:SrvPort -Path '/api/config' -Method 'POST' -HostHeader '127.0.0.1' `
              -Headers @{ 'X-Ka-Client' = 'ka-dashboard'; 'X-Ka-Lang' = 'zh' } -Body $body
        Assert-Eq $zh.Status 400 'zh 请求的返回码'
        $zhReason = "$((ConvertFrom-Json $zh.Body).reason)"
        Assert ($zhReason -match '配置项') "面板要的是中文，后端却回英文：$zhReason"
        # No header at all: the previous visitor's English must not leak into this answer.
        $none = Invoke-RawHttp -Port $script:SrvPort -Path '/api/config' -Method 'POST' -HostHeader '127.0.0.1' `
                 -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -Body $body
        Assert ($none.Status -eq 400 -and (ConvertFrom-Json $none.Body).reason -match '配置项') `
            ('不带 X-Ka-Lang 的请求被上一个访客的语言带走了：' + "$((ConvertFrom-Json $none.Body).reason)")
        Assert-Eq (Get-FileHash -LiteralPath (Get-KaPath).config).Hash $before '被拒绝的写入仍然改了 config.json'
    }

    It '服务端 GET 不改变任何状态，写操作只在 POST 上' {
        Assert ($script:SrvPort) '面板进程未起来'
        $before = (Read-KaJson $paths.intent).desired
        $g = Invoke-RawHttp -Port $script:SrvPort -Path '/api/stop' -HostHeader '127.0.0.1' `
             -Headers @{ 'X-Ka-Client' = 'ka-dashboard' }
        Assert ($g.Status -ne 200) "GET /api/stop 竟然执行了（$($g.Status)）"
        Assert-Eq (Read-KaJson $paths.intent).desired $before 'GET 改了 intent'
    }

    It '服务端 查询串真的解析（?hours / ?tail 不是摆设）' {
        Assert ($script:SrvPort) '面板进程未起来'
        # [Uri]::Query 带前导 '?'，曾经让每个请求的第一个参数落到 "?hours" 键上被忽略。
        $ev = Invoke-RawHttp -Port $script:SrvPort -Path '/api/evidence?hours=6' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard' }
        Assert-Eq $ev.Status 200 '/api/evidence 返回'
        Assert-Eq ([int]((ConvertFrom-Json $ev.Body).hours)) 6 '面板上的时间范围是假的，后端永远查 24 小时'
        $lg = Invoke-RawHttp -Port $script:SrvPort -Path '/api/log?tail=1' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard' }
        Assert-Eq $lg.Status 200 '/api/log 返回'
        Assert (@((ConvertFrom-Json $lg.Body).lines).Count -le 1) '面板上的 tail 是假的，后端固定回 60 行'
    }

    It '服务端 /api/start 的电池阈值与心跳参数真的传到 worker' {
        Assert ($script:SrvPort) '面板进程未起来'
        [void](Stop-KaProtection -Reason 'test')
        $body = @{ minutes = 0; keepDisplayOn = $true; antiLock = $true; antiLockMethod = 'mouse'
                   antiLockIntervalSec = 10; batteryFloorPercent = 55 } | ConvertTo-Json -Compress
        $null = Invoke-RawHttp -Port $script:SrvPort -Path '/api/start' -Method 'POST' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -Body $body
        $deadline = (Get-Date).AddSeconds(30)
        $st = $null
        while ((Get-Date) -lt $deadline) {
            $st = Get-KaWorkerState
            if ($st) { break }
            Start-Sleep -Milliseconds 500
        }
        Assert ($st) 'worker 未上报状态'
        Assert-Eq ([int]$st.batteryFloor) 55 '电池阈值未生效（面板上的这个数字是假的）'
        Assert-Eq ([string]$st.antiLockMethod) 'mouse' '心跳方式未生效'
        Assert-Eq ([int]$st.antiLockInterval) 10 '心跳间隔未生效'
        $out = Invoke-RawHttp -Port $script:SrvPort -Path '/api/stop' -Method 'POST' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -Body '{}'
        Assert-Eq $out.Status 200 '停止接口返回'
        Assert (Wait-WorkerGone) 'POST /api/stop 后仍有 worker'
    }

    It '服务端 面板首页能取到 app.js 与 styles.css 的实际内容' {
        Assert ($script:SrvPort) '面板进程未起来'
        $r = Invoke-RawHttp -Port $script:SrvPort -Path '/app.js'
        Assert ($r.Text -match 'X-Ka-Client') 'app.js 内容不对（未包含请求头常量）'
        $i = Invoke-RawHttp -Port $script:SrvPort -Path '/i18n.js'
        Assert ($i.Text -match "'zh'" -and $i.Text -match "'en'" -and $i.Text -match 'KA\.t|window\.KA') 'i18n.js 内容不对（两本词典没同时送达）'
        $c = Invoke-RawHttp -Port $script:SrvPort -Path '/styles.css'
        Assert ($c.Text -match '--go') 'styles.css 内容不对（未包含设计变量）'
        $f = Invoke-RawHttp -Port $script:SrvPort -Path '/favicon.svg'
        Assert ($f.Text -match '<svg') 'favicon.svg 内容不对'
    }

    It '服务端 /api/start 回显的 applied 含面板读取的每个键' {
        # The toast is built from r.applied, and the "取值已被边界修正" note compares
        # applied.batteryFloorPercent against what was sent. A key missing from applied
        # reads as NaN, so the panel cried "clamped" on every single start.
        Assert ($script:SrvPort) '面板进程未起来'
        [void](Stop-KaProtection -Reason 'test')
        $sent = @{ minutes = 0; keepDisplayOn = $true; antiLock = $true; antiLockMethod = 'key'
                   antiLockIntervalSec = 300; awayMode = $false; batteryFloorPercent = 45 }
        $out = Invoke-RawHttp -Port $script:SrvPort -Path '/api/start' -Method 'POST' -HostHeader '127.0.0.1' `
                -Headers @{ 'X-Ka-Client' = 'ka-dashboard' } -Body ($sent | ConvertTo-Json -Compress)
        Assert-Eq $out.Status 200 '/api/start 返回'
        $j = $out.Body | ConvertFrom-Json
        Assert ($j.applied) '响应里没有 applied —— 面板只能显示自己发出去的值'
        $miss = @()
        foreach ($k in @('keepDisplayOn', 'antiLock', 'antiLockMethod', 'antiLockIntervalSec',
                         'awayMode', 'batteryFloorPercent', 'batteryAllowDisplayOff')) {
            if (-not (@($j.applied.PSObject.Properties.Name) -contains $k)) { $miss += $k }
        }
        Assert ($miss.Count -eq 0) ('applied 缺少 ' + ($miss -join '、') + ' —— 面板的回显与夹取提示不可信')
        Assert-Eq ([int]$j.applied.batteryFloorPercent) 45 'applied 电池阈值与发出值不符'
        Assert-Eq ([int]$j.applied.antiLockIntervalSec) 300 'applied 心跳间隔与发出值不符'
        Assert ($j.PSObject.Properties.Name -contains 'Pid') '响应里没有 Pid'
        [void](Stop-KaProtection -Reason 'test')
        "applied: $($j.applied | ConvertTo-Json -Compress)"
    }

    It '面板生命周期 Start-KaServer 认出健康面板并复用同一 pid' {
        # /api/* answers 403 unless X-Ka-Client is exactly "ka-dashboard". A probe sending
        # any other id makes a healthy panel look dead: start reported failure after a
        # 15s wait, and the already-running path killed and respawned a working panel.
        [void](Stop-KaServer)
        $b1 = Start-KaServer
        Assert ($b1.Ok) "第一次启动面板失败：$($b1.Reason)"
        Assert ($b1.Newly) '第一次调用应当是新起进程'
        $b2 = Start-KaServer
        Assert ($b2.Ok) "健康面板被当成死的：$($b2.Reason)"
        Assert (-not $b2.Newly) '第二次调用又新起了一个面板进程'
        Assert-Eq ([string]$b2.Pid) ([string]$b1.Pid) 'pid 变了 —— 说明复用失败、面板被重启'
        $z = Stop-KaServer
        Assert-Eq ([int]$z.Stopped) 1 '收尾时停不掉自己起的面板'
        "pid=$($b1.Pid) reused=$($b2.Pid)"
    }

    It '面板发现 手敲相对路径起的面板也能被停掉' {
        # Discovery used to require the project root inside the command line. A panel
        # started from inside the folder (`-File ka-server.ps1`) has no root there, so
        # Stop-KaServer reported Stopped=0, the port stayed squatted and every later
        # start died with an HttpListener prefix conflict.
        [void](Stop-KaServer)
        $free = Get-FreePort
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'ka-server.ps1', '-Port', [string]$free)
        $proc = Start-Process powershell.exe -ArgumentList $a -WindowStyle Hidden -WorkingDirectory $paths.root -PassThru
        try {
            $up = $false
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 300
                if (Test-KaUrl "http://127.0.0.1:$free/api/ping") { $up = $true; break }
            }
            Assert ($up) '手起的面板没有起来'
            $cl = "$((Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine)"
            Assert ($cl -notlike "*$($paths.root)*") "测试前提不成立：命令行里已含 root（$cl）"
            $d = @(Get-KaServer)
            Assert ($d.Pid -contains $proc.Id) 'Get-KaServer 认不出相对路径启动的面板'
            $s = Stop-KaServer
            Assert-Eq ([int]$s.Stopped) 1 'Stop-KaServer 仍是空操作'
            Start-Sleep -Milliseconds 800
            Assert (-not (Test-KaUrl "http://127.0.0.1:$free/api/ping")) '停掉后端口仍在响应'
            # Not "the legacy .server.json is gone" - panels now write .server-<port>.json, so
            # that path would be absent no matter what. The fact worth pinning is that no
            # handle survives the process it describes. The message is built from raw paths:
            # when $left is empty, $left.Path is null and Split-Path would reject it - the
            # message argument is evaluated even when this assertion is about to pass.
            $left = @(Get-KaServerHints | Where-Object { $_.Port -eq $free })
            Assert ($left.Count -eq 0) "面板已退出，句柄却留着：$(@($left.Path) -join ', ')"
            "pid=$($proc.Id) port=$free"
        } finally {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    Write-Host "`n== 计划任务（看门狗） ==" -ForegroundColor Cyan

    It '登录触发器 当前用户范围（非管理员也能注册看门狗）' {
        # `New-ScheduledTaskTrigger -AtLogOn` without -User means "at the logon of ANY
        # user", and that registration is administrator-only. Shipped that way, `ka.ps1
        # guard` failed with "Access is denied" on a standard account while the product
        # promises elevation is never needed.
        $probe = "$($script:KaTaskNames[0])-probe-$PID"
        $me = ([Security.Principal.WindowsIdentity]::GetCurrent()).Name
        Assert ($me) "读不到当前账户名，测试本身失效"
        try {
            $act = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -Argument '-NoProfile -Command Write-Host probe'
            $trig = New-ScheduledTaskTrigger -AtLogOn -User $me
            Register-ScheduledTask -TaskName $probe -Action $act -Trigger $trig -Force -ErrorAction Stop | Out-Null
            $t = Get-ScheduledTask -TaskName $probe -ErrorAction SilentlyContinue
            Assert ($t) "注册后查不到任务 $probe"
            $tu = "$($t.Triggers[0].UserId)"
            Assert ($tu) '登录触发器没有绑定用户，正是原来那个需要管理员的写法'
            "user=$tu state=$($t.State)"
        } finally {
            try { Unregister-ScheduledTask -TaskName $probe -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        }
        Assert (-not (Get-ScheduledTask -TaskName $probe -ErrorAction SilentlyContinue)) "探测任务 $probe 没清掉"
    }

    It '看门狗状态读取 指向当前目录且不误报已安装' {
        $g = Get-KaGuardStatus -CacheSeconds 0
        # The task exists on this machine right now; the useful property is that the
        # reader ties it to *this* copy of the project rather than any stale registration.
        Assert ($g.ContainsKey('installed')) 'Get-KaGuardStatus 没有 installed 字段'
        Assert ($g.ContainsKey('tasks')) 'Get-KaGuardStatus 没有 tasks 明细'
        # Independent ground truth. installed used to be computed inside the same try as
        # the last-result formatting, so one unformattable value flipped a real
        # registration to "未安装" on the dashboard and in ka.ps1 status.
        $exists = 0
        foreach ($n in @('KeepAwake-Guard', 'KeepAwake-Logon')) {
            if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { $exists++ }
        }
        Assert-Eq $g.installed ($exists -eq 2) 'installed 必须等于计划任务的真实存在情况'
        Assert-Eq (@($g.tasks).Count) $exists 'tasks 明细数量与真实注册数一致'
        foreach ($t in @($g.tasks)) {
            Assert ($t.lastResult -notmatch 'Cannot convert| too large') "lastResult 里漏出了异常原文：$($t.lastResult)"
        }
        Assert ($g.detail -notmatch 'Cannot convert') "detail 里漏出了异常原文：$($g.detail)"
        # The optional boot task is reported but never gated on: its registration is
        # administrator-only (verified on a standard account - S4U, interactive and
        # both-triggers all get "Access is denied"), so the common install has no
        # KeepAwake-Boot and `installed` must stay true without it.
        Assert ($g.ContainsKey('boot')) 'Get-KaGuardStatus 缺少 boot 字段'
        $bootReallyThere = [bool](Get-ScheduledTask -TaskName 'KeepAwake-Boot' -ErrorAction SilentlyContinue)
        Assert-Eq $g.boot.present $bootReallyThere 'boot.present 必须等于 KeepAwake-Boot 的真实存在情况'
        "installed=$($g.installed) tasks=$(@($g.tasks).Count) boot.present=$($g.boot.present) detail=$($g.detail)"
    }

    It '会话收养决策：只把会话 0 的 worker 迁进真实会话' {
        # The optional boot task starts a worker in session 0, which has no desktop -
        # the power request holds but heartbeats are noise there forever. The first
        # guard pass that runs in a real session adopts it. The decision is a pure
        # function, so pin every boundary: session 0 is the only wrong place, RDP
        # sessions are real sessions, and -1 (process gone) adopts nothing.
        $cases = @(
            @(1, 0, $true), @(2, 0, $true), @(7, 0, $true),
            @(0, 0, $false), @(0, -1, $false), @(0, 2, $false),
            @(1, 1, $false), @(2, 1, $false), @(1, -1, $false)
        )
        foreach ($c in $cases) {
            $got = Get-KaSessionAdoption -MySessionId $c[0] -WorkerSessionId $c[1]
            Assert-Eq $got $c[2] ("收养决策 my={0} worker={1} 应为 {2}" -f $c[0], $c[1], $c[2])
        }
        "cases=$($cases.Count)"
    }

    Write-Host "`n== 汇总 ==" -ForegroundColor Cyan
}
finally {
    if ($script:SrvPid) { try { Stop-Process -Id $script:SrvPid -Force -ErrorAction Stop } catch { } }
    try { [void](Stop-KaWorker -Reason 'test-cleanup') } catch { }
    try { if (@(Get-KaWorker).Count -eq 0) { Remove-Item -LiteralPath $paths.stopFlag -Force -ErrorAction SilentlyContinue } } catch { }
    # Stop-Process above cannot run the panel's own finally, so its .server-<port>.json would
    # leak. Only handles with no process behind them get deleted - a panel the user left
    # running keeps its handle, which is the only lead on how to find and stop it later.
    try {
        foreach ($h in @(Get-KaServerHints)) {
            if ($h.Pid -gt 0 -and (Get-Process -Id ([int]$h.Pid) -ErrorAction SilentlyContinue)) { continue }
            Remove-Item -LiteralPath $h.Path -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    Restore-Files
    Restore-GuardTasks
    if (-not $LeaveOutputs) {
        foreach ($f in $script:Temps) { try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } } catch { } }
    }
}

Write-Host ''
Write-Host ("通过 {0}，失败 {1}，跳过 {2}" -f $script:Pass, $script:Failures.Count, $script:Skipped.Count) `
    -ForegroundColor $(if ($script:Failures.Count) { 'Red' } else { 'Green' })
if ($script:Failures.Count) {
    Write-Host '失败明细：' -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
if ($script:Skipped.Count) {
    Write-Host '跳过明细：' -ForegroundColor DarkYellow
    foreach ($s in $script:Skipped) { Write-Host "  - $s" -ForegroundColor DarkYellow }
}
exit 0
