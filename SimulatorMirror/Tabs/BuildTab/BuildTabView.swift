import SwiftUI

// MARK: - Build Tab

struct BuildTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager

    @State private var projectPath = ""
    @State private var scheme = ""
    @State private var schemes: [String] = []
    @State private var isLoadingSchemes = false
    @State private var schemeError: String?
    @State private var destination = "platform=iOS Simulator,OS=latest,name=iPhone 16"

    @State private var buildStatus = BuildStatus.idle
    @State private var logLines: [String] = []
    @State private var nextIndex = 0
    @State private var pollTask: Task<Void, Never>?

    @State private var showProjectBrowser = false
    @State private var showLogsSheet = false
    @State private var showIssuesSheet = false
    @State private var recentProjects: [String] = []

    private static let recentsKey = "buildRecentProjects"

    private func loadRecents() {
        recentProjects = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    private func saveToRecents(_ path: String) {
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentProjects = list
        UserDefaults.standard.set(list, forKey: Self.recentsKey)
    }

    private func selectRecent(_ path: String) {
        projectPath = path
        schemes = []
        schemeError = nil
        loadSchemes()
    }

    enum BuildStatus: String {
        case idle, building, launching, succeeded, failed

        var color: Color {
            switch self {
            case .idle:      return .secondary
            case .building:  return .blue
            case .launching: return .indigo
            case .succeeded: return .green
            case .failed:    return .red
            }
        }

        var label: String {
            switch self {
            case .idle:      return "Ready"
            case .building:  return "Building…"
            case .launching: return "Launching…"
            case .succeeded: return "Succeeded"
            case .failed:    return "Failed"
            }
        }
    }

    private var errorLines: [String]  { logLines.filter { $0.contains(": error:") } }
    private var warningLines: [String] { logLines.filter { $0.contains(": warning:") } }
    private var issueLines: [String]  { logLines.filter { $0.contains(": error:") || $0.contains(": warning:") } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Status + Build/Cancel ───────────────────────────────────
                HStack(spacing: 10) {
                    if buildStatus == .building || buildStatus == .launching {
                        ProgressView()
                            .tint(buildStatus == .launching ? .indigo : .blue)
                            .scaleEffect(0.8)
                    } else {
                        Circle().fill(buildStatus.color).frame(width: 8, height: 8)
                    }
                    Text(buildStatus.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(buildStatus.color)
                    Spacer()
                    if buildStatus == .building || buildStatus == .launching {
                        Button("Cancel") { cancelBuild() }
                            .foregroundStyle(.red)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button(action: startBuild) {
                            Label("Build & Run", systemImage: "hammer.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canBuild)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()

                // ── Logs + Issues sheet buttons ─────────────────────────────
                HStack(spacing: 12) {
                    Button {
                        showLogsSheet = true
                    } label: {
                        Label(logLines.isEmpty ? "Logs" : "Logs (\(logLines.count))",
                              systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(logLines.isEmpty)

                    Button {
                        showIssuesSheet = true
                    } label: {
                        Label("Issues (\(errorLines.count)E \(warningLines.count)W)",
                              systemImage: "exclamationmark.triangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(errorLines.isEmpty ? (warningLines.isEmpty ? nil : .orange) : .red)
                    .disabled(issueLines.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()

                // ── Form ────────────────────────────────────────────────────
                Form {
                    if !recentProjects.isEmpty {
                        Section("Recent") {
                            ForEach(recentProjects, id: \.self) { path in
                                Button { selectRecent(path) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: path.hasSuffix(".xcworkspace")
                                              ? "square.stack.3d.up.fill" : "square.on.square.fill")
                                            .foregroundStyle(.blue)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            Text((path as NSString).deletingLastPathComponent)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                }
                            }
                            .onDelete { indices in
                                recentProjects.remove(atOffsets: indices)
                                UserDefaults.standard.set(recentProjects, forKey: Self.recentsKey)
                            }
                        }
                    }

                    Section("Project") {
                        HStack {
                            TextField("/path/to/Project.xcodeproj", text: $projectPath)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 14))
                                .onSubmit { loadSchemes() }
                            Button { showProjectBrowser = true } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Section("Scheme (optional)") {
                        if isLoadingSchemes {
                            HStack {
                                ProgressView()
                                Text("Detecting…").foregroundStyle(.secondary)
                            }
                        } else if schemes.isEmpty {
                            HStack {
                                Text("Auto (default scheme)").foregroundStyle(.secondary)
                                Spacer()
                                Button("Detect") { loadSchemes() }
                                    .buttonStyle(.borderless)
                                    .disabled(projectPath.isEmpty)
                            }
                        } else {
                            Picker("Scheme", selection: $scheme) {
                                Text("Auto").tag("")
                                ForEach(schemes, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if let err = schemeError {
                            Text(err)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }

                    Section("Destination") {
                        TextField("platform=iOS Simulator,OS=latest,name=iPhone 16",
                                  text: $destination)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 13))
                    }
                }
            }
            .navigationTitle("Build")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !logLines.isEmpty {
                        Button {
                            logLines = []
                            nextIndex = 0
                            buildStatus = .idle
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 72)
        }
        .onAppear { loadRecents() }
        .onChange(of: projectPath) { _, path in
            guard path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") else { return }
            loadSchemes()
        }
        .sheet(isPresented: $showProjectBrowser) {
            ProjectPickerSheet { path in
                projectPath = path
                showProjectBrowser = false
                loadSchemes()
            }
        }
        .sheet(isPresented: $showLogsSheet) {
            NavigationStack {
                BuildLogView(lines: logLines)
                    .navigationTitle("Build Logs")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showLogsSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showIssuesSheet) {
            NavigationStack {
                BuildLogView(lines: issueLines)
                    .navigationTitle("Issues (\(errorLines.count)E \(warningLines.count)W)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showIssuesSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: - Build actions

    private var canBuild: Bool { !projectPath.isEmpty }

    private func startBuild() {
        logLines = []
        nextIndex = 0
        buildStatus = .building
        let body = try? JSONEncoder().encode(["project": projectPath, "scheme": scheme, "destination": destination])

        if relayManager.isConnected {
            relayManager.sendFireAndForget(method: "POST", path: "/build/start", body: body)
        } else if let url = settings.buildURL("/build/start") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            URLSession.shared.dataTask(with: req).resume()
        }
        startPolling()
    }

    private func cancelBuild() {
        if relayManager.isConnected {
            relayManager.sendFireAndForget(method: "POST", path: "/build/cancel")
        } else if let url = settings.buildURL("/build/cancel") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled && (buildStatus == .building || buildStatus == .launching) {
                await fetchOutput()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func fetchOutput() async {
        let path = "/build/output?since=\(nextIndex)"
        do {
            let data: Data
            if relayManager.isConnected {
                let (_, d) = try await relayManager.request(method: "GET", path: path)
                data = d
            } else {
                guard let url = settings.buildURL(path) else { return }
                let (d, _) = try await URLSession.shared.data(from: url)
                data = d
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statusStr = json["status"] as? String,
                  let lines = json["lines"] as? [String],
                  let nextIdx = json["nextIndex"] as? Int else { return }
            await MainActor.run {
                nextIndex = nextIdx
                logLines.append(contentsOf: lines)
                if let s = BuildStatus(rawValue: statusStr) { buildStatus = s }
                if buildStatus != .building && buildStatus != .launching { pollTask?.cancel() }
            }
        } catch {}
    }

    // MARK: - Scheme detection

    private func loadSchemes() {
        guard !projectPath.isEmpty else { return }
        isLoadingSchemes = true
        schemeError = nil
        schemes = []
        let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        let path = "/build/schemes?project=\(encoded)"
        Task {
            do {
                let data: Data
                if relayManager.isConnected {
                    let (_, d) = try await relayManager.request(method: "GET", path: path)
                    data = d
                } else {
                    guard let url = settings.buildURL(path) else { throw URLError(.badURL) }
                    let (d, _) = try await URLSession.shared.data(from: url)
                    data = d
                }
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let fetched = json?["schemes"] as? [String] ?? []
                let rawError = json?["error"] as? String
                await MainActor.run {
                    schemes = fetched
                    scheme = fetched.first ?? ""
                    isLoadingSchemes = false
                    if fetched.isEmpty {
                        schemeError = rawError ?? "No schemes found. Check the project path and that xcode-select points to Xcode:\n  sudo xcode-select -s /Applications/Xcode-16.2.0.app"
                    } else {
                        saveToRecents(projectPath)
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingSchemes = false
                    schemeError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Build Log View

struct BuildLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i])
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(lineColor(lines[i]))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(uiColor: .systemBackground))
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains(": error:")             { return .red }
        if line.contains(": warning:")           { return .orange }
        if line.hasPrefix("** BUILD SUCCEEDED") { return .green }
        if line.hasPrefix("** BUILD FAILED")    { return .red }
        if line.hasPrefix("===") || line.hasPrefix("**") { return .primary }
        return .secondary
    }
}

// MARK: - Project Picker

struct ProjectPickerSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let roots: [(label: String, icon: String, path: String)] = [
        ("Home",         "house.fill",        "~"),
        ("Developer",    "hammer.fill",        "~/Developer"),
        ("Documents",    "doc.fill",           "~/Documents"),
        ("Desktop",      "desktopcomputer",    "~/Desktop"),
        ("Downloads",    "arrow.down.circle",  "~/Downloads"),
        ("Applications", "square.grid.2x2",   "/Applications"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(roots, id: \.path) { root in
                    NavigationLink(value: root.path) {
                        Label(root.label, systemImage: root.icon)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Choose Project")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { path in
                ProjectDirectoryView(path: path, onSelect: onSelect)
                    .navigationTitle(path == "~" ? "Home" : URL(fileURLWithPath: path).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct ProjectDirectoryView: View {
    let path: String
    let onSelect: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager
    @State private var resolvedPath = ""
    @State private var entries: [PEntry] = []
    @State private var isLoading = false

    struct PEntry: Identifiable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
        let fullPath: String
        var isProject: Bool { name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") }
    }

    private var dirs: [PEntry]     { entries.filter { $0.isDirectory && !$0.isProject && !$0.name.hasPrefix(".") }.sorted { $0.name < $1.name } }
    private var projects: [PEntry] { entries.filter { $0.isProject }.sorted { $0.name < $1.name } }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !projects.isEmpty {
                        Section("Projects") {
                            ForEach(projects) { entry in
                                Button { onSelect(entry.fullPath) } label: {
                                    Label(entry.name,
                                          systemImage: entry.name.hasSuffix(".xcworkspace")
                                            ? "square.stack.3d.up" : "square.on.square")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    if !dirs.isEmpty {
                        Section("Folders") {
                            ForEach(dirs) { entry in
                                NavigationLink(value: entry.fullPath) {
                                    Label(entry.name, systemImage: "folder")
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .onAppear { fetchEntries() }
    }

    private func fetchEntries() {
        isLoading = true
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        Task {
            do {
                let data: Data
                if relayManager.isConnected {
                    let (_, d) = try await relayManager.request(method: "GET", path: "/files?path=\(encoded)")
                    data = d
                } else {
                    guard let base = settings.filesURL,
                          var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
                    comps.queryItems = [URLQueryItem(name: "path", value: path)]
                    guard let url = comps.url else { return }
                    let (d, _) = try await URLSession.shared.data(from: url)
                    data = d
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resolved = json["path"] as? String,
                      let rawEntries = json["entries"] as? [[String: Any]] else {
                    await MainActor.run { isLoading = false }
                    return
                }
                let mapped: [PEntry] = rawEntries.compactMap { d in
                    guard let name = d["name"] as? String else { return nil }
                    let isDir = (d["isDirectory"] as? Bool) ?? ((d["isDirectory"] as? Int) == 1)
                    return PEntry(name: name, isDirectory: isDir, fullPath: resolved + "/" + name)
                }
                await MainActor.run {
                    resolvedPath = resolved
                    entries = mapped
                    isLoading = false
                }
            } catch {
                await MainActor.run { isLoading = false }
            }
        }
    }
}
