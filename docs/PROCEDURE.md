# Nihongo Buddy — Production Build Procedure

Production-ready, fully native Swift Mac app. No MVP placeholders, no LM Studio dependency, no Python. Architecture chosen for **lowest possible voice-to-voice latency** based on July 2026 research (sources at bottom).

---

## 0. Research Findings That Shape This Design

| Fact | Consequence |
|---|---|
| llama.cpp now supports **Gemma 4 audio input natively** (Conformer encoder merged, E2B passes 14/14 audio transcription tests across all quantizations) | **No STT stage at all.** Mic audio goes straight into Gemma. One model does listening + understanding + replying — removes an entire pipeline stage and its latency. |
| Audio path requires the **BF16 mmproj** file (F16/Q8_0 mmproj cause output repetitions; Q6_K aborts due to tensor block alignment) | Must download `mmproj-BF16.gguf` alongside your existing model file. Non-negotiable. |
| A known **audio regression** was reported in llama.cpp (issue #23688) | Pin llama.cpp to a tested release tag; never track master blindly. CI must run an audio-transcription smoke test before any dependency bump. |
| Gemma 4 E2B Q4_0 QAT: ~3.2–3.35 GB, **40–60+ tok/s on a 16 GB Mac**, ~158 tok/s on M5 Max. QAT preserves quality at 4-bit | Your existing GGUF is the right file. At 40+ tok/s, a 2-sentence spoken reply (~40 tokens) generates in ~1 s. |
| Kokoro-82M on **CoreML/ANE is the fastest TTS path**: 15× realtime on a base M1 Mac Mini, up to 79× on big chips, ~2× faster than the MLX implementation | Use the CoreML/ANE build of Kokoro, not MLX. TTS latency is effectively negligible (<400 ms for 30 s of speech). |
| **Japanese G2P is the trap**: MisakiSwift (the Swift Misaki port) is **English-only**. Kokoro's Japanese path in Python needs pyopenjtalk/MeCab | Pure-Swift Japanese phonemization does not exist off the shelf in the Misaki ports. **soniqo/speech-swift** bundles Kokoro CoreML with multi-language support (Japanese included) — use it. Fallback plan in §6. |

**Resulting latency budget per turn (target < 2.0 s perceived):**

```
Done tapped → audio encode + prefill        ~300–600 ms
→ first sentence generated (streaming)      ~500–800 ms
→ Kokoro synthesizes first sentence (ANE)   ~100–200 ms
→ playback starts  ██ user hears reply      ≈ 1.0–1.6 s
   (remaining sentences generate + synth while first one plays)
```

The single biggest speed lever is **sentence-streaming**: never wait for the full reply before speaking.

---

## 1. Prerequisites

1. Xcode (full install): `xcode-select -p` must point at `/Applications/Xcode.app/...`
2. Main model — already on disk (verified):
   ```
   /Users/junechakma/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/gemma-4-E2B_q4_0-it.gguf   (3.35 GB)
   ```
3. **Download the audio projector** (missing — required for the no-STT audio path):
   - From the Gemma 4 E2B GGUF repo on Hugging Face (e.g. unsloth/gemma-4-E2B-it-GGUF or ggml-org mirror), file: `mmproj-BF16.gguf` — **BF16 only**.
   - Keep it next to the main model for development.
4. Validate the audio path **before writing any app code** (this de-risks the whole architecture in 10 minutes):
   ```bash
   brew install llama.cpp   # or build a pinned tag from source
   # record a 16 kHz mono wav of yourself speaking Japanese, then:
   llama-mtmd-cli \
     -m  ~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/gemma-4-E2B_q4_0-it.gguf \
     --mmproj path/to/mmproj-BF16.gguf \
     --audio test_ja.wav \
     -p "Transcribe this audio, then reply to it in simple Japanese."
   ```
   - Test with clear speech, mumbled speech, and JP/EN mixed speech.
   - **Gate:** if mixed/mumbled recognition is unacceptable here, it will be unacceptable in the app. (Contingency: WhisperKit front-end, §6.)
5. Record the llama.cpp version that passes: `llama-cli --version` → pin this tag in the project.

---

## 2. Project Setup

1. Xcode → New → macOS App. Name `NihongoBuddy`, SwiftUI, Swift. Save in this folder.
2. Signing & Capabilities:
   - App Sandbox ✓, **Audio Input** ✓, **Outgoing Connections (Client)** ✓ (first-launch model download only)
3. Info.plist: `NSMicrophoneUsageDescription` = "Nihongo Buddy listens to your Japanese speech."
4. Package dependencies (pin exact versions, never branches):
   - `llama.cpp` (SwiftPM, ggml-org) — pinned to the tag validated in §1.5
   - `soniqo/speech-swift` — Kokoro CoreML TTS + VAD
5. Project structure — protocol-first so every engine is swappable and testable:

```
NihongoBuddy/
├── App/                    NihongoBuddyApp.swift, ContentView
├── Core/
│   ├── ConversationEngine.swift    // state machine: idle→listening→thinking→speaking
│   ├── Brain/
│   │   ├── BrainEngine.swift       // protocol: (audio|text, history) → AsyncStream<Token>
│   │   └── GemmaLlamaEngine.swift  // llama.cpp + mmproj implementation
│   ├── Speech/
│   │   ├── SpeechOutput.swift      // protocol: speak(AsyncStream<Sentence>)
│   │   ├── KokoroEngine.swift      // speech-swift / CoreML-ANE implementation
│   │   └── AppleTTSFallback.swift  // AVSpeechSynthesizer — shipping fallback
│   ├── Audio/
│   │   ├── MicCapture.swift        // AVAudioEngine, 16 kHz mono output
│   │   └── SpeechLevelMeter.swift  // VAD/level for UI feedback only — never ends a turn
│   └── Memory/
│       └── MistakeStore.swift      // SQLite: recurring-error tracking
├── Models/ModelManager.swift       // download, SHA-256 verify, warm-load
└── Resources/prompts/system.txt
```

---

## 3. The Brain (llama.cpp, embedded)

1. **Loading:** load model + mmproj once at app launch on a background actor; keep resident for app lifetime. Show a "warming up" state on cold launch. Metal enabled (default on Apple Silicon), `n_ctx` 8192.
2. **Input:** feed the captured 16 kHz mono buffer directly as an audio token span (mtmd API) + conversation history + system prompt. No STT.
3. **Transcript display:** the UI needs "You said: …". Get it from the model itself — system prompt instructs a fixed output frame:
   ```
   <heard>…what the user said, verbatim Japanese…</heard>
   <reply>…character reply…</reply>
   ```
   Parse tags out of the stream; `<heard>` fills the transcript, `<reply>` goes to TTS. One inference pass produces both.
4. **KV-cache reuse:** system prompt + prior turns stay in the KV cache across turns — only new audio is prefidled each turn. This is a large per-turn latency saving; do not tear down the context between turns.
5. **Streaming:** expose `AsyncStream<String>` of tokens. A `SentenceSplitter` accumulates tokens and emits on `。｡ ！ ？ !? .` boundaries → each sentence goes to TTS immediately.
6. **Sampling:** temperature ~0.8 (character needs life), repeat-penalty on. Cap `n_predict` ≈ 200 — spoken replies must be short; enforce in the prompt too.
7. **History management:** keep last ~10 turns verbatim; summarize older turns into one system-side note (mistake summary lives in MistakeStore, §7).

---

## 4. The Voice (Kokoro on ANE)

1. Use **speech-swift**'s Kokoro CoreML engine; voices `jf_alpha` (female) / `jm_kumo` (male) — expose as a two-option picker.
2. Pipeline = producer/consumer: sentences arrive from the splitter → synth queue (serial) → `AVAudioPlayerNode` gapless playback queue. First sentence plays while later ones synthesize; ANE at 15×+ realtime never becomes the bottleneck.
3. **JP/EN mixing:** replies contain English fragments (grammar explanations). Detect script runs (Kana/Kanji vs Latin) per sentence; synthesize Japanese runs with `jf_alpha`, English runs with an `af_*` voice, stitch buffers. Ship v1 with sentence-level switching (corrections put the English in its own sentence — enforce in system prompt: "put English explanations in separate sentences").
4. **Fallback:** `AppleTTSFallback` behind the same `SpeechOutput` protocol, auto-engaged if Kokoro assets fail to load. Never ship an app that can go mute.
5. Interruption: tapping Speak while Buddy is talking stops playback + cancels generation immediately (llama.cpp abort callback).

---

## 5. Audio Capture & Turn Control

**Design decision: manual turn-taking, no voice-activity auto-endpointing.** Learners pause mid-sentence to think; silence detection would cut them off and reply too early. The user stays in control:

```
[ 🎙️ Speak ]  → tap → recording starts, button becomes [ ✅ Done ]
[ ✅ Done ]   → tap → recording stops, audio sent to Gemma, reply begins
```

1. `AVAudioEngine` input tap → convert to 16 kHz mono Float32 (Gemma's expected rate — feeding native rate forces a resample inside llama.cpp's miniaudio path; do it yourself, correctly, once).
2. **Turn control:** recording starts on Speak tap and stops **only** on Done tap (or Esc / spacebar as keyboard shortcuts). No VAD-triggered end-of-utterance. Cap utterance length at 60 s with a visible countdown near the limit.
3. **VAD used for feedback only, never control:** a live level/waveform indicator while recording (so the user sees the mic is hearing them), and a gentle "I didn't hear anything" if Done is tapped with no detected speech — VAD never starts or ends a turn on its own.
4. Pre-roll buffer: keep a rolling 300 ms buffer while idle so the first syllable after tap isn't clipped.

---

## 6. Contingency Plans (decide by gates, not hope)

| Risk | Gate | Fallback |
|---|---|---|
| Gemma audio comprehension poor on mumbled/mixed speech | §1.4 CLI test | Insert **WhisperKit** (strong Japanese, CoreML/ANE) as STT; Gemma becomes text-in. Costs ~300–500 ms/turn. `BrainEngine` protocol already supports text-in — one new class, nothing else changes. |
| speech-swift Japanese Kokoro quality/G2P inadequate | Listen test in week 1 | (a) `mattmireles/kokoro-coreml` .mlpackage + bridge **OpenJTalk** (C library, links natively into Swift) for ja phonemization; (b) AppleTTSFallback ships regardless. |
| llama.cpp audio regression on dependency bump | CI smoke test (§9) | Stay on pinned tag until fixed upstream. |

---

## 7. Personality & Memory (the product)

1. `Resources/prompts/system.txt` — the character. Iterate in LM Studio chat against the real model *while* building (free, fast). Requirements: correction pattern (react → quote → correct → explain-in-English), short spoken-length replies, English explanations in separate sentences (TTS constraint, §4.3), `<heard>/<reply>` output frame (§3.3).
2. **MistakeStore (SQLite via GRDB):** use the generic `learning_events` schema from **FUTURE_PLAN.md** (events typed mistake/success/new_word, JLPT level tag, session records) — v1 only writes mistake/success rows, but the schema is ready for the Practice/Track/Learn modules. At session start, inject top recurring mistakes into the system prompt: *"User repeatedly confuses を/に (7 times). Tease gently when it recurs."* → this produces the "clingy, remembers you" character. Local file only.
3. Extraction: same output-frame trick — model appends `<mistake wrong="…" correct="…" point="…"/>` when it corrects; parse from stream, never shown raw in UI.

---

## 7.5. Character Visuals — GIF character (v1)

Buddy gets a face — the simple version: **one animated GIF per state**, swapped when the app state changes. No animation frameworks, no rigging, no commissions blocking the build. (Rive / Live2D upgrade paths live in FUTURE_PLAN.md.)

1. **Assets:** 7 looping GIFs bundled in the app:
   ```
   idle · listening · thinking · talking · shocked · happy · teasing
   ```
   Source: commission a simple chibi set, or generate/placeholder art to start — GIFs are trivially replaceable later.
2. **Display:** SwiftUI has no native GIF playback — render via `CGImageSource` frame extraction or a `WKWebView`-free minimal `NSImageView`/`CGAnimateImageURL` wrapper (~40 lines). Preload all 7 at launch; swap = instant.
3. **`CharacterView` protocol** anyway: `setState(_: CharacterState)`, `playReaction(_: Reaction)`. GIF implementation now; Rive/Live2D can drop in behind the same protocol later without touching the rest of the app.
4. **Emotion from the model, free:** extend the §3.3 output frame —
   ```
   <reply emotion="happy|shocked|proud|teasing|neutral">…</reply>
   ```
   Parse attribute from the stream → show the matching reaction GIF the moment TTS playback starts (face and voice must land together), then return to `talking` loop, then `idle`.
5. **State mapping:** app state machine drives it directly — `listening` GIF while recording, `thinking` while waiting on Gemma, `talking` during playback, reaction GIF overrides for the first ~2 s of an emotional reply.
6. No lip sync in the GIF version — the `talking` loop is just a generic mouth-flap GIF. Good enough; real lip sync arrives with the Rive/Live2D upgrade.

### Additions to earlier sections
- §2 structure: add `UI/CharacterView.swift` (protocol) + `UI/GifCharacterView.swift`; `Resources/character/*.gif`.
- §7 system prompt: add emotion-attribute instruction (shock on mistakes, pride on wins, teasing on repeat offenders — same beats as the voice).
- §9 test matrix: add "emotion attribute parses for every reply; character never sticks in a reaction state."

---

## 8. Model Distribution (production requirement)

Do **not** bundle 3.4 GB in the .app.

1. First launch → download screen: main GGUF + BF16 mmproj + Kokoro assets → `~/Library/Application Support/NihongoBuddy/models/`.
2. SHA-256 verify each file; resume partial downloads; disk-space preflight (~5 GB free).
3. Dev builds: point ModelManager at the existing LM Studio path via a debug setting so you never re-download during development.
4. After download: zero network. Enforce it — sandbox network entitlement is used by the downloader only.

---

## 9. Hardening & QA

1. **Memory:** model resident ≈ 4–5 GB total (Gemma + mmproj + Kokoro). Handle memory-pressure notifications: unload on background-idle if pressured, warm-reload on activation.
2. **CI smoke tests** (critical, cheap):
   - Audio: fixed Japanese wav → assert transcription contains expected substring (catches llama.cpp regressions).
   - TTS: fixed sentence → assert non-silent buffer of sane duration.
   - Latency: assert time-to-first-audio < 2.5 s on baseline hardware.
3. **Test matrix:** clear JP / mumbled JP / JP-EN mixed / long thinking pauses mid-utterance (must NOT trigger reply — recording continues until Done) / Done tapped with no speech ("didn't hear anything" path) / interruption mid-reply / 20-turn session (KV-cache + memory growth) / cold vs warm launch.
4. **Error UX:** every failure path speaks or shows something in-character. No silent failures, no raw error strings.
5. **Instruments passes:** Time Profiler on a full turn (find real bottleneck before optimizing), Leaks over 50 turns.

---

## 10. Ship

1. App icon, About panel, minimal Settings (voice picker, mic device, "reset memory").
2. Developer ID signing + **notarization** (`notarytool`) — required for distribution outside the App Store.
3. Package as .dmg. (App Store later if desired — sandbox already in place.)
4. Version pinning manifest in-app: llama.cpp tag, model SHA, mmproj SHA, speech-swift version — printed in About for supportability.

---

## Build Order (dependencies, not phases)

| # | Task | Gate to pass |
|---|---|---|
| 1 | §1.4 CLI audio validation | Gemma understands your real speech |
| 2 | Project skeleton + protocols (§2) | compiles |
| 3 | GemmaLlamaEngine: text-in first, then audio-in, streaming | tokens stream in console |
| 4 | Mic capture + Speak/Done turn control → engine | end-to-end audio→text reply |
| 5 | Kokoro + sentence-streaming playback | time-to-first-audio < 2 s |
| 6 | Output-frame parsing, transcript UI, state machine | full loop, clean UI |
| 7 | MistakeStore + prompt iteration | character remembers mistakes |
| 8 | ModelManager download flow | works on a clean Mac |
| 9 | QA matrix + CI smoke tests | all green |
| 10 | Sign, notarize, dmg | installs on someone else's Mac |

---

## Sources

- llama.cpp Gemma 4 audio conformer support: https://github.com/ggml-org/llama.cpp/pull/21421
- llama.cpp multimodal docs (mtmd, --audio, mmproj): https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/multimodal.md
- Gemma 4 audio regression (pin versions): https://github.com/ggml-org/llama.cpp/issues/23688
- E2B mmproj BF16-only constraint: https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/discussions/1
- Apple Silicon tok/s benchmarks: https://llmcheck.net/benchmarks
- Kokoro CoreML/ANE benchmarks (15–79× RT): https://github.com/mattmireles/kokoro-coreml
- speech-swift toolkit: https://github.com/soniqo/speech-swift
- Kokoro voices/language codes: https://soniqo.audio/guides/kokoro
- MisakiSwift (English-only — the Japanese G2P gap): https://github.com/mlalma/MisakiSwift
- Kokoro upstream + Misaki ja tokenizer (pyopenjtalk/MeCab): https://github.com/hexgrad/misaki
