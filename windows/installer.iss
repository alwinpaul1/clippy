; Inno Setup script for the Clippy Windows installer.
; Built in CI (ISCC is preinstalled on GitHub windows runners):
;   ISCC.exe /DMyAppVersion=1.0.34 windows\installer.iss
; Produces Clippy-Setup.exe — a per-user install (no admin prompt) with
; Start Menu + Desktop shortcuts, launching Clippy when it finishes.
;
; AppId is permanent — never regenerate. Inno uses it as the upgrade identity.
; MyAppVersion is injected at build time from pubspec.yaml (see ci.yml).

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif

[Setup]
; Stable product GUID — changing this creates a SECOND install entry.
AppId={{CA0B975A-A652-43AE-9166-5C82644A2B74}
AppName=Clippy
AppVersion={#MyAppVersion}
AppVerName=Clippy {#MyAppVersion}
AppPublisher=Clippy
WizardStyle=modern
; Per-user install: {autopf} resolves to the user's Programs dir with
; PrivilegesRequired=lowest, so no UAC prompt.
PrivilegesRequired=lowest
DefaultDirName={autopf}\Clippy
DefaultGroupName=Clippy
UninstallDisplayIcon={app}\clippy.exe
Compression=lzma2
SolidCompression=yes
; CLI /CLOSEAPPLICATIONS (from the in-app updater) needs this allowed.
CloseApplications=yes
OutputBaseFilename=Clippy-Setup
OutputDir=..
; Same AppId + higher AppVersion = Inno treats this as an upgrade of the
; existing install (not a side-by-side copy).
DisableProgramGroupPage=yes

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Clippy"; Filename: "{app}\clippy.exe"
Name: "{autodesktop}\Clippy"; Filename: "{app}\clippy.exe"

[Run]
; No `skipifsilent`: the in-app updater runs this installer with /SILENT, and we
; WANT it to relaunch Clippy afterwards (matching the macOS self-update). In an
; interactive install this is the "Launch Clippy" checkbox on the Finished page.
Filename: "{app}\clippy.exe"; Description: "Launch Clippy"; Flags: nowait postinstall
