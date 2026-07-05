import Foundation

/// Decoded browser_poc_manifest.json from MOSS-TTS-Nano-100M-ONNX. Holds the
/// prompt template token ids and the builtin voices' pre-tokenized reference
/// audio codes, so no audio encoder is needed at runtime.
struct MossManifest: Decodable {
    struct ModelFiles: Decodable {
        let ttsMeta: String
        let codecMeta: String
        let tokenizerModel: String

        enum CodingKeys: String, CodingKey {
            case ttsMeta = "tts_meta"
            case codecMeta = "codec_meta"
            case tokenizerModel = "tokenizer_model"
        }
    }

    struct TTSConfig: Decodable {
        let nVq: Int
        let audioPadTokenId: Int32
        let audioStartTokenId: Int32
        let audioEndTokenId: Int32
        let audioUserSlotTokenId: Int32
        let audioAssistantSlotTokenId: Int32
        let audioCodebookSizes: [Int32]

        enum CodingKeys: String, CodingKey {
            case nVq = "n_vq"
            case audioPadTokenId = "audio_pad_token_id"
            case audioStartTokenId = "audio_start_token_id"
            case audioEndTokenId = "audio_end_token_id"
            case audioUserSlotTokenId = "audio_user_slot_token_id"
            case audioAssistantSlotTokenId = "audio_assistant_slot_token_id"
            case audioCodebookSizes = "audio_codebook_sizes"
        }
    }

    struct PromptTemplates: Decodable {
        let userPromptPrefixTokenIds: [Int32]
        let userPromptAfterReferenceTokenIds: [Int32]
        let assistantPromptPrefixTokenIds: [Int32]

        enum CodingKeys: String, CodingKey {
            case userPromptPrefixTokenIds = "user_prompt_prefix_token_ids"
            case userPromptAfterReferenceTokenIds = "user_prompt_after_reference_token_ids"
            case assistantPromptPrefixTokenIds = "assistant_prompt_prefix_token_ids"
        }
    }

    struct GenerationDefaults: Decodable {
        let maxNewFrames: Int32

        enum CodingKeys: String, CodingKey {
            case maxNewFrames = "max_new_frames"
        }
    }

    struct BuiltinVoice: Decodable {
        let voice: String
        let displayName: String?
        let group: String?
        let promptAudioCodes: [[Int32]]

        enum CodingKeys: String, CodingKey {
            case voice
            case displayName = "display_name"
            case group
            case promptAudioCodes = "prompt_audio_codes"
        }
    }

    let modelFiles: ModelFiles
    let ttsConfig: TTSConfig
    let promptTemplates: PromptTemplates
    let generationDefaults: GenerationDefaults
    let builtinVoices: [BuiltinVoice]

    enum CodingKeys: String, CodingKey {
        case modelFiles = "model_files"
        case ttsConfig = "tts_config"
        case promptTemplates = "prompt_templates"
        case generationDefaults = "generation_defaults"
        case builtinVoices = "builtin_voices"
    }

    static func load(from url: URL) throws -> MossManifest {
        try JSONDecoder().decode(MossManifest.self, from: Data(contentsOf: url))
    }

    func voice(named name: String) -> BuiltinVoice? {
        builtinVoices.first { $0.voice == name && !$0.promptAudioCodes.isEmpty }
    }

    /// Builds the prefill input rows (seq_len × (nVq+1), row-major) for one
    /// utterance: template prefix, reference audio codes, then the text and
    /// the assistant audio-start marker. Mirrors buildInputRows in the
    /// Android ONNX reference example.
    func buildInputRows(textTokenIds: [Int32], voice: BuiltinVoice) -> [Int32] {
        let cfg = ttsConfig
        let rowWidth = cfg.nVq + 1
        var rows: [Int32] = []

        func appendTextRow(_ token: Int32) {
            rows.append(token)
            rows.append(contentsOf: [Int32](repeating: cfg.audioPadTokenId, count: cfg.nVq))
        }
        func appendAudioRow(_ codes: [Int32]) {
            rows.append(cfg.audioUserSlotTokenId)
            for q in 0..<cfg.nVq {
                rows.append(q < codes.count ? codes[q] : cfg.audioPadTokenId)
            }
        }

        for token in promptTemplates.userPromptPrefixTokenIds { appendTextRow(token) }
        appendTextRow(cfg.audioStartTokenId)
        for codes in voice.promptAudioCodes { appendAudioRow(codes) }
        appendTextRow(cfg.audioEndTokenId)
        for token in promptTemplates.userPromptAfterReferenceTokenIds { appendTextRow(token) }
        for token in textTokenIds { appendTextRow(token) }
        for token in promptTemplates.assistantPromptPrefixTokenIds { appendTextRow(token) }
        appendTextRow(cfg.audioStartTokenId)

        assert(rows.count % rowWidth == 0)
        return rows
    }
}

/// Minimal slice of codec_browser_onnx_meta.json — only the sample rate and
/// decoder file name are needed.
struct MossCodecMeta: Decodable {
    struct Files: Decodable {
        let decodeFull: String
        enum CodingKeys: String, CodingKey { case decodeFull = "decode_full" }
    }
    struct CodecConfig: Decodable {
        let sampleRate: Int
        enum CodingKeys: String, CodingKey { case sampleRate = "sample_rate" }
    }

    let files: Files
    let codecConfig: CodecConfig

    enum CodingKeys: String, CodingKey {
        case files
        case codecConfig = "codec_config"
    }

    static func load(from url: URL) throws -> MossCodecMeta {
        try JSONDecoder().decode(MossCodecMeta.self, from: Data(contentsOf: url))
    }
}
