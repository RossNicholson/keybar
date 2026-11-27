import Foundation

/// What list_secrets tells an AI app: the keys, then the passwords in their
/// own section. Names and details only, never a value. In Shared so the app's
/// tests can check it.
enum SecretListing {
    static let empty = "KeyBar has no keys or passwords stored yet. Ask the user to add the key in KeyBar (menu bar → +) rather than pasting it here."

    static func text(_ secrets: [SecretSummary], message: String? = nil, now: Date = Date()) -> String {
        guard !secrets.isEmpty else { return empty }
        let sorted = secrets.sorted { $0.name < $1.name }
        let keys = sorted.filter { $0.isPassword != true }
        let passwords = sorted.filter { $0.isPassword == true }
        var lines: [String] = []
        if !keys.isEmpty {
            lines.append("Keys stored in KeyBar (use them with run_with_secrets, as \"$NAME\"):")
            for secret in keys { lines.append(keyLine(secret, now: now)) }
        }
        if !passwords.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Website logins (KeyBar signs in with them on their own websites through fill_password; you never see the "
                + "username or password):")
            for secret in passwords { lines.append(passwordLine(secret)) }
        }
        if let message { lines.append("\n" + message) }
        return lines.joined(separator: "\n")
    }

    private static func keyLine(_ secret: SecretSummary, now: Date) -> String {
        var line = "- \(secret.name): \(secret.service.map { "\($0) " } ?? "")\(secret.kind.lowercased())"
        if let group = secret.group { line += " [\(group)]" }
        if let note = secret.note, !note.isEmpty { line += " (\(note))" }
        line += availability(secret)
        if let fileName = secret.fileName { line += " (file \(fileName): $\(secret.name) is its path)" }
        if let variable = secret.proxyVariable {
            line += " (through KeyBar's proxy: $\(secret.name) is a placeholder; call $\(variable) instead of the service's address)"
        }
        if let expires = secret.expiresAt {
            line += expires < now ? " (EXPIRED \(day(expires)), may not work)" : " (expires \(day(expires)))"
        }
        return line
    }

    private static func passwordLine(_ secret: SecretSummary) -> String {
        let sites = secret.websites ?? []
        var line = "- \(secret.name): login for \(sites.isEmpty ? "no website yet" : sites.joined(separator: ", "))"
        line += secret.hasUsername == true ? " (username and password)" : " (password only, no username saved)"
        if secret.inCommands == true {
            let variables = Bridge.loginVariables(secret.name)
            line += secret.hasUsername == true
                ? "; in commands: $\(variables.username) and $\(variables.password)"
                : "; in commands: $\(variables.password)"
        } else {
            line += "; browser only (the user hasn't allowed logins in commands)"
        }
        if let group = secret.group, group != "Passwords" { line += " [\(group)]" }
        if let note = secret.note, !note.isEmpty { line += " (\(note))" }
        line += availability(secret)
        return line
    }

    private static func availability(_ secret: SecretSummary) -> String {
        guard secret.restricted else { return "" }
        return secret.availableHere ? " (limited to some projects, including this one)" : " (not available in this folder)"
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
