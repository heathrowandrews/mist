# Mist server

Local push-to-talk transcription daemon. See `../docs/spec.md` for the API contract.

## Reuses
- Python 3.12 environment with mlx-audio, fastapi, uvicorn, httpx, pydantic, pyyaml, python-multipart
- HuggingFace cache for `mlx-community/whisper-large-v3-turbo`
- Optional Ollama at `http://localhost:11434` for post-correction

## Layout
- `main.py` — FastAPI app, endpoints, mlx-audio integration, Ollama post-correction + prompt-mode
- `tenants.py` — Pydantic config schema + glossary -> initial_prompt builder
- `launchd/com.bloom.mist.plist` — example launchd unit

## Environment
Set in launchd plist; can be overridden in shell for dev:
- `BLOOM_DICTATE_HOST` (default `127.0.0.1`)
- `BLOOM_DICTATE_PORT` (default `8788`)
- `BLOOM_DICTATE_TOKEN` — bearer token, usually sourced from `~/.bloom-env`
- `BLOOM_DICTATE_ALLOW_NO_AUTH=1` — explicit local-dev override for running without a token
- `BLOOM_DICTATE_DATA` (default `~/.bloom-dictate`)
- `BLOOM_DICTATE_MODEL` (default `mlx-community/whisper-large-v3-turbo`)
- `OLLAMA_URL` (default `http://localhost:11434`)

## Dev run
```
cd server
BLOOM_DICTATE_TOKEN=$(openssl rand -hex 32) \
  python3 -m uvicorn main:app --host 127.0.0.1 --port 8788
```

Copy `configs/example.yaml` to `~/.bloom-dictate/config/default.yaml` before first run.
