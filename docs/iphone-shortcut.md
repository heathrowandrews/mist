# iPhone Shortcut — "Mist"

**Goal:** Tap a button (or "Hey Siri, Mist") on iPhone → record → upload to your Mist daemon → transcript auto-copied to clipboard. Notification confirms.

This version routes through Mist so glossary biasing applies.

## Prerequisites

- iPhone on Tailscale (Tailscale iOS app installed, signed in to tailnet)
- Mist daemon live and reachable, for example at a private Tailscale/LAN URL
- Bearer token from `~/.bloom-env` (`BLOOM_DICTATE_TOKEN`) — paste once into Shortcut config

## Build steps (Shortcuts app on iPhone)

1. **New Shortcut** → name `Mist`. Icon 🌫 on dark background.

2. **Record Audio**
   - Start/Stop: **On Tap** (lets him talk as long as he wants, tap again to finish)
   - Audio Quality: **Normal** (m4a, ~24-32 kbps, fine for ASR)

3. **Get Contents of URL** (the upload step)
   - URL: `http://YOUR_PRIVATE_HOST:8788/transcribe`
   - Method: **POST**
   - Headers:
     - `Authorization` : `Bearer <PASTE_TOKEN_HERE>`
   - Request Body: **Form**
     - `audio` : File → Recorded Audio (from step 2)
     - `tenant_id` : `default`
     - `mode` : `raw`

4. **Get Dictionary Value** from previous result
   - Get Value for: `corrected`
   - From: Contents of URL

5. **Copy to Clipboard** (Dictionary Value)

6. **Show Notification**
   - Title: `Mist`
   - Body: Dictionary Value (the transcript)
   - Sound: default

## Hey Siri wiring

- Shortcut details (i) → Use with Siri **ON** → phrase: `Mist`
- Long-press home screen → Add Widget → Shortcuts → pin a one-tap tile (fallback when Siri misfires)

## Verification

1. Tap shortcut → say a phrase containing terms from your glossary.
2. Tap to stop recording
3. Notification fires with transcript
4. Open Notes → paste → check that glossary terms are preserved.

If glossary terms are not preserved, the glossary path is not being applied; debug the daemon config first.

## Known gotchas

- **Tailscale must be connected** on iPhone for the URL to resolve. If Tailscale drops, request fails — Shortcut shows error notification.
- **m4a default is fine.** Don't switch Record Audio quality to Lossless — ASR doesn't benefit and file size triples.
- **Bearer token in plain Shortcut config** is fine for personal use. If you share the Shortcut, rotate the token.
- **Long recordings (>10 min)** hit daemon limit. Split into multiple takes.
- **First run prompts permissions** — Microphone, Network. Approve both.

## Variants (later)

- **Prompt mode:** duplicate this Shortcut as `Mist Prompt`, set `mode: prompt` in step 3 form fields, and after step 4 also fetch `structured` and route the JSON to your preferred automation target.
- **Apple Watch trigger:** Watch app shortcut surface for hands-free quick dictation while driving / walking.
- **Auto-paste on Mac:** if iPhone is on same Tailscale, push transcript to a Mac clipboard helper (later, after Mac menubar app exists).
