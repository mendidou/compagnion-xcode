import Foundation

// MARK: - Protocol types

private struct RelayRequest: Encodable {
    let id: String
    let method: String
    let path: String
    let body: String?
}

private struct RelayResponse: Decodable {
    let id: String
    let status: Int
    let body: String?
}

// MARK: - RelayManager

@Observable
@MainActor
final class RelayManager {

    // MARK: - Observable state

    var isConnected = false
    private(set) var deviceId: String?
    /// Latest JPEG frame received — persists across tab switches so views don't flash a spinner on re-appear.
    private(set) var latestFrameData: Data? = nil

    // MARK: - Configuration

    var relayURLString: String = ""

    // MARK: - Private state

    @ObservationIgnored private var frameSubscribers: [UUID: AsyncStream<Data>.Continuation] = [:]
    @ObservationIgnored private var pendingRequests: [String: CheckedContinuation<(Int, Data), Error>] = [:]
    @ObservationIgnored private var wsTunnelHandlers: [String: WSTunnelHandler] = [:]
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay: UInt64 = 1_000_000_000

    private struct WSTunnelHandler {
        let onReceive: (Data) -> Void
        let onDisconnect: (Error?) -> Void
    }

    // MARK: - Public API

    func setDeviceId(_ id: String) {
        deviceId = id
        guard !relayURLString.isEmpty else { return }
        connect()
    }

    /// Returns a fresh AsyncStream of JPEG frames for this subscriber.
    /// Each call creates an independent subscription — safe to call on every view appearance.
    func makeFrameStream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream<Data>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            Task { @MainActor [weak self] in
                self?.frameSubscribers[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.frameSubscribers.removeValue(forKey: id)
                }
            }
        }
    }

    /// Sends an HTTP request to the Mac via relay and awaits the response.
    /// Use for operations that need a reply (file listing, screen rect, etc.).
    func request(method: String, path: String, body: Data? = nil) async throws -> (Int, Data) {
        guard isConnected, let t = task else { throw RelayError.notConnected }
        let id = UUID().uuidString
        let req = RelayRequest(id: id, method: method, path: path, body: body?.base64EncodedString())
        guard let json = try? JSONEncoder().encode(req),
              let text = String(data: json, encoding: .utf8) else {
            throw RelayError.encodingFailed
        }
        try await t.send(.string(text))
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    /// Sends an HTTP request to the Mac via relay without waiting for a response.
    /// Use for fire-and-forget actions like touch events.
    func sendFireAndForget(method: String, path: String, body: Data? = nil) {
        guard isConnected, let t = task else { return }
        let id = UUID().uuidString
        let req = RelayRequest(id: id, method: method, path: path, body: body?.base64EncodedString())
        guard let json = try? JSONEncoder().encode(req),
              let text = String(data: json, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    // MARK: - WebSocket tunnel (terminal)

    func openWSTunnel(id: String, onReceive: @escaping (Data) -> Void, onDisconnect: @escaping (Error?) -> Void) async throws {
        guard isConnected, let t = task else { throw RelayError.notConnected }
        wsTunnelHandlers[id] = WSTunnelHandler(onReceive: onReceive, onDisconnect: onDisconnect)
        let msg = "{\"type\":\"ws-open\",\"id\":\"\(id)\"}"
        try await t.send(.string(msg))
    }

    func sendWSTunnelData(id: String, data: Data) {
        let b64 = data.base64EncodedString()
        let msg = "{\"type\":\"ws-data\",\"id\":\"\(id)\",\"data\":\"\(b64)\"}"
        task?.send(.string(msg)) { _ in }
    }

    func sendWSTunnelResize(id: String, cols: Int, rows: Int) {
        let msg = "{\"type\":\"ws-resize\",\"id\":\"\(id)\",\"cols\":\(cols),\"rows\":\(rows)}"
        task?.send(.string(msg)) { _ in }
    }

    func closeWSTunnel(id: String) {
        wsTunnelHandlers.removeValue(forKey: id)
        let msg = "{\"type\":\"ws-close\",\"id\":\"\(id)\"}"
        task?.send(.string(msg)) { _ in }
    }

    // MARK: - Connection management

    private func connect() {
        guard let deviceId, !relayURLString.isEmpty else { return }
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        guard var components = URLComponents(string: relayURLString) else { return }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "room" || $0.name == "role" }
        items += [URLQueryItem(name: "room", value: deviceId),
                  URLQueryItem(name: "role", value: "ios")]
        components.queryItems = items
        guard let url = components.url else { return }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        // isConnected set to true on first successful receive, not here
        reconnectDelay = 1_000_000_000

        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while let t = task, !Task.isCancelled {
            do {
                let message = try await t.receive()
                if !isConnected { isConnected = true }
                handleMessage(message)
            } catch {
                break
            }
        }

        isConnected = false
        task = nil

        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: RelayError.connectionLost)
        }

        let tunnels = wsTunnelHandlers
        wsTunnelHandlers.removeAll()
        for (_, handler) in tunnels {
            handler.onDisconnect(RelayError.connectionLost)
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard deviceId != nil, !relayURLString.isEmpty else { return }
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: reconnectDelay)
            guard !Task.isCancelled else { return }
            reconnectDelay = min(reconnectDelay * 2, 60_000_000_000)
            connect()
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // Binary = JPEG frame — cache latest and fan out to all subscribers
            latestFrameData = data
            for continuation in frameSubscribers.values {
                continuation.yield(data)
            }

        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let type = obj["type"] as? String {
                handleWSTunnelMessage(type: type, obj: obj)
            } else {
                // HTTP proxy response (may have no pending continuation for fire-and-forget requests)
                guard let response = try? JSONDecoder().decode(RelayResponse.self, from: data) else { return }
                let bodyData = response.body.flatMap { Data(base64Encoded: $0) } ?? Data()
                pendingRequests[response.id]?.resume(returning: (response.status, bodyData))
                pendingRequests.removeValue(forKey: response.id)
            }

        @unknown default:
            break
        }
    }

    private func handleWSTunnelMessage(type: String, obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        switch type {
        case "ws-data":
            let data = (obj["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            wsTunnelHandlers[id]?.onReceive(data)
        case "ws-close":
            wsTunnelHandlers[id]?.onDisconnect(nil)
            wsTunnelHandlers.removeValue(forKey: id)
        default:
            break
        }
    }

    // MARK: - Errors

    enum RelayError: Error {
        case notConnected
        case encodingFailed
        case connectionLost
    }
}
