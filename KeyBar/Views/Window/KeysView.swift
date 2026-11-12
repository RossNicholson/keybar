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
    @State private var finding = false

    var body: some View {
        Screen {
            ScreenHeader(title: "Keys", subtitle: subtitle) {
                HStack(spacing: 8) {
                    GhostButton(title: "Find keys", symbol: "magnifyingglass") { finding = true }
                        .fixedSize()
                    GhostButton(title: "Import .env", symbol: "square.and.arrow.down") { chooseEnvFile() }
                        .fixedSize()
                    PillButton(title: "Add key", symbol: "plus") { showingAdd = true }
                        .fixedSize()
                }
            }
            if let importError { SettingNote(importError) }
            if let error = state.store.lastError { SettingNote(error) }
            AttentionCards()

            if state.store.active.isEmpty && state.store.archived.isEmpty {
                MessageCard(title: "No keys yet",
                            message: "Add your API keys once: Claude, Cloudflare, GitHub, anything. They go in your Mac's Keychain, and Claude Code can use them by name without ever seeing them. Already have keys in .env files? Find them.",
                            fill: AppColors.butter) {
                    PillButton(title: "Find keys on this Mac", symbol: "magnifyingglass") { finding = true }
                    GhostButton(title: "Add a key", symbol: "plus") { showingAdd = true }
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
        .sheet(isPresented: $finding) {
            FindKeysView { finding = false }.environment(state)
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
        let parsed = EnvFile.parse(text)
        guard !parsed.isEmpty else {
            importError = "\(url.lastPathComponent) has no NAME=value lines."
            return
        }
        let entries = EnvFile.importable(parsed)
        guard !entries.isEmpty else {
            importError = "\(url.lastPathComponent) only points to keys already in KeyBar."
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
                    if let fileName = record.fileName {
                        TagPill(text: "file", fill: AppColors.periwinkle)
                            .help("\(fileName): commands get the path to a private copy")
                    }
                    if !record.sentTo.isEmpty {
                        TagPill(text: "sent to \(record.sentTo.count)", fill: AppColors.mint)
                            .help(record.sentTo.map(\.label).joined(separator: "\n"))
                    }
                    if let expiry = KeyHealth.expiryText(record) {
                        TagPill(text: expiry, fill: AppColors.coral)
                            .help(record.expiresAt.map { "Expires \($0.formatted(date: .long, time: .omitted))" } ?? "")
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
    @State private var expires = false
    @State private var expiresAt = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    /// A new file for a file key: its name and contents
    @State private var newFile: (name: String, contents: String)?
    @State private var testResult: KeyTester.Result?
    @State private var testing = false
    @State private var sending = false
    /// Sends again, by destination ID: what happened
    @State private var resent: [String: String] = [:]
    @State private var approval: ApprovalChoice = .settings
    @State private var proxied = false
    @State private var rotating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ServiceTile(record: record, size: 44)
                PopoverHeader(title: record.name,
                              subtitle: [record.service?.name, record.kind].compactMap { $0 }.joined(separator: " · "))
            }

            HStack(alignment: .top, spacing: 10) {
                field("Name", detail: "the environment variable") {
                    HouseField(placeholder: record.name, text: $name)
                }
                field("Group", detail: "optional") {
                    HouseField(placeholder: record.service?.name ?? "Other", text: $group, mono: false)
                    GroupSuggestions(text: $group)
                }
            }
            field("Note", detail: "optional") {
                HouseField(placeholder: "What it's for", text: $note, mono: false)
            }
            if let fileName = record.fileName {
                field("File", detail: newFile == nil ? "commands get the path to a private copy" : "replaces \(fileName) when you save") {
                    HStack(spacing: 8) {
                        FileValueRow(fileName: newFile?.name ?? fileName, size: newFile?.contents.utf8.count)
                        GhostButton(title: "New file…", symbol: "doc.badge.arrow.up") { chooseFile() }
                            .fixedSize()
                    }
                }
            } else {
                field("New value", detail: "leave empty to keep the current one") {
                    HouseField(placeholder: "Paste a new value", text: $newValue, secure: true)
                }
            }
            ExpiryField(on: $expires, date: $expiresAt)

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

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Touch ID", detail: "before a command uses it")
                PillPicker(selection: $approval, options: ApprovalChoice.allCases, track: AppColors.surface) { $0.title }
                if approval == .never {
                    Text("Claude and other apps can use it without asking you. Only for keys that don't matter if they leak.")
                        .font(.mono(9.5))
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            if KeyProxy.route(for: record) != nil {
                Toggle(isOn: $proxied) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Through KeyBar's proxy")
                            .font(.mono(11, weight: .semibold))
                            .foregroundStyle(AppColors.text)
                        Text("Commands get a placeholder and $\(KeyProxy.route(for: record)?.variable ?? ""); KeyBar adds the key to their requests, so they never have it. See Dev tools.")
                            .font(.mono(9.5))
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(AppColors.toggle)
            }

            sentTo

            HStack(spacing: 8) {
                GhostButton(title: "Rotate…", symbol: "arrow.triangle.2.circlepath") { rotating = true }
                    .fixedSize()
                    .help("Swap in a new key and send it everywhere this one went")
                GhostButton(title: "Send to GitHub or Cloudflare…", symbol: "paperplane") { sending = true }
                    .fixedSize()
                if KeyTester.canTest(record) {
                    GhostButton(title: testing ? "Testing…" : "Test", symbol: "checkmark.seal") { test() }
                        .fixedSize()
                        .disabled(testing)
                        .help("Asks \(record.service?.name ?? "the service") whether the key works. Nothing is changed.")
                }
                Spacer(minLength: 0)
            }
            if let testResult {
                SettingNote(testResult.summary + (testResult.expiresAt.map { " It expires \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""))
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
            approval = ApprovalChoice(record.approval)
            proxied = record.proxied == true
            if let date = record.expiresAt {
                expires = true
                expiresAt = date
            }
        }
        .sheet(isPresented: $sending) {
            SendKeyView(name: record.name) { sending = false }
                .environment(state)
        }
        .sheet(isPresented: $rotating) {
            RotateKeyView(name: record.name) { rotating = false }
                .environment(state)
        }
    }

    /// Where the key has been sent, with Send again for after a new value
    @ViewBuilder private var sentTo: some View {
        let current = state.store.record(record.name) ?? record
        if !current.sentTo.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Sent to", detail: "send again after a new value")
                ForEach(current.sentTo) { destination in
                    HStack(spacing: 8) {
                        Image(systemName: destination.kind == .githubActions ? "chevron.left.forwardslash.chevron.right" : "cloud.fill")
                            .foregroundStyle(AppColors.secondaryText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(destination.label + (destination.secretName == current.name ? "" : " as \(destination.secretName)"))
                                .font(.mono(11))
                                .foregroundStyle(AppColors.text)
                                .lineLimit(1)
                            Text(resent[destination.id] ?? destination.sentAt.map { "Sent \($0.formatted(.relative(presentation: .named)))" } ?? "")
                                .font(.mono(9))
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer()
                        GhostButton(title: "Send again", symbol: "arrow.clockwise") { sendAgain(destination) }
                            .fixedSize()
                        Button { state.store.forgetSend(current.name, destination) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Forget this one (it stays wherever it was sent)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .card(radius: Radius.small)
                }
            }
        }
    }

    private func sendAgain(_ destination: Destination) {
        resent[destination.id] = "Sending…"
        Task {
            switch await state.send(record.name, to: destination) {
            case .success(let message): resent[destination.id] = message
            case .failure(let error): resent[destination.id] = error.localizedDescription
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            testResult = await state.test(record.name)
            testing = false
            if let date = state.store.record(record.name)?.expiresAt, !expires {
                expires = true
                expiresAt = date
            }
        }
    }

    private func chooseFile() {
        error = nil
        guard let file = KeyFile.choose(title: "Choose a new file for \(record.name)") else { return }
        switch file {
        case .success(let (fileName, contents)): newFile = (fileName, contents)
        case .failure(let problem): error = problem.localizedDescription
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
            if let newFile {
                try state.replaceValue(current, with: newFile.contents, fileName: newFile.name)
            } else if !newValue.isEmpty {
                try state.replaceValue(current, with: newValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            state.setExpiry(current, expires ? expiresAt : nil)
            state.setApproval(current, approval.value)
            state.setProxied(current, proxied)
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

/// A key's Touch ID rule, as a picker shows it
enum ApprovalChoice: CaseIterable, Hashable {
    case settings, everyTime, never

    init(_ approval: KeyApproval?) {
        switch approval {
        case .everyTime: self = .everyTime
        case .never: self = .never
        case nil: self = .settings
        }
    }

    var value: KeyApproval? {
        switch self {
        case .settings: return nil
        case .everyTime: return .everyTime
        case .never: return .never
        }
    }

    var title: String {
        switch self {
        case .settings: return "As in Settings"
        case .everyTime: return "Every time"
        case .never: return "Don't ask"
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
                GroupSuggestions(text: $group)
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

/// Keys that need looking at: expiring soon, or unused for months
private struct AttentionCards: View {
    @Environment(AppState.self) private var state
    @State private var rotating: String?

    var body: some View {
        VStack(spacing: 14) { banners }
            .sheet(item: Binding(get: { rotating.map(RotateTarget.init) }, set: { rotating = $0?.name })) { target in
                RotateKeyView(name: target.name) { rotating = nil }
                    .environment(state)
            }
    }

    @ViewBuilder private var banners: some View {
        let expiring = state.store.active.filter(\.expiresSoon)
        let unused = KeyHealth.unused(state.store.active).filter { !state.settings.keptUnused.contains($0.name) }
        if !expiring.isEmpty {
            AttentionBanner(symbol: "calendar.badge.exclamationmark",
                            title: expiring.count == 1 ? "A key expires soon" : "\(expiring.count) keys expire soon",
                            message: expiring.map { "\($0.name): \(KeyHealth.expiryText($0)?.lowercased() ?? "")" }.joined(separator: " · ")
                                + ". Rotate swaps in a new one and sends it wherever the old one went.",
                            fill: AppColors.coral) {
                if expiring.count == 1 {
                    PillButton(title: "Rotate", symbol: "arrow.triangle.2.circlepath") { rotating = expiring[0].name }
                }
            }
        }
        if !unused.isEmpty {
            AttentionBanner(symbol: "archivebox",
                            title: unused.count == 1 ? "A key you haven't used" : "\(unused.count) keys you haven't used",
                            message: unused.map(\.name).joined(separator: ", ")
                                + ": not used by a command on this Mac for \(KeyHealth.unusedDays) days. Archive to keep \(unused.count == 1 ? "it" : "them") out of Claude's reach until needed?",
                            fill: AppColors.butter) {
                PillButton(title: "Archive", symbol: "archivebox") {
                    for record in unused { state.setArchived(record.name, true) }
                }
                GhostButton(title: "Keep \(unused.count == 1 ? "it" : "them")") {
                    state.settings.keptUnused += unused.map(\.name)
                }
            }
        }
    }
}
