#Requires -Version 5.1
<#
.SYNOPSIS
  Publica Manager + Tray (win-x64) e gera o instalador Inno Setup.
#>
param(
  [string]$Configuration = 'Release',
  [string]$Version = '1.0.0',
  [switch]$SkipInno
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$ManagerProj = Join-Path $Root 'src\LlamaServer.Manager\LlamaServer.Manager.csproj'
$TrayProj = Join-Path $Root 'src\LlamaServer.Tray\LlamaServer.Tray.csproj'
$PublishDir = Join-Path $Root 'publish\win-x64'
$Iss = Join-Path $Root 'installer\LlamaServerManager.iss'
$Dist = Join-Path $Root 'dist'

function Publish-Project([string]$Proj, [string]$OutDir) {
  Write-Host "==> Publish $(Split-Path $Proj -Leaf) -> $OutDir" -ForegroundColor Cyan
  dotnet publish $Proj -c $Configuration -r win-x64 --self-contained true `
    -p:PublishSingleFile=false `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:Version=$Version `
    -o $OutDir
  if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed: $Proj" }
}

if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $PublishDir | Out-Null

# Manager first (full runtime), then Tray into same folder (overwrite shared deps OK)
Publish-Project $ManagerProj $PublishDir
Publish-Project $TrayProj $PublishDir

$helpSrc = Join-Path $Root 'tools\llama-server-help.txt'
if (Test-Path $helpSrc) {
  Copy-Item $helpSrc (Join-Path $PublishDir 'llama-server-help.txt') -Force
}

$mgr = Join-Path $PublishDir 'LlamaServer.Manager.exe'
$tray = Join-Path $PublishDir 'LlamaServer.Tray.exe'
if (-not (Test-Path $mgr)) { throw "Missing $mgr" }
if (-not (Test-Path $tray)) { throw "Missing $tray" }

Write-Host "==> Published:" -ForegroundColor Green
Write-Host "    $mgr"
Write-Host "    $tray"

if ($SkipInno) {
  Write-Host "SkipInno: usa a pasta publish\win-x64"
  exit 0
}

function Find-ISCC {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:LocalAppData}\Programs\Inno Setup 6\ISCC.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { return $c }
  }
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

$iscc = Find-ISCC
if (-not $iscc) {
  Write-Warning @"
Inno Setup 6 (ISCC.exe) nao encontrado.
Instala: https://jrsoftware.org/isdl.php
Ou corre com -SkipInno.
Publicacao em: $PublishDir
"@
  exit 2
}

New-Item -ItemType Directory -Force -Path $Dist | Out-Null
Write-Host "==> Compilar instalador com $iscc" -ForegroundColor Cyan
& $iscc "/DMyAppVersion=$Version" $Iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }

$setup = Get-ChildItem $Dist -Filter 'LlamaServerManager-Setup-*.exe' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($setup) {
  Write-Host "==> OK: $($setup.FullName)" -ForegroundColor Green
} else {
  Write-Warning "Setup nao encontrado em $Dist"
}
