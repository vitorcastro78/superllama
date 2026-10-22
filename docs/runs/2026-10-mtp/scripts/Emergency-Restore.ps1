$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-emergency.log"
function Log($m){ Add-Content $log $m; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== emergency $(Get-Date -Format o) ==="

# kill ALL related
Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
Stop-Service LlamaServer -Force -EA SilentlyContinue
& "C:\LlamaServer\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
Start-Sleep 2
taskkill /F /IM llama-server.exe 2>&1 | ForEach-Object { Log "$_" }
taskkill /F /IM llama-server-impl.exe 2>&1 | ForEach-Object { Log "$_" }
Get-Process | Where-Object { $_.ProcessName -match 'llama' } | ForEach-Object {
  Log "Stop-Process $($_.Id) $($_.ProcessName)"
  Stop-Process -Id $_.Id -Force -EA SilentlyContinue
}
Start-Sleep 3
$left = @(Get-Process llama-server -EA SilentlyContinue)
Log "remaining llama-server count=$($left.Count)"

# free GPU
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv | ForEach-Object { Log "gpu $_" }

$root = "C:\LlamaServer"
Remove-Item "$root\logs\service.err.log","$root\logs\service.out.log" -Force -EA SilentlyContinue

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

& "$root\tools\nssm.exe" start LlamaServer
Log "nssm start exit=$LASTEXITCODE"
Start-Sleep 10

for ($i=0; $i -lt 45; $i++) {
  $st = (Get-Service LlamaServer).Status
  $procs = @(Get-Process llama-server -EA SilentlyContinue).Count
  try {
    $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 6
    Log "[$i] status=$st procs=$procs health=$($r.Content)"
    if ($r.Content -match 'ok') {
      Start-Service KortexioOllamaTunnel -EA SilentlyContinue
      Start-Sleep 2
      nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader | ForEach-Object { Log "gpu $_" }
      Log "Tunnel=$((Get-Service KortexioOllamaTunnel).Status)"
      Log "=== OK ==="
      exit 0
    }
  } catch {
    Log "[$i] status=$st procs=$procs wait=$($_.Exception.Message)"
  }
  if ($st -eq 'Stopped' -and $i -gt 3) {
    Get-Content "$root\logs\service.err.log" -Tail 40 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
    break
  }
  Start-Sleep 4
}
Get-Content "$root\logs\service.err.log" -Tail 50 -EA SilentlyContinue | ForEach-Object { Log "ERR $_" }
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | ForEach-Object { Log "gpu $_" }
Log "=== FAIL ==="
exit 1
