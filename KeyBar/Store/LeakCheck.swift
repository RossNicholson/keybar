import Foundation

/// What to look for to spot a key in text: the value itself, or for a file
/// key the long secret-looking parts of it. Nothing for identifiers (account
/// IDs, publishable keys), which aren't secret and turn up everywhere, or
/// values too short to tell apart from ordinary text.
enum Needles {
    static let minLength = 12

    static func of(_ record: SecretRecord, value: String) -> [String] {
        if CredentialKind.isIdentifier(record.name) { return [] }
        if record.isFile { return KeyFiles.secretParts(of: value).filter { $0.count >= minLength } }
        return value.count >= minLength ? [value] : []
    }

    /// Every stored key's needles, archived ones too. Never shows a Keychain
    /// dialog: a key macOS would ask about is skipped.
    @MainActor
    static func all(in store: SecretStore) -> [(name: String, needles: [String])] {
        store.records.compactMap { record in
            guard let value = store.quietValue(record.name) else { return nil }
            let needles = of(record, value: value)
            return needles.isEmpty ? nil : (record.name, needles)
        }
    }
}

extension CredentialKind {
    /// Names for things that identify rather than unlock: not secret
    static func isIdentifier(_ name: String) -> Bool {
        let kind = of(name)
        return kind.hasSuffix(" ID") || ["Account SID", "Publishable key", "Public key", "Project ref"].contains(kind)
    }
}

/// A stored key found somewhere it shouldn't be
struct Leak: Identifiable, Hashable, Sendable {
    enum Place: String, Sendable, CaseIterable {
        case claudeCode, codex, gemini, cursor, windsurf, claudeDesktop, shellHistory, gitHistory

        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .gemini: return "Gemini CLI"
            case .cursor: return "Cursor"
            case .windsurf: return "Windsurf"
            case .claudeDesktop: return "Claude Desktop"
            case .shellHistory: return "Shell history"
            case .gitHistory: return "Git history"
            }
        }

        /// Who the app sends chats to
        var aiService: String {
            switch self {
            case .claudeCode, .claudeDesktop: return "Anthropic"
            case .codex: return "OpenAI"
            case .gemini: return "Google"
            case .cursor: return "Cursor and the AI service it used"
            case .windsurf: return "Windsurf and the AI service it used"
            case .shellHistory, .gitHistory: return "no one"
            }
        }
    }

    var name: String
    var place: Place
    /// The file, or for git history the repository
    var path: String
    /// For git history: the commit and file it was added in
    var detail: String?
    var count: Int

    var id: String { "\(name)|\(path)|\(detail ?? "")" }

    /// A settings file rather than chats or history
    var isSettings: Bool {
        let file = (path as NSString).lastPathComponent.lowercased()
        return [".claude.json", "claude_desktop_config.json", "settings.json", "settings.local.json", "config.toml",
                "mcp.json", "mcp_config.json", "config.json"].contains(file)
    }

    /// Who could see this copy, in plain words
    var exposure: String {
        switch place {
        case .gitHistory:
            return "It's in this repo's history, so anyone with a copy of the repo has it. If it was pushed (to GitHub, say), so does anyone who can see it there, even though the file has changed since."
        case .shellHistory:
            return "It's in your shell's history. That isn't sent anywhere, but any app you run can read it, and it's in your backups."
        default:
            if isSettings {
                return "It's written out in \(place.title)'s settings. That stays on this Mac, but any app you run can read it, and it's in your backups."
            }
            return "It's in \(place.title)'s chats or prompt history, so it was most likely sent to \(place.aiService) as part of a conversation. On this Mac, any app you run can read it, and it's in your backups."
        }
    }

    /// Whether KeyBar can hide it by rewriting the file: text logs only, not
    /// databases or git history
    var canHide: Bool {
        guard place != .gitHistory else { return false }
        return !["vscdb", "sqlite", "db", "ldb", "log"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// Looks through the places keys leak to: AI tools' transcripts and settings,
/// shell history, and optionally git history. Only reads (hiding is
/// separate), and only on this Mac.
struct LeakScanner: Sendable {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Where to look for git repositories, when git history is wanted
    var gitFolders: [URL] = []
    var includeGit = false

    /// Files bigger than this are skipped
    static let maxFileSize = 1024 * 1024 * 1024
    /// The longest one repository's history is read for
    static let gitTimeout: TimeInterval = 90
    /// Folders in the AI tools' folders that hold their own code, not your text
    static let skippedFolders: Set<String> = ["node_modules", "local", "bin", "extensions", "CachedData", "Cache",
                                               "Code Cache", "GPUCache", "CachedExtensionVSIXs", "logs"]

    /// Where each AI tool keeps transcripts and settings
    func aiPlaces() -> [(Leak.Place, URL)] {
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            (.claudeCode, home.appendingPathComponent(".claude.json")),
            (.claudeCode, home.appendingPathComponent(".claude")),
            (.codex, home.appendingPathComponent(".codex")),
            (.gemini, home.appendingPathComponent(".gemini")),
            (.cursor, home.appendingPathComponent(".cursor")),
            (.cursor, support.appendingPathComponent("Cursor/User/globalStorage")),
            (.cursor, support.appendingPathComponent("Cursor/User/workspaceStorage")),
            (.windsurf, home.appendingPathComponent(".codeium")),
            (.windsurf, support.appendingPathComponent("Windsurf/User/globalStorage")),
            (.windsurf, support.appendingPathComponent("Windsurf/User/workspaceStorage")),
            (.claudeDesktop, support.appendingPathComponent("Claude/claude_desktop_config.json")),
        ]
    }

    func historyFiles() -> [URL] {
        let names = [".zsh_history", ".bash_history", ".sh_history", ".local/share/fish/fish_history", ".python_history",
                     ".node_repl_history", ".psql_history", ".mysql_history", ".sqlite_history", ".lesshst", ".viminfo"]
        var files = names.map { home.appendingPathComponent($0) }
        let sessions = home.appendingPathComponent(".zsh_sessions")
        if let more = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) {
            files += more.filter { $0.pathExtension == "history" || $0.pathExtension == "historynew" }
        }
        return files
    }

    func scan(_ watched: [(name: String, needles: [String])], progress: @Sendable (String) -> Void = { _ in }) -> [Leak] {
        guard !watched.isEmpty else { return [] }
        var leaks: [Leak] = []
        for (place, url) in aiPlaces() {
            progress(place.title)
            for file in files(under: url) {
                leaks += search(file, place: place, watched)
            }
        }
        progress(Leak.Place.shellHistory.title)
        for file in historyFiles() {
            leaks += search(file, place: .shellHistory, watched)
        }
        if includeGit {
            for repo in repositories() {
                progress("\(Leak.Place.gitHistory.title): \(repo.lastPathComponent)")
                leaks += searchGit(repo, watched)
            }
        }
        return leaks
    }

    // MARK: - Files

    /// `url` if it's a file, or the files in it if it's a folder
    func files(under url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                                                          options: [.skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if Self.skippedFolders.contains(file.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= Self.maxFileSize else { continue }
            found.append(file)
        }
        return found
    }

    /// How many times each key is in one file
    func search(_ file: URL, place: Leak.Place, _ watched: [(name: String, needles: [String])]) -> [Leak] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let longest = watched.flatMap(\.needles).map(\.utf8.count).max() ?? 0
        var counts: [String: Int] = [:]
        var carry = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty else { break }
            var window = carry
            window.append(chunk)
            for item in watched {
                // Only matches that end past the overlap, so none counts twice
                let found = item.needles.reduce(0) { $0 + Self.occurrences(of: $1, in: window, endingAfter: carry.count) }
                if found > 0 { counts[item.name, default: 0] += found }
            }
            carry = window.suffix(max(longest - 1, 0))
        }
        return counts.map { Leak(name: $0.key, place: place, path: file.path, count: $0.value) }
    }

    /// Counts `needle` in `data`, only where a match ends after `offset` bytes
    static func occurrences(of needle: String, in data: Data, endingAfter offset: Int = 0) -> Int {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty, data.count >= pattern.count else { return 0 }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var count = 0
            var start = 0
            while start + pattern.count <= buffer.count {
                guard let hit = memmem(base + start, buffer.count - start, pattern, pattern.count) else { break }
                let at = base.distance(to: UnsafeRawPointer(hit))
                if at + pattern.count > offset { count += 1 }
                start = at + pattern.count
            }
            return count
        }
    }

    // MARK: - Git

    /// Git repositories in the chosen folders, a few levels down
    func repositories() -> [URL] {
        var repos: [URL] = []
        func look(_ folder: URL, depth: Int) {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                repos.append(folder)
                return
            }
            guard depth < 4, let children = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            for child in children where !KeyScanner.skippedFolders.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true && values?.isSymbolicLink != true { look(child, depth: depth + 1) }
            }
        }
        for folder in gitFolders { look(folder, depth: 0) }
        return repos
    }

    /// Lines added anywhere in a repository's history that have a key: the
    /// first commit seen (newest) and how many times in all
    func searchGit(_ repo: URL, _ watched: [(name: String, needles: [String])]) -> [Leak] {
        guard let git = GitTool.path else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo.path, "log", "--all", "-p", "--no-color", "--no-ext-diff", "--no-textconv",
                             "--format=@@keybar %h %as"]
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "GIT_PAGER": "cat", "HOME": home.path,
                               "GIT_CONFIG_NOSYSTEM": "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let timer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.gitTimeout, execute: timer)
        defer { timer.cancel() }

        var commit = ""
        var file = ""
        var found: [String: (detail: String, count: Int)] = [:]
        let marker = Array("@@keybar ".utf8)
        let added = Array("+++ b/".utf8)
        var pending = Data()
        let reader = pipe.fileHandleForReading
        func handle(_ line: Data.SubSequence) {
            if line.starts(with: marker) {
                commit = String(decoding: line.dropFirst(marker.count), as: UTF8.self)
            } else if line.starts(with: added) {
                file = String(decoding: line.dropFirst(added.count), as: UTF8.self)
            } else if line.first == UInt8(ascii: "+") {
                let text = Data(line)
                for item in watched where item.needles.contains(where: { Self.occurrences(of: $0, in: text) > 0 }) {
                    let detail = found[item.name]?.detail ?? "commit \(commit) · \(file)"
                    found[item.name] = (detail, (found[item.name]?.count ?? 0) + 1)
                }
            }
        }
        while true {
            let data = reader.availableData
            if data.isEmpty { break }
            pending.append(data)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                handle(pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { handle(pending[...]) }
        process.waitUntilExit()
        return found.map { Leak(name: $0.key, place: .gitHistory, path: repo.path, detail: $0.value.detail, count: $0.value.count) }
    }

    // MARK: - Hiding

    enum HideProblem: LocalizedError {
        case inUse, unreadable, unchanged

        var errorDescription: String? {
            switch self {
            case .inUse: return "That file changed in the last minute, so something's using it. Close that session or terminal and try again."
            case .unreadable: return "KeyBar couldn't read that file."
            case .unchanged: return "The key isn't in that file any more."
            }
        }
    }

    /// Replaces every copy of the needles in a file with [REDACTED]. Returns
    /// how many it replaced.
    static func hide(_ needles: [String], in path: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let modified, Date().timeIntervalSince(modified) < 60 { throw HideProblem.inUse }
        guard var data = try? Data(contentsOf: url) else { throw HideProblem.unreadable }
        var replaced = 0
        let redacted = Data("[REDACTED]".utf8)
        for needle in needles.sorted(by: { $0.count > $1.count }) {
            let pattern = Data(needle.utf8)
            var output = Data()
            var start = data.startIndex
            while let range = data.range(of: pattern, in: start..<data.endIndex) {
                output.append(data[start..<range.lowerBound])
                output.append(redacted)
                start = range.upperBound
                replaced += 1
            }
            output.append(data[start...])
            data = output
        }
        guard replaced > 0 else { throw HideProblem.unchanged }
        try ClaudeConnector.replaceFile(url, with: data)
        return replaced
    }
}
