$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-turbo2-ctx.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== aggressive TurboQuant (turbo2) ctx sweep ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-turbo2-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak (baseline turbo4/turbo3 @16k)"

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 3
}
function Get-Gpu { (nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits) -join ' | ' }

function Apply([int]$ctx, [string]$ctk, [string]$ctv) {
  $base = Get-Content "$bak\server.env"
  $out = foreach ($l in $base) {
    if ($l -match '^CtxSize=') { "CtxSize=$ctx" }
    elseif ($l -match '^CacheTypeK=') { "CacheTypeK=$ctk" }
    elseif ($l -match '^CacheTypeV=') { "CacheTypeV=$ctv" }
    elseif ($l -match '^Profile=') { "Profile=mtp-$ctk-$ctv-ctx$ctx" }
    elseif ($l -match '^CudaVisibleDevices=') { 'CudaVisibleDevices=0' }
    elseif ($l -match '^Device=') { 'Device=CUDA0' }
    elseif ($l -match '^SplitMode=') { 'SplitMode=none' }
    elseif ($l -match '^ExtraArgs=') { 'ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0' }
    elseif ($l -match '^NCpuMoe=|^TensorSplit=') { $null }
    else { $l }
  }
  Set-Content "$root\config\server.env" ($out | Where-Object { $_ -ne $null }) -Encoding ASCII
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
}

function Wait-Health([int]$maxSec=300) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer -EA SilentlyContinue).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      if ($r.Content -match '"status"\s*:\s*"ok"') { Log "  health=ok gpu=$(Get-Gpu)"; return $true }
      Log "  health=$($r.StatusCode) status=$st"
    } catch { Log "  wait status=$st $($_.Exception.Message)" }
    if ($st -eq 'Stopped') {
      Get-Content "$root\logs\service.err.log" -Tail 20 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    $tail = (Get-Content "$root\logs\service.err.log" -Tail 35 -EA SilentlyContinue | Out-String)
    if ($tail -match 'out of memory|CUDA error|GGML_ASSERT|failed to allocate|unsupported') {
      Log "  FAIL signature"
      ($tail -split "`n") | Select-Object -Last 10 | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    Start-Sleep 4
  }
  Log "  TIMEOUT"
  return $false
}

function Bench {
  $body = @{ model='qwen3.6-35b-mtp'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
  try {
    $resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
    $t = $resp.timings
    if ($t) { Log ("  bench tok/s={0:N1} draft={1}/{2}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n) }
    return $true
  } catch { Log "  bench FAIL: $_"; return $false }
}

function Restore-Baseline {
  Log "Restoring baseline $bak"
  Stop-Stack
  if (Test-Path "$root\logs\service.err.log") { Move-Item "$root\logs\service.err.log" "$root\logs\service.err.t2.log" -Force -EA SilentlyContinue }
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  if (Wait-Health 240) { Start-Service KortexioOllamaTunnel -EA SilentlyContinue; Log "Baseline OK" }
}

$lastGood = @{ ctx=16384; ctk='turbo4'; ctv='turbo3' }
# Try configs: turbo2/turbo2 first (most aggressive), then turbo2/turbo3
foreach ($kv in @(
  @{ctk='turbo2'; ctv='turbo2'},
  @{ctk='turbo2'; ctv='turbo3'}
)) {
  $pairOk = $false
  foreach ($ctx in @(16384, 24576, 32768, 40960, 49152, 65536, 81920, 92160)) {
    Log "--- TRY $($kv.ctk)/$($kv.ctv) ctx=$ctx ---"
    Stop-Stack
    if (Test-Path "$root\logs\service.err.log") { Move-Item "$root\logs\service.err.log" "$root\logs\service.err.prev.log" -Force -EA SilentlyContinue }
    Apply $ctx $kv.ctk $kv.ctv
    Log "  BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"
    & "$root\tools\nssm.exe" start LlamaServer | Out-Null
    Start-Sleep 5
    if (-not (Wait-Health 300)) { Log "  FAIL load"; break }
    if (-not (Bench)) { Log "  FAIL bench"; break }
    $p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
    Log "  PASS n_ctx=$($p.default_generation_settings.n_ctx)"
    $lastGood = @{ ctx=$ctx; ctk=$kv.ctk; ctv=$kv.ctv }
    $pairOk = $true
  }
  if ($pairOk -and $lastGood.ctx -ge 32768) {
    Log "Good enough with $($kv.ctk)/$($kv.ctv) @ $($lastGood.ctx) - stop pair loop"
    break
  }
}

Log "=== settle lastGood ctx=$($lastGood.ctx) $($lastGood.ctk)/$($lastGood.ctv) ==="
Stop-Stack
if (Test-Path "$root\logs\service.err.log") { Move-Item "$root\logs\service.err.log" "$root\logs\service.err.prev.log" -Force -EA SilentlyContinue }
Apply $lastGood.ctx $lastGood.ctk $lastGood.ctv
& "$root\tools\nssm.exe" start LlamaServer | Out-Null
if (Wait-Health 300) {
  Start-Service KortexioOllamaTunnel -EA SilentlyContinue
  Bench | Out-Null
  $p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
  Log "FINAL n_ctx=$($p.default_generation_settings.n_ctx) gpu=$(Get-Gpu)"
  Log "FINAL $((Select-String -Path "$root\config\server.env" -Pattern '^(Ctx|CacheType|Profile|Extra)=').Line -join ' || ')"
} else {
  Restore-Baseline
}
Log "=== done ==="
