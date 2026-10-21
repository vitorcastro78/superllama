#Requires -Version 5.1
param(
  [string]$InstallRoot = 'C:\LlamaServer'
)

$ErrorActionPreference = 'Stop'
$tools = Join-Path $InstallRoot 'tools\inference-monitor'
$vbs = Join-Path $tools 'Start-InferenceMonitor.vbs'
if (-not (Test-Path $vbs)) { throw "Inference Monitor em falta: $vbs" }

$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'Inference Monitor.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($shortcutPath)
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = "`"$vbs`""
$sc.WorkingDirectory = $tools
$sc.WindowStyle = 7
$sc.Description = 'SuperLlama Inference Monitor (http://0.0.0.0:11436/ LAN)'
$sc.Save()
Write-Output $shortcutPath
