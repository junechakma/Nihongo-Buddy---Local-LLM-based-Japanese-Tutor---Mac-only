#ifndef MOSS_TTS_H
#define MOSS_TTS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle owning the ONNX Runtime sessions and SentencePiece tokenizer
/// for the MOSS-TTS-Nano pipeline (prefill → decode loop → local frame
/// sampler → audio-tokenizer decode).
typedef struct moss_tts_ctx moss_tts_ctx;

/// Static model configuration, read by Swift from browser_poc_manifest.json
/// and passed down on every synthesize call.
typedef struct {
    int32_t n_vq;                          /* number of RVQ codebooks (16) */
    int32_t row_width;                     /* n_vq + 1 */
    int32_t global_layers;                 /* transformer layers with KV cache (12) */
    int32_t audio_codebook_size;           /* per-codebook vocab (1024) */
    int32_t audio_pad_token_id;
    int32_t audio_assistant_slot_token_id;
    int32_t max_new_frames;
    int32_t sample_rate;                   /* codec output rate (48000) */
} moss_tts_params;

/// Load all ONNX sessions and the SentencePiece model. Returns NULL on
/// failure with a message in err_buf.
moss_tts_ctx *moss_tts_create(const char *prefill_path,
                              const char *decode_path,
                              const char *frame_path,
                              const char *codec_decode_path,
                              const char *spm_model_path,
                              int32_t n_threads,
                              char *err_buf, size_t err_buf_len);

/// SentencePiece-encode UTF-8 text. Returns the token count (which may
/// exceed capacity; only min(count, capacity) ids are written), or -1 on error.
int32_t moss_tts_tokenize(moss_tts_ctx *ctx, const char *utf8_text,
                          int32_t *out_ids, int32_t capacity);

/// Synthesize speech from prepared input rows (seq_len × row_width int32,
/// row-major), as built from the manifest prompt template + builtin voice
/// codes + text tokens. On success writes a malloc'd mono float PCM buffer
/// to *out_pcm (free with moss_tts_free_pcm).
/// Returns 0 = ok, 1 = error (see err_buf), 2 = cancelled.
int32_t moss_tts_synthesize(moss_tts_ctx *ctx, const moss_tts_params *params,
                            const int32_t *input_rows, int32_t seq_len,
                            uint64_t seed,
                            float **out_pcm, int32_t *out_pcm_len,
                            char *err_buf, size_t err_buf_len);

void moss_tts_free_pcm(float *pcm);

/// Abort the synthesis loop currently running on another thread.
void moss_tts_cancel(moss_tts_ctx *ctx);

void moss_tts_destroy(moss_tts_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif /* MOSS_TTS_H */
