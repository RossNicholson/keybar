import Foundation

/// Asks a key's own service whether it still works. Only when the user
/// clicks Test, and only to that service's API: KeyBar otherwise makes no
/// network requests. Each check is a read-only call that changes nothing.
enum KeyTester {
    enum Outcome: Equatable {
        case works
        case rejected(Int)
        case unreachable(String)
    }

    struct Result: Equatable {
        var outcome: Outcome
        /// When the service says the key expires, if it says
        var expiresAt: Date?
        var service: String

        var summary: String {
            switch outcome {
            case .works: return "Works: \(service) accepted it."
            case .rejected(let status):
                return "\(service) refused it (HTTP \(status)). It may be revoked, expired or missing a permission."
            case .unreachable(let reason): return "Couldn't reach \(service): \(reason)"
            }
        }
    }

    private struct Check: Sendable {
        var url: String
        /// Header name → value, with \(key) as KEY
        var headers: [String: String]
        /// Reads an expiry date from the reply, if the service gives one
        var expiry: (@Sendable (HTTPURLResponse, Data) -> Date?)? = nil
    }

    private static func bearer(_ url: String) -> Check { Check(url: url, headers: ["Authorization": "Bearer KEY"]) }

    /// By service name, as ServiceCatalog spells it
    private static let checks: [String: Check] = [
        "Anthropic": Check(url: "https://api.anthropic.com/v1/models?limit=1",
                           headers: ["x-api-key": "KEY", "anthropic-version": "2023-06-01"]),
        "OpenAI": bearer("https://api.openai.com/v1/models"),
        "Groq": bearer("https://api.groq.com/openai/v1/models"),
        "Mistral": bearer("https://api.mistral.ai/v1/models"),
        "OpenRouter": bearer("https://openrouter.ai/api/v1/key"),
        "Hugging Face": bearer("https://huggingface.co/api/whoami-v2"),
        "Cloudflare": Check(url: "https://api.cloudflare.com/client/v4/user/tokens/verify",
                            headers: ["Authorization": "Bearer KEY"], expiry: { _, data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any], let text = result["expires_on"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: text)
        }),
        "GitHub": Check(url: "https://api.github.com/user",
                        headers: ["Authorization": "Bearer KEY", "Accept": "application/vnd.github+json"], expiry: { response, _ in
            // e.g. "2027-01-01 00:00:00 UTC" on tokens that expire
            guard let text = response.value(forHTTPHeaderField: "github-authentication-token-expiration") else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
            return formatter.date(from: text)
        }),
        "Stripe": bearer("https://api.stripe.com/v1/balance"),
        "Buttondown": Check(url: "https://api.buttondown.com/v1/emails", headers: ["Authorization": "Token KEY"]),
        "Slack": bearer("https://slack.com/api/auth.test"),
        "npm": bearer("https://registry.npmjs.org/-/whoami"),
        "Vercel": bearer("https://api.vercel.com/v2/user"),
        "Netlify": bearer("https://api.netlify.com/api/v1/user"),
    ]

    /// Whether Test can check this key
    static func canTest(_ record: SecretRecord) -> Bool {
        !record.isFile && record.service.map { checks[$0.name] != nil } == true
    }

    static func test(_ record: SecretRecord, value: String) async -> Result? {
        guard !record.isFile, let service = record.service, let check = checks[service.name],
              let url = URL(string: check.url) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (header, template) in check.headers {
            request.setValue(template.replacingOccurrences(of: "KEY", with: value), forHTTPHeaderField: header)
        }
        request.setValue("KeyBar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Result(outcome: .unreachable("no reply"), service: service.name)
            }
            // Slack answers 200 with ok: false for a bad token
            if service.name == "Slack", let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["ok"] as? Bool == false {
                return Result(outcome: .rejected(401), service: service.name)
            }
            guard (200..<300).contains(http.statusCode) else {
                return Result(outcome: .rejected(http.statusCode), service: service.name)
            }
            return Result(outcome: .works, expiresAt: check.expiry?(http, data), service: service.name)
        } catch {
            return Result(outcome: .unreachable(error.localizedDescription), service: service.name)
        }
    }

    /// No cookies, no cache: nothing about the key stays behind
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
