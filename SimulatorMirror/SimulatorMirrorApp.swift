import SwiftUI

@main
struct SimulatorMirrorApp: App {
    @State private var settings = AppSettings()
    @State private var sessionManager = TerminalSessionManager()
    @State private var relayManager = RelayManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(sessionManager)
                .environment(relayManager)
                .task {
                    // Connect relay if Room ID is already saved (from a previous session)
                    applyRelaySettings()
                }
                .onChange(of: settings.relayURL)    { _, _ in applyRelaySettings() }
                .onChange(of: settings.relayRoomId) { _, _ in applyRelaySettings() }
        }
    }

    @MainActor
    private func applyRelaySettings() {
        // Don't attempt relay when a local server is already discovered via Bonjour
        guard !settings.hasConfiguredServer else { return }
        let url    = settings.relayURL.trimmingCharacters(in: .whitespaces)
        let roomId = settings.relayRoomId.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !roomId.isEmpty else { return }
        relayManager.relayURLString = url
        relayManager.setDeviceId(roomId)
    }
}
