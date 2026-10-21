; LlamaServer Manager + Tray — Inno Setup 6+
#define MyAppName "LlamaServer Manager"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Kortex / LlamaServer"
#define MyAppExeName "LlamaServer.Manager.exe"
#define MyTrayExeName "LlamaServer.Tray.exe"
#define PublishDir "..\publish\win-x64"

[Setup]
AppId={{A7C3E9F1-2B4D-4E8A-9C1F-6D5E8A0B3C2D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\LlamaServer Manager
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=LlamaServerManager-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#MyAppExeName}
InfoBeforeFile=INFO-BEFORE.txt
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "associate"; Description: "Associar com C:\LlamaServer (guardar path nas settings)"; GroupDescription: "Integracao:"; Flags: checkedonce
Name: "trayautostart"; Description: "Iniciar LlamaServer Tray com o Windows"; GroupDescription: "Tray:"; Flags: checkedonce
Name: "starttray"; Description: "Iniciar o Tray apos instalar"; GroupDescription: "Tray:"; Flags: checkedonce

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\LlamaServer Tray"; Filename: "{app}\{#MyTrayExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Autostart tray (HKCU — nao precisa admin)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "LlamaServerTray"; ValueData: """{app}\{#MyTrayExeName}"""; \
  Flags: uninsdeletevalue; Tasks: trayautostart

[Run]
Filename: "{app}\{#MyTrayExeName}"; Description: "Iniciar LlamaServer Tray"; \
  Flags: nowait postinstall skipifsilent; Tasks: starttray
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent unchecked

[UninstallRun]
Filename: "taskkill"; Parameters: "/IM {#MyTrayExeName} /F"; Flags: runhidden; RunOnceId: "KillTray"
Filename: "taskkill"; Parameters: "/IM {#MyAppExeName} /F"; Flags: runhidden; RunOnceId: "KillManager"

[Code]
function LlamaServerExists: Boolean;
begin
  Result := DirExists('C:\LlamaServer') and
            (FileExists('C:\LlamaServer\bin\llama-server.exe') or
             FileExists('C:\LlamaServer\config\server.env'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SettingsDir, SettingsFile, Json: string;
begin
  if CurStep <> ssPostInstall then Exit;
  if not WizardIsTaskSelected('associate') then Exit;
  if not LlamaServerExists then Exit;

  SettingsDir := ExpandConstant('{localappdata}\LlamaServerManager');
  ForceDirectories(SettingsDir);
  SettingsFile := SettingsDir + '\settings.json';
  Json := '{' + #13#10 +
          '  "LlamaServerRoot": "C:\\LlamaServer",' + #13#10 +
          '  "RuntimeMode": 0,' + #13#10 +
          '  "StartTrayWithWindows": true' + #13#10 +
          '}';
  SaveStringToFile(SettingsFile, Json, False);
end;

procedure InitializeWizard;
begin
  if not LlamaServerExists then
    MsgBox('C:\LlamaServer nao foi detectado.' + #13#10 +
           'Podes instalar na mesma o Manager/Tray e indicar o path em Settings.',
           mbInformation, MB_OK);
end;
