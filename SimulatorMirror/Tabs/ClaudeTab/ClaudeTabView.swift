import SwiftUI
import WebKit

// MARK: - Session Tab

struct SessionTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var sessionManager
    @Environment(RelayManager.self) private var relayManager
    @State private var selectedTab = 0
    @State private var webView = WKWebView()
    @State private var sshConnecting = false
    @State private var presentedSession: TerminalSessionManager.Session?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Claude Remote").tag(0)
                    Text("Terminal").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                if selectedTab == 0 {
                    WebViewRepresentable(webView: webView)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    TerminalConnectionView(
                        sshConnecting: sshConnecting,
                        onConnectSSH: { connectSSH() },
                        onResumeSession: { presentedSession = $0 },
                        onKillSession: { sessionManager.kill(id: $0) }
                    )
                }
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedTab == 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { webView.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            // Handles NavigationLink(value: String) from TerminalConnectionView and
            // nested DirectoryListView pushes — all file drill-down stays in this stack.
            .navigationDestination(for: String.self) { path in
                DirectoryListView(path: path, onOpenTerminal: { openTerminal(at: $0) })
                    .navigationTitle(path == "~" ? "Home" : URL(fileURLWithPath: path).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear { loadClaudeURL() }
        .onChange(of: settings.claudeURL) { _, _ in loadClaudeURL() }
        .fullScreenCover(item: $presentedSession) { session in
            TerminalCoverView(session: session)
                .ignoresSafeArea()
        }
    }

    private func makeConnection() -> TerminalConnection {
        if relayManager.isConnected {
            // Relay takes priority — tunnels to Mac's localhost:8081 whether local or remote
            return RelayTerminalConnection(manager: relayManager)
        } else if settings.terminalMode == "ssh" {
            return SSHConnection(
                host: settings.sshHost,
                port: settings.sshPort,
                username: settings.sshUsername,
                password: settings.sshPassword
            )
        } else {
            return WebSocketConnection(url: settings.terminalWSURL ?? URL(string: "ws://localhost:8081")!)
        }
    }

    private func loadClaudeURL() {
        guard !settings.claudeURL.isEmpty,
              let url = URL(string: settings.claudeURL) else { return }
        webView.load(URLRequest(url: url))
    }

    /// SSH only — opens a terminal at the remote home directory immediately.
    private func connectSSH() {
        sshConnecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            sshConnecting = false
            let connection = makeConnection()
            let label = "SSH \(settings.sshUsername)@\(settings.sshHost)"
            let session = sessionManager.create(label: label, connection: connection)
            presentedSession = session
        }
    }

    /// Called from DirectoryListView "Open Terminal Here" — opens a terminal
    /// already cd'd to the chosen path when the shell becomes ready.
    func openTerminal(at path: String) {
        let connection = makeConnection()
        let label = settings.terminalMode == "ssh"
            ? "SSH \(settings.sshUsername)@\(settings.sshHost)"
            : "Local Server"
        let session = sessionManager.create(
            label: label,
            connection: connection,
            initialCommand: "cd \(path)\n"
        )
        presentedSession = session
    }
}

// MARK: - Terminal Cover View

private struct TerminalCoverView: View {
    let session: TerminalSessionManager.Session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TerminalViewControllerBridge(
            viewController: session.viewController,
            onDismiss: { dismiss() }
        )
        .ignoresSafeArea()
    }
}

// MARK: - Bridge

private struct TerminalViewControllerBridge: UIViewControllerRepresentable {
    let viewController: TerminalViewController
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> TerminalViewController {
        viewController.onDismiss = onDismiss
        return viewController
    }

    func updateUIViewController(_ vc: TerminalViewController, context: Context) {
        vc.onDismiss = onDismiss
    }
}

// MARK: - Terminal ViewController

final class TerminalViewController: UIViewController, WKScriptMessageHandler {

    private let connection: TerminalConnection
    private var webView: WKWebView!
    private var isTerminalReady = false
    private var pendingData: [Data] = []
    private var isConnected = true
    private var ctrlActive = false
    private var ctrlButton: UIButton?

    var onDismiss: (() -> Void)?
    var onSessionDied: (() -> Void)?
    var onDisconnectTapped: (() -> Void)?
    var initialCommand: String?

    init(connection: TerminalConnection) {
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.051, green: 0.067, blue: 0.09, alpha: 1) // #0d1117

        // Nav bar
        let nav = UINavigationBar()
        nav.barStyle = .black
        nav.isTranslucent = true
        nav.tintColor = .white
        nav.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nav)

        let navItem = UINavigationItem(title: "Terminal")
        navItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain, target: self,
            action: #selector(closeTerminal)
        )
        let disconnectBtn = UIBarButtonItem(
            title: "Disconnect",
            style: .plain, target: self,
            action: #selector(disconnectTerminal)
        )
        disconnectBtn.tintColor = .systemRed
        navItem.rightBarButtonItem = disconnectBtn
        nav.items = [navItem]

        // Accessory bar with terminal keys
        let accessoryBar = makeAccessoryBar()
        view.addSubview(accessoryBar)

        // WKWebView with message handlers
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "terminalInput")
        config.userContentController.add(self, name: "terminalResize")
        config.userContentController.add(self, name: "terminalReady")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.051, green: 0.067, blue: 0.09, alpha: 1)
        webView.scrollView.backgroundColor = UIColor(red: 0.051, green: 0.067, blue: 0.09, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            nav.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: nav.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            accessoryBar.topAnchor.constraint(equalTo: webView.bottomAnchor),
            accessoryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessoryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessoryBar.heightAnchor.constraint(equalToConstant: 40),

            view.keyboardLayoutGuide.topAnchor.constraint(equalTo: accessoryBar.bottomAnchor),
        ])

        if let htmlURL = Bundle.main.url(forResource: "terminal", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        startConnection()
    }

    @objc private func closeTerminal() {
        onDismiss?()
    }

    @objc private func disconnectTerminal() {
        isConnected = false
        onDisconnectTapped?()
        onDismiss?()
    }

    // MARK: - Accessory Bar

    private func makeAccessoryBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = UIColor(white: 0.1, alpha: 1)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor, constant: -8),
        ])

        // Key definitions: (label, raw bytes)
        let keys: [(String, Data?)] = [
            ("esc",  Data([0x1B])),
            ("ctrl", nil),  // toggle modifier
            ("tab",  Data([0x09])),
            ("↑",    Data([0x1B, 0x5B, 0x41])),
            ("↓",    Data([0x1B, 0x5B, 0x42])),
            ("←",    Data([0x1B, 0x5B, 0x44])),
            ("→",    Data([0x1B, 0x5B, 0x43])),
            ("^C",   Data([0x03])),
            ("^D",   Data([0x04])),
            ("^Z",   Data([0x1A])),
            ("^L",   Data([0x0C])),
            ("|",    Data([0x7C])),
            ("~",    Data([0x7E])),
            ("-",    Data([0x2D])),
            ("/",    Data([0x2F])),
        ]

        for (label, keyData) in keys {
            let btn = makeKeyButton(label: label, keyData: keyData)
            stack.addArrangedSubview(btn)
            if label == "ctrl" { ctrlButton = btn }
        }

        return bar
    }

    private func makeKeyButton(label: String, keyData: Data?) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = label
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.22, alpha: 1)
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            return a
        }

        let btn: UIButton
        if let data = keyData {
            btn = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.sendKeyData(data)
            })
        } else {
            // Ctrl toggle
            btn = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.toggleCtrl()
            })
        }
        return btn
    }

    private func sendKeyData(_ data: Data) {
        // Reset ctrl if active and this is a direct key (not from keyboard)
        if ctrlActive {
            ctrlActive = false
            updateCtrlHighlight()
        }
        connection.send(data: data)
    }

    private func toggleCtrl() {
        ctrlActive.toggle()
        updateCtrlHighlight()
    }

    private func updateCtrlHighlight() {
        guard let btn = ctrlButton else { return }
        var config = btn.configuration ?? .filled()
        config.baseBackgroundColor = ctrlActive
            ? UIColor.systemBlue
            : UIColor(white: 0.22, alpha: 1)
        btn.configuration = config
    }

    // MARK: - Connection

    private func startConnection() {
        connection.onReceive = { [weak self] data in
            DispatchQueue.main.async {
                self?.writeToTerminal(data)
            }
        }

        connection.onDisconnect = { [weak self] error in
            guard let self else { return }
            isConnected = false
            onSessionDied?()
            let text: String
            if let error {
                text = "\r\n\u{1B}[31mDisconnected: \(error.localizedDescription)\u{1B}[0m\r\n"
            } else {
                text = "\r\n\u{1B}[33mConnection closed.\u{1B}[0m\r\n"
            }
            if let d = text.data(using: .utf8) {
                DispatchQueue.main.async {
                    self.writeToTerminal(d)
                }
            }
        }
    }

    private func writeToTerminal(_ data: Data) {
        guard isTerminalReady else {
            pendingData.append(data)
            return
        }
        let base64 = data.base64EncodedString()
        webView.evaluateJavaScript("writeData('\(base64)')", completionHandler: nil)
    }

    private func flushPending() {
        let queued = pendingData
        pendingData.removeAll()
        for data in queued {
            writeToTerminal(data)
        }
        if let cmd = initialCommand {
            initialCommand = nil
            if let data = cmd.data(using: .utf8) {
                connection.send(data: data)
            }
        }
    }

    /// Removes WKWebView message handlers to break retain cycle. Call before releasing the VC.
    func cleanup() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminalInput")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminalResize")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "terminalReady")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "terminalInput":
            if let b64 = message.body as? String, var data = Data(base64Encoded: b64) {
                // Apply ctrl modifier to single printable character
                if ctrlActive, data.count == 1, let byte = data.first {
                    ctrlActive = false
                    updateCtrlHighlight()
                    if byte >= 0x61 && byte <= 0x7A {       // a-z → ctrl char
                        data = Data([byte - 0x60])
                    } else if byte >= 0x41 && byte <= 0x5A { // A-Z → ctrl char
                        data = Data([byte - 0x40])
                    }
                }
                connection.send(data: data)
            }

        case "terminalResize":
            if let json = message.body as? String,
               let dict = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int],
               let cols = dict["cols"], let rows = dict["rows"] {
                connection.resize(cols: cols, rows: rows)
            }

        case "terminalReady":
            isTerminalReady = true
            flushPending()

        default:
            break
        }
    }

    deinit {
        if isConnected {
            connection.onReceive = nil
            connection.onDisconnect = nil
            connection.disconnect()
        }
    }
}

// MARK: - WebView

struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Terminal Connection View

struct TerminalConnectionView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var sessionManager
    @Environment(RelayManager.self) private var relayManager

    let sshConnecting: Bool
    let onConnectSSH: () -> Void
    let onResumeSession: (TerminalSessionManager.Session) -> Void
    let onKillSession: (UUID) -> Void

    var body: some View {
        @Bindable var settings = settings

        List {
            // ── Connection settings ───────────────────────────────────
            Section {
                Picker("Mode", selection: $settings.terminalMode) {
                    Text("Local Server").tag("local")
                    Text("SSH").tag("ssh")
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)

                if settings.terminalMode == "ssh" {
                    sshFields
                } else {
                    localServerCard
                }
            } header: {
                Text("Terminal Session")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            // ── Open Terminal ─────────────────────────────────────────
            Section {
                if settings.hasConfiguredServer || relayManager.isConnected {
                    // Files accessible (local or relay): browse first, then open terminal there
                    NavigationLink(value: "~") {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.indigo.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.indigo)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Browse Files to Open Terminal")
                                    .font(.subheadline)
                                Text("Navigate to a folder, then tap Open Terminal Here")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                } else if settings.terminalMode == "ssh" && settings.hasConfiguredSSH {
                    // No file access, but SSH credentials available — connect directly
                    Button(action: onConnectSSH) {
                        Group {
                            if sshConnecting {
                                HStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("Connecting…")
                                }
                            } else {
                                Text("Connect")
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(sshConnecting)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

                } else {
                    Label("Connect to a Mac first in Settings", systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Open Terminal")
            }

            // ── Active sessions ───────────────────────────────────────
            if !sessionManager.sessions.isEmpty {
                Section("Active Sessions") {
                    ForEach(sessionManager.sessions) { session in
                        Button {
                            if session.isAlive { onResumeSession(session) }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(session.isAlive ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.label)
                                        .font(.subheadline)
                                        .foregroundStyle(session.isAlive ? .primary : .secondary)
                                    if !session.isAlive {
                                        Text("Disconnected")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if session.isAlive {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            onKillSession(sessionManager.sessions[i].id)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var localServerCard: some View {
        if settings.hasConfiguredServer {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.indigo.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 18))
                        .foregroundStyle(.indigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.serverName)
                        .font(.subheadline)
                    Text(settings.serverIP)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else if relayManager.isConnected {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected via relay")
                        .font(.subheadline)
                    Text("Terminal tunneled through relay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label("Connect to a Mac first in Settings", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sshFields: some View {
        @Bindable var settings = settings

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Host").font(.caption).foregroundStyle(.secondary)
                TextField("hostname or IP", text: $settings.sshHost)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Port").font(.caption).foregroundStyle(.secondary)
                TextField("22", value: $settings.sshPort, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Username").font(.caption).foregroundStyle(.secondary)
            TextField("username", text: $settings.sshUsername)
                .textContentType(.username)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Password").font(.caption).foregroundStyle(.secondary)
            SecureField("password", text: $settings.sshPassword)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
        }

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.blue).padding(.top, 1)
            Text("Enable **Remote Login** on your Mac: System Settings > General > Sharing > Remote Login")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
