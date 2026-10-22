$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-test-8k.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== MTP 8k test start ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-mtp-8k-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak"

# Build test env from current (prod) with MTP + ctx 8192
$map = @{}
Get-Content "$bak\server.env" | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $k,$v = $_.Split('=',2)
  $map[$k.Trim()] = $v.Trim()
}
$map['Model'] = 'D:\Models\gguf\Qwen3.6-35B-A3B-UD-IQ2_M.gguf'
$map['DefaultModel'] = 'qwen3.6-35b-mtp'
$map['CtxSize'] = '8192'
$map['Profile'] = 'mtp-test-8k-turbo4-turbo3'
$map['ExtraArgs'] = '--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0'
# Keep turbo KV; optionally lower npredict for quicker tests
$map['NPredict'] = '2048'

$ordered = @(
  'ModelsDir','Host','Port','DefaultModel','Model','UseRouter','GpuLayers','CtxSize','NPredict','Parallel',
  'FlashAttn','KvUnified','ModelsMax','Threads','CacheTypeK','CacheTypeV','CachePrompt','CacheReuse',
  'SlotPromptSimilarity','SplitMode','MainGpu','Fit','Agent','Tools','Reasoning','ReasoningEffort',
  'ReasoningBudget','ReasoningPreserve','WebUI','MediaPath','CudaVisibleDevices','Device','Jinja',
  'RuntimeMode','ModelsAutoload','Profile','ExtraArgs'
)
$lines = @('# MTP test ctx=8192 Unsloth UD-IQ2_M + draft-mtp; backup=' + $bak)
foreach ($k in $ordered) {
  if ($map.ContainsKey($k)) { $lines += "$k=$($map[$k])" }
}
Set-Content "$root\config\server.env" $lines -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Log "BAT: $(Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1)"

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 2
}

function Start-Stack {
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  Start-Sleep 5
}

function Wait-Health([int]$maxSec=300) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
      Log "status=$st health=$($r.StatusCode) $($r.Content)"
      if ($r.Content -match '"status"\s*:\s*"ok"') { return $true }
    } catch {
      Log "status=$st wait=$($_.Exception.Message)"
    }
    # detect crash loop
    if ($st -eq 'Stopped') {
      Log "service stopped - check err log"
      Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
      return $false
    }
    Start-Sleep 5
  }
  return $false
}

function Restore-Prod {
  Log "Restoring production from $bak"
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
  Stop-Stack
  Start-Stack
  if (Wait-Health 240) {
    Start-Service KortexioOllamaTunnel -EA SilentlyContinue
    Log "PROD restored OK"
  } else {
    Log "PROD restore health FAILED"
  }
}

Stop-Stack
Start-Stack
$ok = Wait-Health 360
if (-not $ok) {
  Log "MTP load FAILED - reverting"
  Restore-Prod
  exit 1
}

Start-Service KortexioOllamaTunnel -EA SilentlyContinue
$props = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
Log "model=$($props.model_path)"
Log "n_ctx=$($props.default_generation_settings.n_ctx)"
Log "spec=$($props.default_generation_settings.params.'speculative.types')"

$body = @{
  model = "qwen3.6-35b-mtp"
  messages = @(@{ role="user"; content="Count from 1 to 40, numbers only, space separated. No other text." })
  max_tokens = 160
  temperature = 0.1
  stream = $false
} | ConvertTo-Json -Depth 5

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
  $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/chat/completions" -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 300
  $sw.Stop()
  $tok = [int]$resp.usage.completion_tokens
  $sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
  $tps = if ($sec -gt 0) { [math]::Round($tok / $sec, 2) } else { 0 }
  $preview = $resp.choices[0].message.content
  if ($preview.Length -gt 150) { $preview = $preview.Substring(0,150) }
  Log "bench tokens=$tok sec=$sec rough_tps=$tps"
  Log "bench preview=$preview"
  if ($resp.timings) { Log ("timings=" + ($resp.timings | ConvertTo-Json -Compress)) }
} catch {
  Log "bench error: $_"
  Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
}

Log "=== MTP 8k test done (left running; backup=$bak) ==="
