# SuperLlama (TurboQuant)

Pacote Windows do stack Kortex/local: **llama-server CUDA com KV TurboQuant** (`turbo2` / `turbo3` / `turbo4`), llama.ui, Manager, Tray, Inference Monitor e Thinking Router (opcional).

Bins e o Setup **não** vão para o git — publicam-se em **GitHub Releases**.

## Componentes

| Componente | Destino | Porta |
|------------|---------|-------|
| llama-server (TurboQuant CUDA) | `C:\LlamaServer\bin` | **11434** |
| llama.ui | `C:\LlamaServer\ui\llama.ui` | via 11434 |
| Manager + Tray | `C:\LlamaServer\manager` | — |
| Inference Monitor | `C:\LlamaServer\tools\inference-monitor` | **11436** |
| Thinking Router (opcional) | `C:\LlamaServer\tools\thinking-router` | **11437** |

## Perfil default (produção)

`config/server.env`:

- `CacheTypeK=turbo4` / `CacheTypeV=turbo3`
- `CtxSize=92160`
- `Profile=super-qwen-90k-turbo4k-turbo3v`
- Paths de modelo como placeholders (`C:\Models\gguf\...`) — edita no host após instalar

Preset opcional GPUs ~6GB: `config/server-moe-6gb.env` + `models-preset-moe-6gb.ini`.

## Build do binário CUDA TurboQuant

O C++ vive fora deste repo (`D:\src\llama.cpp`, branch `super-llama-turboquant`).

```powershell
cd C:\Users\vitor\llm\src\SuperLlama
.\scripts\Build-CudaTurboQuant.ps1 -Archs '75;86'
# Ada / 4050: -Archs '89' ou '75;86;89'
```

Saída típica: `D:\src\llama.cpp\build-cuda-turboquant\bin\llama-server.exe`

## Gerar o Setup

Requisitos: .NET 8 SDK, Inno Setup 6, NSSM, UI em `C:\LlamaServer\ui\llama.ui`, bin TurboQuant (ver acima ou `C:\LlamaServer\bin` com `turbo4` no `--help`).

```powershell
cd C:\Users\vitor\llm\src\SuperLlama
.\scripts\Build-Installer.ps1 -Version 1.2.0
```

Saída: `dist\SuperLlama-Setup-1.2.0.exe`

O script **falha** se o binário não reportar `turbo4` (garante TurboQuant no pacote).

## Kortex / túnel

Produção tipica: túnel SSH → **LocalPort 11434** (sem Thinking Router). Se ativares o router, aponta o túnel para **11437**.

## Layout do repo

```
installer/          Inno Setup
scripts/            Build-CudaTurboQuant, Build-Installer, serviço
config/             server.env (prod default) + presets
tools/              inference-monitor, thinking-router
LlamaServer.Manager/  código .NET Manager + Tray
dist/               (gitignored) Setup gerado
staging/            (gitignored) staging do build
```
