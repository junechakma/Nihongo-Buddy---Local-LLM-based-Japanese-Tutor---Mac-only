import AVFoundation

/// AVSpeechSynthesizer fallback — always available, ships regardless (§4.4).
actor AppleTTSFallback: SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SpeechDelegate?

    func warmUp() async throws {
        // System voices need no loading; verify a Japanese voice exists.
        guard AVSpeechSynthesisVoice(language: "ja-JP") != nil else {
            throw NSError(domain: "AppleTTSFallback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No ja-JP system voice installed"])
        }
    }

    func speak(_ sentences: AsyncStream<Sentence>) async {
        for await sentence in sentences {
            await speakOne(sentence)
        }
    }

    private func speakOne(_ sentence: Sentence) async {
        let utterance = AVSpeechUtterance(string: sentence.text)
        let lang = sentence.script == .japanese ? "ja-JP" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: lang)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = SpeechDelegate { continuation.resume() }
            self.delegate = delegate
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
    }

    func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: () -> Void
    private var finished = false

    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishOnce()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishOnce()
    }
}
