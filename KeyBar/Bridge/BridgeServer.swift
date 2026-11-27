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
    /// Two-step sign-ins whose username step was just approved, keyed by
    /// `approvalScope`: the password step that follows needn't ask again
    private var secondSteps: [String: Date] = [:]
    /// How long the password page of a two-step sign-in has to turn up
    static let secondStepWindow: TimeInterval = 120

    /// Whether macOS lets KeyBar use Accessibility (filling passwords needs it)
    private let accessibility: () -> Bool

    /// Values shorter than this aren't looked for in commands: too likely to match by chance
    static let literalCheckLength = 8

    init(store: SecretStore, log: ActivityLog, settings: AppSettings? = nil, proxy: KeyProxy? = nil,
         accessibility: @escaping () -> Bool = { AccessibilityAccess.isTrusted }) {
        self.store = store
        self.log = log
        self.settings = settings
        self.proxy = proxy
        self.accessibility = accessibility
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
        case .send, .request, .fill: return .failure("KeyBar couldn't handle that request.")
        }
    }

    /// Settings → Logins in commands
    private var loginsInCommands: Bool { settings?.loginsInCommands ?? false }

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
                          expiresAt: record.expiresAt, proxyVariable: record.usesProxy ? KeyProxy.route(for: record)?.variable : nil,
                          isPassword: record.isPassword ? true : nil,
                          hasUsername: record.isPassword ? !(record.username ?? "").isEmpty : nil,
                          websites: record.isPassword ? record.sites : nil,
                          inCommands: record.isPassword && loginsInCommands ? true : nil)
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
    /// The requested keys' own Touch ID rules. Logins have none: they
    /// always follow Settings.
    private func keyRules(_ request: BridgeRequest) -> [KeyApproval] {
        (request.names ?? []).compactMap { name in
            store.record(name).flatMap { $0.isPassword ? nil : $0.approval }
        }
    }

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
                                           keys: keyRules(request))
        guard seconds != 0 else { return nil }
        if seconds > 0, let approved = approvals[Self.approvalScope(request)],
           Date().timeIntervalSince(approved) < seconds {
            return nil
        }
        let names = (request.names ?? []).sorted().map { name in
            store.record(name)?.isPassword == true ? "\(name) (username and password)" : name
        }.joined(separator: ", ")
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

    /// How long one approval lasts. `keybar run` asks every time: its output
    /// isn't redacted, and an approval kept for a while could be reused by
    /// something that edits what the command runs (a package.json script, say)
    /// or gets past the Claude Code check.
    /// A key set to ask every time always asks; if every key is set never to
    /// ask, it doesn't (except for `keybar run`)
    static func approvalSeconds(for request: BridgeRequest, setting: TimeInterval, keys: [KeyApproval] = []) -> TimeInterval {
        if request.client == Bridge.terminalClient { return -1 }
        if keys.contains(.everyTime) { return -1 }
        if !keys.isEmpty && keys.count == (request.names ?? []).count && keys.allSatisfy({ $0 == .never }) { return 0 }
        return setting
    }

    /// One approval covers the same client using the same keys from the same
    /// project, not every key for everyone. (`keybar run` is never covered:
    /// it asks every time. Its scope still names the command and terminal, so
    /// nothing changes if that's ever relaxed.) A fill's covers the same
    /// password on the same site only.
    static func approvalScope(_ request: BridgeRequest, site: String? = nil) -> String {
        var parts = [request.client, request.projectFolder ?? request.cwd, (request.names ?? []).sorted().joined(separator: ",")]
        if request.client == Bridge.terminalClient { parts += [request.command ?? "", request.terminal ?? ""] }
        if request.action == .fill { parts += ["fill", site ?? ""] }
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
            let stored = store.activeKeys.map(\.name).joined(separator: ", ")
            return Problem(message: "KeyBar has no key called \(missing.joined(separator: ", ")). "
                + (stored.isEmpty ? "No keys are stored yet." : "Stored keys: \(stored)."))
        }
        // Logins never leave the Mac, and only go into commands (as
        // $NAME_USERNAME and $NAME_PASSWORD) once the user turns that on:
        // otherwise they're only filled into their own login pages
        let logins = names.filter { store.record($0)?.isPassword == true }.sorted()
        if !logins.isEmpty {
            let list = logins.joined(separator: ", ")
            let what = logins.count == 1 ? "is a website login" : "are website logins"
            if request.action == .send { return Problem(message: "\(list) \(what), and KeyBar never sends logins anywhere.") }
            if !loginsInCommands {
                if request.client == Bridge.terminalClient {
                    return Problem(message: "\(list) \(what). Commands can only use logins once you turn on KeyBar → Settings → Logins in commands.")
                }
                return Problem(message: "\(list) \(what), and KeyBar's setting \"Logins in commands\" is off, so commands can't use "
                    + "\(logins.count == 1 ? "it" : "them"). To sign in on the website, open its login page and call fill_password. "
                    + "If a command really needs the login, ask the user whether they want to turn that setting on.")
            }
            // A login's variables mustn't collide with another name asked for
            let asked = Set(names)
            for login in logins {
                let variables = Bridge.loginVariables(login)
                if let clash = [variables.username, variables.password].first(where: asked.contains) {
                    return Problem(message: "\(clash) is both a stored key and one of \(login)'s variables. Use them in separate commands.")
                }
            }
        }
        let archived = names.filter { store.record($0)?.isArchived == true }
        if !archived.isEmpty {
            return Problem(message: "\(archived.joined(separator: ", ")) \(archived.count == 1 ? "is" : "are") archived in KeyBar. "
                + "Ask the user to restore \(archived.count == 1 ? "it" : "them") if needed.")
        }
        let lists = projectLists(for: request)
        for name in names {
            if let problem = placeProblem(name, request: request, lists: lists) { return Problem(message: problem) }
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

    /// Why a key (or password) can't be used from where the request comes
    /// from: a project's .keybar leaves it out, or it's limited to other folders
    private func placeProblem(_ name: String, request: BridgeRequest, lists: [ProjectKeys]) -> String? {
        if let list = listWithout(name, in: lists) {
            return "\(name) isn't in \(Self.tidy(list.path)), the list of keys this project uses, so it can't "
                + "be used here. Ask the user to add it to that file if the project needs it."
        }
        guard let record = store.record(name), isAvailable(record, for: request) else {
            let folders = store.record(name)?.projectFolders.map(Self.tidy).joined(separator: ", ") ?? "some folders"
            let here = Self.tidy(request.projectFolder ?? request.cwd)
            return "\(name) can only be used in \(folders), not in \(here)."
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
                if let record = store.record(name), record.isPassword {
                    // A login: its username and password, never under its
                    // own name (so $NAME is never a half of it)
                    let variables = Bridge.loginVariables(name)
                    values[variables.password] = try store.value(name)
                    if let username = record.username, !username.isEmpty { values[variables.username] = username }
                } else {
                    values[name] = try store.value(name)
                }
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
        if request.secretType == .password { return passwordRequestAnswer(request) }
        guard let name = request.names?.first, request.names?.count == 1, SecretName.isValid(name) else {
            return .failure("Ask for one key, by a name like CLOUDFLARE_API_TOKEN.")
        }
        if let record = store.record(name) {
            if record.isArchived { return .failure("\(name) is archived in KeyBar. Ask the user to restore it.") }
            if record.isPassword { return BridgeReply(ok: true, message: "\(name) is a website login in KeyBar. Use it with fill_password.") }
            return BridgeReply(ok: true, message: "\(name) is already in KeyBar. Use it with run_with_secrets.")
        }
        return nil
    }

    /// The same, for a password Claude asks for: by website, the name optional
    private func passwordRequestAnswer(_ request: BridgeRequest) -> BridgeReply? {
        guard let site = request.site.flatMap({ try? LoginSite.normalise($0) }) else {
            return .failure("Say which website the password is for, e.g. liverpoolfc.com.")
        }
        let names = request.names ?? []
        guard names.count <= 1 else { return .failure("Ask for one password at a time.") }
        if let name = names.first {
            guard SecretName.isValid(name) else { return .failure("\"\(name)\" can't be a name. Use one like LOGIN_LIVERPOOLFC, or leave it out.") }
            if let record = store.record(name) {
                guard record.isPassword else { return .failure("\(name) is already an API key in KeyBar. Ask for the password under another name.") }
                if record.isArchived { return .failure("\(name) is archived in KeyBar. Ask the user to restore it.") }
                return BridgeReply(ok: true, message: "\(name) is already in KeyBar. Use it with fill_password.")
            }
        }
        let existing = store.passwords(for: site).map(\.name)
        if !existing.isEmpty {
            return BridgeReply(ok: true, message: "KeyBar already has \(existing.count == 1 ? "a password" : "passwords") for \(site): "
                + "\(existing.joined(separator: ", ")). Use \(existing.count == 1 ? "it" : "one") with fill_password.")
        }
        if let archived = store.archived.first(where: { $0.isPassword && LoginSite.matches(site, websites: $0.sites) }) {
            return .failure("\(archived.name), the password for \(site), is archived in KeyBar. Ask the user to restore it.")
        }
        return nil
    }

    // MARK: - Filling passwords

    /// Why a password can't be filled for this request, or nil if KeyBar may
    /// look for its login page. The same rules as using a key: it must exist,
    /// not be archived, and be allowed in this project and folder.
    func fillProblem(_ request: BridgeRequest) -> String? {
        guard let name = request.names?.first, request.names?.count == 1 else { return "Fill one password at a time." }
        guard let record = store.record(name) else {
            let stored = store.activePasswords.map(\.name).joined(separator: ", ")
            return "KeyBar has no login called \(name). "
                + (stored.isEmpty ? "No website logins are stored yet; ask for one with request_secret." : "Stored logins: \(stored).")
        }
        guard record.isPassword else {
            return "\(name) is an API key, not a website login, so it can't be filled into a page. Use it with run_with_secrets."
        }
        if record.isArchived { return "\(name) is archived in KeyBar. Ask the user to restore it if needed." }
        if let problem = placeProblem(name, request: request, lists: projectLists(for: request)) { return problem }
        guard !record.sites.isEmpty else {
            return "\(name) has no website saved, so KeyBar can't tell where it may go. Ask the user to add one in KeyBar."
        }
        if let site = request.site {
            guard let host = try? LoginSite.normalise(site),
                  LoginSite.matches(host, websites: record.sites) || record.sites.contains(where: { LoginSite.matches($0, websites: [host]) }) else {
                return "\(site) isn't one of \(name)'s websites (\(record.sites.joined(separator: ", ")))."
            }
        }
        guard accessibility() else { return FillProblem.notTrusted.message }
        return nil
    }

    /// The websites a fill may go to
    func websites(for request: BridgeRequest) -> [String] {
        request.names?.first.flatMap { store.record($0) }?.sites ?? []
    }

    /// What to ask with Touch ID before filling into this page, or nil if
    /// the rules say not to ask (Settings, or a recent yes for the same login
    /// on the same site)
    func fillPrompt(_ request: BridgeRequest, site: String, browser: String) -> String? {
        guard let settings, fillProblem(request) == nil else { return nil }
        let seconds = Self.approvalSeconds(for: request, setting: settings.approvalSeconds,
                                           keys: keyRules(request))
        guard seconds != 0 else { return nil }
        let scope = Self.approvalScope(request, site: site)
        // The password page of a sign-in whose username page was just approved
        if let started = secondSteps.removeValue(forKey: scope), Date().timeIntervalSince(started) < Self.secondStepWindow {
            return nil
        }
        if seconds > 0, let approved = approvals[scope], Date().timeIntervalSince(approved) < seconds {
            return nil
        }
        let name = request.names?.first ?? ""
        return "let \(Self.promptCommand(request.client)) sign in to \(Self.promptCommand(site)) in \(browser) with your login \(name)"
    }

    func approvedFill(_ request: BridgeRequest, site: String) {
        approvals[Self.approvalScope(request, site: site)] = Date()
    }

    /// A username step went through: the password step on the same site may
    /// follow without asking again, once, for a couple of minutes
    func startedSecondStep(_ request: BridgeRequest, site: String) {
        secondSteps[Self.approvalScope(request, site: site)] = Date()
    }

    /// Whether the login has a username to type
    func loginHasUsername(_ request: BridgeRequest) -> Bool {
        !(request.names?.first.flatMap { store.record($0) }?.username ?? "").isEmpty
    }

    /// The login's username, read only once the fill may go ahead
    func loginUsername(_ request: BridgeRequest) -> String? {
        guard fillProblem(request) == nil else { return nil }
        return request.names?.first.flatMap { store.record($0) }?.username.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The password, read only once the fill may go ahead
    func passwordValue(_ request: BridgeRequest) -> Result<String, FillProblem> {
        guard let name = request.names?.first, fillProblem(request) == nil else {
            return .failure(.failed(fillProblem(request) ?? "nothing to fill."))
        }
        do {
            return .success(try store.value(name))
        } catch {
            return .failure(.failed("couldn't read \(name) from the Keychain: \(error.localizedDescription)"))
        }
    }

    private func fillEntry(_ action: ActivityEntry.Action, _ request: BridgeRequest, detail: String) -> ActivityEntry {
        let source = source(request)
        return ActivityEntry(action: action, source: source, names: request.names ?? [], program: ActivityEntry.fillProgram,
                             folder: request.projectFolder ?? request.cwd, detail: detail,
                             client: source == .other ? request.client : nil)
    }

    private static func place(_ site: String?, _ browser: String?) -> String? {
        guard let site else { return nil }
        return browser.map { "\(site) in \($0)" } ?? site
    }

    /// Logs a fill that was turned away or didn't work
    func refuseFill(_ request: BridgeRequest, _ reason: String, site: String? = nil, browser: String? = nil) -> BridgeReply {
        let detail = [Self.place(site, browser), reason].compactMap { $0 }.joined(separator: ": ")
        log.add(fillEntry(.refused, request, detail: detail))
        return .failure(reason)
    }

    func declinedFill(_ request: BridgeRequest, site: String, browser: String) -> BridgeReply {
        let reason = "You didn't allow it in KeyBar's Touch ID prompt."
        log.add(fillEntry(.refused, request, detail: "\(site) in \(browser): \(reason)"))
        return .failure(reason + " Ask the user before trying again.")
    }

    func filled(_ request: BridgeRequest, site: String, browser: String, outcome: FillOutcome) -> BridgeReply {
        let name = request.names?.first ?? ""
        store.markUsed([name])
        log.add(fillEntry(.filled, request, detail: "\(site) in \(browser): \(outcome.detail)"))
        if outcome == .usernameSent { startedSecondStep(request, site: site) }
        return BridgeReply(ok: true, message: outcome.message(name: name, host: site, browser: browser))
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
