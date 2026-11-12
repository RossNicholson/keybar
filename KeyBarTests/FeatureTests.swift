import XCTest
@testable import KeyBar

final class KeyFilesTests: XCTestCase {
    func testWritesPrivateCopiesAndRemovesThem() throws {
        let files = try KeyFiles(values: ["GSC_KEY": "{\"a\": 1}", "PLAIN": "p"], files: ["GSC_KEY": "gsc-key.json"])
        let path = try XCTUnwrap(files.paths["GSC_KEY"])
        XCTAssertTrue(path.hasSuffix("/GSC_KEY/gsc-key.json"), "keeps the file's name, for tools that check it")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{\"a\": 1}")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "only this user can read it")
        let env = files.environment(["GSC_KEY": "{\"a\": 1}", "PLAIN": "p"])
        XCTAssertEqual(env["GSC_KEY"], path)
        XCTAssertEqual(env["PLAIN"], "p")
        files.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testNoFilesNoFolder() throws {
        let files = try KeyFiles(values: ["A": "x"], files: [:])
        XCTAssertNil(files.folder)
    }

    func testFileNameCantEscape() throws {
        let files = try KeyFiles(values: ["K": "x"], files: ["K": "../../evil.json"])
        let path = try XCTUnwrap(files.paths["K"])
        XCTAssertTrue(path.hasSuffix("/K/evil.json"))
        files.remove()
    }

    func testSecretPartsHideTheKeyNotTheWords() {
        let parts = KeyFiles.secretParts(of: Demo.demoServiceAccount)
        XCTAssertTrue(parts.contains("0123456789abcdef0123456789abcdef01234567"), "the private key ID")
        XCTAssertTrue(parts.contains { $0.hasPrefix("MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcw") }, "the private key")
        XCTAssertFalse(parts.contains("service_account"), "ordinary words aren't blanked out")
        XCTAssertFalse(parts.contains { $0.hasPrefix("-----") })
    }
}

final class DestinationTests: XCTestCase {
    func testOnlyPlainNamesPass() {
        XCTAssertNil(Destination(kind: .githubActions, target: "RossNicholson/keybar", secretName: "GH_TOKEN").problem)
        XCTAssertNil(Destination(kind: .cloudflareWorker, target: "contact-form", secretName: "API_KEY").problem)
        XCTAssertNotNil(Destination(kind: .githubActions, target: "-R/evil", secretName: "X").problem, "no flags")
        XCTAssertNotNil(Destination(kind: .githubActions, target: "noslash", secretName: "X").problem)
        XCTAssertNotNil(Destination(kind: .cloudflareWorker, target: "--name", secretName: "X").problem)
        XCTAssertNotNil(Destination(kind: .cloudflarePages, target: "Site", secretName: "X").problem, "Cloudflare names are lower case")
        XCTAssertNotNil(Destination(kind: .githubActions, target: "a/b", secretName: "1BAD").problem)
    }

    func testSamePlaceIgnoresCaseOfRepo() {
        let a = Destination(kind: .githubActions, target: "RossNicholson/Keybar", secretName: "T")
        let b = Destination(kind: .githubActions, target: "rossnicholson/keybar", secretName: "T", sentAt: Date())
        XCTAssertTrue(a.samePlace(as: b))
    }
}

@MainActor
final class NewDetailsTests: XCTestCase {
    func testDetailsSyncWithTheKey() throws {
        let iCloud = MemoryVault()
        let first = SecretStore(vault: LiveVault(thisMac: MemoryVault(), iCloud: iCloud, syncs: true), indexURL: nil)
        try first.add(name: "GSC_KEY", value: "{}", fileName: "gsc.json", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        first.recordSend("GSC_KEY", to: Destination(kind: .githubActions, target: "a/b", secretName: "GSC_KEY"))
        let second = SecretStore(vault: LiveVault(thisMac: MemoryVault(), iCloud: iCloud, syncs: true), indexURL: nil)
        let record = try XCTUnwrap(second.record("GSC_KEY"))
        XCTAssertEqual(record.fileName, "gsc.json")
        XCTAssertEqual(record.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(record.sentTo.map(\.target), ["a/b"])
    }

    func testOldIndexStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keybar-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        {"version":1,"secrets":[{"name":"A_KEY","projectFolders":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}]}
        """.utf8).write(to: url)
        let store = SecretStore(vault: MemoryVault(["A_KEY": "a"]), indexURL: url)
        XCTAssertEqual(store.record("A_KEY")?.createdAt, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"),
                       "1.2 keys load with their dates, not as new keys")
        XCTAssertNil(store.record("A_KEY")?.fileName)
    }

    func testSendingAgainReplacesTheSamePlace() throws {
        let store = SecretStore(vault: MemoryVault(["T": "v"]), indexURL: nil)
        store.recordSend("T", to: Destination(kind: .githubActions, target: "a/b", secretName: "T", sentAt: Date(timeIntervalSince1970: 1)))
        store.recordSend("T", to: Destination(kind: .githubActions, target: "A/B", secretName: "T", sentAt: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(store.record("T")?.sentTo.count, 1)
        XCTAssertEqual(store.record("T")?.sentTo.first?.sentAt, Date(timeIntervalSince1970: 2))
    }

    func testExpiryAndUnused() {
        let now = Date()
        var record = SecretRecord(name: "T", createdAt: now.addingTimeInterval(-200 * 86_400), updatedAt: now)
        XCTAssertNil(KeyHealth.expiryText(record))
        record.expiresAt = Calendar.current.date(byAdding: .day, value: 5, to: now)
        XCTAssertEqual(KeyHealth.expiryText(record), "Expires in 5 days")
        XCTAssertTrue(record.expiresSoon)
        record.expiresAt = Calendar.current.date(byAdding: .day, value: -1, to: now)
        XCTAssertEqual(KeyHealth.expiryText(record), "Expired")
        record.expiresAt = Calendar.current.date(byAdding: .day, value: 60, to: now)
        XCTAssertFalse(record.expiresSoon)

        XCTAssertEqual(KeyHealth.unused([record]).map(\.name), ["T"], "added 200 days ago, never used")
        record.lastUsedAt = now.addingTimeInterval(-86_400)
        XCTAssertTrue(KeyHealth.unused([record]).isEmpty)
        let fresh = SecretRecord(name: "NEW", createdAt: now, updatedAt: now)
        XCTAssertTrue(KeyHealth.unused([fresh]).isEmpty, "a new key isn't unused")
    }

    func testTestableServices() {
        let now = Date()
        XCTAssertTrue(KeyTester.canTest(SecretRecord(name: "GITHUB_TOKEN", createdAt: now, updatedAt: now)))
        XCTAssertTrue(KeyTester.canTest(SecretRecord(name: "CF_ANALYTICS_TOKEN", createdAt: now, updatedAt: now)))
        XCTAssertFalse(KeyTester.canTest(SecretRecord(name: "MY_OWN_SECRET", createdAt: now, updatedAt: now)))
        XCTAssertFalse(KeyTester.canTest(SecretRecord(name: "GITHUB_KEY", createdAt: now, updatedAt: now, fileName: "k.pem")))
    }

    /// A made-up token against GitHub's real API: it must come back refused.
    /// Needs the network, so only with NETWORK_TESTS=1.
    func testRejectedKeyIsReported() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NETWORK_TESTS"] == "1", "set NETWORK_TESTS=1")
        let record = SecretRecord(name: "GITHUB_TOKEN", createdAt: Date(), updatedAt: Date())
        let result = await KeyTester.test(record, value: "github_pat_notarealtoken0000000000000000")
        XCTAssertEqual(result?.outcome, .rejected(401))
    }
}

@MainActor
final class BridgeFeatureTests: XCTestCase {
    func makePolicy() -> (BridgePolicy, SecretStore) {
        let store = SecretStore(vault: MemoryVault(["GSC_KEY": "{\"k\": \"v\"}", "TOKEN": "t-value-123456"]), indexURL: nil)
        var record = store.record("GSC_KEY")!
        record.fileName = "gsc.json"
        store.update(record)
        return (BridgePolicy(store: store, log: ActivityLog(url: nil), settings: AppSettings()), store)
    }

    func testFileKeysAreMarked() {
        let (policy, _) = makePolicy()
        let list = policy.handle(BridgeRequest(action: .list, cwd: "/tmp"))
        XCTAssertEqual(list.secrets?.first { $0.name == "GSC_KEY" }?.fileName, "gsc.json")
        let resolved = policy.handle(BridgeRequest(action: .resolve, cwd: "/tmp", names: ["GSC_KEY", "TOKEN"], command: "cat \"$GSC_KEY\""))
        XCTAssertEqual(resolved.files, ["GSC_KEY": "gsc.json"])
    }

    func testSendAlwaysAsks() {
        let (policy, _) = makePolicy()
        let request = BridgeRequest(action: .send, cwd: "/tmp", names: ["TOKEN"],
                                    destination: Destination(kind: .githubActions, target: "a/b", secretName: "TOKEN"))
        XCTAssertNil(policy.sendProblem(request))
        XCTAssertEqual(policy.approvalPrompt(for: request), "let Claude Code send TOKEN to GitHub · a/b")
        policy.approved(request)
        XCTAssertNotNil(policy.approvalPrompt(for: request), "an earlier yes doesn't cover the next send")
    }

    func testSendRefusesBadRequests() {
        let (policy, store) = makePolicy()
        XCTAssertNotNil(policy.sendProblem(BridgeRequest(action: .send, cwd: "/tmp", names: ["NOPE"],
                                                         destination: Destination(kind: .githubActions, target: "a/b", secretName: "NOPE"))))
        XCTAssertNotNil(policy.sendProblem(BridgeRequest(action: .send, cwd: "/tmp", names: ["TOKEN"],
                                                         destination: Destination(kind: .githubActions, target: "--repo", secretName: "TOKEN"))))
        var record = store.record("TOKEN")!
        record.projectFolders = ["/Users/nobody/shop"]
        store.update(record)
        XCTAssertNotNil(policy.sendProblem(BridgeRequest(action: .send, cwd: "/tmp", names: ["TOKEN"],
                                                         destination: Destination(kind: .githubActions, target: "a/b", secretName: "TOKEN"))),
                        "folder limits apply to sending too")
    }

    func testRequestAnswers() {
        let (policy, store) = makePolicy()
        XCTAssertNil(policy.requestAnswer(BridgeRequest(action: .request, cwd: "/tmp", names: ["NEW_KEY"])), "shows the Add window")
        XCTAssertEqual(policy.requestAnswer(BridgeRequest(action: .request, cwd: "/tmp", names: ["TOKEN"]))?.ok, true, "already stored")
        XCTAssertEqual(policy.requestAnswer(BridgeRequest(action: .request, cwd: "/tmp", names: ["bad name"]))?.ok, false)
        store.setArchived("TOKEN", true)
        XCTAssertEqual(policy.requestAnswer(BridgeRequest(action: .request, cwd: "/tmp", names: ["TOKEN"]))?.ok, false)
    }

    func testAskingOpensOneRequestAtATime() throws {
        let state = Demo.state()
        let request = try XCTUnwrap(state.ask(name: "NEW_TOKEN", reason: "for deploys", client: "Claude Code"))
        XCTAssertNil(state.ask(name: "OTHER", reason: "", client: "Claude Code"))
        try state.add(name: "NEW_TOKEN", value: "v", group: nil, note: nil)
        XCTAssertNil(state.keyRequest, "adding the key answers the request")
        XCTAssertEqual(request.answered.wait(timeout: .now()), .success)
    }
}
