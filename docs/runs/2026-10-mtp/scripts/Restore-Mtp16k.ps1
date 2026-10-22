$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-restore-16k.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== restore single-GPU 16k $(Get-Date -Format o) ==="

$root = "C:\LlamaServer"
$bak = Get-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" -EA SilentlyContinue
if (-not (Test-Path "$bak\server.env")) {
  $bak = (Get-ChildItem "$root\config" -Directory -Filter "backup-pre-dualgpu-mtp-*" | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
Log "bak=$bak"

Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2

Copy-Item "$bak\server.env" "$root\config\server.env" -Force
# ensure single GPU 16k
$lines = Get-Content "$root\config\server.env"
$out = foreach ($l in $lines) {
  if ($l -match '^CtxSize=') { 'CtxSize=16384' }
  elseif ($l -match '^CudaVisibleDevices=') { 'CudaVisibleDevices=0' }
  elseif ($l -match '^Device=') { 'Device=CUDA0' }
  elseif ($l -match '^SplitMode=') { 'SplitMode=none' }
  elseif ($l -match '^TensorSplit=') { $null }
  elseif ($l -match '^Profile=') { 'Profile=mtp-ctx16k-turbo4-turbo3' }
  else { $l }
}
$out = $out | Where-Object { $_ -ne $null }
Set-Content "$root\config\server.env" $out -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
# rotate err log so old OOM doesn't confuse
if (Test-Path "$root\logs\service.err.log") {
  Move-Item "$root\logs\service.err.log" "$root\logs\service.err.pre-dualgpu.log" -Force
}

& "$root\tools\nssm.exe" start LlamaServer | Out-Null
for ($i=0; $i -lt 40; $i++) {
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
    Log "health $($r.Content)"
    if ($r.Content -match 'ok') { break }
  } catch { Log "wait $($_.Exception.Message)" }
  Start-Sleep 3
}
Start-Service KortexioOllamaTunnel -EA SilentlyContinue
$p = Invoke-RestMethod "http://127.0.0.1:11434/props" -TimeoutSec 30
Log "n_ctx=$($p.default_generation_settings.n_ctx) model=$([IO.Path]::GetFileName($p.model_path))"
Log "gpu=$(nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader)"
Log "Llama=$((Get-Service LlamaServer).Status) Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
Log "env: $((Select-String -Path $root\config\server.env -Pattern '^(Ctx|Cuda|Device|Split|Extra)=').Line -join ' | ')"
Log "=== done ==="
