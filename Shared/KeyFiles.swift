import Foundation

/// Private copies of a command's file keys (a .json service account, a .p8),
/// so the command gets a path rather than the contents. Written before the
/// command starts into a folder only this user can open, and deleted after.
final class KeyFiles {
    let folder: URL?
    /// Key name → path of its copy
    private(set) var paths: [String: String] = [:]

    /// `files`: key name → the file's name, for the keys in `values` that are files
    init(values: [String: String], files: [String: String]) throws {
        let fileKeys = files.filter { values[$0.key] != nil }
        guard !fileKeys.isEmpty else { folder = nil; return }
        Self.removeOld()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        self.folder = folder
        for (name, fileName) in fileKeys {
            // Each in its own subfolder, so two keys with one file name don't clash
            let sub = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let url = sub.appendingPathComponent(Self.safeName(fileName))
            try Self.writePrivate(Data(values[name]!.utf8), to: url)
            paths[name] = url.path
        }
    }

    deinit { remove() }

    /// `values` with each file key's contents swapped for its path
    func environment(_ values: [String: String]) -> [String: String] {
        values.merging(paths) { _, path in path }
    }

    func remove() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        paths = [:]
    }

    /// The parts of a file key worth hiding in output: long runs with no
    /// spaces (private key lines, IDs, tokens), not the whole file, so the
    /// ordinary words a JSON key file shares with everything else aren't
    /// blanked out. A file that's one word (a password or token on its own)
    /// is hidden whole, however short.
    static func secretParts(of contents: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\",{}[]"))
        var parts = Set<String>()
        let whole = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whole.isEmpty, whole.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { parts.insert(whole) }
        for line in contents.replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: .newlines) {
            for piece in line.components(separatedBy: separators) {
                let trimmed = piece.trimmingCharacters(in: CharacterSet(charactersIn: ":;"))
                guard trimmed.count >= 20, !trimmed.hasPrefix("http"), !trimmed.hasPrefix("-----") else { continue }
                parts.insert(trimmed)
            }
        }
        return Array(parts)
    }

    private static let prefix = "keybar-files-"

    private static func safeName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        return base.isEmpty || base.hasPrefix(".") ? "key" + base : base
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Copies left behind by a command whose helper was killed
    private static func removeOld() {
        let temp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for item in items where item.lastPathComponent.hasPrefix(prefix) {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }
}
