import SwiftUI

struct ServerDiscoverySheet: View {
    @Environment(AppSettings.self) private var settings
    @Binding var isPresented: Bool

    @State private var browser = BonjourBrowser()
    @State private var isResolving = false
    @State private var connectingID: UUID?
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Icon + pulse rings ────────────────────────────────────────
            Spacer().frame(height: 44)

            ZStack {
                PulseRing(delay: 0.0, isPulsing: isPulsing && browser.servers.isEmpty)
                PulseRing(delay: 0.5, isPulsing: isPulsing && browser.servers.isEmpty)

                Circle()
                    .fill(.blue.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "desktopcomputer")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.blue)
            }
            .frame(width: 160, height: 160)
            .onAppear { isPulsing = true }

            // ── Title ─────────────────────────────────────────────────────
            Spacer().frame(height: 20)

            Text("Connect to Mac")
                .font(.title2.bold())

            Spacer().frame(height: 8)

            Text(browser.servers.isEmpty
                 ? "Searching for SimulatorMirror Server…"
                 : (browser.servers.count == 1
                    ? "Found your Mac nearby."
                    : "Select your Mac to connect."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // ── Server list ───────────────────────────────────────────────
            Spacer().frame(height: 32)

            if browser.servers.isEmpty {
                ProgressView()
            } else {
                VStack(spacing: 10) {
                    ForEach(browser.servers) { server in
                        ServerRow(
                            server: server,
                            isConnecting: connectingID == server.id,
                            disabled: isResolving,
                            action: { connect(server) }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer()

            // ── Dismiss ───────────────────────────────────────────────────
            Button("Not Now") { isPresented = false }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 36)
        }
        .animation(.spring(duration: 0.45), value: browser.servers.isEmpty)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func connect(_ server: BonjourBrowser.Server) {
        isResolving = true
        connectingID = server.id
        browser.resolve(server) { host, port in
            DispatchQueue.main.async {
                settings.serverIP = host
                settings.serverPort = port
                settings.serverName = server.name
                isResolving = false
                isPresented = false
            }
        }
    }
}

// ── Pulse ring ────────────────────────────────────────────────────────────────

private struct PulseRing: View {
    let delay: Double
    let isPulsing: Bool
    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(Color.blue.opacity(animating ? 0 : 0.35), lineWidth: 1.5)
            .frame(width: 88, height: 88)
            .scaleEffect(animating ? 2.2 : 1.0)
            .onAppear {
                guard isPulsing else { return }
                withAnimation(
                    .easeOut(duration: 1.4)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) { animating = true }
            }
            .onChange(of: isPulsing) { _, on in
                if !on { animating = false }
            }
    }
}

// ── Server row ────────────────────────────────────────────────────────────────

private struct ServerRow: View {
    let server: BonjourBrowser.Server
    let isConnecting: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 21))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("SimulatorMirror Server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
