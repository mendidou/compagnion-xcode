import Network
import Foundation

final class HTTPServer {
    private var listener: NWListener?
    private var frameBuffer: FrameBuffer?
    private let port: UInt16 = 8080

    func start(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            print("[HTTPServer] Failed to create listener on port \(port)")
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        // Advertise on Bonjour so the iOS app can discover it without manual IP entry
        listener.service = NWListener.Service(name: nil, type: "_simulatormirror._tcp")

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[HTTPServer] Listening on port \(self.port)")
            case .failed(let error):
                print("[HTTPServer] Failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            guard let requestStr = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = requestStr.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let method = parts[0]
            let path = parts[1]

            if method == "GET" && path == "/stream" {
                if let fb = self.frameBuffer {
                    MJPEGStreamHandler.stream(to: connection, frameBuffer: fb)
                }
            } else if method == "GET" && path == "/status" {
                let frontmost = SimulatorWindowManager.isSimulatorFrontmost()
                let json = "{\"simulatorFrontmost\":\(frontmost)}"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else if method == "GET" && path == "/screenrect" {
                let r = SimulatorWindowManager.screenRect()
                let json = "{\"x\":\(r.minX),\"y\":\(r.minY),\"width\":\(r.width),\"height\":\(r.height)}"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else if method == "POST" && path == "/movefront" {
                SimulatorWindowManager.moveToFront()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else if method == "POST" && path == "/home" {
                SimulatorActions.home()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            } else if method == "POST" && path == "/screenshot" {
                SimulatorActions.screenshot()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            } else if method == "POST" && path == "/rotate" {
                SimulatorActions.rotate()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            } else if method == "POST" && path == "/shake" {
                SimulatorActions.shake()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            } else if method == "POST" && path == "/keyboard" {
                KeyboardReceiver.handle()
            } else if method == "POST" && path == "/touch" {
                let bodyStart = requestStr.range(of: "\r\n\r\n")
                if let range = bodyStart {
                    let bodyStr = String(requestStr[range.upperBound...])
                    if let bodyData = bodyStr.data(using: .utf8) {
                        TouchReceiver.handle(data: bodyData)
                    }
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else if method == "GET" && path.hasPrefix("/build/output") {
                let since = parseQueryInt(from: path, key: "since") ?? 0
                let result = BuildManager.shared.outputSince(since)
                let obj: [String: Any] = ["status": result.status.rawValue,
                                          "lines": result.lines,
                                          "nextIndex": result.nextIndex]
                if let data = try? JSONSerialization.data(withJSONObject: obj) {
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
                    var payload = header.data(using: .utf8)!
                    payload.append(data)
                    connection.send(content: payload, completion: .contentProcessed({ _ in connection.cancel() }))
                }
            } else if method == "GET" && path.hasPrefix("/build/schemes") {
                handleBuildSchemesRequest(connection: connection, rawPath: path)
            } else if method == "POST" && path == "/build/start" {
                let bodyStart = requestStr.range(of: "\r\n\r\n")
                if let range = bodyStart,
                   let bodyData = String(requestStr[range.upperBound...]).data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String],
                   let project = obj["project"] {
                    let scheme = obj["scheme"] ?? ""
                    let destination = obj["destination"] ?? "platform=iOS Simulator,OS=latest,name=iPhone 16"
                    BuildManager.shared.start(project: project, scheme: scheme, destination: destination)
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            } else if method == "POST" && path == "/build/cancel" {
                BuildManager.shared.cancel()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
            } else if method == "GET" && path.hasPrefix("/files") {
                handleFilesRequest(connection: connection, rawPath: path)
            } else {
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
    }

    private func parseQueryInt(from path: String, key: String) -> Int? {
        guard let qi = path.firstIndex(of: "?") else { return nil }
        let qs = String(path[path.index(after: qi)...])
        for param in qs.components(separatedBy: "&") {
            let kv = param.components(separatedBy: "=")
            if kv.count == 2, kv[0] == key, let val = Int(kv[1]) { return val }
        }
        return nil
    }

    private func handleBuildSchemesRequest(connection: NWConnection, rawPath: String) {
        var projectPath = ""
        if let qi = rawPath.firstIndex(of: "?") {
            let qs = String(rawPath[rawPath.index(after: qi)...])
            for param in qs.components(separatedBy: "&") {
                let kv = param.components(separatedBy: "=")
                if kv.count == 2, kv[0] == "project" {
                    projectPath = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        guard !projectPath.isEmpty else {
            sendJSON(connection: connection, status: 400, obj: ["error": "missing project"])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: BuildManager.xcodebuildPath)
            proc.arguments = projectPath.hasSuffix(".xcworkspace")
                ? ["-workspace", projectPath, "-list", "-json"]
                : ["-project",   projectPath, "-list", "-json"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError  = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                self.sendJSON(connection: connection, status: 500, obj: ["error": error.localizedDescription])
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let rawOutput = String(data: data, encoding: .utf8) ?? ""
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // xcodebuild failed — return the raw output so the iOS app can show the error
                let detail = rawOutput.isEmpty ? "xcodebuild produced no output (exit \(proc.terminationStatus))" : rawOutput
                self.sendJSON(connection: connection, status: 200, obj: ["schemes": [String](), "error": detail])
                return
            }
            let schemes: [String]
            if let proj = json["project"] as? [String: Any] {
                schemes = proj["schemes"] as? [String] ?? []
            } else if let ws = json["workspace"] as? [String: Any] {
                schemes = ws["schemes"] as? [String] ?? []
            } else {
                schemes = []
            }
            if schemes.isEmpty {
                self.sendJSON(connection: connection, status: 200, obj: ["schemes": [String](), "error": rawOutput])
            } else {
                self.sendJSON(connection: connection, status: 200, obj: ["schemes": schemes])
            }
        }
    }

    private func sendJSON(connection: NWConnection, status: Int, obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let statusText = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Internal Server Error")
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n\r\n"
        var payload = header.data(using: .utf8)!
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed({ _ in connection.cancel() }))
    }

    // Encodable types guarantee Bool → true/false (not 1/0) unlike JSONSerialization + [String: Any]
    private struct FilesResponseBody: Encodable {
        let path: String
        let entries: [FileEntryBody]
    }
    private struct FileEntryBody: Encodable {
        let name: String
        let isDirectory: Bool
        let size: Int
    }

    private func handleFilesRequest(connection: NWConnection, rawPath: String) {
        // Parse optional ?path= query parameter
        var dirPath: String
        if let queryStart = rawPath.firstIndex(of: "?") {
            let queryString = String(rawPath[rawPath.index(after: queryStart)...])
            var pathParam: String?
            for param in queryString.components(separatedBy: "&") {
                let kv = param.components(separatedBy: "=")
                if kv.count == 2, kv[0] == "path" {
                    pathParam = kv[1].removingPercentEncoding
                }
            }
            dirPath = pathParam ?? ""
        } else {
            dirPath = ""
        }

        // Resolve ~ and empty to home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if dirPath.isEmpty || dirPath == "~" {
            dirPath = home
        } else if dirPath.hasPrefix("~/") {
            dirPath = home + String(dirPath.dropFirst(1))
        }

        do {
            let fm = FileManager.default
            let names = try fm.contentsOfDirectory(atPath: dirPath).sorted()
            var entries: [FileEntryBody] = []
            for name in names {
                let fullPath = (dirPath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                let size: Int
                if !isDir.boolValue,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let fileSize = attrs[.size] as? Int {
                    size = fileSize
                } else {
                    size = 0
                }
                entries.append(FileEntryBody(name: name, isDirectory: isDir.boolValue, size: size))
            }
            let body = FilesResponseBody(path: dirPath, entries: entries)
            let jsonData = try JSONEncoder().encode(body)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(jsonData.count)\r\n\r\n"
            var payload = header.data(using: .utf8)!
            payload.append(jsonData)
            connection.send(content: payload, completion: .contentProcessed({ _ in connection.cancel() }))
        } catch {
            let msg = "{\"error\":\"\(error.localizedDescription)\"}"
            let response = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: \(msg.utf8.count)\r\n\r\n\(msg)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in connection.cancel() }))
        }
    }
}
