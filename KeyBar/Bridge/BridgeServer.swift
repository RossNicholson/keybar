import Foundation
import Security

/// Listens on ~/.keybar/keybar.sock for the `keybar` helper. Only this user
/// can open the socket, and each caller's code signature must be KeyBar's own
/// helper, signed by the same team as the app.
final class BridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (BridgeRequest) -> BridgeReply

    private let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "com.rossnicholson.KeyBar.bridge", attributes: .concurrent)
    private let requirement: SecRequirement?
    private(set) var lastError: String?

    init(path: String = Bridge.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        requirement = CodeIdentity.requirement(identifier: Bridge.helperIdentifier)
    }

    func start() throws {
        try Storage.ensureDirectory()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.io("socket") }
        guard var addr = BridgeSocket.address(path) else { close(fd); throw BridgeError.io("socket path too long") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw BridgeError.io("bind failed (\(errno))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw BridgeError.io("listen failed") }
        listener = fd

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "KeyBar bridge"
        thread.start()
    }

    func stop() {
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // the listener was closed
            }
            queue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        BridgeSocket.setTimeout(client, Bridge.replyTimeout)
        // Read the request even from a caller that'll be turned away, so it
        // gets the reason rather than a broken connection. It's only used
        // once the caller checks out.
        let line = try? BridgeSocket.readLine(client)
        let reply: BridgeReply
        if !callerIsHelper(client) {
            var refusal = BridgeReply.failure("KeyBar only answers its own signed helper.")
            refusal.refused = true
            reply = refusal
        } else if let line, let request = try? JSONDecoder().decode(BridgeRequest.self, from: line) {
            reply = handler(request)
        } else {
            reply = .failure("KeyBar couldn't read the request.")
        }
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        try? BridgeSocket.writeAll(client, data)
    }

    // MARK: - Who's calling

    private func callerIsHelper(_ client: Int32) -> Bool {
        CodeIdentity.peer(client, meets: requirement)
    }
}

/// Answers the helper's requests: the rules for which keys a command gets
@MainActor
final class BridgePolicy {
    private let store: SecretStore
    private let log: ActivityLog
    private let settings: AppSettings?
    private let proxy: KeyProxy?
    /// Runs waiting for their "finished" report: run ID → log entry
    private var running: [String: String] = [:]
    /// When the user last approved each kind of use with Touch ID, keyed by
    /// `approvalScope`
    private var approvals: [String: Date] = [:]

    /// Values shorter than this aren't looked for in commands: too likely to match by chance
    static let literalCheckLength = 8

    init(store: SecretStore, log: ActivityLog, settings: AppSettings? = nil, proxy: KeyProxy? = nil) {
        self.store = store
        self.log = log
        self.settings = settings
        self.proxy = proxy
    }

    func handle(_ request: BridgeRequest) -> BridgeReply {
        // A key added on another Mac a moment ago should work straight away
        if store.syncs && request.action != .finished { store.refresh() }
        switch request.action {
        case .list: return list(request)
        case .resolve: return resolve(request)
        case .finished: return finished(request)
        case .check: return check(request)
        // The app delegate runs these: they wait on the user, off the main thread
        case .send, .request: return .failure("KeyBar couldn't handle that request.")
        }
    }

    private func source(_ request: BridgeRequest) -> ActivityEntry.Source {
        request.client == "Claude Code" ? .claudeCode : .other
    }

    /// `showCommand` is false when the command has a key's value in it, so
    /// the value doesn't end up in the log
    private func entry(_ action: ActivityEntry.Action, _ request: BridgeRequest, detail: String?,
                       showCommand: Bool = true) -> ActivityEntry {
        let source = source(request)
        return ActivityEntry(action: action, source: source, names: (request.names ?? []).sorted(),
                             program: showCommand ? SecretName.program(in: request.command ?? "") : "a command",
                             folder: request.cwd, detail: detail, client: source == .other ? request.client : nil)
    }

    /// Whether a key may be used for this request: in both the folder the
    /// command runs in and the project Claude Code was started in
    private func isAvailable(_ record: SecretRecord, for request: BridgeRequest) -> Bool {
        record.isAvailable(in: request.cwd) && (request.projectFolder.map { record.isAvailable(in: $0) } ?? true)
    }

    // MARK: - Project lists

    /// The .keybar lists that apply: the project's and the command folder's
    func projectLists(for request: BridgeRequest) -> [ProjectKeys] {
        var lists: [ProjectKeys] = []
        for folder in [request.projectFolder, request.cwd].compactMap({ $0 }) {
            if let list = ProjectKeys.find(from: folder), !lists.contains(list) { lists.append(list) }
        }
        return lists
    }

    /// The list that leaves `name` out, if one does
    private func listWithout(_ name: String, in lists: [ProjectKeys]) -> ProjectKeys? {
        lists.first { !$0.names.contains(name) }
    }

    private func list(_ request: BridgeRequest) -> BridgeReply {
        let lists = projectLists(for: request)
        // Archived keys are filed away, and a project's .keybar narrows it
        // further: Claude doesn't see the others
        let shown = store.active.filter { listWithout($0.name, in: lists) == nil }
        let secrets = shown.map { record in
            SecretSummary(name: record.name, service: record.service?.name, kind: record.kind,
                          group: record.group, note: record.note, restricted: record.isRestricted,
                          availableHere: isAvailable(record, for: request), fileName: record.fileName,
                          expiresAt: record.expiresAt, proxyVariable: record.usesProxy ? KeyProxy.route(for: record)?.variable : nil)
        }
        let hidden = store.active.count - shown.count
        let message = lists.isEmpty || hidden == 0 ? nil
            : "\(lists.map { Self.tidy($0.path) }.joined(separator: " and ")) lists the keys this project uses, so \(hidden) other "
            + "key\(hidden == 1 ? " is" : "s are") hidden here."
        return BridgeReply(ok: true, secrets: secrets, message: message)
    }

    // MARK: - Approval

    /// The longest command shown in a Touch ID prompt
    static let promptCommandLength = 160

    /// What to ask with Touch ID before this request may go ahead, or nil if
    /// it needn't ask (it's not a use, it'll be refused anyway, approval is
    /// off, or the user approved the same use recently enough)
    func approvalPrompt(for request: BridgeRequest) -> String? {
        if request.action == .send {
            // Always asks: the key leaves the Mac
            guard let destination = request.destination, problem(with: request) == nil, destination.problem == nil else { return nil }
            let name = request.names?.first ?? ""
            return "let \(request.client) send \(name) to \(destination.label)"
                + (destination.secretName == name ? "" : " as \(destination.secretName)")
        }
        guard request.action == .resolve, let settings, problem(with: request) == nil else { return nil }
        let seconds = Self.approvalSeconds(for: request, setting: settings.approvalSeconds,
                                           keys: (request.names ?? []).compactMap { store.record($0)?.approval })
        guard seconds != 0 else { return nil }
        if seconds > 0, let approved = approvals[Self.approvalScope(request)],
           Date().timeIntervalSince(approved) < seconds {
            return nil
        }
        let names = (request.names ?? []).sorted().joined(separator: ", ")
        let command = Self.promptCommand(request.command ?? "")
        let folder = Self.tidy(request.projectFolder ?? request.cwd)
        if request.client == Bridge.terminalClient {
            return "give \(names) to a command in \(folder) (keybar run): \(command)"
        }
        return "let \(request.client) use \(names) in \(folder) to run: \(command)"
    }

    /// A command as the Touch ID prompt shows it. The whole command, not just
    /// its program: `wrangler --version; curl …` mustn't pass as "run
    /// wrangler". Runs of spaces are squeezed and invisible characters
    /// (direction overrides and the like) taken out, so nothing can be pushed
    /// out of sight or reordered; a long one shows its start and its end.
    static func promptCommand(_ command: String) -> String {
        let visible = String(String.UnicodeScalarView(command.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "\n" || scalar == "\r" { return "\n" }
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format { return " " }
            return scalar
        }))
        let lines = visible.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        let tidy = lines.joined(separator: " ⏎ ")
        guard tidy.count > promptCommandLength else { return tidy }
        let tail = promptCommandLength / 3
        return String(tidy.prefix(promptCommandLength - tail)) + " … " + String(tidy.suffix(tail))
            + " (\(tidy.count) characters)"
    }

    /// How long one approval lasts. `keybar run` always asks (15 minutes at
    /// most): its output isn't redacted, so "never" would let any program
    /// running as you print every key with it.
    /// A key set to ask every time always asks; if every key is set never to
    /// ask, it doesn't (except for `keybar run`)
    static func approvalSeconds(for request: BridgeRequest, setting: TimeInterval, keys: [KeyApproval] = []) -> TimeInterval {
        var setting = setting
        if keys.contains(.everyTime) {
            setting = -1
        } else if !keys.isEmpty && keys.count == (request.names ?? []).count && keys.allSatisfy({ $0 == .never }) {
            setting = 0
        }
        guard request.client == Bridge.terminalClient else { return setting }
        // Without its terminal an approval couldn't be kept to it: ask each time
        if request.terminal == nil { return -1 }
        guard setting == 0 else { return setting }
        return 900
    }

    /// One approval covers the same client using the same keys from the same
    /// project, not every key for everyone. For `keybar run` it covers only
    /// the same command in the same terminal: approving `npm run dev` doesn't
    /// approve `printenv`, or `npm run dev` started from anywhere else.
    static func approvalScope(_ request: BridgeRequest) -> String {
        var parts = [request.client, request.projectFolder ?? request.cwd, (request.names ?? []).sorted().joined(separator: ",")]
        if request.client == Bridge.terminalClient { parts += [request.command ?? "", request.terminal ?? ""] }
        return parts.joined(separator: "\u{1F}")
    }

    func approved(_ request: BridgeRequest) {
        approvals[Self.approvalScope(request)] = Date()
    }

    func declined(_ request: BridgeRequest) -> BridgeReply {
        let reason = "You didn't allow it in KeyBar's Touch ID prompt."
        log.add(entry(.refused, request, detail: reason))
        return .failure(reason + " Ask the user before trying again.")
    }

    // MARK: - Using keys

    private struct Problem {
        var message: String
        /// The command has a key's value in it
        var containsValue = false
    }

    /// Why a request can't have its keys, or nil if it can
    private func problem(with request: BridgeRequest) -> Problem? {
        let names = request.names ?? []
        let command = request.command ?? ""
        guard !names.isEmpty else { return Problem(message: "Name at least one key.") }
        let missing = names.filter { store.record($0) == nil }
        if !missing.isEmpty {
            let stored = store.active.map(\.name).joined(separator: ", ")
            return Problem(message: "KeyBar has no key called \(missing.joined(separator: ", ")). "
                + (stored.isEmpty ? "No keys are stored yet." : "Stored keys: \(stored)."))
        }
        let archived = names.filter { store.record($0)?.isArchived == true }
        if !archived.isEmpty {
            return Problem(message: "\(archived.joined(separator: ", ")) \(archived.count == 1 ? "is" : "are") archived in KeyBar. "
                + "Ask the user to restore \(archived.count == 1 ? "it" : "them") if needed.")
        }
        let lists = projectLists(for: request)
        for name in names {
            if let list = listWithout(name, in: lists) {
                return Problem(message: "\(name) isn't in \(Self.tidy(list.path)), the list of keys this project uses, so it can't "
                    + "be used here. Ask the user to add it to that file if the project needs it.")
            }
            guard let record = store.record(name), isAvailable(record, for: request) else {
                let folders = store.record(name)?.projectFolders.map(Self.tidy).joined(separator: ", ") ?? "some folders"
                let here = Self.tidy(request.projectFolder ?? request.cwd)
                return Problem(message: "\(name) can only be used in \(folders), not in \(here).")
            }
        }
        // A command with a key's value written into it would leave the value in
        // Claude's transcript; it should use $NAME instead. Which key it was
        // isn't said, so this can't be used to test guesses against key names.
        // Read quietly: a key macOS would ask about mustn't hold up every use
        for value in store.allValues() where value.count >= Self.literalCheckLength {
            if command.contains(value) {
                return Problem(message: "The command has the value of a stored key written into it. Refer to keys as "
                    + "\"$NAME\" and list them in secretNames instead.", containsValue: true)
            }
        }
        return nil
    }

    private func resolve(_ request: BridgeRequest) -> BridgeReply {
        let names = request.names ?? []
        if let problem = problem(with: request) {
            log.add(entry(.refused, request, detail: problem.message, showCommand: !problem.containsValue))
            return .failure(problem.message)
        }
        var values: [String: String] = [:]
        for name in names {
            do {
                values[name] = try store.value(name)
            } catch {
                let problem = "Couldn't read \(name) from the Keychain: \(error.localizedDescription)"
                log.add(entry(.refused, request, detail: problem))
                return .failure(problem)
            }
        }
        let runID = UUID().uuidString
        // Proxied keys: the command gets a placeholder and a local address,
        // and KeyBar adds the key to its requests. If that can't be set up the
        // command is refused, never given the real key instead.
        var environment: [String: String] = [:]
        for name in names {
            // What the user chose, not whether it can still be proxied
            guard let record = store.record(name), record.proxied == true else { continue }
            var problem: String?
            if let route = KeyProxy.route(for: record), let value = values[name] {
                if environment[route.variable] != nil {
                    problem = "Only one key at a time can go through KeyBar's proxy as \(route.variable). Use \(name) in a command of its own."
                } else if let base = proxy?.grant(name: name, value: value, route: route, runID: runID) {
                    environment[route.variable] = base
                    values[name] = Bridge.proxyPlaceholder
                } else {
                    problem = "KeyBar's proxy for \(name) couldn't start, so it wasn't used. Try again, or ask the user to check KeyBar."
                }
            } else {
                problem = "\(name) is set to go through KeyBar's proxy, but KeyBar can't proxy it any more, so it wasn't used. "
                    + "Ask the user to check the key in KeyBar."
            }
            if let problem {
                proxy?.revoke(runID: runID)
                log.add(entry(.refused, request, detail: problem))
                return .failure(problem)
            }
        }
        store.markUsed(names)
        running[runID] = log.add(entry(.ran, request, detail: "Running…"))
        let files = Dictionary(uniqueKeysWithValues: names.compactMap { name in store.record(name)?.fileName.map { (name, $0) } })
        return BridgeReply(ok: true, values: values, files: files.isEmpty ? nil : files, runID: runID,
                           environment: environment.isEmpty ? nil : environment)
    }

    // MARK: - Sending keys

    /// Why a send request can't go ahead, or nil if it can (once approved)
    func sendProblem(_ request: BridgeRequest) -> String? {
        guard request.names?.count == 1 else { return "Send one key at a time." }
        guard let destination = request.destination else { return "Say where to send it." }
        if let problem = destination.problem { return problem }
        return problem(with: request)?.message
    }

    /// Logs a send that was turned away
    func refuseSend(_ request: BridgeRequest, _ reason: String) -> BridgeReply {
        log.add(entry(.refused, request, detail: reason, showCommand: false))
        return .failure(reason)
    }

    // MARK: - Keys Claude asks for

    /// Why Claude can't ask for this key, or what to tell it straight away
    /// (nil: show the Add window)
    func requestAnswer(_ request: BridgeRequest) -> BridgeReply? {
        guard let name = request.names?.first, request.names?.count == 1, SecretName.isValid(name) else {
            return .failure("Ask for one key, by a name like CLOUDFLARE_API_TOKEN.")
        }
        if let record = store.record(name) {
            if record.isArchived { return .failure("\(name) is archived in KeyBar. Ask the user to restore it.") }
            return BridgeReply(ok: true, message: "\(name) is already in KeyBar. Use it with run_with_secrets.")
        }
        return nil
    }

    private func finished(_ request: BridgeRequest) -> BridgeReply {
        guard let runID = request.runID else { return BridgeReply(ok: true) }
        let proxied = proxy?.revoke(runID: runID) ?? 0
        guard let entry = running.removeValue(forKey: runID) else { return BridgeReply(ok: true) }
        var detail = request.timedOut == true ? "Timed out" : "Exit \(request.exitCode ?? 0)"
        if let hidden = request.redactions, hidden > 0 {
            detail += " · \(hidden) cop\(hidden == 1 ? "y" : "ies") hidden"
        }
        if proxied > 0 { detail += " · \(proxied) request\(proxied == 1 ? "" : "s") through KeyBar" }
        log.update(entry, detail: detail)
        return BridgeReply(ok: true)
    }

    // MARK: - The commit guard

    /// Which stored keys are in each file's staged changes. Only names go
    /// back, and only for whole values (or a file key's long secret parts).
    private func check(_ request: BridgeRequest) -> BridgeReply {
        let watched = Needles.all(in: store)
        var found: [String: [String]] = [:]
        for (file, text) in request.texts ?? [:] {
            let data = Data(text.utf8)
            let names = watched.filter { item in item.needles.contains { LeakScanner.occurrences(of: $0, in: data) > 0 } }.map(\.name)
            if !names.isEmpty { found[file] = names.sorted() }
        }
        if !found.isEmpty {
            let files = found.keys.sorted()
            log.add(ActivityEntry(action: .stopped, source: source(request), names: Array(Set(found.values.joined())).sorted(),
                                  program: "git commit", folder: request.cwd,
                                  detail: "In \(files.prefix(3).joined(separator: ", "))\(files.count > 3 ? " and \(files.count - 3) more" : "")",
                                  client: source(request) == .other ? request.client : nil))
        }
        return BridgeReply(ok: true, found: found)
    }

    /// ~/Dev/Project instead of /Users/name/Dev/Project
    nonisolated static func tidy(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
