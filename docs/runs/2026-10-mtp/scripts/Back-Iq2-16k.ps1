$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-back-iq2-16k.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== back to IQ2 MTP 16k $(Get-Date -Format o) ==="

$root = "C:\LlamaServer"
$bak = "C:\LlamaServer\config\backup-pre-q4kxl-20261021-105816"
if (-not (Test-Path "$bak\server.env")) {
  $bak = Get-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" -EA SilentlyContinue
}
Log "bak=$bak"

Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2

Copy-Item "$bak\server.env" "$root\config\server.env" -Force
$lines = Get-Content "$root\config\server.env"
$out = foreach ($l in $lines) {
  if ($l -match '^Model=') { 'Model=D:\Models\gguf\Qwen3.6-35B-A3B-UD-IQ2_M.gguf' }
  elseif ($l -match '^DefaultModel=') { 'DefaultModel=qwen3.6-35b-mtp' }
  elseif ($l -match '^CtxSize=') { 'CtxSize=16384' }
  elseif ($l -match '^CudaVisibleDevices=') { 'CudaVisibleDevices=0' }
  elseif ($l -match '^Device=') { 'Device=CUDA0' }
  elseif ($l -match '^SplitMode=') { 'SplitMode=none' }
  elseif ($l -match '^NCpuMoe=') { $null }
  elseif ($l -match '^TensorSplit=') { $null }
  elseif ($l -match '^Profile=') { 'Profile=mtp-ctx16k-turbo4-turbo3' }
  elseif ($l -match '^ExtraArgs=') { 'ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0' }
  else { $l }
}
Set-Content "$root\config\server.env" ($out | Where-Object { $_ -ne $null }) -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
if (Test-Path "$root\logs\service.err.log") { Move-Item "$root\logs\service.err.log" "$root\logs\service.err.prev.log" -Force -EA SilentlyContinue }

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

$body = @{ model='qwen3.6-35b-mtp'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
$resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
$t = $resp.timings
Log ("bench tok/s={0:N1} draft={1}/{2}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n)
$p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
Log "n_ctx=$($p.default_generation_settings.n_ctx) model=$([IO.Path]::GetFileName($p.model_path))"
Log "Llama=$((Get-Service LlamaServer).Status) Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
Log "=== done ==="
