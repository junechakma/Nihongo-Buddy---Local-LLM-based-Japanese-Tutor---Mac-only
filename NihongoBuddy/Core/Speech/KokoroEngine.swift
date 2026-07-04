import AVFoundation
import KokoroTTS

/// Kokoro-82M on CoreML/ANE via speech-swift (§4). Japanese voice jf_alpha,
/// English sentences use af_heart (§4.3 sentence-level voice switching).
///
/// Producer/consumer: sentences synthesize serially and feed a gapless
/// AVAudioPlayerNode queue — sentence N+1 synthesizes while N plays.
actor KokoroEngine: SpeechOutput {
    private static let sampleRate: Double = 24_000
    // Japanese voices available: jf_alpha, jf_gongitsune, jf_nezumi, jf_tebukuro, jm_kumo.
    // Change via UserDefaults key "kokoroJapaneseVoice" (no rebuild needed):
    //   defaults write com.junechakma.NihongoBuddy kokoroJapaneseVoice jf_gongitsune
    private static var japaneseVoice: String {
        UserDefaults.standard.string(forKey: "kokoroJapaneseVoice") ?? "jf_alpha"
    }
    private static let englishVoice = "af_heart"
    // Slightly slower than 1.0 — clearer for a learner and softens G2P roughness.
    private static let speed: Float = 0.9

    private var model: KokoroTTSModel?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var stopped = false

    func warmUp() async throws {
        guard model == nil else { return }
        // First run downloads ~170 MB of CoreML assets, then cached locally.
        let model = try await KokoroTTSModel.fromPretrained()
        self.model = model

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw KokoroError.formatUnavailable
        }
        self.format = format
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        try audioEngine.start()

        // Warm the ANE pipeline so the first real sentence has no cold-start cost.
        _ = try model.synthesize(text: "こんにちは", voice: Self.japaneseVoice, language: "ja")
    }

    func speak(_ sentences: AsyncStream<Sentence>) async {
        guard let model, let format else { return }
        stopped = false
        if !audioEngine.isRunning { try? audioEngine.start() }
        playerNode.play()

        var scheduled: [Task<Void, Never>] = []

        for await sentence in sentences {
            if stopped { break }
            let isJapanese = sentence.script == .japanese
            let voice = isJapanese ? Self.japaneseVoice : Self.englishVoice
            guard let samples = try? model.synthesize(text: sentence.text,
                                                      voice: voice,
                                                      language: isJapanese ? "ja" : "en",
                                                      speed: Self.speed),
                  !samples.isEmpty,
                  let buffer = Self.makeBuffer(samples: samples, format: format) else { continue }
            if stopped { break }

            // scheduleBuffer returns immediately; completion fires after playback.
            // Collect completions so we only return once audio actually finished.
            let done = Task { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    c.resume()
                }
            } }
            scheduled.append(done)
        }

        for task in scheduled { await task.value }
    }

    func stop() async {
        stopped = true
        playerNode.stop() // fires pending completion handlers immediately
    }

    private static func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }

    enum KokoroError: Error {
        case formatUnavailable
    }
}
