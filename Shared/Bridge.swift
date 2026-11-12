import Foundation

// How the `keybar` helper (the MCP server Claude Code starts) and the KeyBar
// app talk: one JSON request and one JSON reply per connection, over a Unix
// socket in ~/.keybar that only this user can open. The app also checks the
// helper's code signature before it answers.

enum Bridge {
    /// ~/.keybar: the socket, the index of key names and the activity log.
    /// Key values are never written here; they live in the Keychain.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keybar", isDirectory: true)
    }

    static var socketPath: String { directory.appendingPathComponent("keybar.sock").path }

    static let appBundleID = "com.rossnicholson.KeyBar"
    /// Who `keybar run` says is asking, in the activity log and Touch ID prompt
    static let terminalClient = "keybar run"
    static let helperIdentifier = "com.rossnicholson.KeyBar.helper"

    /// The longest we wait for the app to answer
    static let replyTimeout: TimeInterval = 30

    /// How long the user has to add a key Claude asked for
    static let requestTimeout: TimeInterval = 300

    /// What to call the app that started us, from the name it gives
    static func label(forClient name: String) -> String {
        let lower = name.lowercased()
        let known: [(String, String)] = [
            ("claude-code", "Claude Code"), ("claude code", "Claude Code"), ("claude-ai", "Claude Desktop"),
            ("claude desktop", "Claude Desktop"), ("cursor", "Cursor"), ("windsurf", "Windsurf"), ("codex", "Codex"),
            ("gemini", "Gemini CLI"), ("visual studio code", "VS Code"), ("vscode", "VS Code"), ("zed", "Zed"),
        ]
        if let match = known.first(where: { lower.contains($0.0) }) { return match.1 }
        // KeyBar's own Connect test, and older Claude Code versions
        if lower.contains("claude") { return "Claude Code" }
        return String(name.prefix(40))
    }

    /// The only extra variables a `resolve` reply may set
    static let proxyVariables: Set<String> = ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "GROQ_BASE_URL"]
    /// What a proxied key's variable is set to instead of the key
    static let proxyPlaceholder = "keybar-proxy"

    /// Keeps only proxy variables that point at KeyBar on this Mac
    static func proxyEnvironment(_ environment: [String: String]?) -> [String: String] {
        (environment ?? [:]).filter { name, value in
            proxyVariables.contains(name) && value.hasPrefix("http://127.0.0.1:") && !value.contains(where: \.isNewline)
        }
    }

    /// How long the app leaves a Touch ID prompt up, and how long the helper
    /// waits for a reply when there might be one (a little longer)
    static let approvalTimeout: TimeInterval = 170
    static let resolveTimeout: TimeInterval = 180
}

struct BridgeRequest: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        /// The names of the stored keys (never their values)
        case list
        /// The values of some keys, to run one command with
        case resolve
        /// How that command went, for the activity log
        case finished
        /// Send one key to a GitHub repo or Cloudflare. The app sends it; the
        /// helper never sees the value.
        case send
        /// Ask the user to add a key that isn't stored yet
        case request
        /// Which stored keys are in some text (a commit's changes), by name:
        /// never values either way
        case check
    }

    var action: Action
    /// The folder the command runs in, for keys limited to some projects
    var cwd: String
    /// The folder Claude Code was started in. A key limited to some projects
    /// must be allowed in this one too, whatever `cwd` the command asks for.
    var projectFolder: String? = nil
    /// Who's asking, shown in the activity log, e.g. "Claude Code"
    var client: String = "Claude Code"
    var names: [String]? = nil
    var command: String? = nil
    var runID: String? = nil
    var exitCode: Int32? = nil
    var redactions: Int? = nil
    var timedOut: Bool? = nil
    /// For `send`
    var destination: Destination? = nil
    /// For `request`: why it's wanted, shown to the user
    var reason: String? = nil
    /// For `check`: file → the text to look in
    var texts: [String: String]? = nil
}

/// A stored key as the helper sees it: everything but the value
struct SecretSummary: Codable, Sendable, Equatable {
    var name: String
    var service: String?
    var kind: String
    var group: String?
    var note: String?
    /// Limited to some project folders
    var restricted: Bool
    /// Can be used from the folder in the request
    var availableHere: Bool
    /// A key that's a whole file: commands get a path to it
    var fileName: String? = nil
    var expiresAt: Date? = nil
    /// Used through KeyBar's proxy: commands get a placeholder, and this
    /// variable (e.g. ANTHROPIC_BASE_URL) is the address to call instead
    var proxyVariable: String? = nil
}

struct BridgeReply: Codable, Sendable {
    var ok: Bool
    var error: String? = nil
    var secrets: [SecretSummary]? = nil
    var values: [String: String]? = nil
    /// Which of `values` are files, by key name: the file's name
    var files: [String: String]? = nil
    var runID: String? = nil
    /// What happened, for `send` and `request`
    var message: String? = nil
    /// For `resolve`: more variables to set, for keys used through KeyBar's
    /// proxy (e.g. ANTHROPIC_BASE_URL). The helper only takes the names in
    /// `Bridge.proxyVariables`, pointing at this Mac.
    var environment: [String: String]? = nil
    /// For `check`: file → the keys found in it
    var found: [String: [String]]? = nil
    /// The app turned the caller away: it isn't KeyBar's signed helper. A
    /// helper that's been running since before an update gets this, because
    /// its file on disk has changed.
    var refused: Bool? = nil

    static func failure(_ message: String) -> BridgeReply { BridgeReply(ok: false, error: message) }
}

enum BridgeError: Error, CustomStringConvertible {
    case unreachable
    case io(String)
    case badReply
    case notKeyBar

    var description: String {
        switch self {
        case .unreachable: return "KeyBar isn't running, and couldn't be started."
        case .io(let detail): return "Couldn't talk to KeyBar (\(detail))."
        case .badReply: return "KeyBar sent a reply that couldn't be read."
        case .notKeyBar: return "Something other than KeyBar is listening on KeyBar's socket, so no keys were asked for. Quit and reopen KeyBar."
        }
    }
}

/// Socket plumbing both sides use
enum BridgeSocket {
    /// The most a request or reply may be, so nothing can make either side
    /// read forever
    static let maxMessage = 4 * 1024 * 1024

    /// A sockaddr_un for `path`, or nil if the path is too long for one
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }

    /// Sends one request to the app and waits for its reply. `server` checks
    /// who's listening before anything is sent.
    static func send(_ request: BridgeRequest, path: String = Bridge.socketPath,
                     timeout: TimeInterval = Bridge.replyTimeout,
                     server: (Int32) -> Bool = { _ in true }) throws -> BridgeReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.io("socket") }
        defer { close(fd) }
        guard var addr = address(path) else { throw BridgeError.io("socket path too long") }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw BridgeError.unreachable }
        guard server(fd) else { throw BridgeError.notKeyBar }
        setTimeout(fd, timeout)

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try writeAll(fd, data)
        let line = try readLine(fd)
        guard let reply = try? JSONDecoder().decode(BridgeReply.self, from: line) else { throw BridgeError.badReply }
        return reply
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // Don't die of SIGPIPE if the other side goes away mid-write
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, base + sent, buffer.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BridgeError.io("write failed")
                }
                sent += n
            }
        }
    }

    /// Reads up to the first newline (not included)
    static func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw BridgeError.io(errno == EAGAIN ? "timed out" : "read failed")
            }
            if n == 0 { break }
            if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                result.append(contentsOf: chunk[0..<newline])
                return result
            }
            result.append(contentsOf: chunk[0..<n])
            if result.count > maxMessage { throw BridgeError.io("message too long") }
        }
        guard !result.isEmpty else { throw BridgeError.io("connection closed") }
        return result
    }
}
