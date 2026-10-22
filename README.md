# SuperLlama

**Local LLM stack for ordinary PCs** — Windows installer + configs for a CUDA `llama-server` build with **TurboQuant KV** (`turbo2` / `turbo3` / `turbo4`), llama.ui, Manager, Tray, Inference Monitor, and an optional Thinking Router.

License: **[MIT](LICENSE)**. Use it, fork it, ship it. Model weights and third-party UIs keep their own licenses.

Bins and the Setup `.exe` are **not** in git — grab them from **[GitHub Releases](../../releases)**. This repo shares the **configs, scripts, and Manager source** so you can reproduce what we run.

---

## Why this exists

Upstream [llama.cpp](https://github.com/ggml-org/llama.cpp) moves fast. Features that help **mid-range / laptop GPUs** often land first as experimental PRs (TurboQuant KV, MTP speculative decode, MoE CPU offload / LRU). SuperLlama packages a **tested Windows tree** around those builds so you do not need a 24–48 GB card to run a useful MoE chat stack.

If your machine is “good enough” (≈6–12 GB VRAM, 16–32 GB RAM), start with the presets below and scale context / quant up only as VRAM allows.

---

## Reference hardware (what we actually measure on)

| Piece | Spec |
|-------|------|
| CPU | AMD Ryzen 5 5600G (6c / 12t) |
| RAM | ~32 GB |
| GPU 0 (production) | **NVIDIA RTX 3060 12 GB** (Ampere, sm_86) |
| GPU 1 (available) | NVIDIA RTX 3050 8 GB |
| OS | Windows 10/11 x64, recent Game Ready / Studio driver |

Secondary target profile in-repo: **~6 GB laptop GPUs** (e.g. RTX 4050 Ada) via MoE + `--n-cpu-moe`.

These are **not** datacenter numbers. They are what a normal desktop can sustain all day as a Windows service.

---

## Measured results (RTX 3060 12 GB)

Production profile: **Qwen3.6-35B-A3B IQ2_S**, TurboQuant KV **K=`turbo4` / V=`turbo3`**, **ctx 92 160**, Flash Attention on, single slot, CUDA0 only.

Sampled from live `llama-server` logs on this machine (short interactive turns + longer prompts):

| Phase | Typical range | Notes |
|-------|---------------|--------|
| **Generation (decode)** | **~45–60 tok/s** | Short chat often ~50–56 tok/s; longer fills trend ~41–50 tok/s |
| **Prompt eval (cached / mid size)** | **~300–1100 tok/s** | Depends on cache hit + prompt size |
| **Long prompt ingest (~4k–10k tokens)** | **~1000–1200 tok/s** while filling | Full ~10k prompt eval ≈ **~1050 tok/s** |

Example lines (production service):

- decode `133` tokens → **51.3 tok/s**
- decode `459` tokens → **56.6 tok/s**
- prompt `10824` tokens → **~1050 tok/s** prompt eval, then decode **~46 tok/s**

**Takeaway for modest PCs:** TurboQuant KV is what makes **~90k context** practical on **12 GB**. Without it, the same context budget usually does not fit (or forces harsh trade-offs). IQ2_S MoE keeps weights small enough that layers stay on GPU while KV stays compressible.

Speeds vary with driver, power limit, concurrent GPU load, and prompt-cache hits. Treat the table as a **reproducible ballpark**, not a leaderboard claim.

---

## Experimental llama.cpp merges (not all upstream-stable)

SuperLlama is built against a **custom CUDA tree** that folds in work still landing / iterating upstream. Expect breakage if you mix random nightlies.

| Track | What it gives you | Status in our tree |
|-------|-------------------|--------------------|
| **TurboQuant KV** (`turbo2`/`turbo3`/`turbo4`) | Much smaller KV → long context on 8–12 GB | **Production default** (`turbo4`/`turbo3`, ctx 90k) |
| **MTP / `draft-mtp`** | Speculative decode with Unsloth MTP GGUFs | **Optional preset** (`config/server-mtp.env`) — needs MTP heads GGUF, **not** plain IQ2_S |
| **MoE CPU experts** (`--n-cpu-moe`) | Run MoE on ~6 GB by parking experts in system RAM | **Optional** `server-moe-6gb.env` |
| **MoE LRU / TurboQuant hparams** | GPU-resident expert cache adapted to TurboQuant | Experimental branch work (e.g. `super-llama-tq-moe-lru`) |

Build script (C++ lives outside this repo, typically `D:\src\llama.cpp` on a TurboQuant-capable branch):

```powershell
.\scripts\Build-CudaTurboQuant.ps1 -Archs '75;86'
# Ada / 4050 laptop: -Archs '89'   or   '75;86;89'
```

The installer **refuses** to package a binary that does not advertise `turbo4` in `--help` (unless you pass `-SkipTurboQuantCheck`).

---

## Shared configurations

All presets ship under [`config/`](config/). Copy the pair you want over the live files under `C:\LlamaServer\config\` (keep a backup), or point Manager at the env file.

### 1) Production (default) — 12 GB class

Files: [`config/server.env`](config/server.env) + [`config/models-preset.ini`](config/models-preset.ini)

| Setting | Value |
|---------|--------|
| Model | `Qwen_Qwen3.6-35B-A3B-IQ2_S.gguf` (adjust path) |
| Context | `92160` |
| KV | `CacheTypeK=turbo4`, `CacheTypeV=turbo3` |
| GPU | `CudaVisibleDevices=0`, `Device=CUDA0`, `GpuLayers=99` |
| Profile id | `super-qwen-90k-turbo4k-turbo3v` |

```env
# excerpt — full file in config/server.env
Model=C:\Models\gguf\Qwen_Qwen3.6-35B-A3B-IQ2_S.gguf
CtxSize=92160
CacheTypeK=turbo4
CacheTypeV=turbo3
FlashAttn=on
Parallel=1
Device=CUDA0
Profile=super-qwen-90k-turbo4k-turbo3v
```

### 2) ~6 GB VRAM (laptops / RTX 4050-class)

Files: [`config/server-moe-6gb.env`](config/server-moe-6gb.env) + [`config/models-preset-moe-6gb.ini`](config/models-preset-moe-6gb.ini)

| Setting | Value |
|---------|--------|
| Context | `8192` (start small) |
| KV | `turbo3` / `turbo3` |
| MoE | `ExtraArgs=--n-cpu-moe 999` (experts → system RAM) |
| Fit | `Fit=on` |
| Profile id | `moe-6gb-turbo3` |

Point `model=` in the ini at a **small MoE** GGUF you actually have (IQ2/IQ3). Expect slower decode than the 12 GB profile; the goal is **it runs**.

### 3) Optional MTP + TurboQuant (experimental)

Files: [`config/server-mtp.env`](config/server-mtp.env) + [`config/models-preset-mtp.ini`](config/models-preset-mtp.ini)

| Setting | Value |
|---------|--------|
| Model | Unsloth **MTP** GGUF, e.g. `Qwen3.6-35B-A3B-UD-IQ2_M.gguf` |
| Context | `32768` |
| KV | `turbo3` / `turbo2` |
| Speculative | `--spec-type draft-mtp --spec-draft-n-max 1` |
| Profile id | `iq2mtp-32k-turbo3k-turbo2v` |

**Do not** point this at the production IQ2_S file — MTP needs draft heads in the GGUF. Binary must expose `draft-mtp` (ours does).

### Paths you must edit on a new machine

In whichever env you activate:

- `ModelsDir`, `Model` → your GGUF folder  
- `MediaPath`, `UiPath` → local paths  
- `CudaVisibleDevices` / `Device` → which GPU  

---

## What you get after install

| Component | Default path | Port |
|-----------|--------------|------|
| llama-server (TurboQuant CUDA) | `C:\LlamaServer\bin` | **11434** |
| llama.ui | `C:\LlamaServer\ui\llama.ui` | via 11434 |
| Manager + Tray | `C:\LlamaServer\manager` | — |
| Inference Monitor | `C:\LlamaServer\tools\inference-monitor` | **11436** |
| Thinking Router (optional) | `C:\LlamaServer\tools\thinking-router` | **11437** |

Typical remote access (e.g. Kortex): SSH tunnel to **11434**. If you enable the Thinking Router, tunnel **11437** instead.

---

## Quick start (consumers)

1. Install a recent **NVIDIA** driver.  
2. Download the latest **SuperLlama Setup** from Releases.  
3. Place a suitable GGUF under e.g. `C:\Models\gguf\`.  
4. Edit `C:\LlamaServer\config\server.env` (or swap in a preset from this repo).  
5. Start via Tray / Windows service / Manager.  
6. Open `http://127.0.0.1:11434/`.

**Python 3.10+** is needed for Inference Monitor and (optional) Thinking Router.

---

## Build the installer (packagers)

Requirements: .NET 8 SDK, Inno Setup 6, NSSM, UI at `C:\LlamaServer\ui\llama.ui`, TurboQuant `llama-server` (build script or existing `C:\LlamaServer\bin`).

```powershell
cd C:\Users\vitor\llm\src\SuperLlama
.\scripts\Build-CudaTurboQuant.ps1 -Archs '75;86'
.\scripts\Build-Installer.ps1 -Version 1.2.0
```

Output: `dist\SuperLlama-Setup-1.2.0.exe`

---

## Repo layout

```
config/                 Shared env + model presets (production, 6GB MoE, MTP)
installer/              Inno Setup script
scripts/                CUDA TurboQuant build, installer, Windows service helpers
tools/                  inference-monitor, thinking-router
LlamaServer.Manager/    .NET Manager + Tray source
LICENSE                 MIT
dist/, staging/         gitignored build outputs
```

---

## Honest limits / tips for non-beast PCs

1. **Quantization first** — IQ2 / IQ3 MoE beats a dense 70B you cannot load.  
2. **Context is the tax** — raise `CtxSize` only after the model fits; TurboQuant helps, it does not invent VRAM.  
3. **One parallel slot** (`Parallel=1`) keeps latency predictable on 8–12 GB.  
4. **Laptop 6 GB** — use the MoE preset + `--n-cpu-moe`; keep ctx at 4k–8k until stable.  
5. **MTP is optional** — great when it works; production stays on IQ2_S without draft heads.  
6. **Close games / browsers on the GPU** while measuring — shared VRAM ruins tok/s comparisons.

---

## Credits & related licenses

- Runtime engine: [llama.cpp](https://github.com/ggml-org/llama.cpp) (and experimental TurboQuant / MTP / MoE work from the community).  
- UI: llama.ui (upstream license applies).  
- Models: follow each GGUF publisher’s terms (e.g. Qwen / Unsloth).  

SuperLlama packaging, configs, scripts, and Manager/Tray in this repository are MIT — see [LICENSE](LICENSE).
