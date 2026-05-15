# Mist — Daemon Spec

**Version:** 1.0
**Date:** 2026-05-08
**Owner:** local operator

## Mission
Stand up a local Mist daemon. It is a push-to-talk transcription service with per-tenant glossary biasing and optional Ollama post-correction.

## Deployment

- **Host:** your local Mac or a private LAN/Tailscale machine
- **launchd label:** `com.bloom.mist`
- **Working directory:** wherever you clone the repo
- **Port:** 8788 by default
- **Bind:** default to `127.0.0.1`. If exposing over Tailscale/LAN, bind only to that private interface and keep bearer auth enabled. Do not expose directly to the public internet.
- **Logs:** `~/.bloom-dictate/logs/server.log`

## Auth

- Bearer token in env var `BLOOM_DICTATE_TOKEN`, usually sourced from `~/.bloom-env`.
- All endpoints except `/health` require `Authorization: Bearer <token>`. `/health` is unauthenticated for monitoring.
- If `BLOOM_DICTATE_TOKEN` is missing, the server fails closed unless `BLOOM_DICTATE_ALLOW_NO_AUTH=1` is set for local development.

## Endpoints

### `GET /health`

No auth.

```json
{
  "ok": true,
  "version": "1.0.0",
  "engine": "mlx-whisper",
  "model": "large-v3-turbo",
  "tenants_loaded": ["default"],
  "uptime_seconds": 12345
}
```

### `POST /transcribe`

Bearer auth. Multipart form upload.

**Form fields:**
- `audio` (file, required): m4a, mp3, wav, aiff, or webm. Max 10 minutes.
- `tenant_id` (string, required): tenant config to load. e.g. `default`.
- `mode` (string, optional): `raw` (default) or `prompt`. `prompt` runs the intent extractor.
- `language` (string, optional): override tenant default. e.g. `en`.

**Response (mode=raw):**
```json
{
  "raw": "transcribed text from whisper, with glossary biasing applied",
  "corrected": "post-corrected text from ollama qwen2.5",
  "model": "large-v3-turbo",
  "tenant": "default",
  "duration_ms": 1432,
  "audio_seconds": 8.4,
  "request_id": "01HX..."
}
```

**Response (mode=prompt):**
```json
{
  "raw": "...",
  "corrected": "...",
  "structured": {
    "intent": "...",
    "prompt": "...",
    "owner": "person | team | automation",
    "artifact": "...",
    "done_check": "..."
  },
  "model": "large-v3-turbo + qwen2.5:14b",
  "tenant": "default",
  "duration_ms": 4210,
  "audio_seconds": 8.4,
  "request_id": "01HX..."
}
```

**Errors:**
- `401`: missing or bad bearer token
- `404`: unknown tenant_id
- `413`: audio > 10 minutes
- `415`: unsupported audio format
- `500`: engine error (return error message in JSON body)

### `GET /tenants/:id/glossary`

Bearer auth. Returns parsed tenant config (without secrets, if any).

## Engine details

- **mlx-whisper.** Find existing venv (likely the one used by `~/bin/transcribe` — read that script first to find the venv path). Reuse, do not reinstall.
- Default model: `large-v3-turbo` (fast, good enough for dictation). Per-tenant override via config.
- **Glossary biasing:** pass tenant glossary into Whisper as `initial_prompt` parameter. Format the prompt as `"Glossary: term1, term2, term3, phrase one, phrase two."` truncated to ~200 tokens (Whisper's effective prompt window). If glossary > 200 tokens, prioritize: tenant `terms` first, then `phrases`.
- **Post-correction:** if tenant has `post_correction.enabled: true`, send `raw` text + tenant system prompt to Ollama at `http://localhost:11434/api/chat` with `model: <tenant.post_correction.model>`. Return as `corrected`. If post-correction fails or is disabled, set `corrected == raw`. Do not block on Ollama errors — log and fall through.
- **Prompt mode:** if request `mode=prompt` and tenant has `prompt_mode.enabled: true`, send `corrected` text + tenant prompt-mode system prompt to Ollama. Parse JSON response into `structured`. If JSON parse fails, return `structured: null` with the error logged.

## Tenant config schema

YAML at `~/.bloom-dictate/config/<tenant_id>.yaml`. Start from `configs/example.yaml`.

```yaml
tenant_id: string             # required, must match filename
display_name: string
language: string              # default: "en"
model: string                 # default: "large-v3-turbo"
keep_audio: bool              # default: false. If true, persists raw audio for debugging.
terms: [string]               # proper nouns, names, brands
phrases: [string]             # multi-word phrases
post_correction:
  enabled: bool               # default: true
  model: string               # default: "qwen2.5:14b"
  system_prompt: string
prompt_mode:
  enabled: bool               # default: false
  model: string
  system_prompt: string
```

## History

- Append JSONL to `~/.bloom-dictate/history/<tenant_id>/<YYYY-MM-DD>.jsonl`
- One line per request. Schema:
  ```json
  {"ts": "2026-05-08T19:23:45Z", "request_id": "01HX...", "tenant": "default", "mode": "raw", "audio_seconds": 8.4, "duration_ms": 1432, "raw": "...", "corrected": "...", "structured": null, "client_ip": "127.0.0.1"}
  ```
- Audio files: NOT persisted by default. If tenant config has `keep_audio: true`, write audio to `~/.bloom-dictate/audio/<tenant>/<request_id>.<ext>` for debugging.

## Out of scope (do NOT build)

- iPhone Shortcut — companion path documented in `docs/iphone-shortcut.md`
- Live captions / wake-word
- Voice cloning / TTS
- Web UI — later phase
- Multi-user OAuth, SaaS billing — much later

## Done check

The daemon is verified when ALL of these pass:

1. `curl http://127.0.0.1:8788/health` returns `{"ok": true, ...}` with `tenants_loaded: ["default"]`.
2. `lsof -iTCP:8788 -P` shows bind to `127.0.0.1` or a private LAN/Tailscale interface, not `*` or a public interface.
3. `curl -X POST http://127.0.0.1:8788/transcribe -H "Authorization: Bearer $TOKEN" -F "audio=@test.m4a" -F "tenant_id=default"` returns valid JSON with non-empty `raw`.
4. **Glossary biasing verified:** record a short test clip with terms from your tenant config and confirm `corrected` preserves them.
5. `~/.bloom-dictate/history/default/<today>.jsonl` has the request entry.
6. `launchctl print gui/<uid>/com.bloom.mist` shows it loaded and running if using launchd.

## Constraints / rules of engagement

- **Two-fail rule:** if any approach fails twice, stop and document the blocker before changing strategy. Don't loop on the same error.
- **Reuse, don't reinstall:** prefer an existing Python environment with mlx-audio/Ollama dependencies when available.
- **No secret leaks:** the bearer token goes in `~/.bloom-env` only. Never echo it into git or logs.
- **No public bind by default:** bind localhost or a private interface unless you have a stronger auth/reverse-proxy story.
