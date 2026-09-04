$ErrorActionPreference = 'Continue'
<#
    Falsifiable check of the ConstrainedLanguage gate (ka-gate.ps1 + its call sites).

    Three legs, because each one catches a different way this could be decoration:

      A. static wiring  - every entry point dot-sources the gate and exits BEFORE it can
         reach ka-core.ps1. Without this, "wired into all six" would be a claim about files
         nobody opened.
      B. dynamic refusal - a copy of each entry point, run as the process entry point (-File,
         the only shape where `exit` reaches the host code) with the language mode downgraded
         one line above the gate call. Four ka.ps1 cases also cover zh/en.
      C. mutation - the same cases against a copy whose gate call is replaced by a no-op. It
         must go red, in the exact way the gate exists to prevent: one PermissionDenied record
         naming Add-Type, exit 1, and nothing explaining itself.

    The mode is downgraded in-process because __PSLockdownPolicy is only honoured from the
    MACHINE environment, and writing that would change this box for every other program.
    zh/en is driven with KA_LANG, the tool's own documented escape hatch, so no leg depends
    on a culture switch powershell.exe 5.1 does not have.
#>
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '_tmp/clm-gate'   # scratch stays in the ignored _tmp, never beside the shipped tests
$entries = @('ka.ps1', 'ka-worker.ps1', 'ka-server.ps1', 'ka-guard.ps1', 'ka-tray.ps1', 'ka-lid.ps1')

# Each case is one entry point, the arguments that are harmless to it, and the language.
# ka-worker gets a fractional -Minutes and every non-CLI leg gets its own -DataDir, so a leg
# that somehow survives FullLanguage cannot start real protection or touch the user's state.
$cases = @(
    @{ Name = 'cli/clm/zh';    Entry = 'ka.ps1';        Args = @('status');                        Lang = 'zh'; Mode = 'clm' }
    @{ Name = 'cli/clm/en';    Entry = 'ka.ps1';        Args = @('status');                        Lang = 'en'; Mode = 'clm' }
    @{ Name = 'cli/full/zh';   Entry = 'ka.ps1';        Args = @('status');                        Lang = 'zh'; Mode = 'full' }
    @{ Name = 'cli/full/en';   Entry = 'ka.ps1';        Args = @('status');                        Lang = 'en'; Mode = 'full' }
    @{ Name = 'server/clm';    Entry = 'ka-server.ps1'; Args = @('-SelfTest');                     Lang = 'en'; Mode = 'clm' }
    @{ Name = 'tray/clm';      Entry = 'ka-tray.ps1';   Args = @('-SelfTest');                     Lang = 'en'; Mode = 'clm' }
    @{ Name = 'guard/clm';     Entry = 'ka-guard.ps1';  Args = @('-Json');                         Lang = 'en'; Mode = 'clm' }
    @{ Name = 'worker/clm';    Entry = 'ka-worker.ps1'; Args = @('-Minutes', '0.02');              Lang = 'en'; Mode = 'clm' }
    @{ Name = 'lid/clm';       Entry = 'ka-lid.ps1';    Args = @('-Action', 'status');             Lang = 'en'; Mode = 'clm' }
)

function Refusal([string]$Lang) {
    if ($Lang -eq 'zh') {
        return @{ exit = 2; must = @('防休眠无法启动', '语言模式', 'Add-Type', '代码 2', 'ConstrainedLanguage');
                  mustNot = @('PermissionDenied', 'CategoryInfo', 'FullyQualifiedErrorId', '无法将') }
    }
    return @{ exit = 2; must = @('Keep-Awake cannot start', 'language mode', 'Add-Type', 'code 2', 'ConstrainedLanguage');
              mustNot = @('PermissionDenied', 'CategoryInfo', 'FullyQualifiedErrorId', 'is not recognized') }
}

# ---------------------------------------------------------------- A. static wiring
Write-Output '--- A. every entry point gates before it loads the library'
$staticBad = 0
foreach ($e in $entries) {
    $lines = Get-Content -LiteralPath (Join-Path $root $e)
    $gate = -1; $exit = -1; $core = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i]
        if ($gate -lt 0 -and $t -like "*'ka-gate.ps1'*") { $gate = $i }
        if ($exit -lt 0 -and $t -match 'if \(-not \(Test-KaLanguageMode\)\) \{ exit 2 \}') { $exit = $i }
        if ($core -lt 0 -and ($t -like "*'ka-core.ps1'*" -or $t -eq '. $core')) { $core = $i }
    }
    $why = @()
    if ($gate -lt 0) { $why += 'no gate dot-source' }
    if ($exit -lt 0) { $why += 'no exit-2 call' }
    if ($core -lt 0) { $why += 'ka-core never dot-sourced?' }
    elseif ($exit -ge 0 -and $exit -gt $core) { $why += "gate at line $($exit+1) is after ka-core at $($core+1)" }
    if ($why) { $staticBad++ }
    Write-Host ('  {0}{1,-16} gate={2} exit={3} core={4} {5}' -f $(if ($why) { 'FAIL ' } else { 'ok   ' }),
               $e, $(if ($gate -ge 0) { $gate + 1 } else { '-' }), $(if ($exit -ge 0) { $exit + 1 } else { '-' }),
               $(if ($core -ge 0) { $core + 1 } else { '-' }), ($why -join ', '))
}

# ---------------------------------------------------------------- function-name collisions
# Two files defining the same function is silent and order-dependent, and ka-gate.ps1 exists to
# be dot-sourced ahead of ka-core.ps1 by all six entry points - so a collision there is a bug
# this probe would otherwise never see.
Write-Output '--- A2. no function defined twice across the shipped files'
$names = @{}
$collide = 0
foreach ($f in (Get-ChildItem -LiteralPath $root -Filter 'ka*.ps1' -File)) {
    $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { Write-Host ('  FAIL ' + $f.Name + ' does not parse: ' + $errs[0].Message); $collide++; continue }
    foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($names.ContainsKey($fn.Name)) {
            Write-Host ('  FAIL ' + $fn.Name + ' defined in both ' + $names[$fn.Name] + ' and ' + $f.Name); $collide++
        } else { $names[$fn.Name] = $f.Name }
    }
}
Write-Host ('  ok   ' + $names.Count + ' distinct functions in ' + (Get-ChildItem -LiteralPath $root -Filter 'ka*.ps1' -File).Count + ' files')

# ---------------------------------------------------------------- staging
function Stage([string]$Dir, [switch]$DropGate) {
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    foreach ($src in (Get-ChildItem -LiteralPath $root -Filter 'ka*.ps1' -File)) {
        $txt = [IO.File]::ReadAllText($src.FullName)
        if ($DropGate) {
            $anchor = 'if (-not (Test-KaLanguageMode)) { exit 2 }'
            if ($txt.Contains($anchor)) {
                # Replace, never delete: the copy still has to parse, or the mutation would be
                # measuring a syntax error instead of a missing gate.
                $txt = $txt.Replace($anchor, '$script:KaGateCallRemoved = $true')
            }
        }
        [IO.File]::WriteAllText((Join-Path $Dir $src.Name), $txt, (New-Object Text.UTF8Encoding $true))
    }
    # A CLM variant of each entry point: the documented in-process downgrade one line above the
    # gate call, plus a marker proving the downgrade took effect - a leg that silently stayed
    # FullLanguage would otherwise "pass" by refusing nothing at all.
    foreach ($e in $entries) {
        $txt = [IO.File]::ReadAllText((Join-Path $Dir $e))
        $anchor = ". (Join-Path `$PSScriptRoot 'ka-gate.ps1')"
        if (-not $txt.Contains($anchor)) { throw ("$e has no gate call - nothing to stage") }
        $inject = '$ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage''; Write-Host "PROBE-MODE=$($ExecutionContext.SessionState.LanguageMode)"' + "`n"
        $txt = $txt.Replace($anchor, ($inject + $anchor))
        [IO.File]::WriteAllText((Join-Path $Dir ('clm-' + $e)), $txt, (New-Object Text.UTF8Encoding $true))
    }
}

function Run-Case([string]$Dir, $c, [string]$Slot) {
    $data = Join-Path $Dir ('data-' + ($c.Name -replace '[/]', '_'))
    $argv = @($c.Args)
    $script = Join-Path $Dir $(if ($c.Mode -eq 'clm') { 'clm-' + $c.Entry } else { $c.Entry })
    if ($c.Entry -ne 'ka.ps1') { $argv += @('-DataDir', $data) }
    $prev = $env:KA_LANG
    if ($c.Lang) { $env:KA_LANG = $c.Lang }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @argv 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($null -ne $prev) { $env:KA_LANG = $prev } else { Remove-Item -LiteralPath 'env:KA_LANG' -ErrorAction SilentlyContinue }

    $text = ($out -join "`n")
    if ($c.Mode -eq 'clm') { $w = Refusal $c.Lang } else {
        $w = @{ exit = 0; must = @('Keep-Awake'); mustNot = @('cannot start', '无法启动', 'PermissionDenied', 'CategoryInfo') }
    }
    $problems = @()
    if ($c.Mode -eq 'clm' -and $text -notlike '*PROBE-MODE=ConstrainedLanguage*') { $problems += 'leg never entered CLM' }
    if ($code -ne $w.exit) { $problems += ('exit=' + $code + ' want ' + $w.exit) }
    foreach ($m in $w.must)    { if ($text -notlike ('*' + $m + '*')) { $problems += ('missing "' + $m + '"') } }
    foreach ($m in $w.mustNot) { if ($text -like  ('*' + $m + '*'))   { $problems += ('forbidden "' + $m + '"') } }
    $tag = if ($problems.Count) { 'FAIL' } else { 'ok  ' }
    Write-Host ('  {0} {1,-14} exit={2,-3} lines={3,-3} {4}' -f $tag, $c.Name, $code, $out.Count, ($problems -join '; '))
    Set-Variable -Name ('KaGate' + $Slot + ($c.Name -replace '[/]', '_')) -Value @{ code = $code; text = $text; problems = $problems } -Scope Script
}

$live = Join-Path $work 'live'
Stage $live
Write-Output '--- B. current sources, mode forced to ConstrainedLanguage one line above the gate'
foreach ($c in $cases) { Run-Case $live $c 'Cur' }

$mut = Join-Path $work 'no-gate'
Stage $mut -DropGate
Write-Output '--- C. pre-change: same files with the gate call replaced by a no-op'
$red = @()
foreach ($c in $cases) {
    if ($c.Mode -ne 'clm') { continue }
    Run-Case $mut $c 'Old'
    $r = Get-Variable -Name ('KaGateOld' + ($c.Name -replace '[/]', '_')) -ValueOnly
    if ($r.problems.Count) { $red += $c.Name }
}

$bad = 0
foreach ($c in $cases) {
    $r = Get-Variable -Name ('KaGateCur' + ($c.Name -replace '[/]', '_')) -ValueOnly
    if ($r.problems.Count) { $bad++ }
}
Write-Output ('mutation red on: ' + $(if ($red.Count) { $red -join ', ' } else { 'NOTHING - the gate is decoration' }))
$mutText = (Get-Variable -Name 'KaGateOldcli_clm_en' -ValueOnly).text
$mutFirst = @((($mutText -split "`n") | Where-Object { $_ } | Select-Object -First 4))
Write-Output ('no-gate cli/clm/en printed: ' + ($mutFirst -join ' ~ '))
if ($staticBad) { Write-Output "PROBE FAILED: $staticBad entry point(s) not gated"; exit 1 }
if ($collide)   { Write-Output "PROBE FAILED: $collide function-name collision(s)"; exit 1 }
if ($bad)       { Write-Output "PROBE FAILED: $bad live case(s) wrong"; exit 1 }
if (-not $red.Count) { Write-Output 'PROBE FAILED - removing the gate changed nothing'; exit 1 }
Write-Output ('PROBE OK: {0} cases green now, {1} red without the gate, {2} entry points gated before ka-core' -f $cases.Count, $red.Count, $entries.Count)
