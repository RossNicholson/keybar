import SwiftUI

// KeyBar's own pieces. The shared buttons, labels and cards come from the
// HouseStyle package.

/// A pastel square with the service's initials, so each service keeps its colour
struct ServiceTile: View {
    let record: SecretRecord
    var size: CGFloat = 32

    var body: some View {
        let label = record.service?.name ?? record.name
        Text(Self.initials(label))
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
