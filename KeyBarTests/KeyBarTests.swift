import XCTest
@testable import KeyBar

final class RedactorTests: XCTestCase {
    let key = "sk-ant-api03-AbCdEf0123456789/xyz+QQ"

    func testHidesThePlainKey() {
        let result = Redactor(secrets: [key]).redact("token=\(key) done")
        XCTAssertEqual(result.text, "token=[REDACTED] done")
        XCTAssertEqual(result.count, 1)
    }

    func testHidesEncodedCopies() {
        let redactor = Redactor(secrets: [key])
        for form in Redactor.encodings(of: key) {
            let result = redactor.redact("x \(form) y")
            XCTAssertFalse(result.text.contains(form), "\(form) wasn't hidden")
            XCTAssertTrue(result.text.contains(Redactor.marker))
        }
    }

    func testHidesLongFragments() {
        let fragment = String(key.dropFirst(5).prefix(14))
        let result = Redactor(secrets: [key]).redact("partial: \(fragment)!")
        XCTAssertEqual(result.text, "partial: [REDACTED]!")
    }

    func testLeavesShortFragmentsAndOtherText() {
        let text = "sk-ant is a prefix; 0123 is a number"
        XCTAssertEqual(Redactor(secrets: [key]).redact(text).text, text)
    }

    func testAdjacentCopiesBecomeOneMarker() {
        XCTAssertEqual(Redactor(secrets: [key]).redact(key + key).text, Redactor.marker)
    }

    func testIgnoresVeryShortSecrets() {
        XCTAssertTrue(Redactor(secrets: ["abc"]).isEmpty)
    }

    func testMultipleSecretsAndUnicodeText() {
        let other = "ghp_ZZZZZZZZZZZZZZZZZZZZ"
        let result = Redactor(secrets: [key, other]).redact("é \(key) — \(other) ✓")
        XCTAssertEqual(result.text, "é [REDACTED] — [REDACTED] ✓")
        XCTAssertEqual(result.count, 2)
    }
}

final class SecretNameTests: XCTestCase {
    func testValidity() {
        XCTAssertTrue(SecretName.isValid("CLOUDFLARE_API_TOKEN"))
        XCTAssertTrue(SecretName.isValid("_private"))
        XCTAssertFalse(SecretName.isValid("1PASSWORD"))
        XCTAssertFalse(SecretName.isValid("MY-KEY"))
        XCTAssertFalse(SecretName.isValid(""))
        XCTAssertFalse(SecretName.isValid("A B"))
    }

    func testNormalizing() {
        XCTAssertEqual(SecretName.normalized("cloudflare api token"), "CLOUDFLARE_API_TOKEN")
        XCTAssertEqual(SecretName.normalized("  my-key!! "), "MY_KEY")
        XCTAssertEqual(SecretName.normalized("1password"), "_1PASSWORD")
    }

    func testProgramName() {
        XCTAssertEqual(SecretName.program(in: "CI=1 npx wrangler deploy"), "wrangler")
        XCTAssertEqual(SecretName.program(in: "/usr/bin/curl -s https://x"), "curl")
        XCTAssertEqual(SecretName.program(in: "sudo -E gh api user"), "gh")
    }
}

final class EnvFileTests: XCTestCase {
    func testParsing() {
        let text = """
        # comment
        export GITHUB_TOKEN=ghp_abc123
        STRIPE_KEY = "sk_test_x\\ny" # quoted, with an escape
        SINGLE='it''s raw \\n'
        UNQUOTED=value # trailing comment
        HASH=abc#def
        EMPTY=
        bad-name=nope
        MULTI="line one
        line two"
        GITHUB_TOKEN=ghp_last_wins
        """
        let entries = EnvFile.parse(text)
        let values = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.value) })
        XCTAssertEqual(values["GITHUB_TOKEN"], "ghp_last_wins")
        XCTAssertEqual(values["STRIPE_KEY"], "sk_test_x\ny")
        XCTAssertEqual(values["SINGLE"], "it")
        XCTAssertEqual(values["UNQUOTED"], "value")
        XCTAssertEqual(values["HASH"], "abc#def")
        XCTAssertEqual(values["MULTI"], "line one\nline two")
        XCTAssertNil(values["EMPTY"])
        XCTAssertNil(values["bad-name"])
    }
}

final class CatalogTests: XCTestCase {
    func testMatchesServices() {
        XCTAssertEqual(ServiceCatalog.match("CLOUDFLARE_API_TOKEN")?.name, "Cloudflare")
        XCTAssertEqual(ServiceCatalog.match("CF_ACCOUNT_ID")?.name, "Cloudflare")
        XCTAssertEqual(ServiceCatalog.match("GH_TOKEN")?.name, "GitHub")
        XCTAssertEqual(ServiceCatalog.match("ANTHROPIC_API_KEY")?.name, "Anthropic")
        XCTAssertEqual(ServiceCatalog.match("GOOGLE_CLOUD_PROJECT")?.name, "Google Cloud")
        XCTAssertEqual(ServiceCatalog.match("MADROBOT_CLOUDFLARE_TOKEN")?.name, "Cloudflare")
        XCTAssertEqual(ServiceCatalog.match("SENTRY_AUTH_TOKEN")?.name, "Sentry")
        XCTAssertNil(ServiceCatalog.match("FOO_BAR"))
    }

    func testCatalogIsLargeAndUnique() {
        XCTAssertGreaterThan(ServiceCatalog.count, 440)
        XCTAssertEqual(Set(ServiceCatalog.all.map(\.name)).count, ServiceCatalog.count)
    }

    func testKinds() {
        XCTAssertEqual(CredentialKind.of("STRIPE_PUBLISHABLE_KEY"), "Publishable key")
        XCTAssertEqual(CredentialKind.of("STRIPE_SECRET_KEY"), "Secret key")
        XCTAssertEqual(CredentialKind.of("CLOUDFLARE_ACCOUNT_ID"), "Account ID")
        XCTAssertEqual(CredentialKind.of("CLOUDFLARE_API_TOKEN"), "API token")
        XCTAssertEqual(CredentialKind.of("DATABASE_URL"), "Connection string")
        XCTAssertEqual(CredentialKind.of("GITHUB_PAT"), "Personal access token")
        XCTAssertEqual(CredentialKind.of("MYSTERY"), "Secret")
    }

    func testKeyShapes() {
        XCTAssertEqual(KeyShape.suggestedName(for: "sk-ant-api03-xxxxxxxxxxxx"), "ANTHROPIC_API_KEY")
        XCTAssertEqual(KeyShape.suggestedName(for: "github_pat_11AAAAAAAAAAA"), "GITHUB_TOKEN")
        XCTAssertEqual(KeyShape.suggestedName(for: "sk_live_abcdefghijkl"), "STRIPE_SECRET_KEY")
        XCTAssertEqual(KeyShape.suggestedName(for: "AC" + String(repeating: "a", count: 32)), "TWILIO_ACCOUNT_SID")
        XCTAssertNil(KeyShape.suggestedName(for: "ACCOUNTANT-something-long"))
        XCTAssertNil(KeyShape.suggestedName(for: "short"))
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func makeStore(_ values: [String: String] = [:]) -> (SecretStore, MemoryVault) {
        let vault = MemoryVault(values)
        return (SecretStore(vault: vault, indexURL: nil), vault)
    }

    func testFindsKeysAlreadyInTheVault() {
        let (store, _) = makeStore(["GITHUB_TOKEN": "x", "not valid": "y"])
        XCTAssertEqual(store.records.map(\.name), ["GITHUB_TOKEN"])
    }

    func testAddRenameReplaceDelete() throws {
        let (store, vault) = makeStore()
        try store.add(name: "CF_TOKEN", value: "v1", group: "Site", note: " ")
        XCTAssertEqual(store.record("CF_TOKEN")?.group, "Site")
        XCTAssertNil(store.record("CF_TOKEN")?.note)
        XCTAssertThrowsError(try store.add(name: "CF_TOKEN", value: "v2"))
        XCTAssertThrowsError(try store.add(name: "bad name", value: "v"))
        XCTAssertThrowsError(try store.add(name: "EMPTY", value: ""))

        try store.rename("CF_TOKEN", to: "CLOUDFLARE_API_TOKEN")
        XCTAssertNil(try vault.read("CF_TOKEN"))
        XCTAssertEqual(try store.value("CLOUDFLARE_API_TOKEN"), "v1")
        XCTAssertEqual(store.record("CLOUDFLARE_API_TOKEN")?.group, "Site")

        try store.replaceValue("CLOUDFLARE_API_TOKEN", with: "v2")
        XCTAssertEqual(try store.value("CLOUDFLARE_API_TOKEN"), "v2")

        try store.delete("CLOUDFLARE_API_TOKEN")
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try vault.names().isEmpty)
    }

    func testFolderLimits() {
        var record = SecretRecord(name: "K", createdAt: .now, updatedAt: .now)
        XCTAssertTrue(record.isAvailable(in: "/anywhere"))
        record.projectFolders = ["/tmp/project"]
        let tmp = Storage.canonical("/tmp/project")
        XCTAssertTrue(record.isAvailable(in: tmp))
        XCTAssertTrue(record.isAvailable(in: tmp + "/sub/dir"))
        XCTAssertFalse(record.isAvailable(in: tmp + "-other"))
        XCTAssertFalse(record.isAvailable(in: "/tmp"))
        XCTAssertFalse(record.isAvailable(in: tmp + "/../elsewhere"))
    }
}

@MainActor
final class PolicyTests: XCTestCase {
    var store: SecretStore!
    var log: ActivityLog!
    var policy: BridgePolicy!

    override func setUp() async throws {
        store = SecretStore(vault: MemoryVault(), indexURL: nil)
        log = ActivityLog(url: nil)
        try store.add(name: "GITHUB_TOKEN", value: "ghp_secretvalue123")
        try store.add(name: "STRIPE_SECRET_KEY", value: "sk_test_abcdefgh", projectFolders: ["/tmp/shop"])
        policy = BridgePolicy(store: store, log: log)
    }

    func request(_ names: [String], _ command: String, cwd: String = "/tmp") -> BridgeRequest {
        BridgeRequest(action: .resolve, cwd: Storage.canonical(cwd), names: names, command: command)
    }

    func testListNeverIncludesValues() throws {
        let reply = policy.handle(BridgeRequest(action: .list, cwd: "/tmp"))
        XCTAssertEqual(reply.secrets?.map(\.name), ["GITHUB_TOKEN", "STRIPE_SECRET_KEY"])
        XCTAssertNil(reply.values)
        XCTAssertEqual(reply.secrets?.last?.availableHere, false)
        let data = try JSONEncoder().encode(reply)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ghp_secretvalue123"))
    }

    func testResolvesAndLogs() {
        let reply = policy.handle(request(["GITHUB_TOKEN"], "gh api user"))
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.values?["GITHUB_TOKEN"], "ghp_secretvalue123")
        XCTAssertEqual(log.entries.first?.action, .ran)
        XCTAssertEqual(log.entries.first?.program, "gh")
        XCTAssertEqual(log.entries.first?.source, .claudeCode)

        _ = policy.handle(BridgeRequest(action: .finished, cwd: "/tmp", runID: reply.runID, exitCode: 0, redactions: 2))
        XCTAssertEqual(log.entries.first?.detail, "Exit 0 · 2 copies hidden")
        XCTAssertNotNil(store.record("GITHUB_TOKEN")?.lastUsedAt)
    }

    func testRefusesUnknownKeys() {
        let reply = policy.handle(request(["NOPE"], "echo"))
        XCTAssertFalse(reply.ok)
        XCTAssertNil(reply.values)
        XCTAssertTrue(reply.error?.contains("GITHUB_TOKEN") ?? false)
    }

    func testRefusesOutsideItsFolders() {
        XCTAssertFalse(policy.handle(request(["STRIPE_SECRET_KEY"], "stripe", cwd: "/tmp")).ok)
        XCTAssertTrue(policy.handle(request(["STRIPE_SECRET_KEY"], "stripe", cwd: "/tmp/shop")).ok)
        XCTAssertEqual(log.entries.last?.action, .refused)
    }

    func testApprovalPrompts() {
        let settings = AppSettings()
        let saved = settings.approvalSeconds
        defer { settings.approvalSeconds = saved }   // the test host shares the app's defaults
        let guarded = BridgePolicy(store: store, log: log, settings: settings)
        let use = request(["GITHUB_TOKEN"], "gh api user")

        settings.approvalSeconds = 0
        XCTAssertNil(guarded.approvalPrompt(for: use))

        settings.approvalSeconds = -1
        XCTAssertEqual(guarded.approvalPrompt(for: use), "let Claude Code use GITHUB_TOKEN to run gh")
        guarded.approved()
        XCTAssertNotNil(guarded.approvalPrompt(for: use), "every time means every time")
        XCTAssertNil(guarded.approvalPrompt(for: request(["NOPE"], "x")), "no prompt for a request that'll be refused")
        XCTAssertNil(guarded.approvalPrompt(for: BridgeRequest(action: .list, cwd: "/tmp")))

        settings.approvalSeconds = 900
        XCTAssertNil(guarded.approvalPrompt(for: use), "approved within the last 15 minutes")

        let reply = guarded.declined(use)
        XCTAssertFalse(reply.ok)
        XCTAssertNil(reply.values)
        XCTAssertEqual(log.entries.first?.action, .refused)
    }

    func testOtherClientsAreNamed() {
        var other = request(["GITHUB_TOKEN"], "gh api user")
        other.client = "cursor"
        _ = policy.handle(other)
        XCTAssertEqual(log.entries.first?.source, .other)
        XCTAssertEqual(log.entries.first?.sourceLabel, "By cursor")
    }

    func testRefusesCommandsWithAValueInThem() {
        let reply = policy.handle(request(["GITHUB_TOKEN"], "curl -H 'Authorization: sk_test_abcdefgh'"))
        XCTAssertFalse(reply.ok)
        XCTAssertNil(reply.values)
        XCTAssertTrue(reply.error?.contains("$STRIPE_SECRET_KEY") ?? false)
        XCTAssertFalse(log.entries.first?.detail?.contains("sk_test_abcdefgh") ?? true)
    }
}

@MainActor
final class ConnectorTests: XCTestCase {
    func testReminderIsAddedAndRemovedCleanly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let memory = home.appendingPathComponent(".claude/CLAUDE.md")
        let original = "# My notes\n\nKeep this.\n"
        try original.write(to: memory, atomically: true, encoding: .utf8)

        let connector = ClaudeConnector(home: home, helperPath: "/Applications/KeyBar.app/Contents/Helpers/keybar")
        XCTAssertFalse(connector.hasReminder)
        connector.setReminder(true)
        connector.setReminder(true)   // twice doesn't add it twice
        let added = try String(contentsOf: memory, encoding: .utf8)
        XCTAssertTrue(added.hasPrefix(original))
        XCTAssertEqual(added.components(separatedBy: ClaudeConnector.reminderStart).count, 2)
        XCTAssertTrue(connector.hasReminder)

        connector.setReminder(false)
        XCTAssertEqual(try String(contentsOf: memory, encoding: .utf8), original)
        XCTAssertFalse(connector.hasReminder)
    }

    func testStatusReadsClaudeConfig() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let helper = "/Applications/KeyBar.app/Contents/Helpers/keybar"
        let config: [String: Any] = ["numStartups": 3, "mcpServers": ["keybar": ["type": "stdio", "command": "/old/keybar", "args": ["mcp"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: home.appendingPathComponent(".claude.json"))
        let connector = ClaudeConnector(home: home, helperPath: helper)
        XCTAssertEqual(connector.status, .elsewhere("/old/keybar"))
    }
}

/// Uses the real login keychain, under a test service name, and cleans up
/// after itself. Opt in with KEYCHAIN_TESTS=1 (TEST_RUNNER_KEYCHAIN_TESTS=1 via xcodebuild).
final class KeychainVaultTests: XCTestCase {
    func testRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Set KEYCHAIN_TESTS=1 to use the real Keychain")
        }
        let vault = KeychainVault(service: "KeyBar-tests-\(UUID().uuidString)")
        defer { for name in (try? vault.names()) ?? [] { try? vault.delete(name) } }
        XCTAssertNil(try vault.read("KB_TEST_ONE"))
        try vault.write("KB_TEST_ONE", value: "first")
        try vault.write("KB_TEST_ONE", value: "second ✓")   // updates in place
        try vault.write("KB_TEST_TWO", value: "x")
        XCTAssertEqual(try vault.read("KB_TEST_ONE"), "second ✓")
        XCTAssertEqual(Set(try vault.names()), ["KB_TEST_ONE", "KB_TEST_TWO"])
        try vault.delete("KB_TEST_ONE")
        try vault.delete("KB_TEST_ONE")   // deleting twice is fine
        XCTAssertNil(try vault.read("KB_TEST_ONE"))
        XCTAssertEqual(try vault.names(), ["KB_TEST_TWO"])
    }
}
