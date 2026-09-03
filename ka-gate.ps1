<#
.SYNOPSIS
    Pre-library startup checks. Dot-source this from an entry point, before ka-core.ps1:

        . (Join-Path $PSScriptRoot 'ka-gate.ps1')
        if (-not (Test-KaLanguageMode)) { exit 2 }
#>

# ---------------------------------------------------------------- why this file is separate
# Two measured facts force the shape above:
#
#   1. `exit` inside a dot-sourced script does not stop the script that dot-sourced it - the
#      caller resumes on the next line, in every language mode and every invocation shape. A
#      gate that exits here therefore prints its refusal and ka.ps1 carries on and dies later
#      with "Get-KaFullState is not a cmdlet" and exit code 0 - the exact confusing failure
#      this gate exists to replace. The entry point has to own the `exit`.
#   2. The check cannot live in ka-core.ps1 at all: that is precisely the file which cannot
#      load in the environment being diagnosed. ConstrainedLanguage (WDAC, AppLocker, Smart
#      App Control, an enterprise software-restriction policy) forbids Add-Type
#      -TypeDefinition, and every Win32 call this tool makes is compiled at load.
#
# So this file re-implements in a few lines what Get-KaOsUiLanguages and Resolve-KaLanguage
# already know. That duplication is the price of running before the library exists: change all
# three or none, and note that ka-core's version is the one the test suite covers.
#
# Everything below stays inside the subset ConstrainedLanguage still allows - cmdlets, string
# operators, if/try, no methods on non-core types - because it has to execute in the mode it is
# diagnosing. It must not use the message catalog either: the catalog is in the file that
# cannot load, so both languages are spelled out.

function Write-KaGateLine {
    param([string]$Text)
    # Write-Host, not Write-Output: a line in the success stream would arrive at the caller
    # glued to the return value, turning `if (-not (Test-KaLanguageMode))` into a comparison
    # against an array. Write-Host is also the channel that can fail on a host with no
    # console - ka-guard is started that way - hence the fallback rather than silence.
    try { Write-Host $Text -ForegroundColor Red }
    catch { try { Write-Warning $Text } catch { } }
}

function Get-KaStartupLanguage {
    # 'zh' or 'en' for the only two strings this file can print. Same priority as
    # Resolve-KaLanguage, minus the config file: reading it would need the paths and the
    # JSON reader, which are in ka-core.ps1.
    $forced = "$env:KA_LANG".Trim().ToLowerInvariant()
    if ($forced -eq 'zh' -or $forced -eq 'en') { return $forced }

    $tags = @()
    try {
        # The registry first because that is the "Windows display language" the user actually
        # sees. $PSUICulture is a different signal and disagrees with it on a Chinese install
        # that kept an English MUI: measured on this box, MuiCached = zh-CN, PSUICulture = en-US.
        $v = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\MuiCached' `
                              -Name MachinePreferredUILanguages -ErrorAction Stop).MachinePreferredUILanguages
        if ($v) { $tags = @($v) }
    } catch { }
    if (-not $tags.Count) {
        try {
            $v = (Get-ItemProperty 'HKCU:\Control Panel\International\User Profile' `
                                  -Name Languages -ErrorAction Stop).Languages
            if ($v) { $tags = @($v) }
        } catch { }
    }
    if (-not $tags.Count) { $tags = @("$PSUICulture") }
    if (-not $tags.Count) { return 'zh' }

    # Only the first entry counts: the rest are fallback for components that are not installed.
    $first = "$($tags[0])".Trim().ToLowerInvariant()
    if ($first -like 'zh*') { return 'zh' }
    return 'en'
}

function Test-KaLanguageMode {
    <#
        $true when this session can compile the Win32 surface, $false after printing why it
        cannot. Returns instead of exiting so the caller picks its own exit code; the refusal
        has to be readable by a user who is never going to open a log file on this machine,
        so it names the mode and says nothing happened yet.
    #>
    $mode = 'FullLanguage'
    try { $mode = "$($ExecutionContext.SessionState.LanguageMode)" } catch { }
    if ($mode -eq 'FullLanguage') { return $true }
    # An unreadable mode is not evidence of a lockdown. Let the normal load try and fail on
    # its own terms rather than refusing to run on a machine that would have worked.
    if (-not $mode) { return $true }

    if ((Get-KaStartupLanguage) -eq 'zh') {
        Write-KaGateLine "防休眠无法启动：本机 PowerShell 的语言模式是 $mode，不是 FullLanguage。"
        Write-KaGateLine '本工具启动时用 Add-Type 现场编译 Win32 调用，而该语言模式禁止定义新类型。常见来源：WDAC、AppLocker、智能应用控制、企业软件限制策略。'
        Write-KaGateLine '已按代码 2 退出，本机未做任何改动。怎么办见 README.md「换一台 Windows 会怎样」。'
    } else {
        Write-KaGateLine "Keep-Awake cannot start: this PowerShell session is in language mode $mode, not FullLanguage."
        Write-KaGateLine 'The tool compiles its Win32 calls with Add-Type at startup, and defining new types is forbidden in this language mode. Typical sources: WDAC, AppLocker, Smart App Control, an enterprise software-restriction policy.'
        Write-KaGateLine 'Exited with code 2 without changing anything on this machine. See the machine-matrix section of README.md.'
    }
    return $false
}
