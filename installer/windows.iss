; dsh-chat 的 Windows 安装包（Inno Setup）。
; 在 CI 里由 build.yml 调用：
;   ISCC.exe /DAppVersion=<version> installer\windows.iss
; 支持：自定义安装目录、桌面快捷方式、开始菜单、卸载。

#ifndef AppVersion
  #define AppVersion "1.2.2"
#endif

#define AppName "青屿"
#define AppExe "dsh_chat.exe"

[Setup]
AppId={{6C1F0E2A-9B4D-4E5A-8C7B-2F1A3D5E7C90}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=dsh
AppPublisherURL=https://github.com/J1nxi-youmi/dsh-chat
DefaultDirName={autopf}\dsh-chat
DefaultGroupName={#AppName}
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
; 版本化文件名，避免 Windows 图标缓存继续显示旧方角图标。
Source: "..\tool\app_icon.ico"; DestDir: "{app}"; DestName: "app_icon-{#AppVersion}.ico"; Flags: ignoreversion

[InstallDelete]
; 升级安装时清掉旧版本留下的 dsh-chat / Dshchat 快捷方式，避免和青屿并存。
Type: files; Name: "{autodesktop}\dsh-chat.lnk"
Type: files; Name: "{autodesktop}\Dshchat.lnk"
Type: files; Name: "{commonprograms}\Dshchat\dsh-chat.lnk"
Type: files; Name: "{commonprograms}\Dshchat\卸载 dsh-chat.lnk"
Type: files; Name: "{commonprograms}\Dshchat\Dshchat.lnk"
Type: files; Name: "{commonprograms}\Dshchat\卸载 Dshchat.lnk"
Type: files; Name: "{app}\app_icon-*.ico"

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\app_icon-{#AppVersion}.ico"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\app_icon-{#AppVersion}.ico"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\{#AppName}"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\app_icon-{#AppVersion}.ico"; Tasks: quicklaunchicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "启动 {#AppName}"; Flags: nowait postinstall skipifsilent
