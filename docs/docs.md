# Nihongo Buddy — Offline Japanese Conversation AI (Project Spec)

*A fully offline, native Mac app: talk to it, it listens, thinks, corrects your Japanese with humor, and speaks back — all on-device, nothing leaves your machine.*

---

## 1. What You're Building

A single-purpose Mac app with a dead-simple interface:

1. **One button: "Speak."**
2. You tap it, talk in Japanese (or mixed Japanese/English), tap again (or it auto-detects silence).
3. The app shows a short **"listening / thinking"** state.
4. The AI replies **out loud**, in character — funny, warm, a little dramatic — and:
   - If you made a mistake, it **corrects you playfully** (e.g. calls out the wrong particle/verb form, explains *why*, gives the correct version).
   - It **mixes in English** naturally so you're never lost, especially on corrections.
   - It shows the **full text** of both what you said and what it replied, on screen, alongside the audio.
5. Everything — listening, understanding, correcting, speaking — runs **100% locally on your Mac**. No API keys, no internet required after setup, no data ever leaves the device.

This is essentially a **funny, clingy Japanese conversation partner** who happens to live entirely inside your laptop.

---

## 2. Core Interaction Loop

```
[ Speak Button ] 
      │ tap
      ▼
🎙️  Listening... (mic captures audio via AVAudioEngine)
      │
      ▼
🧠  Thinking... (Gemma 4 E2B processes audio directly — no separate STT needed)
      │
      ▼
📝  Shows: "You said: ..."
😄  Shows + speaks: "AI replies (funny, corrective, bilingual)..."
      │
      ▼
[ Speak Button ]  ← ready for your next turn
```

**Key UX principle:** minimal chrome. No settings maze, no chat bubbles history clutter (a simple scrollback is fine) — the personality and the correction *are* the product.

---

## 3. The Personality (this is the actual hard part)

The system prompt needs to define a character, not just an instruction-follower. Rough shape:

- **Tone:** playful, a bit theatrical, genuinely excited when you get something right, comically "wounded" (never mean) when you get something wrong.
- **Correction pattern (always this shape):**
  1. React in character first ("Ehh?? Chotto matte—that's not quite it!")
  2. Say what you *actually* said, in Japanese.
  3. Give the correct version, in Japanese.
  4. Explain the fix briefly, in **English**, so the grammar point actually lands.
  5. Get you to try again or move on, still in character.
- **Language mixing rule:** primary reply in Japanese (matched to your level, N5–N4 range), but corrections and grammar explanations drop into English so nothing gets lost in translation.
- **Consistency:** the character should remember your recurring mistakes across the conversation (and ideally across sessions) and can gently tease you about repeat offenders — this is where "clingy" comes in: it notices, it remembers, it cares (in an over-the-top way).

This lives entirely in the **system prompt + conversation memory**, not in any model's built-in personality — Gemma doesn't ship with a character, you write one.

---

## 4. Tech Stack (Decided)

**Fully native Swift app. No Python, no subprocess, no bundled interpreter.**

| Layer | Choice | Why |
|---|---|---|
| App shell | Native macOS (Swift/SwiftUI) | Best performance, tightest OS integration (mic access, native audio), single compiled binary |
| Brain / conversation model | **Gemma 4 E2B** (2.3B, quantized), via **MLX Swift** | Native audio *and* vision understanding in one model — no separate STT needed for the audio path. Small enough to run fast and light on any Apple Silicon Mac. Ships with native function-calling/tool-use if you want to extend later (note-taking, screen reading, etc.) |
| Voice output (TTS) | **Kokoro-82M**, via native Swift (CoreML/ANE or MLX Swift) | Mature, fast, expressive-enough, Apache 2.0, and — crucially — **already has Japanese voices built in** (`jf_alpha`, `jm_kumo`, etc.), which lines up perfectly with this project |
| Audio capture | `AVAudioEngine` | Standard native Mac mic capture, no extra dependency |

### Model file (downloaded, local)
- **File:** `gemma-4-E2B_q4_0-it.gguf` (~3.35 GB, Q4_0 QAT quantization, GGUF format)
- **Location:** `/Users/junechakma/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/gemma-4-E2B_q4_0-it.gguf`
- Note: GGUF is the llama.cpp format — loadable via llama.cpp (e.g. LM Studio, llama.cpp Swift bindings). MLX Swift uses its own MLX weight format, so running this exact file requires a llama.cpp-based runtime, or downloading the MLX-converted variant of the same model instead.

### Why Gemma 4 E2B specifically
- 2.3B parameters, ~3.35GB at 4-bit (Q4_0 QAT) quantization — fast on any modern Mac, won't compete for resources with the TTS model
- **Native audio input** — you speak, it understands directly, no Whisper/STT step required
- Native function-calling support if you later want the app to do more (flashcards, progress tracking, etc.)
- Runs via MLX Swift with no Python at all

### Why Kokoro over other TTS options considered
Explored during research: Chatterbox-Turbo (350M, most expressive/emotion-controllable, but English-focused and CUDA-benchmarked, no mature Swift port), MOSS-TTS-Nano (100M, CPU-friendly, Apache-2.0, but brand-new/untested and **Python-only, no Swift or CoreML port**), Kyutai Pocket TTS (100M, CPU real-time, newer).

**Kokoro won because:**
- Multiple mature, benchmarked native Swift implementations already exist (see below)
- Built-in Japanese voice support out of the box
- Extremely fast on Apple Silicon — one optimized Core ML pipeline synthesizes 30 seconds of speech in under 400ms on a Mac Studio, and even the cheapest M1 Mac Mini beats real-time by a wide margin
- Apache 2.0, zero licensing friction

---

## 5. Native Swift Libraries Found (ready to use)

- **[soniqo/speech-swift](https://github.com/soniqo/speech-swift)** — comprehensive on-device speech toolkit for Apple Silicon (ASR, TTS, speech-to-speech, VAD, diarization), MLX Swift + CoreML, bundles Kokoro and several other TTS models under one API. **Best starting point** — could cover your entire audio stack with one dependency.
- **[mattmireles/kokoro-coreml](https://github.com/mattmireles/kokoro-coreml)** — Kokoro re-engineered stage-by-stage across ANE/CPU/GPU for maximum speed; fastest benchmarked option, pre-converted `.mlpackage` files ready to load.
- **[mweinbach/kokoro-swift](https://github.com/mweinbach/kokoro-swift)** — simplest API, supports both MLX and CoreML backends, good if you want to compare the two.
- **[mlalma/kokoro-ios](https://github.com/mlalma/kokoro-ios)** — MLX Swift port, works on macOS and iOS.

For Gemma: **MLX Swift** has a native API for running Gemma-family models directly — no Python bridge needed.

---

## 6. Full Architecture (Offline, All-Swift)

```
┌─────────────────────────────────────────────────────────┐
│                     Mac App (SwiftUI)                    │
│                                                           │
│   [ 🎙️ Speak Button ]                                    │
│         │                                                │
│         ▼                                                │
│   AVAudioEngine (mic capture)                            │
│         │                                                │
│         ▼                                                │
│   Gemma 4 E2B — MLX Swift                                │
│   • native audio understanding (no separate STT)         │
│   • conversation + correction logic (system prompt)      │
│   • outputs: reply text (JP + EN mix)                    │
│         │                                                │
│         ▼                                                │
│   Kokoro TTS — CoreML/ANE (via speech-swift or           │
│   kokoro-coreml)                                          │
│   • Japanese voice (jf_alpha / jm_kumo)                  │
│   • speaks the reply aloud                               │
│         │                                                │
│         ▼                                                │
│   UI updates: "You said: ..." / "AI: ..." (text +        │
│   simultaneous audio playback)                            │
└─────────────────────────────────────────────────────────┘

Zero network calls after initial model download.
Zero Python. Zero subprocess. Single compiled app.
```

---

## 7. Open Questions / Next Steps

- [x] Confirm exact Gemma 4 E2B quantization level to bundle — **decided: Q4_0 QAT** (`gemma-4-E2B_q4_0-it.gguf`, ~3.35 GB, already downloaded to `~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/`)
- [ ] Decide: ship model weights *inside* the app installer (bigger download, works fully offline immediately) vs. download-on-first-launch (smaller installer, needs internet once)
- [ ] Write and iterate on the actual system prompt / character voice (this defines "funny," not the models)
- [ ] Decide whether to persist conversation history / recurring-mistake tracking across sessions (local storage only — e.g. a simple local JSON or SQLite file)
- [ ] Test Gemma 4 E2B's native audio path directly vs. falling back to a separate STT model, in case the direct audio understanding isn't reliable enough for casual/mumbled speech
- [ ] Prototype with **soniqo/speech-swift** first since it's the most complete toolkit — validate the whole pipeline before hand-optimizing individual pieces

---

## 8. One-Line Summary

**A native Swift Mac app where you tap a button, talk in Japanese, and a funny, clingy, bilingual AI character — running entirely offline on Gemma 4 E2B + Kokoro TTS — listens, corrects your mistakes with humor, and speaks the correction back to you, with everything shown as text on screen too.**
