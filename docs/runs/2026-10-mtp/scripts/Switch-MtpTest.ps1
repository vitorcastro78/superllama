$ErrorActionPreference = "Stop"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-test-switch.log"
function Log($m){ $t=Get-Date -Format o; Add-Content $log "$t $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== MTP test switch start ==="

$root = "C:\LlamaServer"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bak = Join-Path $root "config\backup-pre-mtp-test-$ts"
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak"

# Write test server.env based on prod, swap model + ExtraArgs for MTP
$envPath = "$root\config\server.env"
$lines = Get-Content $envPath
$out = foreach ($line in $lines) {
  if ($line -match '^Model=') { "Model=D:\Models\gguf\Qwen3.6-35B-A3B-UD-IQ2_M.gguf" }
  elseif ($line -match '^DefaultModel=') { "DefaultModel=qwen3.6-35b-mtp" }
  elseif ($line -match '^Profile=') { "Profile=super-qwen-90k-turbo4k-turbo3v-mtp-test" }
  elseif ($line -match '^ExtraArgs=') { "ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0" }
  elseif ($line -match '^# mmap') { "# MTP test: Unsloth UD-IQ2_M + draft-mtp n-max=2; revert via $bak" }
  else { $line }
}
# ensure ExtraArgs exists
if (-not ($out | Where-Object { $_ -match '^ExtraArgs=' })) {
  $out += "ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0"
}
Set-Content $envPath $out -Encoding UTF8
Log "server.env updated for MTP test"

# regenerate bat
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Log "run-server.bat regenerated"
Get-Content "$root\scripts\run-server.bat" | ForEach-Object { Log "BAT: $_" }

# restart service (stop tunnel dependent first)
Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
Start-Sleep 2
Restart-Service LlamaServer -Force
Log "LlamaServer restarted, waiting model load..."
Start-Sleep 5
Start-Service KortexioOllamaTunnel -EA SilentlyContinue

$ok=$false
for ($i=0; $i -lt 90; $i++) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
    Log "health $($r.StatusCode) $($r.Content)"
    if ($r.StatusCode -eq 200 -and $r.Content -match 'ok') { $ok=$true; break }
  } catch { Log "wait $($_.Exception.Message)" }
  Start-Sleep 5
}
if (-not $ok) { Log "FAIL: health not ok"; exit 1 }

$props = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
Log "model_path=$($props.model_path)"
Log "model_alias=$($props.model_alias)"
Log "speculative=$($props.default_generation_settings.params.'speculative.types')"

# quick completion benchmark
$body = @{
  model = "qwen3.6-35b-mtp"
  messages = @(@{ role="user"; content="Count from 1 to 30, numbers only, space separated." })
  max_tokens = 128
  temperature = 0.1
  stream = $false
} | ConvertTo-Json -Depth 5
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
  $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300
  $sw.Stop()
  $usage = $resp.usage
  $content = $resp.choices[0].message.content
  $tok = $usage.completion_tokens
  $tps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($tok / $sw.Elapsed.TotalSeconds, 2) } else { 0 }
  Log "bench completion_tokens=$tok elapsed_s=$([math]::Round($sw.Elapsed.TotalSeconds,2)) rough_tps=$tps"
  Log "bench preview=$($content.Substring(0,[Math]::Min(120,$content.Length)))"
  if ($resp.timings) { Log "timings=$($resp.timings | ConvertTo-Json -Compress)" }
} catch {
  Log "bench error: $_"
}

Log "=== done ==="
