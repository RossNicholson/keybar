import Foundation

/// Sample keys and activity, held in memory, for screenshots, unit tests and
/// `-demo YES`. Nothing here touches the Keychain or ~/.keybar.
@MainActor
enum Demo {
    static let keys: [(name: String, value: String, group: String?, note: String?)] = [
        ("ANTHROPIC_API_KEY", "sk-ant-api03-demo-1f9c2b7e4a6d8c0b3e5f7a9c1d3e5f70", nil, "Claude API for scripts"),
        ("CLOUDFLARE_API_TOKEN", "demo-cf-token-8KJq2nV7xLp4Rt9Wz3Ym6Hs1", "Website", "Workers + Pages deploys"),
        ("CLOUDFLARE_ACCOUNT_ID", "3f0c9d2a7b1e4c8f9a6d5e2b1c0f7a8e", "Website", nil),
        ("GITHUB_TOKEN", "github_pat_DEMO11AAAAAAA0demo0token0value0here", nil, "Fine-grained, repo + workflow"),
        ("STRIPE_SECRET_KEY", "sk_test_demo51H8xYzAbCdEfGhIjKlMnOpQr", "Shop", nil),
        ("STRIPE_PUBLISHABLE_KEY", "pk_test_demo51H8xYzAbCdEfGhIjKlMnOpQr", "Shop", nil),
        ("RESEND_API_KEY", "re_demo_9sKx2Lm4Np6Qr8Tv0Wx", "Website", "Contact form email"),
        ("OPENAI_API_KEY", "sk-proj-demo-Ab12Cd34Ef56Gh78Ij90", nil, nil),
        ("HEROKU_API_KEY", "demo-heroku-0f1e2d3c4b5a69788796", nil, "Old host, moved to Cloudflare"),
    ]

    static func state() -> AppState {
        let vault = MemoryVault(Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0.value) }))
        let store = SecretStore(vault: vault, indexURL: nil)
        for key in keys {
            if var record = store.record(key.name) {
                record.group = key.group
                record.note = key.note
                if key.name == "STRIPE_SECRET_KEY" {
                    record.projectFolders = ["\(NSHomeDirectory())/Dev/shop"]
                }
                record.lastUsedAt = key.name.hasPrefix("CLOUDFLARE") ? Date().addingTimeInterval(-420) : nil
                store.update(record)
            }
        }
        store.setArchived("HEROKU_API_KEY", true)
        try? store.add(name: "GOOGLE_SERVICE_ACCOUNT", value: demoServiceAccount, group: "Website",
                       note: "Search Console reports", fileName: "search-console.json")
        store.setExpiry("GITHUB_TOKEN", Calendar.current.date(byAdding: .day, value: 9, to: Date()))
        let week = Date().addingTimeInterval(-6 * 86_400)
        for repo in ["RossNicholson/website", "RossNicholson/shop"] {
            store.recordSend("GITHUB_TOKEN", to: Destination(kind: .githubActions, target: repo, secretName: "GH_TOKEN", sentAt: week))
        }
        store.recordSend("CLOUDFLARE_API_TOKEN", to: Destination(kind: .cloudflareWorker, target: "contact-form",
                                                                 secretName: "CLOUDFLARE_API_TOKEN", sentAt: week))
        let log = ActivityLog(url: nil)
        let now = Date()
        log.replace(with: [
            ActivityEntry(date: now.addingTimeInterval(-420), action: .ran, source: .claudeCode,
                          names: ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN"], program: "wrangler",
                          folder: "\(NSHomeDirectory())/Dev/website", detail: "Exit 0"),
            ActivityEntry(date: now.addingTimeInterval(-1_500), action: .ran, source: .claudeCode,
                          names: ["GITHUB_TOKEN"], program: "curl",
                          folder: "\(NSHomeDirectory())/Dev/website", detail: "Exit 0 · 1 copy hidden"),
            ActivityEntry(date: now.addingTimeInterval(-3_900), action: .refused, source: .claudeCode,
                          names: ["STRIPE_SECRET_KEY"], program: "stripe",
                          folder: "\(NSHomeDirectory())/Dev/website",
                          detail: "STRIPE_SECRET_KEY can only be used in ~/Dev/shop, not in ~/Dev/website."),
            ActivityEntry(date: now.addingTimeInterval(-7_200), action: .copied, source: .you,
                          names: ["OPENAI_API_KEY"], detail: "Clipboard clears in 20 sec"),
            ActivityEntry(date: now.addingTimeInterval(-86_400), action: .imported, source: .you,
                          names: ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_API_TOKEN", "RESEND_API_KEY"], detail: "From .env"),
        ])
        let claude = ClaudeConnector(home: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keybar-demo-home"),
                                     helperPath: "/Applications/KeyBar.app/Contents/Helpers/keybar")
        if var record = store.record("ANTHROPIC_API_KEY") {
            record.proxied = true
            store.update(record)
        }
        if var record = store.record("STRIPE_SECRET_KEY") {
            record.approval = .everyTime
            store.update(record)
        }
        let demoHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keybar-demo-home")
        let aiApps = AIApps(home: demoHome, helperPath: "/Applications/KeyBar.app/Contents/Helpers/keybar")
        let state = AppState(store: store, log: log, claude: claude, aiApps: aiApps)
        state.leaks = leaks()
        state.isDemo = true
        return state
    }

    /// What the leak check might find, for screenshots
    static func leaks() -> [Leak] {
        let home = NSHomeDirectory()
        return [
            Leak(name: "OPENAI_API_KEY", place: .claudeCode,
                 path: "\(home)/.claude/projects/-Users-you-Dev-blog/3f2a9c1e-5b7d-4e8a-9c0f-1d2e3f4a5b6c.jsonl", count: 2),
            Leak(name: "OPENAI_API_KEY", place: .shellHistory, path: "\(home)/.zsh_history", count: 1),
            Leak(name: "STRIPE_SECRET_KEY", place: .gitHistory, path: "\(home)/Dev/shop",
                 detail: "commit 8c41d2e 2026-03-14 · src/config.js", count: 1),
        ]
    }

    nonisolated static let demoServiceAccount = """
    {"type": "service_account", "project_id": "demo-site", "private_key_id": "0123456789abcdef0123456789abcdef01234567",
     "private_key": "-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDdemo\\n-----END PRIVATE KEY-----\\n",
     "client_email": "reports@demo-site.iam.gserviceaccount.com"}
    """

    /// What Find keys might turn up on a Mac with the demo keys, for screenshots
    static func found() -> [FoundKey] {
        let dev = "\(NSHomeDirectory())/Dev"
        func env(_ project: String, _ file: String = ".env") -> KeySource {
            KeySource(kind: .envFile, path: "\(dev)/\(project)/\(file)", project: project)
        }
        let claude = KeySource(kind: .claudeCode, path: "\(NSHomeDirectory())/.claude.json")
        let aws = KeySource(kind: .aws, path: "\(NSHomeDirectory())/.aws/credentials")
        return [
            FoundKey(name: "STRIPE_SECRET_KEY", value: "sk_test_demo51H8xYzAbCdEfGhIjKlMnOpQr", source: env("shop")),
            FoundKey(name: "STRIPE_WEBHOOK_SECRET", value: "whsec_demo0a1b2c3d4e5f6a7b8c9d", source: env("shop")),
            FoundKey(name: "STRIPE_SECRET_KEY", value: "sk_test_demoBlogOther0123456789ab", source: env("blog")),
            FoundKey(name: "DATABASE_URL", value: "postgres://blog:demo-pass-4821@db.internal/blog", source: env("blog", ".env.local")),
            FoundKey(name: "SUPABASE_SERVICE_ROLE_KEY", value: "demo-supabase-service-role-9f8e7d6c", source: env("blog", ".env.local")),
            FoundKey(name: "OPENAI_API_KEY", value: "sk-proj-demo-Ab12Cd34Ef56Gh78Ij90", source: env("blog")),
            FoundKey(name: "OPENAI_API_KEY", value: "sk-proj-demo-Ab12Cd34Ef56Gh78Ij90", source: env("website")),
            FoundKey(name: "SENTRY_AUTH_TOKEN", value: "sntrys_demo_0123456789abcdef", source: env("website")),
            FoundKey(name: "LINEAR_API_KEY", value: "lin_api_demo0123456789abcdef", source: claude),
            FoundKey(name: "AWS_ACCESS_KEY_ID", value: "AKIADEMODEMODEMODEMO", source: aws),
            FoundKey(name: "AWS_SECRET_ACCESS_KEY", value: "demoSecretAccessKey0123456789abcdefghij", source: aws),
        ]
    }
}
