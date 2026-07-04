import Foundation

struct Sentence {
    let text: String
    /// Dominant script of the sentence, used to pick the TTS voice (§4.3).
    enum Script { case japanese, english }
    let script: Script
    /// Reply emotion from the output frame — drives TTS expression styles
    /// (VOICEVOX) and the character reaction GIF.
    var emotion: OutputFrameParser.Emotion = .neutral

    init(_ text: String) {
        self.text = text
        let latin = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let jp = text.unicodeScalars.filter {
            (0x3040...0x30FF).contains(Int($0.value)) || (0x4E00...0x9FFF).contains(Int($0.value))
        }
        self.script = jp.count >= latin.count / 2 && !jp.isEmpty ? .japanese : .english
    }
}

/// Text-to-speech. Sentences are spoken in order, gaplessly; synthesis of
/// sentence N+1 overlaps playback of sentence N.
protocol SpeechOutput: Actor {
    /// Load voices/models. Throwing here signals the caller to fall back.
    func warmUp() async throws

    /// Speak sentences as they arrive. Returns when playback of all sentences
    /// has finished or `stop()` was called.
    func speak(_ sentences: AsyncStream<Sentence>) async

    /// Stop playback immediately and drop any queued sentences.
    func stop() async
}

/// Routes to the primary engine (Kokoro) and auto-engages the fallback
/// (AVSpeechSynthesizer) if the primary fails to load. The app must never go mute (§4.4).
actor SpeechOutputRouter: SpeechOutput {
    private let primary: any SpeechOutput
    private let fallback: any SpeechOutput
    private var active: any SpeechOutput

    init(primary: any SpeechOutput, fallback: any SpeechOutput) {
        self.primary = primary
        self.fallback = fallback
        self.active = fallback
    }

    func warmUp() async throws {
        do {
            try await primary.warmUp()
            active = primary
            print("SpeechOutputRouter: primary TTS (Kokoro) active")
        } catch {
            print("SpeechOutputRouter: primary TTS failed, using fallback — \(error)")
            try await fallback.warmUp()
            active = fallback
        }
    }

    func speak(_ sentences: AsyncStream<Sentence>) async { await active.speak(sentences) }
    func stop() async { await active.stop() }
}

/// Accumulates streamed reply text and emits complete sentences on
/// Japanese/Latin terminator boundaries (§3.5). Feed it only <reply> content —
/// never raw tokens containing frame tags.
///
/// Short bursts (「わあ！」「すごい！」) are merged into the following sentence:
/// synthesizing them alone produces choppy word-by-word prosody. A chunk is
/// only emitted once it reaches `minEmitLength` — unless the script changes,
/// since a TTS voice switch requires a boundary there.
struct SentenceSplitter {
    private var buffer = ""
    private var pendingChunk = ""
    private static let terminators: Set<Character> = ["。", "｡", "！", "？", "!", "?", "."]
    private static let minEmitLength = 12

    mutating func push(_ text: String) -> [Sentence] {
        buffer += text
        var out: [Sentence] = []
        while let idx = buffer.firstIndex(where: { Self.terminators.contains($0) }) {
            let end = buffer.index(after: idx)
            let chunk = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(..<end)
            guard !chunk.isEmpty else { continue }

            if !pendingChunk.isEmpty,
               Sentence(pendingChunk).script != Sentence(chunk).script {
                out.append(Sentence(pendingChunk))
                pendingChunk = chunk
            } else {
                pendingChunk += pendingChunk.isEmpty ? chunk : " " + chunk
            }

            if pendingChunk.count >= Self.minEmitLength {
                out.append(Sentence(pendingChunk))
                pendingChunk = ""
            }
        }
        return out
    }

    /// Call at end of stream to flush held-back text (pending short chunks
    /// and any trailing text without a terminator).
    mutating func flush() -> Sentence? {
        var rest = pendingChunk
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { rest += rest.isEmpty ? tail : " " + tail }
        pendingChunk = ""
        buffer = ""
        return rest.isEmpty ? nil : Sentence(rest)
    }
}
