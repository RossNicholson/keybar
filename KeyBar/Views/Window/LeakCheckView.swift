import AppKit
import SwiftUI

/// Looks for stored keys where they shouldn't be: AI tools' transcripts and
/// settings, shell history and git history
struct LeakCheckView: View {
    @Environment(AppState.self) private var state
    @State private var notes: [String: String] = [:]
    @State private var rotating: String?

    var body: some View {
        @Bindable var settings = state.settings
        Screen {
            ScreenHeader(title: "Leak check",
                         subtitle: "Finds your stored keys anywhere they've been copied: AI chats, shell history, git history.") {
                PillButton(title: state.isCheckingLeaks ? "Checking…" : "Check now", symbol: "magnifyingglass") {
                    Task { await state.checkLeaks() }
                }
                .disabled(state.isCheckingLeaks)
                .fixedSize()
            }

            if state.isCheckingLeaks {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking in \(state.leakProgress ?? "…")")
                        .font(.mono(10.5))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            if let leaks = state.leaks, !state.isCheckingLeaks {
                let visible = state.visibleLeaks
                if visible.isEmpty {
                    summary(title: "No leaks found",
                            message: "None of your keys turned up in the places KeyBar looked\(leaks.isEmpty ? "" : " (apart from ones you chose to leave)").",
                            fill: AppColors.mint, happy: true)
                } else {
                    let names = Set(visible.map(\.name))
                    summary(title: names.count == 1 ? "1 key has leaked" : "\(names.count) keys have leaked",
                            message: "Each one below is somewhere other than KeyBar, so it may have been sent to an AI service or shared. Hiding the copies helps, but the safe fix is a new key: Rotate walks you through it.",
                            fill: AppColors.coral, happy: false)
                    ForEach(names.sorted(), id: \.self) { name in
                        keyLeaks(name, visible.filter { $0.name == name })
                    }
                }
            } else if !state.isCheckingLeaks {
                summary(title: "Not checked yet",
                        message: state.settings.leakCheckedAt.map { "Last checked \($0.formatted(.relative(presentation: .named))). Check again to see the results here." }
                            ?? "Check to look through the places keys tend to leak. Nothing leaves your Mac.",
                        fill: AppColors.butter, happy: true)
            }

            SectionLabel(text: "Where it looks")
            VStack(alignment: .leading, spacing: 8) {
                place("Claude Code", "Transcripts, prompt history and settings in ~/.claude and ~/.claude.json")
                place("Other AI tools", "Codex, Gemini CLI, Cursor, Windsurf and Claude Desktop's chats and settings")
                place("Shell history", "zsh, bash and fish history, and Python, Node and database consoles")
                place("Git history", "Every commit in the repositories under your Find keys folders")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: Radius.window)
            SettingToggle(title: "Include git history",
                          detail: "Reads every commit in the repositories under the folders Find keys searches. Slower, and a key in git history can't be hidden: rotate it.",
                          isOn: $settings.leakCheckGit)
            Text("KeyBar only looks for the exact keys you've stored, so it doesn't flag lookalikes. Account IDs and publishable keys aren't secret and are skipped.")
                .font(.mono(10))
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: Binding(get: { rotating.map(RotateTarget.init) }, set: { rotating = $0?.name })) { target in
            RotateKeyView(name: target.name) { rotating = nil }
                .environment(state)
        }
    }

    private func summary(title: String, message: String, fill: Color, happy: Bool) -> some View {
        HStack(spacing: 18) {
            Mascot(mood: happy ? .happy : .sleepy, size: 64, disc: .white.opacity(0.55))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.display(24, relativeTo: .title))
                    .textCase(.uppercase)
                Text(message)
                    .font(.mono(10.5))
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .pastelCard(fill, radius: Radius.hero)
    }

    private func keyLeaks(_ name: String, _ leaks: [Leak]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let record = state.store.record(name) { ServiceTile(record: record, size: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.mono(12, weight: .semibold))
                        .foregroundStyle(AppColors.text)
                    Text("\(leaks.count) place\(leaks.count == 1 ? "" : "s")")
                        .font(.mono(9.5))
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                PillButton(title: "Rotate", symbol: "arrow.triangle.2.circlepath", circle: AppColors.coral) { rotating = name }
                    .fixedSize()
            }
            ForEach(leaks) { leak in
                leakRow(leak)
            }
        }
        .padding(14)
        .card(radius: Radius.window)
    }

    private func leakRow(_ leak: Leak) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                TagPill(text: leak.place.title, fill: leak.place == .gitHistory ? AppColors.lilac : AppColors.peach)
                VStack(alignment: .leading, spacing: 1) {
                    Text(BridgePolicy.tidy(leak.path))
                        .font(.mono(10))
                        .foregroundStyle(AppColors.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text((leak.detail.map { $0 + " · " } ?? "") + "\(leak.count) cop\(leak.count == 1 ? "y" : "ies")")
                        .font(.mono(9))
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                }
                .help(leak.path)
                Spacer(minLength: 6)
                if leak.canHide {
                    GhostButton(title: "Hide", symbol: "eye.slash") { notes[leak.id] = state.hideLeak(leak) }
                        .help("Replace each copy in this file with [REDACTED]")
                }
                GhostButton(title: "Show", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: leak.path)])
                }
                Button { state.ignoreLeak(leak) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Leave this one: don't show it again")
            }
            if let note = notes[leak.id] { SettingNote(note, isError: false) }
        }
        .padding(.vertical, 2)
    }

    private func place(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.mono(10.5, weight: .semibold))
                .foregroundStyle(AppColors.text)
                .frame(width: 120, alignment: .leading)
            Text(detail)
                .font(.mono(10.5))
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A key to rotate, as a sheet item
struct RotateTarget: Identifiable {
    let name: String
    var id: String { name }
}
