import SwiftUI

/// Adds a key: a name (the environment variable), the value, and optionally
/// a group and a note. Pasting a whole NAME=value line fills both. Or adds a
/// website password: its websites, user name and password (typed or
/// generated), and a name suggested from the first website.
struct AddKeyView: View {
    @Environment(AppState.self) private var state
    var compact = false
    /// Set when Claude Code asked for this key: its name is filled in and
    /// its reason shown
    var request: KeyRequest? = nil
    /// Which kind the form starts on
    var startingType: SecretType = .apiKey
    let done: () -> Void

    @State private var name = ""
    @State private var value = ""
    @State private var group = ""
    @State private var note = ""
    @State private var error: String?
    /// The name was filled in from the value's shape, not typed
    @State private var suggestedName = false
    /// The value is this file's contents
    @State private var fileName: String?
    @State private var expires = false
    @State private var expiresAt = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now
    @State private var type: SecretType = .apiKey
    @State private var websites: [String] = []
    @State private var typedWebsite = ""
    @State private var username = ""
    /// The name last suggested from the first website: while the name is
    /// still that, a new first website suggests a new one
    @State private var siteSuggestion = ""

    private var isPassword: Bool { type == .password }
    private var finalName: String { SecretName.isValid(name) ? name : SecretName.normalized(name) }
    private var preview: SecretRecord? {
        guard !finalName.isEmpty else { return nil }
        return SecretRecord(name: finalName, createdAt: .now, updatedAt: .now)
    }
    private var canSave: Bool {
        !finalName.isEmpty && !value.isEmpty
            && (!isPassword || !websites.isEmpty || !typedWebsite.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    private var title: String {
        if let request { return "\(request.client) \(request.isPassword ? "needs a login" : "asks for a key")" }
        return isPassword ? "Add a password" : "Add a key"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PopoverHeader(title: title,
                              subtitle: isPassword
                                ? "Stored in your Keychain. KeyBar fills it into the site's login page for Claude, who never sees it."
                                : "Stored in your Keychain. Claude Code uses it by name, never by value.")
                if !compact { Mascot(size: 48) }
            }
            if request == nil {
                PillPicker(selection: $type, options: SecretType.allCases, track: compact ? AppColors.surface : AppColors.ground) {
                    $0 == .password ? "Password" : "API key"
                }
                .onChange(of: type) { _, _ in error = nil }
            }
            if let request {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.reason.isEmpty ? "It needs \(request.isPassword ? "a password for \(request.website ?? "a website")" : request.name)." : request.reason)
                        .font(.mono(10.5))
                        .foregroundStyle(AppColors.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.isPassword
                         ? "Type it below, or generate a new one. It goes straight into your Keychain; Claude never sees it."
                         : "Paste it below. It goes straight into your Keychain; Claude never sees it.")
                        .font(.mono(9.5))
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.butter.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }

            if isPassword {
                passwordFields
            } else {
                keyFields
            }

            if !compact {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(text: "Group", detail: "optional")
                        HouseField(placeholder: isPassword ? "Passwords" : "e.g. a project", text: $group, mono: false)
                        GroupSuggestions(text: $group)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(text: "Note", detail: "optional")
                        HouseField(placeholder: "What it's for", text: $note, mono: false)
                    }
                }
            }

            if !compact && !isPassword {
                ExpiryField(on: $expires, date: $expiresAt)
            }

            if isPassword && !state.accessibilityTrusted {
                SettingNote("To sign in with logins, KeyBar needs Accessibility permission: Settings → Logins.", isError: false)
            }

            if let error {
                SettingNote(error)
            }

            HStack {
                GhostButton(title: "Cancel", action: done)
                Spacer()
                PillButton(title: "Save", symbol: "checkmark", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
        }
        .popoverChrome(width: compact ? 300 : 460)
        .onAppear {
            type = startingType
            if let request {
                if request.isPassword {
                    type = .password
                    if let website = request.website { websites = [website] }
                    username = request.username ?? ""
                }
                if name.isEmpty { name = request.name }
            }
        }
    }

    // MARK: - A password

    @ViewBuilder private var passwordFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: "Website", detail: websites.count > 1 ? "and their subdomains" : "and its subdomains")
            WebsitesField(websites: $websites, typed: $typedWebsite, error: $error, onSubmit: save)
                .onChange(of: websites) { _, sites in suggestPasswordName(sites.first) }
        }
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: "Username", detail: "or email")
            HouseField(placeholder: "you@example.com", text: $username, mono: false, onSubmit: save)
        }
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: "Password")
            PasswordValueField(value: $value, onSubmit: save)
        }
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: "Name", detail: "how Claude asks for it")
            HouseField(placeholder: "LOGIN_LIVERPOOLFC", text: $name, onSubmit: save)
            if finalName != name && !finalName.isEmpty {
                Text("Saved as \(finalName)")
                    .font(.mono(9.5))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    /// LOGIN_SITE from the first website, unless a name was typed
    private func suggestPasswordName(_ website: String?) {
        guard name.isEmpty || name == siteSuggestion, let website else { return }
        siteSuggestion = state.store.suggestedPasswordName(for: website)
        name = siteSuggestion
    }

    // MARK: - An API key

    @ViewBuilder private var keyFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(text: "Name", detail: "the environment variable")
            HouseField(placeholder: "CLOUDFLARE_API_TOKEN", text: $name, onSubmit: save)
                .onChange(of: name) { _, typed in
                    splitPastedLine(typed)
                    if !typed.isEmpty { suggestedName = false }
                }
            if let preview {
                HStack(spacing: 6) {
                    ServiceTile(record: preview, size: 18)
                    Text(preview.service.map { "\($0.name) · \(preview.kind)" } ?? preview.kind)
                    if finalName != name {
                        Text("· saved as \(finalName)")
                    }
                }
                .font(.mono(9.5))
                .foregroundStyle(AppColors.secondaryText)
                .lineLimit(1)
            }
        }

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                FieldLabel(text: "Value", detail: fileName == nil ? nil : "a file")
                Spacer()
                if !compact {
                    Button(fileName == nil ? "Or choose a file…" : "Paste instead") {
                        if fileName == nil { chooseFile() } else { fileName = nil; value = "" }
                    }
                    .buttonStyle(.plain)
                    .font(.mono(9.5, weight: .semibold))
                    .foregroundStyle(AppColors.text)
                    .help("For keys that come as a file, like a .json service account or a .p8")
                }
            }
            if let fileName {
                FileValueRow(fileName: fileName, size: value.utf8.count)
            } else {
                HouseField(placeholder: "Paste the key", text: $value, secure: true, onSubmit: save)
                    .onChange(of: value) { _, pasted in suggestName(for: pasted) }
            }
        }
    }

    private func chooseFile() {
        error = nil
        guard let file = KeyFile.choose(title: "Choose a key file") else { return }
        switch file {
        case .success(let (fileName, contents)):
            self.fileName = fileName
            value = contents
            if name.isEmpty { name = SecretName.normalized((fileName as NSString).deletingPathExtension) }
        case .failure(let problem):
            error = problem.localizedDescription
        }
    }

    /// "NAME=value" pasted into the name field fills both fields
    private func splitPastedLine(_ text: String) {
        guard let entry = EnvFile.parse(text).first, text.contains("=") else { return }
        name = entry.name
        value = entry.value
    }

    private func suggestName(for pasted: String) {
        guard name.isEmpty || suggestedName, let suggestion = KeyShape.suggestedName(for: pasted) else { return }
        name = suggestion
        suggestedName = true
    }

    private func save() {
        guard canSave else { return }
        do {
            if isPassword {
                // What's still in the website field counts too
                if !typedWebsite.trimmingCharacters(in: .whitespaces).isEmpty {
                    for site in try LoginSite.normaliseList(typedWebsite) where !websites.contains(site) { websites.append(site) }
                    typedWebsite = ""
                }
                guard !websites.isEmpty else { throw StoreError.noWebsite }
                let name = finalName.isEmpty ? state.store.suggestedPasswordName(for: websites[0]) : finalName
                // A password is kept exactly as typed: spaces can be part of it
                try state.add(name: name, value: value, group: group, note: note,
                              login: (username.trimmingCharacters(in: .whitespacesAndNewlines), websites))
                request?.added = name
            } else {
                // A file is kept exactly as it is; a pasted key loses stray spaces
                try state.add(name: finalName, value: fileName == nil ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value,
                              group: group, note: note, fileName: fileName, expiresAt: expires ? expiresAt : nil)
                request?.added = finalName
            }
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
