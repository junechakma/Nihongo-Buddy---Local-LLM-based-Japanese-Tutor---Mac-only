import AVFoundation
import CVoicevox

/// VOICEVOX for Japanese sentences — expressive character voices with proper
/// pitch accent (OpenJTalk frontend). English sentences route to Kokoro,
/// which is English's home turf; VOICEVOX is Japanese-only.
///
/// Credit requirement: shipping builds must show "VOICEVOX:<character>" in the
/// About panel (docs/ASSETS.md).
///
/// Style ID picks the character AND emotion. Loaded models:
///   0.vvm 四国めたん あまあま=0 ノーマル=2 / ずんだもん あまあま=1 ノーマル=3 ツンツン=7
///   1.vvm 冥鳴ひまり ノーマル=14 (refined adult)
///   2.vvm 九州そら ノーマル=16 あまあま=15 セクシー=17 ツンツン=18 ささやき=19 (calm adult, default)
///
/// Default character: 九州そら — the reply's emotion attribute selects among
/// her built-in expression styles per sentence. Pin a fixed style instead with:
///   defaults write com.junechakma.NihongoBuddy voicevoxStyleId -int 14
actor VoicevoxEngine: SpeechOutput {
    private static let vendorDir = URL(fileURLWithPath: "/Users/junechakma/Freelance/June Chakma/Nihongo Buddy/Nihongo Buddy/Vendor")
    private static var onnxruntimePath: String {
        vendorDir.appendingPathComponent("voicevox_onnxruntime-osx-arm64-1.17.3/lib/libvoicevox_onnxruntime.1.17.3.dylib").path
    }
    private static var dictDir: String {
        vendorDir.appendingPathComponent("open_jtalk_dic_utf_8-1.11").path
    }
    private static var modelsDir: URL {
        vendorDir.appendingPathComponent("voicevox/models")
    }

    /// Fixed style override; 0/unset = emotion-driven 九州そら styles.
    private static var pinnedStyleId: UInt32? {
        let value = UserDefaults.standard.integer(forKey: "voicevoxStyleId")
        return value > 0 ? UInt32(value) : nil
    }

    /// Default: 九州そら ノーマル — plain, standard Japanese voice. Emotion
    /// styles proved too much; pin another style via "voicevoxStyleId" if wanted.
    private static func styleId(for emotion: OutputFrameParser.Emotion) -> UInt32 {
        pinnedStyleId ?? 16 // 九州そら ノーマル
    }

    private var synthesizer: OpaquePointer?
    private let english = KokoroEngine()
    private var englishReady = false
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let englishFallback = AppleTTSFallback()
    private var stopped = false

    /// Native VOICEVOX speedScale. Tune: defaults write com.junechakma.NihongoBuddy voicevoxRate -float 1.2
    private static var playbackRate: Float {
        let value = UserDefaults.standard.float(forKey: "voicevoxRate")
        return value > 0 ? value : 1.12
    }

    /// Native VOICEVOX volumeScale — output gain applied at synthesis time
    /// (some character styles are much quieter than others). >1.0 boosts.
    private static var volumeScale: Float {
        let value = UserDefaults.standard.float(forKey: "voicevoxVolume")
        return value > 0 ? value : 1.0
    }

    struct VoicevoxError: Error, CustomStringConvertible {
        let code: Int32
        let stage: String
        var description: String {
            "VOICEVOX \(stage): \(String(cString: voicevox_error_result_to_message(code)))"
        }
    }

    func warmUp() async throws {
        guard synthesizer == nil else { return }

        var onnxruntime: OpaquePointer?
        var loadOptions = voicevox_make_default_load_onnxruntime_options()
        try Self.onnxruntimePath.withCString { path in
            loadOptions.filename = path
            let code = voicevox_onnxruntime_load_once(loadOptions, &onnxruntime)
            guard code == 0 else { throw VoicevoxError(code: code, stage: "onnxruntime load") }
        }

        var openJtalk: OpaquePointer?
        var code = voicevox_open_jtalk_rc_new(Self.dictDir, &openJtalk)
        guard code == 0 else { throw VoicevoxError(code: code, stage: "open_jtalk dict") }

        var synth: OpaquePointer?
        code = voicevox_synthesizer_new(onnxruntime, openJtalk, voicevox_make_default_initialize_options(), &synth)
        voicevox_open_jtalk_rc_delete(openJtalk)
        guard code == 0 else { throw VoicevoxError(code: code, stage: "synthesizer init") }

        let vvms = (try? FileManager.default.contentsOfDirectory(at: Self.modelsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "vvm" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !vvms.isEmpty else { throw VoicevoxError(code: 0, stage: "no .vvm models found") }
        for vvm in vvms {
            var model: OpaquePointer?
            code = voicevox_voice_model_file_open(vvm.path, &model)
            guard code == 0 else { throw VoicevoxError(code: code, stage: "open \(vvm.lastPathComponent)") }
            code = voicevox_synthesizer_load_voice_model(synth, model)
            voicevox_voice_model_file_delete(model)
            guard code == 0 else { throw VoicevoxError(code: code, stage: "load \(vvm.lastPathComponent)") }
        }

        self.synthesizer = synth

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode,
                            format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        try audioEngine.start()

        // English side is best-effort — Japanese must not fail because of it.
        do { try await english.warmUp(); englishReady = true } catch {
            print("VoicevoxEngine: Kokoro (English) unavailable, Apple TTS for English — \(error)")
            try? await englishFallback.warmUp()
        }

        _ = try? synthesizeWav("こんにちは", style: Self.styleId(for: .neutral)) // warm inference path
        print("VoicevoxEngine: ready (\(vvms.count) models, default 九州そら)")
    }

    func speak(_ sentences: AsyncStream<Sentence>) async {
        stopped = false
        if !audioEngine.isRunning { try? audioEngine.start() }
        playerNode.play()

        var completions: [Task<Void, Never>] = []

        for await sentence in sentences {
            if stopped { break }
            if sentence.script == .english {
                // English never goes to VOICEVOX (Japanese-only): Kokoro if
                // loaded, otherwise the Apple system voice. Await to keep order.
                let stream = AsyncStream<Sentence> { c in c.yield(sentence); c.finish() }
                if englishReady {
                    await english.speak(stream)
                } else {
                    await englishFallback.speak(stream)
                }
                continue
            }
            guard let wav = try? synthesizeWav(sentence.text, style: Self.styleId(for: sentence.emotion)),
                  let buffer = Self.pcmBuffer(fromWav: wav) else { continue }
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
        playerNode.stop()
        if englishReady { await english.stop() }
        await englishFallback.stop()
    }

    private func synthesizeWav(_ text: String, style: UInt32) throws -> Data {
        guard let synthesizer else { throw VoicevoxError(code: 0, stage: "not warmed up") }

        // audio_query → adjust speedScale → synthesis. Speed handled by the
        // model itself: natural prosody, no time-stretch DSP artifacts.
        var queryJson: UnsafeMutablePointer<CChar>?
        var code = voicevox_synthesizer_create_audio_query(synthesizer, text, style, &queryJson)
        guard code == 0, let queryJson else { throw VoicevoxError(code: code, stage: "audio_query") }
        var query = String(cString: queryJson)
        voicevox_json_free(queryJson)

        query = query.replacingOccurrences(of: "\"speedScale\":1.0",
                                           with: "\"speedScale\":\(Self.playbackRate)")
        query = query.replacingOccurrences(of: "\"volumeScale\":1.0",
                                           with: "\"volumeScale\":\(Self.volumeScale)")

        var wavLength: UInt = 0
        var wavPointer: UnsafeMutablePointer<UInt8>?
        code = voicevox_synthesizer_synthesis(synthesizer, query, style,
                                              voicevox_make_default_synthesis_options(),
                                              &wavLength, &wavPointer)
        guard code == 0, let wavPointer else { throw VoicevoxError(code: code, stage: "synthesis") }
        defer { voicevox_wav_free(wavPointer) }
        return Data(bytes: wavPointer, count: Int(wavLength))
    }

    /// Parse the WAV VOICEVOX returns (16-bit PCM mono 24 kHz) into a float buffer.
    private static func pcmBuffer(fromWav data: Data) -> AVAudioPCMBuffer? {
        // Locate the "data" chunk rather than assuming a 44-byte header.
        guard let range = data.range(of: Data("data".utf8), in: 12..<min(data.count, 512)) else { return nil }
        let sizeOffset = range.upperBound
        guard data.count >= sizeOffset + 4 else { return nil }
        let chunkSize = data.subdata(in: sizeOffset..<sizeOffset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let start = sizeOffset + 4
        let byteCount = min(Int(chunkSize), data.count - start)
        let sampleCount = byteCount / 2

        guard sampleCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        data.subdata(in: start..<start + byteCount).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16 = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<sampleCount {
                out[i] = Float(Int16(littleEndian: int16[i])) / 32768.0
            }
        }
        return buffer
    }
}
