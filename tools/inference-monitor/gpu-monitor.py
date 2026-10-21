#!/usr/bin/env python3
"""Live NVIDIA GPU + llama-server monitor (web UI / desktop app shell)."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def run_silent(cmd: list[str]) -> str:
    """Run a process without flashing a console window on Windows."""
    kwargs: dict = {
        "text": True,
        "stderr": subprocess.STDOUT,
        "encoding": "utf-8",
        "errors": "replace",
    }
    if sys.platform == "win32":
        # CREATE_NO_WINDOW — evita o blink do cmd a cada poll do nvidia-smi
        kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 0  # SW_HIDE
        kwargs["startupinfo"] = si
    return subprocess.check_output(cmd, **kwargs)

HOST = "0.0.0.0"
PORT = 11436
LLAMA_BASE = "http://127.0.0.1:11434"
HISTORY = 180  # 3 min @ 1 Hz
LOG_PATHS = (
    r"C:\LlamaServer\logs\service.err.log",
    r"C:\LlamaServer\logs\service.out.log",
)
SAMPLES: list[dict] = []
LOCK = threading.Lock()
PREV: dict | None = None
SPEED: dict = {
    "decode_tps": 0.0,
    "prefill_tps": 0.0,
    "decode_tps_ema": 0.0,
    "prefill_tps_ema": 0.0,
    "decode_tps_peak": 0.0,
    "prefill_tps_peak": 0.0,
    "last_completed_decode_tps": 0.0,
    "last_completed_prefill_tps": 0.0,
    "last_completed_at": 0.0,
}


def http_json(url: str, timeout: float = 1.5):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def query_gpus() -> list[dict]:
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,memory.free,power.draw,power.limit,temperature.gpu,clocks.sm,clocks.mem,pcie.link.gen.current,pcie.link.width.current,fan.speed",
        "--format=csv,noheader,nounits",
    ]
    out = run_silent(cmd)
    rows = []
    for line in out.strip().splitlines():
        p = [x.strip() for x in line.split(",")]
        if len(p) < 10:
            continue

        def f(i, default=0.0):
            try:
                return float(p[i])
            except Exception:
                return default

        rows.append(
            {
                "index": int(float(p[0])),
                "name": p[1],
                "util": f(2),
                "mem_util": f(3),
                "mem_used": f(4),
                "mem_total": f(5),
                "mem_free": f(6),
                "power": f(7),
                "power_limit": f(8),
                "temp": f(9),
                "clock_sm": f(10),
                "clock_mem": f(11),
                "pcie_gen": f(12),
                "pcie_width": f(13),
                "fan": f(14) if len(p) > 14 else 0.0,
            }
        )
    return rows


def query_system() -> dict:
    try:
        # Windows: free/total physical memory via wmic/cim alternative using powershell is heavy;
        # use ctypes GlobalMemoryStatusEx
        import ctypes
        from ctypes import wintypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", wintypes.DWORD),
                ("dwMemoryLoad", wintypes.DWORD),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat))
        total = stat.ullTotalPhys / (1024**3)
        avail = stat.ullAvailPhys / (1024**3)
        return {
            "ram_total_gb": round(total, 2),
            "ram_used_gb": round(total - avail, 2),
            "ram_free_gb": round(avail, 2),
            "ram_load_pct": float(stat.dwMemoryLoad),
        }
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


def first_slot(payload):
    if payload is None:
        return None
    if isinstance(payload, list) and payload:
        return payload[0] if isinstance(payload[0], dict) else None
    if isinstance(payload, dict):
        if isinstance(payload.get("value"), list) and payload["value"]:
            return payload["value"][0]
        if "is_processing" in payload or "params" in payload:
            return payload
    return None


_TG_RE = re.compile(r"tg\s*=\s*([0-9.]+)\s*t/s", re.I)
_PP_RE = re.compile(r"([0-9.]+)\s*tokens per second", re.I)
_PROMPT_LINE_RE = re.compile(r"prompt eval time.*?/\s*([0-9]+)\s*tokens.*?([0-9.]+)\s*tokens per second", re.I)
_EVAL_LINE_RE = re.compile(r"eval time.*?/\s*([0-9]+)\s*tokens.*?([0-9.]+)\s*tokens per second", re.I)


def parse_recent_log_timings() -> dict:
    out = {"last_completed_decode_tps": 0.0, "last_completed_prefill_tps": 0.0, "last_completed_at": 0.0}
    try:
        text = ""
        for path in LOG_PATHS:
            if not os.path.exists(path):
                continue
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 64_000), os.SEEK_SET)
                text += "\n" + f.read().decode("utf-8", errors="replace")
        if not text.strip():
            return out
        # prefer full prompt/eval summary lines
        for m in _PROMPT_LINE_RE.finditer(text):
            out["last_completed_prefill_tps"] = float(m.group(2))
            out["last_completed_at"] = time.time()
        for m in _EVAL_LINE_RE.finditer(text):
            out["last_completed_decode_tps"] = float(m.group(2))
            out["last_completed_at"] = time.time()
        if not out["last_completed_decode_tps"]:
            m = None
            for m in _TG_RE.finditer(text):
                pass
            if m:
                out["last_completed_decode_tps"] = float(m.group(1))
                out["last_completed_at"] = time.time()
    except Exception:
        pass
    return out


def query_llama() -> dict:
    info = {
        "ok": False,
        "error": "",
        "router_status": "-",
        "build_info": "-",
        "model": "-",
        "model_status": "-",
        "model_path": "-",
        "model_ftype": "-",
        "n_params": 0,
        "model_size_bytes": 0,
        "context_length": 0,
        "worker_port": "-",
        "processing": False,
        "task_id": "-",
        "prompt_tokens": 0,
        "prompt_processed": 0,
        "prompt_cache": 0,
        "decoded": 0,
        "remain": 0,
        "n_predict": 0,
        "max_tokens": 0,
        "stream": False,
        "chat_format": "-",
        "reasoning_format": "-",
        "thinking": False,
        "n_ctx": 0,
        "speculative": False,
        "temperature": None,
        "top_p": None,
        "top_k": None,
        "phase": "idle",  # idle | prefill | decode
    }
    try:
        health = http_json(f"{LLAMA_BASE}/health")
        info["router_status"] = health.get("status", "ok")
    except Exception as exc:  # noqa: BLE001
        info["error"] = f"router: {exc}"
        return info

    try:
        props = http_json(f"{LLAMA_BASE}/props")
        info["build_info"] = props.get("build_info") or "-"
    except Exception:
        pass

    try:
        models = http_json(f"{LLAMA_BASE}/v1/models")
        data = models.get("data") or []
        if not data:
            info["ok"] = True
            info["model_status"] = "no-model"
            return info
        m0 = data[0]
        info["model"] = m0.get("id") or "-"
        status = m0.get("status") or {}
        info["model_status"] = status.get("value") or "-"
        args = status.get("args") or []
        if "--port" in args:
            info["worker_port"] = str(args[args.index("--port") + 1])
        meta = m0.get("meta") or {}
        info["n_params"] = int(meta.get("n_params") or 0)
        info["model_size_bytes"] = int(meta.get("size") or 0)
        info["context_length"] = int(m0.get("context_length") or meta.get("n_ctx_train") or meta.get("n_ctx") or 0)
        info["n_ctx"] = int(meta.get("n_ctx") or 0)
        info["model_ftype"] = meta.get("ftype") or "-"
        info["model_status"] = info["model_status"] if info["model_status"] != "-" else "loaded"
        info["ok"] = True

        # Single-process (UseRouter=0): no child worker — query the main server.
        # Router mode: follow --port from model status args.
        detail_base = (
            f"http://127.0.0.1:{info['worker_port']}"
            if info["worker_port"] != "-"
            else LLAMA_BASE
        )
        try:
            wprops = http_json(f"{detail_base}/props")
            info["model_path"] = wprops.get("model_path") or info.get("model_path") or "-"
            info["model_ftype"] = wprops.get("model_ftype") or info["model_ftype"] or "-"
            if wprops.get("default_generation_settings", {}).get("n_ctx"):
                info["n_ctx"] = int(wprops["default_generation_settings"]["n_ctx"])
            if wprops.get("build_info"):
                info["build_info"] = wprops.get("build_info")
        except Exception:
            pass

        try:
            slot = first_slot(http_json(f"{detail_base}/slots"))
        except Exception:
            slot = None
        if slot:
            info["processing"] = bool(slot.get("is_processing"))
            info["task_id"] = slot.get("id_task", "-")
            info["prompt_tokens"] = int(slot.get("n_prompt_tokens") or 0)
            info["prompt_processed"] = int(slot.get("n_prompt_tokens_processed") or 0)
            info["prompt_cache"] = int(slot.get("n_prompt_tokens_cache") or 0)
            info["n_ctx"] = int(slot.get("n_ctx") or info["n_ctx"] or 0)
            info["speculative"] = bool(slot.get("speculative"))
            params = slot.get("params") or {}
            info["n_predict"] = int(params.get("n_predict") or 0)
            info["max_tokens"] = int(params.get("max_tokens") or 0)
            info["stream"] = bool(params.get("stream"))
            info["chat_format"] = str(params.get("chat_format") or "-")
            info["reasoning_format"] = str(params.get("reasoning_format") or "-")
            info["temperature"] = params.get("temperature")
            info["top_p"] = params.get("top_p")
            info["top_k"] = params.get("top_k")
            gen = str(params.get("generation_prompt") or "")
            info["thinking"] = "think" in gen.lower()
            nxt = slot.get("next_token")
            if isinstance(nxt, list) and nxt:
                nxt = nxt[0]
            if isinstance(nxt, dict):
                info["decoded"] = int(nxt.get("n_decoded") or 0)
                info["remain"] = int(nxt.get("n_remain") or 0)

            if info["processing"]:
                if info["prompt_tokens"] > 0 and info["prompt_processed"] < info["prompt_tokens"]:
                    info["phase"] = "prefill"
                elif info["decoded"] > 0 or info["prompt_processed"] >= info["prompt_tokens"]:
                    info["phase"] = "decode"
                else:
                    info["phase"] = "prefill"
            else:
                info["phase"] = "idle"
    except Exception as exc:  # noqa: BLE001
        info["error"] = str(exc)
    return info


def update_speed(now: float, llama: dict) -> dict:
    global PREV
    spd = dict(SPEED)
    log_t = parse_recent_log_timings()
    if log_t["last_completed_decode_tps"]:
        spd["last_completed_decode_tps"] = log_t["last_completed_decode_tps"]
    if log_t["last_completed_prefill_tps"]:
        spd["last_completed_prefill_tps"] = log_t["last_completed_prefill_tps"]
    if log_t["last_completed_at"]:
        spd["last_completed_at"] = log_t["last_completed_at"]

    decode_tps = 0.0
    prefill_tps = 0.0
    if PREV and llama.get("ok"):
        dt = max(now - PREV["t"], 1e-3)
        same_task = llama.get("task_id") == PREV["llama"].get("task_id") and llama.get("processing")
        if same_task:
            ddec = max(int(llama.get("decoded") or 0) - int(PREV["llama"].get("decoded") or 0), 0)
            dpref = max(
                int(llama.get("prompt_processed") or 0) - int(PREV["llama"].get("prompt_processed") or 0),
                0,
            )
            if ddec > 0:
                decode_tps = ddec / dt
            if dpref > 0:
                prefill_tps = dpref / dt

    spd["decode_tps"] = round(decode_tps, 2)
    spd["prefill_tps"] = round(prefill_tps, 2)
    # EMA
    alpha = 0.35
    if decode_tps > 0:
        prev_ema = spd.get("decode_tps_ema") or decode_tps
        spd["decode_tps_ema"] = round(prev_ema * (1 - alpha) + decode_tps * alpha, 2)
        spd["decode_tps_peak"] = round(max(float(SPEED.get("decode_tps_peak") or 0), decode_tps), 2)
    else:
        spd["decode_tps_ema"] = round(float(SPEED.get("decode_tps_ema") or 0) * 0.85, 2) if not llama.get("processing") else float(SPEED.get("decode_tps_ema") or 0)
    if prefill_tps > 0:
        prev_ema = spd.get("prefill_tps_ema") or prefill_tps
        spd["prefill_tps_ema"] = round(prev_ema * (1 - alpha) + prefill_tps * alpha, 2)
        spd["prefill_tps_peak"] = round(max(float(SPEED.get("prefill_tps_peak") or 0), prefill_tps), 2)
    else:
        if not llama.get("processing"):
            spd["prefill_tps_ema"] = round(float(SPEED.get("prefill_tps_ema") or 0) * 0.85, 2)

    # keep peaks across idle
    spd["decode_tps_peak"] = max(float(spd.get("decode_tps_peak") or 0), float(SPEED.get("decode_tps_peak") or 0))
    spd["prefill_tps_peak"] = max(float(spd.get("prefill_tps_peak") or 0), float(SPEED.get("prefill_tps_peak") or 0))

    SPEED.clear()
    SPEED.update(spd)
    return spd


def sampler() -> None:
    global PREV
    while True:
        now = time.time()
        point: dict = {"t": now, "gpus": [], "llama": {}, "system": {}, "speed": {}}
        try:
            point["gpus"] = query_gpus()
        except Exception as exc:  # noqa: BLE001
            point["gpu_error"] = str(exc)
        point["system"] = query_system()
        point["llama"] = query_llama()
        point["speed"] = update_speed(now, point["llama"])
        with LOCK:
            SAMPLES.append(point)
            del SAMPLES[:-HISTORY]
            PREV = {"t": now, "llama": dict(point["llama"])}
        time.sleep(1.0)


HTML = r"""<!doctype html>
<html lang="pt">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Inference Monitor</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
  <style>
    :root {
      color-scheme: dark;
      --bg:#0b1020; --card:rgba(24,32,48,.92); --line:rgba(255,255,255,.08);
      --text:#eef3ff; --muted:#93a4c3; --ok:#3ddc97; --warn:#ffb454; --bad:#ff6b6b;
    }
    * { box-sizing:border-box; }
    body {
      margin:0; font-family:"Segoe UI",system-ui,sans-serif; color:var(--text);
      background:
        radial-gradient(1200px 600px at 10% -10%, rgba(91,157,255,.18), transparent 50%),
        radial-gradient(900px 500px at 90% 0%, rgba(61,220,151,.12), transparent 45%),
        linear-gradient(180deg,#0b1020,#121a2b);
      min-height:100vh;
    }
    header {
      padding:16px 20px; display:flex; gap:12px; align-items:center; flex-wrap:wrap;
      border-bottom:1px solid var(--line); position:sticky; top:0; z-index:5;
      background:rgba(11,16,32,.8); backdrop-filter:blur(10px);
    }
    h1 { margin:0; font-size:18px; font-weight:700; letter-spacing:-.02em; }
    .muted { color:var(--muted); font-size:12px; }
    main { padding:16px; display:grid; gap:14px; }
    .section-title { font-size:12px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:2px 0 0; }
    .grid { display:grid; gap:12px; }
    .g-4 { grid-template-columns:repeat(4,minmax(0,1fr)); }
    .g-3 { grid-template-columns:repeat(3,minmax(0,1fr)); }
    .g-2 { grid-template-columns:repeat(2,minmax(0,1fr)); }
    @media (max-width:1100px){ .g-4{grid-template-columns:repeat(2,1fr);} .g-3{grid-template-columns:1fr;} }
    @media (max-width:720px){ .g-4,.g-2{grid-template-columns:1fr;} }
    .card {
      background:var(--card); border:1px solid var(--line); border-radius:16px;
      padding:14px 16px; box-shadow:0 10px 30px rgba(0,0,0,.25);
    }
    .card.wide { grid-column:1/-1; }
    .name { font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.05em; margin-bottom:6px; }
    .big { font-size:30px; font-weight:750; letter-spacing:-.03em; }
    .big.sm { font-size:24px; }
    .sub { margin-top:6px; font-size:12px; color:var(--muted); line-height:1.45; }
    .pill {
      display:inline-flex; align-items:center; gap:8px; padding:6px 10px; border-radius:999px;
      font-size:12px; font-weight:700; border:1px solid var(--line); background:rgba(255,255,255,.03);
    }
    .pill.ok{color:var(--ok); border-color:rgba(61,220,151,.35);}
    .pill.warn{color:var(--warn); border-color:rgba(255,180,84,.4);}
    .pill.bad{color:var(--bad); border-color:rgba(255,107,107,.4);}
    .dot{width:8px;height:8px;border-radius:50%;background:currentColor;box-shadow:0 0 10px currentColor;}
    .kv { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:8px; margin-top:10px; }
    .kv .item { background:rgba(255,255,255,.03); border:1px solid var(--line); border-radius:12px; padding:10px; }
    .kv .k { color:var(--muted); font-size:10px; text-transform:uppercase; letter-spacing:.05em; }
    .kv .v { margin-top:3px; font-size:13px; font-weight:650; word-break:break-word; }
    .charts { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    @media (max-width:1100px){ .charts{grid-template-columns:1fr;} }
    .chart-wrap { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:10px 12px 6px; }
    canvas { width:100%!important; max-height:230px; }
    .bar { height:8px; border-radius:99px; background:rgba(255,255,255,.06); overflow:hidden; margin-top:8px; }
    .bar > i { display:block; height:100%; background:linear-gradient(90deg,#3ddc97,#5b9dff); border-radius:99px; }
  </style>
</head>
<body>
  <header>
    <h1>Inference Monitor</h1>
    <span id="livePill" class="pill ok"><span class="dot"></span>LIVE</span>
    <span class="muted" id="status">a ligar…</span>
    <span class="muted" style="margin-left:auto">GPU · RAM · llama-server · tok/s</span>
  </header>
  <main>
    <div class="section-title">Velocidade</div>
    <div class="grid g-4" id="speedCards"></div>

    <div class="section-title">Inferência</div>
    <div class="grid g-1" id="inferCards"></div>

    <div class="section-title">Hardware</div>
    <div class="grid g-3" id="hwCards"></div>

    <div class="section-title">Gráficos</div>
    <div class="charts">
      <div class="chart-wrap"><canvas id="tpsChart"></canvas></div>
      <div class="chart-wrap"><canvas id="utilChart"></canvas></div>
      <div class="chart-wrap"><canvas id="powerChart"></canvas></div>
      <div class="chart-wrap"><canvas id="memChart"></canvas></div>
    </div>
  </main>
  <script>
    const colors = ['#3ddc97','#5b9dff','#ffb454','#ff6b6b'];
    function opts(title, yMax) {
      return {
        animation:false, responsive:true,
        scales:{
          x:{ type:'linear', ticks:{color:'#93a4c3'}, grid:{color:'rgba(255,255,255,.05)'} },
          y:{ min:0, max:yMax, ticks:{color:'#93a4c3'}, grid:{color:'rgba(255,255,255,.05)'},
              title:{display:true, text:title, color:'#93a4c3'} }
        },
        plugins:{ legend:{ labels:{ color:'#eef3ff' } }, title:{ display:true, text:title, color:'#eef3ff' } }
      };
    }
    const tpsChart = new Chart(document.getElementById('tpsChart'), {
      type:'line', data:{ datasets:[
        { label:'Decode tok/s', data:[], borderColor:'#3ddc97', backgroundColor:'transparent', borderWidth:2, pointRadius:0, tension:.2 },
        { label:'Prefill tok/s', data:[], borderColor:'#5b9dff', backgroundColor:'transparent', borderWidth:2, pointRadius:0, tension:.2 }
      ]}, options:opts('Tokens / segundo')
    });
    const utilChart = new Chart(document.getElementById('utilChart'), { type:'line', data:{datasets:[]}, options:opts('GPU Util %', 100) });
    const powerChart = new Chart(document.getElementById('powerChart'), { type:'line', data:{datasets:[]}, options:opts('Potência W') });
    const memChart = new Chart(document.getElementById('memChart'), { type:'line', data:{datasets:[]}, options:opts('VRAM MiB') });

    function ensureGpuDatasets(n, names) {
      for (const chart of [utilChart, powerChart, memChart]) {
        while (chart.data.datasets.length < n) {
          const i = chart.data.datasets.length;
          chart.data.datasets.push({
            label: names[i] || ('GPU '+i), data:[], borderColor:colors[i%colors.length],
            backgroundColor:'transparent', borderWidth:2, pointRadius:0, tension:.2
          });
        }
      }
    }
    function pill(state, label){ return `<span class="pill ${state}"><span class="dot"></span>${label}</span>`; }
    function fmtBytes(b){
      if (!b) return '-';
      return (b/1024/1024/1024).toFixed(2) + ' GB';
    }
    function fmtParamsSafe(n){
      if (!n) return '-';
      if (n >= 1e9) return (n/1e9).toFixed(1) + 'B';
      if (n >= 1e6) return (n/1e6).toFixed(1) + 'M';
      return String(n);
    }

    async function tick(){
      try {
        const hist = await (await fetch('/api/history')).json();
        if (!hist.length) return;
        const latest = hist[hist.length-1];
        const t0 = hist[0].t;
        const gpus = latest.gpus || [];
        const llama = latest.llama || {};
        const speed = latest.speed || {};
        const sys = latest.system || {};
        const names = gpus.map(g => g.index + ': ' + g.name.replace('NVIDIA GeForce ',''));
        ensureGpuDatasets(names.length, names);

        // Speed cards
        document.getElementById('speedCards').innerHTML = `
          <div class="card"><div class="name">Decode agora</div><div class="big">${(speed.decode_tps||0).toFixed(1)}</div><div class="sub">tok/s (instantâneo)</div></div>
          <div class="card"><div class="name">Decode EMA</div><div class="big sm">${(speed.decode_tps_ema||0).toFixed(1)}</div><div class="sub">suave · pico ${(speed.decode_tps_peak||0).toFixed(1)}</div></div>
          <div class="card"><div class="name">Prefill agora</div><div class="big">${(speed.prefill_tps||0).toFixed(1)}</div><div class="sub">tok/s prompt · EMA ${(speed.prefill_tps_ema||0).toFixed(1)}</div></div>
          <div class="card"><div class="name">Último pedido (log)</div><div class="big sm">${(speed.last_completed_decode_tps||0).toFixed(1)}</div><div class="sub">decode · prefill ${(speed.last_completed_prefill_tps||0).toFixed(1)} tok/s</div></div>`;

        let statePill = pill('bad','OFFLINE');
        if (llama.ok && llama.processing && llama.phase==='prefill') statePill = pill('warn','PREFILL');
        else if (llama.ok && llama.processing) statePill = pill('warn','DECODE');
        else if (llama.ok) statePill = pill('ok','IDLE');

        const progPrompt = llama.prompt_tokens ? Math.min(100, 100*llama.prompt_processed/llama.prompt_tokens) : 0;
        const progGen = llama.n_predict ? Math.min(100, 100*llama.decoded/llama.n_predict) : 0;

        document.getElementById('inferCards').innerHTML = `
          <div class="card wide">
            <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
              ${statePill}
              <div class="name" style="margin:0">llama-server · :11434</div>
              <span class="muted">${llama.error || ''}</span>
            </div>
            <div class="kv">
              <div class="item"><div class="k">Model</div><div class="v">${llama.model||'-'}</div></div>
              <div class="item"><div class="k">Status</div><div class="v">${llama.model_status||'-'}</div></div>
              <div class="item"><div class="k">Worker</div><div class="v">:${llama.worker_port||'-'}</div></div>
              <div class="item"><div class="k">Build</div><div class="v">${llama.build_info||'-'}</div></div>
              <div class="item"><div class="k">FType</div><div class="v">${llama.model_ftype||'-'}</div></div>
              <div class="item"><div class="k">Params</div><div class="v">${fmtParamsSafe(llama.n_params)}</div></div>
              <div class="item"><div class="k">GGUF size</div><div class="v">${fmtBytes(llama.model_size_bytes)}</div></div>
              <div class="item"><div class="k">Path</div><div class="v">${(llama.model_path||'-').split('\\\\').pop()}</div></div>
              <div class="item"><div class="k">n_ctx / train</div><div class="v">${llama.n_ctx||0} / ${llama.context_length||0}</div></div>
              <div class="item"><div class="k">Task</div><div class="v">${llama.task_id??'-'}</div></div>
              <div class="item"><div class="k">Format</div><div class="v">${llama.chat_format||'-'}${llama.thinking?' + think':''}</div></div>
              <div class="item"><div class="k">Reasoning</div><div class="v">${llama.reasoning_format||'-'}</div></div>
              <div class="item"><div class="k">Stream</div><div class="v">${llama.stream?'yes':'no'}</div></div>
              <div class="item"><div class="k">Speculative</div><div class="v">${llama.speculative?'yes':'no'}</div></div>
              <div class="item"><div class="k">Temp / top_p / top_k</div><div class="v">${llama.temperature??'-'} / ${llama.top_p??'-'} / ${llama.top_k??'-'}</div></div>
              <div class="item"><div class="k">n_predict / max</div><div class="v">${llama.n_predict||0} / ${llama.max_tokens||0}</div></div>
            </div>
            <div class="kv" style="margin-top:8px">
              <div class="item">
                <div class="k">Prompt progress</div>
                <div class="v">${llama.prompt_processed||0} / ${llama.prompt_tokens||0} · cache ${llama.prompt_cache||0}</div>
                <div class="bar"><i style="width:${progPrompt.toFixed(1)}%"></i></div>
              </div>
              <div class="item">
                <div class="k">Generation progress</div>
                <div class="v">decoded ${llama.decoded||0} · remain ${llama.remain||0}</div>
                <div class="bar"><i style="width:${progGen.toFixed(1)}%"></i></div>
              </div>
              <div class="item"><div class="k">Decode tok/s</div><div class="v" style="font-size:22px;color:#3ddc97">${(speed.decode_tps||0).toFixed(1)}</div></div>
              <div class="item"><div class="k">Prefill tok/s</div><div class="v" style="font-size:22px;color:#5b9dff">${(speed.prefill_tps||0).toFixed(1)}</div></div>
            </div>
          </div>`;

        const ramPct = sys.ram_load_pct || 0;
        document.getElementById('hwCards').innerHTML = `
          <div class="card">
            <div class="name">System RAM</div>
            <div class="big sm">${(sys.ram_used_gb||0).toFixed(1)} <span class="muted" style="font-size:14px">/ ${(sys.ram_total_gb||0).toFixed(1)} GB</span></div>
            <div class="sub">livre ${(sys.ram_free_gb||0).toFixed(1)} GB · load ${ramPct.toFixed(0)}%</div>
            <div class="bar"><i style="width:${ramPct}%"></i></div>
          </div>
          ${gpus.map(g => `
            <div class="card">
              <div class="name">GPU ${g.index} · ${g.name.replace('NVIDIA GeForce ','')}</div>
              <div class="big">${g.util.toFixed(0)}%</div>
              <div class="sub">
                VRAM ${g.mem_used.toFixed(0)} / ${g.mem_total.toFixed(0)} MiB (free ${g.mem_free.toFixed(0)})<br>
                ${g.power.toFixed(0)} / ${g.power_limit.toFixed(0)} W · ${g.temp.toFixed(0)} °C · fan ${g.fan||0}%<br>
                clocks SM ${g.clock_sm||0} · MEM ${g.clock_mem||0} · PCIe gen${g.pcie_gen||'?'} x${g.pcie_width||'?'}
              </div>
              <div class="bar"><i style="width:${Math.min(100,g.util)}%"></i></div>
            </div>`).join('')}`;

        // charts
        tpsChart.data.datasets[0].data = hist.map(p => ({x:+(p.t-t0).toFixed(1), y:p.speed?.decode_tps ?? 0}));
        tpsChart.data.datasets[1].data = hist.map(p => ({x:+(p.t-t0).toFixed(1), y:p.speed?.prefill_tps ?? 0}));
        tpsChart.update('none');
        for (let i=0;i<names.length;i++){
          utilChart.data.datasets[i].label = names[i];
          powerChart.data.datasets[i].label = names[i];
          memChart.data.datasets[i].label = names[i];
          utilChart.data.datasets[i].data = hist.map(p => ({x:+(p.t-t0).toFixed(1), y:p.gpus?.[i]?.util ?? null}));
          powerChart.data.datasets[i].data = hist.map(p => ({x:+(p.t-t0).toFixed(1), y:p.gpus?.[i]?.power ?? null}));
          memChart.data.datasets[i].data = hist.map(p => ({x:+(p.t-t0).toFixed(1), y:p.gpus?.[i]?.mem_used ?? null}));
        }
        utilChart.update('none'); powerChart.update('none'); memChart.update('none');
        document.getElementById('status').textContent = new Date(latest.t*1000).toLocaleTimeString();
        document.getElementById('livePill').className = 'pill ' + (llama.ok ? (llama.processing?'warn':'ok') : 'bad');
        document.getElementById('livePill').innerHTML = `<span class="dot"></span>${llama.ok?(llama.processing?'BUSY':'LIVE'):'DOWN'}`;
      } catch(e) {
        document.getElementById('status').textContent = String(e);
      }
    }
    setInterval(tick, 1000);
    tick();
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            body = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/history":
            with LOCK:
                payload = list(SAMPLES)
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/now":
            with LOCK:
                payload = SAMPLES[-1] if SAMPLES else {"gpus": [], "llama": {}, "speed": {}, "system": {}}
            body = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    threading.Thread(target=sampler, daemon=True).start()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f"Inference Monitor: {url}")
    if not args.no_browser:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    httpd.serve_forever()


if __name__ == "__main__":
    main()
