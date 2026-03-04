import SwiftUI

// MARK: - Models

private struct FileEntry: Identifiable, Decodable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: Int

    private enum CodingKeys: String, CodingKey {
        case name, isDirectory, size
    }

    // Custom decoder: accepts both JSON bool (true/false) and integer (1/0)
    // for isDirectory. The old server serialised Bool via JSONSerialization
    // which can emit 1/0 instead of true/false due to NSNumber bridging.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        if let b = try? c.decode(Bool.self, forKey: .isDirectory) {
            isDirectory = b
        } else {
            isDirectory = ((try? c.decode(Int.self, forKey: .isDirectory)) ?? 0) != 0
        }
    }
}

private struct FilesResponse: Decodable {
    let path: String
    let entries: [FileEntry]
}

// MARK: - File Browser Root
// No network requests here — shows a static list of starting points.
// Loading only happens inside DirectoryListView, which is pushed on navigation.

struct FileBrowserView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager
    let onOpenTerminal: (String) -> Void

    var body: some View {
        if settings.hasConfiguredServer || relayManager.isConnected {
            NavigationStack {
                List {
                    NavigationLink(value: "~") {
                        Label("Home Directory", systemImage: "house.fill")
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
                // Single navigationDestination handles all levels of drill-down.
                // DirectoryListView uses NavigationLink(value:) at every level,
                // and they all resolve here — no duplicate registrations needed.
                .navigationDestination(for: String.self) { path in
                    DirectoryListView(path: path, onOpenTerminal: onOpenTerminal)
                        .navigationTitle(navigationTitle(for: path))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        } else {
            ContentUnavailableView(
                "No Server Connected",
                systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                description: Text("Connect to a Mac in Settings to browse files.")
            )
        }
    }

    private func navigationTitle(for path: String) -> String {
        path == "~" ? "Home" : URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Directory List View
// Only fetches when it appears (i.e. after the user taps into the folder).
// Internal (not private) so ClaudeTabView can push it onto the Terminal tab's NavigationStack.

struct DirectoryListView: View {
    let path: String        // "~" → home dir; absolute path for subfolders
    let onOpenTerminal: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(RelayManager.self) private var relayManager
    @State private var resolvedPath = ""
    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                ContentUnavailableView(
                    "Cannot Load Directory",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Retry") { fetch() }
                    }
                }
            } else {
                List {
                    ForEach(sortedEntries) { entry in
                        if entry.isDirectory {
                            NavigationLink(value: "\(resolvedPath)/\(entry.name)") {
                                Label(entry.name, systemImage: "folder.fill")
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            HStack {
                                Label(entry.name, systemImage: fileIcon(for: entry.name))
                                Spacer()
                                if entry.size > 0 {
                                    Text(formattedSize(entry.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onOpenTerminal(resolvedPath)
                        } label: {
                            Label("Open Terminal Here", systemImage: "terminal")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(resolvedPath.isEmpty)
                    }
                }
            }
        }
        // fetch() runs once when the user navigates into this directory.
        // Since this view is only created via navigationDestination (never at rest),
        // .onAppear fires exactly once per user-initiated navigation tap.
        .onAppear { fetch() }
    }

    private var sortedEntries: [FileEntry] {
        let dirs  = entries.filter(\.isDirectory).sorted { $0.name < $1.name }
        let files = entries.filter { !$0.isDirectory }.sorted { $0.name < $1.name }
        return dirs + files
    }

    private func fetch() {
        if relayManager.isConnected {
            fetchViaRelay()
        } else {
            fetchViaHTTP()
        }
    }

    private func fetchViaRelay() {
        isLoading = true
        errorMessage = nil
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        Task {
            do {
                let (_, data) = try await relayManager.request(method: "GET", path: "/files?path=\(encodedPath)")
                let response = try JSONDecoder().decode(FilesResponse.self, from: data)
                await MainActor.run {
                    isLoading = false
                    resolvedPath = response.path
                    entries = response.entries
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func fetchViaHTTP() {
        guard let baseURL = settings.filesURL else {
            errorMessage = "Server URL not configured"
            return
        }
        isLoading = true
        errorMessage = nil

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]

        guard let url = components.url else {
            isLoading = false
            errorMessage = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error {
                    errorMessage = error.localizedDescription
                    return
                }
                guard let data else {
                    errorMessage = "No data received"
                    return
                }
                do {
                    let response = try JSONDecoder().decode(FilesResponse.self, from: data)
                    resolvedPath = response.path
                    entries = response.entries
                } catch {
                    let raw = String(data: data, encoding: .utf8)
                        .map { $0.count > 400 ? String($0.prefix(400)) + "…" : $0 }
                        ?? "<binary \(data.count) bytes>"
                    errorMessage = "Decode failed: \(error.localizedDescription)\n\nServer sent:\n\(raw)"
                }
            }
        }.resume()
    }

    private func fileIcon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "java": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "7z": return "archivebox"
        default: return "doc"
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        let mb = kb / 1024
        if mb < 1 { return String(format: "%.1f KB", kb) }
        let gb = mb / 1024
        if gb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", gb)
    }
}
