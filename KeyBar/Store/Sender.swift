import Foundation

/// Sends a key to a GitHub repo's Actions secrets (with gh) or to a
/// Cloudflare Worker or Pages project (with wrangler). The value goes in on
/// the tool's standard input, never as an argument, so it isn't visible in
/// the process list. Slow (it runs a command): never call it on the main
/// thread.
enum Sender {
    enum Failure: LocalizedError {
        case missingTool(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingTool(let message), .failed(let message): return message
            }
        }
    }

    /// Sends `value`. Returns a line saying where it went.
    static func send(_ value: String, to destination: Destination) throws -> String {
        if let problem = destination.problem { throw Failure.failed(problem) }
        switch destination.kind {
        case .githubActions:
            let gh = try tool("gh", install: "brew install gh, then gh auth login")
            try run(gh, ["secret", "set", destination.secretName, "--repo", destination.target], input: value)
            return "\(destination.secretName) is set in \(destination.target)'s Actions secrets."
        case .cloudflareWorker:
            let wrangler = try wranglerCommand()
            // `secret put` offers to create a Worker that doesn't exist, and
            // would take the key as the answer: make sure it's there first
            try run(wrangler.path, wrangler.prefix + ["secret", "list", "--name", destination.target], input: nil,
                    failure: "Cloudflare has no Worker called \(destination.target) that wrangler can see")
            try run(wrangler.path, wrangler.prefix + ["secret", "put", destination.secretName, "--name", destination.target],
                    input: value)
            return "\(destination.secretName) is set on the Worker \(destination.target)."
        case .cloudflarePages:
            let wrangler = try wranglerCommand()
            try run(wrangler.path, wrangler.prefix + ["pages", "secret", "list", "--project-name", destination.target], input: nil,
                    failure: "Cloudflare has no Pages project called \(destination.target) that wrangler can see")
            try run(wrangler.path, wrangler.prefix + ["pages", "secret", "put", destination.secretName,
                                                      "--project-name", destination.target], input: value)
            return "\(destination.secretName) is set on the Pages project \(destination.target)."
        }
    }

    /// The user's GitHub repos, for picking from (owner/name)
    static func githubRepos() throws -> [String] {
        let gh = try tool("gh", install: "brew install gh, then gh auth login")
        let output = try run(gh, ["repo", "list", "--limit", "300", "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"], input: nil)
        return output.split(whereSeparator: \.isNewline).map(String.init).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    // MARK: - Running tools

    /// Where tools usually live: KeyBar, started from the Dock or at login,
    /// doesn't get the PATH a terminal has
    private static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                    "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    private static func find(_ name: String) -> String? {
        searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func tool(_ name: String, install: String) throws -> String {
        guard let path = find(name) else { throw Failure.missingTool("\(name) isn't installed. To use it: \(install).") }
        return path
    }

    /// wrangler if it's installed, else through npx (slower the first time)
    private static func wranglerCommand() throws -> (path: String, prefix: [String]) {
        if let wrangler = find("wrangler") { return (wrangler, []) }
        if let npx = find("npx") { return (npx, ["--yes", "wrangler"]) }
        throw Failure.missingTool("wrangler isn't installed. To use it: npm install -g wrangler, then wrangler login.")
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], input: String?,
                            failure: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        // No colours, prompts or update checks: it's not a terminal
        environment["NO_COLOR"] = "1"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["WRANGLER_SEND_METRICS"] = "false"
        environment["CI"] = "1"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure.failed("Couldn't start \((executable as NSString).lastPathComponent): \(error.localizedDescription)")
        }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        // Read both before waiting, so a chatty tool can't fill a pipe and stall
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let timer = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        group.wait()
        let output = String(decoding: out, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let said = String(decoding: err.isEmpty ? out : err, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
            // Whatever the tool says, it never gets the value to repeat back
            let detail = input.map { said.replacingOccurrences(of: $0, with: "[REDACTED]") } ?? said
            throw Failure.failed((failure.map { $0 + ". " } ?? "") + (detail.isEmpty ? "It stopped with exit \(process.terminationStatus)." : detail))
        }
        return output
    }
}
