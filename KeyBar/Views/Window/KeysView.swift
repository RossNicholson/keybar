import AppKit
import SwiftUI

/// Every key, grouped, with show, copy and edit
struct KeysView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var showingAdd = false
    @State private var editing: SecretRecord?
    @State private var importing: ImportRequest?
    @State private var importError: String?
    @State private var showArchived = false

    var body: some View {
        Screen {
            ScreenHeader(title: "Keys", subtitle: subtitle) {
                HStack(spacing: 8) {
                    GhostButton(title: "Import .env", symbol: "square.and.arrow.down") { chooseEnvFile() }
                    PillButton(title: "Add key", symbol: "plus") { showingAdd = true }
                }
            }
            if let importError { SettingNote(importError) }
            if let error = state.store.lastError { SettingNote(error) }

            if state.store.active.isEmpty && state.store.archived.isEmpty {
                MessageCard(title: "No keys yet",
                            message: "Add your API keys once: Claude, Cloudflare, GitHub, anything. They go in your Mac's Keychain, and Claude Code can use them by name without ever seeing them. Got a .env file? Import it.",
                            fill: AppColors.butter) {
                    PillButton(title: "Add a key", symbol: "plus") { showingAdd = true }
                    GhostButton(title: "Import .env", symbol: "square.and.arrow.down") { chooseEnvFile() }
                }
            } else {
                HStack(spacing: 12) {
                    SearchField(text: $search, placeholder: "Search by name, service, group or note")
                        .frame(maxWidth: 360)
                    if !state.store.archived.isEmpty || showArchived {
                        PillPicker(selection: $showArchived, options: [false, true], track: AppColors.ground) {
                            $0 ? "Archived \(state.store.archived.count)" : "Active \(state.store.active.count)"
                        }
                        .frame(width: 260)
                    }
                }
                let records = state.store.search(search, archived: showArchived)
                let groups = Dictionary(grouping: records, by: \.displayGroup)
                let custom = Set(state.store.customGroups)
                ForEach(groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: group)
                            .contextMenu {
                                if custom.contains(group) {
                                    Button("Rename Group…") { renameGroup(group) }
                                    Button("Ungroup") { state.store.renameGroup(group, to: nil) }
                                }
                            }
                        ForEach(groups[group] ?? []) { record in
                            KeyRow(record: record) { editing = record }
                        }
                    }
                }
                if records.isEmpty {
                    Text(search.isEmpty ? (showArchived ? "Nothing archived." : "Every key is archived.")
                                        : "No keys match \"\(search)\".")
                        .font(.mono(11))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyBarAddKey)) { _ in showingAdd = true }
        .sheet(isPresented: $showingAdd) {
            AddKeyView { showingAdd = false }.environment(state)
        }
        .sheet(item: $editing) { record in
            KeyEditor(record: record) { editing = nil }.environment(state)
        }
        .sheet(item: $importing) { request in
            ImportView(request: request) { importing = nil }.environment(state)
        }
    }

    /// Asks for a group's new name
    private func renameGroup(_ group: String) {
        let alert = NSAlert()
        alert.messageText = "Rename \"\(group)\""
        alert.informativeText = "Every key in the group moves to the new name."
        let field = NSTextField(string: group)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != group else { return }
        state.store.renameGroup(group, to: name)
    }

    private var subtitle: String {
        let count = state.store.records.count
        return count == 0 ? "Nothing stored yet" : "\(count) key\(count == 1 ? "" : "s") in your Keychain. Only their names are listed here until you show one."
    }

    private func chooseEnvFile() {
        importError = nil
        let panel = NSOpenPanel()
        panel.title = "Import a .env file"
        panel.prompt = "Import"
        panel.message = "Choose a .env file. You'll pick which keys to import next."
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let entries = EnvFile.parse(text)
        guard !entries.isEmpty else {
            importError = "\(url.lastPathComponent) has no NAME=value lines."
            return
        }
        importing = ImportRequest(file: url, entries: entries)
    }
}

/// A key in the window's list
struct KeyRow: View {
    @Environment(AppState.self) private var state
    let record: SecretRecord
    let edit: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            ServiceTile(record: record, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(record.name)
                        .font(.mono(12, weight: .semibold))
                        .foregroundStyle(AppColors.text)
                        .textSelection(.enabled)
                    if record.isRestricted {
                        TagPill(text: "\(record.projectFolders.count) folder\(record.projectFolders.count == 1 ? "" : "s")",
                                fill: AppColors.lilac)
                            .help(record.projectFolders.map(BridgePolicy.tidy).joined(separator: "\n"))
                    }
                }
                KeySubtitle(record: record)
                if let note = record.note {
                    Text(note)
                        .font(.mono(9.5))
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let used = record.lastUsedAt {
                Text("Used \(used, format: .relative(presentation: .named))")
                    .font(.mono(9.5))
                    .foregroundStyle(AppColors.secondaryText)
            }
            KeyActions(name: record.name)
            RoundIconButton(symbol: "pencil", size: 26, fill: AppColors.ground, foreground: AppColors.text,
                            help: "Edit \(record.name)", action: edit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .card(hovered: hovered, radius: Radius.row)
        .onHover { hovered = $0 }
        .opacity(record.isArchived ? 0.7 : 1)
        .contextMenu {
            Button("Copy Name") { Clipboard.copyText(record.name) }
            Button("Copy as $\(record.name)") { Clipboard.copyText("$\(record.name)") }
            Button("Edit…", action: edit)
            Divider()
            Button("Move Up") { state.store.move(record.name, by: -1) }
            Button("Move Down") { state.store.move(record.name, by: 1) }
            Menu("Move to Group") {
                Button(record.service.map { "Under \($0.name)" } ?? "No Group") { state.store.setGroup(record.name, nil) }
                    .disabled(record.group == nil)
                let groups = state.store.customGroups.filter { $0 != record.group }
                if !groups.isEmpty { Divider() }
                ForEach(groups, id: \.self) { group in
                    Button(group) { state.store.setGroup(record.name, group) }
                }
            }
            Divider()
            Button(record.isArchived ? "Restore" : "Archive") { state.setArchived(record.name, !record.isArchived) }
        }
    }
}

/// Changes a key: rename it, replace its value, group, note and the folders
/// it's limited to, or delete it
struct KeyEditor: View {
    @Environment(AppState.self) private var state
    let record: SecretRecord
    let done: () -> Void

    @State private var name = ""
    @State private var newValue = ""
    @State private var group = ""
    @State private var note = ""
    @State private var folders: [String] = []
    @State private var error: String?
    /// The Keychain refused to delete it; offer to take it off the list instead
    @State private var deleteFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ServiceTile(record: record, size: 44)
                PopoverHeader(title: record.name,
                              subtitle: [record.service?.name, record.kind].compactMap { $0 }.joined(separator: " · "))
            }

            HStack(spacing: 10) {
                field("Name", detail: "the environment variable") {
                    HouseField(placeholder: record.name, text: $name)
                }
                field("Group", detail: "optional") {
                    HouseField(placeholder: record.service?.name ?? "Other", text: $group, mono: false)
                }
            }
            field("Note", detail: "optional") {
                HouseField(placeholder: "What it's for", text: $note, mono: false)
            }
            field("New value", detail: "leave empty to keep the current one") {
                HouseField(placeholder: "Paste a new value", text: $newValue, secure: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Project folders",
                           detail: folders.isEmpty ? "any folder can use it" : "only commands run inside these can use it")
                ForEach(folders, id: \.self) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(AppColors.secondaryText)
                        Text(BridgePolicy.tidy(folder))
                            .font(.mono(11))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button { folders.removeAll { $0 == folder } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .card(radius: Radius.small)
                }
                GhostButton(title: "Limit to a folder…", symbol: "folder.badge.plus") { chooseFolder() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Added \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · changed \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                if let used = record.lastUsedAt {
                    Text("Last used by a command \(used.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.mono(9.5))
            .foregroundStyle(AppColors.secondaryText)

            if let error { SettingNote(error) }
            if deleteFailed {
                HStack(spacing: 10) {
                    Text("Take it off KeyBar's list anyway? It stays in the Keychain, where Keychain Access can delete it.")
                        .font(.mono(10))
                        .foregroundStyle(AppColors.secondaryText)
                    ConfirmButton(title: "Remove from KeyBar", confirmTitle: "Remove it?") {
                        state.forget(record.name)
                        done()
                    }
                }
            }

            HStack {
                ConfirmButton(title: "Delete", confirmTitle: "Delete for good?") {
                    do {
                        try state.delete(record.name)
                        done()
                    } catch {
                        self.error = error.localizedDescription
                        deleteFailed = true
                    }
                }
                GhostButton(title: record.isArchived ? "Restore" : "Archive",
                            symbol: record.isArchived ? "tray.and.arrow.up" : "archivebox") {
                    state.setArchived(record.name, !record.isArchived)
                    done()
                }
                .help(record.isArchived ? "Bring it back into use" : "Keep it, but hide it and stop commands using it")
                Spacer()
                GhostButton(title: "Cancel", action: done)
                PillButton(title: "Save", symbol: "checkmark", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .popoverChrome(width: 520)
        .onAppear {
            name = record.name
            group = record.group ?? ""
            note = record.note ?? ""
            folders = record.projectFolders
        }
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: title, detail: detail)
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Limit \(record.name) to a folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = Storage.canonical(url.path)
            if !folders.contains(path) { folders.append(path) }
        }
    }

    private func save() {
        error = nil
        do {
            var current = record.name
            let typed = name.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty, typed != record.name {
                try state.rename(record.name, to: typed)
                current = typed
            }
            if !newValue.isEmpty {
                try state.replaceValue(current, with: newValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if var updated = state.store.record(current) {
                let changed = updated.group != group.nonEmpty || updated.note != note.nonEmpty || updated.projectFolders != folders
                updated.group = group
                updated.note = note
                updated.projectFolders = folders
                state.store.update(updated)
                if changed { state.log.log(.changed, [current], detail: "Details") }
            }
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ImportRequest: Identifiable {
    let id = UUID()
    let file: URL
    let entries: [EnvFile.Entry]
}

/// Picks which keys from a .env file to import
struct ImportView: View {
    @Environment(AppState.self) private var state
    let request: ImportRequest
    let done: () -> Void
    @State private var chosen: Set<String> = []
    @State private var group = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PopoverHeader(title: "Import \(request.file.lastPathComponent)",
                          subtitle: "\(request.entries.count) found in \(BridgePolicy.tidy(request.file.deletingLastPathComponent().path)). Values aren't shown. The file itself isn't changed; delete it once your keys are in KeyBar.")
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(request.entries, id: \.name) { entry in
                        let preview = SecretRecord(name: entry.name, createdAt: .now, updatedAt: .now)
                        Toggle(isOn: Binding(get: { chosen.contains(entry.name) },
                                             set: { if $0 { chosen.insert(entry.name) } else { chosen.remove(entry.name) } })) {
                            HStack(spacing: 10) {
                                ServiceTile(record: preview, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.mono(11, weight: .semibold)).foregroundStyle(AppColors.text)
                                    Text(preview.service.map { "\($0.name) · \(preview.kind)" } ?? preview.kind)
                                        .font(.mono(9.5)).foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                if state.store.record(entry.name) != nil {
                                    TagPill(text: "Replaces", fill: AppColors.peach)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .card()
                    }
                }
            }
            .frame(maxHeight: 320)

            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: "Group", detail: "optional, e.g. the project's name")
                HouseField(placeholder: "No group", text: $group, mono: false)
            }
            if let error { SettingNote(error) }
            HStack {
                GhostButton(title: chosen.count == request.entries.count ? "Select none" : "Select all") {
                    chosen = chosen.count == request.entries.count ? [] : Set(request.entries.map(\.name))
                }
                Spacer()
                GhostButton(title: "Cancel", action: done)
                PillButton(title: "Import \(chosen.count)", symbol: "square.and.arrow.down") {
                    do {
                        _ = try state.importEntries(request.entries.filter { chosen.contains($0.name) },
                                                    group: group, from: request.file.lastPathComponent)
                        done()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.5 : 1)
            }
        }
        .popoverChrome(width: 520)
        .onAppear {
            chosen = Set(request.entries.map(\.name))
            group = request.file.deletingLastPathComponent().lastPathComponent
        }
    }
}
