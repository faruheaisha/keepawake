$ErrorActionPreference = 'Continue'
<#
    Does ka-tray.ps1 -SelfTest ever actually run?

    Until this probe existed the answer was no. The only CI invocation of the tray was
    tests/probe-clm-gate.ps1 case 'tray/clm', which asserts the *gate refusal* - exit 2 from
    ka-gate.ps1 at line 35, well before the self test body at line 411. So the preset
    value-fidelity check added to that body was, as written, a claim about code nothing
    executed. (ka-server.ps1 -SelfTest has always had tests/ka-tests.ps1 'ka-server.ps1
    -SelfTest 通过'; the tray had nothing.)

    Legs, because "it ran and said OK" is the weakest possible evidence here:

      1. skip-shape  - the same entry point with KA_LANG set, which makes the language half of
         the body print 'SELFTEST lang=skip' and STILL exit 0. Measured on 2026-09-26, not
         imagined. This leg is why the clean leg asserts on the two 'lang=' lines and not merely
         on 'SELFTEST OK' + exit 0.
      2. clean       - body ran in FullLanguage against a -DataDir of ours: both languages
         rendered, the menu really has its 5 duration / 4 interval items, OK printed.
      3. handoffs    - no runner in this repository ever *performs* a tray click (a real click
         starts a worker and registers a scheduled task), so the one place a preset's number
         leaves the menu and enters the engine is read off the syntax tree instead: exactly one
         duration handler passing $this.Tag to -Minutes, exactly one interval handler writing
         $this.Tag into antiLockIntervalSec, and no arithmetic anywhere near either. Three
         in-memory sabotages must each be named; none of them starts a process.
      4. mut-frozen  - Refresh-State resolves the new language but never relabels. The pre-fix
         tray (English items under a header that just switched), and it is caught by the per-item
         fidelity check, which is the stricter of the two guards: the stale Chinese label no
         longer equals what the now-English catalog renders for that same Tag.
      5. mut-nolang  - Refresh-State never even re-resolves the language, so the menu stays
         internally consistent in one language forever. Fidelity cannot see that (label and
         expectation drift together), and this is exactly the case the en!=zh backstop exists
         for. Measured, not assumed: this is the only injection that reaches that backstop.
      6. mut-unit    - the preset labels rebuilt off the Tag with the seconds formatter, which is
         the actual historical bug ("30 分钟" shown as "30 秒", same digits, 1/60th the time).
         Mutated in both places the label is written, or Update-TrayLabels would overwrite the
         injected construction text and the leg would escape.
      7. controls    - each mutant tree re-run in the same leg with its injection switched off
         (printed as '<name>(ctrl)'). Without this a red could have come from the copying rather
         than from the mutation.

    Legs 4 and 6 both die on the fidelity check, so the probe additionally requires their failure
    messages to differ: two mutations printing one identical message means one of them is not
    testing what it claims.

    A -DataDir is passed to every leg on purpose: the body writes config.json to switch
    languages, and a self test must never be able to edit anybody's real config. The single
    instance mutex is keyed on the data root, so a fresh directory per leg also means these runs
    cannot collide with a tray the operator is actually using.
#>
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '_tmp/tray-selftest'
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Anchors are whole-line replacements, so each must match exactly one line or the mutation is
# not testing what we think. Compared after trimming, so indentation is not part of the anchor.
$mutants = @{
    'frozen' = @(
        @{ Have = 'if ($want -ne $script:TrayLang) { $script:TrayLang = $want; Update-TrayLabels }'
           Want = '$script:TrayLang = $want  # MUT: the new language is known, the menu is not told'
           Red  = 'preset reads' }
    )
    'nolang' = @(
        @{ Have = '$want = Set-KaUiLanguage -Configured $cfg[''language'']'
           Want = '$want = Get-KaUiLanguage  # MUT: config.json is never looked at again'
           Red  = 'kept their text across a language change' }
    )
    'unit' = @(
        @{ Have = '$item = New-MenuItem (Format-DurationPreset $d.Sec)'
           Want = '$item = New-MenuItem (Format-KaSeconds ([double]$d.Min))  # MUT: label off the Tag, seconds formatter'
           Red  = 'preset reads' }
        @{ Have = '$MiDuration.DropDownItems[$n].Text = Format-DurationPreset ([double]$script:DurationPresets[$n].Sec)'
           Want = '$MiDuration.DropDownItems[$n].Text = Format-KaSeconds ([double]$script:DurationPresets[$n].Min)  # MUT'
           Red  = 'preset reads' }
    )
}

function Stage([string]$Dir, [string]$Mutant) {
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    foreach ($src in (Get-ChildItem -LiteralPath $root -Filter 'ka*.ps1' -File)) {
        $dst = Join-Path $Dir $src.Name
        if (-not $Mutant -or $src.Name -ne 'ka-tray.ps1') {
            Copy-Item -LiteralPath $src.FullName -Destination $dst   # byte for byte, BOM and all
            if ((Get-FileHash $dst -Algorithm SHA256).Hash -ne (Get-FileHash $src.FullName -Algorithm SHA256).Hash) {
                throw ($src.Name + ' is not a byte copy')
            }
            continue
        }
        # LF, always: the shipped files are BOM + LF and a rejoin on Environment.NewLine would
        # hand the child a different file than the one in the repository.
        $txt = [IO.File]::ReadAllText($src.FullName)
        $lines = @($txt -split "`n")
        $edits = 0
        foreach ($m in $mutants[$Mutant]) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq $m.Have) {
                    $lead = $lines[$i].Substring(0, $lines[$i].Length - $lines[$i].TrimStart().Length)
                    $lines[$i] = $lead + $m.Want
                    $edits++
                }
            }
        }
        if ($edits -ne $mutants[$Mutant].Count) {
            throw ($Mutant + ': replaced ' + $edits + ' line(s), expected ' + $mutants[$Mutant].Count +
                   ' - the mutation would not be testing what we think')
        }
        [IO.File]::WriteAllText($dst, ($lines -join "`n"), (New-Object Text.UTF8Encoding $true))
        $diff = 0
        $a = [IO.File]::ReadAllLines($src.FullName); $b = [IO.File]::ReadAllLines($dst)
        if ($a.Count -ne $b.Count) { throw 'the mutant changed the line count' }
        for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $b[$i]) { $diff++ } }
        if ($diff -ne $edits) { throw ('the mutant differs on ' + $diff + ' lines, expected ' + $edits) }
    }
}

function Run-Tray([string]$Dir, [string]$Name, $SetEnv) {
    $data = Join-Path $Dir ('data-' + $Name)
    $prev = @{}
    foreach ($k in @('KA_LANG', 'KA_DATA')) { $prev[$k] = (Get-Item -LiteralPath ('env:' + $k) -ErrorAction SilentlyContinue).Value }
    Remove-Item Env:KA_LANG -ErrorAction SilentlyContinue
    if ($SetEnv) { foreach ($k in $SetEnv.Keys) { Set-Item -LiteralPath ('env:' + $k) -Value $SetEnv[$k] } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'ka-tray.ps1') `
        -SelfTest -DataDir $data 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $sw.Stop()
    foreach ($k in @('KA_LANG', 'KA_DATA')) {
        if ($null -ne $prev[$k]) { Set-Item -LiteralPath ('env:' + $k) -Value $prev[$k] }
        else { Remove-Item Env:$k -ErrorAction SilentlyContinue }
    }
    return @{ code = $code; text = ($out -join "`n"); lines = $out.Count; secs = $sw.Elapsed.TotalSeconds }
}

function PresetOf([string]$Text, [string]$Lang) {
    if ($Text -match ('SELFTEST lang=' + $Lang + '.*?presetDur=(.*?) presetInt=')) { return $Matches[1] }
    return ''
}

$bad = 0
$live = Join-Path $work 'live'
Stage $live ''

# ---------------------------------------------------------------- 1. the skip shape is real
Write-Output '--- 1. KA_LANG set: the body still says OK while its language half does nothing'
$r = Run-Tray $live 'skip' @{ KA_LANG = 'zh' }
$p = @()
if ($r.code -ne 0) { $p += ('exit=' + $r.code + ' want 0') }
if ($r.text -notlike '*lang=skip*') { $p += 'no lang=skip line - the escape hatch this leg documents is gone' }
if ($r.text -like '*SELFTEST lang=en*' -or $r.text -like '*SELFTEST lang=zh*') { $p += 'the language legs ran anyway, so nothing here is skipping' }
if ($r.text -notlike '*SELFTEST OK*') { $p += 'the run did not claim OK, so exit 0 was never the decoration' }
Write-Host ('  ' + $(if ($p.Count) { 'FAIL' } else { 'ok  ' }) + ' skip-shape  exit=' + $r.code +
           ' lines=' + $r.lines + ' (' + ('{0:0.0}' -f $r.secs) + 's) ' + ($p -join '; '))
Write-Host ('       printed: ' + ((($r.text -split "`n") | Where-Object { $_ -like 'SELFTEST*' } | Select-Object -Last 2) -join ' ~ '))
if ($p.Count) { $bad++ }

# ---------------------------------------------------------------- 2. the body actually runs
Write-Output '--- 2. clean sources: both languages rendered, the menu built, OK printed'
$r = Run-Tray $live 'clean' $null
$p = @()
if ($r.code -ne 0) { $p += ('exit=' + $r.code + ' want 0') }
if ($r.text -notlike '*SELFTEST OK*') { $p += 'no SELFTEST OK' }
foreach ($need in @('SELFTEST lang=en', 'SELFTEST lang=zh', 'durations=5 intervals=4')) {
    if ($r.text -notlike ('*' + $need + '*')) { $p += ('missing "' + $need + '"') }
}
if ($r.text -like '*lang=skip*') { $p += 'the language half skipped, so legs 3 and 4 would have nothing to catch' }
$en = PresetOf $r.text 'en'; $zh = PresetOf $r.text 'zh'
if (-not $en -or -not $zh) { $p += 'could not read the 30-minute preset label back out of both language lines' }
elseif ($en -eq $zh) { $p += ('the 30-minute preset reads "' + $en + '" in both languages') }
Write-Host ('  ' + $(if ($p.Count) { 'FAIL' } else { 'ok  ' }) + ' clean        exit=' + $r.code +
           ' lines=' + $r.lines + ' (' + ('{0:0.0}' -f $r.secs) + 's) presetDur en="' + $en + '" zh="' + $zh + '" ' + ($p -join '; '))
if ($p.Count) { $bad++ }

<#
    ---------------------------------------------------------------- 3. the click handoffs, read
    off the AST. Nothing in this repository ever *performs* a tray click: the self test builds the
    menu and refreshes it, and a real click would start a worker and register a scheduled task on
    whoever's machine runs this probe. So the one place where a preset's number leaves the menu
    and enters the engine is not covered by execution - and it is precisely the unit-swap class
    this probe exists for (a Tag holding minutes, handed to something that reads seconds). What
    can be checked without starting anything is the handoff itself, and the rule is written at
    the grammar level rather than for the two numbers we happen to have: no arithmetic may appear
    anywhere between `$this.Tag` and the engine call. `* 60` and `/ 60` are the same bug wearing
    different signs. Each red case also names which handoff it died on, so a guard that fires
    cannot be riding on an unrelated one.
#>
$handoffs = @(
    @{ Name = 'duration'; Pick = { param($t) $t -match '(?<![\w-])Start-Protect(?![\w-])\s+-Minutes' }
       Must = @('-Minutes', '$this.Tag') }
    @{ Name = 'interval'; Pick = { param($t) $t -match 'antiLockIntervalSec\s*=' }
       Must = @('antiLockIntervalSec', '$this.Tag') }
)
function Get-HandoffProblem([string]$Text) {
    $errs = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { return @('ka-tray.ps1 does not parse: ' + $errs[0].Message) }
    $blocks = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true) |
                ForEach-Object { $_.Extent.Text })
    # An empty collection here would make every count assertion below true over nothing.
    if (-not $blocks.Count) { return @('ka-tray.ps1 has not one script block - this is not the tray source') }
    $problems = @()
    foreach ($h in $handoffs) {
        $mine = @($blocks | Where-Object { & $h.Pick $_ })
        if ($mine.Count -ne 1) { $problems += ($h.Name + ': ' + $mine.Count + ' click handlers, want exactly 1'); continue }
        foreach ($m in $h.Must) { if ($mine[0] -notlike ('*' + $m + '*')) { $problems += ($h.Name + ' handler no longer contains ' + $m) } }
        if ($mine[0] -match '[*/]') { $problems += ($h.Name + ' handler does arithmetic on the Tag: ' + $mine[0].Trim('{ }')) }
    }
    return $problems
}

$handoffSrc = [IO.File]::ReadAllText((Join-Path $root 'ka-tray.ps1'))
$handoffCases = @(
    @{ Tag = 'clean'; Want = 0; Expect = '' }
    @{ Tag = 'duration /60'; Want = 1; Expect = 'duration handler does arithmetic'
       Sabotage = @('Start-Protect -Minutes ([double]$this.Tag)', 'Start-Protect -Minutes ([double]$this.Tag / 60)') }
    @{ Tag = 'interval *60'; Want = 1; Expect = 'interval handler does arithmetic'
       Sabotage = @('antiLockIntervalSec = [int]$this.Tag', 'antiLockIntervalSec = [int]$this.Tag * 60') }
    @{ Tag = 'duration no-Tag'; Want = 1; Expect = 'duration handler no longer contains $this.Tag'
       Sabotage = @('Start-Protect -Minutes ([double]$this.Tag)', 'Start-Protect -Minutes 30') }
)
Write-Output '--- 3. the Tag -> engine handoff inside each click handler (AST; nothing is started)'
foreach ($c in $handoffCases) {
    $txt = $handoffSrc
    if ($c.Sabotage) {
        $n = @([regex]::Matches($txt, [regex]::Escape($c.Sabotage[0]))).Count
        if ($n -ne 1) { Write-Host ('  FAIL sabotage anchor matched ' + $n + ' times, want 1'); $bad++; continue }
        $txt = $txt.Replace($c.Sabotage[0], $c.Sabotage[1])
    }
    $probs = @(Get-HandoffProblem $txt)
    $p = @()
    if ($probs.Count -ne $c.Want) { $p += ('problems=' + $probs.Count + ' want ' + $c.Want) }
    if ($c.Expect -and (($probs -join '; ') -notlike ('*' + $c.Expect + '*'))) { $p += ('did not name "' + $c.Expect + '"') }
    if (-not $c.Expect -and $probs.Count) { $p += 'clean tree is already wrong' }
    Write-Host ('  ' + $(if ($p.Count) { 'FAIL' } else { 'ok  ' }) + ' ' + $c.Tag.PadRight(16) +
               ' problems=' + $probs.Count + ' want ' + $c.Want + '  ' + ($p -join '; ') +
               $(if ($probs.Count) { ' [' + ($probs -join '; ') + ']' } else { '' }))
    if ($p.Count) { $bad++ }
}

# ---------------------------------------------------------------- 4-7. mutants, each with its control
$n = 3
$said = @{}
foreach ($name in @('frozen', 'nolang', 'unit')) {
    $n++
    $dir = Join-Path $work ('mut-' + $name)
    $ctrl = Join-Path $work ('ctrl-' + $name)
    Write-Output ('--- ' + $n + '. mutation: ' + $name)
    Stage $dir $name
    Stage $ctrl ''
    $want = $mutants[$name][0].Red
    foreach ($run in @(@{ D = $dir; N = 'mut'; Want = 1 }, @{ D = $ctrl; N = 'ctrl'; Want = 0 })) {
        $r = Run-Tray $run.D ($name + '-' + $run.N) $null
        $p = @()
        if ($r.code -ne $run.Want) { $p += ('exit=' + $r.code + ' want ' + $run.Want) }
        if ($run.Want -eq 1) {
            if ($r.text -like '*SELFTEST OK*') { $p += 'claimed OK while wrong' }
            if ($r.text -notlike ('*' + $want + '*')) { $p += ('died somewhere else, not on "' + $want + '"') }
            $said[$name] = ((($r.text -split "`n") | Where-Object { $_ -like 'SELFTEST FAILED*' } | Select-Object -First 1))
            Write-Host ('       mutant said: ' + $said[$name])
        }
        elseif ($r.text -notlike '*SELFTEST OK*' -or $r.text -like '*lang=skip*') {
            $p += 'the control tree is not the same green run as leg 2' }
        $tag = $name + '(' + $run.N + ')'
        Write-Host ('  ' + $(if ($p.Count) { 'FAIL' } else { 'ok  ' }) + ' ' + $tag.PadRight(12) +
                   ' exit=' + $r.code + ' (' + ('{0:0.0}' -f $r.secs) + 's) ' + ($p -join '; '))
        if ($p.Count) { $bad++ }
    }
}

# frozen and unit both die on the fidelity check, so a shared message would mean one of the two
# injections is riding on the other one.
if ($said.ContainsKey('frozen') -and $said.ContainsKey('unit') -and $said['frozen'] -and ($said['frozen'] -eq $said['unit'])) {
    Write-Host '  FAIL frozen and unit printed one identical message'
    $bad++
}
if ($said.Count -ne 3) { Write-Host ('FAIL only ' + $said.Count + ' mutants reported a failure line'); $bad++ }

Write-Output ('evidence kept in ' + $work)
if ($bad) { Write-Output ('PROBE FAILED: ' + $bad + ' leg(s) wrong'); exit 1 }
Write-Output ('PROBE OK: the tray self test body runs here for real - 1 skip shape pinned, ' +
              $said.Count + ' mutations each red on their own guard and green with the injection switched off')
exit 0
