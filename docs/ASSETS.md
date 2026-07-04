# Nihongo Buddy — Model Assets & Locations (dev)

Where every runtime asset lives during development. All dirs are hidden — in Finder press `Cmd+Shift+.` or use `Cmd+Shift+G` with the path.

| What | Role | Location | Size |
|---|---|---|---|
| Gemma 4 E2B Q4_0 QAT (GGUF) | Brain — listening + conversation | `~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/gemma-4-E2B_q4_0-it.gguf` | 3.35 GB |
| Audio projector BF16 | Ears — feeds mic audio into Gemma (no STT) | `~/.lmstudio/models/google/gemma-4-E2B-it-qat-q4_0-gguf/mmproj-BF16.gguf` | 987 MB |
| VOICEVOX core 0.16.4 | Voice (Japanese) — expressive character TTS, pitch-accent correct | `<project>/Vendor/voicevox_core-osx-arm64-0.16.4/` + `Vendor/voicevox/models/0.vvm` + `Vendor/open_jtalk_dic_utf_8-1.11/` + `Vendor/voicevox_onnxruntime-osx-arm64-1.17.3/` | ~120 MB |
| Kokoro-82M CoreML | Voice (English sentences only) | `~/Library/Caches/qwen3-speech/models/aufklarer/Kokoro-82M-CoreML/` | ~330 MB |
| llama.cpp dylibs (build 9870, pinned) | Inference runtime | `/opt/homebrew/opt/llama.cpp/lib/` (Homebrew) | — |
| Mistake/learning DB | Buddy's memory of your mistakes | `~/Library/Application Support/NihongoBuddy/memory.sqlite` | tiny |

## Kokoro cache contents

Downloaded from Hugging Face `aufklarer/Kokoro-82M-CoreML` by speech-swift on first warm-up:

- `kokoro_5s.mlmodelc/` — synthesizer; `weights/weight.bin` is 309 MB (82M params × 4 bytes fp32). The in-app downloader repeatedly failed on this one file; it was fetched manually with curl into the cache (2026-07-04).
- `G2PEncoder.mlmodelc` / `G2PDecoder.mlmodelc` — grapheme-to-phoneme
- `voices/*.json` — 54 voice styles; app uses `jf_alpha` (ja) and `af_heart` (en)
- `config.json`, `pipeline_config.json`, vocab files

## VOICEVOX notes

- JP sentences → VOICEVOX; EN sentences → Kokoro (VOICEVOX is Japanese-only).
- Default style: ずんだもん あまあま (style ID 1). Switch without rebuild:
  `defaults write com.junechakma.NihongoBuddy voicevoxStyleId -int 3`
  (0.vvm talk styles — 四国めたん: あまあま=0 ノーマル=2 セクシー=4 ツンツン=6; ずんだもん: あまあま=1 ノーマル=3 セクシー=5 ツンツン=7)
- **License: free incl. commercial, BUT the shipped app MUST display "VOICEVOX:ずんだもん" (per character used) in About/credits.** No credit = paid license.
- More characters = more .vvm files from github.com/VOICEVOX/voicevox_vvm releases.

## Integrity references

- mmproj SHA-256: `a402f10fb5780bf91d03a10cd89061139f522bee2e679b1291bbfdcd71d9547d` (see docs/VALIDATION.md)
- speech-swift pinned: v0.0.21
- llama.cpp pinned: Homebrew build 9870 (`2d973636e`)

## Ship plan (PROCEDURE.md §8)

Release builds do NOT use these dev paths. First launch downloads main GGUF + mmproj + Kokoro assets to `~/Library/Application Support/NihongoBuddy/models/` with SHA-256 verify + resume; `ModelManager` already prefers the LM Studio dev path only in DEBUG builds. After download: zero network.
