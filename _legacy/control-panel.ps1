<#
.SYNOPSIS
    防休眠控制台 - a small WPF control panel for the keep-awake tool.

.DESCRIPTION
    Shows live status, lets you start/stop the protection with one click,
    displays the machine-adaptation report and tails the log.

    Run directly:
        powershell -NoProfile -STA -ExecutionPolicy Bypass -File control-panel.ps1

    Self test (validates the UI builds, no window shown):
        powershell ... -File control-panel.ps1 -SelfTest
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $dir 'keep-awake.log'
$pidFile = Join-Path $dir '.keep-awake.pid'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="防休眠控制台 Keep-Awake" Height="610" Width="500"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize">
  <StackPanel Margin="16">
    <TextBlock x:Name="TxtStatus" FontSize="18" FontWeight="Bold" Text="状态检测中…"/>
    <TextBlock x:Name="TxtDetail" FontSize="12" Foreground="#666666" Text="" TextWrapping="Wrap"/>

    <CheckBox x:Name="ChkDisplay" Content="保持屏幕常亮（系统 + 显示器都不休眠）"
              IsChecked="True" Margin="0,14,0,0"/>
    <CheckBox x:Name="ChkAntiLock" Content="防锁屏心跳（定时模拟无害输入，重置空闲计时器）"
              IsChecked="True" Margin="0,6,0,0"/>
    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
      <TextBlock Text="运行时长(分钟, 0=一直):" VerticalAlignment="Center"/>
      <TextBox x:Name="TbMinutes" Width="60" Text="0" Margin="6,0,0,0"/>
      <TextBlock Text="心跳间隔(秒):" VerticalAlignment="Center" Margin="18,0,0,0"/>
      <TextBox x:Name="TbHeartbeat" Width="60" Text="240" Margin="6,0,0,0"/>
    </StackPanel>

    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
      <Button x:Name="BtnStart"   Content="启动保护" Width="100" Height="34"/>
      <Button x:Name="BtnStop"    Content="停止"     Width="80"  Height="34" Margin="10,0,0,0"/>
      <Button x:Name="BtnRefresh" Content="刷新"     Width="70"  Height="34" Margin="10,0,0,0"/>
    </StackPanel>

    <TextBlock Text="远程无人值守（重启 / 崩溃后自动恢复保护）" FontSize="13" FontWeight="Bold" Margin="0,16,0,4"/>
    <StackPanel Orientation="Horizontal">
      <Button x:Name="BtnGuard" Content="安装" Width="80" Height="30"/>
      <TextBlock x:Name="TxtGuard" Text="" VerticalAlignment="Center" Margin="10,0,0,0" FontSize="12"/>
    </StackPanel>

    <TextBlock Text="本机环境适配报告（check-machine）" FontSize="13" FontWeight="Bold" Margin="0,16,0,4"/>
    <TextBox x:Name="TxtEnv" Height="118" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
             VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>

    <TextBlock Text="运行日志（末尾 8 行）" FontSize="13" FontWeight="Bold" Margin="0,10,0,4"/>
    <TextBox x:Name="TxtLog" Height="96" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
             VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
  </StackPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml.OuterXml)

$TxtStatus   = $window.FindName('TxtStatus')
$TxtDetail   = $window.FindName('TxtDetail')
$ChkDisplay  = $window.FindName('ChkDisplay')
$ChkAntiLock = $window.FindName('ChkAntiLock')
$TbMinutes   = $window.FindName('TbMinutes')
$TbHeartbeat = $window.FindName('TbHeartbeat')
$BtnStart    = $window.FindName('BtnStart')
$BtnStop     = $window.FindName('BtnStop')
$BtnRefresh  = $window.FindName('BtnRefresh')
$BtnGuard    = $window.FindName('BtnGuard')
$TxtGuard    = $window.FindName('TxtGuard')
$TxtEnv      = $window.FindName('TxtEnv')
$TxtLog      = $window.FindName('TxtLog')

function Invoke-Manage {
    param([string]$ManageAction)
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               (Join-Path $dir 'manage.ps1'), '-Action', $ManageAction)

    if ($ManageAction -eq 'start') {
        if (-not $ChkDisplay.IsChecked) { $args_ += '-AllowDisplayOff' }
        if (-not $ChkAntiLock.IsChecked) { $args_ += '-NoAntiLock' }
        $m = 0; [void][double]::TryParse($TbMinutes.Text, [ref]$m)
        if ($m -gt 0) { $args_ += @('-Minutes', "$m") }
        $hb = 0; [void][int]::TryParse($TbHeartbeat.Text, [ref]$hb)
        if ($hb -gt 0) { $args_ += @('-AntiLockIntervalSec', "$hb") }
    }

    Start-Process powershell.exe -ArgumentList ($args_ | ForEach-Object { "`"$_`"" }) `
        -WindowStyle Hidden -Wait:$false | Out-Null
}

function Update-GuardState {
    $t1 = Get-ScheduledTask -TaskName 'KeepAwakeLogon' -ErrorAction SilentlyContinue
    $t2 = Get-ScheduledTask -TaskName 'KeepAwakeGuard' -ErrorAction SilentlyContinue
    if ($t1 -and $t2) {
        $TxtGuard.Text = '🛡 已安装：开机自动启动保护，每 10 分钟自检拉起（重启/崩溃也不怕）'
        $TxtGuard.Foreground = 'ForestGreen'
        $BtnGuard.Content = '卸载'
    } else {
        $TxtGuard.Text = '⚠ 未安装：电脑重启或进程意外退出后，需要手动重新启动保护'
        $TxtGuard.Foreground = 'DarkGoldenrod'
        $BtnGuard.Content = '安装'
    }
}

$BtnGuard.Add_Click({
    $act = if ($BtnGuard.Content -eq '卸载') { 'uninstall' } else { 'install' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'install-guard.ps1') -Action $act | Out-Null
    Update-GuardState
})

function Update-Status {
    $running = $false
    if (Test-Path $pidFile) {
        $storedPid = Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ("$storedPid" -match '^\d+$') {
            $p = Get-Process -Id ([int]$storedPid) -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match '^powershell') { $running = $true }
        }
    }

    if ($running) {
        $TxtStatus.Text = "🟢 保护运行中（pid $storedPid）— 电脑不会休眠、不会锁屏、屏幕常亮"
        $TxtStatus.Foreground = 'ForestGreen'
        $BtnStart.IsEnabled = $false
        $BtnStop.IsEnabled = $true
    } else {
        $TxtStatus.Text = '🔴 未启动 — 电脑将按系统默认电源计划休眠/锁屏'
        $TxtStatus.Foreground = 'Firebrick'
        $BtnStart.IsEnabled = $true
        $BtnStop.IsEnabled = $false
    }

    $tail = Get-Content $logFile -Tail 8 -ErrorAction SilentlyContinue
    $TxtLog.Text = if ($tail) { $tail -join "`n" } else { '(暂无日志)' }
}

# seed the heartbeat box from config.json when present
$cfgPath = Join-Path $dir 'config.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.antiLockIntervalSec) { $TbHeartbeat.Text = "$([int]$cfg.antiLockIntervalSec)" }
        if ($null -ne $cfg.keepDisplayOn) { $ChkDisplay.IsChecked = [bool]$cfg.keepDisplayOn }
        if ($null -ne $cfg.antiLock)      { $ChkAntiLock.IsChecked = [bool]$cfg.antiLock }
    } catch {}
}

# machine adaptation report
try {
    $envOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'check-machine.ps1') 2>&1
    $TxtEnv.Text = ($envOut | ForEach-Object { "$_" }) -join "`n"
} catch {
    $TxtEnv.Text = "环境检测失败: $_"
}

$BtnStart.Add_Click({ Invoke-Manage 'start'; Start-Sleep -Seconds 2; Update-Status })
$BtnStop.Add_Click({ Invoke-Manage 'stop'; Start-Sleep -Milliseconds 800; Update-Status })
$BtnRefresh.Add_Click({ Update-Status })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status
Update-GuardState

if ($SelfTest) {
    Write-Host 'SELFTEST OK - window built successfully (not shown).'
    $window.Close()
    exit 0
}

[void]$window.ShowDialog()
