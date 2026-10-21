#Requires -Version 5.1
param(
  [string]$InstallRoot = 'C:\LlamaServer'
)

$ErrorActionPreference = 'SilentlyContinue'
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'Inference Monitor.lnk'
if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }

# stop backend on 11436 if it is our monitor
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
  Where-Object { $_.CommandLine -match 'gpu-monitor\.py' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Get-NetTCPConnection -LocalPort 11436 -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

Write-Output 'Inference Monitor startup removed'
