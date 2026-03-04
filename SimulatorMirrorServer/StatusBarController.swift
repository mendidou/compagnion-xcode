import AppKit

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let captureManager = ScreenCaptureManager()
    private let httpServer = HTTPServer()
    private let terminalServer = TerminalServer()
    private var relayClient: RelayClient?
    private var relayMenuItem: NSMenuItem?
    private var copyRoomIdMenuItem: NSMenuItem?
    private var isRunning = false

    // Persisted relay URL — default is localhost for local testing
    private var relayURL: String {
        get { UserDefaults.standard.string(forKey: "relayURL") ?? "wss://simulatormirror-relay.fly.dev" }
        set { UserDefaults.standard.set(newValue, forKey: "relayURL") }
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "SimulatorMirror")
            button.title = " Mirror"
        }
        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        let startItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)

        menu.addItem(.separator())

        // Relay status — updated dynamically
        let relayItem = NSMenuItem(title: "Remote: Inactive", action: nil, keyEquivalent: "")
        relayItem.isEnabled = false
        relayMenuItem = relayItem
        menu.addItem(relayItem)

        // Copy Room ID — lets the user paste it into the iOS Settings tab
        let copyItem = NSMenuItem(title: "Copy Room ID", action: #selector(copyRoomId), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = false
        copyRoomIdMenuItem = copyItem
        menu.addItem(copyItem)

        // Set Relay URL — change without recompiling
        let setURLItem = NSMenuItem(title: "Set Relay URL…", action: #selector(setRelayURL), keyEquivalent: "")
        setURLItem.target = self
        menu.addItem(setURLItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SimulatorMirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleServer() {
        if isRunning { stopServer() } else { startServer() }
    }

    func startServer() {
        Task {
            do {
                try await captureManager.start()
                // All post-start work must run on the main thread — NSMenu/NSStatusItem are not thread-safe.
                await MainActor.run {
                    httpServer.start(frameBuffer: captureManager.frameBuffer)
                    terminalServer.start()
                    isRunning = true
                    updateMenu()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Screen Recording Permission Required"
                    alert.informativeText = "Please grant screen recording permission in System Settings > Privacy & Security > Screen Recording, then restart."
                    alert.runModal()
                }
            }
        }
    }

    private func startRelay() {
        let deviceId = storedOrNewDeviceId()
        copyRoomIdMenuItem?.isEnabled = true

        let client = RelayClient(roomId: deviceId, relayURL: relayURL)
        client.onStatusChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.relayMenuItem?.title = connected ? "Remote: Connected" : "Remote: Connecting…"
            }
        }
        relayClient = client
        client.start(frameBuffer: captureManager.frameBuffer)
    }

    private func stopServer() {
        relayClient?.stop()
        relayClient = nil
        relayMenuItem?.title = "Remote: Inactive"
        copyRoomIdMenuItem?.isEnabled = false
        terminalServer.stop()
        httpServer.stop()
        captureManager.stop()
        isRunning = false
        updateMenu()
    }

    // MARK: - Menu actions

    @objc private func copyRoomId() {
        let roomId = storedOrNewDeviceId()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(roomId, forType: .string)
        // Briefly update the menu title for visual feedback
        copyRoomIdMenuItem?.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyRoomIdMenuItem?.title = "Copy Room ID"
        }
    }

    @objc private func setRelayURL() {
        let alert = NSAlert()
        alert.messageText = "Set Relay URL"
        alert.informativeText = "Enter the WebSocket URL of your relay server.\nLocal: ws://localhost:8765\nRemote: wss://my-relay.fly.dev"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = relayURL
        input.placeholderString = "ws://localhost:8765"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let newURL = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newURL.isEmpty else { return }
            relayURL = newURL
            // Reconnect relay client with new URL if server is running
            if isRunning {
                relayClient?.stop()
                startRelay()
            }
        }
    }

    // MARK: - Helpers

    private func storedOrNewDeviceId() -> String {
        let key = "relayDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    private func updateMenu() {
        guard let menu = statusItem.menu,
              let startItem = menu.items.first else { return }
        startItem.title = isRunning ? "Stop Server" : "Start Server"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: isRunning ? "iphone.fill" : "iphone",
                                   accessibilityDescription: "SimulatorMirror")
            button.title = isRunning ? " Mirror ●" : " Mirror"
        }
    }
}
