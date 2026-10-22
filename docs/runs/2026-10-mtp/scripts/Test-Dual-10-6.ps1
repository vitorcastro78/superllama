$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-dual-10-6.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== dual-GPU tensor-split 10,6 ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-dual-10-6-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak"

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 3
}
function Get-Gpu { (nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits) -join ' | ' }

function Restore {
  Log "Restoring single-GPU from $bak"
  Stop-Stack
  if (Test-Path "$root\logs\service.err.log") { Move-Item "$root\logs\service.err.log" "$root\logs\service.err.dualfail.log" -Force -EA SilentlyContinue }
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  for ($i=0; $i -lt 40; $i++) {
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      if ($r.Content -match 'ok') { Log "restored health ok"; break }
    } catch { Log "restore wait $($_.Exception.Message)" }
    Start-Sleep 3
  }
  Start-Service KortexioOllamaTunnel -EA SilentlyContinue
}

Stop-Stack
if (Test-Path "$root\logs\service.err.log") { Move-Item "$root\logs\service.err.log" "$root\logs\service.err.before106.log" -Force -EA SilentlyContinue }

# Build env: MTP IQ2, ctx 16k, dual GPU, split 10,6, fit margin
$lines = @(
  "# dual 10,6 MTP test; backup $bak"
  "ModelsDir=D:\Models\gguf"
  "Host=127.0.0.1"
  "Port=11434"
  "DefaultModel=qwen3.6-35b-mtp"
  "Model=D:\Models\gguf\Qwen3.6-35B-A3B-UD-IQ2_M.gguf"
  "UseRouter=0"
  "GpuLayers=99"
  "CtxSize=16384"
  "NPredict=2048"
  "Parallel=1"
  "FlashAttn=on"
  "KvUnified=0"
  "ModelsMax=1"
  "Threads=8"
  "CacheTypeK=turbo4"
  "CacheTypeV=turbo3"
  "CachePrompt=1"
  "CacheReuse=512"
  "SlotPromptSimilarity=0.30"
  "SplitMode=layer"
  "TensorSplit=10,6"
  "MainGpu=0"
  "Fit=on"
  "Agent=0"
  "Tools=none"
  "Reasoning=auto"
  "ReasoningEffort=medium"
  "ReasoningBudget=4096"
  "ReasoningPreserve=0"
  "WebUI=1"
  "MediaPath=D:/"
  "CudaVisibleDevices=0,1"
  "Device=CUDA0,CUDA1"
  "Jinja=1"
  "RuntimeMode=Service"
  "ModelsAutoload=0"
  "Profile=mtp-dual-ts10-6-ctx16k"
  "ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0 --fit-target 1024"
)
Set-Content "$root\config\server.env" $lines -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Log "BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"

& "$root\tools\nssm.exe" start LlamaServer | Out-Null
$ok = $false
for ($i=0; $i -lt 60; $i++) {
  $st = (Get-Service LlamaServer).Status
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
    Log "status=$st health=$($r.Content) gpu=$(Get-Gpu)"
    if ($r.Content -match 'ok') { $ok = $true; break }
  } catch { Log "status=$st wait=$($_.Exception.Message)" }
  $tail = (Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | Out-String)
  if ($tail -match 'out of memory|CUDA error|GGML_ASSERT') {
    Log "OOM/CUDA fail"
    ($tail -split "`n") | Select-Object -Last 12 | ForEach-Object { Log "ERR $_" }
    break
  }
  if ($st -eq 'Stopped') {
    Get-Content "$root\logs\service.err.log" -Tail 25 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
    break
  }
  Start-Sleep 4
}

if (-not $ok) {
  Restore
  Log "=== FAIL - restored single GPU ==="
  exit 1
}

Start-Service KortexioOllamaTunnel -EA SilentlyContinue
$body = @{ model='qwen3.6-35b-mtp'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
$resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
$t = $resp.timings
Log ("bench tok/s={0:N1} draft={1}/{2}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n)
$p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
Log "n_ctx=$($p.default_generation_settings.n_ctx) FINAL gpu=$(Get-Gpu)"
Log "=== PASS dual 10,6 ==="
