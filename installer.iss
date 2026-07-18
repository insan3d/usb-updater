; USB Updater installer. Build with Inno Setup 6 (ISCC.exe installer.iss).

#define AppName "USB Updater"
#define AppVersion "1.1.0"
#define AppPublisher "insan3d"
#define AppExeName "usb-updater.exe"

[Setup]
AppId={{1EA00465-94F2-4F6A-B20A-95DDBCB73087}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={userappdata}\insan3d\USB Updater
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=USB-Updater-Setup-{#AppVersion}
SetupIconFile=icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Files]
Source: "usb-updater.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "updater_worker.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительные значки:"; Flags: unchecked

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent

[Registry]
; The application stores its per-user settings here. Remove all of them on uninstall.
Root: HKCU; Subkey: "Software\insan3d\usb-updater"; Flags: uninsdeletekey

[UninstallDelete]
; The application has no user documents in its installation folder, so remove it entirely.
Type: filesandordirs; Name: "{app}"
