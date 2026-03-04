import SwiftUI

struct SettingsTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager
    @Binding var showDiscovery: Bool

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Mac Server") {
                    if settings.hasConfiguredServer {
                        Label(settings.serverName, systemImage: "desktopcomputer")
                            .foregroundStyle(.primary)
                    } else {
                        Label("Not connected", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showDiscovery = true
                    } label: {
                        Label("Find Server…", systemImage: "magnifyingglass")
                    }
                }

                Section("Claude") {
                    LabeledContent("Session URL") {
                        TextField("https://claude.ai/...", text: $settings.claudeURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                    }
                }

                // ── Remote Access via WebSocket relay ────────────────────────────
                Section {
                    // Connection status
                    Group {
                        if relayManager.isConnected {
                            Label("Connected via relay", systemImage: "point.3.filled.connected.trianglepath.dotted")
                                .foregroundStyle(.green)
                        } else if !settings.relayRoomId.isEmpty && !settings.relayURL.isEmpty {
                            Label("Connecting to relay…", systemImage: "circle.dotted")
                                .foregroundStyle(.orange)
                        } else {
                            Label("Not configured", systemImage: "icloud.slash")
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Relay URL — entered once, saved in UserDefaults
                    LabeledContent("Relay URL") {
                        TextField("wss://simulatormirror-relay.fly.dev", text: $settings.relayURL)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                    }

                    // Room ID — paste from Mac's "Copy Room ID" menu item
                    // (or auto-filled by CloudKit when both devices share an iCloud account)
                    LabeledContent("Room ID") {
                        HStack(spacing: 4) {
                            TextField("Paste from Mac menu bar", text: $settings.relayRoomId)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .autocapitalization(.none)
                            if !settings.relayRoomId.isEmpty {
                                Button {
                                    settings.relayRoomId = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Remote Access")
                } footer: {
                    Text("Run the relay on your Mac: cd relay-server && node index.js\nThen enter its IP above and paste the Room ID from the Mac menu bar.")
                        .font(.caption)
                }

                Section {
                    Toggle("Force Relay Only", isOn: $settings.debugForceRelay)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Disables local MJPEG. Use when testing relay from the same network.")
                        .font(.caption)
                }

                Section("Stream URL") {
                    if let url = settings.streamURL {
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
