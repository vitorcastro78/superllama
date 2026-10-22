$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-highctx-plan.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== MTP high-ctx plan (ordered) ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-highctx-plan-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak (baseline single-GPU 16k MTP)"

function Gpu-ErrLog {
  if (Test-Path "$root\logs\service.err.log") {
    Move-Item "$root\logs\service.err.log" "$root\logs\service.err.$([DateTime]::Now.ToString('HHmmss')).log" -Force -EA SilentlyContinue
  }
}

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 3
}

function Get-Gpu { (nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits) -join ' | ' }

function Write-Env {
  param(
    [int]$Ctx,
    [string]$CudaVis,
    [string]$Device,
    [string]$Split = 'none',
    [string]$TensorSplit = '',
    [string]$ExtraArgs,
    [string]$Profile,
    [string]$NCpuMoe = ''
  )
  $base = Get-Content "$bak\server.env"
  $map = @{}
  foreach ($line in $base) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k,$v = $line.Split('=',2); $map[$k.Trim()] = $v.Trim()
  }
  $map['CtxSize'] = "$Ctx"
  $map['CudaVisibleDevices'] = $CudaVis
  $map['Device'] = $Device
  $map['SplitMode'] = $Split
  $map['Fit'] = 'off'
  $map['MainGpu'] = '0'
  $map['Profile'] = $Profile
  $map['ExtraArgs'] = $ExtraArgs
  if ($TensorSplit) { $map['TensorSplit'] = $TensorSplit } else { $map.Remove('TensorSplit') }
  if ($NCpuMoe -ne '') { $map['NCpuMoe'] = $NCpuMoe } else { $map.Remove('NCpuMoe') }

  $order = @(
    'ModelsDir','Host','Port','DefaultModel','Model','UseRouter','GpuLayers','CtxSize','NPredict','Parallel',
    'FlashAttn','KvUnified','ModelsMax','Threads','CacheTypeK','CacheTypeV','CachePrompt','CacheReuse',
    'SlotPromptSimilarity','SplitMode','TensorSplit','MainGpu','Fit','NCpuMoe','Agent','Tools','Reasoning',
    'ReasoningEffort','ReasoningBudget','ReasoningPreserve','WebUI','MediaPath','CudaVisibleDevices','Device',
    'Jinja','RuntimeMode','ModelsAutoload','Profile','ExtraArgs'
  )
  $lines = @("# highctx plan; baseline backup $bak")
  foreach ($k in $order) { if ($map.ContainsKey($k)) { $lines += "$k=$($map[$k])" } }
  Set-Content "$root\config\server.env" $lines -Encoding ASCII

  # Patch Write-RunServerBat support for NCpuMoe if missing - inject via ExtraArgs instead if needed
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null

  # If NCpuMoe set but not in bat, append to ExtraArgs in bat via regenerating ExtraArgs
  if ($NCpuMoe -ne '') {
    $bat = Get-Content "$root\scripts\run-server.bat" -Raw
    if ($bat -notmatch 'n-cpu-moe') {
      $map['ExtraArgs'] = ($ExtraArgs + " --n-cpu-moe $NCpuMoe").Trim()
      $lines2 = @("# highctx plan; baseline backup $bak")
      foreach ($k in $order) { if ($map.ContainsKey($k)) { $lines2 += "$k=$($map[$k])" } }
      Set-Content "$root\config\server.env" $lines2 -Encoding ASCII
      & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
    }
  }
}

function Wait-Health([int]$maxSec=300) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer -EA SilentlyContinue).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      if ($r.Content -match '"status"\s*:\s*"ok"') {
        Log "  health=ok status=$st gpu=$(Get-Gpu)"
        return $true
      }
      Log "  health=$($r.StatusCode) status=$st"
    } catch { Log "  wait status=$st $($_.Exception.Message)" }
    if ($st -eq 'Stopped') {
      Get-Content "$root\logs\service.err.log" -Tail 20 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    $tail = (Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | Out-String)
    if ($tail -match 'out of memory|CUDA error|GGML_ASSERT|failed to allocate') {
      Log "  FAIL signature in err"
      ($tail -split "`n") | Select-Object -Last 10 | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    Start-Sleep 4
  }
  Log "  TIMEOUT"
  Get-Content "$root\logs\service.err.log" -Tail 20 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
  return $false
}

function Try-Config {
  param([string]$Name, [scriptblock]$Apply, [int]$WaitSec=300)
  Log "--- TRY: $Name ---"
  Stop-Stack
  Rotate-ErrLog
  & $Apply
  Log "  BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  Start-Sleep 5
  if (-not (Wait-Health $WaitSec)) { Log "  RESULT=FAIL $Name"; return $false }
  try {
    $body = @{ model='qwen3.6-35b-mtp'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
    $t = $resp.timings
    if ($t) { Log ("  bench tok/s={0:N1} draft={1}/{2}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n) }
    else { Log '  bench ok' }
  } catch { Log "  bench FAIL: $_"; return $false }
  $p = Invoke-RestMethod 'http://127.0.0.1:11434/props' -TimeoutSec 30
  Log "  n_ctx=$($p.default_generation_settings.n_ctx) RESULT=PASS $Name"
  return $true
}

function Restore-Baseline {
  Log "Restoring baseline from $bak"
  Stop-Stack
  Rotate-ErrLog
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  if (Wait-Health 240) {
    Start-Service KortexioOllamaTunnel -EA SilentlyContinue
    Log "Baseline restored OK"
  } else { Log "Baseline restore FAILED" }
}

# ========== STEP 1: draft on 3050 ==========
$step1 = Try-Config 'step1 draft-device CUDA1 @16k' {
  Write-Env -Ctx 16384 -CudaVis '0,1' -Device 'CUDA0' -Split 'none' `
    -ExtraArgs '--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0 --spec-draft-device CUDA1' `
    -Profile 'mtp-draft3050-ctx16k'
}

$draft3050Ok = $step1
if ($step1) {
  # try raise ctx with draft on 3050
  foreach ($ctx in @(24576, 32768, 49152, 65536)) {
    $ok = Try-Config "step1b draft3050 @ctx=$ctx" {
      Write-Env -Ctx $ctx -CudaVis '0,1' -Device 'CUDA0' -Split 'none' `
        -ExtraArgs '--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0 --spec-draft-device CUDA1' `
        -Profile "mtp-draft3050-ctx$ctx"
    }
    if (-not $ok) { break }
  }
} else {
  Log "Step1 failed - continue to step2 n-cpu-moe"
}

# ========== STEP 2: n-cpu-moe (if still need higher ctx / step1 failed) ==========
# Check current ctx
$curCtx = 0
try { $curCtx = [int](Invoke-RestMethod 'http://127.0.0.1:11434/props').default_generation_settings.n_ctx } catch {}
Log "Current live ctx=$curCtx"

$needStep2 = (-not $draft3050Ok) -or ($curCtx -lt 32768)
if ($needStep2) {
  # Use both GPUs only if draft3050 worked; else single GPU + cpu moe
  $cudaVis = if ($draft3050Ok) { '0,1' } else { '0' }
  $dev = if ($draft3050Ok) { 'CUDA0' } else { 'CUDA0' }
  $draftArg = if ($draft3050Ok) { ' --spec-draft-device CUDA1' } else { '' }

  foreach ($ncmoe in @(20, 30, 40)) {
    $passed = $false
    foreach ($ctx in @(32768, 49152, 65536, 81920, 92160)) {
      $extra = "--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0$draftArg --n-cpu-moe $ncmoe"
      $ok = Try-Config "step2 n-cpu-moe=$ncmoe ctx=$ctx" {
        Write-Env -Ctx $ctx -CudaVis $cudaVis -Device $dev -Split 'none' -NCpuMoe "$ncmoe" `
          -ExtraArgs $extra -Profile "mtp-ncmoe$ncmoe-ctx$ctx"
      }
      if ($ok) { $passed = $true; $curCtx = $ctx }
      else { break }
    }
    if ($passed -and $curCtx -ge 65536) { break }
  }
}

# ========== STEP 3: fine sweep 20-28k if still below 32k ==========
try { $curCtx = [int](Invoke-RestMethod 'http://127.0.0.1:11434/props').default_generation_settings.n_ctx } catch {}
if ($curCtx -lt 32768 -and $curCtx -ge 16384) {
  Log "Step3 fine sweep above $curCtx"
  foreach ($ctx in @(20480, 24576, 28672, 30720)) {
    if ($ctx -le $curCtx) { continue }
    # reuse whatever env pattern is currently in bak+live: read live ExtraArgs
    $liveExtra = (Select-String -Path "$root\config\server.env" -Pattern '^ExtraArgs=').Line -replace '^ExtraArgs=',''
    $liveCuda = (Select-String -Path "$root\config\server.env" -Pattern '^CudaVisibleDevices=').Line -replace '^CudaVisibleDevices=',''
    if (-not $liveCuda) { $liveCuda = '0' }
    $ok = Try-Config "step3 fine ctx=$ctx" {
      Write-Env -Ctx $ctx -CudaVis $liveCuda -Device 'CUDA0' -Split 'none' `
        -ExtraArgs $liveExtra -Profile "mtp-fine-ctx$ctx"
    }
    if (-not $ok) { break }
  }
}

# Ensure tunnel up on final config
Start-Service KortexioOllamaTunnel -EA SilentlyContinue
try {
  $p = Invoke-RestMethod 'http://127.0.0.1:11434/props' -TimeoutSec 30
  Log "FINAL n_ctx=$($p.default_generation_settings.n_ctx) model=$([IO.Path]::GetFileName($p.model_path)) gpu=$(Get-Gpu)"
  Log "FINAL env: $((Select-String -Path "$root\config\server.env" -Pattern '^(Ctx|Cuda|Device|Split|Extra|Profile)=').Line -join ' || ')"
} catch {
  Log "FINAL unhealthy - restoring baseline"
  Restore-Baseline
}
Log "=== plan done ==="
