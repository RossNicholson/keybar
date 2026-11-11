import Foundation
import Observation

/// Connects Claude Code to KeyBar: registers the `keybar` MCP server for
/// every project (user scope, in ~/.claude.json) and, if wanted, adds a short
/// note to ~/.claude/CLAUDE.md telling Claude to check KeyBar before asking
/// for a key. Disconnecting removes both.
@MainActor
@Observable
final class ClaudeConnector {
    enum Status: Equatable {
        case connected
        /// Registered, but pointing at another copy of KeyBar (it moved, say)
        case elsewhere(String)
        case disconnected
    }

    enum TestResult: Equatable {
        case passed(String)
        case failed(String)
    }

    static let serverName = "keybar"

    private(set) var status: Status = .disconnected
    private(set) var hasReminder = false
    private(set) var isWorking = false
    private(set) var lastError: String?
    private(set) var testResult: TestResult?

    private let home: URL
    private let helperPath: String

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         helperPath: String = ClaudeConnector.bundledHelperPath) {
        self.home = home
        self.helperPath = helperPath
        refresh()
    }

    nonisolated static var bundledHelperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/keybar").path
    }

    var configURL: URL { home.appendingPathComponent(".claude.json") }
    var memoryURL: URL { home.appendingPathComponent(".claude/CLAUDE.md") }

    /// What to type to connect by hand
    var manualCommand: String {
        "claude mcp add --scope user \(Self.serverName) -- \"\(helperPath)\" mcp"
    }

    var manualJSON: String {
        """
        "mcpServers": {
          "\(Self.serverName)": {
            "type": "stdio",
            "command": "\(helperPath)",
            "args": ["mcp"]
          }
        }
        """
    }

    // MARK: - Status

    func refresh() {
        hasReminder = (try? String(contentsOf: memoryURL, encoding: .utf8))?.contains(Self.reminderStart) ?? false
        guard let config = readConfig(),
              let servers = config["mcpServers"] as? [String: Any],
              let server = servers[Self.serverName] as? [String: Any] else {
            status = .disconnected
            return
        }
        let command = server["command"] as? String ?? ""
        status = command == helperPath ? .connected : .elsewhere(command)
    }

    private func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Connecting

    func connect(addReminder: Bool) async {
        isWorking = true
        lastError = nil
        testResult = nil
        defer { isWorking = false }

        // Claude Code's own command is the safest way to change its settings;
        // without it, edit ~/.claude.json directly
        if let claude = Self.findClaude() {
            _ = await Self.run(claude, ["mcp", "remove", "--scope", "user", Self.serverName])
            let added = await Self.run(claude, ["mcp", "add", "--scope", "user", Self.serverName, "--", helperPath, "mcp"])
            if added.status != 0 {
                do {
                    try writeServerEntry()
                } catch {
                    lastError = "Couldn't add KeyBar to Claude Code: \(added.output.nonEmpty ?? error.localizedDescription)"
                }
            }
        } else {
            do {
                try writeServerEntry()
            } catch {
                lastError = "Couldn't update \(configURL.path): \(error.localizedDescription)"
            }
        }
        if addReminder { setReminder(true) }
        refresh()
        if status == .connected && lastError == nil { await test() }
    }

    func disconnect() async {
        isWorking = true
        lastError = nil
        testResult = nil
        defer { isWorking = false }
        if let claude = Self.findClaude() {
            _ = await Self.run(claude, ["mcp", "remove", "--scope", "user", Self.serverName])
        }
        refresh()
        if status != .disconnected {
            do {
                try removeServerEntry()
            } catch {
                lastError = "Couldn't update \(configURL.path): \(error.localizedDescription)"
            }
        }
        setReminder(false)
        refresh()
    }

    private func writeServerEntry() throws {
        var config = readConfig() ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[Self.serverName] = ["type": "stdio", "command": helperPath, "args": ["mcp"], "env": [String: String]()]
        config["mcpServers"] = servers
        try writeConfig(config)
    }

    private func removeServerEntry() throws {
        guard var config = readConfig(), var servers = config["mcpServers"] as? [String: Any] else { return }
        servers[Self.serverName] = nil
        config["mcpServers"] = servers
        try writeConfig(config)
    }

    private func writeConfig(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes])
        let existed = FileManager.default.fileExists(atPath: configURL.path)
        try data.write(to: configURL, options: .atomic)
        if !existed {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    // MARK: - The CLAUDE.md note

    static let reminderStart = "<!-- KeyBar:start -->"
    static let reminderEnd = "<!-- KeyBar:end -->"
    static let reminder = """
    \(reminderStart)
    ## API keys (KeyBar)
    My API keys and tokens are stored in KeyBar. Before asking me to paste a key, or reading one from a .env file, \
    call the `list_secrets` tool of the `keybar` MCP server. Run commands that need a key with `run_with_secrets`, \
    referring to the key as `$NAME`. Never print, echo or save a key's value.
    \(reminderEnd)
    """

    func setReminder(_ on: Bool) {
        let fm = FileManager.default
        var text = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        // Take out any existing note first
        if let start = text.range(of: Self.reminderStart), let end = text.range(of: Self.reminderEnd, range: start.upperBound..<text.endIndex) {
            var removeEnd = end.upperBound
            if removeEnd < text.endIndex, text[removeEnd] == "\n" { removeEnd = text.index(after: removeEnd) }
            var removeStart = start.lowerBound
            if removeStart > text.startIndex, text[text.index(before: removeStart)] == "\n",
               removeStart > text.index(after: text.startIndex), text[text.index(removeStart, offsetBy: -2)] == "\n" {
                removeStart = text.index(before: removeStart)
            }
            text.removeSubrange(removeStart..<removeEnd)
        }
        if on {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            if !text.isEmpty { text += "\n" }
            text += Self.reminder + "\n"
        }
        do {
            try fm.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if text.isEmpty && !fm.fileExists(atPath: memoryURL.path) { hasReminder = false; return }
            try text.write(to: memoryURL, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn't update \(memoryURL.path): \(error.localizedDescription)"
        }
        hasReminder = on
    }

    // MARK: - Testing

    /// Starts the helper the way Claude Code does and asks it for its tools
    /// and the key list
    func test() async {
        isWorking = true
        testResult = nil
        defer { isWorking = false }
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"KeyBar test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_secrets","arguments":{}}}"#,
        ].joined(separator: "\n") + "\n"
        let result = await Self.run(helperPath, ["mcp"], input: input, timeout: 15)
        let replies = result.output.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let tools = (replies.first { ($0["id"] as? Int) == 2 }?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let call = replies.first { ($0["id"] as? Int) == 3 }?["result"] as? [String: Any]
        guard let tools, tools.count == 2 else {
            testResult = .failed("The helper didn't answer. \(result.output.nonEmpty ?? "No output.")")
            return
        }
        if call?["isError"] as? Bool == true {
            let text = ((call?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "Unknown error"
            testResult = .failed(text)
        } else {
            testResult = .passed(status == .connected
                ? "Working. Claude Code will see KeyBar's tools in new sessions."
                : "The helper works. Connect to let Claude Code use it.")
        }
    }

    // MARK: - Running things

    /// Where the `claude` command is. Apps don't get the shell's PATH, so look
    /// in the usual places.
    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct RunResult: Sendable {
        var status: Int32
        var output: String
    }

    nonisolated static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                                timeout: TimeInterval = 30) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let stdin = Pipe()
                process.standardInput = stdin
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RunResult(status: -1, output: error.localizedDescription))
                    return
                }
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                // The helper keeps going until its input ends; give it a moment to answer first
                DispatchQueue.global().asyncAfter(deadline: .now() + (input == nil ? 0 : 3)) {
                    try? stdin.fileHandleForWriting.close()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: RunResult(status: process.terminationStatus,
                                                         output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
