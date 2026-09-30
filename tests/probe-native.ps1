param(
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
<#
    The shipped tool compiles its Win32 layer at start with Add-Type -TypeDefinition, so the only
    copy of that C# that matters is the string literal inside ka-core.ps1. src\native\KaNative.cs
    used to sit next to it as a hand-copied twin; two copies of a source file drift, and the drift
    is invisible because the product never reads the .cs. It is gone, and this probe is what
    replaces the assurance it was supposed to give:

      1. extract the embedded C# from ka-core.ps1 by AST (not by regex on lines that could be a
         comment) and compile it with the same csc the Add-Type path uses;
      2. reflect over the compiled Ka.Native type and require that every [Ka.Native]::Member the
         product actually calls exists on it. This is the failure mode the runtime cannot catch:
         every native call site sits in a try/catch that quietly degrades to "unknown", so a
         renamed or typo'd method never surfaces as an error - it just makes the tool stupider;
      3. run a few of those members for real and require answers, in a separate process.

    -SelfTest recompiles a sabotaged copy of the extracted source in memory only (the product
    files are never touched) and requires the coverage check to name the member it lost. Without
    that, a green here is worthless: an empty allowlist or a reflection call that silently
    returned nothing would look identical.

    As of 2026-09-28 a plain run does both: after the green checks above, it spawns itself with
    -SelfTest and requires that child to end in `PROBE OK (self-test):`. The switch stayed (that
    child is how the leg is reached) but it is no longer the only way in - ka-ci runs every
    globbed probe without arguments, so before this the sabotage had never run anywhere automated.
#>
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'ka-core.ps1'

# ---------------------------------------------------------------- 1. extract
$errs = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count) { throw "ka-core.ps1 does not parse: $($errs[0].Message)" }
$addTypes = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                                        $n.GetCommandName() -eq 'Add-Type' }, $true))
if ($addTypes.Count -ne 1) { throw "expected exactly 1 Add-Type in ka-core.ps1, found $($addTypes.Count)" }
$strings = @($addTypes[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
$csSrc = $null
foreach ($s in $strings) { if ($s.Value -match 'namespace\s+Ka' -and $s.Value -match 'class\s+Native') { $csSrc = $s.Value } }
if (-not $csSrc) { throw 'no C# source literal found in the Add-Type call - the extraction premise broke' }
Write-Output ('extracted embedded C#: ' + ($csSrc -split "`r?`n").Count + ' lines, ' + $csSrc.Length + ' chars')

# ---------------------------------------------------------------- 2. what the product calls
$need = New-Object System.Collections.Generic.HashSet[string]
$scan = Get-ChildItem -File -Path $root -Filter 'ka*.ps1' | Where-Object { $_.Name -ne 'probe-native.ps1' }
foreach ($f in $scan) {
    $t = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$t)
    if ($t -and $t.Count) { throw "$($f.Name) does not parse: $($t[0].Message)" }
    $calls = @($ast.FindAll({ param($n)
        (($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -or
         ($n -is [System.Management.Automation.Language.MemberExpressionAst])) -and
        $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $n.Expression.TypeName.Name -eq 'Ka.Native' }, $true))
    foreach ($c in $calls) { [void]$need.Add($c.Member.Extent.Text) }
    # Cross-check the AST walk against a plain scan, so a parser surprise cannot hide a call site.
    $raw = @(([regex]::Matches([IO.File]::ReadAllText($f.FullName), '\[Ka\.Native\]::([A-Za-z0-9_]+)') |
              ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique)
    foreach ($r in $raw) { if (-not $need.Contains($r)) { throw "$($f.Name) references [Ka.Native]::$r via text but the AST walk missed it" } }
}
if ($need.Count -lt 10) { throw "only $($need.Count) Ka.Native members found - the scan is not seeing the call sites" }
Write-Output ('members the product calls: ' + $need.Count)

# ---------------------------------------------------------------- 3. compile and reflect
$csc = @(
    (Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ }
if (-not $csc) { throw 'no csc.exe - the compile check cannot run' }

$sandbox = Join-Path $env:TEMP ('ka-native-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox -Force
try {
    $srcName = if ($SelfTest) { 'KaNative.sabotaged.cs' } else { 'KaNative.extracted.cs' }
    $body = $csSrc
    if ($SelfTest) {
        # Break exactly one public member the product calls, and one that nothing inside the
        # class itself calls - otherwise the sabotaged copy fails to compile and reports a build
        # error instead of the coverage miss this self-test exists to prove is detectable.
        $victim = @($need | Where-Object {
                        $csSrc -match ('public\s+static\s+[\w\[\]<>,\s]+\s+' + [regex]::Escape($_) + '\s*\(') -and
                        ([regex]::Matches($csSrc, [regex]::Escape($_))).Count -eq 1 }
                   ) | Select-Object -First 1
        if (-not $victim) { throw 'SelfTest found no callable public member to rename - nothing would be tested' }
        $body = $csSrc -replace ('public static ([\w\[\]<>,\s]+?) ' + [regex]::Escape($victim) + '\('), "public static `$1 ${victim}Gone("
        if ($body -eq $csSrc) { throw "SelfTest could not rewrite $victim - the mutation is not happening" }
        Set-Variable -Scope Script -Name Victim -Value $victim
        Write-Output ("SelfTest: renamed public member '$victim' out of the compiled copy only")
    }
    $cs = Join-Path $sandbox $srcName
    $dll = Join-Path $sandbox ('Ka.Native.' + $srcName + '.dll')
    [IO.File]::WriteAllText($cs, $body, (New-Object Text.UTF8Encoding($true)))
    $cscLog = & $csc[0] /nologo /target:library /out:$dll $cs 2>&1 | ForEach-Object { "$_" }
    if (-not (Test-Path -LiteralPath $dll)) {
        $cscLog | ForEach-Object { Write-Output ('  csc: ' + $_) }
        throw 'the embedded C# does not compile with csc - so Add-Type cannot compile it either'
    }
    Write-Output ('compiled: ' + (Get-Item -LiteralPath $dll).Length + ' bytes, csc said: ' + (($cscLog | Where-Object { $_.Trim() }) -join ' / '))

    # A fresh process, because a type already registered in this AppDomain would make a second
    # load look like success no matter what it was compiled from.
    $child = Join-Path $sandbox 'child.ps1'
    @'
$ErrorActionPreference = 'Continue'
Add-Type -Path '%DLL%'
$t = [Ka.Native] -as [type]
if (-not $t) { Write-Output 'TYPE=missing'; exit 1 }
$members = @($t.GetMembers([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static) |
             ForEach-Object { $_.Name } | Sort-Object -Unique)
Write-Output ('MEMBERS=' + ($members -join ','))
$s = $t.GetMethod('PowerStatus').Invoke($null, $null)
Write-Output ('POWERSTATUS_KNOWN=' + $s.known + ' AC=' + $s.acOnline + ' PCT=' + $s.percent)
Write-Output ('IDLE=' + [math]::Round($t.GetMethod('SecondsSinceInput').Invoke($null, $null), 1))
Write-Output ('IL=' + $t.GetMethod('SelfIntegrityRid').Invoke($null, $null))
$fg = $t.GetMethod('ForegroundPid').Invoke($null, $null)
Write-Output ('FOREGROUND_PID=' + [long]$fg)
'@ -replace '%DLL%', $dll | Set-Content -LiteralPath $child -Encoding UTF8

    $outFile = Join-Path $sandbox 'child.out'
    $p = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outFile `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $child + '"')
    $lines = @([IO.File]::ReadAllText($outFile) -split "`r?`n" | Where-Object { $_ -match '=' })
    $map = @{}
    foreach ($l in $lines) { $map[$l.Split('=')[0]] = ($l -split '=', 2)[1] }

    $bad = @()
    if ($null -eq $map['MEMBERS']) { $bad += 'the reflection child printed nothing (exit=' + $p.ExitCode + ') - no members were checked' }
    $have = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in ($map['MEMBERS'] -split ',')) { if ($m) { [void]$have.Add($m.Trim()) } }
    foreach ($n in $need) { if (-not $have.Contains($n)) { $bad += "[Ka.Native]::$n is called by the product but does not exist on the compiled type" } }
    foreach ($k in 'POWERSTATUS_KNOWN', 'IDLE', 'IL', 'FOREGROUND_PID') {
        if (-not $map[$k]) { $bad += "$k produced no answer" }
    }
    if ($map['FOREGROUND_PID'] -and $map['FOREGROUND_PID'] -notmatch '^-?\d+$') {
        $bad += "ForegroundPid did not return a number (got '$($map['FOREGROUND_PID'])')"
    }
    if ($SelfTest) {
        if ($bad.Count -eq 0) { Write-Output 'PROBE FAILED: the sabotaged build still passed coverage - the check is vacuous'; exit 1 }
        $named = ($bad | Where-Object { $_ -like ('*' + (Get-Variable -Scope Script -Name Victim -ValueOnly) + '*') }).Count -gt 0
        if (-not $named) { Write-Output ('PROBE FAILED: coverage went red but not on ' + (Get-Variable -Scope Script -Name Victim -ValueOnly)); exit 1 }
        Write-Output ('PROBE OK (self-test): renaming ' + (Get-Variable -Scope Script -Name Victim -ValueOnly) + ' is caught: ' + ($bad -join ' | '))
        exit 0
    }
    if ($bad) { foreach ($m in $bad) { Write-Output ('  FAIL ' + $m) }; Write-Output ('PROBE FAILED: ' + $bad.Count + ' problem(s)'); exit 1 }
    Write-Output ('  live: ' + (($lines | Where-Object { $_ -notmatch '^MEMBERS=' }) -join '  '))
    Write-Output ('PROBE OK: the C# inside ka-core.ps1 compiles, exposes all ' + $need.Count + ' members the product calls, and answers when run')

    # Then prove that check has teeth, in the same CI run. Until 2026-09-28 this leg only existed
    # behind -SelfTest, and ka-ci runs every globbed probe WITHOUT arguments, so the sabotage below
    # had never executed anywhere automated: a green coverage check above told you nothing about
    # whether it could go red. The leg costs one extra compile-plus-child (5 s here), which is why
    # it can simply always run instead of being an opt-in.
    $self = Join-Path $env:TEMP ('ka-native-selftest-' + [guid]::NewGuid().ToString('N') + '.out')
    try {
        $me = $MyInvocation.MyCommand.Path
        $c = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -NoNewWindow -PassThru -RedirectStandardOutput $self `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $me + '" -SelfTest')
        # HasExited polling, not -Wait: see the note in probe-server-hint.ps1 - a redirected stdout
        # pipe is only a deadline-free wait once a grandchild can inherit the write end, and this
        # file should not have to be re-audited for that every time it grows a child.
        $deadline = (Get-Date).AddSeconds(180)
        while (-not $c.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $c.Refresh() }
        $timedOut = -not $c.HasExited
        # Get-Content, not [IO.File]::ReadAllText: the parent's own redirection handle stays open
        # (measured here - ReadAllText threw "being used by another process" while the child was
        # already gone), and Get-Content opens shared.
        $text = (@(Get-Content -LiteralPath $self -Raw -ErrorAction SilentlyContinue) -join "`n")
        if ($timedOut) {
            try { Stop-Process -Id $c.Id -Force -ErrorAction Stop } catch { }
            Write-Output '  FAIL the sabotaged re-run did not finish in 180s'
            Write-Output 'PROBE FAILED: 1 problem(s)'
            exit 1
        }
        # Verdict by the child's own marker, not by its exit code. This launch carries -NoNewWindow
        # and a redirect, and an object from that shape answers a silent $null even after the exit
        # - HasExited is True here and .ExitCode would still be $null (measured 2026-09-30,
        # _tmp/exitcode-switch-matrix-20260930.txt T2/T4, rerun in -switch-verify-/-switch-pin-;
        # while the child still runs it is $null in every shape). So there is no code to read from
        # here, and the failure below names the only readable thing: the missing verdict line.
        if ($text -notlike '*PROBE OK (self-test):*') {
            Write-Output '  FAIL the sabotaged copy did not print its own verdict'
            foreach ($l in ($text -split "`r?`n") | Where-Object { $_.Trim() }) { Write-Output ('        ' + $l.Trim()) }
            Write-Output 'PROBE FAILED: 1 problem(s)'
            exit 1
        }
        $line = @(($text -split "`r?`n") | Where-Object { $_ -like '*PROBE OK (self-test)*' })[0]
        Write-Output ('  self-test: ' + $line.Trim())
        Write-Output 'PROBE OK: the embedded C# compiles and covers every member the product calls, and renaming one of them in a compiled copy is caught by name'
    } finally {
        Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
