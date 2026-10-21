#Requires -Version 5.1
<#
.SYNOPSIS
  DEPRECATED — usa Build-Installer.ps1 (TurboQuant unificado).

  Mantido como wrapper para scripts antigos. Preferir:
    .\scripts\Build-Installer.ps1 -Version 1.2.0
#>
param(
  [string]$Version = '1.2.0',
  [string]$BinSource = 'D:\src\llama.cpp\build-cuda-turboquant\bin',
  [string]$UiSource = 'C:\LlamaServer\ui\llama.ui',
  [switch]$SkipPublish,
  [switch]$SkipInno
)

$ErrorActionPreference = 'Stop'
Write-Host "DEPRECATED: Build-Installer-TurboQuant4050 -> Build-Installer.ps1" -ForegroundColor Yellow

& (Join-Path $PSScriptRoot 'Build-Installer.ps1') `
  -Version $Version `
  -BinSource $BinSource `
  -UiSource $UiSource `
  -SkipPublish:$SkipPublish `
  -SkipInno:$SkipInno
