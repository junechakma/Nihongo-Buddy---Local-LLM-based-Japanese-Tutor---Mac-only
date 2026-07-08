import Foundation
import SwiftUI

struct ConversationTurn: Identifiable {
    enum Role { case user, buddy }
    let id = UUID()
    let role: Role
    var text: String
}

/// App state machine: warmingUp → idle → listening → thinking → speaking → idle.
/// Owns the turn loop and wires brain, speech, mic, memory and character together.
@MainActor
final class ConversationEngine: ObservableObject {
    enum State { case warmingUp, idle, listening, thinking, speaking }

    /// Manual: tap to record, tap to send. Auto: hands-free — a pause in
    /// speech ends the turn, and listening restarts after each reply.
    enum Mode: String, CaseIterable, Identifiable {
        case manual = "Manual"
        case auto = "Auto"
        var id: String { rawValue }
    }

    @Published private(set) var state: State = .warmingUp
    @Published private(set) var transcript: [ConversationTurn] = []
    @Published private(set) var characterState: CharacterState = .idle
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var warmUpStatus: String = "Starting up…"
    @Published var mode: Mode = .manual {
        didSet { if oldValue != mode, mode == .manual { leaveAutoConversation() } }
    }

    private let brain: any BrainEngine
    private let speech: any SpeechOutput
    private let mic: MicCapture
    private let store: MistakeStore
    private var history: [HistoryTurn] = []
    private var turnTask: Task<Void, Never>?

    // MARK: Auto-mode voice activity detection
    /// micLevel is normalized RMS (~0–1, see SpeechLevelMeter.rms). Levels
    /// above this count as speech for turn-taking.
    private static let voiceThreshold: Float = 0.12
    /// Silence after speech that ends an auto-mode turn.
    private static let pauseSeconds: TimeInterval = 1.5
    private var autoActive = false
    private var autoEndTask: Task<Void, Never>?
    private var heardVoiceThisTurn = false
    private var lastVoiceAt: Date?
    private var listenStartedAt = Date()

    init(brain: any BrainEngine, speech: any SpeechOutput, mic: MicCapture, store: MistakeStore) {
        self.brain = brain
        self.speech = speech
        self.mic = mic
        self.store = store
    }

    func warmUp() async {
        guard state == .warmingUp else { return }
        do {
            warmUpStatus = "Opening memory…"
            try await store.open()
            history = Self.loadHistory()

            warmUpStatus = "Preparing microphone…"
            try await mic.prepare { [weak self] level in
                Task { @MainActor in self?.handleMicLevel(level) }
            }

            warmUpStatus = "Loading voice…"
            let voiceProgress = watchKokoroDownload()
            try await speech.warmUp()
            voiceProgress.cancel()

            warmUpStatus = "Loading brain… (3.4 GB, one moment)"
            try await brain.warmUp()

            state = .idle
        } catch {
            warmUpStatus = "Startup failed"
            transcript.append(ConversationTurn(role: .buddy, text: "うーん、starting up went wrong: \(error.localizedDescription)"))
        }
    }

    /// Kokoro assets download on first launch (~330 MB). speech-swift exposes no
    /// progress callback, so show progress by watching its cache directory grow.
    private func watchKokoroDownload() -> Task<Void, Never> {
        Task { [weak self] in
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("qwen3-speech")
            let expectedBytes: Int64 = 330_000_000
            while !Task.isCancelled {
                let size = Self.directorySize(cacheDir)
                if size > 5_000_000, size < expectedBytes {
                    let percent = Int(Double(size) / Double(expectedBytes) * 100)
                    self?.warmUpStatus = "Downloading voice… \(min(percent, 99))% (\(size / 1_048_576)/315 MB)"
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Single button. Manual: Speak → Done → (interrupt while speaking).
    /// Auto: Start conversation → (tap while listening ends it; tap while
    /// speaking interrupts and goes straight back to listening).
    func toggleTurn() async {
        switch state {
        case .idle:
            if mode == .auto { autoActive = true }
            startListening()
        case .listening:
            if mode == .auto {
                leaveAutoConversation()
                return
            }
            let audio = mic.finish()
            guard SpeechLevelMeter.containsSpeech(audio) else {
                state = .idle
                characterState = .idle
                transcript.append(ConversationTurn(role: .buddy, text: "あれ？ I didn't hear anything — try again!"))
                return
            }
            runTurn(audio: audio)
        case .speaking, .thinking:
            await interrupt()
        case .warmingUp:
            break
        }
    }

    private func startListening() {
        mic.start()
        state = .listening
        characterState = .listening
        heardVoiceThisTurn = false
        lastVoiceAt = nil
        listenStartedAt = Date()

        autoEndTask?.cancel()
        autoEndTask = nil
        if mode == .auto, autoActive {
            autoEndTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    await self?.autoCheckTurnEnd()
                }
            }
        }
    }

    /// Level callback (~15 Hz, main queue): UI meter + auto-mode VAD.
    private func handleMicLevel(_ level: Float) {
        micLevel = level
        if state == .listening, mode == .auto, level > Self.voiceThreshold {
            heardVoiceThisTurn = true
            lastVoiceAt = Date()
        }
    }

    /// Auto mode: end the turn once the user has spoken and then paused.
    private func autoCheckTurnEnd() {
        guard mode == .auto, autoActive, state == .listening else { return }
        if mic.isAtMaxLength {
            finishAutoTurn()
            return
        }
        guard heardVoiceThisTurn,
              let last = lastVoiceAt,
              Date().timeIntervalSince(last) >= Self.pauseSeconds,
              Date().timeIntervalSince(listenStartedAt) >= 1.0 else { return }
        finishAutoTurn()
    }

    private func finishAutoTurn() {
        let audio = mic.finish()
        guard SpeechLevelMeter.containsSpeech(audio) else {
            // False trigger — keep listening on a fresh capture buffer.
            mic.start()
            heardVoiceThisTurn = false
            lastVoiceAt = nil
            listenStartedAt = Date()
            return
        }
        autoEndTask?.cancel()
        autoEndTask = nil
        runTurn(audio: audio)
    }

    /// Tear down the hands-free loop and return to idle.
    private func leaveAutoConversation() {
        autoActive = false
        autoEndTask?.cancel()
        autoEndTask = nil
        if state == .listening {
            _ = mic.finish()
            state = .idle
            characterState = .idle
        }
    }

    private func runTurn(audio: [Float]) {
        state = .thinking
        characterState = .thinking
        mic.pauseIdleTap()

        turnTask = Task {
            var parser = OutputFrameParser()
            var splitter = SentenceSplitter()
            var replyText = ""
            var currentEmotion = OutputFrameParser.Emotion.neutral
            let (sentenceStream, sentenceContinuation) = AsyncStream<Sentence>.makeStream()

            let speaking = Task { await speech.speak(sentenceStream) }

            do {
                let systemPrompt = await SystemPrompt.build(recurringMistakes: store.topRecurring(limit: 5))
                let stream = await brain.generate(input: .audio(audio), history: history, systemPrompt: systemPrompt)

                for try await token in stream {
                    guard !Task.isCancelled else { break }
                    for event in parser.push(token) {
                        switch event {
                        case .heard(let text):
                            transcript.append(ConversationTurn(role: .user, text: text))
                            history.append(HistoryTurn(role: .user, text: text))
                        case .emotion(let emotion):
                            currentEmotion = emotion
                            state = .speaking
                            characterState = .reaction(emotion)
                        case .replyText(let text):
                            replyText += text
                            appendToBuddyTurn(text)
                            for var sentence in splitter.push(text) {
                                sentence.emotion = currentEmotion
                                sentenceContinuation.yield(sentence)
                                characterState = .talking
                            }
                        case .mistake(let wrong, let correct, let point):
                            await store.record(.mistake, item: wrong, wrong: wrong, correct: correct, grammarPoint: point)
                        }
                    }
                }
                if let tail = parser.flushTail(), !tail.isEmpty {
                    replyText += tail
                    appendToBuddyTurn(tail)
                    for var sentence in splitter.push(tail) {
                        sentence.emotion = currentEmotion
                        sentenceContinuation.yield(sentence)
                    }
                }
                if var last = splitter.flush() {
                    last.emotion = currentEmotion
                    sentenceContinuation.yield(last)
                }

                // Model ignored the output frame — show and speak the raw reply
                // rather than dropping it (frame adherence improves in step 7).
                if replyText.isEmpty, let fallback = parser.untaggedFallback {
                    replyText = fallback
                    state = .speaking
                    characterState = .talking
                    transcript.append(ConversationTurn(role: .buddy, text: fallback))
                    var fallbackSplitter = SentenceSplitter()
                    for sentence in fallbackSplitter.push(fallback) { sentenceContinuation.yield(sentence) }
                    if let last = fallbackSplitter.flush() { sentenceContinuation.yield(last) }
                }
            } catch {
                transcript.append(ConversationTurn(role: .buddy, text: "ちょっと待って… my brain glitched. Try once more?"))
            }

            sentenceContinuation.finish()
            await speaking.value

            if !replyText.isEmpty {
                history.append(HistoryTurn(role: .assistant, text: replyText))
            }
            trimHistory()
            Self.saveHistory(history)
            mic.resumeIdleTap()
            // On interrupt() the canceller owns the state transition.
            if !Task.isCancelled {
                if mode == .auto, autoActive {
                    startListening()
                } else {
                    state = .idle
                    characterState = .idle
                }
            }
        }
    }

    /// Wipe transcript, persisted history and the brain's KV cache so the
    /// buddy greets fresh on the next turn.
    func startNewConversation() async {
        guard state != .warmingUp else { return }
        autoActive = false
        autoEndTask?.cancel()
        autoEndTask = nil
        if state == .listening { _ = mic.finish() }
        turnTask?.cancel()
        await brain.cancelGeneration()
        await speech.stop()
        await turnTask?.value // let the cancelled turn drain before clearing
        turnTask = nil
        mic.resumeIdleTap()
        transcript = []
        history = []
        Self.saveHistory(history)
        await brain.resetConversation()
        state = .idle
        characterState = .idle
    }

    private func interrupt() async {
        turnTask?.cancel()
        await brain.cancelGeneration()
        await speech.stop()
        mic.resumeIdleTap()
        if mode == .auto, autoActive {
            startListening()
        } else {
            state = .idle
            characterState = .idle
        }
    }

    private func appendToBuddyTurn(_ text: String) {
        if let last = transcript.indices.last, transcript[last].role == .buddy,
           history.last?.role == .user {
            transcript[last].text += text
        } else if transcript.last?.role != .buddy {
            transcript.append(ConversationTurn(role: .buddy, text: text))
        } else if let last = transcript.indices.last {
            transcript[last].text += text
        }
    }

    /// Keep last ~10 turns verbatim (§3.7); older context lives in MistakeStore.
    private func trimHistory() {
        let maxTurns = 20 // 10 user + 10 assistant
        if history.count > maxTurns {
            history.removeFirst(history.count - maxTurns)
        }
    }

    // MARK: - History persistence

    /// Conversation history survives app relaunches so the buddy stays
    /// personal. The brain replays these turns into a fresh KV cache on the
    /// first turn (and again after a context-overflow wipe).
    private nonisolated static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NihongoBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private nonisolated static func loadHistory() -> [HistoryTurn] {
        guard let data = try? Data(contentsOf: historyURL),
              let turns = try? JSONDecoder().decode([HistoryTurn].self, from: data) else { return [] }
        return turns
    }

    private nonisolated static func saveHistory(_ turns: [HistoryTurn]) {
        if let data = try? JSONEncoder().encode(turns) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}

enum SystemPrompt {
    static func url() -> URL? {
        for subdirectory in ["prompts", "Resources/prompts", nil] {
            if let url = Bundle.main.url(forResource: "system", withExtension: "txt", subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }

    static func build(recurringMistakes: [MistakeStore.RecurringMistake]) -> String {
        // Settings panel can override the bundled prompt (customSystemPrompt).
        let custom = UserDefaults.standard.string(forKey: "customSystemPrompt")
        var prompt: String
        if let custom, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = custom
        } else {
            prompt = SystemPrompt.url().flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        assert(!prompt.isEmpty, "system.txt missing from bundle — character prompt not loaded")
        if !recurringMistakes.isEmpty {
            prompt += "\n\n# Recurring mistakes to roast mercilessly when they recur:\n"
            for mistake in recurringMistakes {
                prompt += "- \(mistake.grammarPoint) (\(mistake.count) times)\n"
            }
        }
        return prompt
    }
}
