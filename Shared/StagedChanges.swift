import Foundation

/// Reading a commit's staged changes for KeyBar's commit guard
enum StagedChanges {
    /// The most sent to KeyBar in one request
    static let batchSize = 3 * 1024 * 1024

    /// File → the lines the diff adds to it
    static func addedLines(_ diff: String) -> [String: String] {
        var files: [String: String] = [:]
        var file: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let path = line.dropFirst(4)
                file = path == "/dev/null" ? nil : String(path.hasPrefix("b/") ? path.dropFirst(2) : path)
            } else if line.hasPrefix("+"), let file {
                files[file, default: ""] += line.dropFirst() + "\n"
            }
        }
        return files
    }

    /// Splits the files into requests small enough to send; a file too big
    /// for one is cut into pieces (a key could straddle a cut, but a file
    /// that size is rarely hand-written)
    static func batches(_ files: [String: String]) -> [[String: String]] {
        var batches: [[String: String]] = []
        var current: [String: String] = [:]
        var size = 0
        for (file, text) in files.sorted(by: { $0.key < $1.key }) {
            var pieces: [String] = []
            var rest = Substring(text)
            while rest.utf8.count > batchSize {
                let cut = rest.index(rest.startIndex, offsetBy: batchSize / 2)
                pieces.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
            pieces.append(String(rest))
            for piece in pieces {
                if size + piece.utf8.count > batchSize, !current.isEmpty {
                    batches.append(current)
                    current = [:]
                    size = 0
                }
                current[file, default: ""] += piece
                size += piece.utf8.count
                if size >= batchSize {
                    batches.append(current)
                    current = [:]
                    size = 0
                }
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
