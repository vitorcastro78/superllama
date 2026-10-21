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

$svc = 'ThinkingRouter'
$nssm = Find-Nssm
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

Get-NetTCPConnection -LocalPort 11437 -State Listen -EA SilentlyContinue | ForEach-Object {
  Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue
}

Write-Host "Servico $svc removido."
