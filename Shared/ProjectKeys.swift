import Foundation

/// A project's `.keybar` file: the keys that project uses, one name per line
/// (`#` starts a comment). In a folder with one, Claude only sees and uses
/// those keys, and `keybar run` sets them. It only ever narrows what's
/// available: folder limits still apply, and a key it names that isn't
/// stored is simply missing.
///
///     # Keys for this site
///     CLOUDFLARE_API_TOKEN
///     CLOUDFLARE_ACCOUNT_ID
struct ProjectKeys: Equatable, Sendable {
    static let fileName = ".keybar"
    /// Bigger than this isn't a list of names
    static let maxSize = 64 * 1024

    /// The file's path
    var path: String
    var names: [String]

    /// The folder it's in
    var folder: String { (path as NSString).deletingLastPathComponent }

    static func parse(_ text: String) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let name = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if SecretName.isValid(name) && !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The nearest `.keybar` file in `folder` or a folder above it, stopping
    /// before the home folder (~/.keybar is KeyBar's own folder) and the root.
    /// `read` returns a file's text, or nil if there's no such file.
    static func find(from folder: String,
                     home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                     read: (String) -> String? = ProjectKeys.readFile) -> ProjectKeys? {
        var current = URL(fileURLWithPath: folder).standardizedFileURL.path
        let stop = URL(fileURLWithPath: home).standardizedFileURL.path
        while current != "/" && current != stop && !current.isEmpty {
            let path = (current as NSString).appendingPathComponent(fileName)
            if let text = read(path) { return ProjectKeys(path: path, names: parse(text)) }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// A regular file's text, if it's small enough to be a list
    @Sendable static func readFile(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxSize else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// The text for a new file listing `names`
    static func text(for names: [String]) -> String {
        """
        # The keys this project uses, from KeyBar. In this folder Claude only
        # sees these keys, and `keybar run -- COMMAND` sets them.
        # One name per line. Names only: never put a key's value here.

        """ + names.joined(separator: "\n") + "\n"
    }
}
