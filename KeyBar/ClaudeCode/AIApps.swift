import Foundation
import Observation

/// Connects AI apps other than Claude Code to KeyBar's MCP server, by adding
/// it to each app's own MCP settings file. Each app's other settings are
/// kept; a file KeyBar can't read safely (one with comments, say) is left
/// alone, and the setup is offered to copy instead.
@MainActor
@Observable
final class AIApps {
    enum App: String, CaseIterable, Identifiable, Sendable {
        case claudeDesktop, cursor, windsurf, vsCode, codex, gemini, zed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .cursor: return "Cursor"
            case .windsurf: return "Windsurf"
            case .vsCode: return "VS Code"
            case .codex: return "Codex CLI"
            case .gemini: return "Gemini CLI"
            case .zed: return "Zed"
            }
        }

        /// The settings file, relative to the home folder
        var configPath: String {
            switch self {
            case .claudeDesktop: return "Library/Application Support/Claude/claude_desktop_config.json"
            case .cursor: return ".cursor/mcp.json"
            case .windsurf: return ".codeium/windsurf/mcp_config.json"
            case .vsCode: return "Library/Application Support/Code/User/mcp.json"
            case .codex: return ".codex/config.toml"
            case .gemini: return ".gemini/settings.json"
            case .zed: return ".config/zed/settings.json"
            }
        }

        /// The JSON object servers go in, for the JSON ones
        var serversKey: String? {
            switch self {
            case .claudeDesktop, .cursor, .windsurf, .gemini: return "mcpServers"
            case .vsCode: return "servers"
            case .codex, .zed: return nil
            }
        }

        /// Zed's settings are full of comments: always set up by hand
        var isManual: Bool { self == .zed }

        var afterConnecting: String {
            switch self {
            case .claudeDesktop, .cursor, .windsurf, .zed: return "Quit and reopen \(title) to pick it up."
            case .vsCode: return "In VS Code, KeyBar's tools appear in Copilot's agent mode."
            case .codex, .gemini: return "New \(title) sessions pick it up."
            }
        }

        /// Signs it's on this Mac: apps, folders it makes, or its command
        var traces: [String] {
            switch self {
            case .claudeDesktop: return ["/Applications/Claude.app", "~/Applications/Claude.app"]
            case .cursor: return ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"]
            case .windsurf: return ["/Applications/Windsurf.app", "~/Applications/Windsurf.app", "~/.codeium/windsurf"]
            case .vsCode: return ["/Applications/Visual Studio Code.app", "~/Applications/Visual Studio Code.app",
                                  "~/Library/Application Support/Code"]
            case .codex: return ["~/.codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]
            case .gemini: return ["~/.gemini", "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]
            case .zed: return ["/Applications/Zed.app", "~/Applications/Zed.app", "~/.config/zed"]
            }
        }
    }

    enum Status: Equatable {
        case connected
        /// Set up, but pointing at another copy of KeyBar
        case elsewhere(String)
        case disconnected
    }

    static let serverName = ClaudeConnector.serverName
    static let codexStart = "# KeyBar:start"
    static let codexEnd = "# KeyBar:end"

    private(set) var statuses: [App: Status] = [:]
    private(set) var errors: [App: String] = [:]
    private(set) var connectedNote: [App: String] = [:]

    private let home: URL
    private let helperPath: String

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, helperPath: String = ClaudeConnector.bundledHelperPath) {
        self.home = home
        self.helperPath = helperPath
        refresh()
    }

    func url(_ app: App) -> URL { home.appendingPathComponent(app.configPath) }

    func isInstalled(_ app: App) -> Bool {
        app.traces.contains { trace in
            let path = trace.hasPrefix("~/") ? home.appendingPathComponent(String(trace.dropFirst(2))).path : trace
            return FileManager.default.fileExists(atPath: path)
        }
    }

    /// Installed apps first, then the rest
    var ordered: [App] {
        App.allCases.filter(isInstalled) + App.allCases.filter { !isInstalled($0) }
    }

    func status(_ app: App) -> Status { statuses[app] ?? .disconnected }

    // MARK: - Reading

    func refresh() {
        for app in App.allCases { statuses[app] = readStatus(app) }
    }

    private func readStatus(_ app: App) -> Status {
        switch app {
        case .codex:
            guard let text = try? String(contentsOf: url(app), encoding: .utf8),
                  let command = Self.codexCommand(in: text) else { return .disconnected }
            return command == helperPath ? .connected : .elsewhere(command)
        case .zed:
            guard let text = try? String(contentsOf: url(app), encoding: .utf8), text.contains(helperPath) else { return .disconnected }
            return .connected
        default:
            guard let key = app.serversKey, let json = readJSON(app),
                  let server = (json[key] as? [String: Any])?[Self.serverName] as? [String: Any] else { return .disconnected }
            let command = server["command"] as? String ?? ""
            return command == helperPath ? .connected : .elsewhere(command)
        }
    }

    private func readJSON(_ app: App) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url(app)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The command of the keybar server in a Codex config.toml
    static func codexCommand(in text: String) -> String? {
        var inTable = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inTable = trimmed == "[mcp_servers.\(serverName)]"
            } else if inTable, trimmed.hasPrefix("command"), let start = trimmed.firstIndex(of: "\""),
                      let end = trimmed.lastIndex(of: "\""), start < end {
                return String(trimmed[trimmed.index(after: start)..<end])
            }
        }
        return nil
    }

    // MARK: - Setting up by hand

    func snippet(_ app: App) -> String {
        switch app {
        case .codex:
            return codexBlock
        case .zed:
            return """
            "context_servers": {
              "\(Self.serverName)": {
                "source": "custom",
                "command": "\(helperPath)",
                "args": ["mcp"]
              }
            }
            """
        case .vsCode:
            return """
            "servers": {
              "\(Self.serverName)": {
                "type": "stdio",
                "command": "\(helperPath)",
                "args": ["mcp"]
              }
            }
            """
        default:
            return """
            "mcpServers": {
              "\(Self.serverName)": {
                "command": "\(helperPath)",
                "args": ["mcp"]
              }
            }
            """
        }
    }

    private var codexBlock: String {
        """
        \(Self.codexStart)
        [mcp_servers.\(Self.serverName)]
        command = "\(helperPath)"
        args = ["mcp"]
        \(Self.codexEnd)
        """
    }

    // MARK: - Connecting

    enum Problem: LocalizedError {
        case unreadable(String), manual, existing(String), translocated

        var errorDescription: String? {
            switch self {
            case .unreadable(let path):
                return "\(BridgePolicy.tidy(path)) has comments or isn't plain JSON, so KeyBar left it alone. Copy the setup and add it by hand."
            case .manual: return "Copy the setup and add it to the settings by hand."
            case .existing(let path):
                return "\(BridgePolicy.tidy(path)) already has a keybar server KeyBar didn't add. Remove it, or change it by hand."
            case .translocated: return ClaudeConnector.ConnectorError.translocated.localizedDescription
            }
        }
    }

    func connect(_ app: App) {
        errors[app] = nil
        connectedNote[app] = nil
        do {
            guard !helperPath.contains("/AppTranslocation/") else { throw Problem.translocated }
            try write(app, connect: true)
            connectedNote[app] = app.afterConnecting
        } catch {
            errors[app] = error.localizedDescription
        }
        statuses[app] = readStatus(app)
    }

    func disconnect(_ app: App) {
        errors[app] = nil
        connectedNote[app] = nil
        do {
            try write(app, connect: false)
        } catch {
            errors[app] = error.localizedDescription
        }
        statuses[app] = readStatus(app)
    }

    private func write(_ app: App, connect: Bool) throws {
        let url = url(app)
        let exists = FileManager.default.fileExists(atPath: url.path)
        switch app {
        case .zed:
            throw Problem.manual
        case .codex:
            var text = exists ? try String(contentsOf: url, encoding: .utf8) : ""
            text = Self.removingCodexBlock(text)
            if Self.codexCommand(in: text) != nil { throw Problem.existing(url.path) }
            if connect {
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                if !text.isEmpty { text += "\n" }
                text += codexBlock + "\n"
            }
            guard exists || connect else { return }
            try save(Data(text.utf8), to: url)
        default:
            guard let key = app.serversKey else { return }
            var json: [String: Any] = [:]
            if exists {
                guard let read = readJSON(app) else {
                    // An empty file is as good as none
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    guard String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw Problem.unreadable(url.path)
                    }
                    return try write(app, json: [:], key: key, connect: connect, to: url)
                }
                json = read
            } else if !connect {
                return
            }
            try write(app, json: json, key: key, connect: connect, to: url)
        }
    }

    private func write(_ app: App, json: [String: Any], key: String, connect: Bool, to url: URL) throws {
        var json = json
        var servers = json[key] as? [String: Any] ?? [:]
        if connect {
            var entry: [String: Any] = ["command": helperPath, "args": ["mcp"]]
            if app == .vsCode { entry["type"] = "stdio" }
            servers[Self.serverName] = entry
        } else {
            servers[Self.serverName] = nil
        }
        json[key] = servers
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try save(data, to: url)
    }

    private func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ClaudeConnector.replaceFile(url, with: data)
    }

    /// The text without KeyBar's marked block
    static func removingCodexBlock(_ text: String) -> String {
        guard let start = text.range(of: codexStart),
              let end = text.range(of: codexEnd, range: start.upperBound..<text.endIndex) else { return text }
        var removeEnd = end.upperBound
        if removeEnd < text.endIndex, text[removeEnd] == "\n" { removeEnd = text.index(after: removeEnd) }
        var result = text
        result.removeSubrange(start.lowerBound..<removeEnd)
        // The blank line KeyBar added before it
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }
}
