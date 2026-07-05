import Foundation

/// One turn of input to the brain: either raw audio (16 kHz mono Float32) or text.
enum BrainInput {
    case audio([Float])
    case text(String)
}

struct HistoryTurn: Codable {
    enum Role: String, Codable { case user, assistant }
    let role: Role
    let text: String
}

/// The conversation model. Implementations stream raw tokens; parsing of the
/// <heard>/<reply> output frame happens downstream in OutputFrameParser.
protocol BrainEngine: Actor {
    /// Load model weights and keep them resident. Called once at app launch.
    func warmUp() async throws

    /// Generate a streamed reply. History excludes the current input.
    /// The returned stream yields raw token strings as they are generated.
    func generate(input: BrainInput, history: [HistoryTurn], systemPrompt: String) -> AsyncThrowingStream<String, Error>

    /// Abort any in-flight generation immediately (user interruption).
    func cancelGeneration()
}
