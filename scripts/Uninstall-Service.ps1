#Requires -Version 5.1
param([string]$InstallRoot = 'C:\LlamaServer')
$ErrorActionPreference = 'Continue'

function Find-Nssm {
  @(
    (Join-Path $InstallRoot 'tools\nssm.exe'),
    (Get-Command nssm.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source),
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

$nssm = Find-Nssm

# Thinking router first (depends on LlamaServer)
$trUninstall = Join-Path $InstallRoot 'tools\thinking-router\Uninstall-ThinkingRouter-Service.ps1'
if (Test-Path $trUninstall) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $trUninstall -InstallRoot $InstallRoot
}

$svc = 'LlamaServer'
if (Get-Service $svc -EA SilentlyContinue) {
  if ($nssm) {
    & $nssm stop $svc confirm 2>$null
    Start-Sleep 2
    & $nssm remove $svc confirm 2>$null
  } else {
    Stop-Service $svc -Force -EA SilentlyContinue
    sc.exe delete $svc | Out-Null
  }
}

Get-Process llama-server, LlamaServer.Tray, LlamaServer.Manager -EA SilentlyContinue |
  Stop-Process -Force -EA SilentlyContinue

Write-Host "Servico $svc removido."
