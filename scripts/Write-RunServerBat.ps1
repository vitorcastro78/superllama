#Requires -Version 5.1
param(
  [string]$Root = 'C:\LlamaServer'
)

$ErrorActionPreference = 'Stop'
$envPath = Join-Path $Root 'config\server.env'
$preset = Join-Path $Root 'config\models-preset.ini'
$batPath = Join-Path $Root 'scripts\run-server.bat'
$bin = Join-Path $Root 'bin'

$cfg = @{}
Get-Content $envPath | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $k, $v = $_.Split('=', 2)
  $cfg[$k.Trim()] = $v.Trim()
}

$exe = Join-Path $bin 'llama-server.exe'
if (-not (Test-Path $exe)) {
  # some zips ship only llama.exe with serve subcommand — prefer llama-server
  $alt = Join-Path $bin 'llama.exe'
  if (Test-Path $alt) { $exe = $alt }
}

$hostA = $cfg['Host']; if (-not $hostA) { $hostA = '127.0.0.1' }
$port = $cfg['Port']; if (-not $port) { $port = '11434' }
$ngl = $cfg['GpuLayers']; if (-not $ngl) { $ngl = '99' }
$ctx = $cfg['CtxSize']; if (-not $ctx) { $ctx = '65536' }
$npred = $cfg['NPredict']; if (-not $npred) { $npred = '32768' }
$par = $cfg['Parallel']; if (-not $par) { $par = '1' }
$mmax = $cfg['ModelsMax']; if (-not $mmax) { $mmax = '1' }
$fa = $cfg['FlashAttn']; if (-not $fa) { $fa = 'on' }
$th = $cfg['Threads']; if (-not $th) { $th = '1' }
$ctk = $cfg['CacheTypeK']; if (-not $ctk) { $ctk = 'turbo4' }
$ctv = $cfg['CacheTypeV']; if (-not $ctv) { $ctv = 'turbo3' }
$rea = $cfg['Reasoning']; if (-not $rea) { $rea = 'auto' }
$eff = $cfg['ReasoningEffort']; if (-not $eff) { $eff = 'medium' }
$bud = $cfg['ReasoningBudget']; if (-not $bud) { $bud = '4096' }
# Tools=all enables server-built-in tools; Tools=none/off/0 disables. Empty → none (API agents bring their own).
$tools = $cfg['Tools']
if ($null -eq $tools) { $tools = '' }
$toolsOff = ($tools -match '^(none|off|0|false|no)?$')
$sm = $cfg['SplitMode']; if (-not $sm) { $sm = 'none' }
$tsplit = $cfg['TensorSplit']
$cuda = $cfg['CudaVisibleDevices']; if ($null -eq $cuda -or $cuda -eq '') { $cuda = '0' }
# UseRouter=0 + Model=path → single llama-server (-m), no router child process
$useRouter = -not ($cfg['UseRouter'] -match '^(0|false|off|no)$')
$modelPath = $cfg['Model']
if (-not $modelPath) { $modelPath = $cfg['ModelPath'] }

$a = New-Object System.Collections.Generic.List[string]
if ((Split-Path $exe -Leaf) -eq 'llama.exe') {
  [void]$a.Add('serve')
}
if ($useRouter) {
  [void]$a.Add("--models-preset `"$preset`"")
} elseif ($modelPath) {
  [void]$a.Add("-m `"$modelPath`"")
  if ($cfg['DefaultModel']) { [void]$a.Add("--alias $($cfg['DefaultModel'])") }
} else {
  throw "UseRouter=0 requires Model= path to GGUF in server.env"
}
[void]$a.Add("--host $hostA"); [void]$a.Add("--port $port")
[void]$a.Add("-ngl $ngl"); [void]$a.Add("-c $ctx")
[void]$a.Add("--n-predict $npred")
[void]$a.Add("--parallel $par")
if ($useRouter) {
  [void]$a.Add("--models-max $mmax")
  if ($cfg['ModelsAutoload'] -match '^(1|true|on|yes)$') { [void]$a.Add('--models-autoload') }
  elseif ($cfg.ContainsKey('ModelsAutoload') -and $cfg['ModelsAutoload'] -match '^(0|false|off|no)$') { [void]$a.Add('--no-models-autoload') }
}
[void]$a.Add("-fa $fa"); [void]$a.Add("--threads $th")
[void]$a.Add("-ctk $ctk"); [void]$a.Add("-ctv $ctv")
if ($cfg['Device']) { [void]$a.Add("--device $($cfg['Device'])") }
[void]$a.Add("--split-mode $sm")
if ($tsplit -and $sm -ne 'none') { [void]$a.Add("--tensor-split $tsplit") }
if ($cfg.ContainsKey('MainGpu') -and $cfg['MainGpu'] -ne '') { [void]$a.Add("--main-gpu $($cfg['MainGpu'])") }
if ($cfg.ContainsKey('Fit') -and $cfg['Fit'] -ne '') { [void]$a.Add("--fit $($cfg['Fit'])") }
if ($cfg['KvUnified'] -match '^(1|true|on|yes)$') { [void]$a.Add('--kv-unified') }
if ($cfg['CachePrompt'] -notmatch '^(0|false|off|no)$') { [void]$a.Add('--cache-prompt') }
$cr = $cfg['CacheReuse']; if (-not $cr) { $cr = '512' }
if ([int]$cr -gt 0) { [void]$a.Add("--cache-reuse $cr") }
$sps = $cfg['SlotPromptSimilarity']; if (-not $sps) { $sps = '0.30' }
[void]$a.Add("--slot-prompt-similarity $sps")
[void]$a.Add('--jinja')
[void]$a.Add("--reasoning $rea")
[void]$a.Add("--reasoning-effort $eff")
[void]$a.Add("--reasoning-budget $bud")
if ($cfg['ReasoningPreserve'] -match '^(1|true|on|yes)$') { [void]$a.Add('--reasoning-preserve') }
if ($cfg['Agent'] -match '^(1|true|on|yes)$') { [void]$a.Add('--agent') }
if (-not $toolsOff -and $tools) { [void]$a.Add("--tools $tools") }
if ($cfg['MediaPath']) {
  $mp = [string]$cfg['MediaPath']
  if ($mp.EndsWith('\')) { $mp = $mp.TrimEnd('\') + '/' }
  [void]$a.Add("--media-path `"$mp`"")
}
# llama.ui (or any static WebUI) via --path; otherwise built-in --webui
$uiPath = $cfg['UiPath']
if (-not $uiPath) { $uiPath = $cfg['PublicPath'] }
if ($uiPath -and (Test-Path $uiPath)) {
  $uiNorm = (Resolve-Path $uiPath).Path
  [void]$a.Add("--path `"$uiNorm`"")
} elseif ($cfg['WebUI'] -notmatch '^(0|false|off|no)$') {
  [void]$a.Add('--webui')
}
if ($cfg['ExtraArgs']) { [void]$a.Add($cfg['ExtraArgs']) }

$joined = [string]::Join(' ', $a.ToArray())
$bat = @"
@echo off
setlocal
set ROOT=%~dp0..
set PATH=%ROOT%\bin;%PATH%
cd /d "%ROOT%\bin"
set CUDA_VISIBLE_DEVICES=$cuda
"$exe" $joined
"@
New-Item -ItemType Directory -Path (Split-Path $batPath) -Force | Out-Null
[IO.File]::WriteAllText($batPath, $bat.Replace("`n", "`r`n"), [Text.Encoding]::ASCII)
Write-Output $batPath
