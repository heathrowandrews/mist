"""Bloom Dictate daemon — local push-to-talk transcription with glossary biasing.

Endpoints:
  GET  /health
  GET  /tenants/:id/glossary  (bearer auth)
  POST /transcribe            (bearer auth, multipart)

Loaded once at startup: whisper model, all tenant configs.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile

from tenants import TenantConfig, build_initial_prompt, load_tenant


# --- Config ----------------------------------------------------------------

HOST = os.environ.get("BLOOM_DICTATE_HOST", "127.0.0.1")
PORT = int(os.environ.get("BLOOM_DICTATE_PORT", "8788"))
TOKEN = os.environ.get("BLOOM_DICTATE_TOKEN", "")
DEFAULT_MODEL = os.environ.get(
    "BLOOM_DICTATE_MODEL", "mlx-community/whisper-large-v3-turbo"
)
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
DATA_DIR = Path(os.environ.get("BLOOM_DICTATE_DATA", str(Path.home() / ".bloom-dictate")))
CONFIG_DIR = DATA_DIR / "config"
HISTORY_DIR = DATA_DIR / "history"
AUDIO_DIR = DATA_DIR / "audio"
LOG_DIR = DATA_DIR / "logs"

VERSION = "1.0.0"
START_TS = time.time()

MAX_AUDIO_BYTES = 25 * 1024 * 1024  # 25 MB
ALLOWED_EXT = {"m4a", "mp3", "wav", "aiff", "webm", "mp4", "ogg", "flac"}

# Loaded at startup
_models: dict[str, Any] = {}
_tenants: dict[str, TenantConfig] = {}


# --- Lifecycle -------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    for d in (DATA_DIR, CONFIG_DIR, HISTORY_DIR, AUDIO_DIR, LOG_DIR):
        d.mkdir(parents=True, exist_ok=True)

    for f in sorted(CONFIG_DIR.glob("*.yaml")):
        try:
            t = load_tenant(f)
            _tenants[t.tenant_id] = t
            print(f"[startup] loaded tenant: {t.tenant_id} ({len(t.terms)} terms, {len(t.phrases)} phrases)", flush=True)
        except Exception as e:
            print(f"[startup] FAILED to load tenant {f}: {e}", flush=True)

    print(f"[startup] loading default model: {DEFAULT_MODEL}", flush=True)
    t0 = time.time()
    _load_model(DEFAULT_MODEL)
    print(f"[startup] model ready in {time.time()-t0:.1f}s", flush=True)
    print(f"[startup] bind {HOST}:{PORT} | tenants={list(_tenants.keys())}", flush=True)
    yield
    print("[shutdown] bye", flush=True)


app = FastAPI(title="Bloom Dictate", version=VERSION, lifespan=lifespan)


def _load_model(name: str):
    if name not in _models:
        from mlx_audio.stt.utils import load_model as _load
        _models[name] = _load(name)
    return _models[name]


# --- Auth ------------------------------------------------------------------

def check_auth(authorization: Optional[str]):
    if not TOKEN:
        return  # auth disabled (dev only — DO NOT run in prod without token)
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    if authorization[7:].strip() != TOKEN:
        raise HTTPException(status_code=401, detail="bad bearer token")


# --- Endpoints -------------------------------------------------------------

@app.get("/health")
def health():
    return {
        "ok": True,
        "version": VERSION,
        "engine": "mlx-audio",
        "model": DEFAULT_MODEL,
        "tenants_loaded": list(_tenants.keys()),
        "uptime_seconds": int(time.time() - START_TS),
    }


@app.get("/tenants/{tenant_id}/glossary")
def get_glossary(tenant_id: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    if tenant_id not in _tenants:
        raise HTTPException(404, f"unknown tenant: {tenant_id}")
    t = _tenants[tenant_id]
    return {
        "tenant_id": t.tenant_id,
        "display_name": t.display_name,
        "language": t.language,
        "model": t.model,
        "terms": t.terms,
        "phrases": t.phrases,
        "post_correction_enabled": t.post_correction.enabled,
        "prompt_mode_enabled": t.prompt_mode.enabled,
    }


@app.post("/transcribe")
async def transcribe(
    request: Request,
    audio: UploadFile = File(...),
    tenant_id: str = Form(...),
    mode: str = Form("raw"),
    language: Optional[str] = Form(None),
    correct: str = Form("true"),  # "false" skips Ollama post-correction (streaming)
    authorization: Optional[str] = Header(None),
):
    check_auth(authorization)

    if tenant_id not in _tenants:
        raise HTTPException(404, f"unknown tenant: {tenant_id}")
    if mode not in {"raw", "prompt"}:
        raise HTTPException(400, f"invalid mode: {mode}")

    tenant = _tenants[tenant_id]
    do_correct = correct.lower() not in ("false", "0", "no")

    raw_bytes = await audio.read()
    if len(raw_bytes) > MAX_AUDIO_BYTES:
        raise HTTPException(413, f"audio > {MAX_AUDIO_BYTES} bytes")

    fname = audio.filename or "upload.bin"
    ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else "bin"
    if ext not in ALLOWED_EXT:
        raise HTTPException(415, f"unsupported audio format: {ext}")

    request_id = uuid.uuid4().hex
    inflight_dir = AUDIO_DIR / "_inflight"
    inflight_dir.mkdir(parents=True, exist_ok=True)
    tmp_path = inflight_dir / f"{request_id}.{ext}"
    tmp_path.write_bytes(raw_bytes)

    try:
        t0 = time.time()
        initial_prompt = build_initial_prompt(tenant)
        model_name = tenant.model or DEFAULT_MODEL
        model = _load_model(model_name)

        # Streaming mode (correct=false) uses aggressive anti-hallucination
        # params. The default condition_on_previous_text=True is the #1 cause
        # of repeat loops on short/silent chunks ("for the whole point. for
        # the whole point...").
        gen_kwargs = dict(
            language=language or tenant.language,
            initial_prompt=initial_prompt,
        )
        if not do_correct:
            gen_kwargs.update(
                condition_on_previous_text=False,
                compression_ratio_threshold=2.0,
                no_speech_threshold=0.45,
                temperature=0.0,
            )
        result = model.generate(str(tmp_path), **gen_kwargs)
        raw_text = (getattr(result, "text", "") or "").strip()
        audio_seconds = float(getattr(result, "total_time", 0.0) or 0.0)

        corrected = raw_text
        if do_correct and tenant.post_correction.enabled and raw_text:
            try:
                corrected = await _ollama_correct(raw_text, tenant)
            except Exception as e:
                print(f"[transcribe] post-correct failed: {e}", flush=True)

        structured = None
        model_tag = model_name
        if mode == "prompt" and tenant.prompt_mode.enabled:
            try:
                structured = await _ollama_prompt(corrected, tenant)
                model_tag = f"{model_name} + {tenant.prompt_mode.model}"
            except Exception as e:
                print(f"[transcribe] prompt-mode failed: {e}", flush=True)
        elif tenant.post_correction.enabled and corrected != raw_text:
            model_tag = f"{model_name} + {tenant.post_correction.model}"

        duration_ms = int((time.time() - t0) * 1000)

        result_json = {
            "raw": raw_text,
            "corrected": corrected,
            "structured": structured,
            "model": model_tag,
            "tenant": tenant_id,
            "duration_ms": duration_ms,
            "audio_seconds": audio_seconds,
            "request_id": request_id,
        }

        client_ip = request.client.host if request and request.client else None
        _write_history(tenant_id, {
            "ts": datetime.now(timezone.utc).isoformat(),
            "request_id": request_id,
            "tenant": tenant_id,
            "mode": mode,
            "audio_seconds": audio_seconds,
            "duration_ms": duration_ms,
            "raw": raw_text,
            "corrected": corrected,
            "structured": structured,
            "client_ip": client_ip,
        })

        if tenant.keep_audio:
            keep_dir = AUDIO_DIR / tenant_id
            keep_dir.mkdir(parents=True, exist_ok=True)
            tmp_path.rename(keep_dir / f"{request_id}.{ext}")
        else:
            tmp_path.unlink(missing_ok=True)

        return result_json

    except HTTPException:
        tmp_path.unlink(missing_ok=True)
        raise
    except Exception as e:
        tmp_path.unlink(missing_ok=True)
        print(f"[transcribe] engine error: {e}", flush=True)
        raise HTTPException(500, f"engine error: {e}")


# --- Ollama integration ----------------------------------------------------

async def _ollama_correct(raw: str, tenant: TenantConfig) -> str:
    pc = tenant.post_correction
    payload = {
        "model": pc.model,
        "messages": [
            {"role": "system", "content": pc.system_prompt},
            {"role": "user", "content": raw},
        ],
        "stream": False,
        "options": {"temperature": 0.1},
    }
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post(f"{OLLAMA_URL}/api/chat", json=payload)
        r.raise_for_status()
        data = r.json()
        return data["message"]["content"].strip()


async def _ollama_prompt(corrected: str, tenant: TenantConfig) -> Optional[dict]:
    pm = tenant.prompt_mode
    payload = {
        "model": pm.model,
        "messages": [
            {"role": "system", "content": pm.system_prompt},
            {"role": "user", "content": corrected},
        ],
        "stream": False,
        "format": "json",
        "options": {"temperature": 0.1},
    }
    async with httpx.AsyncClient(timeout=60.0) as client:
        r = await client.post(f"{OLLAMA_URL}/api/chat", json=payload)
        r.raise_for_status()
        data = r.json()
        text = data["message"]["content"].strip()
        try:
            return json.loads(text)
        except json.JSONDecodeError as e:
            print(f"[ollama_prompt] JSON parse failed: {e}\n  text: {text[:200]}", flush=True)
            return None


# --- History ---------------------------------------------------------------

def _write_history(tenant_id: str, entry: dict):
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    path = HISTORY_DIR / tenant_id / f"{today}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


# --- Entry -----------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT)
