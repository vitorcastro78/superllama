# SuperLlama

**Local LLM stack for ordinary PCs** — Windows installer + configs for a CUDA `llama-server` build with **TurboQuant KV** (`turbo2` / `turbo3` / `turbo4`), llama.ui, Manager, Tray, Inference Monitor, and an optional Thinking Router.

License: **[MIT](LICENSE)**. Use it, fork it, ship it. Model weights and third-party UIs keep their own licenses.

Bins and the Setup `.exe` are **not** in git — grab them from **[GitHub Releases](../../releases)**. This repo shares the **configs, scripts, and Manager source** so you can reproduce what we run.

---

## Why this exists

Upstream [llama.cpp](https://github.com/ggml-org/llama.cpp) moves fast. Features that help **mid-range / laptop GPUs** often land first as experimental PRs (TurboQuant KV, MTP speculative decode, MoE CPU offload / LRU). SuperLlama packages a **tested Windows tree** around those builds so you do not need a 24–48 GB card to run a useful MoE chat stack.

If your machine is “good enough” (≈6–12 GB VRAM, 16–32 GB RAM), start with the presets below and scale context / quant up only as VRAM allows.

---

## The saga: why SuperLlama looks the way it does

We did not start with a polished installer. We started with a normal desktop (**RTX 3060 12 GB + Ryzen 5 + 32 GB RAM**) and a simple goal: **a local assistant that stays up as a Windows service, with enough context to be useful for real work** — not a 2k-token toy demo.

That goal collided with reality:

1. **Stock llama.cpp + “sensible” quants** gave us a model that fit… until we asked for long context. KV cache ate the 12 GB card alive.
2. **Bigger quants / denser models** felt smarter for a few turns, then OOMed or crawled once the conversation grew.
3. **Dual-GPU experiments** (3060 + 3050, tensor split, dual VRAM profiles) looked promising on paper. In practice: more moving parts, harder restarts, and not enough win for a daily driver. We kept the hardware; production stayed **single GPU (CUDA0)**.
4. **MoE + CPU experts** (`--n-cpu-moe`) unlocked smaller cards (~6 GB) and taught us that “usable on a laptop” is a different profile than “usable as the house server”.
5. **mmap / load-mode / Q4_K_M / coding-oriented presets** — each left a backup folder under `C:\LlamaServer\config\backup-pre-*`. Most were stepping stones, not destinations.
6. **MTP / speculative decode** (`draft-mtp`, Unsloth MTP GGUFs, 8k→16k→32k→64k sweeps) delivered real speed — **peaks ~108–113 tok/s** at 8k–16k — but dual-GPU and high-ctx MTP OOMed or slowed once we stacked CPU MoE. It remains an **optional preset**, not the default, because production has to survive overnight without babysitting.
7. **TurboQuant KV** (`turbo2` / `turbo3` / `turbo4`) was the breakthrough for *our* hardware: compress the cache hard enough that **~90k context** on **IQ2_S Qwen3.6-35B-A3B** became a boring, reliable service at **~80 tok/s peak** (typical chat ~45–60) instead of a weekend science project.

Along the way we also had to productize the boring parts nobody ships in a random PR branch: **NSSM Windows service**, **Manager + Tray**, **llama.ui**, **Inference Monitor**, rollback scripts, and finally **one Setup.exe** so the next machine (or the next person with a mid-range GPU) does not repeat the archaeology.

So SuperLlama is not “yet another llama.cpp fork page”. It is the **survivors’ kit** from that saga:

| We tried | What we learned | What shipped |
|----------|-----------------|--------------|
| Dual GPU / fancy splits | Complexity > benefit for 12+8 GB | Production = **one GPU** |
| Chase max tok/s with MTP | Cool when it works; fragile as default | Optional `server-mtp.env` |
| Chase max quality quants | Context dies first on 12 GB | **IQ2_S MoE** + TurboQuant KV |
| Nightly upstream only | Flags move; breaks your service | Pin a **TurboQuant-capable** build; refuse to package without `turbo4` |
| Manual folder copy | Easy to desync bin/config/UI | **Single installer** + shared `config/` presets |

If you only have a modest PC: **skip our dead ends**. Install the Release build, start from `config/server.env` (or the 6 GB MoE preset), and raise context only after the model fits. The backups and failed sweeps were the tuition; the presets are the diploma.

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

All numbers below are from **this reference box** (CUDA0 = 3060 12 GB). Decode = `predicted_per_second` from the server API / `eval time` in logs (generation only, not prompt eval).

### Production default (what we leave running)

**Qwen3.6-35B-A3B IQ2_S** · KV `turbo4`/`turbo3` · **ctx 92 160** · FlashAttn · **no** speculative · single GPU

| Metric | Result | Source |
|--------|--------|--------|
| **Peak / short-bench decode** | **~80 tok/s** (**79.5** API bench, **~79** peak in service logs) | Prod revert bench + overnight logs |
| **Typical interactive decode** | **~45–60 tok/s** (busy-day average ≈ **58**) | Live `slot print_timing` |
| **Longer generations** | **~41–56 tok/s** | e.g. 459 tok @ 56.6; 968 tok @ 41 |
| **Prompt eval (mid / cached)** | **~300–1100 tok/s** | Depends on cache hit |
| **Long prompt ingest (~4k–10k)** | **~1000–1200 tok/s** fill · full ~10k ≈ **~1050 tok/s** | Production service |

That **~80 tok/s** peak is the important headline for “stock” SuperLlama: same 90k-capable profile, no MTP GGUF required.

### MTP speculative (`draft-mtp`) — optional, faster, fussier

**Unsloth MTP GGUF** `Qwen3.6-35B-A3B-UD-IQ2_M` · `--spec-type draft-mtp` · single GPU (unless noted)

| Setup | Decode tok/s | Notes |
|-------|----------------|-------|
| **MTP · ctx 8k · turbo4/turbo3 · draft-n-max 2** | **Peak ~113 tok/s** (API `predicted_per_second`; wall rough ≈ 89) | Best speed we measured · draft accept 99/118 |
| **MTP · ctx 16k** | **~105–107 tok/s** (sweep **104.5**, re-bench **106.8**) | Stable sweet spot on 12 GB |
| **MTP · ctx 16k** (other runs) | **~86 tok/s** | Still well above plain IQ2_S mid-load |
| **MTP · ctx 32k–90k + `--n-cpu-moe 20`** | **~34–45 tok/s** | Fits higher ctx; experts on CPU → slower than 8k/16k MTP |
| **MTP · Q4_K_XL** | **~12–16 tok/s** | Heavier quant lost; not worth it here |
| **MTP · dual GPU / draft on CUDA1** | **FAIL (CUDA OOM)** | Abandoned for daily use |

Headline: **MTP peaked around 108–113 tok/s** on this 3060; **production without MTP still hits ~80 tok/s** on short turns while keeping **90k context**.

### What we rejected (so you do not repeat it)

| Experiment | Outcome |
|------------|---------|
| Dual-GPU MTP / tensor-split for speed | OOM or flaky restarts · rolled back to CUDA0 |
| Chase 64k+ MTP without CPU MoE | Unstable / OOM on 12 GB |
| Q4_K_XL + MTP | Accepted drafts but **~4–7× slower** than IQ2_M MTP |
| MTP as Windows-service default | Great benches; more fragile overnight than IQ2_S 90k |

**Takeaway for modest PCs:** use **production IQ2_S + TurboQuant (~80 tok/s peak, 90k ctx)** as the daily driver. Turn on **MTP** (`config/server-mtp.env`) when you want **~100–110+ tok/s** and can live with a smaller ctx / MTP GGUF. Speeds move with driver, power limit, and GPU load — treat these as **logged runs on our hardware**, not a contest board.

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
