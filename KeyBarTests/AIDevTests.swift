import Network
import XCTest
@testable import KeyBar

/// A scratch folder, deleted afterwards
private func scratch(_ name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("keybar-test-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

final class ProjectKeysTests: XCTestCase {
    func testParseKeepsNamesOnly() {
        XCTAssertEqual(ProjectKeys.parse("# keys\nCLOUDFLARE_API_TOKEN\n  STRIPE_KEY  # live\nnot a name\nCLOUDFLARE_API_TOKEN\n"),
                       ["CLOUDFLARE_API_TOKEN", "STRIPE_KEY"])
    }

    func testFindsNearestFileUpToHome() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Dev/site")
        try write("A_KEY\n", to: project.appendingPathComponent(".keybar"))
        let deep = project.appendingPathComponent("src/lib")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertEqual(ProjectKeys.find(from: deep.path, home: home.path)?.names, ["A_KEY"])
        XCTAssertNil(ProjectKeys.find(from: home.appendingPathComponent("Dev").path, home: home.path))
        // ~/.keybar is KeyBar's folder, never a list
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".keybar"), withIntermediateDirectories: true)
        XCTAssertNil(ProjectKeys.find(from: home.path, home: home.path))
    }

    func testKeybarRunSetsTheListedKeys() throws {
        let files = ["/p/.keybar": "TOKEN\nOTHER\n", "/p/.env": "TOKEN=keybar:REAL_TOKEN\n"]
        let plan = try RunPlan.make(["--", "deploy"], in: "/p") { files[$0] }
        XCTAssertEqual(plan.keys, ["TOKEN": "REAL_TOKEN", "OTHER": "OTHER"], ".env's reference wins; the list adds the rest")
        XCTAssertEqual(plan.projectFile, "/p/.keybar")
    }
}

@MainActor
final class PolicyAIDevTests: XCTestCase {
    func makePolicy(_ values: [String: String] = ["TOKEN": "t-value-1234567890", "OTHER": "o-value-1234567890"],
                    proxy: KeyProxy? = nil) -> (BridgePolicy, SecretStore, ActivityLog, AppSettings) {
        let store = SecretStore(vault: MemoryVault(values), indexURL: nil)
        let log = ActivityLog(url: nil)
        let settings = AppSettings()
        settings.approvalSeconds = 900
        return (BridgePolicy(store: store, log: log, settings: settings, proxy: proxy), store, log, settings)
    }

    func testProjectListHidesAndRefuses() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("TOKEN\n", to: folder.appendingPathComponent(".keybar"))
        let (policy, _, _, _) = makePolicy()
        let list = policy.handle(BridgeRequest(action: .list, cwd: folder.path, projectFolder: folder.path))
        XCTAssertEqual(list.secrets?.map(\.name), ["TOKEN"])
        XCTAssertNotNil(list.message)
        let refused = policy.handle(BridgeRequest(action: .resolve, cwd: folder.path, projectFolder: folder.path,
                                                  names: ["OTHER"], command: "echo $OTHER"))
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.error?.contains(".keybar") == true)
        let allowed = policy.handle(BridgeRequest(action: .resolve, cwd: folder.path, projectFolder: folder.path,
                                                  names: ["TOKEN"], command: "echo $TOKEN"))
        XCTAssertTrue(allowed.ok)
    }

    func testPerKeyApproval() {
        let (policy, store, _, settings) = makePolicy()
        let request = BridgeRequest(action: .resolve, cwd: "/tmp", names: ["TOKEN"], command: "deploy")
        XCTAssertNotNil(policy.approvalPrompt(for: request))
        policy.approved(request)
        XCTAssertNil(policy.approvalPrompt(for: request), "15 minutes by default")

        var record = store.record("TOKEN")!
        record.approval = .everyTime
        store.update(record)
        XCTAssertNotNil(policy.approvalPrompt(for: request), "every time, whatever was approved before")

        record.approval = .never
        store.update(record)
        settings.approvalSeconds = -1
        XCTAssertNil(policy.approvalPrompt(for: request), "don't ask beats Settings' every time")
        let both = BridgeRequest(action: .resolve, cwd: "/tmp", names: ["TOKEN", "OTHER"], command: "deploy")
        XCTAssertNotNil(policy.approvalPrompt(for: both), "a key without its own rule still follows Settings")
        let terminal = BridgeRequest(action: .resolve, cwd: "/tmp", client: Bridge.terminalClient, names: ["TOKEN"], command: "printenv")
        XCTAssertNotNil(policy.approvalPrompt(for: terminal), "keybar run always asks")
    }

    func testCommitCheckFindsWholeValuesOnly() {
        let (policy, _, log, _) = makePolicy(["STRIPE_SECRET_KEY": "sk_live_abcdefghijklmnop", "CLOUDFLARE_ACCOUNT_ID": "3f0c9d2a7b1e4c8f9a6d5e2b1c0f7a8e",
                                              "SHORT_KEY": "abc123"])
        let reply = policy.handle(BridgeRequest(action: .check, cwd: "/repo", client: "git commit", texts: [
            "config.js": "const key = 'sk_live_abcdefghijklmnop'\n",
            "wrangler.toml": "account_id = \"3f0c9d2a7b1e4c8f9a6d5e2b1c0f7a8e\"\n",
            "notes.md": "abc123 sk_live_abc\n",
        ]))
        XCTAssertEqual(reply.found, ["config.js": ["STRIPE_SECRET_KEY"]], "account IDs aren't secret; short values and fragments don't count")
        XCTAssertEqual(log.entries.first?.action, .stopped)
        XCTAssertEqual(policy.handle(BridgeRequest(action: .check, cwd: "/repo", texts: ["a.js": "process.env.STRIPE_SECRET_KEY"])).found, [:])
    }

    func testProxiedKeyGetsAPlaceholderAndAnAddress() throws {
        let proxy = KeyProxy()
        let (policy, store, _, settings) = makePolicy(["ANTHROPIC_API_KEY": "sk-ant-real-value-123456"], proxy: proxy)
        settings.approvalSeconds = 0
        var record = store.record("ANTHROPIC_API_KEY")!
        record.proxied = true
        store.update(record)
        let reply = policy.handle(BridgeRequest(action: .resolve, cwd: "/tmp", names: ["ANTHROPIC_API_KEY"], command: "python app.py"))
        XCTAssertEqual(reply.values?["ANTHROPIC_API_KEY"], Bridge.proxyPlaceholder)
        let base = try XCTUnwrap(reply.environment?["ANTHROPIC_BASE_URL"])
        XCTAssertTrue(base.hasPrefix("http://127.0.0.1:"))
        XCTAssertEqual(Bridge.proxyEnvironment(reply.environment), reply.environment)
        XCTAssertEqual(proxy.activeGrants, 1)
        _ = policy.handle(BridgeRequest(action: .finished, cwd: "/tmp", runID: reply.runID, exitCode: 0))
        XCTAssertEqual(proxy.activeGrants, 0, "the address stops working when the command ends")
        proxy.stop()
    }

    func testHelperOnlyTakesLocalProxyVariables() {
        XCTAssertEqual(Bridge.proxyEnvironment(["ANTHROPIC_BASE_URL": "http://127.0.0.1:5/t", "BASH_ENV": "/tmp/evil",
                                                "OPENAI_BASE_URL": "https://evil.example"]),
                       ["ANTHROPIC_BASE_URL": "http://127.0.0.1:5/t"])
    }

    func testClientNames() {
        XCTAssertEqual(Bridge.label(forClient: "claude-code"), "Claude Code")
        XCTAssertEqual(Bridge.label(forClient: "claude-ai"), "Claude Desktop")
        XCTAssertEqual(Bridge.label(forClient: "cursor-vscode"), "Cursor")
        XCTAssertEqual(Bridge.label(forClient: "codex-mcp-client"), "Codex")
        XCTAssertEqual(Bridge.label(forClient: "KeyBar test"), "KeyBar test")
    }
}

final class StagedChangesTests: XCTestCase {
    func testReadsAddedLinesByFile() {
        let diff = """
        diff --git a/src/a.js b/src/a.js
        --- a/src/a.js
        +++ b/src/a.js
        @@ -1 +1 @@
        -old
        +new line
        diff --git a/gone.txt b/gone.txt
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        XCTAssertEqual(StagedChanges.addedLines(diff), ["src/a.js": "new line\n"])
    }

    func testBatchesStayUnderTheLimit() {
        let big = String(repeating: "x", count: StagedChanges.batchSize + 10)
        let batches = StagedChanges.batches(["big.txt": big, "small.txt": "hi"])
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.values.reduce(0) { $0 + $1.utf8.count } <= StagedChanges.batchSize })
        XCTAssertEqual(batches.compactMap { $0["big.txt"] }.joined().count, big.count, "nothing lost")
    }
}

final class LeakScannerTests: XCTestCase {
    let watched: [(name: String, needles: [String])] = [("OPENAI_API_KEY", ["sk-proj-leakedvalue123456"])]

    func testCountsAcrossChunkBoundaries() {
        let data = Data("..sk-proj-leakedvalue123456..sk-proj-leakedvalue123456".utf8)
        XCTAssertEqual(LeakScanner.occurrences(of: "sk-proj-leakedvalue123456", in: data), 2)
        XCTAssertEqual(LeakScanner.occurrences(of: "sk-proj-leakedvalue123456", in: data, endingAfter: 28), 1)
    }

    func testFindsAndHidesInTranscripts() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent(".claude/projects/-Users-me-site/session.jsonl")
        try write(#"{"message":"export OPENAI_API_KEY=sk-proj-leakedvalue123456"}"# + "\n", to: transcript)
        try write("echo sk-proj-leakedvalue123456\n", to: home.appendingPathComponent(".zsh_history"))
        try write("module code sk-proj-leakedvalue123456", to: home.appendingPathComponent(".claude/local/node_modules/x.js"))
        let leaks = LeakScanner(home: home).scan(watched)
        XCTAssertEqual(Set(leaks.map(\.place)), [.claudeCode, .shellHistory], "Claude's own code folder is skipped")
        let found = try XCTUnwrap(leaks.first { $0.place == .claudeCode })
        XCTAssertTrue(found.canHide)
        // Hiding refuses a file that's being written to
        XCTAssertThrowsError(try LeakScanner.hide(watched[0].needles, in: found.path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: found.path)
        XCTAssertEqual(try LeakScanner.hide(watched[0].needles, in: found.path), 1)
        XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), #"{"message":"export OPENAI_API_KEY=[REDACTED]"}"# + "\n")
        XCTAssertTrue(LeakScanner(home: home).scan(watched).allSatisfy { $0.place != .claudeCode })
    }

    func testFindsKeysInGitHistory() throws {
        try XCTSkipIf(GitTool.path == nil, "needs git")
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent("Dev/shop")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        GitTool.run(["-C", repo.path, "init", "-q"], environment: env)
        try write("key = 'sk-proj-leakedvalue123456'\n", to: repo.appendingPathComponent("config.py"))
        GitTool.run(["-C", repo.path, "add", "."], environment: env)
        GitTool.run(["-C", repo.path, "commit", "-qm", "add config"], environment: env)
        try write("key = os.environ['OPENAI_API_KEY']\n", to: repo.appendingPathComponent("config.py"))
        GitTool.run(["-C", repo.path, "commit", "-qam", "use env"], environment: env)
        let leaks = LeakScanner(home: home, gitFolders: [home.appendingPathComponent("Dev")], includeGit: true).searchGit(repo, watched)
        XCTAssertEqual(leaks.count, 1)
        XCTAssertEqual(leaks.first?.place, .gitHistory)
        XCTAssertTrue(leaks.first?.detail?.hasSuffix("config.py") == true)
        XCTAssertFalse(leaks.first?.canHide ?? true)
    }

    func testIdentifiersArentWatched() {
        let now = Date()
        XCTAssertTrue(Needles.of(SecretRecord(name: "CLOUDFLARE_ACCOUNT_ID", createdAt: now, updatedAt: now), value: "3f0c9d2a7b1e4c8f9a6d5e2b1c0f7a8e").isEmpty)
        XCTAssertTrue(Needles.of(SecretRecord(name: "STRIPE_PUBLISHABLE_KEY", createdAt: now, updatedAt: now), value: "pk_live_0123456789abcdef").isEmpty)
        XCTAssertEqual(Needles.of(SecretRecord(name: "STRIPE_SECRET_KEY", createdAt: now, updatedAt: now), value: "sk_live_0123456789abcdef"),
                       ["sk_live_0123456789abcdef"])
    }
}

final class CommitGuardTests: XCTestCase {
    var home: URL!
    var env: [String: String] = [:]

    override func setUpWithError() throws {
        try XCTSkipIf(GitTool.path == nil, "needs git")
        home = try scratch()
        let config = home.appendingPathComponent("gitconfig")
        try write("[user]\n\tname = t\n\temail = t@t\n", to: config)
        env = ["GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"]
    }

    override func tearDown() {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    func makeGuard(helper: String) -> CommitGuard {
        CommitGuard(folder: home.appendingPathComponent("hooks"), helperPath: helper, gitEnvironment: env)
    }

    func makeRepo() throws -> URL {
        let repo = home.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        GitTool.run(["-C", repo.path, "init", "-q"], environment: env)
        return repo
    }

    func helper(exitCode: Int) throws -> String {
        let url = home.appendingPathComponent("fake-keybar-\(exitCode)")
        try write("#!/bin/sh\n[ \"$1\" = guard ] || exit 9\nexit \(exitCode)\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func commit(_ repo: URL) throws -> Int32 {
        try write(UUID().uuidString, to: repo.appendingPathComponent("file-\(UUID().uuidString).txt"))
        GitTool.run(["-C", repo.path, "add", "."], environment: env)
        return GitTool.run(["-C", repo.path, "commit", "-qm", "test"], environment: env).status
    }

    func testOnAndOff() throws {
        let commitGuard = makeGuard(helper: try helper(exitCode: 0))
        XCTAssertEqual(commitGuard.status(), .off)
        try commitGuard.turnOn()
        XCTAssertEqual(commitGuard.status(), .on)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("hooks/pre-commit").path))
        try commitGuard.turnOff()
        XCTAssertEqual(commitGuard.status(), .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks").path))
    }

    func testLeavesSomeoneElsesHooksFolderAlone() throws {
        GitTool.run(["config", "--global", "core.hooksPath", "/somewhere/else"], environment: env)
        let commitGuard = makeGuard(helper: try helper(exitCode: 0))
        XCTAssertEqual(commitGuard.status(), .otherHooks("/somewhere/else"))
        XCTAssertThrowsError(try commitGuard.turnOn())
        try commitGuard.turnOff()
        XCTAssertEqual(GitTool.run(["config", "--global", "--get", "core.hooksPath"], environment: env).output, "/somewhere/else")
    }

    func testStopsACommitAndStillRunsTheRepoHook() throws {
        let repo = try makeRepo()
        let marker = home.appendingPathComponent("own-hook-ran")
        let own = repo.appendingPathComponent(".git/hooks/pre-commit")
        try write("#!/bin/sh\ntouch '\(marker.path)'\n", to: own)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.path)

        try makeGuard(helper: try helper(exitCode: 1)).turnOn()
        XCTAssertNotEqual(try commit(repo), 0, "the guard found a key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try makeGuard(helper: try helper(exitCode: 0)).turnOn()
        XCTAssertEqual(try commit(repo), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the repo's own hook still runs")

        try makeGuard(helper: "/nowhere/keybar").turnOn()
        XCTAssertEqual(try commit(repo), 0, "without KeyBar, commits go ahead")
    }
}

@MainActor
final class AIAppsTests: XCTestCase {
    let helper = "/Applications/KeyBar.app/Contents/Helpers/keybar"

    func testConnectsAndKeepsOtherSettings() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let apps = AIApps(home: home, helperPath: helper)
        let cursor = apps.url(.cursor)
        try write(#"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#, to: cursor)
        apps.connect(.cursor)
        XCTAssertEqual(apps.status(.cursor), .connected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cursor)) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "dark")
        XCTAssertNotNil((json["mcpServers"] as? [String: Any])?["other"])
        apps.disconnect(.cursor)
        XCTAssertEqual(apps.status(.cursor), .disconnected)

        apps.connect(.vsCode)
        let vs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: apps.url(.vsCode))) as? [String: Any])
        XCTAssertEqual(((vs["servers"] as? [String: Any])?["keybar"] as? [String: Any])?["type"] as? String, "stdio")
    }

    func testLeavesFilesWithCommentsAlone() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let apps = AIApps(home: home, helperPath: helper)
        let text = "// my settings\n{\"mcpServers\": {}}\n"
        try write(text, to: apps.url(.gemini))
        apps.connect(.gemini)
        XCTAssertNotNil(apps.errors[.gemini])
        XCTAssertEqual(try String(contentsOf: apps.url(.gemini), encoding: .utf8), text)
        apps.connect(.zed)
        XCTAssertNotNil(apps.errors[.zed], "Zed is set up by hand")
    }

    func testCodexBlockComesAndGoes() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let apps = AIApps(home: home, helperPath: helper)
        let original = "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        try write(original, to: apps.url(.codex))
        apps.connect(.codex)
        XCTAssertEqual(apps.status(.codex), .connected)
        XCTAssertTrue(try String(contentsOf: apps.url(.codex), encoding: .utf8).hasPrefix(original))
        apps.connect(.codex)
        XCTAssertEqual(try String(contentsOf: apps.url(.codex), encoding: .utf8).components(separatedBy: "[mcp_servers.keybar]").count, 2, "once only")
        apps.disconnect(.codex)
        XCTAssertEqual(try String(contentsOf: apps.url(.codex), encoding: .utf8), original)
    }
}

/// The proxy against a stand-in for the service, on this Mac
final class KeyProxyTests: XCTestCase {
    /// Answers every request with 200 and what it was sent
    final class FakeService: @unchecked Sendable {
        let listener: NWListener
        var port: UInt16 = 0
        var lastRequest = ""

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.read(connection, Data())
            }
            listener.start(queue: .global())
            _ = ready.wait(timeout: .now() + 5)
        }

        /// Reads until the whole request (headers and Content-Length body) is in
        private func read(_ connection: NWConnection, _ sofar: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
                var all = sofar
                if let data { all.append(data) }
                let text = String(decoding: all, as: UTF8.self)
                if let split = text.range(of: "\r\n\r\n") {
                    let length = text[..<split.lowerBound].lowercased().components(separatedBy: "\r\n")
                        .first { $0.hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                    if text[split.upperBound...].utf8.count >= length || done {
                        self?.lastRequest = text
                        let body = "event: message\ndata: hello\n\n"
                        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                }
                if done { connection.cancel(); return }
                self?.read(connection, all)
            }
        }
    }

    func testAddsTheKeyAndPassesTheReplyBack() async throws {
        let service = try FakeService()
        defer { service.listener.cancel() }
        let proxy = KeyProxy()
        defer { proxy.stop() }
        let route = KeyProxy.Route(variable: "ANTHROPIC_BASE_URL", origin: "http://127.0.0.1:\(service.port)", basePath: "",
                                   header: "x-api-key", format: "KEY", service: "Test")
        let base = try XCTUnwrap(proxy.grant(name: "ANTHROPIC_API_KEY", value: "sk-real-123", route: route, runID: "run1"))

        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/v1/messages?beta=true")))
        request.httpMethod = "POST"
        request.setValue(Bridge.proxyPlaceholder, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = Data(#"{"model":"claude"}"#.utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "event: message\ndata: hello\n\n")
        let seen = service.lastRequest.lowercased()
        XCTAssertTrue(seen.hasPrefix("post /v1/messages?beta=true "), seen)
        XCTAssertTrue(seen.contains("x-api-key: sk-real-123"))
        XCTAssertFalse(seen.contains(Bridge.proxyPlaceholder))
        XCTAssertTrue(seen.contains("anthropic-version: 2023-06-01"))
        XCTAssertTrue(seen.contains(#"{"model":"claude"}"#))

        XCTAssertEqual(proxy.revoke(runID: "run1"), 1)
        let (_, after) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((after as? HTTPURLResponse)?.statusCode, 403, "the address stops working")
    }

    /// Through the proxy to Anthropic's real API with a made-up key: it must
    /// come back as Anthropic's own "invalid key" answer. NETWORK_TESTS=1 only.
    func testRealServiceOverHTTPS() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NETWORK_TESTS"] == "1", "set NETWORK_TESTS=1")
        let proxy = KeyProxy()
        defer { proxy.stop() }
        let now = Date()
        let route = try XCTUnwrap(KeyProxy.route(for: SecretRecord(name: "ANTHROPIC_API_KEY", createdAt: now, updatedAt: now)))
        let base = try XCTUnwrap(proxy.grant(name: "ANTHROPIC_API_KEY", value: "sk-ant-api03-not-a-real-key", route: route, runID: "net"))
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/v1/models")))
        request.setValue(Bridge.proxyPlaceholder, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("authentication_error"), String(decoding: data, as: UTF8.self))
    }

    func testOnlyAPIKeysOfKnownServices() {
        let now = Date()
        XCTAssertEqual(KeyProxy.route(for: SecretRecord(name: "ANTHROPIC_API_KEY", createdAt: now, updatedAt: now))?.variable, "ANTHROPIC_BASE_URL")
        XCTAssertEqual(KeyProxy.route(for: SecretRecord(name: "OPENAI_API_KEY", createdAt: now, updatedAt: now))?.basePath, "/v1")
        XCTAssertNil(KeyProxy.route(for: SecretRecord(name: "CLAUDE_CODE_OAUTH_TOKEN", createdAt: now, updatedAt: now)))
        XCTAssertNil(KeyProxy.route(for: SecretRecord(name: "STRIPE_SECRET_KEY", createdAt: now, updatedAt: now)))
    }

    func testChunkedBodies() {
        var decoder = ChunkedDecoder()
        var buffer = Data("5\r\nhello\r\n6\r\n world\r\n".utf8)
        var body = Data()
        XCTAssertFalse(decoder.feed(&buffer, into: &body))
        buffer.append(Data("0\r\n\r\n".utf8))
        XCTAssertTrue(decoder.feed(&buffer, into: &body))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")
    }
}
