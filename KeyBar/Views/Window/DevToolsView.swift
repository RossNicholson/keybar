import AppKit
import SwiftUI

/// The commit guard, project key lists and the AI proxy
struct DevToolsView: View {
    @Environment(AppState.self) private var state
    @State private var listFolder: ProjectFolder?
    @State private var copied = false

    var body: some View {
        Screen {
            ScreenHeader(title: "Dev tools", subtitle: "Keep keys out of commits, and give each project only the keys it needs.")

            SectionLabel(text: "Commit guard")
            guardCard

            SectionLabel(text: "Project key lists")
            SettingCard(title: "A .keybar file per project",
                        detail: "List the keys a project uses in a .keybar file in its folder. There, Claude only sees and uses those keys, and keybar run -- COMMAND sets them. Names only, so it's safe to commit.",
                        trailing: {
                            GhostButton(title: "Make one…", symbol: "doc.badge.plus", action: chooseFolder)
                                .fixedSize()
                        }, below: {
                            code(ProjectKeys.text(for: ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]))
                        })

            SectionLabel(text: "AI proxy")
            proxyCard
        }
        .onAppear { state.refreshGuard() }
        .sheet(item: $listFolder) { folder in
            ProjectKeysEditor(folder: folder.path) { listFolder = nil }
                .environment(state)
        }
    }

    // MARK: - Commit guard

    @ViewBuilder private var guardCard: some View {
        let status = state.guardStatus
        SettingToggle(title: "Stop commits that contain a key",
                      detail: "Before every commit in every repo on this Mac, KeyBar checks the changes for the value of any key you've stored, and stops the commit if it finds one, whether you or Claude made it. Repos' own hooks still run.",
                      isOn: Binding(get: { status == .on }, set: { state.setGuard($0) })) {
            switch status {
            case .otherHooks(let path):
                SettingNote("git already uses \(BridgePolicy.tidy(path)) for hooks in every repo, so KeyBar can't turn this on. To add the check yourself, put this line in that folder's pre-commit hook:")
                code(CommitGuard.hookLine)
                GhostButton(title: copied ? "Copied" : "Copy the line", symbol: copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copyText(CommitGuard.hookLine)
                    copied = true
                }
            case .noGit:
                SettingNote("git isn't installed on this Mac.")
            case .on:
                SettingNote("On. Skip it once with git commit --no-verify. A repo with its own hooks folder (Husky, say) isn't checked.", isError: false)
            case .off:
                EmptyView()
            }
            if let note = state.guardNote { SettingNote(note) }
        }
    }

    // MARK: - Proxy

    private var proxyCard: some View {
        let proxied = state.store.active.filter(\.usesProxy)
        let possible = state.store.active.filter { KeyProxy.route(for: $0) != nil }
        return VStack(alignment: .leading, spacing: 10) {
            Text("For Anthropic, OpenAI and Groq API keys. Turn it on for a key (edit it → Through KeyBar's proxy) and commands get a placeholder instead of the key, plus a local address in ANTHROPIC_BASE_URL (or OPENAI_BASE_URL, GROQ_BASE_URL). Their SDKs call KeyBar, and KeyBar adds the key and passes the request on over HTTPS. The command never has the key, so it can't print or send it anywhere.")
                .font(.mono(10.5))
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each address only works while its command runs. A command that calls the service's own address with the key (curl to api.anthropic.com, say) gets the placeholder and fails, so it's off unless you turn it on.")
                .font(.mono(10))
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(possible) { record in
                    TagPill(text: record.name, fill: record.usesProxy ? AppColors.mint : AppColors.ground)
                        .help(record.usesProxy ? "Through KeyBar's proxy" : "Given to commands directly")
                }
            }
            if possible.isEmpty {
                SettingNote("None of your keys can use it yet: it works with API keys for Anthropic, OpenAI and Groq.", isError: false)
            } else if proxied.isEmpty {
                SettingNote("No key uses it yet.", isError: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.window)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder to list keys for"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        listFolder = ProjectFolder(path: url.path)
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.mono(10))
            .foregroundStyle(AppColors.text)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.ground, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

struct ProjectFolder: Identifiable {
    let path: String
    var id: String { path }
}

/// Picks the keys for a project's .keybar file and writes it
struct ProjectKeysEditor: View {
    @Environment(AppState.self) private var state
    let folder: String
    let done: () -> Void
    @State private var chosen: Set<String> = []
    @State private var error: String?

    private var path: String { (folder as NSString).appendingPathComponent(ProjectKeys.fileName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PopoverHeader(title: "Keys for \((folder as NSString).lastPathComponent)",
                          subtitle: "Tick the keys this project uses. KeyBar writes their names to \(BridgePolicy.tidy(path)).")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.store.active) { record in
                        let on = chosen.contains(record.name)
                        Button {
                            if on { chosen.remove(record.name) } else { chosen.insert(record.name) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? AppColors.text : AppColors.secondaryText)
                                Text(record.name)
                                    .font(.mono(10.5))
                                    .foregroundStyle(AppColors.text)
                                Spacer()
                                Text(record.displayGroup)
                                    .font(.mono(9.5))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .card(radius: Radius.small)
            if let error { SettingNote(error) }
            HStack {
                GhostButton(title: "Cancel", action: done)
                Spacer()
                PillButton(title: "Save", symbol: "checkmark", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.5 : 1)
            }
        }
        .popoverChrome(width: 460)
        .onAppear(perform: load)
    }

    /// Starts from the folder's .keybar, or its .env's keybar: references
    private func load() {
        if let text = ProjectKeys.readFile(path) {
            chosen = Set(ProjectKeys.parse(text))
        } else if let env = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(".env"), encoding: .utf8) {
            chosen = Set(EnvFile.parse(env).compactMap(\.reference))
        }
    }

    private func save() {
        let names = state.store.active.map(\.name).filter(chosen.contains)
        do {
            try Data(ProjectKeys.text(for: names).utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            done()
        } catch {
            self.error = "Couldn't write \(BridgePolicy.tidy(path)): \(error.localizedDescription)"
        }
    }
}
