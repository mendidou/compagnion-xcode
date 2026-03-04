import Network
import Foundation

@Observable
final class BonjourBrowser {
    struct Server: Identifiable {
        let id = UUID()
        let name: String
        let endpoint: NWEndpoint
    }

    var servers: [Server] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_simulatormirror._tcp", domain: nil),
                          using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.servers = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Server(name: name, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
            }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        servers = []
    }

    /// Resolves a Bonjour service to (host, port) by briefly connecting to it.
    /// The connection is cancelled as soon as the remote address is known.
    func resolve(_ server: Server, completion: @escaping (String, Int) -> Void) {
        let conn = NWConnection(to: server.endpoint, using: .tcp)

        let timeout = DispatchWorkItem { conn.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timeout.cancel()
                if let remote = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote {
                    var hostStr = "\(host)"
                    // Strip IPv6 scope ID: "fe80::1%en0" → "fe80::1"
                    if let pct = hostStr.firstIndex(of: "%") {
                        hostStr = String(hostStr[..<pct])
                    }
                    // Strip IPv6 brackets
                    hostStr = hostStr.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    completion(hostStr, Int(port.rawValue))
                }
                conn.cancel()
            case .failed:
                timeout.cancel()
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }
}
