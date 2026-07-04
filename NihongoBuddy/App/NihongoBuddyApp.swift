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
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 480, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
