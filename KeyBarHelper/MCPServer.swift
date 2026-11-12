import Foundation

/// A small MCP server over stdio: newline-delimited JSON-RPC 2.0. It offers
/// two tools, one that lists the stored keys' names and one that runs a
/// command with some of them set as environment variables. Tool calls run in
/// the background so a long command doesn't hold up pings or cancelling it.
final class MCPServer: @unchecked Sendable {
    let version: String
    private let out = FileHandle.standardOutput
    private let lock = NSLock()
    /// Who started us, from `initialize`, for KeyBar's activity log
    private var client = "Claude Code"
    /// Commands running for tool calls, by request ID, so they can be cancelled
    private var running: [String: CommandRunner.Handle] = [:]
    private let calls = DispatchGroup()

    init(version: String) {
        self.version = version
    }

    static let instructions = """
    KeyBar keeps the user's API keys and tokens (Claude, Cloudflare, GitHub and others) in the macOS Keychain. \
    Before asking the user to paste a key, or reading one from a .env file, call list_secrets to see what's stored. \
    To run a command that needs a key, call run_with_secrets with the key names: each one is set as an environment \
    variable of that name, so refer to it as "$NAME" in the command. Never put a key's value in a command, and never \
    try to print, echo or save a key. Output comes back with any copy of a key replaced by [REDACTED]. \
    Don't run `keybar run` yourself: it's for the user's own terminal and doesn't hide keys. A .env line like \
    NAME=keybar:STORED_NAME means the key is in KeyBar as STORED_NAME.
    """

    func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(message)
        }
        // stdin closed: let calls in progress finish and send their replies
        calls.wait()
    }

    // MARK: - Messages

    func handle(_ message: [String: Any]) {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) need no reply
        guard let id, !(id is NSNull) else {
            if method == "notifications/cancelled", let requestID = params["requestId"] {
                cancel(String(describing: requestID))
            }
            return
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            if let name = (params["clientInfo"] as? [String: Any])?["name"] as? String, !name.isEmpty {
                let label = name.lowercased().contains("claude") ? "Claude Code" : String(name.prefix(40))
                lock.withLock { client = label }
            }
            reply(id, [
                "protocolVersion": requested ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "keybar", "title": "KeyBar", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let call = Unchecked((id: id, arguments: params["arguments"] as? [String: Any] ?? [:]))
            calls.enter()
            DispatchQueue.global().async { [self] in
                let key = String(describing: call.value.id)
                reply(call.value.id, callTool(name, call.value.arguments, requestID: key))
                calls.leave()
            }
        case "resources/list":
            reply(id, ["resources": []])
        case "prompts/list":
            reply(id, ["prompts": []])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        lock.withLock { out.write(data) }
    }

    private var clientName: String { lock.withLock { client } }

    /// Stops the command a cancelled tool call is running
    private func cancel(_ requestID: String) {
        lock.withLock { running[requestID] }?.stop()
    }

    // MARK: - Tools

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "list_secrets",
            "title": "List stored keys",
            "description": """
            Lists the API keys and tokens stored in KeyBar: each one's name (also the environment variable it's \
            set as), the service it's for and what kind of credential it is. Values are never shown. Call this \
            before asking the user for a key.
            """,
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "run_with_secrets",
            "title": "Run a command with stored keys",
            "description": """
            Runs a shell command with the named KeyBar keys set as environment variables, e.g. secretNames \
            ["CLOUDFLARE_API_TOKEN"] and command "curl -H \\"Authorization: Bearer $CLOUDFLARE_API_TOKEN\\" \
            https://api.cloudflare.com/client/v4/user/tokens/verify". Refer to keys only as "$NAME"; a command \
            containing a key's actual value is refused. Returns the exit code, stdout and stderr, with any copy \
            of a key replaced by [REDACTED]. Runs in the project folder unless cwd is given. Keys may be limited \
            to certain project folders.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to run (zsh)."],
                    "secretNames": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Names of the keys to set as environment variables.",
                    ],
                    "cwd": ["type": "string", "description": "Folder to run in. Defaults to the project folder."],
                    "timeoutSeconds": [
                        "type": "number",
                        "description": "Stop the command after this many seconds (default 120, at most 600).",
                    ],
                ],
                "required": ["command", "secretNames"],
                "additionalProperties": false,
            ],
            "annotations": ["destructiveHint": true, "openWorldHint": true],
        ],
    ]

    func callTool(_ name: String, _ arguments: [String: Any], requestID: String = UUID().uuidString) -> [String: Any] {
        switch name {
        case "list_secrets":
            return listSecrets()
        case "run_with_secrets":
            return runWithSecrets(arguments, requestID: requestID)
        default:
            return toolError("There's no tool called \(name).")
        }
    }

    private func toolText(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func toolError(_ text: String) -> [String: Any] { toolText(text, isError: true) }

    /// The folder Claude Code started us in
    private let projectFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .resolvingSymlinksInPath().standardizedFileURL.path

    private func listSecrets() -> [String: Any] {
        let reply: BridgeReply
        do {
            reply = try AppLink.send(BridgeRequest(action: .list, cwd: projectFolder, projectFolder: projectFolder,
                                                   client: clientName))
        } catch {
            return toolError("\(error)")
        }
        guard reply.ok, let secrets = reply.secrets else { return toolError(reply.error ?? "KeyBar refused.") }
        guard !secrets.isEmpty else {
            return toolText("KeyBar has no keys stored yet. Ask the user to add the key in KeyBar (menu bar → +) rather than pasting it here.")
        }
        var lines = ["Keys stored in KeyBar (use them with run_with_secrets, as \"$NAME\"):"]
        for secret in secrets.sorted(by: { $0.name < $1.name }) {
            var line = "- \(secret.name): \(secret.service.map { "\($0) " } ?? "")\(secret.kind.lowercased())"
            if let group = secret.group { line += " [\(group)]" }
            if let note = secret.note, !note.isEmpty { line += " (\(note))" }
            if secret.restricted { line += secret.availableHere ? " (limited to some projects, including this one)" : " (not available in this folder)" }
            lines.append(line)
        }
        return toolText(lines.joined(separator: "\n"))
    }

    private func runWithSecrets(_ arguments: [String: Any], requestID: String) -> [String: Any] {
        guard let command = arguments["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolError("Give a command to run.")
        }
        let names = (arguments["secretNames"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !names.isEmpty else { return toolError("Name at least one key in secretNames (see list_secrets).") }
        for name in names where !SecretName.isValid(name) {
            return toolError("\"\(name)\" isn't a key name. Use the names list_secrets gives.")
        }

        var cwd = projectFolder
        if let requested = arguments["cwd"] as? String, !requested.isEmpty {
            let expanded = (requested as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : (projectFolder as NSString).appendingPathComponent(expanded)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory), isDirectory.boolValue else {
                return toolError("The folder \(requested) doesn't exist.")
            }
            cwd = absolute
        }
        cwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path

        let timeout = min(600, max(1, (arguments["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 120))

        let client = clientName
        let wanted = Set(names)
        let reply: BridgeReply
        do {
            // Long enough for the user to answer a Touch ID prompt
            reply = try AppLink.send(BridgeRequest(action: .resolve, cwd: cwd, projectFolder: projectFolder,
                                                   client: client, names: Array(wanted), command: command),
                                     timeout: Bridge.resolveTimeout)
        } catch {
            return toolError("\(error)")
        }
        guard reply.ok, let reported = reply.values else { return toolError(reply.error ?? "KeyBar refused.") }
        // Only the keys asked for: nothing else gets into the environment
        // (BASH_ENV, PATH…), whatever the reply says
        let values = reported.filter { wanted.contains($0.key) }

        let handle = CommandRunner.Handle()
        lock.withLock { running[requestID] = handle }
        let result = CommandRunner.run(command, in: cwd, extraEnvironment: values, timeout: timeout, handle: handle)
        lock.withLock { running[requestID] = nil }
        let redactor = Redactor(secrets: Array(values.values))
        let stdout = redactor.redact(result.stdout)
        let stderr = redactor.redact(result.stderr)
        let redactions = stdout.count + stderr.count

        _ = try? AppLink.send(BridgeRequest(action: .finished, cwd: cwd, client: client, runID: reply.runID,
                                            exitCode: result.exitCode, redactions: redactions,
                                            timedOut: result.timedOut), timeout: 5)

        var text = result.cancelled
            ? "Cancelled."
            : result.timedOut
            ? "Stopped after \(Int(timeout)) seconds (timed out)."
            : "Exit code: \(result.exitCode)"
        if redactions > 0 {
            text += "\nKeyBar hid \(redactions) cop\(redactions == 1 ? "y" : "ies") of a key in the output."
        }
        text += "\n\n--- stdout ---\n" + (stdout.text.isEmpty ? "(empty)" : stdout.text)
        if !stderr.text.isEmpty { text += "\n\n--- stderr ---\n" + stderr.text }
        if result.truncated { text += "\n\n(Output was cut short: it was longer than \(CommandRunner.maxOutput / 1024) KB.)" }
        return toolText(text, isError: result.timedOut || result.exitCode != 0)
    }
}

/// Reaches the KeyBar app, starting it if it isn't running
enum AppLink {
    /// Whoever's listening must be the KeyBar app, signed by our team
    nonisolated(unsafe) private static let appRequirement = CodeIdentity.requirement(identifier: Bridge.appBundleID)

    private static func isKeyBar(_ fd: Int32) -> Bool {
        CodeIdentity.peer(fd, meets: appRequirement)
    }

    static func send(_ request: BridgeRequest, timeout: TimeInterval = Bridge.replyTimeout) throws -> BridgeReply {
        do {
            return try BridgeSocket.send(request, timeout: timeout, server: isKeyBar)
        } catch BridgeError.unreachable {
            launchApp()
            // Give it a few seconds to start listening. Only "not there yet"
            // is retried: anything else would send the request twice.
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.25)
                do {
                    return try BridgeSocket.send(request, timeout: timeout, server: isKeyBar)
                } catch BridgeError.unreachable {
                    continue
                }
            }
            throw BridgeError.unreachable
        }
    }

    /// Opens the KeyBar this helper is inside, in the background
    private static func launchApp() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // …/KeyBar.app/Contents/Helpers/keybar
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = bundle.pathExtension == "app"
            ? ["-g", "-j", bundle.path, "--args", "-launchedByHelper", "YES"]
            : ["-g", "-j", "-b", Bridge.appBundleID, "--args", "-launchedByHelper", "YES"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Carries a value that isn't Sendable onto another thread that alone uses it
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
