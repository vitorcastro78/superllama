@echo off
setlocal
set ROOT=%~dp0..
set PATH=%ROOT%\bin;%PATH%
cd /d "%ROOT%\bin"
set CUDA_VISIBLE_DEVICES=0
"C:\LlamaServer\bin\llama-server.exe" -m "D:\Models\gguf\Qwen_Qwen3.6-35B-A3B-IQ2_S.gguf" --alias qwen3.6-35b --host 127.0.0.1 --port 11434 -ngl 99 -c 92160 --n-predict 32768 --parallel 1 -fa on --threads 8 -ctk turbo4 -ctv turbo3 --device CUDA0 --split-mode none --main-gpu 0 --fit off --cache-prompt --cache-reuse 512 --slot-prompt-similarity 0.30 --jinja --reasoning auto --reasoning-effort medium --reasoning-budget 4096 --media-path "D:/" --webui