$ErrorActionPreference = "Continue"
$log = "C:\Users\vitor\llm\src\SuperLlama\dist\mtp-try-64k.log"
function Log($m){ Add-Content $log "$(Get-Date -Format o) $m"; Write-Host $m }
Remove-Item $log -Force -EA SilentlyContinue
Log "=== try reach 64k ==="

$root = "C:\LlamaServer"
$bak = Join-Path $root ("config\backup-pre-64k-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Copy-Item "$root\config\server.env" "$bak\server.env" -Force
Copy-Item "$root\scripts\run-server.bat" "$bak\run-server.bat" -Force -EA SilentlyContinue
Set-Content "$root\config\LAST_MTP_TEST_BACKUP.txt" $bak
Log "Backup=$bak"

function Stop-Stack {
  Stop-Service KortexioOllamaTunnel -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" stop LlamaServer confirm 2>$null | Out-Null
  Start-Sleep 2
  Get-Process llama-server -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
  Start-Sleep 3
}
function Get-Gpu { (nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits) -join ' | ' }

function Write-Env {
  param($Ctx,$Ctk,$Ctv,$Extra,$Profile,$EnvExtra='')
  @"
ModelsDir=D:\Models\gguf
Host=127.0.0.1
Port=11434
DefaultModel=qwen3.6-35b-mtp
Model=D:\Models\gguf\Qwen3.6-35B-A3B-UD-IQ2_M.gguf
UseRouter=0
GpuLayers=99
CtxSize=$Ctx
NPredict=2048
Parallel=1
FlashAttn=on
KvUnified=0
ModelsMax=1
Threads=8
CacheTypeK=$Ctk
CacheTypeV=$Ctv
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
Profile=$Profile
ExtraArgs=$Extra
"@ | Set-Content "$root\config\server.env" -Encoding ASCII
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null

  # inject env var into bat if needed (TURBO_AUTO_ASYMMETRIC)
  if ($EnvExtra) {
    $bat = Get-Content "$root\scripts\run-server.bat"
    $new = @()
    foreach ($line in $bat) {
      $new += $line
      if ($line -match '^set CUDA_VISIBLE_DEVICES') {
        $new += "set $EnvExtra"
      }
    }
    Set-Content "$root\scripts\run-server.bat" $new -Encoding ASCII
  }
}

function Wait-Health([int]$sec=300) {
  if (Test-Path "$root\logs\service.err.log") { Remove-Item "$root\logs\service.err.log" -Force -EA SilentlyContinue }
  $deadline = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Service LlamaServer).Status
    try {
      $r = Invoke-WebRequest "http://127.0.0.1:11434/health" -UseBasicParsing -TimeoutSec 6
      if ($r.Content -match '"status"\s*:\s*"ok"') { Log "  health=ok gpu=$(Get-Gpu)"; return $true }
      Log "  health=$($r.StatusCode) status=$st"
    } catch { Log "  wait status=$st $($_.Exception.Message)" }
    $tail = (Get-Content "$root\logs\service.err.log" -Tail 30 -EA SilentlyContinue | Out-String)
    if ($tail -match 'out of memory|CUDA error|GGML_ASSERT|resource allocation failed') {
      Log "  FAIL CUDA"; ($tail -split "`n") | Select-Object -Last 8 | ForEach-Object { Log "  ERR $_" }
      return $false
    }
    if ($st -eq 'Stopped') { Get-Content "$root\logs\service.err.log" -Tail 20 -EA SilentlyContinue | ForEach-Object { Log "  ERR $_" }; return $false }
    Start-Sleep 4
  }
  return $false
}

function Bench {
  $body = @{ model='qwen3.6-35b-mtp'; messages=@(@{role='user';content='Say only: OK'}); max_tokens=16; temperature=0; stream=$false } | ConvertTo-Json -Depth 5
  $resp = Invoke-RestMethod 'http://127.0.0.1:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
  $t = $resp.timings
  Log ("  bench tok/s={0:N1} draft={1}/{2}" -f $t.predicted_per_second, $t.draft_n_accepted, $t.draft_n)
}

function Try-One($Name, $ApplyBlock) {
  Log "--- $Name ---"
  Stop-Stack
  & $ApplyBlock
  Log "  BAT=$(Get-Content "$root\scripts\run-server.bat" | Select-Object -Last 1)"
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  Start-Sleep 6
  if (-not (Wait-Health 300)) { Log "  RESULT=FAIL"; return $false }
  Bench
  Log "  RESULT=PASS"
  return $true
}

function Restore {
  Log "Restore baseline"
  Stop-Stack
  Copy-Item "$bak\server.env" "$root\config\server.env" -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\Write-RunServerBat.ps1" -Root $root | Out-Null
  Remove-Item "$root\logs\service.err.log" -Force -EA SilentlyContinue
  & "$root\tools\nssm.exe" start LlamaServer | Out-Null
  if (Wait-Health 300) { Start-Service KortexioOllamaTunnel -EA SilentlyContinue; Log "baseline ok" }
}

# A) turbo2 forced (no auto q8) @ 32k then 64k
$ok = Try-One 'A turbo2 forced @32768' {
  Write-Env 32768 'turbo2' 'turbo2' '--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0' 'mtp-t2force-32k' 'TURBO_AUTO_ASYMMETRIC=0'
}
if ($ok) {
  $ok = Try-One 'A2 turbo2 forced @65536' {
    Write-Env 65536 'turbo2' 'turbo2' '--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0' 'mtp-t2force-64k' 'TURBO_AUTO_ASYMMETRIC=0'
  }
}

# B) if not 64k yet: minimal n-cpu-moe for 64k with turbo4/3
$needB = $true
try {
  $ctx = [int](Invoke-RestMethod 'http://127.0.0.1:11434/props').default_generation_settings.n_ctx
  if ($ctx -ge 65536) { $needB = $false }
} catch { $needB = $true }

if ($needB) {
  foreach ($n in @(8, 12, 16, 20)) {
    $ok = Try-One "B n-cpu-moe=$n @65536 turbo4/3" {
      Write-Env 65536 'turbo4' 'turbo3' "--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0.0 --n-cpu-moe $n" "mtp-ncmoe$n-64k"
    }
    if ($ok) { break }
  }
}

# final status
try {
  $p = Invoke-RestMethod 'http://127.0.0.1:11434/props'
  Log "FINAL n_ctx=$($p.default_generation_settings.n_ctx) gpu=$(Get-Gpu)"
  Log "FINAL $((Select-String -Path "$root\config\server.env" -Pattern '^(Ctx|CacheType|Extra|Profile)=').Line -join ' || ')"
  Start-Service KortexioOllamaTunnel -EA SilentlyContinue
} catch {
  Log "unhealthy - restore"
  Restore
}
Log "=== done ==="
