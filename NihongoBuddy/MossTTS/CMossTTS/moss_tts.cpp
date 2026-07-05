// C shim around ONNX Runtime + SentencePiece for the MOSS-TTS-Nano pipeline.
// Port of the reference flow in MOSS-TTS-Nano/examples/android_onnx_runtime
// (MossOnnxDemoEngine.kt): prefill → per-frame decode with KV-cache feedback →
// local fixed-sampled-frame head → audio-tokenizer full decode.

#include "moss_tts.h"

#include <onnxruntime_cxx_api.h>
#include <sentencepiece_processor.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {

void set_error(char *buf, size_t len, const std::string &msg) {
    if (buf == nullptr || len == 0) return;
    std::snprintf(buf, len, "%s", msg.c_str());
}

// Reads an integer scalar/array tensor regardless of its element type
// (the exported graphs mix int32/int64/bool outputs).
std::vector<int32_t> tensor_to_ints(const Ort::Value &value) {
    auto info = value.GetTensorTypeAndShapeInfo();
    size_t count = info.GetElementCount();
    std::vector<int32_t> out(count);
    switch (info.GetElementType()) {
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: {
        const int32_t *p = value.GetTensorData<int32_t>();
        std::copy(p, p + count, out.begin());
        break;
    }
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: {
        const int64_t *p = value.GetTensorData<int64_t>();
        for (size_t i = 0; i < count; i++) out[i] = static_cast<int32_t>(p[i]);
        break;
    }
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: {
        const bool *p = value.GetTensorData<bool>();
        for (size_t i = 0; i < count; i++) out[i] = p[i] ? 1 : 0;
        break;
    }
    default:
        throw std::runtime_error("unsupported int tensor element type");
    }
    return out;
}

// Copies the hidden state of the LAST sequence position into a fresh
// [1, hidden] tensor (mirrors extractLastHiddenTensor in the Kotlin demo).
Ort::Value extract_last_hidden(const Ort::Value &tensor, std::vector<float> &storage) {
    auto info = tensor.GetTensorTypeAndShapeInfo();
    std::vector<int64_t> shape = info.GetShape();
    const float *data = tensor.GetTensorData<float>();
    int64_t hidden = shape.back();
    int64_t rows = 1;
    for (size_t i = 0; i + 1 < shape.size(); i++) rows *= shape[i];
    const float *last = data + (rows - 1) * hidden;
    storage.assign(last, last + hidden);
    std::vector<int64_t> out_shape{1, hidden};
    auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    return Ort::Value::CreateTensor<float>(mem, storage.data(), storage.size(),
                                           out_shape.data(), out_shape.size());
}

} // namespace

struct moss_tts_ctx {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "moss-tts"};
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> prefill;
    std::unique_ptr<Ort::Session> decode;
    std::unique_ptr<Ort::Session> frame;
    std::unique_ptr<Ort::Session> codec;
    sentencepiece::SentencePieceProcessor sp;
    std::atomic<bool> cancelled{false};
};

moss_tts_ctx *moss_tts_create(const char *prefill_path,
                              const char *decode_path,
                              const char *frame_path,
                              const char *codec_decode_path,
                              const char *spm_model_path,
                              int32_t n_threads,
                              char *err_buf, size_t err_buf_len) {
    try {
        auto ctx = std::make_unique<moss_tts_ctx>();
        ctx->options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        ctx->options.SetIntraOpNumThreads(std::max<int32_t>(1, n_threads));
        ctx->options.SetInterOpNumThreads(1);
        ctx->prefill = std::make_unique<Ort::Session>(ctx->env, prefill_path, ctx->options);
        ctx->decode = std::make_unique<Ort::Session>(ctx->env, decode_path, ctx->options);
        ctx->frame = std::make_unique<Ort::Session>(ctx->env, frame_path, ctx->options);
        ctx->codec = std::make_unique<Ort::Session>(ctx->env, codec_decode_path, ctx->options);
        auto status = ctx->sp.Load(spm_model_path);
        if (!status.ok()) {
            set_error(err_buf, err_buf_len, "sentencepiece load failed: " + status.ToString());
            return nullptr;
        }
        return ctx.release();
    } catch (const std::exception &e) {
        set_error(err_buf, err_buf_len, e.what());
        return nullptr;
    }
}

int32_t moss_tts_tokenize(moss_tts_ctx *ctx, const char *utf8_text,
                          int32_t *out_ids, int32_t capacity) {
    if (ctx == nullptr || utf8_text == nullptr) return -1;
    std::vector<int> ids;
    auto status = ctx->sp.Encode(utf8_text, &ids);
    if (!status.ok()) return -1;
    int32_t n = static_cast<int32_t>(ids.size());
    for (int32_t i = 0; i < std::min(n, capacity); i++) out_ids[i] = ids[i];
    return n;
}

int32_t moss_tts_synthesize(moss_tts_ctx *ctx, const moss_tts_params *params,
                            const int32_t *input_rows, int32_t seq_len,
                            uint64_t seed,
                            float **out_pcm, int32_t *out_pcm_len,
                            char *err_buf, size_t err_buf_len) {
    if (ctx == nullptr || params == nullptr || input_rows == nullptr || seq_len <= 0) {
        set_error(err_buf, err_buf_len, "invalid arguments");
        return 1;
    }
    ctx->cancelled.store(false);
    const int32_t n_vq = params->n_vq;
    const int32_t row_width = params->row_width;
    const int32_t layers = params->global_layers;
    const int32_t codebook = params->audio_codebook_size;
    auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    try {
        // ---- Prefill ----------------------------------------------------
        std::vector<int32_t> ids(input_rows, input_rows + (size_t)seq_len * row_width);
        std::vector<int32_t> mask(seq_len, 1);
        std::vector<int64_t> ids_shape{1, seq_len, row_width};
        std::vector<int64_t> mask_shape{1, seq_len};
        std::vector<Ort::Value> prefill_inputs;
        prefill_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
            mem, ids.data(), ids.size(), ids_shape.data(), ids_shape.size()));
        prefill_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
            mem, mask.data(), mask.size(), mask_shape.data(), mask_shape.size()));

        // KV-cache tensor names follow the fixed pattern in tts_browser_onnx_meta.json.
        std::vector<std::string> kv_names;
        for (int32_t l = 0; l < layers; l++) {
            kv_names.push_back("present_key_" + std::to_string(l));
            kv_names.push_back("present_value_" + std::to_string(l));
        }
        std::vector<std::string> past_names;
        for (int32_t l = 0; l < layers; l++) {
            past_names.push_back("past_key_" + std::to_string(l));
            past_names.push_back("past_value_" + std::to_string(l));
        }

        std::vector<const char *> prefill_input_names{"input_ids", "attention_mask"};
        std::vector<const char *> prefill_output_names{"global_hidden"};
        for (auto &n : kv_names) prefill_output_names.push_back(n.c_str());

        auto prefill_out = ctx->prefill->Run(
            Ort::RunOptions{nullptr},
            prefill_input_names.data(), prefill_inputs.data(), prefill_inputs.size(),
            prefill_output_names.data(), prefill_output_names.size());

        std::vector<float> hidden_storage;
        Ort::Value global_hidden = extract_last_hidden(prefill_out[0], hidden_storage);
        // Keep KV values (indices 1..) alive across decode steps.
        std::vector<Ort::Value> past;
        for (size_t i = 1; i < prefill_out.size(); i++) past.push_back(std::move(prefill_out[i]));
        int32_t past_valid = seq_len;

        // ---- Decode loop -------------------------------------------------
        std::mt19937_64 rng(seed);
        std::uniform_real_distribution<double> uniform(1e-6, 1.0 - 1e-6);
        std::vector<std::vector<int32_t>> frames;
        std::vector<char> seen((size_t)n_vq * codebook, 0);

        std::vector<const char *> frame_input_names{
            "global_hidden", "repetition_seen_mask", "assistant_random_u", "audio_random_u"};
        std::vector<const char *> frame_output_names{"should_continue", "frame_token_ids"};

        std::vector<const char *> decode_input_names{"input_ids", "past_valid_lengths"};
        for (auto &n : past_names) decode_input_names.push_back(n.c_str());
        std::vector<const char *> decode_output_names{"global_hidden"};
        for (auto &n : kv_names) decode_output_names.push_back(n.c_str());

        const int32_t max_frames = std::max<int32_t>(1, params->max_new_frames);
        for (int32_t step = 0; step < max_frames; step++) {
            if (ctx->cancelled.load()) return 2;

            // Local frame head: sampling happens inside the graph; we only
            // supply uniform randoms and the repetition mask.
            std::vector<int32_t> seen_mask(seen.begin(), seen.end());
            std::vector<int64_t> seen_shape{1, n_vq, codebook};
            float assistant_u = (float)uniform(rng);
            std::vector<float> audio_u(n_vq);
            for (auto &u : audio_u) u = (float)uniform(rng);
            std::vector<int64_t> one_shape{1};
            std::vector<int64_t> audio_u_shape{1, n_vq};

            std::vector<Ort::Value> frame_inputs;
            frame_inputs.push_back(std::move(global_hidden));
            frame_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
                mem, seen_mask.data(), seen_mask.size(), seen_shape.data(), seen_shape.size()));
            frame_inputs.push_back(Ort::Value::CreateTensor<float>(
                mem, &assistant_u, 1, one_shape.data(), one_shape.size()));
            frame_inputs.push_back(Ort::Value::CreateTensor<float>(
                mem, audio_u.data(), audio_u.size(), audio_u_shape.data(), audio_u_shape.size()));

            auto frame_out = ctx->frame->Run(
                Ort::RunOptions{nullptr},
                frame_input_names.data(), frame_inputs.data(), frame_inputs.size(),
                frame_output_names.data(), frame_output_names.size());
            global_hidden = std::move(frame_inputs[0]); // take ownership back

            bool should_continue = !tensor_to_ints(frame_out[0]).empty() &&
                                   tensor_to_ints(frame_out[0])[0] > 0;
            if (!should_continue) break;
            std::vector<int32_t> frame_tokens = tensor_to_ints(frame_out[1]);
            frame_tokens.resize(n_vq);
            frames.push_back(frame_tokens);
            for (int32_t q = 0; q < n_vq; q++) {
                int32_t t = frame_tokens[q];
                if (t >= 0 && t < codebook) seen[(size_t)q * codebook + t] = 1;
            }

            // Global decode step: feed the new audio row + previous KV cache.
            std::vector<int32_t> row(row_width, params->audio_pad_token_id);
            row[0] = params->audio_assistant_slot_token_id;
            for (int32_t q = 0; q < n_vq; q++) row[q + 1] = frame_tokens[q];
            std::vector<int64_t> row_shape{1, 1, row_width};
            std::vector<Ort::Value> decode_inputs;
            decode_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
                mem, row.data(), row.size(), row_shape.data(), row_shape.size()));
            decode_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
                mem, &past_valid, 1, one_shape.data(), one_shape.size()));
            for (auto &kv : past) decode_inputs.push_back(std::move(kv));

            auto decode_out = ctx->decode->Run(
                Ort::RunOptions{nullptr},
                decode_input_names.data(), decode_inputs.data(), decode_inputs.size(),
                decode_output_names.data(), decode_output_names.size());

            global_hidden = extract_last_hidden(decode_out[0], hidden_storage);
            past.clear();
            for (size_t i = 1; i < decode_out.size(); i++) past.push_back(std::move(decode_out[i]));
            past_valid += 1;
        }

        if (frames.empty()) {
            set_error(err_buf, err_buf_len, "no audio frames generated");
            return 1;
        }

        // ---- Audio tokenizer decode --------------------------------------
        int32_t n_frames = (int32_t)frames.size();
        std::vector<int32_t> codes((size_t)n_frames * n_vq);
        for (int32_t f = 0; f < n_frames; f++)
            for (int32_t q = 0; q < n_vq; q++)
                codes[(size_t)f * n_vq + q] = frames[f][q];
        std::vector<int64_t> codes_shape{1, n_frames, n_vq};
        std::vector<int64_t> one_shape{1};
        std::vector<Ort::Value> codec_inputs;
        codec_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
            mem, codes.data(), codes.size(), codes_shape.data(), codes_shape.size()));
        codec_inputs.push_back(Ort::Value::CreateTensor<int32_t>(
            mem, &n_frames, 1, one_shape.data(), one_shape.size()));
        std::vector<const char *> codec_input_names{"audio_codes", "audio_code_lengths"};
        std::vector<const char *> codec_output_names{"audio", "audio_lengths"};

        auto codec_out = ctx->codec->Run(
            Ort::RunOptions{nullptr},
            codec_input_names.data(), codec_inputs.data(), codec_inputs.size(),
            codec_output_names.data(), codec_output_names.size());

        auto audio_info = codec_out[0].GetTensorTypeAndShapeInfo();
        std::vector<int64_t> audio_shape = audio_info.GetShape(); // [1, ch, len]
        if (audio_shape.size() != 3) {
            set_error(err_buf, err_buf_len, "unexpected codec audio rank");
            return 1;
        }
        int64_t channels = audio_shape[1];
        int64_t length = audio_shape[2];
        int32_t reported = tensor_to_ints(codec_out[1])[0];
        int64_t final_len = std::min<int64_t>(length, reported);
        const float *audio = codec_out[0].GetTensorData<float>();

        float *pcm = (float *)std::malloc(sizeof(float) * (size_t)final_len);
        if (pcm == nullptr) {
            set_error(err_buf, err_buf_len, "out of memory");
            return 1;
        }
        for (int64_t i = 0; i < final_len; i++) {
            double sum = 0.0;
            for (int64_t c = 0; c < channels; c++) sum += audio[c * length + i];
            pcm[i] = (float)(sum / (double)channels);
        }
        *out_pcm = pcm;
        *out_pcm_len = (int32_t)final_len;
        return 0;
    } catch (const std::exception &e) {
        set_error(err_buf, err_buf_len, e.what());
        return 1;
    }
}

void moss_tts_free_pcm(float *pcm) { std::free(pcm); }

void moss_tts_cancel(moss_tts_ctx *ctx) {
    if (ctx != nullptr) ctx->cancelled.store(true);
}

void moss_tts_destroy(moss_tts_ctx *ctx) { delete ctx; }
