# LlamaServer Manager

App Windows (WPF / .NET 8) para gerir **todas** as opções do `llama-server` — sem chat.

Integra-se com o stack em `C:\LlamaServer` (`server.env`, `models-preset.ini`, NSSM, `Write-RunServerBat.ps1`).

## Requisitos

- Windows 10/11 x64
- .NET 8 SDK (para desenvolver)
- Stack LlamaServer em `C:\LlamaServer` (binário Prism / llama.cpp)
- Opcional: [Inno Setup 6](https://jrsoftware.org/isinfo.php) para o instalador
- NSSM + serviço `LlamaServer` para o modo serviço

## Funcionalidades

| Separador | Função |
|-----------|--------|
| **Dashboard** | Status serviço/processo, `/health`, GPUs, Start/Stop/Restart, Update binário |
| **Global / Router** | Flags de `server.env` + Extra args + catálogo parseado de `--help` |
| **Presets** | CRUD de `models-preset.ini` (device por GPU, ctx, mmproj, …) |
| **Apply** | Preview do comando → guardar env/presets/bat → restart |
| **Logs** | Tail de `logs\service*.log` + stdout do modo processo |
| **Settings** | Path do LlamaServer |

### Modos de runtime

- **Serviço NSSM** — chama `nssm start|stop|restart LlamaServer` com elevação UAC; sincroniza `CUDA_VISIBLE_DEVICES` a partir de `CudaVisibleDevices` no env.
- **Processo local** — a app lança `llama-server.exe` com o argv gerado (útil para testar sem serviço).

## Desenvolvimento

```powershell
cd C:\Users\vitor\llm\src\LlamaServer.Manager
dotnet build LlamaServer.Manager.slnx -c Release
dotnet run --project src\LlamaServer.Manager -c Release
```

## Instalador

```powershell
.\scripts\Build-Installer.ps1
# ou só publish:
.\scripts\Build-Installer.ps1 -SkipInno
```

Saída: `dist\LlamaServerManager-Setup-1.0.0.exe`  
Instala em `C:\Program Files\LlamaServer Manager\` (ou pasta do utilizador).  
Não reinstala o binário llama — detecta / associa `C:\LlamaServer`.

## Licença / flags

O catálogo de flags vem de `llama-server --help` (Prism).  
Não se inclui código do LLama-GUI (GPL-3.0); só categorias/UX inspiradas.

## Estrutura

```
src/LlamaServer.Manager.Core/   # env, presets, argv, help parser, NSSM, process
src/LlamaServer.Manager/        # WPF UI
installer/                      # Inno Setup
scripts/Build-Installer.ps1
```
