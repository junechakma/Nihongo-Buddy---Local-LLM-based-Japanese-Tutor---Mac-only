# Nihongo Buddy — Local LLM-based Japanese Tutor (Mac only)

A fully offline, native macOS app: talk to it, it listens, thinks, corrects your Japanese with humor, and speaks back — all on-device, nothing leaves your machine.

## What it does

- **One button: "Speak."** Tap, talk in Japanese (or mixed Japanese/English), and get a spoken, in-character reply.
- Runs entirely locally — no API keys, no internet required after setup, no data leaves the device.
- Corrects mistakes playfully: shows what you said, the correct version, and a short English explanation of the fix.
- Shows full text of both your speech and the AI's reply alongside the audio.

## Stack

- **App:** Native macOS (SwiftUI), targeting macOS 15+
- **LLM:** Local Gemma model via `llama.cpp` (on-device inference, no cloud calls)
- **TTS:** Voicevox (Japanese speech synthesis)
- Project generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`)

## Project layout

```
NihongoBuddy/
  App/            App entry point
  Core/           Conversation engine, speech pipeline
  CLlama/         llama.cpp integration
  CVoicevox/       Voicevox TTS integration
  MossTTS/        MOSS-TTS experiments
  Models/         Local model files
  Resources/      Prompts, assets
  UI/             SwiftUI views
docs/             Project spec, plans, validation notes
```

## Setup

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Generate the Xcode project:
   ```
   xcodegen generate
   ```
3. Open `NihongoBuddy.xcodeproj` in Xcode and run.
4. See `docs/docs.md` for the full project spec and `docs/PROCEDURE.md` for setup/build notes.

## Status

Actively in development — local LLM conversation loop, corrections, and TTS are working; ongoing tuning of voice quality and conversation personality.
