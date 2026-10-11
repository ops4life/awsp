; Inno Setup script for the winget package. Build: ISCC /DAppVersion=1.9.0 packaging\windows\awsp.iss
#ifndef AppVersion
  #error AppVersion is not defined (pass /DAppVersion=x.y.z)
#endif

[Setup]
; AppId identifies the app for upgrades/uninstall. Never change it.
AppId={{D84FA4B4-940F-4C32-91AD-3E0E0988BF79}
AppName=awsp
AppVersion={#AppVersion}
AppPublisher=ops4life
AppPublisherURL=https://github.com/ops4life/awsp
AppSupportURL=https://github.com/ops4life/awsp/issues
DefaultDirName={localappdata}\Programs\awsp
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
Compression=lzma2
SolidCompression=yes
OutputDir=..\..\dist
OutputBaseFilename=awsp-{#AppVersion}-setup
UninstallDisplayName=awsp

[Files]
Source: "..\..\bin\awsp.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\awsp-profile.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\completions\awsp.completion.ps1"; DestDir: "{app}\completions"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\awsp-profile.ps1"" -Action Add -ScriptPath ""{app}\awsp.ps1"""; Flags: runhidden

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\awsp-profile.ps1"" -Action Remove -ScriptPath ""{app}\awsp.ps1"""; Flags: runhidden; RunOnceId: "RemoveAwspProfileLine"
