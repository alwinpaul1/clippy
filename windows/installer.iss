; Inno Setup script for the Clippy Windows installer.
; Built in CI (ISCC is preinstalled on GitHub windows runners):
;   ISCC.exe windows\installer.iss
; Produces Clippy-Setup.exe — a per-user install (no admin prompt) with
; Start Menu + Desktop shortcuts, launching Clippy when it finishes.

[Setup]
AppName=Clippy
AppVersion=1.0.0
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
OutputBaseFilename=Clippy-Setup
OutputDir=..

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Clippy"; Filename: "{app}\clippy.exe"
Name: "{autodesktop}\Clippy"; Filename: "{app}\clippy.exe"

[Run]
Filename: "{app}\clippy.exe"; Description: "Launch Clippy"; Flags: nowait postinstall skipifsilent
