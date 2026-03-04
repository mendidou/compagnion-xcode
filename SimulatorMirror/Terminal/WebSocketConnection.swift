import Foundation

final class WebSocketConnection: TerminalConnection {
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var socket: URLSessionWebSocketTask?

    init(url: URL) {
        socket = URLSession.shared.webSocketTask(with: url)
        socket?.resume()
        receive()
    }

    func send(data: Data) {
        socket?.send(.data(data)) { _ in }
    }

    func resize(cols: Int, rows: Int) {
        let msg = "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
        socket?.send(.string(msg)) { _ in }
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let d)):
                self.onReceive?(d)
                self.receive()
            case .success(.string(let s)):
                if let d = s.data(using: .utf8) {
                    self.onReceive?(d)
                }
                self.receive()
            case .failure(let err):
                self.onDisconnect?(err)
            @unknown default:
                self.receive()
            }
        }
    }
}
