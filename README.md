# Mist

Native-feeling push-to-talk dictation for macOS, powered by Bloom.

Mist runs Apple's on-device `SFSpeechRecognizer` continuously, streams partial transcripts to a local JSONL file, and uses Hammerspoon to type text into the focused app while you hold a hotkey. It is designed to feel like macOS dictation, but with hackable glossary correction and a local server path for Whisper/Ollama experiments.

## Current Shape

- Hold Right Command to dictate into the focused text field.
- Double-tap Right Command to lock dictation on; tap again to stop.
- `Control` + `Option` + `Command` + `Escape` cancels.
- Transcription is local on the Mac in native streamer mode.
- Optional server path supports mlx-audio Whisper, tenant glossaries, and Ollama post-correction.

## macOS Streamer Setup

Requirements:

- macOS 14+
- Xcode command line tools / SwiftPM
- Hammerspoon with Accessibility permission
- Microphone and Speech Recognition permission for `Mist.app`

Build and install the app bundle:

```bash
cd client-mac-app
make app
```

Start the streamer:

```bash
open -n ~/Applications/Mist.app --args --streamer
```

Install the Hammerspoon bridge by copying `client-mac/hammerspoon-mist.lua` into `~/.hammerspoon/init.lua` or loading it from your existing config.

The streamer writes events to the existing Bloom-compatible state directory:

```text
~/.bloom-dictate/dictate-stream.jsonl
```

The Hammerspoon bridge tails that file and posts Unicode key events into the app that had focus when dictation began.

Optional private glossary corrections can live in:

```text
~/.bloom-dictate/hammerspoon-glossary.lua
```

The file should return Lua pairs like `{ { "open claw", "OpenClaw" } }`.

## Optional Whisper Server

The `server/` directory contains a FastAPI daemon that accepts audio uploads and runs mlx-audio Whisper with glossary biasing. This was the original batch/streaming path and remains useful for experiments or appliance-style deployments.

Create a tenant config:

```bash
mkdir -p ~/.bloom-dictate/config
cp configs/example.yaml ~/.bloom-dictate/config/default.yaml
```

Run locally:

```bash
cd server
BLOOM_DICTATE_TOKEN="$(openssl rand -hex 32)" python3 -m uvicorn main:app --host 127.0.0.1 --port 8788
```

The server fails closed if `BLOOM_DICTATE_TOKEN` is missing. For local-only development without auth, explicitly set `BLOOM_DICTATE_ALLOW_NO_AUTH=1`.

Point `client-mac/bd` at the daemon with:

```bash
export BLOOM_DICTATE_URL=http://127.0.0.1:8788
export BLOOM_DICTATE_TOKEN=<your-token>
export BLOOM_DICTATE_TENANT=default
```

## Notes

- This is not notarized or packaged for general users yet.
- The hotkey bridge currently depends on Hammerspoon because native Swift event-tap delivery was unreliable during development.
- Bluetooth headset inputs can be unreliable on macOS when the device stays in high-quality stereo mode. Mist avoids known-problem AirPods/Beats capture inputs and falls back to the built-in mic when available. Set `BLOOM_DICTATE_PREFER_SYSTEM_INPUT=1` to force the macOS default input, or `BLOOM_DICTATE_AUDIO_DEVICE=<name-or-id>` to pick a specific device.
- `client-mac/mist doctor` checks local health without printing secrets. `client-mac/mist reset` clears Hammerspoon dictation state if a hotkey session ever feels stuck. `client-mac/bd` remains as a compatibility alias for early builds.
- `scripts/privacy-scan.sh` is the release gate for private paths, raw bearer headers, and token-shaped hex strings.

## License

MIT. See [LICENSE](LICENSE).
