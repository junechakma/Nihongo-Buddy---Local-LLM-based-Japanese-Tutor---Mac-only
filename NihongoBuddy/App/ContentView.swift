import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: ConversationEngine

    var body: some View {
        VStack(spacing: 16) {
            GifCharacterView(state: engine.characterState)
                .frame(width: 240, height: 240)

            TranscriptView(turns: engine.transcript)

            if engine.state == .listening {
                SpeechLevelIndicator(level: engine.micLevel)
                    .frame(height: 24)
            }

            if engine.state == .warmingUp {
                VStack(spacing: 6) {
                    ProgressView()
                    Text(engine.warmUpStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            SpeakButton()
                .padding(.bottom, 24)
        }
        .padding()
        .task { await engine.warmUp() }
    }
}

struct SpeakButton: View {
    @EnvironmentObject var engine: ConversationEngine

    var body: some View {
        Button(action: { Task { await engine.toggleTurn() } }) {
            Label(label, systemImage: icon)
                .font(.title2)
                .frame(width: 200, height: 48)
        }
        .buttonStyle(.borderedProminent)
        .disabled(engine.state == .warmingUp)
        .keyboardShortcut(.space, modifiers: [])
    }

    private var label: String {
        switch engine.state {
        case .warmingUp: return "Warming up…"
        case .idle:      return "Speak"
        case .listening: return "Done"
        case .thinking:  return "Thinking…"
        case .speaking:  return "Interrupt"
        }
    }

    private var icon: String {
        switch engine.state {
        case .listening: return "checkmark.circle.fill"
        case .speaking:  return "stop.circle"
        default:         return "mic.fill"
        }
    }
}

struct TranscriptView: View {
    let turns: [ConversationTurn]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.role == .user ? "You said:" : "Buddy:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(turn.text)
                        }
                        .id(turn.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: turns.count) {
                if let last = turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

struct SpeechLevelIndicator: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(.green.opacity(0.8))
                .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                .animation(.linear(duration: 0.05), value: level)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
    }
}
