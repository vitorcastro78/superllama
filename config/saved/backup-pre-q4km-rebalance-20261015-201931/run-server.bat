@echo off

setlocal

set ROOT=%~dp0..

set PATH=%ROOT%\bin;%PATH%

cd /d "%ROOT%\bin"

set CUDA_VISIBLE_DEVICES=0,1

"C:\LlamaServer\bin\llama-server.exe" -m "D:\Models\gguf\Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf" --alias qwen3.6-35b --host 127.0.0.1 --port 11434 -ngl 99 -c 67584 --n-predict 32768 --parallel 1 -fa on --threads 8 -ctk q4_0 -ctv q4_0 --device CUDA0,CUDA1 --split-mode layer --tensor-split 12,8 --main-gpu 0 --fit off --n-cpu-moe 999 --moe-cache-mib 5500,3200 --cache-prompt --cache-reuse 512 --slot-prompt-similarity 0.30 --jinja --reasoning auto --reasoning-effort medium --reasoning-budget 4096 --media-path "D:/" --webui --load-mode none