import SwiftUI

/// The panel under the menu bar icon: find a key, show or copy it, add one
struct MenuBarPanel: View {
    @Environment(AppState.self) private var state
    let close: () -> Void
    @State private var search = ""
    @State private var showingAdd = false
    @State private var showingAbout = false

    /// Rows shown before the list scrolls
    private static let visibleRows = 6
    private static let rowHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 8) {
                if state.store.records.isEmpty {
                    MessageCard(title: "No keys yet",
                                message: "Add an API key once and Claude Code can use it without ever seeing it.",
                                fill: AppColors.butter, compact: true) {
                        PillButton(title: "Add a key", symbol: "plus") { showingAdd = true }
                    }
                } else {
                    if state.store.records.count > Self.visibleRows {
                        SearchField(text: $search)
                    }
                    keyList
                }
                claudeCard
            }
            .padding(.horizontal, PanelMetrics.inset)
            .padding(.bottom, 12)
            Spacer(minLength: 0)
            footer
        }
        .menuBarPanel()
    }

    // MARK: - Header

    private var header: some View {
        PanelHeader(title: "KeyBar", subtitle: "Your API keys") {
            Mascot(size: PanelMetrics.mascot)
        } actions: {
            HeaderIconButton(symbol: "plus", help: "Add a key") { showingAdd.toggle() }
                .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                    AddKeyView(compact: true) { showingAdd = false }
                        .environment(state)
                }
            HeaderIconButton(symbol: "macwindow", help: "Open KeyBar") {
                close()
                state.openWindow?(nil)
            }
            HeaderIconButton(symbol: "info", help: "About & help") { showingAbout.toggle() }
                .popover(isPresented: $showingAbout, arrowEdge: .bottom) {
                    AboutPopover(app: .keyBar, hidingInstalledApps: !state.isDemo) { Mascot(size: 56) }
                }
        }
    }

    // MARK: - Keys

    private var keyList: some View {
        let records = state.store.search(search)
        let rows = VStack(spacing: 6) {
            ForEach(records) { record in
                PanelKeyRow(record: record)
            }
            if records.isEmpty {
                Text("No keys match \"\(search)\"")
                    .font(.mono(10.5))
                    .foregroundStyle(AppColors.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        return Group {
            if state.store.records.count > Self.visibleRows {
                ScrollView { rows }
                    .scrollIndicators(.automatic)
                    .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight + 10)
            } else {
                rows
            }
        }
    }

    // MARK: - Claude Code

    @ViewBuilder private var claudeCard: some View {
        switch state.claude.status {
        case .connected:
            EmptyView()
        case .disconnected, .elsewhere:
            let moved = state.claude.status != .disconnected
            Button {
                close()
                state.openWindow?(.claudeCode)
            } label: {
                HStack(spacing: 10) {
                    SymbolTile(symbol: "terminal.fill", fill: .white.opacity(0.6), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moved ? "Reconnect Claude Code" : "Connect Claude Code")
                            .font(.display(16, relativeTo: .headline))
                            .textCase(.uppercase)
                        Text(moved ? "KeyBar has moved since you connected it" : "So Claude can use your keys without seeing them")
                            .font(.mono(9.5))
                            .opacity(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(AppColors.ink, in: Circle())
                }
                .padding(10)
                .pastelCard(AppColors.peach, radius: Radius.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
    }

    // MARK: - Footer

    private var footer: some View {
        PanelFooter {
            let count = state.store.records.count
            let keys = "\(count) key\(count == 1 ? "" : "s")"
            switch state.claude.status {
            case .connected: Text("\(keys) · Claude Code connected")
            default: Text("\(keys) · Not connected")
            }
        }
    }
}

/// One key in the panel: its service, name, and show and copy buttons
struct PanelKeyRow: View {
    let record: SecretRecord
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            ServiceTile(record: record, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.mono(11, weight: .semibold))
                    .foregroundStyle(AppColors.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                KeySubtitle(record: record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            KeyActions(name: record.name, fromPanel: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card(hovered: hovered)
        .onHover { hovered = $0 }
    }
}
