$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-dualgpu-ctx.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== dual-GPU MTP ctx sweep ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-dualgpu-mtp-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak"

$lastGood = 16384
$candidates = @(16384, 32768, 49152, 65536, 81920, 92160)

function Get-GpuMem {
  return (nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits 2>$null) -join ' | '
}

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 3
}

function Apply-Config([int]$ctx) {
  $lines = Get-Content "$bak\server.env"
  $out = foreach ($line in $lines) {
    if ($line -match '^CtxSize=') { "CtxSize=$ctx" }
    elseif ($line -match '^SplitMode=') { 'SplitMode=layer' }
    elseif ($line -match '^CudaVisibleDevices=') { 'CudaVisibleDevices=0,1' }
    elseif ($line -match '^Device=') { 'Device=CUDA0,CUDA1' }
    elseif ($line -match '^Fit=') { 'Fit=off' }
    elseif ($line -match '^MainGpu=') { 'MainGpu=0' }
    elseif ($line -match '^Profile=') { "Profile=mtp-dualgpu-ctx$ctx" }
    elseif ($line -match '^TensorSplit=') { 'TensorSplit=12,8' }
    else { $line }
  }
  if (-not ($out | Where-Object { $_ -match '^TensorSplit=' })) {
    $out = @($out) + 'TensorSplit=12,8'
  }
  Set-Content "$root\config\server.env" $out -Encoding ASCII
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
}

function Wait-Health([int]$maxSec=300) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer -EA SilentlyContinue).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      if ($r.Content -match '"status"\s*:\s*"ok"') {
        Log "  health=ok status=$st gpu=$(Get-GpuMem)"
        return $true
      }
      Log "  health=$($r.StatusCode) $($r.Content.Substring(0,[Math]::Min(80,$r.Content.Length))) status=$st"
    } catch {
      Log "  wait status=$st $($_.Exception.Message)"
    }
    if ($st -eq 'Stopped') {
      Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    $tail = (Get-Content "$root\logs\service.err.log" -Tail 50 -EA SilentlyContinue | Out-String)
    if ($tail -match 'out of memory|failed to allocate|CUDA error|GGML_ASSERT') {
      Log "  DETECTED OOM/CUDA fail"
      ($tail -split "`n") | Select-Object -Last 12 | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    # stuck: StartPending/Paused with near-empty GPU0 for >90s after start
    Start-Sleep 5
  }
  Log "  TIMEOUT"
  Get-Content "$root\logs\service.err.log" -Tail 25 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
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
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/chat/completions" -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 180
    $t = $resp.timings
    if ($t) {
      Log ("  bench tok/s={0:N1} draft={1}/{2} pp={3:N1}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n, $t.prompt_per_second)
    } else { Log "  bench ok" }
    return $true
  } catch {
    Log "  bench FAIL: $_"
    return $false
  }
}

foreach ($ctx in $candidates) {
  Log "--- dual-GPU try ctx=$ctx ---"
  Stop-Stack
  Apply-Config $ctx
  Log "  BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  Start-Sleep 5
  if (Wait-Health 300) {
    $props = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
    Log "  n_ctx=$($props.default_generation_settings.n_ctx)"
    if (Quick-Bench) {
      $lastGood = $ctx
      Log "  PASS lastGood=$lastGood"
    } else {
      Log "  bench fail - stop"
      break
    }
  } else {
    Log "  FAIL at ctx=$ctx"
    break
  }
}

Log "=== settle lastGood=$lastGood ==="
Stop-Stack
Apply-Config $lastGood
& "$root\tools\nssm.exe" start LlamaServer | Out-Null
if (Wait-Health 300) {
  Start-Service KortexioOllamaTunnel -EA SilentlyContinue
  $props = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
  Log "FINAL n_ctx=$($props.default_generation_settings.n_ctx) gpu=$(Get-GpuMem)"
  Log "FINAL Device/Split: $((Select-String -Path "$root\config\server.env" -Pattern '^(Device|Split|Tensor|Cuda|Ctx)=').Line -join '; ')"
} else {
  Log "settle failed - restoring single-GPU 16k from backup"
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  Wait-Health 240 | Out-Null
  Start-Service KortexioOllamaTunnel -EA SilentlyContinue
}
Log "=== done ==="
