$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\restore-prod-90k-clean.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Set-Content $log "=== clean restore $(Get-Date -Format o) ===" -Encoding UTF8

$root = "C:\LlamaServer"
Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
taskkill /F /IM llama-server.exe 2>&1 | ForEach-Object { Log "$_" }
Start-Sleep 3
$left = @(Get-Process llama-server -EA SilentlyContinue).Count
Log "llama-server left=$left"

Copy-Item "$root\config\backup-pre-mtp-test-20261021-101132\server.env" "$root\config\server.env" -Force
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Remove-Item "$root\logs\service.err.log","$root\logs\service.out.log" -Force -EA SilentlyContinue
Log "BAT=$(Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1)"
Log "Model=$((Select-String -Path "$root\config\server.env" -Pattern '^Model=').Line)"
Log "Ctx=$((Select-String -Path "$root\config\server.env" -Pattern '^CtxSize=').Line)"
Log "Extra=$((Select-String -Path "$root\config\server.env" -Pattern '^ExtraArgs=').Line)"

& "$root\tools\nssm.exe" start LlamaServer
Log "started, waiting load..."
Start-Sleep 20

for ($i=0; $i -lt 100; $i++) {
  $st = (Get-Service LlamaServer).Status
  $n = @(Get-Process llama-server -EA SilentlyContinue).Count
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 8
    Log "[$i] status=$st procs=$n health=$($r.Content)"
    if ($r.Content -match 'ok') {
      Start-Service KortexioOllamaTunnel -EA SilentlyContinue
      $p = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
      Log "n_ctx=$($p.default_generation_settings.n_ctx)"
      Log "model=$([IO.Path]::GetFileName($p.model_path))"
      $body = @{ model='qwen3.6-35b'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
      $resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
      $t = $resp.timings
      if ($t) { Log ("bench tok/s={0:N1}" -f $t.predicted_per_second) }
      Log "Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
      Log "gpu=$(nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader)"
      Log "=== OK ==="
      exit 0
    }
  } catch {
    Log "[$i] status=$st procs=$n wait=$($_.Exception.Message)"
  }
  if ($st -eq 'Stopped' -and $i -gt 3) {
    Get-Content "$root\logs\service.err.log" -Tail 50 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
    Log "=== FAIL stopped ==="
    exit 1
  }
  Start-Sleep 4
}
Get-Content "$root\logs\service.err.log" -Tail 50 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
Log "=== FAIL timeout ==="
exit 1
