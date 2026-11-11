import Foundation

/// Runs one shell command with extra environment variables and collects its
/// output, up to a limit, stopping it if it runs too long
enum CommandRunner {
    struct Result: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var truncated: Bool
    }

    /// The most output kept from each of stdout and stderr
    static let maxOutput = 256 * 1024

    static func run(_ command: String, in folder: String, extraEnvironment: [String: String],
                    timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in extraEnvironment { environment[name] = value }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = Collector()
        let err = Collector()
        let group = DispatchGroup()
        for (pipe, collector) in [(outPipe, out), (errPipe, err)] {
            group.enter()
            DispatchQueue.global().async {
                collector.drain(pipe.fileHandleForReading)
                group.leave()
            }
        }

        do {
            try process.run()
        } catch {
            return Result(exitCode: 127, stdout: "", stderr: "Couldn't start the shell: \(error.localizedDescription)",
                          timedOut: false, truncated: false)
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // A command can leave a child holding the pipes open; don't wait for it forever
        _ = group.wait(timeout: .now() + 2)

        return Result(exitCode: process.terminationStatus, stdout: out.text, stderr: err.text,
                      timedOut: timedOut, truncated: out.truncated || err.truncated)
    }

    /// The user's shell if it's zsh or bash, so the command runs as it would in their terminal
    private static var shell: String {
        let preferred = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if ["/bin/zsh", "/bin/bash"].contains(preferred) { return preferred }
        return "/bin/zsh"
    }
}

/// Reads a pipe to the end, keeping only the first `maxOutput` bytes
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private(set) var truncated = false

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            lock.lock()
            let room = CommandRunner.maxOutput - data.count
            if room > 0 { data.append(chunk.prefix(room)) }
            if chunk.count > room { truncated = true }
            lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
