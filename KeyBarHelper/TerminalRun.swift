import Foundation

/// `keybar run`: runs a command in your terminal with keys from KeyBar set as
/// environment variables, so a project's .env can hold `keybar:` references
/// instead of the keys. KeyBar asks with Touch ID first and shows the command.
/// Output isn't redacted: it's your own terminal, not Claude's transcript.
enum TerminalRun {
    static let usage = """
    keybar run: run a command with keys from KeyBar set as environment variables.

    Usage:
      keybar run [options] -- COMMAND [ARGS...]

    Keys come from NAME=keybar:STORED_NAME lines in ./.env, the names in the
    project's .keybar file, and --key. Other lines in the .env are set too,
    unless they're set already.

    Options:
      -k, --key NAME            Set the stored key NAME as $NAME
      -k, --key VARIABLE=NAME   Set the stored key NAME as $VARIABLE
      -e, --env-file PATH       Read this file instead of ./.env (can repeat)
          --no-env-file         Don't read ./.env

    Examples:
      keybar run -- npm run dev
      keybar run --key CLOUDFLARE_API_TOKEN -- wrangler deploy

    """

    static func main(_ arguments: [String]) -> Never {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let plan: RunPlan
        do {
            plan = try RunPlan.make(arguments, in: folder) { try? String(contentsOfFile: $0, encoding: .utf8) }
        } catch RunPlan.Problem.help {
            print(usage, terminator: "")
            exit(0)
        } catch {
            fail("\(error)", code: 64)
        }

        // Claude Code marks the commands it runs. Its way to use keys is the
        // run_with_secrets tool, which hides them in what Claude reads back.
        if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil {
            fail("keybar run is for your own terminal. From Claude Code, use KeyBar's run_with_secrets tool, "
                + "which keeps keys out of the output.", code: 77)
        }

        let reply: BridgeReply
        do {
            reply = try AppLink.send(BridgeRequest(action: .resolve, cwd: folder, projectFolder: folder,
                                                   client: Bridge.terminalClient, names: plan.storedNames,
                                                   command: plan.commandLine),
                                     timeout: Bridge.resolveTimeout)
        } catch {
            fail("\(error)", code: 69)
        }
        guard reply.ok, let values = reply.values else { fail(reply.error ?? "KeyBar refused.", code: 77) }

        var environment = ProcessInfo.processInfo.environment
        for (name, value) in plan.plain where environment[name] == nil {
            environment[name] = value
        }
        let keyFiles: KeyFiles
        do {
            keyFiles = try KeyFiles(values: values, files: reply.files ?? [:])
        } catch {
            fail("Couldn't write the file keys: \(error.localizedDescription)", code: 77)
        }
        for (name, value) in Bridge.proxyEnvironment(reply.environment) { environment[name] = value }
        let given = keyFiles.environment(values)
        for (variable, stored) in plan.keys {
            guard let value = given[stored] else { fail("KeyBar didn't send \(stored).", code: 77) }
            environment[variable] = value
        }

        let status = spawn(plan.command, environment: environment)
        keyFiles.remove()
        _ = try? AppLink.send(BridgeRequest(action: .finished, cwd: folder, client: Bridge.terminalClient,
                                            runID: reply.runID, exitCode: status), timeout: 5)
        exit(status)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("keybar: \(message)\n".utf8))
        exit(code)
    }

    /// Runs the command in the foreground with this terminal, and returns its
    /// exit status (128 + the signal if a signal ended it)
    private static func spawn(_ command: [String], environment: [String: String]) -> Int32 {
        // Ctrl-C and Ctrl-\ reach the whole foreground group, the command
        // included: let it decide, and wait for it. TERM and HUP are passed on.
        let forwarded = [SIGTERM, SIGHUP]
        for signal in [SIGINT, SIGQUIT] + forwarded { Foundation.signal(signal, SIG_IGN) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Ignored signals would stay ignored in the command; give it the defaults
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGQUIT] + forwarded { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawnp(&pid, command[0], nil, &attributes, argv, envp)
        guard result == 0 else {
            FileHandle.standardError.write(Data("keybar: couldn't run \(command[0]): \(String(cString: strerror(result)))\n".utf8))
            return 127
        }

        let child = pid
        let sources = forwarded.map { signal in
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            source.setEventHandler { kill(child, signal) }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno != EINTR { return 1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
