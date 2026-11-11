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
        let state = AppState(store: store, log: log, claude: claude)
        state.isDemo = true
        return state
    }
}
