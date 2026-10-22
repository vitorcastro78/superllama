$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-revert.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== revert $(Get-Date -Format o) ==="

# kill stuck llama-server
Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "C:\LlamaServer\tools\nssm.exe" stop LlamaServer confirm 2>$null
Start-Sleep 2
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2

$bak = Get-Content "C:\LlamaServer\config\LAST_MTP_TEST_BACKUP.txt" -EA SilentlyContinue
if (-not $bak -or -not (Test-Path "$bak\server.env")) {
  $bak = (Get-ChildItem "C:\LlamaServer\config" -Directory -Filter "backup-pre-mtp-test-*" | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
Log "Using backup=$bak"
Copy-Item "$bak\server.env" "C:\LlamaServer\config\server.env" -Force
if (Test-Path "$bak\run-server.bat") { Copy-Item "$bak\run-server.bat" "C:\LlamaServer\scripts\run-server.bat" -Force }

# regenerate bat from restored env to be safe
& powershell -NoProfile -ExecutionPolicy Bypass -File "C:\LlamaServer\scripts\Write-RunServerBat.ps1" -Root "C:\LlamaServer"
Log "Restored env Model line:"
(Get-Content "C:\LlamaServer\config\server.env" | Select-String '^Model=|^ExtraArgs=|^Profile=') | ForEach-Object { Log $_.Line }
Log "BAT:"
Get-Content "C:\LlamaServer\scripts\run-server.bat" | ForEach-Object { Log $_ }

& "C:\LlamaServer\tools\nssm.exe" start LlamaServer
Start-Sleep 8
for ($i=0; $i -lt 60; $i++) {
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
    Log "health $($r.StatusCode) $($r.Content)"
    if ($r.Content -match 'ok') { break }
  } catch { Log "wait $_" }
  Start-Sleep 5
}
Start-Service KortexioOllamaTunnel -EA SilentlyContinue
Start-Sleep 2
Log "LlamaServer=$((Get-Service LlamaServer).Status) Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
try {
  $p = Invoke-RestMethod "http://127.0.0.1:11434/props"
  Log "model=$($p.model_path)"
  Log "spec=$($p.default_generation_settings.params.'speculative.types')"
} catch { Log "props err $_" }
Log "=== done ==="
