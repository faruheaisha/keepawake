; -----------------------------------------------------------------------------
;  KeepAwake - per-user installer
;
;  Compiled by "packaging/build.ps1 -Installer" (which passes the version and the paths
;  in), or by hand from this folder after a build with -Stage:
;
;      iscc KeepAwake.iss
;      iscc /DMyAppVersion=1.0.0 /DSourceDir=..\dist\staging /DOutDir=..\dist KeepAwake.iss
;
;  Deliberately absent, and why:
;
;   * No file list. [Files] installs whatever build.ps1 staged from
;     tests/ka-release-files.ps1, so the installer cannot disagree with the portable zip
;     about what the product is. Two lists describing one thing is how the probes drifted.
;   * No CJK, not even in a shortcut name. Inno reads a BOM-less .iss using the system
;     ANSI codepage, so a Chinese label typed on a UTF-8 machine arrives as mojibake on a
;     zh-CN one - and there is no compiler here to catch it. Inno's own language files
;     localise the wizard; the product's strings are localised at run time.
;   * No architecture restriction. This is PowerShell: it runs on x86, x64 and ARM64
;     wherever in-box PowerShell 5.1 runs. The WOW64 question the engine cares about is
;     which powershell.exe executes the scripts, and ka-gate.ps1 answers that at run time.
;   * No uninstall of the data directory. %LOCALAPPDATA%\KeepAwake keeps the config, the
;     log and the history; deleting them unasked would destroy the only record of what the
;     protection did. PRIVACY.md names every file there and says removal is manual.
;   * No code signing. SECURITY.md explains SmartScreen instead of hiding it behind a
;     certificate this project does not have.
; -----------------------------------------------------------------------------

#ifndef MyAppVersion
  #error MyAppVersion is not set. The version lives in ka-core.ps1: build with "packaging\build.ps1 -Installer", or pass /DMyAppVersion=x.y.z
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\staging"
#endif
#ifndef OutDir
  #define OutDir "..\dist"
#endif

#define MyAppName "KeepAwake"
; The same wording NOTICE uses. No individual name and no repository URL until the repo
; actually exists - Add/Remove Programs would otherwise show a link that goes nowhere, and a
; URL invented here cannot be checked by any test on this machine.
#define MyAppPublisher "The KeepAwake Authors"
#define PSExe "{sys}\WindowsPowerShell\v1.0\powershell.exe"

[Setup]
; A literal AppId. Without it Inno derives one from AppName, and renaming the product
; would leave an orphan behind in "Add or remove programs" forever.
AppId={{8B7C1F4E-2D9A-4C3B-9E57-6A18D3F0C4B2}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultGroupName={#MyAppName}
; Per-user, into the user's own profile: no UAC prompt, nothing in Program Files - and the
; logon task the guard registers then runs in the same context that wrote the data.
DefaultDirName={localappdata}\Programs\{#MyAppName}
PrivilegesRequired=lowest
; No PrivilegesRequiredOverridesAllowed. Not because the folder could not move - it can, and the
; measured install of 2026-09-05 put DefaultDirName aside with /DIR and ran from %TEMP% - but because
; an offered "elevate and install for all users" would leave the guard's logon task registered in
; whichever profile happened to be elevated, running in a different context than the data it writes.
; This installer is per-user or it is wrong.
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir={#OutDir}
OutputBaseFilename=KeepAwake-{#MyAppVersion}-setup
UninstallDisplayName={#MyAppName}
MinVersion=0,6.1sp1
; The Restart Manager would offer to close "powershell.exe" to unlock the files - and that
; is the image of every PowerShell window the user owns. InitializeUninstall stops our own
; worker and panel by name instead, so nothing unrelated is ever asked to leave.
CloseApplications=no
RestartApplications=no
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Simplified Chinese is an unofficial translation and does not ship with Inno Setup. If it
; happens to be installed the wizard gains a Chinese option; if not, the build must not die.
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; One line on purpose - the manifest is the only source of truth about what ships.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Parameters is quoted as one value with doubled inner quotes - the documented spelling. An
; unquoted value holding bare " characters is at the mercy of the section-line parser, and
; the semicolon is that parser's field separator.
Name: "{group}\{#MyAppName} - Dashboard"; Filename: "{#PSExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\ka.ps1"" serve"; WorkingDir: "{app}"; Comment: "Open the dashboard on 127.0.0.1"
Name: "{group}\{#MyAppName} - Tray"; Filename: "{#PSExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\ka.ps1"" tray"; WorkingDir: "{app}"; Comment: "Status, start and stop from the notification area"
Name: "{group}\{#MyAppName} - Protect"; Filename: "{#PSExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\ka.ps1"" start"; WorkingDir: "{app}"; Comment: "Keep this machine awake until you release it"
Name: "{group}\{#MyAppName} - Release"; Filename: "{#PSExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\ka.ps1"" stop"; WorkingDir: "{app}"; Comment: "Drop the power request and let the machine sleep"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{#PSExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\ka.ps1"" serve"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; postinstall only, and never in a silent run: an unattended CI install must not park a
; console window nobody is watching. A portable user gets the same window from panel.bat.
Filename: "{#PSExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\ka.ps1"" serve"; WorkingDir: "{app}"; Description: "{#MyAppName} dashboard"; Flags: postinstall skipifsilent nowait

[Code]
function KaArgs(const AArgs: String): String;
begin
  Result := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\ka.ps1') + '" ' + AArgs;
end;

procedure RunKa(const AArgs: String);
var
  Code: Integer;
begin
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), KaArgs(AArgs),
              ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code) then
    Log('KeepAwake: could not run "ka.ps1 ' + AArgs + '" from the installed copy')
  else
    Log('KeepAwake: ran "ka.ps1 ' + AArgs + '" from the installed copy, exit ' + IntToStr(Code));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    // Scripts copied by an installer carry no Mark-of-the-Web, unlike every file inside a
    // downloaded zip - which is why the portable package needs the unblock step and this
    // one does not (probe-motw.ps1 measures the difference).
    Log('KeepAwake: install finished; installer-copied scripts carry no MOTW.');
end;

function InitializeUninstall(): Boolean;
begin
  // Runs while {app}\ka.ps1 still exists. After the files are gone nothing can ask the
  // worker to release its power request, and a panel would keep holding its port with no
  // script behind it. unguard last: the logon task is the one artefact that outlives the
  // program files, and pointed at a deleted script it would fail at every logon.
  //
  // Result is True no matter what those runs did, on purpose - an uninstall that refused to
  // finish because a process was already gone would trap the user with a half-deleted product.
  // ka.ps1 reports honestly when it finds nothing, and the Setup Log keeps that line.
  if FileExists(ExpandConstant('{app}\ka.ps1')) then
  begin
    RunKa('stop-server');
    RunKa('stop');
    RunKa('unguard');
  end;
  Result := True;
end;
