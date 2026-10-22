#Requires -Version 5.1
<#
.SYNOPSIS
  Regista o servico NSSM LlamaServer (SuperLlama) e gera run-server.bat.
#>
param(
  [string]$InstallRoot = 'C:\LlamaServer',
  [ValidateSet('auto', 'demand')]
  [string]$StartType = 'auto',
  [switch]$StartNow
)

$ErrorActionPreference = 'Stop'

function Find-Nssm {
  $candidates = @(
    (Join-Path $InstallRoot 'tools\nssm.exe'),
    (Get-Command nssm.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source),
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe",
    "$env:ProgramFiles\nssm\nssm.exe",
    "${env:ProgramFiles(x86)}\nssm\win64\nssm.exe"
  ) | Where-Object { $_ }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  throw "nssm.exe nao encontrado. Instala com: winget install NSSM.NSSM"
}

$bin = Join-Path $InstallRoot 'bin\llama-server.exe'
if (-not (Test-Path $bin)) { throw "Falta $bin" }

New-Item -ItemType Directory -Force -Path `
  (Join-Path $InstallRoot 'logs'),
  (Join-Path $InstallRoot 'cache'),
  (Join-Path $InstallRoot 'scripts') | Out-Null

$writeBat = Join-Path $InstallRoot 'scripts\Write-RunServerBat.ps1'
if (Test-Path $writeBat) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $writeBat -Root $InstallRoot
  if ($LASTEXITCODE -ne 0) { throw "Write-RunServerBat falhou ($LASTEXITCODE)" }
}

$bat = Join-Path $InstallRoot 'scripts\run-server.bat'
if (-not (Test-Path $bat)) { throw "run-server.bat em falta apos Write-RunServerBat" }

$nssm = Find-Nssm
$svc = 'LlamaServer'

if (Get-Service $svc -EA SilentlyContinue) {
  # nssm writes to stderr even on benign "not started" — don't abort
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $nssm stop $svc confirm 2>$null | Out-Null
  Start-Sleep 1
  & $nssm remove $svc confirm 2>$null | Out-Null
  Start-Sleep 2
  $ErrorActionPreference = $prevEap
}

& $nssm install $svc $env:ComSpec '/c' "`"$bat`""
& $nssm set $svc AppDirectory (Join-Path $InstallRoot 'scripts')
& $nssm set $svc DisplayName "SuperLlama Server"
& $nssm set $svc Description "llama-server SuperLlama (CUDA) + llama.ui"
& $nssm set $svc Start $(if ($StartType -eq 'auto') { 'SERVICE_AUTO_START' } else { 'SERVICE_DEMAND_START' })
& $nssm set $svc AppStdout (Join-Path $InstallRoot 'logs\service.out.log')
& $nssm set $svc AppStderr (Join-Path $InstallRoot 'logs\service.err.log')
& $nssm set $svc AppRotateFiles 1
& $nssm set $svc AppRotateBytes 5000000
& $nssm set $svc AppExit Default Restart
& $nssm set $svc AppRestartDelay 3000

# CUDA device from server.env if present
$envFile = Join-Path $InstallRoot 'config\server.env'
$cuda = '0'
if (Test-Path $envFile) {
  $line = Get-Content $envFile | Where-Object { $_ -match '^\s*CudaVisibleDevices\s*=' } | Select-Object -First 1
  if ($line -match '=\s*(.+)$') { $cuda = $Matches[1].Trim() }
}
& $nssm set $svc AppEnvironmentExtra "CUDA_VISIBLE_DEVICES=$cuda"

if ($StartNow) {
  & $nssm start $svc
  Start-Sleep 2
}

$status = (Get-Service $svc -EA SilentlyContinue).Status
Write-Host "Servico $svc ($StartType): $status"
Write-Host "Health: http://127.0.0.1:11434/health"
Write-Host "UI:     http://127.0.0.1:11434/"
