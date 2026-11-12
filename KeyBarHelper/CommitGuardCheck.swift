import Foundation

/// `keybar guard`: KeyBar's git pre-commit check. Reads the lines the commit
/// adds, asks KeyBar which stored keys are in them (KeyBar answers with names
/// only), and stops the commit if any are. If KeyBar can't be reached the
/// commit goes ahead with a warning: the guard never stops you working.
enum CommitGuardCheck {
    static func main() -> Never {
        let folder = FileManager.default.currentDirectoryPath
        guard let diff = stagedDiff() else {
            warn("couldn't read the staged changes, so this commit wasn't checked for keys.")
            exit(0)
        }
        let added = StagedChanges.addedLines(diff)
        guard !added.isEmpty else { exit(0) }
        var found: [String: [String]] = [:]
        do {
            for batch in StagedChanges.batches(added) {
                let reply = try AppLink.send(BridgeRequest(action: .check, cwd: folder, client: "git commit", texts: batch),
                                             timeout: 20)
                guard reply.ok else { throw BridgeError.io(reply.error ?? "refused") }
                found.merge(reply.found ?? [:]) { $0 + $1 }
            }
        } catch {
            warn("couldn't ask KeyBar (\(error)), so this commit wasn't checked for keys.")
            exit(0)
        }
        guard !found.isEmpty else { exit(0) }
        var message = "KeyBar stopped this commit: it has the value of a key stored in KeyBar.\n"
        for file in found.keys.sorted() {
            message += "  \(file): \(found[file, default: []].joined(separator: ", "))\n"
        }
        message += "Use the environment variable instead (e.g. process.env.NAME, os.environ[\"NAME\"]) and unstage the key.\n"
        message += "To commit anyway, which publishes the key to anyone with the repo: git commit --no-verify\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("keybar: \(message)\n".utf8))
    }

    /// `git diff --cached`, with no context lines
    private static func stagedDiff() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "-U0", "--diff-filter=ACMR"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
