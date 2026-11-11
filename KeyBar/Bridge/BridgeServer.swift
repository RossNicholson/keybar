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
        requirement = Self.helperRequirement()
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
        let reply: BridgeReply
        if !callerIsHelper(client) {
            reply = .failure("KeyBar only answers its own signed helper.")
        } else if let line = try? BridgeSocket.readLine(client),
                  let request = try? JSONDecoder().decode(BridgeRequest.self, from: line) {
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
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }

        // The socket is private to this user; also make sure it's the same user
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return false }

        guard let requirement else {
            // An unsigned development build can't check signatures
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// "Signed by Apple's CA for this app's team, as KeyBar's helper". Nil if
    /// this copy of the app isn't signed with a team (a local test build).
    private static func helperRequirement() -> SecRequirement? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(Bridge.helperIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}

/// Answers the helper's requests: the rules for which keys a command gets
@MainActor
final class BridgePolicy {
    private let store: SecretStore
    private let log: ActivityLog
    /// Runs waiting for their "finished" report: run ID → log entry
    private var running: [String: String] = [:]

    /// Values shorter than this aren't looked for in commands: too likely to match by chance
    static let literalCheckLength = 8

    init(store: SecretStore, log: ActivityLog) {
        self.store = store
        self.log = log
    }

    func handle(_ request: BridgeRequest) -> BridgeReply {
        switch request.action {
        case .list: return list(request)
        case .resolve: return resolve(request)
        case .finished: return finished(request)
        }
    }

    private func source(_ request: BridgeRequest) -> ActivityEntry.Source {
        request.client == "Claude Code" ? .claudeCode : .other
    }

    private func list(_ request: BridgeRequest) -> BridgeReply {
        let secrets = store.sorted.map { record in
            SecretSummary(name: record.name, service: record.service?.name, kind: record.kind,
                          group: record.group, note: record.note, restricted: record.isRestricted,
                          availableHere: record.isAvailable(in: request.cwd))
        }
        return BridgeReply(ok: true, secrets: secrets)
    }

    private func resolve(_ request: BridgeRequest) -> BridgeReply {
        let names = request.names ?? []
        let command = request.command ?? ""
        let program = SecretName.program(in: command)

        func refuse(_ reason: String) -> BridgeReply {
            log.add(ActivityEntry(action: .refused, source: source(request), names: names, program: program,
                                  folder: request.cwd, detail: reason))
            return .failure(reason)
        }

        guard !names.isEmpty else { return .failure("Name at least one key.") }
        let missing = names.filter { store.record($0) == nil }
        if !missing.isEmpty {
            let stored = store.sorted.map(\.name).joined(separator: ", ")
            return refuse("KeyBar has no key called \(missing.joined(separator: ", ")). "
                          + (stored.isEmpty ? "No keys are stored yet." : "Stored keys: \(stored)."))
        }
        for name in names {
            guard let record = store.record(name), record.isAvailable(in: request.cwd) else {
                return refuse("\(name) can only be used in \(store.record(name)?.projectFolders.map(Self.tidy).joined(separator: ", ") ?? "some folders"), not in \(Self.tidy(request.cwd)).")
            }
        }
        // A command with a key's value written into it would leave the value in
        // Claude's transcript; it should use $NAME instead
        for record in store.records {
            guard let value = try? store.value(record.name), value.count >= Self.literalCheckLength else { continue }
            if command.contains(value) {
                return refuse("The command contains the value of \(record.name). Use \"$\(record.name)\" and pass its name in secretNames instead.")
            }
        }

        var values: [String: String] = [:]
        for name in names {
            do {
                values[name] = try store.value(name)
            } catch {
                return refuse("Couldn't read \(name) from the Keychain: \(error.localizedDescription)")
            }
        }
        store.markUsed(names)
        let runID = UUID().uuidString
        running[runID] = log.add(ActivityEntry(action: .ran, source: source(request), names: names.sorted(),
                                               program: program, folder: request.cwd, detail: "Running…"))
        return BridgeReply(ok: true, values: values, runID: runID)
    }

    private func finished(_ request: BridgeRequest) -> BridgeReply {
        guard let runID = request.runID, let entry = running.removeValue(forKey: runID) else { return BridgeReply(ok: true) }
        var detail = request.timedOut == true ? "Timed out" : "Exit \(request.exitCode ?? 0)"
        if let hidden = request.redactions, hidden > 0 {
            detail += " · \(hidden) cop\(hidden == 1 ? "y" : "ies") hidden"
        }
        log.update(entry, detail: detail)
        return BridgeReply(ok: true)
    }

    /// ~/Dev/Project instead of /Users/name/Dev/Project
    static func tidy(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
