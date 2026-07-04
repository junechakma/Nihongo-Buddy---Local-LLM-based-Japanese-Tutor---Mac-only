import Foundation

/// Character display states (§7.5). GIF implementation ships v1; Rive/Live2D
/// drop in behind the same abstraction later.
enum CharacterState: Equatable {
    case idle
    case listening
    case thinking
    case talking
    case reaction(OutputFrameParser.Emotion)

    /// Bundled GIF asset name for this state.
    var assetName: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .talking: return "talking"
        case .reaction(let emotion):
            switch emotion {
            case .happy, .proud: return "happy"
            case .shocked: return "shocked"
            case .teasing: return "teasing"
            case .neutral: return "talking"
            }
        }
    }
}
