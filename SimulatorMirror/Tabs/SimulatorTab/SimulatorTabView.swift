import SwiftUI

struct SimulatorTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager
    @State private var client = MJPEGClient()
    @State private var statusChecker = SimulatorStatusChecker()
    @State private var screenRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    // Relay state
    @State private var relayImage: UIImage?
    @State private var relayStreamTask: Task<Void, Never>?

    /// Reference type so we can mutate without triggering a SwiftUI body re-evaluation.
    private class MoveThrottle {
        var lastSent: Date = .distantPast
    }
    @State private var throttle = MoveThrottle()

    /// Use relay when it's connected AND local MJPEG isn't delivering frames.
    /// This means relay automatically takes over when away from home —
    /// even if a local server was previously configured.
    private var useRelay: Bool {
        relayManager.isConnected && client.currentImage == nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: 0.60, saturation: 0.75, brightness: 0.22),
                        Color(hue: 0.63, saturation: 0.85, brightness: 0.07),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                if useRelay {
                    if let image = relayImage {
                        let t = DisplayTransform(imageSize: image.size,
                                                screenRect: screenRect,
                                                displaySize: geo.size)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: t.scaledW, height: t.scaledH)
                            .position(x: t.centerX, y: t.centerY)
                            .allowsHitTesting(false)

                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let mapped = t.normalize(from: value.location)
                                        let type = value.translation == .zero ? "down" : "move"
                                        sendRelayTouch(type: type, point: mapped)
                                    }
                                    .onEnded { value in
                                        let mapped = t.normalize(from: value.location)
                                        sendRelayTouch(type: "up", point: mapped)
                                    }
                            )
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Connecting via relay…")
                                .foregroundStyle(.white)
                                .font(.caption)
                        }
                    }

                } else if let image = client.currentImage {
                    let t = DisplayTransform(imageSize: image.size,
                                            screenRect: screenRect,
                                            displaySize: geo.size)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: t.scaledW, height: t.scaledH)
                        .position(x: t.centerX, y: t.centerY)
                        .allowsHitTesting(false)

                    TouchOverlayView(
                        touchURL: settings.touchURL,
                        coordinateMapper: { t.normalize(from: $0) },
                        onAction: { statusChecker.checkNow() }
                    )
                } else if settings.hasConfiguredServer || !settings.relayRoomId.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(settings.hasConfiguredServer ? "Connecting to Simulator…" : "Connecting via relay…")
                            .foregroundStyle(.white)
                            .font(.caption)
                    }
                }

                let hasContent = useRelay ? relayImage != nil : client.currentImage != nil
                if hasContent {
                    SimulatorCoverageOverlayView(
                        isFrontmost:     statusChecker.isSimulatorFrontmost,
                        isMovingToFront: statusChecker.isMovingToFront,
                        onMoveToFront:   { statusChecker.moveToFront() }
                    )
                }
            }
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            // Seed relay image from last known frame so re-appearing tab doesn't flash a spinner
            if relayImage == nil, let cached = relayManager.latestFrameData {
                relayImage = UIImage(data: cached)
            }
            // Always try local if previously configured — runs in background even if relay is also active.
            // Skip when debugForceRelay is on (relay-only mode for testing).
            if !settings.debugForceRelay, settings.hasConfiguredServer, let url = settings.streamURL {
                client.connect(to: url)
                fetchScreenRect()
                statusChecker.startPolling(statusURL: settings.statusURL,
                                           moveFrontURL: settings.moveFrontURL)
            }
            // Always start relay stream — it becomes visible only if local delivers no frames
            if relayManager.isConnected {
                startRelayStream()
                if client.currentImage == nil { fetchScreenRectViaRelay() }
                // Start relay-based status polling when local isn't active
                if !settings.hasConfiguredServer || settings.debugForceRelay {
                    statusChecker.startRelayPolling(relayManager: relayManager)
                }
            }
        }
        .onDisappear {
            relayStreamTask?.cancel()
            relayStreamTask = nil
            client.disconnect()
            statusChecker.stopPolling()
        }
        // Relay connects after view appears — start stream without stopping local
        .onChange(of: relayManager.isConnected) { _, connected in
            if connected {
                startRelayStream()
                if client.currentImage == nil { fetchScreenRectViaRelay() }
                if !settings.hasConfiguredServer || settings.debugForceRelay {
                    statusChecker.startRelayPolling(relayManager: relayManager)
                }
            }
        }
        // Local server URL changes (Bonjour discovery)
        .onChange(of: settings.streamURL) { _, newURL in
            guard !settings.debugForceRelay else { return }
            client.disconnect()
            if let url = newURL { client.connect(to: url) }
            fetchScreenRect()
        }
        .onChange(of: settings.statusURL) { _, _ in
            statusChecker.startPolling(statusURL: settings.statusURL,
                                       moveFrontURL: settings.moveFrontURL)
        }
    }

    // MARK: - Relay helpers

    private func startRelayStream() {
        relayStreamTask?.cancel()
        relayStreamTask = Task {
            for await frameData in relayManager.makeFrameStream() {
                guard !Task.isCancelled else { break }
                if let image = UIImage(data: frameData) {
                    await MainActor.run { relayImage = image }
                }
            }
        }
    }

    private func sendRelayTouch(type: String, point: CGPoint) {
        let event = TouchEvent(type: type, x: Float(point.x), y: Float(point.y))

        // "down" and "up" always sent immediately — only "move" is throttled
        guard type == "move" else {
            fireTouch(event)
            return
        }

        // Throttle move events to 20 fps to avoid flooding the relay
        let now = Date()
        guard now.timeIntervalSince(throttle.lastSent) >= 1.0 / 20.0 else { return }
        throttle.lastSent = now
        fireTouch(event)
    }

    private func fireTouch(_ event: TouchEvent) {
        guard let body = try? JSONEncoder().encode(event) else { return }
        relayManager.sendFireAndForget(method: "POST", path: "/touch", body: body)
    }

    private func fetchScreenRectViaRelay() {
        Task {
            guard let (_, data) = try? await relayManager.request(method: "GET", path: "/screenrect"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                  let x = json["x"], let y = json["y"],
                  let w = json["width"], let h = json["height"],
                  w > 0, h > 0 else { return }
            await MainActor.run {
                screenRect = CGRect(x: x, y: y, width: w, height: h)
            }
        }
    }

    private func fetchScreenRect() {
        guard let url = settings.screenRectURL else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                  let x = json["x"], let y = json["y"],
                  let w = json["width"], let h = json["height"],
                  w > 0, h > 0 else { return }
            DispatchQueue.main.async {
                screenRect = CGRect(x: x, y: y, width: w, height: h)
            }
        }.resume()
    }
}

// MARK: - Display transform

private struct DisplayTransform {
    let scaledW: CGFloat
    let scaledH: CGFloat
    private let offsetX: CGFloat
    private let offsetY: CGFloat

    var centerX: CGFloat { offsetX + scaledW / 2 }
    var centerY: CGFloat { offsetY + scaledH / 2 }

    init(imageSize: CGSize, screenRect: CGRect, displaySize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0,
              screenRect.width > 0, screenRect.height > 0 else {
            scaledW = displaySize.width; scaledH = displaySize.height
            offsetX = 0; offsetY = 0; return
        }
        let contentW = imageSize.width  * screenRect.width
        let contentH = imageSize.height * screenRect.height
        let scale    = max(displaySize.width / contentW, displaySize.height / contentH)
        scaledW  = imageSize.width  * scale
        scaledH  = imageSize.height * scale
        offsetX  = (displaySize.width  - contentW * scale) / 2 - screenRect.minX * scaledW
        offsetY  = (displaySize.height - contentH * scale) / 2 - screenRect.minY * scaledH
    }

    func normalize(from point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(1, (point.x - offsetX) / scaledW)),
            y: max(0, min(1, (point.y - offsetY) / scaledH))
        )
    }
}
