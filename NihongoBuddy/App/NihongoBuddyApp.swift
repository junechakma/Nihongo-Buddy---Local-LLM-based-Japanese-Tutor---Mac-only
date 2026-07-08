import SwiftUI

@main
struct NihongoBuddyApp: App {
    @StateObject private var engine = ConversationEngine(
        brain: GemmaLlamaEngine(),
        speech: SpeechOutputRouter(primary: VoicevoxEngine(), fallback: AppleTTSFallback()),
        mic: MicCapture(),
        store: MistakeStore()
    )

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 420, minHeight: 560)
        }
        .windowResizability(.automatic)
        #else
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
        #endif
    }
}
