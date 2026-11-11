import Foundation

/// Hides key values in a command's output before Claude sees it. It finds each
/// key as written, base64-encoded (standard and URL-safe, with or without
/// padding), URL-encoded, in hex and backwards, plus long fragments of it. It's a safety
/// net, not a sandbox: a command that cuts a key up or changes it some other
/// way before printing it gets past.
struct Redactor: Sendable {
    static let marker = "[REDACTED]"
    /// Keys shorter than this aren't hidden: they'd match ordinary output
    static let minimumLength = 4
    /// A run of at least this many characters from a key counts as part of it
    static let fragmentLength = 10
    /// Fragments are only looked for in keys at least this long
    static let fragmentKeyLength = 16

    private let forms: [[UInt8]]
    private let fragmentSets: [(length: Int, grams: Set<[UInt8]>)]

    init(secrets: [String]) {
        var forms = Set<[UInt8]>()
        var fragmentSets: [(Int, Set<[UInt8]>)] = []
        for secret in secrets where secret.utf8.count >= Self.minimumLength {
            for form in Self.encodings(of: secret) where form.count >= Self.minimumLength {
                forms.insert(Array(form.utf8))
            }
            let bytes = Array(secret.utf8)
            if bytes.count >= Self.fragmentKeyLength {
                var grams = Set<[UInt8]>()
                for start in 0...(bytes.count - Self.fragmentLength) {
                    grams.insert(Array(bytes[start..<(start + Self.fragmentLength)]))
                }
                fragmentSets.append((Self.fragmentLength, grams))
            }
        }
        // Longest first, so a longer form wins where two overlap
        self.forms = forms.sorted { $0.count > $1.count }
        self.fragmentSets = fragmentSets
    }

    /// The ways a key might turn up in output
    static func encodings(of secret: String) -> [String] {
        let data = Data(secret.utf8)
        let base64 = data.base64EncodedString()
        let unpadded = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let urlSafe = unpadded.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let percent = secret.addingPercentEncoding(withAllowedCharacters: unreserved) ?? secret
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // JSON writers often escape slashes
        let jsonEscaped = secret.replacingOccurrences(of: "/", with: "\\/")
        let reversed = String(secret.reversed())
        return [secret, base64, unpadded, urlSafe, percent, hex, hex.uppercased(), jsonEscaped, reversed]
    }

    var isEmpty: Bool { forms.isEmpty }

    /// The text with every key hidden, and how many places were hidden
    func redact(_ text: String) -> (text: String, count: Int) {
        guard !forms.isEmpty else { return (text, 0) }
        let bytes = Array(text.utf8)
        var hidden = [Bool](repeating: false, count: bytes.count)
        var any = false

        for form in forms where form.count <= bytes.count {
            var index = 0
            let first = form[0]
            while index <= bytes.count - form.count {
                if bytes[index] == first, bytes[index..<(index + form.count)].elementsEqual(form) {
                    for i in index..<(index + form.count) { hidden[i] = true }
                    any = true
                    index += form.count
                } else {
                    index += 1
                }
            }
        }

        for (length, grams) in fragmentSets where length <= bytes.count {
            for start in 0...(bytes.count - length) where !hidden[start] || !hidden[start + length - 1] {
                if grams.contains(Array(bytes[start..<(start + length)])) {
                    for i in start..<(start + length) { hidden[i] = true }
                    any = true
                }
            }
        }

        guard any else { return (text, 0) }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        let marker = Array(Self.marker.utf8)
        var count = 0
        var i = 0
        while i < bytes.count {
            if hidden[i] {
                while i < bytes.count && hidden[i] { i += 1 }
                output.append(contentsOf: marker)
                count += 1
            } else {
                output.append(bytes[i])
                i += 1
            }
        }
        return (String(decoding: output, as: UTF8.self), count)
    }
}

/// Key names are the environment variable they're handed to a command as
enum SecretName {
    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty, name.count <= 128 else { return false }
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy { rest.contains($0) }
    }

    /// Turns what someone typed ("cloudflare api token") into a usable name
    /// ("CLOUDFLARE_API_TOKEN")
    static func normalized(_ typed: String) -> String {
        var result = ""
        var lastWasUnderscore = false
        for scalar in typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasUnderscore = false
            } else if !lastWasUnderscore, !result.isEmpty {
                result.append("_")
                lastWasUnderscore = true
            }
        }
        while result.hasSuffix("_") { result.removeLast() }
        if let first = result.first, first.isNumber { result = "_" + result }
        return result
    }

    /// The program a command runs, for the activity log: `wrangler` for
    /// `CI=1 npx wrangler deploy`
    static func program(in command: String) -> String {
        let skip: Set<String> = ["sudo", "env", "npx", "bunx", "pnpx", "exec", "time", "command", "nohup"]
        for word in command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            let token = String(word)
            if token.contains("="), !token.hasPrefix("-"), !token.hasPrefix("\"") { continue }
            if skip.contains(token) { continue }
            if token.hasPrefix("-") { continue }
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'();&|"))
            guard !trimmed.isEmpty else { continue }
            return (trimmed as NSString).lastPathComponent
        }
        return "command"
    }
}
