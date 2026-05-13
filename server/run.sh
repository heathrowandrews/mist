#!/bin/bash
# bloom-dictate launcher. Sources ~/.bloom-env so BLOOM_DICTATE_TOKEN never
# touches the plist on disk. Called by launchd.
set -euo pipefail

cd "$(dirname "$0")"

if [ -f "$HOME/.bloom-env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$HOME/.bloom-env"
    set +a
fi

# Homebrew bins (ffmpeg lives here on Apple Silicon) — mlx_audio shells out
# to ffmpeg for m4a/aac decoding so it MUST be on PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

: "${BLOOM_DICTATE_HOST:=127.0.0.1}"
: "${BLOOM_DICTATE_PORT:=8788}"
: "${BLOOM_DICTATE_DATA:=$HOME/.bloom-dictate}"
: "${OLLAMA_URL:=http://localhost:11434}"

export BLOOM_DICTATE_HOST BLOOM_DICTATE_PORT BLOOM_DICTATE_DATA OLLAMA_URL

PYTHON_BIN="${BLOOM_DICTATE_PYTHON:-python3}"

exec "$PYTHON_BIN" -m uvicorn main:app \
    --host "$BLOOM_DICTATE_HOST" --port "$BLOOM_DICTATE_PORT"
