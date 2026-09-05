param([switch]$Show)
$ErrorActionPreference = 'Stop'
<#
    The Inno script is the one part of the release that no other check in this repository can
    see: ka-syntax parses .ps1, ka-workflow parses the .yml run blocks, and the portable zip
    never contains KeepAwake.iss. Until this probe existed, the strongest true statement about
    the installer was "a person read it".

    So compile it. Five assertions, each measured against ISCC on this machine:

      control     the shipped bytes compile, and what comes out is named exactly the way
                  release.yml's three-file check looks for. OutputBaseFilename is the only place
                  that name is written, and nothing else reads it back.
      crlf        the same bytes with CRLF endings compile too. .gitattributes pins *.iss to
                  eol=crlf, so CRLF is the shape a fresh clone hands to CI, and the rule on this
                  repo is that the bytes tested have to be the bytes shipped.
      no-version  without /DMyAppVersion the #error fires and the build aborts. The version has
                  one home (ka-core.ps1); an installer that could be built with a hand-typed
                  version would be a second home.
      bad-proto   InitializeUninstall written as a procedure instead of a function returning
                  Boolean is rejected: "Invalid prototype for 'InitializeUninstall'". That form
                  was the shipped one until it was fixed - this mutant is the regression test
                  for a mistake that was actually made here.
      no-result   deleting "Result := True" still compiles. The compiler is blind to that one,
                  and an uninitialized Boolean handed back to the uninstaller is the difference
                  between an uninstall that proceeds and one that aborts for no stated reason.
                  Asserting the blind spot on purpose: if a future Inno starts catching it, this
                  probe goes red and we find out here rather than on a user's machine.

    A red mutant only counts when the compiler's own words name the injected defect - otherwise a
    typo elsewhere would be read as the assertion passing. That is what Require-Compile checks.

    When Inno Setup is not installed the probe says "SKIPPED" and exits 0: the honest state of a
    compile check with no compiler is "not run", never "passed". build-test.yml installs Inno
    before running it, so in CI it is always run.
#>
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'packaging/ka-iscc.ps1')

$iscc = Get-KaIscc
if (-not $iscc) {
    Write-Host 'PROBE SKIPPED: Inno Setup is not installed here, so the installer script was not compiled.'
    Write-Host '               install it ("winget install JRSoftware.InnoSetup") and run this again.'
    exit 0
}
Write-Host "  compiler: $iscc"

$issPath = Join-Path $root 'packaging/KeepAwake.iss'
if (-not (Test-Path -LiteralPath $issPath)) { throw "no $issPath - there is no installer script to compile" }
$lf = ([IO.File]::ReadAllText($issPath)) -replace "`r`n", "`n"

$work = Join-Path $root '_tmp/iss-probe'
$fail = 0
$ran = 0

function Invoke-Issc([string]$Text, [string]$Label, [bool]$WithVersion) {
    <#
        Returns the exit code plus the compiler's own words, both streams: the build report goes
        to stdout but a script error - including our own #error - goes to stderr, and an assertion
        that only reads stdout cannot tell "this went red for the reason we injected" from "this
        went red because of an unrelated typo".
    #>
    $dir = Join-Path $work $Label
    $null = New-Item -ItemType Directory -Force -Path $dir
    $f = Join-Path $dir ($Label + '.iss')
    [IO.File]::WriteAllText($f, $Text, (New-Object Text.UTF8Encoding($false)))
    $out = Join-Path $dir ($Label + '.out')
    $err = Join-Path $dir ($Label + '.err')
    $pre = ''
    if ($WithVersion) { $pre = '/DMyAppVersion=1.0.0 ' }
    $cmd = ('{0}/DSourceDir="{1}" /DOutDir="{2}" "{3}"' -f $pre, (Join-Path $work 'staging'), $dir, $f)
    $p = Start-Process -FilePath $iscc -ArgumentList $cmd -Wait -PassThru -NoNewWindow `
                       -RedirectStandardOutput $out -RedirectStandardError $err `
                       -WorkingDirectory (Join-Path $root 'packaging')
    return @{ code = [int]$p.ExitCode
               text = (([IO.File]::ReadAllText($out)) + "`n" + ([IO.File]::ReadAllText($err)))
               dir = $dir }
}

function Require-Compile([hashtable]$r, [string]$Name, [string]$Expect) {
    $script:ran++
    if ($Expect -eq 'green') {
        if ($r.code -ne 0) {
            $script:fail++
            Write-Host "  FAIL $Name : the compiler refused it (exit $($r.code))"
            foreach ($l in @($r.text -split "`n") | Where-Object { $_ -match 'Error|aborted' } | Select-Object -First 4) { Write-Host ('       ' + $l.Trim()) }
            return
        }
        if ($r.text -notlike '*Successful compile*') { $script:fail++; Write-Host "  FAIL $Name : exit 0 but the compiler never said Successful compile"; return }
        Write-Host "  ok   $Name"
        return
    }
    if ($r.code -eq 0) { $script:fail++; Write-Host "  FAIL $Name : the compiler accepted it - this mutant was supposed to be rejected"; return }
    if ($r.text -notlike ('*' + $Expect + '*')) {
        $script:fail++
        Write-Host "  FAIL $Name : red, but not the red that was injected. Waiting for '$Expect':"
        foreach ($l in @($r.text -split "`n") | Where-Object { $_ -match 'Error|aborted' } | Select-Object -First 4) { Write-Host ('       ' + $l.Trim()) }
        return
    }
    Write-Host "  ok   $Name"
}

try {
    # A staging tree of two stub files. [Files] only needs something to recurse over, and this
    # probe is about the script, not about the product bytes - build.ps1 plus probe-build-selftest
    # already cover what a real staging tree has to hold.
    $stg = Join-Path $work 'staging'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $stg 'dashboard')
    [IO.File]::WriteAllText((Join-Path $stg 'ka.ps1'), '# stub', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $stg 'dashboard\index.html'), '<html></html>', (New-Object Text.UTF8Encoding($false)))

    $control = Invoke-Issc $lf 'control' $true
    Require-Compile $control 'control: the shipped installer script compiles' 'green'

    $script:ran++
    $setup = Join-Path $control.dir 'KeepAwake-1.0.0-setup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        $fail++
        Write-Host ('  FAIL naming: no {0} where the compiler was told to put it - release.yml looks for exactly that name' -f (Split-Path -Leaf $setup))
    } else {
        Write-Host ('  ok   naming: {0} ({1:N0} bytes)' -f (Split-Path -Leaf $setup), (Get-Item -LiteralPath $setup).Length)
    }

    Require-Compile (Invoke-Issc ($lf -replace "`n", "`r`n") 'crlf' $true) 'crlf: the CRLF shape a fresh clone gets compiles too' 'green'
    Require-Compile (Invoke-Issc $lf 'no-version' $false) 'no-version: the #error fires without /DMyAppVersion' 'MyAppVersion is not set'

    $protoLine = 'function InitializeUninstall(): Boolean;'
    $resultLine = '  Result := True;'
    foreach ($a in @($protoLine, $resultLine)) {
        $n = @(($lf -split "`n") | Where-Object { $_ -eq $a }).Count
        if ($n -ne 1) { throw ("anchor {0} matches {1} lines - the mutant would not be testing what we think" -f $a, $n) }
    }
    # The pre-fix shape exactly: the callback as a procedure, which is how it stood before anyone
    # compiled it. Leaving "Result := True" inside a procedure body makes ISCC stop on
    # "Unknown identifier 'Result'" first and never reach the prototype check, so a mutant that
    # changes only the declaration goes red for a different reason than the one being tested.
    $badProto = $lf.Replace($protoLine, 'procedure InitializeUninstall();').Replace($resultLine + "`n", '')
    Require-Compile (Invoke-Issc $badProto 'bad-proto' $true) 'bad-proto: a procedure-shaped callback is rejected' "Invalid prototype for 'InitializeUninstall'"
    Require-Compile (Invoke-Issc $lf.Replace($resultLine + "`n", '') 'no-result' $true) 'no-result: dropping Result := True still compiles, so the line is load-bearing' 'green'

    if ($Show) {
        Write-Host ''
        foreach ($l in @($control.text -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 5) { Write-Host ('     | ' + $l.Trim()) }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host ("PROBE FAILED: {0} of {1} assertions" -f $fail, $ran); exit 1 }
Write-Host ("PROBE OK: {0} assertions - KeepAwake.iss compiles as shipped and as a clone receives it, names the setup.exe the release check looks for, refuses a build with no version and a callback with the wrong prototype, and records the one mistake the compiler will not catch for us" -f $ran)
exit 0
