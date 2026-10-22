$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-hard-restore.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== hard restore $(Get-Date -Format o) ==="

# kill stuck fix scripts
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Fix-AfterTurbo2|Sweep-Turbo2' } | ForEach-Object {
  Log "kill $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue
}

$root = "C:\LlamaServer"
Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
& "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 3
Get-Process llama-server,nssm -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2
# nssm again after kill
try { & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null } catch {}

# wipe logs
Remove-Item "$root\logs\service.err.log","$root\logs\service.out.log" -Force -EA SilentlyContinue

# write clean env
@"
ModelsDir=D:\Models\gguf
Host=127.0.0.1
Port=11434
DefaultModel=qwen3.6-35b-mtp
Model=D:\Models\gguf\Qwen3.6-35B-A3B-UD-IQ2_M.gguf
UseRouter=0
GpuLayers=99
CtxSize=16384
NPredict=2048
Parallel=1
FlashAttn=on
KvUnified=0
ModelsMax=1
Threads=8
CacheTypeK=turbo4
CacheTypeV=turbo3
CachePrompt=1
CacheReuse=512
SlotPromptSimilarity=0.30
SplitMode=none
MainGpu=0
Fit=off
Agent=0
Tools=none
Reasoning=auto
ReasoningEffort=medium
ReasoningBudget=4096
ReasoningPreserve=0
WebUI=1
MediaPath=D:/
CudaVisibleDevices=0
Device=CUDA0
Jinja=1
RuntimeMode=Service
ModelsAutoload=0
Profile=mtp-ctx16k-turbo4-turbo3
ExtraArgs=--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0
"@ | Set-Content "$root\config\server.env" -Encoding ASCII

& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root
Log "BAT=$(Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1)"

# reset CUDA state a bit
nvidia-smi --gpu-reset -i 0 2>&1 | ForEach-Object { Log "nvidia: $_" }

& "$root\tools\nssm.exe" start LlamaServer
Start-Sleep 8
for ($i=0; $i -lt 60; $i++) {
  $st = (Get-Service LlamaServer -EA SilentlyContinue).Status
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 8
    Log "status=$st health=$($r.Content)"
    if ($r.Content -match 'ok') {
      Start-Service KortexioOllamaTunnel -EA SilentlyContinue
      $p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
      Log "n_ctx=$($p.default_generation_settings.n_ctx)"
      Log "gpu=$(nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader)"
      Log "Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
      Log "=== OK ==="
      exit 0
    }
  } catch { Log "status=$st wait=$($_.Exception.Message)" }
  if ($st -eq 'Stopped') {
    Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
    Log "=== FAIL stopped ==="
    exit 1
  }
  Start-Sleep 4
}
Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
Log "=== FAIL timeout ==="
exit 1
