$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\restore-prod-90k.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== restore prod 90k $(Get-Date -Format o) ==="

$root = "C:\LlamaServer"
$bak = "$root\config\backup-pre-mtp-test-20261021-101132\server.env"

Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
taskkill /F /IM llama-server.exe 2>&1 | Out-Null
Start-Sleep 2

Copy-Item $bak "$root\config\server.env" -Force
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Remove-Item "$root\logs\service.err.log","$root\logs\service.out.log" -Force -EA SilentlyContinue
Log "BAT=$(Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1)"

& "$root\tools\nssm.exe" start LlamaServer
Start-Sleep 8
for ($i=0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 8
    Log "health $($r.Content)"
    if ($r.Content -match 'ok') { break }
  } catch { Log "wait $($_.Exception.Message)" }
  if ((Get-Service LlamaServer).Status -eq 'Stopped') {
    Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
    break
  }
  Start-Sleep 4
}

Start-Service KortexioOllamaTunnel -EA SilentlyContinue
$p = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
Log "n_ctx=$($p.default_generation_settings.n_ctx)"
Log "model=$($p.model_path)"
Log "spec=$($p.default_generation_settings.params.'speculative.types')"

$body = @{ model='qwen3.6-35b'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
$resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
$t = $resp.timings
if ($t) { Log ("bench tok/s={0:N1}" -f $t.predicted_per_second) }

Log "Llama=$((Get-Service LlamaServer).Status) Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
Log "gpu=$(nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader)"
Log "=== done ==="
