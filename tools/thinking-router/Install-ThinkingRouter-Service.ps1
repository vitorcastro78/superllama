#Requires -Version 5.1
<#
.SYNOPSIS
  Cria venv (se preciso), instala deps e regista servico NSSM ThinkingRouter.
#>
param(
  [string]$InstallRoot = 'C:\LlamaServer',
  [ValidateSet('auto', 'demand')]
  [string]$StartType = 'auto',
  [switch]$StartNow,
  [switch]$SkipPip
)

$ErrorActionPreference = 'Stop'
$RouterRoot = Join-Path $InstallRoot 'tools\thinking-router'
$pyVenv = Join-Path $RouterRoot '.venv\Scripts\python.exe'
$req = Join-Path $RouterRoot 'requirements.txt'
$logDir = Join-Path $RouterRoot 'logs'
$hfCache = Join-Path $RouterRoot 'hf-cache'
New-Item -ItemType Directory -Force -Path $logDir, $hfCache | Out-Null

function Find-Nssm {
  @(
    (Join-Path $InstallRoot 'tools\nssm.exe'),
    (Get-Command nssm.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source),
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe"
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Find-SystemPython {
  foreach ($c in @(
      (Get-Command python.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source),
      "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
      "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
      "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
      'C:\Python312\python.exe',
      'C:\Python311\python.exe'
    )) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  throw "Python 3.10+ nao encontrado. Instala de https://www.python.org/downloads/ (Add to PATH)."
}

if (-not (Test-Path (Join-Path $RouterRoot 'router.py'))) {
  throw "Thinking router em falta: $RouterRoot\router.py"
}

if (-not (Test-Path $pyVenv)) {
  Write-Host "A criar venv em $RouterRoot\.venv ..." -ForegroundColor Cyan
  $sysPy = Find-SystemPython
  & $sysPy -m venv (Join-Path $RouterRoot '.venv')
  if (-not (Test-Path $pyVenv)) { throw "Falha ao criar venv" }
}

if (-not $SkipPip) {
  Write-Host "A instalar dependencias do thinking-router (1ª vez pode demorar)..." -ForegroundColor Cyan
  & $pyVenv -m pip install -U pip
  # Torch CUDA 12.4 wheel when possible; fallback to default index
  & $pyVenv -m pip install torch --index-url https://download.pytorch.org/whl/cu124
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "Torch CUDA wheel falhou; a tentar PyPI default..."
    & $pyVenv -m pip install torch
  }
  & $pyVenv -m pip install -r $req
  if ($LASTEXITCODE -ne 0) { throw "pip install thinking-router falhou" }
}

# Free port
Get-NetTCPConnection -LocalPort 11437 -State Listen -EA SilentlyContinue | ForEach-Object {
  Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue
}
Start-Sleep 1

$nssm = Find-Nssm
if (-not $nssm) { throw "nssm.exe nao encontrado em $InstallRoot\tools" }

$svc = 'ThinkingRouter'
if (Get-Service $svc -EA SilentlyContinue) {
  & $nssm stop $svc confirm 2>$null
  Start-Sleep 2
  & $nssm remove $svc confirm 2>$null
  Start-Sleep 1
}

& $nssm install $svc $pyVenv
& $nssm set $svc AppParameters '-m uvicorn router:app --host 127.0.0.1 --port 11437'
& $nssm set $svc AppDirectory $RouterRoot
& $nssm set $svc DisplayName 'SuperLlama Thinking Router'
& $nssm set $svc Description 'GLiNER thinking on/off :11437 -> llama-server :11434'
& $nssm set $svc Start $(if ($StartType -eq 'auto') { 'SERVICE_AUTO_START' } else { 'SERVICE_DEMAND_START' })
& $nssm set $svc AppStdout (Join-Path $logDir 'thinking-router.out.log')
& $nssm set $svc AppStderr (Join-Path $logDir 'thinking-router.err.log')
& $nssm set $svc AppRotateFiles 1
& $nssm set $svc AppRotateBytes 2097152
& $nssm set $svc AppRestartDelay 5000
& $nssm set $svc AppExit Default Restart
& $nssm set $svc DependOnService LlamaServer
& $nssm set $svc AppEnvironmentExtra `
  "CUDA_DEVICE=auto" `
  "UPSTREAM=http://127.0.0.1:11434" `
  "HOST=127.0.0.1" `
  "PORT=11437" `
  "LOG_DECISIONS=1" `
  "RESPECT_CLIENT_FLAG=1" `
  "GLINER_MODEL=fastino/GLiNER2.5-Decide" `
  "HF_HOME=$hfCache" `
  "HUGGINGFACE_HUB_CACHE=$hfCache\hub"

if ($StartType -eq 'auto') {
  sc.exe config $svc start= delayed-auto | Out-Null
}

if ($StartNow) {
  & $nssm start $svc
  Start-Sleep 12
}

$status = (Get-Service $svc -EA SilentlyContinue).Status
Write-Host "Servico $svc ($StartType): $status"
Write-Host "Thinking Router: http://127.0.0.1:11437/health"
Write-Host "Kortex/API path: :11437 -> :11434"
