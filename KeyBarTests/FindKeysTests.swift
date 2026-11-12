import XCTest
@testable import KeyBar

final class ScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("keybar-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func scan(shell: Bool = false, claude: Bool = false, tools: Bool = false) -> [FoundKey] {
        let home = root.appendingPathComponent("home")
        return KeyScanner(home: home, places: .init(folders: [root.appendingPathComponent("Dev")], shellProfiles: shell,
                                                    claudeCode: claude, toolCredentials: tools)).scan()
    }

    func testFindsEnvFilesButNotDependenciesOrExamples() throws {
        try write("STRIPE_SECRET_KEY=sk_live_abcdefghijklmnop\nPORT=3000\nNODE_ENV=production\n", to: "Dev/Shop/.env")
        try write("OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv\n", to: "Dev/Shop/web/.env.local")
        try write("STRIPE_SECRET_KEY=sk_live_realvaluefromexample\n", to: "Dev/Shop/.env.example")
        try write("NPM_TOKEN=npm_abcdefghijklmnopqrstuvwx\n", to: "Dev/Shop/node_modules/pkg/.env")
        try write("GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz\n", to: "Dev/Shop/.git/.env")
        try write("SECRET=hunter22hunter22\n", to: "Dev/Shop/build/.env")

        let found = scan()
        XCTAssertEqual(Set(found.map(\.name)), ["STRIPE_SECRET_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(found.first { $0.name == "STRIPE_SECRET_KEY" }?.source.project, "Shop")
        XCTAssertEqual(found.first { $0.name == "OPENAI_API_KEY" }?.source.project, "Shop/web")
        XCTAssertEqual(found.first { $0.name == "OPENAI_API_KEY" }?.source.label, "Shop/web/.env.local")
    }

    func testReadsShellClaudeAwsAndNpm() throws {
        try write("export PATH=$HOME/bin:$PATH\nexport ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnop\nalias ll='ls -l'\n",
                  to: "home/.zshrc")
        try write(#"{"mcpServers":{"linear":{"command":"x","env":{"LINEAR_API_KEY":"lin_api_abcdefghijklmnop"}}},"projects":{"/p":{"mcpServers":{"s":{"env":{"SENTRY_AUTH_TOKEN":"sntrys_abcdefghijklmnop","DEBUG":"true"}}}}}}"#,
                  to: "home/.claude.json")
        try write("[default]\naws_access_key_id = AKIAABCDEFGHIJKLMNOP\naws_secret_access_key = abcdEFGHijklMNOPqrstUVWXyz0123456789abcd\n[work]\naws_access_key_id=AKIAWORKWORKWORKWORK\n",
                  to: "home/.aws/credentials")
        try write("//registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwx\n//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}\n",
                  to: "home/.npmrc")

        let names = Set(scan(shell: true, claude: true, tools: true).map(\.name))
        XCTAssertEqual(names, ["ANTHROPIC_API_KEY", "LINEAR_API_KEY", "SENTRY_AUTH_TOKEN", "AWS_ACCESS_KEY_ID",
                               "AWS_SECRET_ACCESS_KEY", "WORK_AWS_ACCESS_KEY_ID", "NPM_TOKEN"])
    }

    func testWhatLooksLikeAKey() {
        XCTAssertTrue(KeyScanner.looksSecret(name: "STRIPE_SECRET_KEY", value: "sk_live_abcdefghijk"))
        XCTAssertTrue(KeyScanner.looksSecret(name: "WHATEVER", value: "ghp_abcdefghijklmnopqrst"), "a known key shape")
        XCTAssertTrue(KeyScanner.looksSecret(name: "DATABASE_URL", value: "postgres://app:s3cretpass@db.internal/app"))
        XCTAssertTrue(KeyScanner.looksSecret(name: "REDIS_URL", value: "redis://default:s3cretpass@cache:6379"))
        XCTAssertTrue(KeyScanner.looksSecret(name: "SESSION_SECRET", value: "f9a8b7c6d5e4f3a2b1"))

        XCTAssertFalse(KeyScanner.looksSecret(name: "DATABASE_URL", value: "postgres://localhost/app"), "no password")
        XCTAssertFalse(KeyScanner.looksSecret(name: "API_KEY", value: "your-api-key-here"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "API_KEY", value: "<paste your key>"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "API_KEY", value: "${OTHER_KEY}"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "API_KEY", value: "keybar:API_KEY"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "TOKEN", value: "short"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "STRIPE_PUBLISHABLE_KEY", value: "abcdefghijklmnop"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "NEXT_PUBLIC_SUPABASE_KEY", value: "abcdefghijklmnopqrst"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "CLOUDFLARE_ACCOUNT_ID", value: "0123456789abcdef0123"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "SECRET_FILE", value: "/etc/secrets/app"))
        XCTAssertFalse(KeyScanner.looksSecret(name: "PORT", value: "300000000"))
    }

    /// Set SCAN_DIR to time a scan of a real folder. Prints names and where
    /// they were found, never values.
    func testScanARealFolder() throws {
        guard let dir = ProcessInfo.processInfo.environment["SCAN_DIR"] else { throw XCTSkip("Set SCAN_DIR") }
        let start = Date()
        let everywhere = ProcessInfo.processInfo.environment["SCAN_ALL"] != nil
        let found = KeyScanner(places: .init(folders: [URL(fileURLWithPath: dir)], shellProfiles: everywhere,
                                             claudeCode: everywhere, toolCredentials: everywhere)).scan()
        print("SCAN: \(found.count) found in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        for key in found { print("SCAN: \(key.name) · \(key.source.label)") }
    }

    func testEnvFileNames() {
        for name in [".env", ".env.local", ".env.production", "production.env", ".envrc"] {
            XCTAssertTrue(KeyScanner.isEnvFile(name), name)
        }
        for name in [".env.example", ".env.sample", ".env.template", "env.dist", ".environment", "README.md"] {
            XCTAssertFalse(KeyScanner.isEnvFile(name), name)
        }
    }
}

final class ScanPlanTests: XCTestCase {
    func key(_ name: String, _ value: String, _ project: String?, kind: KeySource.Kind = .envFile) -> FoundKey {
        FoundKey(name: name, value: value,
                 source: KeySource(kind: kind, path: "/dev/\(project ?? "home")/.env", project: project))
    }

    func testMergesDuplicatesAndRenamesClashes() {
        let found = [
            key("STRIPE_SECRET_KEY", "sk_live_shop", "Shop"),
            key("STRIPE_SECRET_KEY", "sk_live_blog", "Blog"),
            key("OPENAI_API_KEY", "sk-same", "Shop"),
            key("OPENAI_API_KEY", "sk-same", "Blog"),
            key("GITHUB_TOKEN", "ghp_new", nil, kind: .shellProfile),
            key("ANTHROPIC_API_KEY", "sk-ant-have", "Shop"),
        ]
        let plan = ScanPlan.make(found, stored: ["GITHUB_TOKEN", "CLAUDE"],
                                 storedName: { $0 == "sk-ant-have" ? "CLAUDE" : nil })
        XCTAssertEqual(plan.count, 5)

        let stripe = plan.filter { $0.variable == "STRIPE_SECRET_KEY" }
        XCTAssertEqual(Set(stripe.map(\.name)), ["SHOP_STRIPE_SECRET_KEY", "BLOG_STRIPE_SECRET_KEY"],
                       "two values with one name: both get their project's name")
        XCTAssertTrue(stripe.allSatisfy { $0.status == .renamed && $0.include })

        let openAI = plan.first { $0.variable == "OPENAI_API_KEY" }
        XCTAssertEqual(openAI?.name, "OPENAI_API_KEY")
        XCTAssertEqual(openAI?.sources.count, 2, "one value in two projects is one key")
        XCTAssertNil(openAI?.group, "and isn't put in either project's group")

        let github = plan.first { $0.variable == "GITHUB_TOKEN" }
        XCTAssertEqual(github?.name, "GITHUB_TOKEN_2", "KeyBar already has a GITHUB_TOKEN, and there's no project")

        let claude = plan.first { $0.variable == "ANTHROPIC_API_KEY" }
        XCTAssertEqual(claude?.status, .stored)
        XCTAssertEqual(claude?.name, "CLAUDE", "a value KeyBar has points to the key that holds it")
        XCTAssertEqual(claude?.include, false)
    }

    func testRewritesOnlyMatchingValues() {
        let text = """
        # Shop
        export STRIPE_SECRET_KEY="sk_live_shop"
          OPENAI_API_KEY=sk-same # comment
        PORT=3000
        PRIVATE_KEY="-----BEGIN
        abc
        -----END"
        OTHER=changed-since
        """
        let result = EnvRewriter.rewrite(text, references: [
            "STRIPE_SECRET_KEY": ("sk_live_shop", "SHOP_STRIPE_SECRET_KEY"),
            "OPENAI_API_KEY": ("sk-same", "OPENAI_API_KEY"),
            "PRIVATE_KEY": ("-----BEGIN\nabc\n-----END", "SHOP_PRIVATE_KEY"),
            "OTHER": ("original", "OTHER"),
        ])
        XCTAssertEqual(result.text, """
        # Shop
        export STRIPE_SECRET_KEY=keybar:SHOP_STRIPE_SECRET_KEY
          OPENAI_API_KEY=keybar:OPENAI_API_KEY
        PORT=3000
        PRIVATE_KEY="-----BEGIN
        abc
        -----END"
        OTHER=changed-since
        """)
        XCTAssertEqual(result.swapped, ["STRIPE_SECRET_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(result.skipped, ["PRIVATE_KEY"])
    }
}

@MainActor
final class FindKeysStateTests: XCTestCase {
    func testImportsThenSwapsAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keybar-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = folder.appendingPathComponent(".env")
        try "STRIPE_SECRET_KEY=sk_live_abcdefghijklmnop\nPORT=3000\n".write(to: env, atomically: true, encoding: .utf8)
        chmod(env.path, 0o600)

        let state = AppState(store: SecretStore(vault: MemoryVault(), indexURL: nil), log: ActivityLog(url: nil),
                             claude: ClaudeConnector())
        let found = [FoundKey(name: "STRIPE_SECRET_KEY", value: "sk_live_abcdefghijklmnop",
                              source: KeySource(kind: .envFile, path: env.path, project: "Shop"))]
        let plan = state.plan(found)
        XCTAssertNil(state.importProblem(plan))
        let imported = try state.importFound(plan)
        XCTAssertEqual(try state.store.value("STRIPE_SECRET_KEY"), "sk_live_abcdefghijklmnop")
        XCTAssertEqual(state.store.record("STRIPE_SECRET_KEY")?.group, "Shop")

        XCTAssertEqual(state.swappableFiles(imported), [env.path])
        let result = state.swapReferences(imported, in: [env.path])
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(result.swapped, 1)
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "STRIPE_SECRET_KEY=keybar:STRIPE_SECRET_KEY\nPORT=3000\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: env.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "the file keeps its permissions")

        // Scanning again finds nothing new: the file holds references now
        XCTAssertTrue(KeyScanner.looksSecret(name: "STRIPE_SECRET_KEY", value: "keybar:STRIPE_SECRET_KEY") == false)
    }

    func testRefusesNamesUsedTwice() throws {
        let state = AppState(store: SecretStore(vault: MemoryVault(), indexURL: nil), log: ActivityLog(url: nil),
                             claude: ClaudeConnector())
        try state.store.add(name: "TAKEN", value: "something-else")
        var plan = state.plan([FoundKey(name: "NEW_TOKEN", value: "tok_abcdefghijk",
                                        source: KeySource(kind: .shellProfile, path: "/x/.zshrc"))])
        plan[0].name = "TAKEN"
        XCTAssertNotNil(state.importProblem(plan))
        XCTAssertThrowsError(try state.importFound(plan))
    }
}

final class RunPlanTests: XCTestCase {
    let env = """
    STRIPE_SECRET_KEY=keybar:SHOP_STRIPE_SECRET_KEY
    OPENAI_API_KEY=keybar:OPENAI_API_KEY
    PORT=3000
    """

    func plan(_ arguments: [String], files: [String: String]? = nil) throws -> RunPlan {
        let files = files ?? ["/p/.env": env]
        return try RunPlan.make(arguments, in: "/p") { files[$0] }
    }

    func testReadsReferencesFromDotEnv() throws {
        let plan = try plan(["--", "npm", "run", "dev"])
        XCTAssertEqual(plan.keys, ["STRIPE_SECRET_KEY": "SHOP_STRIPE_SECRET_KEY", "OPENAI_API_KEY": "OPENAI_API_KEY"])
        XCTAssertEqual(plan.plain, ["PORT": "3000"])
        XCTAssertEqual(plan.storedNames, ["OPENAI_API_KEY", "SHOP_STRIPE_SECRET_KEY"])
        XCTAssertEqual(plan.command, ["npm", "run", "dev"])
        XCTAssertEqual(plan.commandLine, "npm run dev")
    }

    func testKeysFromTheCommandLine() throws {
        let plan = try plan(["--no-env-file", "-k", "GITHUB_TOKEN", "--key", "TOKEN=CLOUDFLARE_API_TOKEN",
                             "wrangler", "deploy", "--message", "it's live"])
        XCTAssertEqual(plan.keys, ["GITHUB_TOKEN": "GITHUB_TOKEN", "TOKEN": "CLOUDFLARE_API_TOKEN"])
        XCTAssertTrue(plan.plain.isEmpty)
        XCTAssertEqual(plan.command, ["wrangler", "deploy", "--message", "it's live"], "options after the command are its own")
        XCTAssertEqual(plan.commandLine, "wrangler deploy --message 'it'\\''s live'")
    }

    func testKeyOverridesTheFile() throws {
        let plan = try plan(["--key", "STRIPE_SECRET_KEY=OTHER", "--", "x"])
        XCTAssertEqual(plan.keys["STRIPE_SECRET_KEY"], "OTHER")
    }

    func testEnvFiles() throws {
        let files = ["/p/.env.production": "API_KEY=keybar:PROD_API_KEY", "/p/.env": env]
        let plan = try plan(["-e", ".env.production", "--", "x"], files: files)
        XCTAssertEqual(plan.keys, ["API_KEY": "PROD_API_KEY"], "a named file replaces the default one")
        XCTAssertThrowsError(try self.plan(["-e", "missing.env", "--", "x"])) {
            XCTAssertEqual($0 as? RunPlan.Problem, .unreadable("missing.env"))
        }
    }

    func testProblems() {
        XCTAssertThrowsError(try plan([])) { XCTAssertEqual($0 as? RunPlan.Problem, .noCommand) }
        XCTAssertThrowsError(try plan(["--"])) { XCTAssertEqual($0 as? RunPlan.Problem, .noCommand) }
        XCTAssertThrowsError(try plan(["--key"])) { XCTAssertEqual($0 as? RunPlan.Problem, .missingValue("--key")) }
        XCTAssertThrowsError(try plan(["--key", "not a name", "x"])) { XCTAssertEqual($0 as? RunPlan.Problem, .badKey("not a name")) }
        XCTAssertThrowsError(try plan(["--frob", "x"])) { XCTAssertEqual($0 as? RunPlan.Problem, .unknownOption("--frob")) }
        XCTAssertThrowsError(try plan(["x"], files: [:])) { XCTAssertEqual($0 as? RunPlan.Problem, .nothingToSet) }
        XCTAssertThrowsError(try plan(["--help"])) { XCTAssertEqual($0 as? RunPlan.Problem, .help) }
    }
}

@MainActor
final class TerminalPolicyTests: XCTestCase {
    func testKeybarRunApprovalsCoverOneCommandAndAlwaysAsk() throws {
        let store = SecretStore(vault: MemoryVault(), indexURL: nil)
        try store.add(name: "GITHUB_TOKEN", value: "ghp_secretvalue123")
        let settings = AppSettings()
        let saved = settings.approvalSeconds
        defer { settings.approvalSeconds = saved }   // the test host shares the app's defaults
        let policy = BridgePolicy(store: store, log: ActivityLog(url: nil), settings: settings)
        func run(_ command: String) -> BridgeRequest {
            var request = BridgeRequest(action: .resolve, cwd: "/tmp", projectFolder: "/tmp", client: Bridge.terminalClient,
                                        names: ["GITHUB_TOKEN"], command: command)
            request.terminal = "/dev/ttys001"
            return request
        }

        settings.approvalSeconds = 0
        XCTAssertNotNil(policy.approvalPrompt(for: run("npm run dev")), "never asking doesn't cover keybar run")
        XCTAssertEqual(policy.approvalPrompt(for: run("npm run dev")),
                       "give GITHUB_TOKEN to a command in /tmp (keybar run): npm run dev")

        for setting in AppSettings.approvalChoices {
            settings.approvalSeconds = setting
            policy.approved(run("npm run dev"))
            XCTAssertNotNil(policy.approvalPrompt(for: run("npm run dev")), "keybar run asks every time, even right after a yes")
        }
    }
}
