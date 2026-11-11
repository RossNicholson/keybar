import SwiftUI

/// Connecting Claude Code, testing it, and how it works
struct ClaudeCodeView: View {
    @Environment(AppState.self) private var state
    @State private var showingManual = false
    @State private var copiedCommand = false

    var body: some View {
        @Bindable var settings = state.settings
        let claude = state.claude
        Screen {
            ScreenHeader(title: "Claude Code", subtitle: "Let Claude Code use your keys without ever seeing them.")
            hero

            if let error = claude.lastError { SettingNote(error) }
            if let result = claude.testResult {
                switch result {
                case .passed(let message): resultCard(message, ok: true)
                case .failed(let message): resultCard(message, ok: false)
                }
            }

            SectionLabel(text: "Options")
            SettingToggle(title: "Add a note to CLAUDE.md",
                          detail: "Adds a short marked section to ~/.claude/CLAUDE.md telling Claude to check KeyBar before asking you to paste a key. KeyBar's MCP server already tells Claude this; the note makes it stick. Disconnecting removes it.",
                          isOn: Binding(get: { claude.hasReminder }, set: { on in
                              settings.addClaudeReminder = on
                              claude.setReminder(on)
                          }))

            SettingCard(title: "Set up by hand", detail: "Run this in Terminal, or add the JSON to the mcpServers in ~/.claude.json.", trailing: {
                GhostButton(title: showingManual ? "Hide" : "Show") { withAnimation { showingManual.toggle() } }
            }, below: {
                if showingManual {
                    code(claude.manualCommand)
                    HStack {
                        GhostButton(title: copiedCommand ? "Copied" : "Copy command", symbol: copiedCommand ? "checkmark" : "doc.on.doc") {
                            Clipboard.copyText(claude.manualCommand)
                            copiedCommand = true
                        }
                        GhostButton(title: "Copy JSON", symbol: "curlybraces") { Clipboard.copyText(claude.manualJSON) }
                    }
                }
            })

            SectionLabel(text: "How it works")
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Claude asks KeyBar which keys there are. It gets names like CLOUDFLARE_API_TOKEN, never values.")
                step(2, "To use one, Claude asks KeyBar to run a command and refers to the key as $CLOUDFLARE_API_TOKEN.")
                step(3, "KeyBar sets the key as an environment variable for that one command, and refuses commands that contain a key's actual value.")
                step(4, "Claude gets back what the command printed, with any copy of the key (as written, base64, URL-encoded, hex or a long fragment of it) replaced by [REDACTED].")
                step(5, "Every use is in Activity: which key, which program, and when.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: Radius.window)

            SectionLabel(text: "What it can't stop")
            VStack(alignment: .leading, spacing: 8) {
                Text("The command itself has the key, so a command could change it before printing it (reverse it, say) or send it somewhere over the network. Hiding it in the output is a safety net, not a sandbox. Claude Code asks you before running commands unless you've told it not to, so read what it wants to run.")
                Text("To limit the risk, lock keys to the project folders that need them (Keys → edit a key → Limit to a folder).")
            }
            .font(.mono(10.5))
            .foregroundStyle(AppColors.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelCard(AppColors.lilac, radius: Radius.window)
        }
        .onAppear { claude.refresh() }
    }

    // MARK: - Status

    @ViewBuilder private var hero: some View {
        let claude = state.claude
        let (title, message, fill): (String, String, Color) = {
            switch claude.status {
            case .connected:
                return ("Connected", "Claude Code can list your keys and use them in commands. New Claude Code sessions pick this up; restart any that are open.", AppColors.mint)
            case .elsewhere(let path):
                return ("Connected to another copy", "Claude Code is set up to use \(BridgePolicy.tidy(path)), not this KeyBar. Reconnect to fix it.", AppColors.peach)
            case .disconnected:
                return ("Not connected", "Connect to add KeyBar's MCP server to Claude Code for all your projects. You can undo it here at any time.", AppColors.butter)
            }
        }()
        HStack(spacing: 20) {
            Mascot(mood: claude.status == .connected ? .happy : .sleepy, size: 84, disc: .white.opacity(0.55))
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.display(28, relativeTo: .title))
                    .textCase(.uppercase)
                Text(message)
                    .font(.mono(11))
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if claude.isWorking {
                        ProgressView().controlSize(.small)
                    }
                    switch claude.status {
                    case .connected:
                        PillButton(title: "Test connection", symbol: "checkmark", circle: AppColors.mint) {
                            Task { await claude.test() }
                        }
                        GhostButton(title: "Disconnect") { Task { await claude.disconnect() } }
                    case .elsewhere:
                        PillButton(title: "Reconnect", symbol: "arrow.triangle.2.circlepath") {
                            Task { await claude.connect(addReminder: state.settings.addClaudeReminder) }
                        }
                        GhostButton(title: "Disconnect") { Task { await claude.disconnect() } }
                    case .disconnected:
                        PillButton(title: "Connect Claude Code", symbol: "arrow.right") {
                            Task { await claude.connect(addReminder: state.settings.addClaudeReminder) }
                        }
                        GhostButton(title: "Test the helper") { Task { await claude.test() } }
                    }
                }
                .disabled(claude.isWorking)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .pastelCard(fill, radius: Radius.hero)
    }

    private func resultCard(_ message: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.mono(10.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .pastelCard(ok ? AppColors.mint : AppColors.coral, radius: Radius.row)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.display(15, relativeTo: .headline))
                .foregroundStyle(AppColors.ink)
                .frame(width: 22, height: 22)
                .background(AppColors.pastels[(number - 1) % AppColors.pastels.count], in: Circle())
            Text(text)
                .font(.mono(10.5))
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.mono(10.5))
            .foregroundStyle(AppColors.text)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.ground, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}
