#Requires -Version 5.1
<#
.SYNOPSIS
  Empacota SuperLlama TurboQuant (bin + llama.ui + scripts) + Manager/Tray e gera Setup Inno.

.NOTES
  Requer llama-server com KV TurboQuant (turbo2/turbo3/turbo4).
  BinSource default: build-cuda-turboquant; fallback C:\LlamaServer\bin se validar turbo4.
#>
param(
  [string]$Version = '1.2.0',
  [string]$BinSource = '',
  [string]$UiSource = 'C:\LlamaServer\ui\llama.ui',
  [string]$Configuration = 'Release',
  [switch]$SkipPublish,
  [switch]$SkipInno,
  [switch]$SkipTurboQuantCheck
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Staging = Join-Path $Root 'staging'
$Payload = Join-Path $Staging 'payload'
$ManagerOut = Join-Path $Staging 'manager'
$Dist = Join-Path $Root 'dist'
$Iss = Join-Path $Root 'installer\SuperLlama.iss'

function Resolve-ManagerRepo {
  $candidates = @(
    (Join-Path $Root 'LlamaServer.Manager'),
    (Join-Path (Split-Path $Root -Parent) 'LlamaServer.Manager')
  )
  foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'src\LlamaServer.Manager\LlamaServer.Manager.csproj')) {
      return (Resolve-Path $c).Path
    }
  }
  return $null
}

function Find-ISCC {
  foreach ($c in @(
      "${env:LocalAppData}\Programs\Inno Setup 6\ISCC.exe",
      "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
      "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
    if (Test-Path $c) { return $c }
  }
  $cmd = Get-Command ISCC.exe -EA SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Find-Nssm {
  foreach ($c in @(
      "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe",
      (Get-Command nssm.exe -EA SilentlyContinue | Select-Object -ExpandProperty Source),
      "$env:ProgramFiles\nssm\nssm.exe",
      "${env:ProgramFiles(x86)}\nssm\win64\nssm.exe"
    )) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  return $null
}

function Test-TurboQuantBin([string]$Dir) {
  $exe = Join-Path $Dir 'llama-server.exe'
  if (-not (Test-Path $exe)) { return $false }
  $help = & $exe --help 2>&1 | Out-String
  return ($help -match 'turbo4')
}

function Resolve-BinSource([string]$Requested) {
  if ($Requested -and (Test-Path (Join-Path $Requested 'llama-server.exe'))) {
    return (Resolve-Path $Requested).Path
  }
  $preferred = 'D:\src\llama.cpp\build-cuda-turboquant\bin'
  $fallback = 'C:\LlamaServer\bin'
  foreach ($c in @($preferred, $fallback)) {
    if (Test-Path (Join-Path $c 'llama-server.exe')) {
      return (Resolve-Path $c).Path
    }
  }
  throw "Binario SuperLlama em falta. Build com scripts\Build-CudaTurboQuant.ps1 ou passa -BinSource."
}

Write-Host "==> SuperLlama Build-Installer v$Version (TurboQuant)" -ForegroundColor Cyan

$BinSource = Resolve-BinSource $BinSource
Write-Host "    BinSource=$BinSource"

if (-not $SkipTurboQuantCheck) {
  if (-not (Test-TurboQuantBin $BinSource)) {
    throw "Binario sem TurboQuant KV (turbo4 ausente em --help). Corre Build-CudaTurboQuant.ps1 ou usa -SkipTurboQuantCheck."
  }
  Write-Host "    TurboQuant OK (turbo4 presente)" -ForegroundColor Green
}

if (-not (Test-Path (Join-Path $UiSource 'index.html'))) {
  throw "llama.ui em falta: $UiSource"
}

$ManagerRepo = Resolve-ManagerRepo
if (-not $ManagerRepo) {
  throw "LlamaServer.Manager nao encontrado em $Root\LlamaServer.Manager nem no directorio irmao"
}
Write-Host "    ManagerRepo=$ManagerRepo"

if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }
@(
  "$Payload\bin",
  "$Payload\config",
  "$Payload\scripts",
  "$Payload\ui\llama.ui",
  "$Payload\tools",
  $ManagerOut,
  $Dist
) | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ | Out-Null }

Write-Host "==> Staging bin from $BinSource" -ForegroundColor Cyan
Copy-Item "$BinSource\*" "$Payload\bin\" -Recurse -Force

function Find-CudaRedistDir {
  foreach ($c in @(
      "$env:CUDA_PATH\bin\x64",
      "$env:CUDA_PATH\bin",
      'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3\bin\x64',
      'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1\bin\x64',
      'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0\bin\x64',
      'C:\LlamaServer\bin',
      $BinSource
    )) {
    if ($c -and (Test-Path (Join-Path $c 'cublas64_13.dll'))) { return $c }
  }
  return $null
}
$cudaRedist = Find-CudaRedistDir
if (-not $cudaRedist) {
  throw "cublas64_13.dll nao encontrado. Instala CUDA Toolkit 13.x ou coloca as DLLs em C:\LlamaServer\bin"
}
Write-Host "==> Staging CUDA redist from $cudaRedist" -ForegroundColor Cyan
foreach ($dll in @('cublas64_13.dll', 'cublasLt64_13.dll', 'cudart64_13.dll')) {
  $src = Join-Path $cudaRedist $dll
  if (-not (Test-Path $src)) { throw "CUDA DLL em falta: $src" }
  Copy-Item $src "$Payload\bin\" -Force
  Write-Host "    $dll"
}

Write-Host "==> Staging llama.ui from $UiSource" -ForegroundColor Cyan
Copy-Item "$UiSource\*" "$Payload\ui\llama.ui\" -Recurse -Force
Set-Content -Path "$Payload\ui\SERVE_PATH.txt" -Value 'C:\LlamaServer\ui\llama.ui' -Encoding ASCII

Write-Host "==> Staging config + scripts" -ForegroundColor Cyan
Copy-Item "$Root\config\*" "$Payload\config\" -Force
Copy-Item "$Root\scripts\Install-Service.ps1" "$Payload\scripts\" -Force
Copy-Item "$Root\scripts\Uninstall-Service.ps1" "$Payload\scripts\" -Force
Copy-Item "$Root\scripts\Write-RunServerBat.ps1" "$Payload\scripts\" -Force

$nssm = Find-Nssm
if (-not $nssm) {
  Write-Host "nssm nao encontrado - a tentar winget install NSSM.NSSM..." -ForegroundColor Yellow
  winget install --id NSSM.NSSM -e --accept-package-agreements --accept-source-agreements | Out-Host
  $nssm = Find-Nssm
}
if (-not $nssm) { throw "nssm.exe obrigatorio para o instalador (servico Windows)." }
Copy-Item $nssm "$Payload\tools\nssm.exe" -Force
Write-Host "    nssm from $nssm"

$monitorSrc = Join-Path $Root 'tools\inference-monitor'
if (-not (Test-Path (Join-Path $monitorSrc 'gpu-monitor.py'))) {
  throw "Inference Monitor em falta: $monitorSrc\gpu-monitor.py"
}
$monitorDst = Join-Path $Payload 'tools\inference-monitor'
New-Item -ItemType Directory -Force -Path $monitorDst | Out-Null
Copy-Item "$monitorSrc\*" $monitorDst -Force
Write-Host "==> Staging Inference Monitor -> tools\inference-monitor (porta 11436)" -ForegroundColor Cyan

$routerSrc = Join-Path $Root 'tools\thinking-router'
if (-not (Test-Path (Join-Path $routerSrc 'router.py'))) {
  throw "Thinking Router em falta: $routerSrc\router.py"
}
$routerDst = Join-Path $Payload 'tools\thinking-router'
New-Item -ItemType Directory -Force -Path $routerDst | Out-Null
Get-ChildItem $routerSrc -File | Where-Object {
  $_.Name -notmatch '^\.venv' -and $_.Extension -notin '.pyc'
} | ForEach-Object { Copy-Item $_.FullName $routerDst -Force }
Write-Host "==> Staging Thinking Router -> tools\thinking-router (porta 11437)" -ForegroundColor Cyan
foreach ($need in @('router.py', 'requirements.txt', 'config.env', 'Install-ThinkingRouter-Service.ps1', 'Uninstall-ThinkingRouter-Service.ps1')) {
  if (-not (Test-Path (Join-Path $routerDst $need))) { throw "Thinking Router em falta no staging: $need" }
}

if (-not $SkipPublish) {
  $mgrProj = Join-Path $ManagerRepo 'src\LlamaServer.Manager\LlamaServer.Manager.csproj'
  $trayProj = Join-Path $ManagerRepo 'src\LlamaServer.Tray\LlamaServer.Tray.csproj'
  Write-Host "==> Publish Manager" -ForegroundColor Cyan
  dotnet publish $mgrProj -c $Configuration -r win-x64 --self-contained true `
    -p:PublishSingleFile=false -p:Version=$Version -o $ManagerOut
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish Manager falhou" }
  Write-Host "==> Publish Tray" -ForegroundColor Cyan
  dotnet publish $trayProj -c $Configuration -r win-x64 --self-contained true `
    -p:PublishSingleFile=false -p:Version=$Version -o $ManagerOut
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish Tray falhou" }
}
else {
  $existing = Join-Path $ManagerRepo 'publish\win-x64'
  if (-not (Test-Path (Join-Path $existing 'LlamaServer.Tray.exe'))) {
    throw "SkipPublish mas $existing nao tem Tray. Corre sem -SkipPublish."
  }
  Copy-Item "$existing\*" $ManagerOut -Recurse -Force
}

foreach ($need in @('LlamaServer.Manager.exe', 'LlamaServer.Tray.exe')) {
  if (-not (Test-Path (Join-Path $ManagerOut $need))) {
    throw "Em falta no staging manager: $need"
  }
}

$binMb = [math]::Round(((Get-ChildItem "$Payload\bin" -File | Measure-Object Length -Sum).Sum / 1MB), 0)
$uiMb = [math]::Round(((Get-ChildItem "$Payload\ui" -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 0)
$mgrMb = [math]::Round(((Get-ChildItem $ManagerOut -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 0)
Write-Host "==> Staging OK" -ForegroundColor Green
Write-Host "    bin=$binMb MB"
Write-Host "    ui =$uiMb MB"
Write-Host "    mgr=$mgrMb MB"

if ($SkipInno) {
  Write-Host "SkipInno: staging em $Staging"
  exit 0
}

$iscc = Find-ISCC
if (-not $iscc) {
  throw "ISCC.exe (Inno Setup 6) nao encontrado. Instala: https://jrsoftware.org/isdl.php"
}

Write-Host "==> ISCC $iscc" -ForegroundColor Cyan
& $iscc "/DMyAppVersion=$Version" $Iss
if ($LASTEXITCODE -ne 0) { throw "ISCC falhou ($LASTEXITCODE)" }

$setup = Get-ChildItem $Dist -Filter 'SuperLlama-Setup-*.exe' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { throw "Setup nao encontrado em $Dist" }
$mb = [math]::Round($setup.Length / 1MB, 1)
Write-Host "==> OK: $($setup.FullName) - $mb MB" -ForegroundColor Green
