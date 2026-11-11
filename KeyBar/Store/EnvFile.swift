import Foundation

/// Reads KEY=value pairs from a .env file, the way dotenv does: comments,
/// `export` in front, single quotes (taken as written), double quotes (with
/// \n escapes, and able to run over several lines) and comments after
/// unquoted values
enum EnvFile {
    struct Entry: Hashable, Sendable {
        var name: String
        var value: String
    }

    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            var line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard SecretName.isValid(name) else { continue }
            var rest = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)

            let value: String
            if rest.hasPrefix("\"") {
                rest.removeFirst()
                // Keep reading lines until the closing quote
                var collected = rest
                while closingQuote(in: collected) == nil, index < lines.count {
                    collected += "\n" + lines[index]
                    index += 1
                }
                let end = closingQuote(in: collected) ?? collected.endIndex
                value = unescape(String(collected[..<end]))
            } else if rest.hasPrefix("'") {
                rest.removeFirst()
                value = rest.firstIndex(of: "'").map { String(rest[..<$0]) } ?? rest
            } else if rest.hasPrefix("`") {
                rest.removeFirst()
                value = rest.firstIndex(of: "`").map { String(rest[..<$0]) } ?? rest
            } else {
                // An unquoted value ends at " #"
                if let comment = rest.range(of: " #") {
                    rest = String(rest[..<comment.lowerBound])
                }
                value = rest.trimmingCharacters(in: .whitespaces)
            }
            guard !value.isEmpty else { continue }
            entries.removeAll { $0.name == name }   // the last one wins, as in dotenv
            entries.append(Entry(name: name, value: value))
        }
        return entries
    }

    /// The index of the first double quote not escaped by a backslash
    private static func closingQuote(in text: String) -> String.Index? {
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { return index }
        }
        return nil
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
