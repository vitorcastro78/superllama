#Requires -Version 5.1
<#
.SYNOPSIS
  Build llama-server CUDA with TurboQuant KV (turbo2/turbo3/turbo4).

.NOTES
  Expects llama.cpp checkout on branch super-llama-turboquant (or -SkipBranchCheck).
  Default root: D:\src\llama.cpp — override with -LlamaCppRoot.
  Archs examples: 75;86 (Turing/Ampere), 89 (Ada 4050), 75;86;89
#>
param(
  [string]$LlamaCppRoot = 'D:\src\llama.cpp',
  [string]$Archs = '75;86',
  [string]$BuildDirName = 'build-cuda-turboquant',
  [string]$CudaPath = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.3',
  [string]$ExpectedBranch = 'super-llama-turboquant',
  [switch]$SkipBranchCheck
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $LlamaCppRoot)) {
  throw "llama.cpp root em falta: $LlamaCppRoot"
}

$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'VS Build Tools with C++ not found' }
$devCmd = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $devCmd)) { throw "VsDevCmd missing: $devCmd" }

if (-not (Test-Path $CudaPath)) { throw "CUDA toolkit missing: $CudaPath" }
$env:CUDA_PATH = $CudaPath
$env:PATH = "$CudaPath\bin;" + $env:PATH

if (-not $SkipBranchCheck) {
  Push-Location $LlamaCppRoot
  $branch = (git branch --show-current)
  Pop-Location
  if ($branch -ne $ExpectedBranch) {
    throw "Expected branch $ExpectedBranch, on $branch (use -SkipBranchCheck to override)"
  }
}

$build = Join-Path $LlamaCppRoot $BuildDirName
New-Item -ItemType Directory -Force -Path $build | Out-Null

$gen = 'Ninja'
$ninja = Get-Command ninja -EA SilentlyContinue
if (-not $ninja) { $gen = 'Visual Studio 17 2022' }

if ($gen -eq 'Ninja') {
  $cmd = @"
call `"$devCmd`" -arch=amd64 && cd /d `"$LlamaCppRoot`" && cmake -S . -B `"$build`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=`"$Archs`" -DGGML_CUDA_FA_ALL_QUANTS=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON && cmake --build `"$build`" --config Release -j %NUMBER_OF_PROCESSORS%
"@
} else {
  $cmd = @"
call `"$devCmd`" -arch=amd64 && cd /d `"$LlamaCppRoot`" && cmake -S . -B `"$build`" -G `"Visual Studio 17 2022`" -A x64 -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=`"$Archs`" -DGGML_CUDA_FA_ALL_QUANTS=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON && cmake --build `"$build`" --config Release -j %NUMBER_OF_PROCESSORS%
"@
}

Write-Host "==> Build-CudaTurboQuant Archs=$Archs BuildDir=$build" -ForegroundColor Cyan
Write-Host $cmd
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "build failed exit=$LASTEXITCODE" }
Write-Host 'BUILD OK' -ForegroundColor Green
Get-ChildItem $build -Recurse -Filter 'llama-server.exe' | Select-Object FullName, Length, LastWriteTime
