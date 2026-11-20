import Foundation

/// A small MCP server over stdio: newline-delimited JSON-RPC 2.0. Its tools
/// (see MCPCatalog) list the stored keys' names, run a command with some of
/// them set as environment variables, fill a website password into a login
/// page, ask the user for a key and send one to GitHub or Cloudflare. Tool
/// calls run in the background so a long command doesn't hold up pings or
/// cancelling it.
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
                let label = Bridge.label(forClient: name)
                lock.withLock { client = label }
            }
            reply(id, [
                "protocolVersion": requested ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "keybar", "title": "KeyBar", "version": version],
                "instructions": MCPCatalog.instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": MCPCatalog.tools])
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

    func callTool(_ name: String, _ arguments: [String: Any], requestID: String = UUID().uuidString) -> [String: Any] {
        switch name {
        case "list_secrets":
            return listSecrets()
        case "run_with_secrets":
            return runWithSecrets(arguments, requestID: requestID)
        case "fill_password":
            return fillPassword(arguments)
        case "request_secret":
            return requestSecret(arguments)
        case "send_secret":
            return sendSecret(arguments)
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
        return toolText(SecretListing.text(secrets, message: reply.message))
    }

    private func requestSecret(_ arguments: [String: Any]) -> [String: Any] {
        let typeName = (arguments["type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard typeName.isEmpty || SecretType(rawValue: typeName) != nil else {
            return toolError("type must be apiKey or password.")
        }
        let isPassword = typeName == SecretType.password.rawValue
        let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !isPassword || !name.isEmpty {
            guard SecretName.isValid(name) else {
                return toolError("\"\(name)\" can't be a key name: letters, numbers and underscores, starting with a letter.")
            }
        }
        var website: String?
        if isPassword {
            do {
                website = try LoginSite.normalise(arguments["website"] as? String ?? "")
            } catch {
                return toolError("Give the website the password is for. \(error.localizedDescription)")
            }
        }
        let reason = String((arguments["reason"] as? String ?? "").prefix(300))
        let username = (arguments["username"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        let reply: BridgeReply
        do {
            reply = try AppLink.send(BridgeRequest(action: .request, cwd: projectFolder, projectFolder: projectFolder,
                                                   client: clientName, names: name.isEmpty ? [] : [name], reason: reason,
                                                   site: website, secretType: isPassword ? .password : nil,
                                                   username: isPassword ? username : nil),
                                     timeout: Bridge.requestTimeout + 10)
        } catch {
            return toolError("\(error)")
        }
        guard reply.ok else { return toolError(reply.error ?? "KeyBar refused.") }
        return toolText(reply.message ?? (isPassword ? "The password is in KeyBar now. Use it with fill_password."
                                                     : "\(name) is in KeyBar now. Use it with run_with_secrets."))
    }

    /// Asks the app to fill a password into the login page open in a
    /// browser. The app does it all; only what happened comes back.
    private func fillPassword(_ arguments: [String: Any]) -> [String: Any] {
        let name = (arguments["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard SecretName.isValid(name) else { return toolError("\"\(name)\" isn't a password's name. Use the names list_secrets gives.") }
        var site: String?
        if let hint = (arguments["site"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            do {
                site = try LoginSite.normalise(hint)
            } catch {
                return toolError(error.localizedDescription)
            }
        }
        let reply: BridgeReply
        do {
            // Long enough for the user to answer a Touch ID prompt
            reply = try AppLink.send(BridgeRequest(action: .fill, cwd: projectFolder, projectFolder: projectFolder,
                                                   client: clientName, names: [name], site: site),
                                     timeout: Bridge.fillTimeout)
        } catch {
            return toolError("\(error)")
        }
        guard reply.ok else { return toolError(reply.error ?? "KeyBar refused.") }
        return toolText(reply.message ?? "Filled the password. Submit the form now.")
    }

    private func sendSecret(_ arguments: [String: Any]) -> [String: Any] {
        let name = arguments["secretName"] as? String ?? ""
        guard SecretName.isValid(name) else { return toolError("\"\(name)\" isn't a key name. Use the names list_secrets gives.") }
        guard let kind = Destination.Kind(rawValue: arguments["destination"] as? String ?? "") else {
            return toolError("destination must be githubActions, cloudflareWorker or cloudflarePages.")
        }
        let nameThere = (arguments["nameThere"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let destination = Destination(kind: kind, target: (arguments["target"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                      secretName: nameThere)
        if let problem = destination.problem { return toolError(problem) }
        let reply: BridgeReply
        do {
            reply = try AppLink.send(BridgeRequest(action: .send, cwd: projectFolder, projectFolder: projectFolder,
                                                   client: clientName, names: [name], destination: destination),
                                     timeout: Bridge.resolveTimeout + 120)
        } catch {
            return toolError("\(error)")
        }
        guard reply.ok else { return toolError(reply.error ?? "KeyBar refused.") }
        return toolText(reply.message ?? "Sent.")
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
        let fileNames = reply.files ?? [:]
        let keyFiles: KeyFiles
        do {
            keyFiles = try KeyFiles(values: values, files: fileNames)
        } catch {
            return toolError("Couldn't write the file keys for the command: \(error.localizedDescription)")
        }

        let handle = CommandRunner.Handle()
        lock.withLock { running[requestID] = handle }
        let environment = keyFiles.environment(values).merging(Bridge.proxyEnvironment(reply.environment)) { key, _ in key }
        let result = CommandRunner.run(command, in: cwd, extraEnvironment: environment,
                                       timeout: timeout, handle: handle)
        lock.withLock { running[requestID] = nil }
        keyFiles.remove()
        let redactor = Redactor(secrets: values.flatMap { name, value in
            value == Bridge.proxyPlaceholder ? [] : fileNames[name] == nil ? [value] : KeyFiles.secretParts(of: value) })
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

    static func send(_ request: BridgeRequest, timeout: TimeInterval = Bridge.replyTimeout,
                     relaying: Bool = true) throws -> BridgeReply {
        let reply = try sendOrLaunch(request, timeout: timeout)
        // Turned away: KeyBar was most likely updated while this helper ran,
        // so its file on disk is a new one the running copy no longer matches.
        // A fresh copy of that file passes, so hand it the request.
        guard relaying, reply.refused == true || reply.error == "KeyBar only answers its own signed helper." else { return reply }
        if let relayed = relay(request, timeout: timeout), relayed.refused != true { return relayed }
        return .failure("KeyBar was updated after this session started, and turned this older copy of its helper away. Reconnect KeyBar (/mcp in Claude Code) to fix it.")
    }

    /// Runs the request through `keybar relay`, a new process from the
    /// helper's file as it is now
    private static func relay(_ request: BridgeRequest, timeout: TimeInterval) -> BridgeReply? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              FileManager.default.isExecutableFile(atPath: executable.path),
              let input = try? JSONEncoder().encode(request) else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["relay", String(Int(timeout))]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? JSONDecoder().decode(BridgeReply.self, from: output)
    }

    /// `keybar relay SECONDS`: one request from stdin, its reply to stdout
    static func relayMain(_ arguments: [String]) -> Int32 {
        let timeout = arguments.first.flatMap(TimeInterval.init) ?? Bridge.replyTimeout
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let reply: BridgeReply
        if let request = try? JSONDecoder().decode(BridgeRequest.self, from: input) {
            do {
                reply = try send(request, timeout: timeout, relaying: false)
            } catch let error as BridgeError {
                reply = .failure(error.description)
            } catch {
                reply = .failure(error.localizedDescription)
            }
        } else {
            reply = .failure("KeyBar couldn't read the request.")
        }
        guard let data = try? JSONEncoder().encode(reply) else { return 1 }
        FileHandle.standardOutput.write(data)
        return 0
    }

    private static func sendOrLaunch(_ request: BridgeRequest, timeout: TimeInterval) throws -> BridgeReply {
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

    /// Opens the KeyBar this helper is inside, in the background. Not
    /// hidden (`open -j`): a hidden app's menu bar panel never shows.
    private static func launchApp() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // …/KeyBar.app/Contents/Helpers/keybar
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = bundle.pathExtension == "app"
            ? ["-g", bundle.path, "--args", "-launchedByHelper", "YES"]
            : ["-g", "-b", Bridge.appBundleID, "--args", "-launchedByHelper", "YES"]
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
