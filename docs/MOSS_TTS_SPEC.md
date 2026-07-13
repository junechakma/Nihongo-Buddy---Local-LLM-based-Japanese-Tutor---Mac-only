# MOSS-TTS-Nano Integration — Full Spec & Architecture

Status: **built, working, code kept in tree but NOT the active engine.** VoicevoxEngine is primary
(user judged MOSS output "very distorted and broken" on 2026-07-04). This doc exists so the whole
integration — code, models, wiring — can be recreated from scratch if `Vendor/` is ever lost again.

All source files described here already exist in git on `main`/`local-full`:
- `NihongoBuddy/MossTTS/MossTTSEngine.swift`
- `NihongoBuddy/MossTTS/MossManifest.swift`
- `NihongoBuddy/MossTTS/CMossTTS/moss_tts.h`
- `NihongoBuddy/MossTTS/CMossTTS/moss_tts.cpp`
- `NihongoBuddy/MossTTS/CMossTTS/module.modulemap`

What's **not** in git (must be re-fetched) is the ~715MB of ONNX weights under `Vendor/moss-tts-onnx/`.

---

## 1. What it is

A fully native (no Python) Swift/C++ port of MOSS-TTS-Nano, a ~100M-parameter RVQ-token
text-to-speech model from the OpenMOSS team. One model speaks both Japanese and English via a
builtin cloned-voice prompt (no audio encoder needed at runtime — reference speaker codes ship
pre-tokenized in the manifest JSON).

Reference implementation ported from: `MOSS-TTS-Nano/examples/android_onnx_runtime` /
`MossOnnxDemoEngine.kt` (Kotlin/Android ONNX Runtime demo), adapted to C++ + ONNX Runtime C API
+ SentencePiece, wrapped in a Swift actor.

## 2. Pipeline architecture

```
text (Sentence.text, ja or en)
   │
   ▼
SentencePiece tokenize (moss_tts_tokenize)
   │
   ▼
MossManifest.buildInputRows()
   builds [seq_len × (n_vq+1)] int32 row matrix:
     - user_prompt_prefix tokens
     - <audio_start>
     - builtin voice's prompt_audio_codes (reference speaker, pre-tokenized)
     - <audio_end>
     - user_prompt_after_reference tokens
     - text token ids
     - assistant_prompt_prefix tokens
     - <audio_start>  (assistant now generates audio)
   │
   ▼
moss_tts_synthesize() — 4 ONNX sessions, in order:
   │
   ├─ 1. PREFILL  (moss_tts_prefill.onnx)
   │     in:  input_ids [1,seq_len,row_width], attention_mask [1,seq_len]
   │     out: global_hidden, present_key_{0..11}, present_value_{0..11}
   │          (12 transformer layers, KV cache)
   │     → take hidden state of LAST sequence position only
   │
   ├─ 2. DECODE LOOP  (repeat up to max_new_frames times)
   │     a) FRAME HEAD (moss_tts_local_fixed_sampled_frame.onnx)
   │        in:  global_hidden, repetition_seen_mask [1,n_vq,1024],
   │             assistant_random_u [1], audio_random_u [1,n_vq]
   │        out: should_continue, frame_token_ids [n_vq]
   │        (sampling — top-k/top-p equivalent — happens INSIDE this graph;
   │         host only supplies uniform randoms + a "seen token" repetition mask)
   │        if !should_continue → break
   │     b) DECODE STEP (moss_tts_decode_step.onnx)
   │        in:  input_ids [1,1,row_width] (new audio row: assistant-slot id +
   │             the n_vq frame tokens just sampled), past_valid_lengths,
   │             past_key_{0..11}, past_value_{0..11} (fed back from previous step)
   │        out: global_hidden, present_key_{0..11}, present_value_{0..11}
   │        → becomes the new past for next iteration
   │     accumulate frame_token_ids into `frames: [[Int32]]`
   │
   └─ 3. CODEC DECODE  (MOSS-Audio-Tokenizer-Nano-ONNX decode_full.onnx)
         in:  audio_codes [1,n_frames,n_vq], audio_code_lengths [1]
         out: audio [1,channels,length], audio_lengths [1]
         → average channels down to mono float32 PCM @ 48kHz
   │
   ▼
AVAudioPCMBuffer, peak-normalized per sentence (voices vary wildly in loudness —
Soyo peaks ~0.08, Ava ~0.43 — gain = min(0.7/peak, 12.0) applied if >1.05x)
   │
   ▼
AVAudioEngine playerNode.scheduleBuffer (sentence-by-sentence streaming playback)
```

### Key model facts (`moss_tts_params`)
| field | value | meaning |
|---|---|---|
| `n_vq` | 16 | RVQ codebooks per audio frame |
| `row_width` | 17 | n_vq + 1 (leading text/slot token column) |
| `global_layers` | 12 | transformer layers, each with its own KV cache pair |
| `audio_codebook_size` | 1024 | vocab per codebook |
| `sample_rate` | 48000 | codec output rate |

### RVQ audio row layout
Every row in the input matrix is `row_width` int32s: column 0 is either a text token id, a
special slot marker (`audio_user_slot_token_id`, `audio_assistant_slot_token_id`), or a control
token (`audio_start`/`audio_end`); columns 1..16 are RVQ codebook indices (or `audio_pad_token_id`
for non-audio rows).

## 3. File inventory (what must be re-downloaded)

Root: `Vendor/moss-tts-onnx/` (~715MB total, from Hugging Face `OpenMOSS-Team/*-ONNX`)

```
Vendor/moss-tts-onnx/
├── MOSS-TTS-Nano-100M-ONNX/
│   ├── moss_tts_prefill.onnx
│   ├── moss_tts_decode_step.onnx
│   ├── moss_tts_local_fixed_sampled_frame.onnx   (the "browser PoC" sampler — see §5 caveat)
│   ├── <tokenizer>.model                          (SentencePiece model, name from manifest.model_files.tokenizer_model)
│   └── browser_poc_manifest.json                  (prompt template + builtin voice reference codes)
└── MOSS-Audio-Tokenizer-Nano-ONNX/
    ├── moss_tts_local_shared.data / global_shared.data  (large external-data blobs for the above .onnx graphs)
    ├── <decode_full onnx file, name from codec_browser_onnx_meta.json "files.decode_full">
    └── codec_browser_onnx_meta.json               (sample_rate + decoder filename)
```

Exact filenames for the tokenizer model and codec decoder are NOT hardcoded — they're read at
runtime from `browser_poc_manifest.json` (`model_files.tokenizer_model`) and
`codec_browser_onnx_meta.json` (`files.decode_full`) respectively. Pull both JSON files first,
then fetch whatever filenames they reference from the same HF repos.

**Source:** Hugging Face, org `OpenMOSS-Team`, repos named after `MOSS-TTS-Nano-100M-ONNX` and
`MOSS-Audio-Tokenizer-Nano-ONNX` (search HF for these exact strings — this is an ONNX export of
the reference PyTorch MOSS-TTS-Nano checkpoint, packaged specifically for the browser/mobile
ONNX Runtime demo referenced in `moss_tts.cpp`'s header comment).

## 4. Build wiring (project.yml)

Already committed in `project.yml`. If recreating from scratch, a MOSS-TTS integration needs:

1. Homebrew deps: `brew install onnxruntime sentencepiece`
2. `SWIFT_INCLUDE_PATHS` includes `NihongoBuddy/MossTTS/CMossTTS`
3. `HEADER_SEARCH_PATHS` includes `/opt/homebrew/opt/onnxruntime/include/onnxruntime` and
   `/opt/homebrew/opt/sentencepiece/include`
4. `LIBRARY_SEARCH_PATHS` / `LD_RUNPATH_SEARCH_PATHS` include
   `/opt/homebrew/opt/onnxruntime/lib` and `/opt/homebrew/opt/sentencepiece/lib`
5. `CLANG_CXX_LANGUAGE_STANDARD: c++17` (ONNX Runtime C++ API requires it)
6. `NihongoBuddy/MossTTS/CMossTTS/module.modulemap` exposes the C header as Swift module
   `CMossTTS`, linking `onnxruntime` and `sentencepiece` — note the modulemap currently uses an
   **absolute path** to `moss_tts.h`; if the project moves machines/paths this must be updated to
   match `$(SRCROOT)`.

`MossTTSEngine.swift` also hardcodes an absolute path for `modelRoot`
(`/Users/junechakma/Freelance/June Chakma/Nihongo Buddy/Nihongo Buddy/Vendor/moss-tts-onnx`) —
update if the project directory moves.

## 5. Known caveats / why it was shelved

- **Quality verdict (2026-07-04): "very distorted and broken — not worth it."** Voicevox reverted
  to primary engine (`NihongoBuddy/Core/Speech/VoicevoxEngine.swift`). This code is otherwise
  functional (tokenizer verified exact against manifest samples) — the defect is audio quality,
  not a build/wiring bug.
- **Suspected root cause:** used `moss_tts_local_fixed_sampled_frame.onnx`, the browser-PoC fixed
  sampler (mirrors the Android reference example). The reference Python runtime
  (`ort_cpu_runtime.py` in the upstream repo) instead uses a `local_decoder` +
  `local_cached_step` pair with **host-side top-k/top-p sampling**, which is a materially
  different (and likely higher-quality) code path. Revisiting this would mean porting that
  decoder pair instead of the fixed-frame sampler, and implementing top-k/top-p sampling in the
  C++ shim rather than relying on the graph's baked-in sampling.
  - Would need 2 more ONNX sessions (`local_decoder`, `local_cached_step`) replacing the single
    `frame` session in `moss_tts_ctx`, plus a host-side sampling loop.
- **No GGUF/llama.cpp path exists** for this model — the RVQ 16-codebook audio pipeline isn't
  supported by llama.cpp's existing architectures, hence the separate ONNX Runtime path.
- **Builtin voice loudness varies wildly** (Soyo peak ~0.08, Ava peak ~0.43) — engine
  peak-normalizes per sentence as a workaround, not a fix.

## 6. Voices

Builtin voices come from `browser_poc_manifest.json`'s `builtin_voices` array, each with
pre-tokenized `prompt_audio_codes` (no live voice cloning at runtime — it's a fixed set of
speakers baked into the manifest at export time). Default: Japanese = "Soyo", English = "Ava".
Override via:
```
defaults write com.junechakma.NihongoBuddy mossVoiceJa -string "Saki"
defaults write com.junechakma.NihongoBuddy mossVoiceEn -string "Ava"
```

## 7. Smoke-testing outside the app

A standalone smoke test was used during development: a small `moss_test.cpp` driving the same
4-session pipeline directly, linked against the same Homebrew `onnxruntime`/`sentencepiece`
libs, to validate synthesis before wiring into the SwiftUI app. Recreate by compiling
`moss_tts.cpp`/`moss_tts.h` with a `main()` that calls `moss_tts_create` →
`moss_tts_tokenize` → `moss_tts_synthesize` → write PCM to a `.wav` file, e.g.:
```
clang++ -std=c++17 \
  -I/opt/homebrew/opt/onnxruntime/include/onnxruntime \
  -I/opt/homebrew/opt/sentencepiece/include \
  -L/opt/homebrew/opt/onnxruntime/lib -lonnxruntime \
  -L/opt/homebrew/opt/sentencepiece/lib -lsentencepiece \
  moss_tts.cpp moss_test.cpp -o moss_test
```

## 8. To re-enable as the active engine

`NihongoBuddy/App/NihongoBuddyApp.swift` constructs
`SpeechOutputRouter(primary: VoicevoxEngine(), fallback: AppleTTSFallback())` and passes it into
`ConversationEngine` as `SpeechOutput`. Swapping back to `MossTTSEngine` (it conforms to the same
`SpeechOutput` protocol) is a one-line change of `primary:` at that construction site — no other
app code depends on which engine is active.
