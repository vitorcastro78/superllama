$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-ctx-sweep.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== MTP ctx sweep start ==="

$root = "C:\LlamaServer"
$candidates = @(16384, 32768, 49152, 65536, 81920, 92160)
$lastGood = 8192

function Get-GpuMem {
  $csv = nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits 2>$null
  return ($csv -join ' | ')
}

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 3
}

function Apply-Ctx([int]$ctx) {
  $lines = Get-Content "$root\config\server.env"
  $out = foreach ($line in $lines) {
    if ($line -match '^CtxSize=') { "CtxSize=$ctx" }
    elseif ($line -match '^Profile=') { "Profile=mtp-test-ctx$ctx-turbo4-turbo3" }
    else { $line }
  }
  Set-Content "$root\config\server.env" $out -Encoding ASCII
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
}

function Wait-Health([int]$maxSec=420) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer -EA SilentlyContinue).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      if ($r.Content -match '"status"\s*:\s*"ok"') {
        Log "  health=ok status=$st gpu=$(Get-GpuMem)"
        return $true
      }
      Log "  health=$($r.StatusCode) $($r.Content) status=$st"
    } catch {
      Log "  wait status=$st $($_.Exception.Message)"
    }
    if ($st -eq 'Stopped') {
      Get-Content "$root\logs\service.err.log" -Tail 25 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    # OOM / crash signatures in err log
    $tail = Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | Out-String
    if ($tail -match 'out of memory|failed to allocate|CUDA error|GGML_ASSERT|fatal') {
      Log "  DETECTED failure in err log"
      $tail -split "`n" | Select-Object -Last 15 | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    Start-Sleep 5
  }
  Log "  TIMEOUT"
  Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
  return $false
}

function Quick-Bench {
  $body = @{
    model = "qwen3.6-35b-mtp"
    messages = @(@{ role="user"; content="Say only: OK" })
    max_tokens = 16
    temperature = 0
    stream = $false
  } | ConvertTo-Json -Depth 5
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/chat/completions" -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 180
    $sw.Stop()
    $t = $resp.timings
    if ($t) {
      Log ("  bench predicted_tok/s={0:N1} draft_n={1} accepted={2} prompt_tok/s={3:N1}" -f $t.predicted_per_second, $t.draft_n, $t.draft_n_accepted, $t.prompt_per_second)
    } else {
      Log "  bench ok sec=$([math]::Round($sw.Elapsed.TotalSeconds,2))"
    }
    return $true
  } catch {
    Log "  bench FAIL: $_"
    return $false
  }
}

foreach ($ctx in $candidates) {
  Log "--- try CtxSize=$ctx ---"
  Stop-Stack
  Apply-Ctx $ctx
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  Start-Sleep 4
  if (Wait-Health 420) {
    $props = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
    Log "  n_ctx=$($props.default_generation_settings.n_ctx) model=$([IO.Path]::GetFileName($props.model_path))"
    if (Quick-Bench) {
      $lastGood = $ctx
      Log "  PASS lastGood=$lastGood"
    } else {
      Log "  LOAD ok but bench failed - treat as FAIL"
      break
    }
  } else {
    Log "  FAIL at ctx=$ctx - stopping sweep"
    break
  }
}

Log "=== settling on lastGood=$lastGood ==="
Stop-Stack
Apply-Ctx $lastGood
& "$root\tools\nssm.exe" start LlamaServer | Out-Null
if (Wait-Health 420) {
  Start-Service KortexioOllamaTunnel -EA SilentlyContinue
  $props = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
  Log "FINAL ctx=$($props.default_generation_settings.n_ctx) gpu=$(Get-GpuMem)"
  Log "FINAL model=$($props.model_path)"
  Log "server.env CtxSize=$((Select-String -Path "$root\config\server.env" -Pattern '^CtxSize=').Line)"
} else {
  Log "FATAL: could not settle on lastGood=$lastGood"
}
Log "=== sweep done ==="
