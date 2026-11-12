import Darwin
import Foundation

/// Whether a process was started by Claude Code, for `keybar run`, whose
/// output isn't redacted. Claude Code marks the commands it runs with
/// CLAUDECODE, but a command can drop that (`env -u CLAUDECODE …`), so the
/// processes it was started from are looked at too.
enum ClaudeCodeCheck {
    static let variables = ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]

    static func isInsideClaudeCode(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if variables.contains(where: { environment[$0] != nil }) { return true }
        return ancestors().contains { looksLikeClaudeCode(path: $0.path, arguments: $0.arguments) }
    }

    /// Claude Code's own program: the native `claude` (installed as
    /// …/claude/versions/2.1.5), or node running the npm package
    static func looksLikeClaudeCode(path: String, arguments: [String]) -> Bool {
        let candidates = [path] + arguments.prefix(2)
        return candidates.contains { item in
            (item as NSString).lastPathComponent == "claude"
                || item.contains("/claude/versions/")
                || item.contains("/@anthropic-ai/claude-code/")
        }
    }

    /// The processes this one was started from, nearest first, up to launchd
    static func ancestors() -> [(path: String, arguments: [String])] {
        var found: [(String, [String])] = []
        var pid = getppid()
        var seen = Set<pid_t>()
        while pid > 1, seen.insert(pid).inserted, found.count < 64 {
            found.append(commandLine(of: pid))
            guard let parent = parent(of: pid) else { break }
            pid = parent
        }
        return found
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// A process's program and arguments (KERN_PROCARGS2: argc, the program's
    /// path, padding, then the arguments, each ending in NUL)
    private static func commandLine(of pid: pid_t) -> (String, [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ("", []) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ("", []) }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var parts: [String] = []
        var start = MemoryLayout<Int32>.size
        var index = start
        // The path, then NUL padding, then argc arguments
        while index < size, parts.count <= Int(argc) {
            if buffer[index] == 0 {
                if index > start { parts.append(String(decoding: buffer[start..<index], as: UTF8.self)) }
                start = index + 1
            }
            index += 1
        }
        guard let path = parts.first else { return ("", []) }
        return (path, Array(parts.dropFirst()))
    }
}
