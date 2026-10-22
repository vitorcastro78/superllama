$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-fix-turbo2.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== fix restore $(Get-Date -Format o) ==="
$root = "C:\LlamaServer"
$bak = "C:\LlamaServer\config\backup-pre-turbo2-20261021-111621"

Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2

# clear poisoned err log
Get-ChildItem "$root\logs\service.err*.log" -EA SilentlyContinue | ForEach-Object {
  Move-Item $_.FullName ($_.FullName + ".old") -Force -EA SilentlyContinue
}

Copy-Item "$bak\server.env" "$root\config\server.env" -Force
# enforce known-good
$lines = Get-Content "$root\config\server.env"
$out = foreach ($l in $lines) {
  if ($l -match '^CtxSize=') { 'CtxSize=16384' }
  elseif ($l -match '^CacheTypeK=') { 'CacheTypeK=turbo4' }
  elseif ($l -match '^CacheTypeV=') { 'CacheTypeV=turbo3' }
  elseif ($l -match '^CudaVisibleDevices=') { 'CudaVisibleDevices=0' }
  elseif ($l -match '^Device=') { 'Device=CUDA0' }
  elseif ($l -match '^SplitMode=') { 'SplitMode=none' }
  elseif ($l -match '^Profile=') { 'Profile=mtp-ctx16k-turbo4-turbo3' }
  elseif ($l -match '^ExtraArgs=') { 'ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0' }
  elseif ($l -match '^NCpuMoe=|^TensorSplit=') { $null }
  else { $l }
}
Set-Content "$root\config\server.env" ($out | Where-Object { $_ -ne $null }) -Encoding ASCII
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Log "BAT: $((Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1))"

& "$root\tools\nssm.exe" start LlamaServer | Out-Null
for ($i=0; $i -lt 50; $i++) {
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 5
    Log "health $($r.Content)"
    if ($r.Content -match 'ok') { break }
  } catch { Log "wait $($_.Exception.Message)" }
  $st = (Get-Service LlamaServer).Status
  if ($st -eq 'Stopped') {
    Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
    break
  }
  Start-Sleep 3
}
Start-Service KortexioOllamaTunnel -EA SilentlyContinue
$p = Invoke-RestMethod 'http://127.0.0.1:11434/props' -TimeoutSec 30
Log "n_ctx=$($p.default_generation_settings.n_ctx) model=$([IO.Path]::GetFileName($p.model_path))"
Log "env: $((Select-String -Path "$root\config\server.env" -Pattern '^(Ctx|CacheType|Profile)=').Line -join ' | ')"
Log "Llama=$((Get-Service LlamaServer).Status) Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
Log "=== done ==="
