import Foundation

/// A TerminalConnection that tunnels through the WebSocket relay to
/// the Mac's local TerminalServer (ws://localhost:8081).
///
/// Used automatically when the relay is active and no local server is reachable.
final class RelayTerminalConnection: TerminalConnection {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let manager: RelayManager
    private let id: String

    init(manager: RelayManager) {
        self.manager = manager
        self.id = UUID().uuidString
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await manager.openWSTunnel(
                id: id,
                onReceive: { [weak self] data in self?.onReceive?(data) },
                onDisconnect: { [weak self] error in self?.onDisconnect?(error) }
            )
        }
    }

    func send(data: Data) {
        let id = self.id
        Task { @MainActor [weak self] in self?.manager.sendWSTunnelData(id: id, data: data) }
    }

    func resize(cols: Int, rows: Int) {
        let id = self.id
        Task { @MainActor [weak self] in self?.manager.sendWSTunnelResize(id: id, cols: cols, rows: rows) }
    }

    func disconnect() {
        let id = self.id
        Task { @MainActor [weak self] in self?.manager.closeWSTunnel(id: id) }
    }
}
