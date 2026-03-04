import Network
import Foundation
import Darwin

// Type-safe shim: links directly to the C `ioctl` symbol with a fixed signature
// so Swift can call it without the variadic restriction.
@_silgen_name("ioctl")
private func ioctlWinSize(_ fd: Int32, _ cmd: UInt, _ ws: UnsafeMutablePointer<winsize>) -> Int32

private let TIOCSWINSZ_VAL: UInt = 0x80087467 // _IOW('t', 103, struct winsize)

// MARK: - Terminal Server

final class TerminalServer {
    private var listener: NWListener?
    private var currentSession: TerminalSession?
    private let port: UInt16 = 8081

    func start() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            print("[TerminalServer] Failed to start on port \(port)")
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            // Terminate any existing session before starting a new one
            self?.currentSession?.stop()
            let session = TerminalSession(connection: connection)
            self?.currentSession = session
            session.start()
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[TerminalServer] Listening on port \(self.port)")
            case .failed(let error):
                print("[TerminalServer] Failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        currentSession?.stop()
        currentSession = nil
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Terminal Session

private final class TerminalSession {
    private let connection: NWConnection
    private var masterFD: Int32 = -1
    private var shellProcess: Process?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if !(self?.spawnShell() ?? false) {
                    self?.connection.cancel()
                }
            case .failed, .cancelled:
                self?.cleanup()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        cleanup()
    }

    // MARK: Shell Spawn

    @discardableResult
    private func spawnShell() -> Bool {
        // Open PTY master
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0,
              grantpt(master) == 0,
              unlockpt(master) == 0,
              let slaveNamePtr = ptsname(master) else {
            if master >= 0 { close(master) }
            return false
        }

        let slaveName = String(cString: slaveNamePtr)

        // Set initial window size (large default so Claude CLI has room)
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctlWinSize(master, TIOCSWINSZ_VAL, &ws)

        let slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); return false }

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l"]
        process.standardInput  = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError  = slaveHandle
        var env = ProcessInfo.processInfo.environment
        env["TERM"]      = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        process.environment = env

        do {
            try process.run()
        } catch {
            print("[TerminalSession] Failed to launch shell: \(error)")
            close(master)
            close(slave)
            return false
        }

        close(slave) // Parent closes slave after handing it to child
        masterFD    = master
        shellProcess = process

        process.terminationHandler = { [weak self] _ in
            self?.cleanup()
        }

        startPTYReader()
        receiveFromClient()
        return true
    }

    // MARK: PTY → WebSocket

    private func startPTYReader() {
        let fd   = masterFD
        let conn = connection
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                let data = Data(buf[0..<n])
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let ctx  = NWConnection.ContentContext(identifier: "pty-out", metadata: [meta])
                conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
            }
        }
    }

    // MARK: WebSocket → PTY

    private func receiveFromClient() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, context, _, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // Check opcode: text = control message (resize), binary = keystroke input
                let isText = (context?
                    .protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?
                    .opcode == .text

                if isText {
                    self.handleControlMessage(data)
                } else if self.masterFD >= 0 {
                    data.withUnsafeBytes { ptr in
                        _ = write(self.masterFD, ptr.baseAddress!, data.count)
                    }
                }
            }

            if error == nil { self.receiveFromClient() }
        }
    }

    // MARK: Resize

    private func handleControlMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cols = json["cols"] as? Int,
              let rows = json["rows"] as? Int,
              masterFD >= 0 else { return }

        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctlWinSize(masterFD, TIOCSWINSZ_VAL, &ws)
    }

    // MARK: Cleanup

    private func cleanup() {
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        shellProcess?.terminate()
        shellProcess = nil
        connection.cancel()
    }
}
