import XCTest
@testable import KeyBar

final class LoginSiteTests: XCTestCase {
    func testNormalisesPastedAddressesAndDomains() throws {
        XCTAssertEqual(try LoginSite.normalise("https://www.LiverpoolFC.com/login?next=/shop#x"), "liverpoolfc.com")
        XCTAssertEqual(try LoginSite.normalise("www.bbc.co.uk"), "bbc.co.uk")
        // www. in front of a shared ending stays, rather than saving the ending
        XCTAssertEqual(try LoginSite.normalise("www.co.uk"), "www.co.uk")
        XCTAssertTrue(LoginSite.matches("accounts.liverpoolfc.com", websites: [try LoginSite.normalise("https://www.liverpoolfc.com/login")]))
        XCTAssertEqual(try LoginSite.normalise("  liverpoolfc.com/ "), "liverpoolfc.com")
        XCTAssertEqual(try LoginSite.normalise("LIVERPOOLFC.COM."), "liverpoolfc.com", "a trailing dot is the same host")
        XCTAssertEqual(try LoginSite.normalise("https://accounts.liverpoolfc.com:443/"), "accounts.liverpoolfc.com")
        XCTAssertEqual(try LoginSite.normalise("http://shop.example.co.uk/basket"), "shop.example.co.uk")
        XCTAssertEqual(try LoginSite.normalise("https://ross@liverpoolfc.com/"), "liverpoolfc.com", "a user name isn't the host")
        XCTAssertEqual(try LoginSite.normalise("https://liverpoolfc.com@evil.io/"), "evil.io", "the host is what follows the @")
        XCTAssertEqual(try LoginSite.normalise("192.168.1.10"), "192.168.1.10")
        // Punycode and the name it stands for are one host
        XCTAssertEqual(try LoginSite.normalise("https://xn--bcher-kva.de"), try LoginSite.normalise("bücher.de"))
    }

    func testRefusesWhatIsNotAWebsite() {
        for text in ["", "   ", "localhost", "com", "not a site", "ftp://files.example.com", "https://", "exa%mple.com", "a..b"] {
            XCTAssertThrowsError(try LoginSite.normalise(text), text)
        }
        XCTAssertThrowsError(try LoginSite.normalise("co.uk")) { XCTAssertEqual($0 as? LoginSite.Problem, .tooBroad("co.uk")) }
        XCTAssertThrowsError(try LoginSite.normalise("https://github.io")) { XCTAssertEqual($0 as? LoginSite.Problem, .tooBroad("github.io")) }
        XCTAssertEqual(try LoginSite.normalise("rossnicholson.github.io"), "rossnicholson.github.io", "a site on a shared host is fine")
    }

    func testListsSplitAndDropDuplicates() throws {
        XCTAssertEqual(try LoginSite.normaliseList("liverpoolfc.com, https://accounts.liverpoolfc.com/login\nLIVERPOOLFC.com"),
                       ["liverpoolfc.com", "accounts.liverpoolfc.com"])
        XCTAssertThrowsError(try LoginSite.normaliseList("liverpoolfc.com, localhost"))
    }

    func testMatchesWholeHostsAndSubdomainsOnly() {
        let sites = ["liverpoolfc.com"]
        func allowed(_ address: String) -> String? {
            LoginSite.allowedHost(frames: [URL(string: address)], websites: sites)
        }
        XCTAssertEqual(allowed("https://liverpoolfc.com/login"), "liverpoolfc.com")
        XCTAssertEqual(allowed("https://accounts.liverpoolfc.com/sign-in"), "accounts.liverpoolfc.com")
        XCTAssertEqual(allowed("https://LIVERPOOLFC.COM./"), "liverpoolfc.com")
        XCTAssertEqual(allowed("https://liverpoolfc.com:443/"), "liverpoolfc.com")
        // Lookalikes
        XCTAssertNil(allowed("https://liverpoolfc.com.evil.io/login"))
        XCTAssertNil(allowed("https://evilliverpoolfc.com/login"))
        XCTAssertNil(allowed("https://liverpoolfc.co/login"))
        XCTAssertNil(allowed("https://liverpoolfc.com@evil.io/"))
        XCTAssertNil(allowed("https://evil.io/liverpoolfc.com"))
        XCTAssertNil(allowed("https://evil.io/?site=https://liverpoolfc.com"))
        XCTAssertNil(allowed("https://xn--liverpoolfc-xyz.com/"))
        // Only https, on its usual port
        XCTAssertNil(allowed("http://liverpoolfc.com/login"))
        XCTAssertNil(allowed("https://liverpoolfc.com:8443/login"))
        XCTAssertNil(allowed("file:///Users/me/liverpoolfc.com.html"))
        XCTAssertNil(allowed("about:blank"))
        XCTAssertNil(LoginSite.allowedHost(frames: [nil], websites: sites), "a frame without an address")
        XCTAssertNil(LoginSite.allowedHost(frames: [URL(string: "https://liverpoolfc.com")], websites: []))
        // An IP address matches only itself
        XCTAssertTrue(LoginSite.matches("10.0.0.1", websites: ["10.0.0.1"]))
        XCTAssertFalse(LoginSite.matches("x.10.0.0.1", websites: ["10.0.0.1"]))
    }

    func testEveryFrameAroundTheFieldMustBeAllowed() {
        let sites = ["liverpoolfc.com"]
        let login = URL(string: "https://accounts.liverpoolfc.com/frame")
        let evil = URL(string: "https://evil.io/")
        XCTAssertEqual(LoginSite.allowedHost(frames: [URL(string: "https://liverpoolfc.com/"), login], websites: sites),
                       "accounts.liverpoolfc.com", "the field's own frame is the host filled")
        XCTAssertNil(LoginSite.allowedHost(frames: [evil, login], websites: sites), "a login frame inside another site's page")
        XCTAssertNil(LoginSite.allowedHost(frames: [URL(string: "https://liverpoolfc.com/"), evil], websites: sites),
                     "another site's frame inside the login page")
        XCTAssertNil(LoginSite.allowedHost(frames: [URL(string: "http://liverpoolfc.com/"), login], websites: sites))
    }

    func testSuggestedNames() {
        XCTAssertEqual(LoginSite.suggestedName(for: "liverpoolfc.com"), "LOGIN_LIVERPOOLFC")
        XCTAssertEqual(LoginSite.suggestedName(for: "https://accounts.liverpoolfc.com/login"), "LOGIN_LIVERPOOLFC")
        XCTAssertEqual(LoginSite.suggestedName(for: "www.bbc.co.uk"), "LOGIN_BBC")
        XCTAssertEqual(LoginSite.suggestedName(for: "the-internet.herokuapp.com"), "LOGIN_THE_INTERNET")
        XCTAssertEqual(LoginSite.suggestedName(for: "my.1password.com"), "LOGIN_1PASSWORD")
        XCTAssertTrue(SecretName.isValid(LoginSite.suggestedName(for: "192.168.1.1")))
    }
}

final class PasswordGeneratorTests: XCTestCase {
    func testStrongAndVaried() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let password = PasswordGenerator.make()
            XCTAssertEqual(password.count, PasswordGenerator.defaultLength)
            XCTAssertTrue(password.allSatisfy(PasswordGenerator.allowed.contains), password)
            XCTAssertTrue(password.contains(where: PasswordGenerator.lower.contains))
            XCTAssertTrue(password.contains(where: PasswordGenerator.upper.contains))
            XCTAssertTrue(password.contains(where: PasswordGenerator.digits.contains))
            XCTAssertTrue(password.contains(where: PasswordGenerator.symbols.contains))
            XCTAssertFalse(password.contains { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "\\" })
            seen.insert(password)
        }
        XCTAssertEqual(seen.count, 200, "never the same twice")
        XCTAssertEqual(PasswordGenerator.make(length: 2).count, 4, "always room for one of each kind")
        XCTAssertEqual(PasswordGenerator.make(length: 32).count, 32)
    }
}

final class FillRuleTests: XCTestCase {
    func candidate(_ focused: Bool, main: Bool = true, front: Bool = false, browser: String = "Safari") -> FillCandidate {
        FillCandidate(browser: browser, host: "liverpoolfc.com", focused: focused, inMainWindow: main, inFrontApp: front)
    }

    func testChoosesTheField() {
        XCTAssertEqual(FillChoice.choose([]), .none)
        XCTAssertEqual(FillChoice.choose([candidate(false)]), .fill(0, needsFocus: true), "a lone field gets the cursor")
        XCTAssertEqual(FillChoice.choose([candidate(false), candidate(true)]), .fill(1, needsFocus: false), "the focused one wins")
        XCTAssertEqual(FillChoice.choose([candidate(false), candidate(false)]), .several(2), "nobody guesses")
        XCTAssertEqual(FillChoice.choose([candidate(true, front: false), candidate(true, front: true, browser: "Chrome")]),
                       .fill(1, needsFocus: false), "focused in two browsers: the one in front")
        XCTAssertEqual(FillChoice.choose([candidate(true, main: false), candidate(true, main: true)]),
                       .fill(1, needsFocus: false), "focused in two windows: the front window")
        XCTAssertEqual(FillChoice.choose([candidate(true), candidate(true)]), .several(2))
    }

    func testTyping() {
        XCTAssertEqual(FillTyping.split("SuperSecretPassword!")?.head, "SuperSecretPassword")
        XCTAssertEqual(FillTyping.split("SuperSecretPassword!")?.last, "!")
        XCTAssertEqual(FillTyping.split("x")?.head, "", "one character is all typed")
        XCTAssertNil(FillTyping.split(""))
        // A last character that's a surrogate pair or a cluster goes whole
        XCTAssertEqual(FillTyping.split("pass🔑")?.last, "🔑")
        XCTAssertEqual(FillTyping.split("pass👍🏽")?.last, "👍🏽")
        XCTAssertEqual(FillTyping.split("café")?.last, "é")

        XCTAssertTrue(FillTyping.holdsWhole(20, of: "SuperSecretPassword!"))
        XCTAssertFalse(FillTyping.holdsWhole(19, of: "SuperSecretPassword!"))
        XCTAssertFalse(FillTyping.holdsWhole(0, of: "x"))
        XCTAssertTrue(FillTyping.holdsWhole("pass🔑".utf16.count, of: "pass🔑"))
    }

    func testProblemsNeverHoldThePassword() {
        let problems: [FillProblem] = [.notTrusted, .noBrowser, .noPage(["liverpoolfc.com"]), .noField(host: "liverpoolfc.com", browser: "Safari"),
                                       .several(2), .couldNotFocus(host: "a.com", browser: "Chrome"), .notFrontWindow(host: "a.com", browser: "Arc"),
                                       .pageChanged(host: "a.com", browser: "Safari"), .notTaken(host: "a.com", browser: "Safari")]
        for problem in problems { XCTAssertFalse(problem.message.isEmpty) }
        XCTAssertTrue(FillProblem.notTrusted.message.contains("Accessibility"))
        XCTAssertEqual(FillProblem.noField(host: "liverpoolfc.com", browser: "Safari").site, "liverpoolfc.com")
        XCTAssertEqual(FillProblem.noField(host: "liverpoolfc.com", browser: "Safari").browser, "Safari")
        XCTAssertTrue(FillBrowser.all.contains { $0.bundleIDs.contains("com.apple.Safari") && !$0.chromium })
        XCTAssertTrue(FillBrowser.all.contains { $0.bundleIDs.contains("com.google.Chrome") && $0.chromium })
        XCTAssertFalse(FillBrowser.all.contains { $0.name.contains("Firefox") })
    }
}

@MainActor
final class PasswordStoreTests: XCTestCase {
    func makeStore() -> SecretStore { SecretStore(vault: MemoryVault(), indexURL: nil) }

    func testAddingAPassword() throws {
        let store = makeStore()
        try store.add(name: "LOGIN_LIVERPOOLFC", value: "pw with spaces ", login: ("ross@example.com", ["liverpoolfc.com"]))
        let record = try XCTUnwrap(store.record("LOGIN_LIVERPOOLFC"))
        XCTAssertTrue(record.isPassword)
        XCTAssertEqual(record.username, "ross@example.com")
        XCTAssertEqual(record.sites, ["liverpoolfc.com"])
        XCTAssertEqual(record.kind, "Password")
        XCTAssertNil(record.service, "never a service, whatever its name says")
        XCTAssertEqual(record.displayGroup, "Passwords")
        XCTAssertEqual(record.loginSummary, "liverpoolfc.com · ross@example.com")
        XCTAssertEqual(try store.value("LOGIN_LIVERPOOLFC"), "pw with spaces ", "kept exactly")
        XCTAssertEqual(store.activePasswords.map(\.name), ["LOGIN_LIVERPOOLFC"])
        XCTAssertEqual(store.passwords(for: "https://accounts.liverpoolfc.com/x").map(\.name), ["LOGIN_LIVERPOOLFC"])
        XCTAssertTrue(store.passwords(for: "liverpoolfc.com.evil.io").isEmpty)
        XCTAssertEqual(store.search("ross@").map(\.name), ["LOGIN_LIVERPOOLFC"], "found by user name")
        XCTAssertEqual(store.search("liverpool").map(\.name), ["LOGIN_LIVERPOOLFC"], "and by website")
        XCTAssertEqual(store.suggestedPasswordName(for: "liverpoolfc.com"), "LOGIN_LIVERPOOLFC_2", "a free name")

        XCTAssertThrowsError(try store.add(name: "LOGIN_X", value: "v", login: (nil, []))) {
            XCTAssertEqual($0.localizedDescription, StoreError.noWebsite.localizedDescription)
        }
    }

    func testKeysAndPasswordsNeverReplaceEachOther() throws {
        let store = makeStore()
        try store.add(name: "LOGIN_SHOP", value: "pw", login: (nil, ["shop.example.com"]))
        try store.add(name: "SHOP_TOKEN", value: "tok")
        // .env import replaces keys of the same name; never a password
        XCTAssertThrowsError(try store.add(name: "LOGIN_SHOP", value: "from .env", replacing: true))
        XCTAssertThrowsError(try store.add(name: "SHOP_TOKEN", value: "pw", login: (nil, ["shop.example.com"]), replacing: true))
        XCTAssertEqual(try store.value("LOGIN_SHOP"), "pw")

        // Editing details can't change the type, nor leave a password without a website
        var record = try XCTUnwrap(store.record("LOGIN_SHOP"))
        record.type = nil
        record.websites = []
        store.update(record)
        XCTAssertEqual(store.record("LOGIN_SHOP")?.isPassword, true)
        XCTAssertEqual(store.record("LOGIN_SHOP")?.sites, ["shop.example.com"])
    }

    func testOldIndexDecodesAsKeysAndNewOneKeepsPasswords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        // Written by KeyBar 1.4.8, before passwords
        let old = #"{"secrets":[{"approval":"everyTime","createdAt":"2026-11-11T22:25:55Z","name":"GH_TOKEN","projectFolders":["/Users/me/site"],"proxied":true,"updatedAt":"2026-11-11T22:25:55Z"}],"version":1}"#
        try Data(old.utf8).write(to: url)
        let vault = MemoryVault(["GH_TOKEN": "x"])
        let store = SecretStore(vault: vault, indexURL: url)
        XCTAssertNil(store.lastError)
        let key = try XCTUnwrap(store.record("GH_TOKEN"))
        XCTAssertNil(key.type)
        XCTAssertFalse(key.isPassword)
        XCTAssertEqual(key.secretType, .apiKey)
        XCTAssertEqual(key.approval, .everyTime)
        XCTAssertEqual(key.projectFolders, ["/Users/me/site"])

        try store.add(name: "LOGIN_SITE", value: "pw", login: ("me", ["site.example.com"]))
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("\"pw\""), "values never go in the index")
        XCTAssertEqual(saved.components(separatedBy: "\"type\"").count, 2, "only the password has a type")
        let reloaded = SecretStore(vault: vault, indexURL: url)
        XCTAssertEqual(reloaded.record("LOGIN_SITE")?.isPassword, true)
        XCTAssertEqual(reloaded.record("LOGIN_SITE")?.username, "me")
        XCTAssertEqual(reloaded.record("LOGIN_SITE")?.sites, ["site.example.com"])
        XCTAssertEqual(reloaded.record("GH_TOKEN")?.isPassword, false)
    }

    func testSyncedDetailsCarryPasswordsBothWays() throws {
        var record = SecretRecord(name: "LOGIN_LIVERPOOLFC", group: "Football", createdAt: Date(timeIntervalSince1970: 1_000),
                                  updatedAt: Date(timeIntervalSince1970: 2_000), type: .password, username: "ross",
                                  websites: ["liverpoolfc.com", "accounts.liverpoolfc.com"])
        let data = try XCTUnwrap(SyncedDetails(record).encoded)
        let decoded = try XCTUnwrap(SyncedDetails.decode(data))
        XCTAssertEqual(decoded, SyncedDetails(record))
        var onAnotherMac = SecretRecord(name: "LOGIN_LIVERPOOLFC", createdAt: .now, updatedAt: .now)
        decoded.apply(to: &onAnotherMac)
        XCTAssertTrue(onAnotherMac.isPassword)
        XCTAssertEqual(onAnotherMac.username, "ross")
        XCTAssertEqual(onAnotherMac.sites, ["liverpoolfc.com", "accounts.liverpoolfc.com"])
        XCTAssertEqual(onAnotherMac.group, "Football")

        // An older KeyBar's details (no type) decode, and an API key's stay a key
        let old = #"{"createdAt":"2026-11-11T22:25:55Z","group":"Site","projectFolders":[],"updatedAt":"2026-11-11T22:25:55Z"}"#
        let oldDetails = try XCTUnwrap(SyncedDetails.decode(Data(old.utf8)))
        var key = SecretRecord(name: "GH_TOKEN", createdAt: .now, updatedAt: .now)
        oldDetails.apply(to: &key)
        XCTAssertFalse(key.isPassword)
        XCTAssertEqual(key.group, "Site")
        // …and an older KeyBar saving a password's details can't turn it into a key
        oldDetails.apply(to: &record)
        XCTAssertTrue(record.isPassword)
        XCTAssertEqual(record.sites, ["liverpoolfc.com", "accounts.liverpoolfc.com"])
        XCTAssertEqual(record.group, "Site", "the rest of the details still apply")

        // What an older KeyBar reads: the same keys it knows, the rest ignored
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "password")
        XCTAssertNotNil(json["createdAt"])
        XCTAssertNotNil(json["projectFolders"])
    }

    func testPasswordsSyncThroughICloud() throws {
        let iCloud = MemoryVault()
        let first = SecretStore(vault: LiveVault(thisMac: MemoryVault(), iCloud: iCloud, syncs: true), indexURL: nil)
        try first.add(name: "LOGIN_SHOP", value: "pw", login: ("me@example.com", ["shop.example.com"]))
        let second = SecretStore(vault: LiveVault(thisMac: MemoryVault(), iCloud: iCloud, syncs: true), indexURL: nil)
        let seen = try XCTUnwrap(second.record("LOGIN_SHOP"))
        XCTAssertTrue(seen.isPassword)
        XCTAssertEqual(seen.username, "me@example.com")
        XCTAssertEqual(seen.sites, ["shop.example.com"])
    }

    func testPasswordsAreNeverTestedProxiedOrSkippedByLeakChecks() throws {
        let store = makeStore()
        try store.add(name: "GITHUB_TOKEN", value: "ghp_aaaaaaaaaaaaaaaaaaaa", login: (nil, ["github.com"]))
        try store.add(name: "ANTHROPIC_API_KEY", value: "pw-0123456789abcdef", login: (nil, ["console.anthropic.com"]))
        try store.add(name: "LOGIN_ACCOUNT_ID", value: "a-long-password-123", login: (nil, ["example.com"]))
        XCTAssertFalse(KeyTester.canTest(try XCTUnwrap(store.record("GITHUB_TOKEN"))), "a password named like a token isn't sent to GitHub")
        XCTAssertNil(KeyProxy.route(for: try XCTUnwrap(store.record("ANTHROPIC_API_KEY"))))
        let record = try XCTUnwrap(store.record("LOGIN_ACCOUNT_ID"))
        XCTAssertEqual(Needles.of(record, value: "a-long-password-123"), ["a-long-password-123"],
                       "watched for leaks even with a name that sounds like an ID")
    }
}

@MainActor
final class PasswordPolicyTests: XCTestCase {
    var store: SecretStore!
    var log: ActivityLog!
    var settings: AppSettings!
    var trusted = true
    var savedApproval: TimeInterval = 0

    override func setUp() async throws {
        store = SecretStore(vault: MemoryVault(), indexURL: nil)
        log = ActivityLog(url: nil)
        settings = AppSettings()
        // The test host shares the app's defaults: put this back afterwards
        savedApproval = settings.approvalSeconds
        settings.approvalSeconds = 900
        try store.add(name: "GITHUB_TOKEN", value: "ghp_secretvalue1234567")
        try store.add(name: "LOGIN_LIVERPOOLFC", value: "Kop-pass-word-99", login: ("ross@example.com", ["liverpoolfc.com"]))
    }

    override func tearDown() async throws {
        settings.approvalSeconds = savedApproval
    }

    func policy() -> BridgePolicy {
        BridgePolicy(store: store, log: log, settings: settings, accessibility: { [unowned self] in trusted })
    }

    func fill(_ name: String, site: String? = nil, cwd: String = "/tmp") -> BridgeRequest {
        BridgeRequest(action: .fill, cwd: cwd, projectFolder: cwd, names: [name], site: site)
    }

    func testRunWithSecretsRefusesPasswords() {
        let policy = policy()
        let reply = policy.handle(BridgeRequest(action: .resolve, cwd: "/tmp", projectFolder: "/tmp",
                                                names: ["LOGIN_LIVERPOOLFC", "GITHUB_TOKEN"], command: "curl -u ross:$LOGIN_LIVERPOOLFC x"))
        XCTAssertFalse(reply.ok)
        XCTAssertNil(reply.values, "no value of either goes back")
        XCTAssertTrue(reply.error?.contains("fill_password") == true, reply.error ?? "")
        XCTAssertFalse(reply.error?.contains("Kop-pass-word-99") == true)
        XCTAssertEqual(log.entries.first?.action, .refused)
        XCTAssertNil(policy.approvalPrompt(for: BridgeRequest(action: .resolve, cwd: "/tmp", names: ["LOGIN_LIVERPOOLFC"], command: "x")),
                     "no Touch ID for something that'll be refused")

        var terminal = BridgeRequest(action: .resolve, cwd: "/tmp", client: Bridge.terminalClient, names: ["LOGIN_LIVERPOOLFC"], command: "x")
        terminal.terminal = "/dev/ttys001"
        XCTAssertFalse(policy.handle(terminal).ok, "keybar run can't have one either")

        let send = BridgeRequest(action: .send, cwd: "/tmp", names: ["LOGIN_LIVERPOOLFC"],
                                 destination: Destination(kind: .githubActions, target: "me/site", secretName: "PW"))
        XCTAssertTrue(policy.sendProblem(send)?.contains("never sends passwords") == true)
        XCTAssertNil(policy.approvalPrompt(for: send))

        // A command with the password written into it is refused like a key's
        let literal = policy.handle(BridgeRequest(action: .resolve, cwd: "/tmp", names: ["GITHUB_TOKEN"], command: "echo Kop-pass-word-99"))
        XCTAssertFalse(literal.ok)
    }

    func testSendingAPasswordFromTheAppIsRefusedToo() async {
        let state = AppState(store: store, log: log, claude: ClaudeConnector())
        state.isDemo = true
        let result = await state.sendConfirmed("LOGIN_LIVERPOOLFC", to: Destination(kind: .githubActions, target: "me/site", secretName: "PW"),
                                               source: .you)
        guard case .failure(let error) = result else { return XCTFail("sent a password") }
        XCTAssertTrue(error.localizedDescription.contains("never sends passwords"))
    }

    func testFillRefusals() throws {
        let policy = policy()
        XCTAssertNil(policy.fillProblem(fill("LOGIN_LIVERPOOLFC")))
        XCTAssertTrue(policy.fillProblem(fill("GITHUB_TOKEN"))?.contains("API key, not a website password") == true)
        XCTAssertTrue(policy.fillProblem(fill("NOPE"))?.contains("Stored passwords: LOGIN_LIVERPOOLFC") == true)
        XCTAssertNotNil(policy.fillProblem(BridgeRequest(action: .fill, cwd: "/tmp", names: ["LOGIN_LIVERPOOLFC", "GITHUB_TOKEN"])))
        // A site hint must be one of its websites
        XCTAssertNil(policy.fillProblem(fill("LOGIN_LIVERPOOLFC", site: "accounts.liverpoolfc.com")))
        XCTAssertTrue(policy.fillProblem(fill("LOGIN_LIVERPOOLFC", site: "liverpoolfc.com.evil.io"))?.contains("isn't one of") == true)

        trusted = false
        XCTAssertTrue(policy.fillProblem(fill("LOGIN_LIVERPOOLFC"))?.contains("Accessibility") == true, "not allowed yet: a clear error")
        trusted = true

        store.setArchived("LOGIN_LIVERPOOLFC", true)
        XCTAssertTrue(policy.fillProblem(fill("LOGIN_LIVERPOOLFC"))?.contains("archived") == true)
        store.setArchived("LOGIN_LIVERPOOLFC", false)

        var record = try XCTUnwrap(store.record("LOGIN_LIVERPOOLFC"))
        record.projectFolders = ["/Users/me/football"]
        store.update(record)
        XCTAssertTrue(policy.fillProblem(fill("LOGIN_LIVERPOOLFC", cwd: "/tmp"))?.contains("can only be used in") == true)
        XCTAssertNil(policy.fillProblem(fill("LOGIN_LIVERPOOLFC", cwd: "/Users/me/football/site")))
    }

    func testProjectListsApplyToPasswords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keybar-pw-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("GITHUB_TOKEN\n".utf8).write(to: folder.appendingPathComponent(".keybar"))
        let policy = policy()
        XCTAssertTrue(policy.fillProblem(fill("LOGIN_LIVERPOOLFC", cwd: folder.path))?.contains(".keybar") == true)
        XCTAssertEqual(policy.handle(BridgeRequest(action: .list, cwd: folder.path, projectFolder: folder.path)).secrets?.map(\.name),
                       ["GITHUB_TOKEN"])
    }

    func testFillLogAndTouchID() throws {
        let policy = policy()
        let request = fill("LOGIN_LIVERPOOLFC")
        let prompt = try XCTUnwrap(policy.fillPrompt(request, site: "accounts.liverpoolfc.com", browser: "Safari"))
        XCTAssertEqual(prompt, "let Claude Code fill your password for accounts.liverpoolfc.com in Safari (LOGIN_LIVERPOOLFC)")
        policy.approvedFill(request, site: "accounts.liverpoolfc.com")
        XCTAssertNil(policy.fillPrompt(request, site: "accounts.liverpoolfc.com", browser: "Safari"), "one yes lasts, as for keys")
        XCTAssertNotNil(policy.fillPrompt(request, site: "liverpoolfc.com", browser: "Safari"), "but only for that site")
        XCTAssertNotNil(policy.approvalPrompt(for: BridgeRequest(action: .resolve, cwd: "/tmp", projectFolder: "/tmp",
                                                                 names: ["GITHUB_TOKEN"], command: "gh api user")))

        // The password's own rule wins, as for keys
        var record = try XCTUnwrap(store.record("LOGIN_LIVERPOOLFC"))
        record.approval = .everyTime
        store.update(record)
        XCTAssertNotNil(policy.fillPrompt(request, site: "accounts.liverpoolfc.com", browser: "Safari"))
        record.approval = .never
        store.update(record)
        XCTAssertNil(policy.fillPrompt(request, site: "accounts.liverpoolfc.com", browser: "Safari"))
        settings.approvalSeconds = 0
        record.approval = nil
        store.update(record)
        XCTAssertNil(policy.fillPrompt(request, site: "liverpoolfc.com", browser: "Safari"), "Settings says never")

        XCTAssertEqual(policy.websites(for: request), ["liverpoolfc.com"])
        guard case .success(let value) = policy.passwordValue(request) else { return XCTFail() }
        XCTAssertEqual(value, "Kop-pass-word-99")
        guard case .failure = policy.passwordValue(fill("GITHUB_TOKEN")) else { return XCTFail("an API key's value for a fill") }

        XCTAssertNil(store.record("LOGIN_LIVERPOOLFC")?.lastUsedAt)
        let done = policy.filled(request, site: "accounts.liverpoolfc.com", browser: "Safari")
        XCTAssertTrue(done.ok)
        XCTAssertNil(done.values)
        XCTAssertTrue(done.message?.contains("accounts.liverpoolfc.com in Safari") == true)
        XCTAssertNotNil(store.record("LOGIN_LIVERPOOLFC")?.lastUsedAt)
        XCTAssertEqual(log.entries.first?.action, .filled)
        XCTAssertEqual(log.entries.first?.summary, "Filled")
        XCTAssertEqual(log.entries.first?.detail, "accounts.liverpoolfc.com in Safari")

        var cursor = request
        cursor.client = "Cursor"
        _ = policy.refuseFill(cursor, FillProblem.noPage(["liverpoolfc.com"]).message)
        XCTAssertEqual(log.entries.first?.summary, "Refused to fill")
        XCTAssertEqual(log.entries.first?.client, "Cursor")
        _ = policy.declinedFill(request, site: "liverpoolfc.com", browser: "Chrome")
        XCTAssertTrue(log.entries.first?.detail?.hasPrefix("liverpoolfc.com in Chrome") == true)
        for entry in log.entries {
            XCTAssertFalse([entry.detail, entry.program, entry.folder].compactMap { $0 }.joined().contains("Kop-pass-word-99"))
        }
    }

    func testListAndListing() throws {
        let reply = policy().handle(BridgeRequest(action: .list, cwd: "/tmp"))
        let password = try XCTUnwrap(reply.secrets?.first { $0.name == "LOGIN_LIVERPOOLFC" })
        XCTAssertEqual(password.isPassword, true)
        XCTAssertEqual(password.username, "ross@example.com")
        XCTAssertEqual(password.websites, ["liverpoolfc.com"])
        XCTAssertNil(reply.secrets?.first { $0.name == "GITHUB_TOKEN" }?.isPassword)
        XCTAssertNil(reply.values)

        let text = SecretListing.text(reply.secrets ?? [])
        XCTAssertEqual(text, """
        Keys stored in KeyBar (use them with run_with_secrets, as "$NAME"):
        - GITHUB_TOKEN: GitHub token

        Website passwords (fill one into its login page with fill_password; they can't be used in commands):
        - LOGIN_LIVERPOOLFC: password for liverpoolfc.com, username ross@example.com
        """)
        XCTAssertFalse(text.contains("Kop-pass-word-99"))
        XCTAssertEqual(SecretListing.text([]), SecretListing.empty)
        let onlyPasswords = SecretListing.text([password])
        XCTAssertTrue(onlyPasswords.hasPrefix("Website passwords"), onlyPasswords)
    }

    func testAskingForAPassword() throws {
        let policy = policy()
        func ask(_ site: String?, name: String? = nil) -> BridgeRequest {
            BridgeRequest(action: .request, cwd: "/tmp", names: name.map { [$0] } ?? [], reason: "to log in", site: site, secretType: .password)
        }
        XCTAssertNil(policy.requestAnswer(ask("shop.example.com")), "shows the Add window")
        XCTAssertEqual(policy.requestAnswer(ask(nil))?.ok, false, "needs a website")
        XCTAssertEqual(policy.requestAnswer(ask("localhost"))?.ok, false)
        let existing = try XCTUnwrap(policy.requestAnswer(ask("https://accounts.liverpoolfc.com/login")))
        XCTAssertTrue(existing.ok)
        XCTAssertTrue(existing.message?.contains("LOGIN_LIVERPOOLFC") == true)
        XCTAssertEqual(policy.requestAnswer(ask("shop.example.com", name: "GITHUB_TOKEN"))?.ok, false, "that name's an API key")
        XCTAssertTrue(policy.requestAnswer(BridgeRequest(action: .request, cwd: "/tmp", names: ["LOGIN_LIVERPOOLFC"]))?
            .message?.contains("fill_password") == true, "a key request that names a password")

        let state = AppState(store: store, log: log, claude: ClaudeConnector())
        let request = try XCTUnwrap(state.ask(name: store.suggestedPasswordName(for: "shop.example.com"), reason: "", client: "Claude Code",
                                              login: ("shop.example.com", "me")))
        XCTAssertTrue(request.isPassword)
        XCTAssertEqual(request.name, "LOGIN_EXAMPLE")
        try state.add(name: "LOGIN_EXAMPLE", value: "pw", group: nil, note: nil, login: ("me", ["shop.example.com"]))
        XCTAssertNil(state.keyRequest, "adding the password answers the request")
        XCTAssertEqual(request.added, "LOGIN_EXAMPLE")
    }
}

@MainActor
final class PasswordConnectTests: XCTestCase {
    func testToolsAndInstructionsExplainFilling() throws {
        let names = MCPCatalog.toolNames
        for tool in ["list_secrets", "run_with_secrets", "fill_password", "request_secret", "send_secret"] {
            XCTAssertTrue(names.contains(tool), tool)
        }
        XCTAssertEqual(Set(names).count, names.count)
        let fill = try XCTUnwrap(MCPCatalog.tools.first { $0["name"] as? String == "fill_password" })
        let schema = try XCTUnwrap(fill["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["name"])
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["site"])
        let request = try XCTUnwrap(MCPCatalog.tools.first { $0["name"] as? String == "request_secret" })
        let requestProperties = try XCTUnwrap((request["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertNotNil(requestProperties["website"])
        XCTAssertEqual((requestProperties["type"] as? [String: Any])?["enum"] as? [String], ["apiKey", "password"])
        XCTAssertTrue(MCPCatalog.instructions.contains("fill_password"))
        XCTAssertTrue(ClaudeConnector.reminder.contains("fill_password"))
        // The tools list is valid JSON, as it's sent
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["tools": MCPCatalog.tools]))
    }

    func testAnOlderNoteIsUpdatedInPlace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("keybar-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = "/Applications/KeyBar.app/Contents/Helpers/keybar"
        let config = #"{"mcpServers":{"keybar":{"type":"stdio","command":"\#(helper)","args":["mcp"]}}}"#
        try Data(config.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let oldNote = "\(ClaudeConnector.reminderStart)\n## API keys (KeyBar)\nOld words.\n\(ClaudeConnector.reminderEnd)"
        let memory = home.appendingPathComponent(".claude/CLAUDE.md")
        try Data("# Mine\n\n\(oldNote)\n\n## After\nKeep me.\n".utf8).write(to: memory)

        let elsewhere = ClaudeConnector(home: home, helperPath: "/tmp/build/KeyBar.app/Contents/Helpers/keybar")
        elsewhere.updateReminderIfOutdated()
        XCTAssertTrue(try String(contentsOf: memory, encoding: .utf8).contains("Old words."), "a copy that isn't connected leaves it")

        let connector = ClaudeConnector(home: home, helperPath: helper)
        XCTAssertEqual(connector.status, .connected)
        XCTAssertTrue(connector.reminderIsOutdated)
        connector.updateReminderIfOutdated()
        let text = try String(contentsOf: memory, encoding: .utf8)
        XCTAssertEqual(text, "# Mine\n\n\(ClaudeConnector.reminder)\n\n## After\nKeep me.\n")
        XCTAssertFalse(connector.reminderIsOutdated)
    }
}
