import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: ConversationEngine

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12),
                                    Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HeaderBar()
                GifCharacterView(state: engine.characterState)
                    .frame(width: 190, height: 190)
                TranscriptView(turns: engine.transcript)
                StatusLine()
                OrbButton()
                    .padding(.bottom, 18)
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .task { await engine.warmUp() }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var engine: ConversationEngine

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suki")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("日本語 tutor · JLPT N5")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Picker("", selection: $engine.mode) {
                ForEach(ConversationEngine.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .disabled(engine.state == .warmingUp)
        }
    }
}

/// The Siri-style orb IS the talk button.
private struct OrbButton: View {
    @EnvironmentObject var engine: ConversationEngine
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            Button(action: { Task { await engine.toggleTurn() } }) {
                VoiceOrbView(state: engine.state, level: engine.micLevel)
            }
            .buttonStyle(.plain)
            .scaleEffect(hovering ? 1.04 : 1.0)
            .animation(.spring(duration: 0.25), value: hovering)
            .onHover { hovering = $0 }
            .disabled(engine.state == .warmingUp)
            .keyboardShortcut(.space, modifiers: [])

            Text(hint)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: hint)
        }
    }

    private var hint: String {
        switch engine.state {
        case .warmingUp:
            return engine.warmUpStatus
        case .idle:
            return engine.mode == .auto ? "Tap to start the conversation" : "Tap to speak"
        case .listening:
            return engine.mode == .auto ? "Listening — pause to send, tap to end" : "Listening — tap when done"
        case .thinking:
            return "Thinking… tap to cancel"
        case .speaking:
            return "Speaking — tap to interrupt"
        }
    }
}

private struct StatusLine: View {
    @EnvironmentObject var engine: ConversationEngine

    var body: some View {
        Group {
            if engine.state == .warmingUp {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Color.clear
            }
        }
        .frame(height: 16)
    }
}

struct TranscriptView: View {
    let turns: [ConversationTurn]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(turns) { turn in
                        BubbleRow(turn: turn)
                            .id(turn.id)
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: turns.count) {
                if let last = turns.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct BubbleRow: View {
    let turn: ConversationTurn

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if turn.role == .user { Spacer(minLength: 48) }
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 3) {
                Text(turn.role == .user ? "You" : "Suki")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text(turn.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        turn.role == .user
                            ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1.0),
                                                                    Color(red: 0.45, green: 0.30, blue: 0.95)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(.white.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                    .textSelection(.enabled)
            }
            if turn.role == .buddy { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }
}
