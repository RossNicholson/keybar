import Foundation

// `keybar mcp` is the MCP server Claude Code starts (registered by KeyBar's
// Connect button). It speaks MCP over stdin and stdout, asks the running
// KeyBar app for keys, and never prints a key's value. `keybar run` runs a
// command in your own terminal with keys set.

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

switch CommandLine.arguments.dropFirst().first {
case "mcp":
    signal(SIGPIPE, SIG_IGN)
    MCPServer(version: version).run()
case "run":
    TerminalRun.main(Array(CommandLine.arguments.dropFirst(2)))
case "guard":
    CommitGuardCheck.main()
case "--version", "version":
    print("keybar \(version)")
default:
    let usage = """
    keybar \(version): KeyBar's helper for Claude Code and your terminal.

    Usage:
      keybar run -- COMMAND  Run a command with keys from KeyBar (keybar run --help)
      keybar mcp             Run the MCP server (Claude Code starts this for you)
      keybar guard           Stop a commit that has a stored key in it (git runs this)
      keybar --version       Print the version

    Connect it from KeyBar → Claude Code, or by hand:
      claude mcp add --scope user keybar -- "\(CommandLine.arguments[0])" mcp

    """
    FileHandle.standardError.write(Data(usage.utf8))
    exit(CommandLine.arguments.count > 1 ? 64 : 0)
}
