# Nihongo Buddy — Local LLM-based Japanese Tutor (Mac only)

A fully offline, native macOS app: talk to it, it listens, thinks, corrects your Japanese with humor, and speaks back — all on-device, nothing leaves your machine.

## What it does

- **One button: "Speak."** Tap, talk in Japanese (or mixed Japanese/English), and get a spoken, in-character reply.
- Runs entirely locally — no API keys, no internet required after setup, no data leaves the device.
- Corrects mistakes playfully: shows what you said, the correct version, and a short English explanation of the fix.
- Shows full text of both your speech and the AI's reply alongside the audio.

## Stack

- **App:** Native macOS (SwiftUI), targeting macOS 15+
- **LLM:** Local Gemma 4 E2B (GGUF) via `llama.cpp` — audio in, text out, no separate STT stage
- **TTS:** VOICEVOX core (Japanese, expressive pitch-accent-correct speech) + Kokoro-82M CoreML (English)
- Project generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`)

## Project layout

```
NihongoBuddy/
  App/            App entry point
  Core/           Conversation engine, speech pipeline
  CLlama/         llama.cpp integration
  CVoicevox/      VOICEVOX TTS integration
  MossTTS/        MOSS-TTS experiments
  Models/         Model manager / download logic
  Resources/      Prompts, assets
  UI/             SwiftUI views
docs/             Project spec, plans, asset locations, validation notes
Vendor/           Third-party runtime binaries (VOICEVOX core, ONNX runtime, MOSS-TTS weights) — not tracked on main, see below
```

## Branches

- **`main`** — source only, pushed to GitHub. `Vendor/` is gitignored here: it's ~1GB of third-party binaries (VOICEVOX core/models, ONNX runtime, MOSS-TTS ONNX weights) that don't belong in GitHub history.
- **`local-full`** — local development branch where `Vendor/` *is* tracked in git for convenience. Never pushed to origin.

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Generate the Xcode project:
   ```
   xcodegen generate
   ```
3. Fetch runtime assets into `Vendor/` and `~/.lmstudio/models/...` — see `docs/ASSETS.md` for exact paths, sources, and sizes (main Gemma GGUF, audio projector, VOICEVOX core/models, Kokoro CoreML cache).
4. Open `NihongoBuddy.xcodeproj` in Xcode and run.
5. See `docs/docs.md` for the full project spec and `docs/PROCEDURE.md` for setup/build notes.

## Credits / Licensing

- **VOICEVOX:** free including commercial use, but the app must display "VOICEVOX:ずんだもん" (per character used) in About/credits — see `docs/ASSETS.md`.

## Status

Actively in development — local LLM conversation loop, corrections, and TTS are working; ongoing tuning of voice quality and conversation personality.
