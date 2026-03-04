import SwiftUI

@Observable
final class AppSettings {
    // Properly @Observable-tracked (not @ObservationIgnored) so onChange(of:)
    // and computed URL properties fire correctly when Bonjour updates these.
    var serverIP: String = "localhost" {
        didSet { UserDefaults.standard.set(serverIP, forKey: "serverIP") }
    }
    var serverPort: Int = 8080 {
        didSet { UserDefaults.standard.set(serverPort, forKey: "serverPort") }
    }
    var serverName: String = "" {
        didSet { UserDefaults.standard.set(serverName, forKey: "serverName") }
    }
    var claudeURL: String = "" {
        didSet { UserDefaults.standard.set(claudeURL, forKey: "claudeURL") }
    }

    // SSH settings
    var terminalMode: String = "local" {
        didSet { UserDefaults.standard.set(terminalMode, forKey: "terminalMode") }
    }
    var sshHost: String = "" {
        didSet { UserDefaults.standard.set(sshHost, forKey: "sshHost") }
    }
    var sshPort: Int = 22 {
        didSet { UserDefaults.standard.set(sshPort, forKey: "sshPort") }
    }
    var sshUsername: String = "" {
        didSet { UserDefaults.standard.set(sshUsername, forKey: "sshUsername") }
    }
    var sshPassword: String = "" {
        didSet { UserDefaults.standard.set(sshPassword, forKey: "sshPassword") }
    }

    // Relay settings
    /// WebSocket URL of the deployed relay server, e.g. "ws://192.168.1.5:8765" for local or
    /// "wss://my-relay.fly.dev" for production. Leave empty to disable relay.
    var relayURL: String = "" {
        didSet { UserDefaults.standard.set(relayURL, forKey: "relayURL") }
    }
    /// Room ID copied from the Mac's menu bar ("Copy Room ID").
    /// Auto-populated by CloudKit when both devices share the same iCloud account.
    var relayRoomId: String = "" {
        didSet { UserDefaults.standard.set(relayRoomId, forKey: "relayRoomId") }
    }

    // Debug
    /// When true, skip local MJPEG connection and use relay only. Useful for testing relay without being on the same network.
    var debugForceRelay: Bool = false {
        didSet { UserDefaults.standard.set(debugForceRelay, forKey: "debugForceRelay") }
    }

    init() {
        let d = UserDefaults.standard
        serverIP   = d.string(forKey: "serverIP")   ?? "localhost"
        let port   = d.integer(forKey: "serverPort")
        serverPort = port == 0 ? 8080 : port
        serverName = d.string(forKey: "serverName") ?? ""
        claudeURL  = d.string(forKey: "claudeURL")  ?? ""
        terminalMode = d.string(forKey: "terminalMode") ?? "local"
        sshHost      = d.string(forKey: "sshHost")      ?? ""
        let sPort    = d.integer(forKey: "sshPort")
        sshPort      = sPort == 0 ? 22 : sPort
        sshUsername   = d.string(forKey: "sshUsername")  ?? ""
        sshPassword   = d.string(forKey: "sshPassword")  ?? ""
        relayURL        = d.string(forKey: "relayURL")        ?? "wss://simulatormirror-relay.fly.dev"
        relayRoomId     = d.string(forKey: "relayRoomId")     ?? ""
        debugForceRelay = d.bool(forKey: "debugForceRelay")
    }

    /// True once the user has successfully connected via Bonjour at least once.
    var hasConfiguredServer: Bool { !serverName.isEmpty }

    /// True when SSH host and username are filled in.
    var hasConfiguredSSH: Bool { !sshHost.isEmpty && !sshUsername.isEmpty }

    // Brackets IPv6 addresses per RFC 3986 (e.g. "fe80::1" → "[fe80::1]")
    private var serverHost: String {
        serverIP.contains(":") ? "[\(serverIP)]" : serverIP
    }

    var terminalWSURL: URL? {
        URL(string: "ws://\(serverHost):8081")
    }

    var streamURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/stream")
    }

    var touchURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/touch")
    }

    var keyboardURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/keyboard")
    }

    var statusURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/status")
    }

    var moveFrontURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/movefront")
    }

    var screenRectURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/screenrect")
    }

    var homeURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/home")
    }

    var screenshotURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/screenshot")
    }

    var rotateURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/rotate")
    }

    var shakeURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/shake")
    }

    var filesURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)/files")
    }

    /// Generic helper for build endpoints — e.g. buildURL("/build/output?since=5")
    func buildURL(_ path: String) -> URL? {
        URL(string: "http://\(serverHost):\(serverPort)\(path)")
    }
}
