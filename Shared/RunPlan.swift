import Foundation

/// What `keybar run` was asked to do: which keys to set, under which
/// environment variable names, and the command to run with them.
///
///     keybar run -- npm run dev                 keys from ./.env's keybar: lines
///     keybar run --key CLOUDFLARE_API_TOKEN -- wrangler deploy
///     keybar run --key TOKEN=MADROBOT_TOKEN -- ./deploy.sh
///     keybar run --env-file .env.production -- npm start
struct RunPlan: Equatable, Sendable {
    /// Environment variable → the stored key it gets
    var keys: [String: String] = [:]
    /// Plain NAME=value lines from the env files, set (like dotenv does) only
    /// when the environment doesn't have them already
    var plain: [String: String] = [:]
    /// The env files read, for messages
    var envFiles: [String] = []
    var command: [String] = []

    /// The stored keys to ask KeyBar for
    var storedNames: [String] { Array(Set(keys.values)).sorted() }

    /// The command as one line, for the Touch ID prompt and the activity log
    var commandLine: String { command.map(Self.quoted).joined(separator: " ") }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case help
        case noCommand
        case badKey(String)
        case missingValue(String)
        case unknownOption(String)
        case unreadable(String)
        case nothingToSet

        var description: String {
            switch self {
            case .help: return ""
            case .noCommand: return "Give a command to run after --, e.g. keybar run -- npm run dev"
            case .badKey(let key): return "\"\(key)\" isn't a key name. Use NAME, or VARIABLE=NAME to set a key under another name."
            case .missingValue(let option): return "\(option) needs a value."
            case .unknownOption(let option): return "keybar run has no option \(option)."
            case .unreadable(let path): return "Couldn't read \(path)."
            case .nothingToSet:
                return "No keys to set. Name some with --key NAME, or put NAME=keybar:STORED_NAME lines in .env "
                    + "(KeyBar's Find keys can write them for you)."
            }
        }
    }

    /// The default env file, read when it's there and no --env-file is given
    static let defaultEnvFile = ".env"

    /// Reads `keybar run`'s arguments (the ones after `run`). `read` returns a
    /// file's text, or nil if it can't be read.
    static func make(_ arguments: [String], in folder: String, read: (String) -> String?) throws -> RunPlan {
        var plan = RunPlan()
        var envFiles: [String] = []
        var useDefault = true
        var index = 0

        func value(for option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw Problem.missingValue(option) }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--":
                plan.command = Array(arguments[(index + 1)...])
                index = arguments.count
                continue
            case "-h", "--help":
                throw Problem.help
            case "-k", "--key":
                try plan.addKey(try value(for: argument))
            case "-e", "--env-file":
                envFiles.append(try value(for: argument))
            case "--no-env-file":
                useDefault = false
            default:
                if argument.hasPrefix("--key=") {
                    try plan.addKey(String(argument.dropFirst(6)))
                } else if argument.hasPrefix("--env-file=") {
                    envFiles.append(String(argument.dropFirst(11)))
                } else if argument.hasPrefix("-") {
                    throw Problem.unknownOption(argument)
                } else {
                    // The command starts at the first word that isn't an option
                    plan.command = Array(arguments[index...])
                    index = arguments.count
                    continue
                }
            }
            index += 1
        }
        guard !plan.command.isEmpty else { throw Problem.noCommand }

        let explicitFiles = !envFiles.isEmpty
        if !explicitFiles && useDefault { envFiles = [defaultEnvFile] }
        for file in envFiles {
            let path = file.hasPrefix("/") ? file : (folder as NSString).appendingPathComponent(file)
            guard let text = read(path) else {
                // The default .env is optional; one you named isn't
                if explicitFiles { throw Problem.unreadable(file) }
                continue
            }
            plan.envFiles.append(file)
            for entry in EnvFile.parse(text) {
                if let stored = entry.reference {
                    // --key wins over the file
                    if plan.keys[entry.name] == nil { plan.keys[entry.name] = stored }
                } else {
                    plan.plain[entry.name] = entry.value
                }
            }
        }
        // A variable set from a key isn't also set from a plain line
        for variable in plan.keys.keys { plan.plain[variable] = nil }
        guard !plan.keys.isEmpty else { throw Problem.nothingToSet }
        return plan
    }

    /// NAME, or VARIABLE=NAME
    private mutating func addKey(_ text: String) throws {
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        let variable = parts[0]
        let stored = parts.count == 2 ? parts[1] : parts[0]
        guard SecretName.isValid(variable), SecretName.isValid(stored) else { throw Problem.badKey(text) }
        keys[variable] = stored
    }

    /// A word quoted the way a shell would need it
    static func quoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
