import SwiftUI

/// Siri/Gemini-style animated voice orb: layered rotating gradient blobs,
/// additively blended and blurred. The orb doubles as the main talk button —
/// its motion reflects the conversation state:
///   idle       gentle breathing
///   listening  swells with the live mic level
///   thinking   fast tight pulse
///   speaking   rhythmic talk pulse
struct VoiceOrbView: View {
    let state: ConversationEngine.State
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Soft outer glow
                Circle()
                    .fill(
                        RadialGradient(colors: [glowColor.opacity(0.45), .clear],
                                       center: .center, startRadius: 8, endRadius: 90)
                    )
                    .frame(width: 180, height: 180)
                    .scaleEffect(orbScale(t) * 1.15)

                Group {
                    blob(t, speed: 0.6, phase: 0,
                         colors: [Color(red: 0.20, green: 0.55, blue: 1.0), Color(red: 0.35, green: 0.90, blue: 1.0)])
                    blob(t, speed: -1.0, phase: 2.1,
                         colors: [Color(red: 0.65, green: 0.30, blue: 1.0), Color(red: 1.0, green: 0.35, blue: 0.75)])
                    blob(t, speed: 1.5, phase: 4.2,
                         colors: [Color(red: 0.15, green: 0.85, blue: 0.75), Color(red: 0.30, green: 0.45, blue: 1.0)])
                }
                .frame(width: 96, height: 96)
                .scaleEffect(orbScale(t))

                // Glassy core highlight
                Circle()
                    .fill(
                        RadialGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)],
                                       center: .init(x: 0.35, y: 0.3), startRadius: 2, endRadius: 46)
                    )
                    .frame(width: 92, height: 92)
                    .scaleEffect(orbScale(t))

                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 3)
            }
            .frame(width: 190, height: 190)
        }
    }

    private func blob(_ t: TimeInterval, speed: Double, phase: Double, colors: [Color]) -> some View {
        Circle()
            .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
            .blur(radius: 14)
            .rotationEffect(.radians(t * speed))
            .offset(x: cos(t * speed * 1.3 + phase) * wobble,
                    y: sin(t * speed * 1.7 + phase) * wobble)
            .blendMode(.plusLighter)
    }

    private var wobble: CGFloat {
        switch state {
        case .listening: return 10
        case .speaking:  return 12
        case .thinking:  return 6
        default:         return 5
        }
    }

    private func orbScale(_ t: TimeInterval) -> CGFloat {
        switch state {
        case .warmingUp:
            return 0.9 + 0.03 * sin(t * 1.0)
        case .idle:
            return 1.0 + 0.03 * sin(t * 1.4)
        case .listening:
            return 1.0 + CGFloat(min(level, 1)) * 0.35
        case .thinking:
            return 0.92 + 0.06 * sin(t * 6.0)
        case .speaking:
            return 1.0 + 0.10 * abs(sin(t * 4.5)) + 0.04 * sin(t * 9.0)
        }
    }

    private var glowColor: Color {
        switch state {
        case .listening: return Color(red: 0.30, green: 0.75, blue: 1.0)
        case .thinking:  return Color(red: 0.70, green: 0.45, blue: 1.0)
        case .speaking:  return Color(red: 1.0, green: 0.40, blue: 0.70)
        default:         return Color(red: 0.40, green: 0.55, blue: 1.0)
        }
    }

    private var iconName: String {
        switch state {
        case .warmingUp: return "hourglass"
        case .idle:      return "mic.fill"
        case .listening: return "waveform"
        case .thinking:  return "ellipsis"
        case .speaking:  return "stop.fill"
        }
    }
}
