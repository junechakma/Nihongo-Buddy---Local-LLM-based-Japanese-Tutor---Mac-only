# §1.4 Audio Path Validation — Results

Date: 2026-07-04

## Pinned versions (§1.5)

| Component | Value |
|---|---|
| llama.cpp | build **9870** (`2d973636e`), Homebrew, ggml 0.15.3 |
| Main model | `gemma-4-E2B_q4_0-it.gguf` — 3,349,514,112 bytes |
| Audio projector | `mmproj-BF16.gguf` (unsloth/gemma-4-E2B-it-GGUF) — 986,833,728 bytes |
| mmproj SHA-256 | `a402f10fb5780bf91d03a10cd89061139f522bee2e679b1291bbfdcd71d9547d` |

Both files in `~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/`.

## Test results (macOS `say` Kyoko voice as speech source)

| Test | Input | Result |
|---|---|---|
| Clear JP | 昨日、友達と映画を見に行きました。とても面白かったです。 | ✅ Transcribed **verbatim**, correct simple-JP reply |
| JP/EN mixed | 昨日、映画を見ました。The movie was すごく面白い。 | ⚠️ JP perfect; "The movie was" heard as ザ・ムーブ — but Kyoko renders English with JP phonology, so partly source artifact |
| Audio encode time | 4s utterance | 121–140 ms |
| Full cold run (load + encode + ~100 tok) | — | 3.53 s wall (model load dominates; app keeps model resident) |

## Findings that affect the app build

1. **`--jinja` required** — default template path aborts (`std::runtime_error: this custom template is not supported`). In-app: use the model's Jinja chat template via llama.cpp's common chat API.
2. **Model has a thinking channel** — emits `<|channel>thought …<channel|>` before the reply; template shows a `<|think|>` toggle in the system turn. App MUST disable/strip thinking or latency and the `<heard>/<reply>` frame parsing break.
3. mmproj loads clean; llama.cpp prints "audio input is in experimental stage" warning — reinforces version pinning + CI smoke test (§9).

## Gate status

**PASS (provisional).** Synthetic-voice tests pass. Plan requires validation on real human speech (clear / mumbled / mixed). Record 16 kHz mono wavs of yourself and rerun:

```bash
llama-mtmd-cli \
  -m  ~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/gemma-4-E2B_q4_0-it.gguf \
  --mmproj ~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/mmproj-BF16.gguf \
  --jinja --audio your_voice.wav \
  -p "Transcribe this audio, then reply to it in simple Japanese."
```
