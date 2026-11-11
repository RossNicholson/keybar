import Foundation

// `keybar mcp` is the MCP server Claude Code starts (registered by KeyBar's
// Connect button). It speaks MCP over stdin and stdout, asks the running
// KeyBar app for keys, and never prints a key's value.

let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

switch CommandLine.arguments.dropFirst().first {
case "mcp":
    signal(SIGPIPE, SIG_IGN)
    MCPServer(version: version).run()
case "--version", "version":
    print("keybar \(version)")
default:
    let usage = """
    keybar \(version): KeyBar's helper for Claude Code.

    Usage:
      keybar mcp        Run the MCP server (Claude Code starts this for you)
      keybar --version  Print the version

    Connect it from KeyBar → Claude Code, or by hand:
      claude mcp add --scope user keybar -- "\(CommandLine.arguments[0])" mcp

    """
    FileHandle.standardError.write(Data(usage.utf8))
    exit(CommandLine.arguments.count > 1 ? 64 : 0)
}
