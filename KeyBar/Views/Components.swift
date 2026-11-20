import SwiftUI

// KeyBar's own pieces. The shared buttons, labels and cards come from the
// HouseStyle package.

/// A pastel square with the service's initials, so each service keeps its
/// colour. A password gets a person-and-key symbol, in its site's colour.
struct ServiceTile: View {
    let record: SecretRecord
    var size: CGFloat = 32

    var body: some View {
        if record.isPassword {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(AppColors.ink)
                .frame(width: size, height: size)
                .background(AppColors.pastel(for: record.sites.first ?? record.name),
                            in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityHidden(true)
        } else {
            initialsTile
        }
    }

    private var initialsTile: some View {
        let label = record.service?.name ?? record.name
        return Text(Self.initials(label))
            .font(.display(size * 0.5, relativeTo: .headline))
            .foregroundStyle(AppColors.ink)
            .frame(width: size, height: size)
            .background(AppColors.pastel(for: label), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "_" || $0 == "." || $0 == "-" }
        if words.count >= 2, let a = words[0].first, let b = words[1].first, name.contains(" ") {
            return "\(a)\(b)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

/// A text field in the house style: mono text on a white rounded field
struct HouseField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = true
    var onSubmit: () -> Void = {}
    @State private var showing = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if secure && !showing {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(mono ? .mono(12) : .system(size: 12))
            .disableAutocorrection(true)
            .onSubmit(onSubmit)
            if secure {
                Button {
                    showing.toggle()
                } label: {
                    Image(systemName: showing ? "eye.slash" : "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help(showing ? "Hide" : "Show")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(AppColors.hairline))
    }
}

/// A small caption above a field
struct FieldLabel: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.mono(9.5, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(AppColors.secondaryText)
            if let detail {
                Text(detail)
                    .font(.mono(9.5))
                    .foregroundStyle(AppColors.secondaryText.opacity(0.8))
            }
        }
    }
}

/// The search box at the top of a list
struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search keys"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.mono(11.5))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(AppColors.surface, in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(AppColors.hairline))
    }
}

/// Reveal and copy, as small round buttons
struct KeyActions: View {
    @Environment(AppState.self) private var state
    let name: String
    var fromPanel = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            let revealed = state.isRevealed(name)
            RoundIconButton(symbol: revealed ? "eye.slash.fill" : "eye.fill", size: 26,
                            fill: AppColors.ground, foreground: AppColors.text,
                            help: revealed ? "Hide \(name)" : "Show \(name)") {
                if revealed {
                    state.hide(name)
                } else {
                    Task { await state.reveal(name, fromPanel: fromPanel) }
                }
            }
            RoundIconButton(symbol: copied ? "checkmark" : "doc.on.doc.fill", size: 26,
                            fill: copied ? AppColors.mint : AppColors.solid,
                            foreground: copied ? AppColors.ink : AppColors.onSolid,
                            help: "Copy \(name)") {
                Task {
                    if await state.copy(name, fromPanel: fromPanel) {
                        withAnimation { copied = true }
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation { copied = false }
                    }
                }
            }
        }
    }
}

/// The value of a revealed key, or what the key is for
struct KeySubtitle: View {
    @Environment(AppState.self) private var state
    let record: SecretRecord

    var body: some View {
        if let value = state.revealedValue(record.name) {
            Text(value)
                .font(.mono(10))
                .foregroundStyle(AppColors.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(AppColors.butter.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        } else if record.isPassword {
            HStack(spacing: 4) {
                Text(record.loginSummary)
                if record.isRestricted {
                    Image(systemName: "folder.fill").font(.system(size: 8))
                        .help("Only for some project folders")
                }
            }
            .font(.mono(9.5))
            .foregroundStyle(AppColors.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(record.sites.joined(separator: "\n"))
        } else {
            HStack(spacing: 4) {
                Text(record.service.map { "\($0.name) · \(record.kind)" } ?? record.kind)
                if record.isRestricted {
                    Image(systemName: "folder.fill").font(.system(size: 8))
                        .help("Only for some project folders")
                }
            }
            .font(.mono(9.5))
            .foregroundStyle(AppColors.secondaryText)
            .lineLimit(1)
        }
    }
}

/// A friendly message with the mascot, for empty and error states
struct MessageCard<Actions: View>: View {
    let title: String
    let message: String
    var mood: Mascot.Mood = .happy
    var fill: Color = AppColors.mint
    var compact = false
    @ViewBuilder var actions: Actions

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 20))
        layout {
            Mascot(mood: mood, size: compact ? 56 : 84, disc: .white.opacity(0.55))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.display(compact ? 20 : 26, relativeTo: .title))
                    .textCase(.uppercase)
                Text(message)
                    .font(.mono(compact ? 10 : 11))
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions }
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(compact ? 16 : 24)
        .pastelCard(fill, radius: compact ? Radius.block : Radius.hero)
    }
}

/// "Ask again" step for deleting: the first press arms it, the second deletes
struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                action()
                armed = false
            } else {
                withAnimation { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { withAnimation { armed = false } }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: armed ? "exclamationmark.triangle.fill" : "trash.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(armed ? confirmTitle : title)
                    .font(.mono(11, weight: .semibold))
            }
            .foregroundStyle(armed ? AppColors.ink : AppColors.destructive)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(armed ? AppColors.coral : AppColors.surface, in: Capsule(style: .circular))
            .overlay(Capsule(style: .circular).strokeBorder(armed ? .clear : AppColors.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// The groups already in use, under a Group field: tap one to fill it in.
/// Shows the ones matching what's typed, or all of them while it's empty.
struct GroupSuggestions: View {
    @Environment(AppState.self) private var state
    @Binding var text: String

    private var matches: [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        return state.store.customGroups.filter {
            typed.isEmpty || ($0.localizedCaseInsensitiveContains(typed) && $0.caseInsensitiveCompare(typed) != .orderedSame)
        }
        .prefix(6).map { $0 }
    }

    var body: some View {
        if !matches.isEmpty {
            HStack(spacing: 5) {
                ForEach(matches, id: \.self) { group in
                    Button { text = group } label: {
                        Text(group)
                            .font(.mono(9.5, weight: .semibold))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(AppColors.surface, in: Capsule(style: .circular))
                            .overlay(Capsule(style: .circular).strokeBorder(AppColors.hairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Put it in \(group)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Reading a key that comes as a file
enum KeyFile {
    /// The most a file key may be: key files are small, and every command
    /// that uses it gets a copy
    static let maxBytes = 64 * 1024

    enum Problem: LocalizedError {
        case tooBig(String), notText(String), unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooBig(let name): return "\(name) is bigger than \(KeyFile.maxBytes / 1024) KB, too big for a key."
            case .notText(let name): return "\(name) isn't a text file. Key files like .json, .pem and .p8 are text."
            case .unreadable(let name): return "Couldn't read \(name)."
            }
        }
    }

    /// Asks for a file; nil if the user cancelled
    @MainActor
    static func choose(title: String) -> Result<(String, String), Problem>? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.message = "A key file such as a service account .json or an Apple .p8. KeyBar keeps a copy in your Keychain."
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return read(url)
    }

    static func read(_ url: URL) -> Result<(String, String), Problem> {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(name)) }
        guard data.count <= maxBytes else { return .failure(.tooBig(name)) }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.contains("\0") else { return .failure(.notText(name)) }
        return .success((name, text))
    }
}

/// Stands in for the value field when the key is a file
struct FileValueRow: View {
    let fileName: String
    /// nil when it isn't known without reading the Keychain
    var size: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill").foregroundStyle(AppColors.secondaryText)
            Text(fileName)
                .font(.mono(11, weight: .semibold))
                .foregroundStyle(AppColors.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.mono(9.5))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(AppColors.hairline))
    }
}

/// "Expires" with a date, for a reminder before a key stops working
struct ExpiryField: View {
    @Binding var on: Bool
    @Binding var date: Date

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $on) {
                FieldLabel(text: "Expires", detail: on ? "KeyBar reminds you 2 weeks before" : "optional")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(AppColors.toggle)
            Spacer()
            if on {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
            }
        }
    }
}

/// A slim card above the key list for keys that need looking at
struct AttentionBanner<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    let fill: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: symbol, fill: .white.opacity(0.55), size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.display(16, relativeTo: .headline))
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.ink)
                Text(message)
                    .font(.mono(10))
                    .foregroundStyle(AppColors.ink.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }
}

/// A password's websites: each one a chip with a remove button, and a field
/// that takes a pasted address or a typed domain (several at once, split by
/// commas or spaces). Return or Add puts what's typed on the list.
struct WebsitesField: View {
    @Binding var websites: [String]
    /// What's typed and not yet added; saving adds it too
    @Binding var typed: String
    @Binding var error: String?
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !websites.isEmpty {
                FlowChips(items: websites) { site in websites.removeAll { $0 == site } }
            }
            HStack(spacing: 8) {
                HouseField(placeholder: websites.isEmpty ? "liverpoolfc.com, or paste the login page's address" : "Another website",
                           text: $typed, onSubmit: { if !add() { onSubmit() } })
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                    GhostButton(title: "Add", symbol: "plus") { _ = add() }
                        .fixedSize()
                }
            }
        }
    }

    /// Adds what's typed. True if there was something to add (and it was a
    /// website), false if the field was empty.
    @discardableResult
    func add() -> Bool {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            for site in try LoginSite.normaliseList(typed) where !websites.contains(site) { websites.append(site) }
            typed = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        return true
    }
}

/// Small removable chips that wrap onto more lines
private struct FlowChips: View {
    let items: [String]
    let remove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 5) {
                    Image(systemName: "globe").font(.system(size: 9, weight: .semibold))
                    Text(item).font(.mono(10.5, weight: .semibold)).lineLimit(1)
                    Button { remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(item)")
                }
                .foregroundStyle(AppColors.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(AppColors.surface, in: Capsule(style: .circular))
                .overlay(Capsule(style: .circular).strokeBorder(AppColors.hairline))
            }
        }
    }
}

/// Lays its subviews out left to right, wrapping onto new lines
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// A password field with a button that makes up a strong one
struct PasswordValueField: View {
    @Binding var value: String
    var placeholder = "The password"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            HouseField(placeholder: placeholder, text: $value, secure: true, onSubmit: onSubmit)
            GhostButton(title: "Generate", symbol: "wand.and.stars") {
                value = PasswordGenerator.make()
            }
            .fixedSize()
            .help("Make up a strong \(PasswordGenerator.defaultLength)-character password. Show it with the eye, or copy it later from KeyBar.")
        }
    }
}
