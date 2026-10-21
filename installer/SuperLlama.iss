; SuperLlama — stack completo (bin + llama.ui + Manager + Tray + Monitor + Thinking Router)
; Compilar via scripts\Build-Installer.ps1
#define MyAppName "SuperLlama"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "Kortexio"
#define MyAppURL "http://127.0.0.1:11434/"
#define ManagerExe "LlamaServer.Manager.exe"
#define TrayExe "LlamaServer.Tray.exe"
#ifndef PayloadDir
  #define PayloadDir "..\staging\payload"
#endif
#ifndef ManagerDir
  #define ManagerDir "..\staging\manager"
#endif

[Setup]
AppId={{B8D4F0A2-3C5E-4F9B-8D2A-7E6F9B1C4D3E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName=C:\LlamaServer
DefaultGroupName={#MyAppName}
DisableDirPage=no
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=SuperLlama-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
UninstallDisplayIcon={app}\manager\{#ManagerExe}
InfoBeforeFile=INFO-BEFORE.txt
CloseApplications=yes
RestartApplications=no
MinVersion=10.0
SetupLogging=yes

[Languages]
Name: "portuguese"; MessagesFile: "compiler:Languages\Portuguese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "serviceautostart"; Description: "Carregar SuperLlama / llama.cpp (servico) ao iniciar o Windows"; GroupDescription: "Arranque:"; Flags: checkedonce
Name: "startservice"; Description: "Iniciar o servico SuperLlama apos instalar"; GroupDescription: "Arranque:"; Flags: checkedonce
Name: "trayautostart"; Description: "Iniciar Tray Icon com o Windows"; GroupDescription: "Tray:"; Flags: checkedonce
Name: "starttray"; Description: "Iniciar o Tray apos instalar"; GroupDescription: "Tray:"; Flags: checkedonce
Name: "monitorautostart"; Description: "Iniciar Inference Monitor com o Windows (GPU + tok/s)"; GroupDescription: "Monitor:"; Flags: checkedonce
Name: "startmonitor"; Description: "Abrir Inference Monitor apos instalar"; GroupDescription: "Monitor:"; Flags: checkedonce
Name: "routerautostart"; Description: "Instalar Thinking Router (GLiNER on/off) como servico — pip na 1ª vez"; GroupDescription: "Thinking Router:"; Flags: unchecked
Name: "startrouter"; Description: "Iniciar Thinking Router apos instalar"; GroupDescription: "Thinking Router:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\config\*"; DestDir: "{app}\config"; Flags: ignoreversion onlyifdoesntexist
Source: "{#PayloadDir}\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\ui\*"; DestDir: "{app}\ui"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\tools\*"; DestDir: "{app}\tools"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ManagerDir}\*"; DestDir: "{app}\manager"; Flags: ignoreversion recursesubdirs createallsubdirs

[Dirs]
Name: "{app}\logs"
Name: "{app}\cache"
Name: "{app}\config"
Name: "{app}\tools\thinking-router\logs"
Name: "{app}\tools\thinking-router\hf-cache"
Name: "C:\Models\gguf"; Flags: uninsneveruninstall

[Icons]
Name: "{group}\{#MyAppName} Manager (Admin)"; Filename: "{app}\manager\{#ManagerExe}"
Name: "{group}\{#MyAppName} Tray"; Filename: "{app}\manager\{#TrayExe}"
Name: "{group}\Inference Monitor"; Filename: "{app}\tools\inference-monitor\Start-InferenceMonitor.bat"
Name: "{group}\Thinking Router (manual)"; Filename: "{app}\tools\thinking-router\Start-ThinkingRouter.bat"
Name: "{group}\Abrir llama.ui"; Filename: "{#MyAppURL}"
Name: "{group}\Abrir Inference Monitor (URL)"; Filename: "http://127.0.0.1:11436/"
Name: "{group}\Abrir Thinking Router (health)"; Filename: "http://127.0.0.1:11437/health"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName} Manager"; Filename: "{app}\manager\{#ManagerExe}"; Tasks: desktopicon
Name: "{autodesktop}\Inference Monitor"; Filename: "{app}\tools\inference-monitor\Start-InferenceMonitor.bat"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "SuperLlamaTray"; ValueData: """{app}\manager\{#TrayExe}"""; \
  Flags: uninsdeletevalue; Tasks: trayautostart

[Run]
Filename: "{app}\manager\{#TrayExe}"; Description: "Iniciar SuperLlama Tray"; \
  Flags: nowait postinstall skipifsilent; Tasks: starttray
Filename: "{app}\manager\{#ManagerExe}"; Description: "Abrir SuperLlama Manager (Admin)"; \
  Flags: nowait postinstall skipifsilent unchecked
Filename: "{#MyAppURL}"; Description: "Abrir llama.ui no browser"; \
  Flags: nowait postinstall skipifsilent shellexec unchecked
Filename: "wscript.exe"; \
  Parameters: """{app}\tools\inference-monitor\Start-InferenceMonitor.vbs"""; \
  Description: "Abrir Inference Monitor"; \
  Flags: nowait postinstall skipifsilent; Tasks: startmonitor

[UninstallRun]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Uninstall-Service.ps1"" -InstallRoot ""{app}"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "StopSuperLlamaService"
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\inference-monitor\Uninstall-InferenceMonitor-Startup.ps1"" -InstallRoot ""{app}"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "StopInferenceMonitor"
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\tools\thinking-router\Uninstall-ThinkingRouter-Service.ps1"" -InstallRoot ""{app}"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "StopThinkingRouter"
Filename: "taskkill"; Parameters: "/IM {#TrayExe} /F"; Flags: runhidden; RunOnceId: "KillTray"
Filename: "taskkill"; Parameters: "/IM {#ManagerExe} /F"; Flags: runhidden; RunOnceId: "KillManager"
Filename: "taskkill"; Parameters: "/IM llama-server.exe /F"; Flags: runhidden; RunOnceId: "KillServer"

[Code]
function EscapeJsonPath(const S: string): string;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
end;

procedure WriteManagerSettings(const AppDir: string);
var
  SettingsDir, SettingsFile, Json, TrayBool: string;
begin
  SettingsDir := ExpandConstant('{localappdata}\LlamaServerManager');
  ForceDirectories(SettingsDir);
  SettingsFile := SettingsDir + '\settings.json';
  if WizardIsTaskSelected('trayautostart') then
    TrayBool := 'true'
  else
    TrayBool := 'false';
  Json := '{' + #13#10 +
          '  "LlamaServerRoot": "' + EscapeJsonPath(AppDir) + '",' + #13#10 +
          '  "RuntimeMode": 0,' + #13#10 +
          '  "StartTrayWithWindows": ' + TrayBool + #13#10 +
          '}';
  SaveStringToFile(SettingsFile, Json, False);
end;

procedure RegisterService(const AppDir: string);
var
  Ps1, StartType, Params: string;
  ResultCode: Integer;
begin
  Ps1 := AppDir + '\scripts\Install-Service.ps1';
  if not FileExists(Ps1) then
  begin
    MsgBox('Install-Service.ps1 em falta: ' + Ps1, mbError, MB_OK);
    Exit;
  end;

  if WizardIsTaskSelected('serviceautostart') then
    StartType := 'auto'
  else
    StartType := 'demand';

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + Ps1 +
            '" -InstallRoot "' + AppDir + '" -StartType ' + StartType;
  if WizardIsTaskSelected('startservice') then
    Params := Params + ' -StartNow';

  if not Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    MsgBox('Falha ao executar Install-Service.ps1', mbError, MB_OK)
  else if ResultCode <> 0 then
    MsgBox('Install-Service.ps1 terminou com codigo ' + IntToStr(ResultCode) +
           '. Verifica se o NSSM esta disponivel.', mbError, MB_OK);
end;

procedure RegisterInferenceMonitorStartup(const AppDir: string);
var
  Ps1, Params: string;
  ResultCode: Integer;
begin
  if not WizardIsTaskSelected('monitorautostart') then Exit;
  Ps1 := AppDir + '\tools\inference-monitor\Install-InferenceMonitor-Startup.ps1';
  if not FileExists(Ps1) then Exit;
  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + Ps1 +
            '" -InstallRoot "' + AppDir + '"';
  Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure RegisterThinkingRouter(const AppDir: string);
var
  Ps1, StartType, Params: string;
  ResultCode: Integer;
begin
  if not WizardIsTaskSelected('routerautostart') then Exit;
  Ps1 := AppDir + '\tools\thinking-router\Install-ThinkingRouter-Service.ps1';
  if not FileExists(Ps1) then
  begin
    MsgBox('Install-ThinkingRouter-Service.ps1 em falta.', mbError, MB_OK);
    Exit;
  end;

  if WizardIsTaskSelected('serviceautostart') then
    StartType := 'auto'
  else
    StartType := 'demand';

  Params := '-NoProfile -ExecutionPolicy Bypass -File "' + Ps1 +
            '" -InstallRoot "' + AppDir + '" -StartType ' + StartType;
  if WizardIsTaskSelected('startrouter') then
    Params := Params + ' -StartNow';

  { pip + torch — pode demorar; mostra janela }
  if not Exec('powershell.exe', Params, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
    MsgBox('Falha ao executar Install-ThinkingRouter-Service.ps1', mbError, MB_OK)
  else if ResultCode <> 0 then
    MsgBox('Thinking Router install terminou com codigo ' + IntToStr(ResultCode) +
           '. Precisas de Python 3.10+ e internet na 1ª vez.', mbError, MB_OK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  AppDir: string;
begin
  if CurStep <> ssPostInstall then Exit;
  AppDir := ExpandConstant('{app}');
  WriteManagerSettings(AppDir);
  RegisterService(AppDir);
  RegisterInferenceMonitorStartup(AppDir);
  RegisterThinkingRouter(AppDir);
end;
