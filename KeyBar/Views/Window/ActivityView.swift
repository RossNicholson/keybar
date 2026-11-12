import SwiftUI

/// When keys were used, and whether by Claude Code or by you. Never their values.
struct ActivityView: View {
    @Environment(AppState.self) private var state
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all, claudeCode, you

        var label: String {
            switch self {
            case .all: return "All"
            case .claudeCode: return "Claude Code"
            case .you: return "You"
            }
        }
    }

    var body: some View {
        Screen {
            ScreenHeader(title: "Activity", subtitle: "When each key was used and what used it. Values are never logged.") {
                if !state.log.entries.isEmpty {
                    ConfirmButton(title: "Clear", confirmTitle: "Clear the log?") { state.log.clear() }
                }
            }
            PillPicker(selection: $filter, options: Filter.allCases) { $0.label }
                .frame(maxWidth: 340)

            let entries = state.log.entries.filter {
                switch filter {
                case .all: return true
                case .claudeCode: return $0.source == .claudeCode
                case .you: return $0.source == .you
                }
            }
            if entries.isEmpty {
                MessageCard(title: "Nothing yet",
                            message: filter == .claudeCode
                                ? "When Claude Code runs a command with one of your keys, it shows up here: which key, which program and how it went."
                                : "Showing, copying, adding and using keys shows up here.",
                            mood: .sleepy, fill: AppColors.mint) { EmptyView() }
            } else {
                VStack(spacing: 6) {
                    ForEach(entries.prefix(500)) { entry in
                        ActivityRow(entry: entry)
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, fill: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.summary)
                        .font(.mono(11.5, weight: .semibold))
                        .foregroundStyle(AppColors.text)
                    if !entry.names.isEmpty {
                        Text(entry.names.joined(separator: ", "))
                            .font(.mono(11))
                            .foregroundStyle(AppColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                let details = [entry.detail, entry.action == .refused ? nil : entry.folder.map(BridgePolicy.tidy)].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.mono(9.5))
                        .foregroundStyle(entry.action == .refused ? AppColors.destructive : AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TagPill(text: entry.sourceLabel,
                    fill: entry.source == .claudeCode ? AppColors.peach : AppColors.ground,
                    foreground: entry.source == .claudeCode ? AppColors.ink : AppColors.text)
            Text(entry.date, format: .relative(presentation: .named))
                .font(.mono(9.5))
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 92, alignment: .trailing)
                .help(entry.date.formatted(date: .complete, time: .standard))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card()
    }

    private var symbol: String {
        switch entry.action {
        case .ran: return "play.fill"
        case .refused: return "hand.raised.fill"
        case .revealed: return "eye.fill"
        case .copied: return "doc.on.doc.fill"
        case .added: return "plus"
        case .changed: return "pencil"
        case .renamed: return "character.cursor.ibeam"
        case .deleted: return "trash.fill"
        case .imported: return "square.and.arrow.down.fill"
        case .deletedEverything: return "trash.fill"
        case .sent: return "paperplane.fill"
        case .requested: return "questionmark.bubble.fill"
        case .tested: return "checkmark.seal.fill"
        case .stopped: return "hand.raised.fill"
        case .rotated: return "arrow.triangle.2.circlepath"
        case .hid: return "eye.slash.fill"
        }
    }

    private var tint: Color {
        switch entry.action {
        case .ran: return AppColors.mint
        case .refused, .deleted, .deletedEverything: return AppColors.coral
        case .revealed, .copied: return AppColors.butter
        default: return AppColors.lilac
        }
    }
}
