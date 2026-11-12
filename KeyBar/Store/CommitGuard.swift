import Foundation

/// Where git is, without setting off macOS's "install the developer tools"
/// dialog when it isn't there
enum GitTool {
    static var path: String? {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // /usr/bin/git is a stub that asks to install the tools if they're missing
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return tools.contains(where: fm.isExecutableFile) ? "/usr/bin/git" : nil
    }

    /// Runs git; returns its exit status and output
    @discardableResult
    static func run(_ arguments: [String], environment: [String: String] = [:]) -> (status: Int32, output: String) {
        guard let path else { return (-1, "git isn't installed.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "git couldn't start.") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The commit guard: stops a commit that has a stored key's value in it, in
/// every repository on this Mac. It points git's global core.hooksPath at
/// ~/.keybar/hooks, where each hook runs the check (pre-commit only) and
/// then the repository's own hook, so nothing a repo already has stops
/// working. A repository with its own core.hooksPath (Husky, say) keeps
/// using that and isn't guarded.
struct CommitGuard {
    enum Status: Equatable {
        case on
        case off
        /// git's global hooks folder is already set to something else
        case otherHooks(String)
        case noGit
    }

    enum Problem: LocalizedError {
        case otherHooks(String), noGit, git(String)

        var errorDescription: String? {
            switch self {
            case .otherHooks(let path):
                return "git already uses \(BridgePolicy.tidy(path)) for hooks in every repo, so KeyBar left it alone. Add this line to its pre-commit hook instead: \(CommitGuard.hookLine)"
            case .noGit: return "git isn't installed. Install Apple's developer tools (xcode-select --install) or Homebrew's git."
            case .git(let output): return "git couldn't change its settings: \(output)"
            }
        }
    }

    var folder: URL = Bridge.directory.appendingPathComponent("hooks", isDirectory: true)
    var helperPath: String = ClaudeConnector.bundledHelperPath
    /// For tests: e.g. GIT_CONFIG_GLOBAL pointing at a scratch file
    var gitEnvironment: [String: String] = [:]

    /// The hooks git runs that a repository might have its own of. Not
    /// reference-transaction (it runs on every ref change) or server hooks.
    static let hookNames = [
        "applypatch-msg", "pre-applypatch", "post-applypatch", "pre-commit", "pre-merge-commit", "prepare-commit-msg",
        "commit-msg", "post-commit", "pre-rebase", "post-checkout", "post-merge", "pre-push", "post-rewrite",
        "pre-auto-gc", "push-to-checkout", "sendemail-validate",
    ]

    /// For adding the check to a hook by hand
    static var hookLine: String { "\"\(ClaudeConnector.bundledHelperPath)\" guard || exit 1" }

    private var configuredPath: String? {
        let result = GitTool.run(["config", "--global", "--get", "core.hooksPath"], environment: gitEnvironment)
        return result.status == 0 && !result.output.isEmpty ? result.output : nil
    }

    private func isOurs(_ path: String) -> Bool {
        Storage.canonical((path as NSString).expandingTildeInPath) == Storage.canonical(folder.path)
    }

    func status() -> Status {
        guard GitTool.path != nil else { return .noGit }
        guard let path = configuredPath else { return .off }
        return isOurs(path) ? .on : .otherHooks(path)
    }

    func turnOn() throws {
        guard GitTool.path != nil else { throw Problem.noGit }
        if let path = configuredPath, !isOurs(path) { throw Problem.otherHooks(path) }
        try writeHooks()
        let result = GitTool.run(["config", "--global", "core.hooksPath", folder.path], environment: gitEnvironment)
        guard result.status == 0 else { throw Problem.git(result.output) }
    }

    func turnOff() throws {
        if let path = configuredPath, isOurs(path) {
            let result = GitTool.run(["config", "--global", "--unset", "core.hooksPath"], environment: gitEnvironment)
            guard result.status == 0 else { throw Problem.git(result.output) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Rewrites the hooks if the guard is on, e.g. after KeyBar moved
    func refresh() {
        if status() == .on { try? writeHooks() }
    }

    func script(for hook: String) -> String {
        var text = """
        #!/bin/sh
        # KeyBar's commit guard. Runs this repository's own \(hook) hook, if it has one\(hook == "pre-commit" ? ",\n# after checking the commit has no key stored in KeyBar in it" : "").
        # Turn it off in KeyBar → Dev tools. Skip it once with git commit --no-verify.

        """
        if hook == "pre-commit" {
            text += """
            helper="\(helperPath)"
            if [ -x "$helper" ]; then "$helper" guard || exit 1; fi

            """
        }
        text += """
        own="$(git rev-parse --git-common-dir 2>/dev/null)/hooks/\(hook)"
        if [ -x "$own" ]; then exec "$own" "$@"; fi
        exit 0

        """
        return text
    }

    private func writeHooks() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for hook in Self.hookNames {
            let url = folder.appendingPathComponent(hook)
            try Data(script(for: hook).utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}
