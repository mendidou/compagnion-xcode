import Foundation

/// Connects outbound to the relay server and bridges the Mac's local HTTP server
/// to a remote iOS client sharing the same room ID.
///
/// **Binary messages** sent to relay: raw JPEG frames (one per message)
///
/// **Text messages received from relay** (JSON):
///   - HTTP proxy:  `{ "id": "...", "method": "GET", "path": "/...", "body": null }`
///   - WS tunnel:   `{ "type": "ws-open"|"ws-data"|"ws-resize"|"ws-close", "id": "...", ... }`
///
/// **Text messages sent to relay** (JSON):
///   - HTTP proxy response: `{ "id": "...", "status": 200, "body": "<base64>" }`
///   - WS tunnel data:      `{ "type": "ws-data"|"ws-close", "id": "...", "data": "<base64>" }`
final class RelayClient: @unchecked Sendable {

    private let roomId: String
    private let relayURL: String

    private var task: URLSessionWebSocketTask?
    private var frameBuffer: FrameBuffer?

    private var frameTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: UInt64 = 1_000_000_000
    private var consecutiveFailures = 0

    /// Active WebSocket tunnels keyed by session ID (for terminal forwarding).
    private var wsTunnels: [String: URLSessionWebSocketTask] = [:]

    /// Called on the main thread when relay connection status changes.
    var onStatusChange: ((Bool) -> Void)?

    init(roomId: String, relayURL: String) {
        self.roomId = roomId
        self.relayURL = relayURL
    }

    func start(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        receiveTask?.cancel()
        frameTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        closeAllTunnels()
    }

    // MARK: - Connection

    private func connect() {
        guard var components = URLComponents(string: relayURL) else { return }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "room" || $0.name == "role" }
        items += [URLQueryItem(name: "room", value: roomId),
                  URLQueryItem(name: "role", value: "mac")]
        components.queryItems = items
        guard let url = components.url else { return }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        reconnectDelay = 1_000_000_000

        print("[RelayClient] Connecting to room \(roomId.prefix(8))… via \(relayURL)")

        frameTask?.cancel()
        frameTask = Task { [weak self] in await self?.streamFrames() }

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    // MARK: - Frame streaming

    private func streamFrames() async {
        guard let fb = frameBuffer else { return }
        let (stream, _) = await fb.makeStream()
        for await jpeg in stream {
            guard !Task.isCancelled else { break }
            try? await task?.send(.data(jpeg))
        }
    }

    // MARK: - Receive loop

    private var didNotifyConnected = false

    private func receiveLoop() async {
        while let t = task, !Task.isCancelled {
            do {
                let message = try await t.receive()
                if !didNotifyConnected {
                    didNotifyConnected = true
                    consecutiveFailures = 0
                    DispatchQueue.main.async { self.onStatusChange?(true) }
                    print("[RelayClient] Connected to room \(roomId.prefix(8))…")
                }
                if case .string(let text) = message {
                    handleIncomingText(text)
                }
            } catch {
                break
            }
        }
        didNotifyConnected = false
        print("[RelayClient] Disconnected from room \(roomId.prefix(8))…")
        DispatchQueue.main.async { self.onStatusChange?(false) }
        task = nil
        closeAllTunnels()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            print("[RelayClient] Relay unreachable after \(consecutiveFailures) attempts, stopping.")
            return
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: reconnectDelay)
            guard !Task.isCancelled else { return }
            reconnectDelay = min(reconnectDelay * 2, 60_000_000_000)
            connect()
        }
    }

    // MARK: - Incoming message routing

    private func handleIncomingText(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let type = obj["type"] as? String {
            // WS tunnel control message
            handleWSTunnelMessage(type: type, obj: obj)
        } else {
            // HTTP proxy request
            handleHTTPRequest(json: json, obj: obj)
        }
    }

    // MARK: - HTTP request proxying

    private struct IncomingRequest: Decodable {
        let id: String
        let method: String
        let path: String
        let body: String?
    }

    private struct OutgoingResponse: Encodable {
        let id: String
        let status: Int
        let body: String?
    }

    private func handleHTTPRequest(json: String, obj: [String: Any]) {
        guard let data = json.data(using: .utf8),
              let req = try? JSONDecoder().decode(IncomingRequest.self, from: data) else {
            return
        }

        // Short-circuit touch events: skip the HTTP hop entirely.
        if req.method == "POST", req.path == "/touch",
           let bodyB64 = req.body, let bodyData = Data(base64Encoded: bodyB64) {
            TouchReceiver.handle(data: bodyData)
            return
        }

        // Short-circuit no-body POST actions: call handlers directly, skip HTTP round-trip.
        if req.method == "POST" {
            switch req.path {
            case "/home":         SimulatorActions.home();                  return
            case "/screenshot":   SimulatorActions.screenshot();            return
            case "/rotate":       SimulatorActions.rotate();                return
            case "/shake":        SimulatorActions.shake();                 return
            case "/keyboard":     KeyboardReceiver.handle();                return
            case "/movefront":    SimulatorWindowManager.moveToFront();     return
            case "/build/cancel": BuildManager.shared.cancel();             return
            default: break
            }
        }

        // Short-circuit /build/start: decode JSON body and call BuildManager directly.
        if req.method == "POST", req.path == "/build/start",
           let bodyB64 = req.body, let bodyData = Data(base64Encoded: bodyB64),
           let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
           let project = obj["project"] {
            let scheme = obj["scheme"] ?? ""
            let destination = obj["destination"] ?? "platform=iOS Simulator,OS=latest,name=iPhone 16"
            BuildManager.shared.start(project: project, scheme: scheme, destination: destination)
            return
        }

        // Short-circuit GET /status: return JSON response directly.
        if req.method == "GET", req.path == "/status" {
            let frontmost = SimulatorWindowManager.isSimulatorFrontmost()
            let body = "{\"simulatorFrontmost\":\(frontmost)}"
            if let bodyData = body.data(using: .utf8) {
                sendResponse(OutgoingResponse(id: req.id, status: 200, body: bodyData.base64EncodedString()))
            }
            return
        }

        let urlString = "http://localhost:8080\(req.path)"
        guard let url = URL(string: urlString) else {
            sendResponse(OutgoingResponse(id: req.id, status: 400, body: nil))
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = req.method
        urlRequest.timeoutInterval = 10

        if let bodyB64 = req.body, let bodyData = Data(base64Encoded: bodyB64) {
            urlRequest.httpBody = bodyData
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        URLSession.shared.dataTask(with: urlRequest) { [weak self] responseData, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 500
            let bodyB64 = responseData?.base64EncodedString()
            self?.sendResponse(OutgoingResponse(id: req.id, status: status, body: bodyB64))
        }.resume()
    }

    private func sendResponse(_ response: OutgoingResponse) {
        guard let json = try? JSONEncoder().encode(response),
              let text = String(data: json, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - WebSocket tunnel (terminal forwarding)

    private func handleWSTunnelMessage(type: String, obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        switch type {
        case "ws-open":
            openWSTunnel(id: id)
        case "ws-data":
            if let b64 = obj["data"] as? String, let data = Data(base64Encoded: b64) {
                wsTunnels[id]?.send(.data(data)) { _ in }
            }
        case "ws-resize":
            let cols = obj["cols"] as? Int ?? 80
            let rows = obj["rows"] as? Int ?? 24
            let msg = "{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)}"
            wsTunnels[id]?.send(.string(msg)) { _ in }
        case "ws-close":
            wsTunnels[id]?.cancel(with: .goingAway, reason: nil)
            wsTunnels.removeValue(forKey: id)
        default:
            break
        }
    }

    private func openWSTunnel(id: String) {
        guard let url = URL(string: "ws://localhost:8081") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        wsTunnels[id] = ws
        ws.resume()
        receiveWSTunnel(id: id)
    }

    private func receiveWSTunnel(id: String) {
        guard let ws = wsTunnels[id] else { return }
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let data)):
                self.sendTunnelData(id: id, data: data)
                self.receiveWSTunnel(id: id)
            case .success(.string(let str)):
                let data = str.data(using: .utf8) ?? Data()
                self.sendTunnelData(id: id, data: data)
                self.receiveWSTunnel(id: id)
            case .failure:
                self.wsTunnels.removeValue(forKey: id)
                let msg = "{\"type\":\"ws-close\",\"id\":\"\(id)\"}"
                self.task?.send(.string(msg)) { _ in }
            @unknown default:
                self.receiveWSTunnel(id: id)
            }
        }
    }

    private func sendTunnelData(id: String, data: Data) {
        let b64 = data.base64EncodedString()
        let msg = "{\"type\":\"ws-data\",\"id\":\"\(id)\",\"data\":\"\(b64)\"}"
        task?.send(.string(msg)) { _ in }
    }

    private func closeAllTunnels() {
        for (id, ws) in wsTunnels {
            ws.cancel(with: .goingAway, reason: nil)
            let msg = "{\"type\":\"ws-close\",\"id\":\"\(id)\"}"
            task?.send(.string(msg)) { _ in }
        }
        wsTunnels.removeAll()
    }
}
