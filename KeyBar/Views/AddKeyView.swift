import SwiftUI

/// Adds a key: a name (the environment variable), the value, and optionally
/// a group and a note. Pasting a whole NAME=value line fills both.
struct AddKeyView: View {
    @Environment(AppState.self) private var state
    var compact = false
    let done: () -> Void

    @State private var name = ""
    @State private var value = ""
    @State private var group = ""
    @State private var note = ""
    @State private var error: String?
    /// The name was filled in from the value's shape, not typed
    @State private var suggestedName = false

    private var finalName: String { SecretName.isValid(name) ? name : SecretName.normalized(name) }
    private var preview: SecretRecord? {
        guard !finalName.isEmpty else { return nil }
        return SecretRecord(name: finalName, createdAt: .now, updatedAt: .now)
    }
    private var canSave: Bool { !finalName.isEmpty && !value.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                PopoverHeader(title: "Add a key", subtitle: "Stored in your Keychain. Claude Code uses it by name, never by value.")
                if !compact { Mascot(size: 48) }
            }

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
                FieldLabel(text: "Value")
                HouseField(placeholder: "Paste the key", text: $value, secure: true, onSubmit: save)
                    .onChange(of: value) { _, pasted in suggestName(for: pasted) }
            }

            if !compact {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(text: "Group", detail: "optional")
                        HouseField(placeholder: "e.g. a project", text: $group, mono: false)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(text: "Note", detail: "optional")
                        HouseField(placeholder: "What it's for", text: $note, mono: false)
                    }
                }
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
            try state.add(name: finalName, value: value.trimmingCharacters(in: .whitespacesAndNewlines),
                          group: group, note: note)
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
