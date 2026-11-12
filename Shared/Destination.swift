import Foundation

/// Somewhere a key can be sent so a deploy can use it: a GitHub repo's
/// Actions secrets, or a Cloudflare Worker's or Pages project's secrets
struct Destination: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case githubActions, cloudflareWorker, cloudflarePages

        var id: String { rawValue }

        var title: String {
            switch self {
            case .githubActions: return "GitHub Actions"
            case .cloudflareWorker: return "Cloudflare Worker"
            case .cloudflarePages: return "Cloudflare Pages"
            }
        }

        /// What `target` is, for a field label
        var targetLabel: String {
            switch self {
            case .githubActions: return "Repository"
            case .cloudflareWorker: return "Worker"
            case .cloudflarePages: return "Pages project"
            }
        }

        var targetExample: String {
            switch self {
            case .githubActions: return "owner/repo"
            case .cloudflareWorker: return "my-worker"
            case .cloudflarePages: return "my-site"
            }
        }
    }

    var kind: Kind
    /// owner/repo, the Worker's name or the Pages project's
    var target: String
    /// The secret's name there, usually the key's own
    var secretName: String
    var sentAt: Date?

    var id: String { "\(kind.rawValue):\(target.lowercased()):\(secretName)" }

    func samePlace(as other: Destination) -> Bool { id == other.id }

    var label: String {
        switch kind {
        case .githubActions: return "GitHub · \(target)"
        case .cloudflareWorker: return "Worker · \(target)"
        case .cloudflarePages: return "Pages · \(target)"
        }
    }

    /// Why this can't be sent to, or nil if it can. The target and name end
    /// up as command arguments, so only plain names pass (never "-flag").
    var problem: String? {
        guard SecretName.isValid(secretName) else {
            return "\"\(secretName)\" can't be a secret name: letters, numbers and underscores, starting with a letter."
        }
        let pattern: String
        switch kind {
        case .githubActions: pattern = "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9_.][A-Za-z0-9_.-]{0,99}$"
        case .cloudflareWorker, .cloudflarePages: pattern = "^[a-z0-9][a-z0-9-]{0,62}$"
        }
        guard target.range(of: pattern, options: .regularExpression) != nil else {
            return "\"\(target)\" isn't a \(kind.targetLabel.lowercased()) name, like \(kind.targetExample)."
        }
        return nil
    }
}
