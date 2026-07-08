import SwiftUI

/// User-tunable settings. Persists straight to the UserDefaults keys the
/// engines already read live (`voicevoxStyleId`, `voicevoxRate`,
/// `customSystemPrompt`), so changes apply on the next sentence/turn with no
/// engine restart.
@MainActor
final class AppSettings: ObservableObject {
    @Published var styleId: Int {
        didSet { UserDefaults.standard.set(styleId, forKey: "voicevoxStyleId") }
    }
    @Published var rate: Double {
        didSet { UserDefaults.standard.set(Float(rate), forKey: "voicevoxRate") }
    }
    @Published var systemPrompt: String {
        didSet {
            if systemPrompt == Self.defaultPrompt {
                UserDefaults.standard.removeObject(forKey: "customSystemPrompt")
            } else {
                UserDefaults.standard.set(systemPrompt, forKey: "customSystemPrompt")
            }
        }
    }

    static let defaultPrompt: String =
        SystemPrompt.url().flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    init() {
        let defaults = UserDefaults.standard
        let storedStyle = defaults.integer(forKey: "voicevoxStyleId")
        styleId = storedStyle > 0 ? storedStyle : 16 // 九州そら ノーマル (engine default)
        let storedRate = defaults.float(forKey: "voicevoxRate")
        rate = storedRate > 0 ? Double(storedRate) : 1.12
        let storedPrompt = defaults.string(forKey: "customSystemPrompt")
        systemPrompt = storedPrompt?.isEmpty == false ? storedPrompt! : Self.defaultPrompt
    }

    var isPromptCustomized: Bool { systemPrompt != Self.defaultPrompt }
}

/// A VOICEVOX character and its selectable expression styles. Only the
/// characters whose .vvm models ship with the app (0.vvm–2.vvm) are listed.
struct VoiceCharacter: Identifiable {
    struct Style: Identifiable {
        let id: Int      // VOICEVOX style id
        let name: String
    }
    let id: String
    let name: String
    let japaneseName: String
    let description: String
    let styles: [Style]

    static let all: [VoiceCharacter] = [
        VoiceCharacter(id: "sora", name: "Kyushu Sora", japaneseName: "九州そら",
                       description: "Female · calm adult (default)",
                       styles: [.init(id: 16, name: "Normal"), .init(id: 15, name: "Sweet"),
                                .init(id: 18, name: "Tsundere"), .init(id: 19, name: "Whisper")]),
        VoiceCharacter(id: "himari", name: "Meimei Himari", japaneseName: "冥鳴ひまり",
                       description: "Female · soft, refined",
                       styles: [.init(id: 14, name: "Normal")]),
        VoiceCharacter(id: "zundamon", name: "Zundamon", japaneseName: "ずんだもん",
                       description: "Mascot · high-pitched, playful",
                       styles: [.init(id: 3, name: "Normal"), .init(id: 1, name: "Sweet"),
                                .init(id: 7, name: "Tsundere")]),
    ]

    static func character(forStyleId id: Int) -> VoiceCharacter? {
        all.first { $0.styles.contains { $0.id == id } }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    voiceSection
                    speedSection
                    promptSection
                    credit
                }
                .padding(20)
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.12))
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 520, height: 700)
        #endif
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(red: 0.35, green: 0.55, blue: 1.0))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.white.opacity(0.03))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.06)),
                 alignment: .bottom)
    }

    // MARK: Voice

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Voice & Character")
            sectionCaption("Pick who Suki sounds like. Takes effect on the next reply.")

            VStack(spacing: 10) {
                ForEach(VoiceCharacter.all) { character in
                    CharacterCard(character: character, selectedStyleId: $settings.styleId)
                }
            }
        }
    }

    // MARK: Speed

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Speaking Speed")

            card {
                HStack(spacing: 12) {
                    Text("Slow")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                    Slider(value: $settings.rate, in: 0.8...1.5, step: 0.02)
                        .tint(Color(red: 0.35, green: 0.55, blue: 1.0))
                    Text("Fast")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(String(format: "%.2f×", settings.rate))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    // MARK: System prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Personality · System Prompt")
                Spacer()
                if settings.isPromptCustomized {
                    Button("Reset to default") {
                        settings.systemPrompt = AppSettings.defaultPrompt
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                }
            }
            sectionCaption("How the AI behaves and responds. Keep the <heard>/<reply>/<mistake> output tags — voice output depends on them.")

            TextEditor(text: $settings.systemPrompt)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220, maxHeight: 320)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private var credit: some View {
        // License requirement: shipping builds must credit the active character.
        Text("Voice: VOICEVOX:\(VoiceCharacter.character(forStyleId: settings.styleId)?.japaneseName ?? "九州そら")")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: Building blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct CharacterCard: View {
    let character: VoiceCharacter
    @Binding var selectedStyleId: Int

    private var isSelected: Bool {
        character.styles.contains { $0.id == selectedStyleId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(character.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(character.japaneseName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(character.description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if isSelected {
                    Circle()
                        .fill(Color(red: 0.35, green: 0.55, blue: 1.0))
                        .frame(width: 8, height: 8)
                }
            }

            // Style chips: tapping one both selects the character and its style.
            HStack(spacing: 8) {
                ForEach(character.styles) { style in
                    let active = selectedStyleId == style.id
                    Button {
                        selectedStyleId = style.id
                    } label: {
                        Text(style.name)
                            .font(.caption.weight(active ? .semibold : .regular))
                            .foregroundStyle(active ? .white : .white.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                active
                                    ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1.0),
                                                                            Color(red: 0.45, green: 0.30, blue: 0.95)],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(.white.opacity(0.07)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(.white.opacity(isSelected ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color(red: 0.35, green: 0.55, blue: 1.0).opacity(0.5)
                                         : .white.opacity(0.08), lineWidth: 1)
        )
    }
}
