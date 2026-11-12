import AppKit
import SwiftUI

/// Find keys on this Mac: choose where to look, pick what to import, then
/// optionally swap the .env files' values for keybar: references
struct FindKeysView: View {
    @Environment(AppState.self) private var state
    let done: () -> Void

    private enum Step { case choose, scanning, review, imported }
    @State private var step = Step.choose
    @State private var shellProfiles = true
    @State private var claudeCode = true
    @State private var toolCredentials = true
    @State private var candidates: [ScanCandidate] = []
    @State private var importedCount = 0
    @State private var swapFiles: Set<String> = []
    @State private var swap: AppState.SwapResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .choose: choose
            case .scanning: scanning
            case .review: review
            case .imported: imported
            }
        }
        .popoverChrome(width: 600)
    }

    // MARK: - Where to look

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(title: "Find keys on this Mac",
                          subtitle: "KeyBar looks through these places for API keys and tokens. Nothing leaves your Mac, values aren't shown, and no file is changed unless you ask.")
            SettingCard(title: "Project folders", detail: ".env files and .mcp.json files, not going into node_modules, builds or hidden folders") {
                GhostButton(title: "Add folder", symbol: "plus") { addFolder() }
            } below: {
                if state.settings.scanFolders.isEmpty {
                    Text("No folders yet. Add the one your projects are in.")
                        .font(.mono(10)).foregroundStyle(AppColors.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.settings.scanFolders, id: \.self) { folder in
                            HStack {
                                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(AppColors.secondaryText)
                                Text(BridgePolicy.tidy(folder)).font(.mono(10.5)).foregroundStyle(AppColors.text)
                                Spacer()
                                Button {
                                    state.settings.scanFolders.removeAll { $0 == folder }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AppColors.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .help("Don't look here")
                            }
                        }
                    }
                }
            }
            SettingToggle(title: "Shell startup files", detail: "export lines in ~/.zshrc, ~/.zprofile, ~/.bashrc and the like",
                          isOn: $shellProfiles)
            SettingToggle(title: "Claude Code's MCP servers", detail: "keys in the env of MCP servers in ~/.claude.json",
                          isOn: $claudeCode)
            SettingToggle(title: "AWS and npm", detail: "access keys in ~/.aws/credentials, tokens in ~/.npmrc",
                          isOn: $toolCredentials)
            HStack {
                Spacer()
                GhostButton(title: "Cancel", action: done)
                PillButton(title: "Find keys", symbol: "magnifyingglass") { scan() }
                    .disabled(!canScan)
                    .opacity(canScan ? 1 : 0.5)
            }
        }
    }

    private var canScan: Bool {
        !state.settings.scanFolders.isEmpty || shellProfiles || claudeCode || toolCredentials
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a folder to look in"
        panel.prompt = "Add"
        panel.message = "Choose the folder your projects are in. KeyBar looks for .env files inside it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.resolvingSymlinksInPath().path
            if !state.settings.scanFolders.contains(path) { state.settings.scanFolders.append(path) }
        }
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            PopoverHeader(title: "Looking for keys", subtitle: "Going through your folders. Big ones can take a little while.")
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func scan() {
        let places = KeyScanner.Places(folders: state.settings.scanFolders.map { URL(fileURLWithPath: $0) },
                                       shellProfiles: shellProfiles, claudeCode: claudeCode,
                                       toolCredentials: toolCredentials)
        step = .scanning
        Task {
            let found = await Task.detached { KeyScanner(places: places).scan() }.value
            candidates = state.plan(found).sorted(by: Self.order)
            step = .review
        }
    }

    /// New keys first, by where they were found; ones KeyBar has last
    private static func order(_ a: ScanCandidate, _ b: ScanCandidate) -> Bool {
        if (a.status == .stored) != (b.status == .stored) { return b.status == .stored }
        if a.whereFound != b.whereFound { return a.whereFound.localizedStandardCompare(b.whereFound) == .orderedAscending }
        return a.name < b.name
    }

    // MARK: - What to import

    private var chosen: Int { candidates.filter { $0.include && $0.status != .stored }.count }
    private var newCount: Int { candidates.filter { $0.status != .stored }.count }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            let stored = candidates.count - newCount
            PopoverHeader(title: candidates.isEmpty ? "No keys found" : "Found \(candidates.count) key\(candidates.count == 1 ? "" : "s")",
                          subtitle: candidates.isEmpty
                            ? "Nothing that looks like an API key or token turned up. Try adding another folder."
                            : "\(newCount) new\(stored > 0 ? ", \(stored) already in KeyBar" : ""). Values aren't shown. A name another key already has gets the project's name in front; you can change it.")
            if !candidates.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($candidates) { $candidate in
                            CandidateRow(candidate: $candidate)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            if let error { SettingNote(error) }
            HStack {
                if newCount > 0 {
                    GhostButton(title: chosen == newCount ? "Select none" : "Select all") {
                        let all = chosen != newCount
                        for index in candidates.indices where candidates[index].status != .stored {
                            candidates[index].include = all
                        }
                    }
                }
                Spacer()
                GhostButton(title: candidates.isEmpty ? "Back" : "Cancel") {
                    if candidates.isEmpty { step = .choose } else { done() }
                }
                if !candidates.isEmpty {
                    PillButton(title: chosen == 0 ? "Next" : "Import \(chosen)", symbol: "square.and.arrow.down") { importChosen() }
                }
            }
        }
    }

    private func importChosen() {
        error = nil
        do {
            importedCount = chosen
            candidates = try state.importFound(candidates)
            swapFiles = Set(state.swappableFiles(candidates))
            step = .imported
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Swapping .env values for references

    private var imported: some View {
        VStack(alignment: .leading, spacing: 12) {
            let files = state.swappableFiles(candidates)
            PopoverHeader(title: importedCount == 0 ? "Nothing new imported" : "Imported \(importedCount) key\(importedCount == 1 ? "" : "s")",
                          subtitle: "They're in your Keychain now, and Claude Code can use them through KeyBar.")
            if let swap {
                SettingCard(title: "Swapped \(swap.swapped) value\(swap.swapped == 1 ? "" : "s") in \(swap.files) file\(swap.files == 1 ? "" : "s")",
                            detail: "Run those projects with keybar run, e.g. keybar run -- npm run dev, and the keys are set for them.", below: {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(swap.failed, id: \.self) { SettingNote("Couldn't change \($0)") }
                        if !swap.skipped.isEmpty {
                            SettingNote("Left as they were (a value over several lines): \(swap.skipped.joined(separator: ", "))", isError: false)
                        }
                    }
                })
            } else if !files.isEmpty {
                SettingCard(title: "Take the keys out of your .env files?",
                            detail: "Each value is swapped for a reference, e.g. STRIPE_SECRET_KEY=keybar:STRIPE_SECRET_KEY, so the file no longer holds the key. Then run the project with keybar run -- npm run dev: KeyBar asks with Touch ID and sets the keys for it. Other lines aren't changed.", below: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(files, id: \.self) { path in
                                Toggle(isOn: Binding(get: { swapFiles.contains(path) },
                                                     set: { if $0 { swapFiles.insert(path) } else { swapFiles.remove(path) } })) {
                                    Text(label(for: path)).font(.mono(10.5)).foregroundStyle(AppColors.text)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                })
            }
            if candidates.contains(where: { $0.status == .stored && $0.sources.contains { !$0.canHoldReferences } }) {
                SettingNote("Shell startup files, Claude Code's settings and the AWS and npm files aren't changed. Take the keys out of them yourself once nothing needs them there.", isError: false)
            }
            HStack {
                Spacer()
                if swap == nil && !files.isEmpty {
                    GhostButton(title: "Not now", action: done)
                    PillButton(title: "Swap \(swapFiles.count) file\(swapFiles.count == 1 ? "" : "s")", symbol: "arrow.left.arrow.right") {
                        swap = state.swapReferences(candidates, in: files.filter(swapFiles.contains))
                    }
                    .disabled(swapFiles.isEmpty)
                    .opacity(swapFiles.isEmpty ? 0.5 : 1)
                } else {
                    PillButton(title: "Done", symbol: "checkmark", action: done)
                }
            }
        }
    }

    private func label(for path: String) -> String {
        candidates.flatMap(\.sources).first { $0.path == path }?.label ?? BridgePolicy.tidy(path)
    }
}

/// One found key: tick to import, its name (editable), its service and where it was
private struct CandidateRow: View {
    @Binding var candidate: ScanCandidate

    var body: some View {
        let record = candidate.record
        let stored = candidate.status == .stored
        HStack(spacing: 10) {
            Toggle("", isOn: $candidate.include)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(stored)
            ServiceTile(record: record, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                if candidate.status == .renamed {
                    TextField("Name", text: $candidate.name)
                        .textFieldStyle(.plain)
                        .font(.mono(11, weight: .semibold))
                        .foregroundStyle(AppColors.text)
                        .onChange(of: candidate.name) { _, name in
                            let normalized = SecretName.normalized(name)
                            if normalized != name { candidate.name = normalized }
                        }
                } else {
                    Text(candidate.name).font(.mono(11, weight: .semibold)).foregroundStyle(AppColors.text)
                }
                Text(subtitle(record))
                    .font(.mono(9.5)).foregroundStyle(AppColors.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            switch candidate.status {
            case .stored: TagPill(text: candidate.name == candidate.variable ? "In KeyBar" : "In KeyBar as \(candidate.name)", fill: AppColors.mint)
            case .renamed: TagPill(text: "Was \(candidate.variable)", fill: AppColors.peach)
            case .new: EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card()
        .opacity(stored ? 0.7 : 1)
    }

    private func subtitle(_ record: SecretRecord) -> String {
        let kind = record.service.map { "\($0.name) · \(record.kind)" } ?? record.kind
        return "\(kind) · \(candidate.whereFound)"
    }
}
