; dsh-chat 的 Windows 安装包（Inno Setup）。
; 在 CI 里由 build-windows.yml 调用：
;   ISCC.exe /DAppVersion=<build number> installer\windows.iss
; 支持：自定义安装目录、桌面快捷方式、开始菜单、卸载。

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#define AppName "dsh-chat"
#define AppExe "dsh_chat.exe"

[Setup]
AppId={{6C1F0E2A-9B4D-4E5A-8C7B-2F1A3D5E7C90}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=dsh
AppPublisherURL=https://github.com/J1nxi-youmi/dsh-chat
DefaultDirName={autopf}\dsh-chat
DefaultGroupName=dsh-chat
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=dsh-chat-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
ShowLanguageDialog=no

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："
Name: "quicklaunchicon"; Description: "创建快速启动栏图标"; GroupDescription: "附加任务："; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\dsh-chat"; Filename: "{app}\{#AppExe}"
Name: "{group}\卸载 dsh-chat"; Filename: "{uninstallexe}"
Name: "{autodesktop}\dsh-chat"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\dsh-chat"; Filename: "{app}\{#AppExe}"; Tasks: quicklaunchicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "启动 dsh-chat"; Flags: nowait postinstall skipifsilent
