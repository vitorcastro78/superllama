$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-q4kxl-test.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== Q4_K_XL MTP + n-cpu-moe test ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-q4kxl-$ts"
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
function Rotate-Err {
  if (Test-Path "$root\logs\service.err.log") {
    Move-Item "$root\logs\service.err.log" "$root\logs\service.err.$ts.log" -Force -EA SilentlyContinue
  }
}

function Apply([int]$ctx, [int]$ncmoe) {
  $lines = @(
    "# Q4_K_XL MTP test; backup $bak"
    "ModelsDir=D:\Models\gguf"
    "Host=127.0.0.1"
    "Port=11434"
    "DefaultModel=qwen3.6-35b-q4-mtp"
    "Model=D:\Models\gguf\Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
    "UseRouter=0"
    "GpuLayers=99"
    "CtxSize=$ctx"
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
    "SplitMode=none"
    "MainGpu=0"
    "Fit=off"
    "Agent=0"
    "Tools=none"
    "Reasoning=auto"
    "ReasoningEffort=medium"
    "ReasoningBudget=4096"
    "ReasoningPreserve=0"
    "WebUI=1"
    "MediaPath=D:/"
    "CudaVisibleDevices=0"
    "Device=CUDA0"
    "Jinja=1"
    "RuntimeMode=Service"
    "ModelsAutoload=0"
    "Profile=mtp-q4kxl-ncmoe$ncmoe-ctx$ctx"
    "ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0 --n-cpu-moe $ncmoe"
  )
  Set-Content "$root\config\server.env" $lines -Encoding ASCII
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
}

function Wait-Health([int]$maxSec=420) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer -EA SilentlyContinue).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      if ($r.Content -match '"status"\s*:\s*"ok"') { Log "  health=ok gpu=$(Get-Gpu)"; return $true }
      Log "  health=$($r.StatusCode) status=$st"
    } catch { Log "  wait status=$st $($_.Exception.Message)" }
    if ($st -eq 'Stopped') {
      Get-Content "$root\logs\service.err.log" -Tail 25 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    $tail = (Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | Out-String)
    if ($tail -match 'out of memory|CUDA error|GGML_ASSERT|failed to allocate') {
      Log "  FAIL CUDA/OOM"
      ($tail -split "`n") | Select-Object -Last 12 | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    Start-Sleep 5
  }
  Log "  TIMEOUT"; Get-Content "$root\logs\service.err.log" -Tail 20 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }
  return $false
}

function Bench {
  $body = @{ model='qwen3.6-35b-q4-mtp'; messages=@(@{role='user';content='Explain in 2 short sentences what a binary tree is.'}); max_tokens=80; temperature=0.2; stream=$false } | ConvertTo-Json -Depth 5
  try {
    $resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 300
    $t = $resp.timings
    $txt = $resp.choices[0].message.content
    if (-not $txt) { $txt = $resp.choices[0].message.reasoning_content }
    if ($txt -and $txt.Length -gt 160) { $txt = $txt.Substring(0,160) }
    if ($t) { Log ("  bench tok/s={0:N1} draft={1}/{2} pp={3:N1}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n, $t.prompt_per_second) }
    Log "  preview=$txt"
    return $true
  } catch { Log "  bench FAIL: $_"; return $false }
}

function Restore {
  Log "Restoring previous from $bak"
  Stop-Stack; Rotate-Err
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  if (Wait-Health 300) { Start-Service KortexioOllamaTunnel -EA SilentlyContinue; Log "Restored OK" }
  else { Log "Restore FAILED" }
}

$lastGood = $null
# Start with ncmoe=30 (more offload for larger quant), ctx 16384 then climb
foreach ($ncmoe in @(30, 40, 20)) {
  $okAny = $false
  foreach ($ctx in @(16384, 32768, 49152, 65536)) {
    Log "--- TRY Q4_K_XL ncmoe=$ncmoe ctx=$ctx ---"
    Stop-Stack; Rotate-Err
    Apply $ctx $ncmoe
    Log "  BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"
    & "$root\tools\nssm.exe" start LlamaServer | Out-Null
    Start-Sleep 6
    if (-not (Wait-Health 480)) { Log "  FAIL load"; break }
    if (-not (Bench)) { Log "  FAIL bench"; break }
    $p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
    Log "  PASS n_ctx=$($p.default_generation_settings.n_ctx)"
    $lastGood = @{ ctx=$ctx; ncmoe=$ncmoe }
    $okAny = $true
  }
  if ($okAny -and $lastGood.ctx -ge 32768) { break }
}

if ($null -eq $lastGood) {
  Log "No Q4 config worked - restore"
  Restore
} else {
  Log "Settling on ctx=$($lastGood.ctx) ncmoe=$($lastGood.ncmoe)"
  Stop-Stack; Rotate-Err
  Apply $lastGood.ctx $lastGood.ncmoe
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  if (Wait-Health 480) {
    Start-Service KortexioOllamaTunnel -EA SilentlyContinue
    Bench | Out-Null
    Log "FINAL gpu=$(Get-Gpu)"
    Log "FINAL $((Select-String -Path "$root\config\server.env" -Pattern '^(Model|Ctx|Extra|Profile)=').Line -join ' || ')"
  } else {
    Restore
  }
}
Log "=== done ==="
