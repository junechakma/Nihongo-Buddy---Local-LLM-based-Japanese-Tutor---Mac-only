import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: ConversationEngine
    @StateObject private var settings = AppSettings()
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 560

            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12),
                                        Color(red: 0.02, green: 0.02, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    TopBar(compact: compact, showSettings: $showSettings)
                        .padding(.horizontal, compact ? 16 : 28)
                        .padding(.top, compact ? 10 : 18)
                        .padding(.bottom, 8)

                    if engine.transcript.isEmpty {
                        // Empty state: the orb owns the screen, ChatGPT-voice style.
                        Spacer()
                        OrbButton(size: heroOrbSize(in: geo.size))
                        Spacer()
                    } else {
                        TranscriptView(turns: engine.transcript)
                            .frame(maxWidth: 760)
                            .padding(.horizontal, compact ? 12 : 28)
                            .padding(.top, 6)

                        OrbButton(size: compact ? 132 : 168)
                            .padding(.top, 14)
                            .padding(.bottom, compact ? 14 : 24)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await engine.warmUp() }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
    }

    private func heroOrbSize(in size: CGSize) -> CGFloat {
        min(min(size.width, size.height) * 0.48, 280)
    }
}

private struct TopBar: View {
    @EnvironmentObject var engine: ConversationEngine
    let compact: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Suki")
                    .font(.system(size: compact ? 19 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if !compact {
                    Text("日本語 tutor · JLPT N5")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            Picker("", selection: $engine.mode) {
                ForEach(ConversationEngine.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 140 : 170)
            .disabled(engine.state == .warmingUp)

            Button {
                Task { await engine.startNewConversation() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(engine.state == .warmingUp)
            .help("New conversation")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }
}

/// The orb IS the talk button — no icons, its motion is the interface.
private struct OrbButton: View {
    @EnvironmentObject var engine: ConversationEngine
    var size: CGFloat = 190
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            Button(action: { Task { await engine.toggleTurn() } }) {
                VoiceOrbView(state: engine.state, level: engine.micLevel, size: size)
            }
            .buttonStyle(.plain)
            .scaleEffect(hovering ? 1.04 : 1.0)
            .animation(.spring(duration: 0.25), value: hovering)
            .onHover { hovering = $0 }
            .disabled(engine.state == .warmingUp)
            .keyboardShortcut(.space, modifiers: [])

            HStack(spacing: 8) {
                if engine.state == .warmingUp {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(hint)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: hint)
            }
            .frame(height: 20)
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
            .onChange(of: turns.count) { scrollToLatest(proxy) }
            // Streaming: buddy text grows inside the last bubble without the
            // count changing — follow it too.
            .onChange(of: turns.last?.text) { scrollToLatest(proxy) }
            .onAppear { scrollToLatest(proxy) }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let last = turns.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
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
