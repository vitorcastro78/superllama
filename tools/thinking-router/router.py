"""
Thinking Router — classifica thinking on/off com GLiNER2.5-Decide
e reencaminha para llama-server sem recarregar o modelo grande.

Fluxo:
  Cliente → :11437 → GLiNER (GPU 3050) → inject enable_thinking
                   → :11434 llama-server (Qwen na 3060)
"""
from __future__ import annotations

import json
import logging
import os
import re
from contextlib import asynccontextmanager
from typing import Any

import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

load_dotenv(os.path.join(os.path.dirname(__file__), "config.env"))

UPSTREAM = os.getenv("UPSTREAM", "http://127.0.0.1:11434").rstrip("/")
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "11437"))
CUDA_DEVICE = os.getenv("CUDA_DEVICE", "auto").strip().lower()
GLINER_MODEL = os.getenv("GLINER_MODEL", "fastino/GLiNER2.5-Decide")
RESPECT_CLIENT = os.getenv("RESPECT_CLIENT_FLAG", "1") not in ("0", "false", "off", "no")
LOG_DECISIONS = os.getenv("LOG_DECISIONS", "1") not in ("0", "false", "off", "no")
# Fast regex short-circuit. Default OFF so GLiNER actually runs (agents almost
# always send tools / code keywords and otherwise never hit the decision model).
USE_HEURISTIC = os.getenv("USE_HEURISTIC", "0") not in ("0", "false", "off", "no")
# If 1, presence of tools/functions still forces thinking_off when heuristics on.
HEURISTIC_TOOLS_OFF = os.getenv("HEURISTIC_TOOLS_OFF", "0") not in ("0", "false", "off", "no")
# Raise client max_tokens/n_predict when missing or below this (agent write cuts).
# Set MIN_MAX_TOKENS=0 to disable.
try:
    MIN_MAX_TOKENS = int(os.getenv("MIN_MAX_TOKENS", "16384"))
except ValueError:
    MIN_MAX_TOKENS = 16384


def apply_min_max_tokens(body: dict[str, Any]) -> tuple[dict[str, Any], str | None]:
    """Ensure generation budget is high enough for large tool writes."""
    if MIN_MAX_TOKENS <= 0:
        return body, None
    out = dict(body)
    note: str | None = None
    cur = out.get("max_tokens")
    if cur is None:
        cur = out.get("max_completion_tokens")
    if cur is None:
        cur = out.get("n_predict")
    try:
        cur_i = int(cur) if cur is not None else None
    except (TypeError, ValueError):
        cur_i = None
    if cur_i is None or cur_i < MIN_MAX_TOKENS:
        out["max_tokens"] = MIN_MAX_TOKENS
        if "n_predict" in out or cur_i is not None:
            out["n_predict"] = MIN_MAX_TOKENS
        note = f"max_tokens {cur_i!r}->{MIN_MAX_TOKENS}"
    return out, note

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("thinking-router")


def resolve_cuda_visible() -> str | None:
    """Return physical GPU index for CUDA_VISIBLE_DEVICES, or None for CPU."""
    if CUDA_DEVICE in ("", "cpu", "none"):
        return None
    if CUDA_DEVICE == "auto":
        try:
            import torch

            n = torch.cuda.device_count() if torch.cuda.is_available() else 0
            if n <= 0:
                return None
            # Prefer secondary GPU so llama-server can keep GPU0
            return str(n - 1 if n >= 2 else 0)
        except Exception:
            return None
    return CUDA_DEVICE

# Labels zero-shot para o teu use-case (coding vs raciocínio)
CLASSIFY_SCHEMA: dict[str, Any] = {
    "mode": {
        "labels": {
            "thinking_off": (
                "Write, edit, refactor, or fix code; implement a function; apply a patch; "
                "produce diffs; autocomplete; short direct answer; run tools; JSON/tool calls; "
                "coding agent task; generate code without long explanation"
            ),
            "thinking_on": (
                "Explain why; architecture design; tradeoffs; deep debugging root cause; "
                "plan a system; reason step by step; compare approaches; "
                "non-trivial analysis that needs chain-of-thought"
            ),
        }
    }
}

# Heurística rápida (antes do GLiNER) — barata e estável
CODE_HINTS = re.compile(
    r"(```|diff --git|\bdef |\bclass |\bfunction\b|\bimplement\b|\brefactor\b|"
    r"\bfix(es|ed)?\b|\bpatch\b|\bPR\b|\btypescript\b|\bpython\b|\.tsx?\b|\.py\b|"
    r"\bwrite code\b|\bcodifica|\bimplementa|\bcorrige o bug\b)",
    re.I,
)
THINK_HINTS = re.compile(
    r"(\bwhy\b|\bexplain\b|\barchitecture\b|\btrade-?off\b|\bcompara\b|\bexplica\b|"
    r"\bporqu[eê]\b|\bdesenha (a|o) (arquitetura|sistema)\b|\banalis[ea]\b|"
    r"\bstep by step\b|\braciocin)",
    re.I,
)

_extractor = None
_http: httpx.AsyncClient | None = None


def _pick_device() -> str:
    if resolve_cuda_visible() is None and CUDA_DEVICE in ("", "cpu", "none", "auto"):
        # auto may still have set CUDA_VISIBLE_DEVICES in lifespan
        pass
    try:
        import torch

        if torch.cuda.is_available() and torch.cuda.device_count() > 0:
            return "cuda:0"
    except Exception as e:
        log.warning("CUDA check failed: %s — using CPU", e)
    return "cpu"


def load_classifier() -> None:
    global _extractor
    if _extractor is not None:
        return
    from gliner2 import AutoExtractor

    device = _pick_device()
    log.info("Loading %s on %s …", GLINER_MODEL, device)
    _extractor = AutoExtractor.from_pretrained(GLINER_MODEL)
    # Prefer GPU when available
    try:
        if hasattr(_extractor, "model") and device.startswith("cuda"):
            import torch

            _extractor.model.to(torch.device(device))
    except Exception as e:
        log.warning("Could not move GLiNER to %s: %s (staying default)", device, e)
    log.info("GLiNER ready")


def extract_user_text(body: dict[str, Any]) -> str:
    parts: list[str] = []
    for m in body.get("messages") or []:
        role = (m.get("role") or "").lower()
        if role not in ("user", "system"):
            continue
        content = m.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(str(block.get("text") or ""))
                elif isinstance(block, str):
                    parts.append(block)
    # Prefer last user message; keep a bit of system for context
    text = "\n".join(parts[-3:]).strip()
    return text[:6000] if text else ""


def heuristic_mode(text: str, body: dict[str, Any]) -> str | None:
    """Return 'thinking_off' / 'thinking_on' or None to defer to GLiNER."""
    if not USE_HEURISTIC:
        return None
    tools = body.get("tools") or body.get("functions")
    if tools and HEURISTIC_TOOLS_OFF:
        # Optional: agent/tool loops without CoT (skips GLiNER entirely)
        return "thinking_off"
    if not text:
        return "thinking_off"
    code = bool(CODE_HINTS.search(text))
    think = bool(THINK_HINTS.search(text))
    if code and not think:
        return "thinking_off"
    if think and not code:
        return "thinking_on"
    return None


def classify_thinking(text: str, body: dict[str, Any]) -> tuple[bool, str]:
    """
    Returns (enable_thinking, reason).
    """
    h = heuristic_mode(text, body)
    if h is not None:
        return (h == "thinking_on", f"heuristic:{h}")

    if _extractor is None:
        return (False, "fallback:no_classifier")

    try:
        result = _extractor.classify_text(text or "empty", CLASSIFY_SCHEMA)
        mode = result.get("mode") if isinstance(result, dict) else None
        if isinstance(mode, list):
            mode = mode[0] if mode else None
        if mode == "thinking_on":
            return (True, "gliner:thinking_on")
        if mode == "thinking_off":
            return (False, "gliner:thinking_off")
        # Unknown shape — default off (faster, safer for coding stack)
        return (False, f"gliner:unknown:{mode!r}")
    except Exception as e:
        log.exception("GLiNER classify failed")
        return (False, f"error:{e}")


def client_already_set(body: dict[str, Any]) -> bool | None:
    kwargs = body.get("chat_template_kwargs")
    if isinstance(kwargs, dict) and "enable_thinking" in kwargs:
        return bool(kwargs["enable_thinking"])
    if "reasoning_budget_tokens" in body:
        try:
            return int(body["reasoning_budget_tokens"]) != 0
        except (TypeError, ValueError):
            pass
    if "thinking_budget_tokens" in body:
        try:
            return int(body["thinking_budget_tokens"]) != 0
        except (TypeError, ValueError):
            pass
    return None


def apply_thinking_flag(body: dict[str, Any], enable: bool) -> dict[str, Any]:
    out = dict(body)
    kwargs = dict(out.get("chat_template_kwargs") or {})
    kwargs["enable_thinking"] = enable
    out["chat_template_kwargs"] = kwargs
    if not enable:
        # Belt-and-suspenders for builds that prefer budget=0
        out.setdefault("reasoning_budget_tokens", 0)
        out.setdefault("thinking_budget_tokens", 0)
    return out


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _http
    # Isolate GLiNER on the chosen physical GPU before torch init
    if "CUDA_VISIBLE_DEVICES" not in os.environ:
        vis = resolve_cuda_visible()
        if vis is not None:
            os.environ["CUDA_VISIBLE_DEVICES"] = vis
            log.info("CUDA_VISIBLE_DEVICES=%s (from CUDA_DEVICE=%s)", vis, CUDA_DEVICE)
        else:
            os.environ["CUDA_VISIBLE_DEVICES"] = ""
            log.info("GLiNER on CPU (CUDA_DEVICE=%s)", CUDA_DEVICE)
    load_classifier()
    _http = httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=10.0))
    log.info("Thinking router up → upstream %s", UPSTREAM)
    yield
    await _http.aclose()


app = FastAPI(title="Thinking Router", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "ok": True,
        "upstream": UPSTREAM,
        "classifier": GLINER_MODEL,
        "cuda_device": CUDA_DEVICE or "cpu",
        "loaded": _extractor is not None,
    }


@app.get("/router/decide")
async def decide_preview(q: str):
    """Debug: classifica uma string sem chamar o LLM."""
    enable, reason = classify_thinking(q, {})
    return {"enable_thinking": enable, "reason": reason, "query": q}


async def _proxy_raw(request: Request, path: str) -> Response:
    assert _http is not None
    url = f"{UPSTREAM}{path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length")
    }
    body = await request.body()
    upstream = await _http.request(request.method, url, content=body, headers=headers)
    excluded = {"content-encoding", "transfer-encoding", "content-length"}
    out_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in excluded}
    return Response(content=upstream.content, status_code=upstream.status_code, headers=out_headers)


@app.api_route("/v1/models", methods=["GET", "POST"])
@app.api_route("/v1/models/{rest:path}", methods=["GET", "POST", "DELETE"])
@app.api_route("/props", methods=["GET"])
@app.api_route("/slots", methods=["GET"])
async def passthrough(request: Request, rest: str = ""):
    return await _proxy_raw(request, request.url.path)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    assert _http is not None
    raw = await request.body()
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        return Response(content=raw, status_code=400, media_type="application/json")

    existing = client_already_set(body)
    if RESPECT_CLIENT and existing is not None:
        enable = existing
        reason = "client"
    else:
        text = extract_user_text(body)
        enable, reason = classify_thinking(text, body)

    body = apply_thinking_flag(body, enable)
    body, max_note = apply_min_max_tokens(body)
    if LOG_DECISIONS:
        n_tools = 0
        tools = body.get("tools") or body.get("functions")
        if isinstance(tools, list):
            n_tools = len(tools)
        log.info(
            "decide enable_thinking=%s reason=%s model=%s max_tokens=%s n_predict=%s tools=%s %s",
            enable,
            reason,
            body.get("model"),
            body.get("max_tokens"),
            body.get("n_predict"),
            n_tools,
            max_note or "",
        )

    stream = bool(body.get("stream"))
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length")
    }
    headers["content-type"] = "application/json"
    payload = json.dumps(body).encode("utf-8")

    if stream:
        req = _http.build_request(
            "POST",
            f"{UPSTREAM}/v1/chat/completions",
            content=payload,
            headers=headers,
        )
        upstream = await _http.send(req, stream=True)

        async def gen():
            try:
                async for chunk in upstream.aiter_bytes():
                    yield chunk
            finally:
                await upstream.aclose()

        out_h = {
            k: v
            for k, v in upstream.headers.items()
            if k.lower() not in ("content-encoding", "transfer-encoding", "content-length")
        }
        # Expose decision to client for debugging
        out_h["x-thinking-router"] = "on" if enable else "off"
        out_h["x-thinking-reason"] = reason
        return StreamingResponse(gen(), status_code=upstream.status_code, headers=out_h, media_type="text/event-stream")

    upstream = await _http.post(
        f"{UPSTREAM}/v1/chat/completions",
        content=payload,
        headers=headers,
    )
    excluded = {"content-encoding", "transfer-encoding", "content-length"}
    out_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in excluded}
    out_headers["x-thinking-router"] = "on" if enable else "off"
    out_headers["x-thinking-reason"] = reason
    return Response(content=upstream.content, status_code=upstream.status_code, headers=out_headers)


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def catch_all(request: Request, path: str):
    """Resto dos endpoints do llama-server (webui, etc.)."""
    if request.url.path.rstrip("/") in ("", "/"):
        return {
            "service": "thinking-router",
            "upstream": UPSTREAM,
            "endpoints": {
                "chat": "/v1/chat/completions",
                "decide": "/router/decide?q=...",
                "health": "/health",
            },
        }
    return await _proxy_raw(request, "/" + path)


def main() -> None:
    import uvicorn

    if "CUDA_VISIBLE_DEVICES" not in os.environ:
        vis = resolve_cuda_visible()
        if vis is not None:
            os.environ["CUDA_VISIBLE_DEVICES"] = vis
    uvicorn.run(
        "router:app",
        host=HOST,
        port=PORT,
        reload=False,
        log_level="info",
    )


if __name__ == "__main__":
    main()
