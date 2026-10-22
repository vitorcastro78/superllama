@echo off
setlocal
set ROOT=%~dp0..
set PATH=%ROOT%\bin;%PATH%
cd /d "%ROOT%\bin"
set CUDA_VISIBLE_DEVICES=0
"C:\LlamaServer\bin\llama-server.exe" --models-preset "C:\LlamaServer\config\models-preset.ini" --host 127.0.0.1 --port 11434 -ngl 99 -c 67584 --n-predict 2048 --parallel 1 --models-max 1 --models-autoload -fa on --threads 8 -ctk q4_0 -ctv q4_0 --device CUDA0 --split-mode none --fit off --main-gpu 0 --cache-prompt --cache-reuse 512 --slot-prompt-similarity 0.30 --jinja --reasoning auto --reasoning-effort medium --reasoning-budget 4096 --agent --tools all --media-path "D:/" --webui