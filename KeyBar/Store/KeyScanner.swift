import Foundation

/// Where a found key was: a project's .env, a shell startup file, Claude
/// Code's MCP settings, or a tool's credentials file
struct KeySource: Hashable, Sendable {
    enum Kind: String, Sendable {
        case envFile, shellProfile, claudeCode, aws, npm
    }

    var kind: Kind
    var path: String
    /// For a project file, its folder's name
    var project: String?

    /// MadRobot/.env, ~/.zshrc
    var label: String {
        let file = (path as NSString).lastPathComponent
        if let project { return "\(project)/\(file)" }
        return BridgePolicy.tidy(path)
    }

    /// Whether KeyBar can swap the file's values for keybar: references
    var canHoldReferences: Bool { kind == .envFile }
}

/// One NAME=value found on this Mac
struct FoundKey: Hashable, Sendable {
    var name: String
    var value: String
    var source: KeySource
}

/// Looks for keys in the places they usually end up: .env files in project
/// folders, `export` lines in shell startup files, the env of MCP servers in
/// Claude Code's settings, and AWS and npm credentials. Only reads; nothing
/// it finds leaves the Mac.
struct KeyScanner: Sendable {
    struct Places: Sendable {
        var folders: [URL] = []
        var shellProfiles = true
        var claudeCode = true
        var toolCredentials = true
    }

    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var places: Places
    /// How deep into a project folder to look
    var maxDepth = 6
    /// Files bigger than this aren't env files
    static let maxFileSize = 256 * 1024

    /// Folders never worth going into: dependencies, builds, caches
    static let skippedFolders: Set<String> = [
        "node_modules", "bower_components", "vendor", "Pods", "Carthage", "DerivedData", "build", "dist", "out",
        "target", "Library", "venv", "env", "site-packages", "__pycache__", "coverage", "tmp", "Temp", "Caches",
        // Unity, Unreal and .NET build output
        "Logs", "obj", "Intermediate", "Saved", "Binaries", "DerivedDataCache",
    ]

    /// Bundles that look like folders
    static let skippedExtensions: Set<String> = [
        "app", "xcodeproj", "xcworkspace", "xcassets", "bundle", "framework", "photoslibrary", "playground",
    ]

    /// The shell startup files read for `export NAME=value` lines
    static let shellProfiles = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"]

    func scan() -> [FoundKey] {
        var found: [FoundKey] = []
        var seenFiles = Set<String>()
        for folder in places.folders {
            let root = folder.resolvingSymlinksInPath()
            for file in projectFiles(in: root) where seenFiles.insert(file.path).inserted {
                found += read(projectFile: file, root: root)
            }
        }
        if places.shellProfiles {
            for name in Self.shellProfiles {
                let url = home.appendingPathComponent(name)
                guard let text = Self.text(at: url) else { continue }
                let source = KeySource(kind: .shellProfile, path: url.path)
                found += EnvFile.parse(text).map { FoundKey(name: $0.name, value: $0.value, source: source) }
            }
        }
        if places.claudeCode {
            found += claudeCodeKeys()
        }
        if places.toolCredentials {
            found += awsKeys() + npmKeys()
        }
        return found.filter { Self.looksSecret(name: $0.name, value: $0.value) }
    }

    // MARK: - Project folders

    /// .env files (and .mcp.json files) inside a folder, not going into
    /// dependencies, builds, hidden folders or bundles
    func projectFiles(in folder: URL) -> [URL] {
        let root = folder.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                          options: [], errorHandler: { _, _ in true }) else { return [] }
        var files: [URL] = []
        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if walker.level >= maxDepth || name.hasPrefix(".") || Self.skippedFolders.contains(name)
                    || Self.skippedExtensions.contains(url.pathExtension.lowercased()) {
                    walker.skipDescendants()
                }
                continue
            }
            guard Self.isEnvFile(name) || name == ".mcp.json" else { continue }
            if let size = values?.fileSize, size > Self.maxFileSize { continue }
            files.append(url)
        }
        return files
    }

    /// .env, .env.local, .env.production, production.env, .envrc. Not the
    /// example and template files, which hold placeholders.
    static func isEnvFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env") || lower == ".envrc" else { return false }
        return !["example", "sample", "template", "dist", "schema"].contains { lower.contains($0) }
    }

    private func read(projectFile url: URL, root: URL) -> [FoundKey] {
        guard let text = Self.text(at: url) else { return [] }
        let source = KeySource(kind: .envFile, path: url.path, project: project(of: url, root: root))
        if url.lastPathComponent == ".mcp.json" {
            return Self.mcpServerKeys(in: text).map { FoundKey(name: $0.name, value: $0.value, source: source) }
        }
        return EnvFile.parse(text).map { FoundKey(name: $0.name, value: $0.value, source: source) }
    }

    /// The project a file belongs to: the folder it's in, or for a file in a
    /// project's subfolder (MadRobot/web/.env), the top folder under the root
    private func project(of file: URL, root: URL) -> String {
        // The walker can hand back /var/… for a root of /private/var/…
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        let rootPath = root.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard folder.path.hasPrefix(rootPrefix) else { return folder.lastPathComponent }
        let relative = folder.path.dropFirst(rootPrefix.count).split(separator: "/")
        guard let top = relative.first else { return folder.lastPathComponent }
        return relative.count == 1 ? String(top) : "\(top)/\(relative.dropFirst().joined(separator: "/"))"
    }

    // MARK: - Claude Code

    /// The env of MCP servers in ~/.claude.json (for you, and per project)
    /// and the env block of ~/.claude/settings.json
    private func claudeCodeKeys() -> [FoundKey] {
        var found: [FoundKey] = []
        let config = home.appendingPathComponent(".claude.json")
        if let text = Self.text(at: config, limit: 64 * 1024 * 1024) {
            let source = KeySource(kind: .claudeCode, path: config.path)
            found += Self.mcpServerKeys(in: text).map { FoundKey(name: $0.name, value: $0.value, source: source) }
        }
        let settings = home.appendingPathComponent(".claude/settings.json")
        if let text = Self.text(at: settings),
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let env = json["env"] as? [String: Any] {
            let source = KeySource(kind: .claudeCode, path: settings.path)
            for (name, value) in env {
                if let value = value as? String { found.append(FoundKey(name: name, value: value, source: source)) }
            }
        }
        return found
    }

    /// Every `env` of every MCP server in a Claude Code config, at the top
    /// level and under `projects`
    static func mcpServerKeys(in text: String) -> [EnvFile.Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        var entries: [EnvFile.Entry] = []
        func collect(_ servers: Any?) {
            guard let servers = servers as? [String: Any] else { return }
            for case let server as [String: Any] in servers.values {
                guard let env = server["env"] as? [String: Any] else { continue }
                for (name, value) in env {
                    if let value = value as? String, SecretName.isValid(name) {
                        entries.append(EnvFile.Entry(name: name, value: value))
                    }
                }
            }
        }
        collect(json["mcpServers"])
        if let projects = json["projects"] as? [String: Any] {
            for case let project as [String: Any] in projects.values { collect(project["mcpServers"]) }
        }
        return entries
    }

    // MARK: - Tool credentials

    /// ~/.aws/credentials: each profile's access key pair, as the variables
    /// the AWS tools read (WORK_AWS_… for a profile other than default)
    private func awsKeys() -> [FoundKey] {
        let url = home.appendingPathComponent(".aws/credentials")
        guard let text = Self.text(at: url) else { return [] }
        let source = KeySource(kind: .aws, path: url.path)
        return Self.awsEntries(in: text).map { FoundKey(name: $0.name, value: $0.value, source: source) }
    }

    static func awsEntries(in text: String) -> [EnvFile.Entry] {
        let variables = ["aws_access_key_id": "AWS_ACCESS_KEY_ID", "aws_secret_access_key": "AWS_SECRET_ACCESS_KEY"]
        var profile = "default"
        var entries: [EnvFile.Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                profile = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let variable = variables[parts[0].lowercased()] else { continue }
            let prefix = profile == "default" ? "" : SecretName.normalized(profile) + "_"
            entries.append(EnvFile.Entry(name: prefix + variable, value: parts[1]))
        }
        return entries
    }

    /// ~/.npmrc: registry tokens (NPM_TOKEN for the npm registry itself)
    private func npmKeys() -> [FoundKey] {
        let url = home.appendingPathComponent(".npmrc")
        guard let text = Self.text(at: url) else { return [] }
        let source = KeySource(kind: .npm, path: url.path)
        return Self.npmEntries(in: text).map { FoundKey(name: $0.name, value: $0.value, source: source) }
    }

    static func npmEntries(in text: String) -> [EnvFile.Entry] {
        var entries: [EnvFile.Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//"), let marker = trimmed.range(of: ":_authToken=") else { continue }
            let host = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<marker.lowerBound]
                .split(separator: "/").first.map(String.init) ?? ""
            let value = String(trimmed[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            let name = host == "registry.npmjs.org" ? "NPM_TOKEN" : SecretName.normalized(host) + "_NPM_TOKEN"
            entries.append(EnvFile.Entry(name: name, value: value))
        }
        return entries
    }

    // MARK: - Is it a key?

    /// Kinds of names that hold a secret. IDs, URLs, regions, usernames and
    /// publishable keys don't, unless the value says otherwise.
    private static let secretKinds: Set<String> = [
        "Secret access key", "Private key", "Signing secret", "Signing key", "Webhook secret", "Webhook URL",
        "Client secret", "App secret", "App key", "Secret key", "Master key", "Admin key", "Service role key",
        "Encryption key", "Licence key", "API key", "API token", "API secret", "Access token", "Refresh token",
        "Auth token", "Bot token", "Bearer token", "Session token", "OAuth token", "Personal access token",
        "Token", "Secret", "Password", "Passphrase", "Connection string", "DSN", "Key",
    ]

    /// Values that are clearly not a real key
    private static let placeholders = [
        "your_", "your-", "yourkey", "<", "xxxx", "changeme", "change_me", "placeholder", "example", "replace",
        "todo", "insert", "dummy", "fake", "redacted", "...", "****",
    ]

    /// Names whose values end up in a public web page anyway
    private static let publicPrefixes = ["NEXT_PUBLIC_", "EXPO_PUBLIC_", "PUBLIC_", "GATSBY_"]

    static func looksSecret(name: String, value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SecretName.isValid(name), value.count >= 8, EnvFile.reference(in: value) == nil else { return false }
        // Pointing at another variable or a command, not holding a value
        guard !value.contains("$"), !value.contains("`") else { return false }
        let lower = value.lowercased()
        if placeholders.contains(where: lower.contains) { return false }
        if publicPrefixes.contains(where: name.uppercased().hasPrefix) { return false }
        if KeyShape.suggestedName(for: value) != nil { return true }
        // postgres://user:password@host
        if hasPassword(value) { return true }
        guard let kind = CredentialKind.matched(name), secretKinds.contains(kind) else { return false }
        // A connection string needs a password in it (checked above), a DSN
        // its key before the @, a webhook to be a URL; a key mustn't be a
        // word, a number or a path
        switch kind {
        case "Connection string": return false
        case "DSN": return value.contains("://") && value.contains("@")
        case "Webhook URL": return value.contains("://")
        default: break
        }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix("./") { return false }
        if ["true", "false", "null", "none"].contains(lower) || Double(value) != nil { return false }
        return true
    }

    /// A URL with a password in it
    static func hasPassword(_ value: String) -> Bool {
        guard let scheme = value.range(of: "://"), let at = value.range(of: "@", range: scheme.upperBound..<value.endIndex) else { return false }
        let credentials = value[scheme.upperBound..<at.lowerBound]
        guard let colon = credentials.firstIndex(of: ":") else { return false }
        return !credentials[credentials.index(after: colon)...].isEmpty
    }

    // MARK: - Files

    static func text(at url: URL, limit: Int = maxFileSize) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
