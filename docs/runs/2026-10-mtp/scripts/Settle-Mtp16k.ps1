$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-settle-16k.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== settle 16k $(Get-Date -Format o) ==="

# kill sweep if running
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Sweep-MtpCtx' } | ForEach-Object {
  Log "Killing sweep PID $($_.ProcessId)"
  Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
}

$root = "C:\LlamaServer"
Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2

$lines = Get-Content "$root\config\server.env"
$out = foreach ($line in $lines) {
  if ($line -match '^CtxSize=') { 'CtxSize=16384' }
  elseif ($line -match '^Profile=') { 'Profile=mtp-ctx16k-turbo4-turbo3' }
  else { $line }
}
Set-Content "$root\config\server.env" $out -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Log "BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"

& "$root\tools\nssm.exe" start LlamaServer | Out-Null
for ($i=0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
    Log "health $($r.Content)"
    if ($r.Content -match 'ok') { break }
  } catch { Log "wait $($_.Exception.Message)" }
  Start-Sleep 3
}
Start-Service KortexioOllamaTunnel -EA SilentlyContinue
$p = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
Log "FINAL n_ctx=$($p.default_generation_settings.n_ctx)"
Log "FINAL model=$($p.model_path)"
Log "GPU: $(nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader)"
Log "svc Llama=$((Get-Service LlamaServer).Status) Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
Log "=== done ==="
