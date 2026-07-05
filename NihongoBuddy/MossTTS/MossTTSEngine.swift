import AVFoundation
import CMossTTS

/// MOSS-TTS-Nano running fully natively via ONNX Runtime (C++ shim in
/// CMossTTS). One model speaks both Japanese and English; the voice is a
/// builtin cloned speaker whose reference audio codes ship in the manifest.
///
/// Voice overrides:
///   defaults write com.junechakma.NihongoBuddy mossVoiceJa -string "Saki"
///   defaults write com.junechakma.NihongoBuddy mossVoiceEn -string "Ava"
actor MossTTSEngine: SpeechOutput {
    private static let modelRoot = URL(fileURLWithPath:
        "/Users/junechakma/Freelance/June Chakma/Nihongo Buddy/Nihongo Buddy/Vendor/moss-tts-onnx")
    private static var ttsDir: URL { modelRoot.appendingPathComponent("MOSS-TTS-Nano-100M-ONNX") }
    private static var codecDir: URL { modelRoot.appendingPathComponent("MOSS-Audio-Tokenizer-Nano-ONNX") }

    private static var japaneseVoice: String {
        UserDefaults.standard.string(forKey: "mossVoiceJa") ?? "Soyo"
    }
    private static var englishVoice: String {
        UserDefaults.standard.string(forKey: "mossVoiceEn") ?? "Ava"
    }

    private var ctx: OpaquePointer?
    private var manifest: MossManifest?
    private var sampleRate: Int = 48_000
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var stopped = false

    struct MossTTSError: Error, CustomStringConvertible {
        let message: String
        var description: String { "MossTTS: \(message)" }
    }

    func warmUp() async throws {
        guard ctx == nil else { return }

        let manifest = try MossManifest.load(
            from: Self.ttsDir.appendingPathComponent("browser_poc_manifest.json"))
        let codecMeta = try MossCodecMeta.load(
            from: Self.codecDir.appendingPathComponent("codec_browser_onnx_meta.json"))
        self.manifest = manifest
        self.sampleRate = codecMeta.codecConfig.sampleRate

        var errBuf = [CChar](repeating: 0, count: 1024)
        let created = moss_tts_create(
            Self.ttsDir.appendingPathComponent("moss_tts_prefill.onnx").path,
            Self.ttsDir.appendingPathComponent("moss_tts_decode_step.onnx").path,
            Self.ttsDir.appendingPathComponent("moss_tts_local_fixed_sampled_frame.onnx").path,
            Self.codecDir.appendingPathComponent(codecMeta.files.decodeFull).path,
            Self.ttsDir.appendingPathComponent(manifest.modelFiles.tokenizerModel).path,
            Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2)),
            &errBuf, errBuf.count)
        guard let created else {
            throw MossTTSError(message: String(cString: errBuf))
        }
        ctx = created

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode,
                            format: AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1))
        try audioEngine.start()

        print("MossTTSEngine: ready (voices ja=\(Self.japaneseVoice) en=\(Self.englishVoice), \(sampleRate) Hz)")
    }

    func speak(_ sentences: AsyncStream<Sentence>) async {
        stopped = false
        if !audioEngine.isRunning { try? audioEngine.start() }
        playerNode.play()

        var completions: [Task<Void, Never>] = []

        for await sentence in sentences {
            if stopped { break }
            guard let buffer = synthesize(sentence) else { continue }
            if stopped { break }

            let done = Task { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    c.resume()
                }
            } }
            completions.append(done)
        }

        for task in completions { await task.value }
    }

    func stop() async {
        stopped = true
        if let ctx { moss_tts_cancel(ctx) }
        playerNode.stop()
    }

    private func synthesize(_ sentence: Sentence) -> AVAudioPCMBuffer? {
        guard let ctx, let manifest else { return nil }

        let voiceName = sentence.script == .japanese ? Self.japaneseVoice : Self.englishVoice
        guard let voice = manifest.voice(named: voiceName)
                ?? manifest.builtinVoices.first(where: { !$0.promptAudioCodes.isEmpty }) else {
            print("MossTTSEngine: no builtin voice available")
            return nil
        }

        var tokens = [Int32](repeating: 0, count: 512)
        let count = moss_tts_tokenize(ctx, sentence.text, &tokens, Int32(tokens.count))
        guard count > 0 else {
            print("MossTTSEngine: tokenize failed for \"\(sentence.text)\"")
            return nil
        }
        tokens = Array(tokens.prefix(Int(min(count, Int32(tokens.count)))))

        let rows = manifest.buildInputRows(textTokenIds: tokens, voice: voice)
        let cfg = manifest.ttsConfig
        let rowWidth = cfg.nVq + 1
        var params = moss_tts_params(
            n_vq: Int32(cfg.nVq),
            row_width: Int32(rowWidth),
            global_layers: 12,
            audio_codebook_size: cfg.audioCodebookSizes.first ?? 1024,
            audio_pad_token_id: cfg.audioPadTokenId,
            audio_assistant_slot_token_id: cfg.audioAssistantSlotTokenId,
            max_new_frames: manifest.generationDefaults.maxNewFrames,
            sample_rate: Int32(sampleRate))

        var pcm: UnsafeMutablePointer<Float>?
        var pcmLen: Int32 = 0
        var errBuf = [CChar](repeating: 0, count: 1024)
        let status = rows.withUnsafeBufferPointer { ptr in
            moss_tts_synthesize(ctx, &params, ptr.baseAddress, Int32(rows.count / rowWidth),
                                UInt64.random(in: 1...UInt64.max),
                                &pcm, &pcmLen, &errBuf, errBuf.count)
        }
        guard status == 0, let pcm, pcmLen > 0 else {
            if status == 1 { print("MossTTSEngine: synthesis failed — \(String(cString: errBuf))") }
            return nil
        }
        defer { moss_tts_free_pcm(pcm) }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcmLen)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(pcmLen)
        let out = buffer.floatChannelData![0]
        out.update(from: pcm, count: Int(pcmLen))

        // Builtin voices differ a lot in reference loudness (Soyo peaks ~0.08,
        // Ava ~0.43) — peak-normalize per sentence, with a gain cap so silence
        // isn't blown up into noise.
        var peak: Float = 0
        for i in 0..<Int(pcmLen) { peak = max(peak, abs(out[i])) }
        if peak > 0.001 {
            let gain = min(0.7 / peak, 12.0)
            if gain > 1.05 {
                for i in 0..<Int(pcmLen) { out[i] *= gain }
            }
        }
        return buffer
    }
}
