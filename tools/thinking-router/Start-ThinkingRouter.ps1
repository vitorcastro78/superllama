#Requires -Version 5.1
param([switch]$InstallDeps, [switch]$Cpu)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
Set-Location $Root
$venv = Join-Path $Root '.venv'
$py = Join-Path $venv 'Scripts\python.exe'

if (-not (Test-Path $py)) {
  Write-Host "Creating venv..." -ForegroundColor Cyan
  python -m venv $venv
  $InstallDeps = $true
}

if ($InstallDeps) {
  & $py -m pip install -U pip
  & $py -m pip install torch --index-url https://download.pytorch.org/whl/cu124
  & $py -m pip install -r (Join-Path $Root 'requirements.txt')
}

Get-Content (Join-Path $Root 'config.env') | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $k, $v = $_.Split('=', 2)
  [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), 'Process')
}

if ($Cpu) { $env:CUDA_DEVICE = 'cpu' }

Write-Host "Starting Thinking Router http://$($env:HOST):$($env:PORT) → $($env:UPSTREAM)" -ForegroundColor Green
& $py -m uvicorn router:app --host $env:HOST --port $env:PORT
