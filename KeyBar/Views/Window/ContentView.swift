import SwiftUI

/// The main window: a sidebar of sections and the chosen one beside it
struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.ground)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.claude.refresh()
        }
        // A key Claude Code asked for
        .sheet(item: Binding(get: { state.keyRequest }, set: { if $0 == nil, let open = state.keyRequest { state.answer(open) } })) { request in
            AddKeyView(request: request) { state.answer(request) }
                .environment(state)
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.section {
        case .keys: KeysView()
        case .activity: ActivityView()
        case .claudeCode: ClaudeCodeView()
        case .leaks: LeakCheckView()
        case .devTools: DevToolsView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Mascot(size: 40)
                Text("KeyBar")
                    .font(.display(26, relativeTo: .title))
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.text)
            }
            .padding(.top, 46)
            .padding(.bottom, 18)
            .padding(.horizontal, 6)

            ForEach(AppSection.allCases.filter { $0 != .settings }) { section in
                SidebarRow(section: section)
            }
            Spacer()
            SidebarRow(section: .settings)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppColors.surface.opacity(0.55))
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppColors.hairline).frame(width: 1)
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppState.self) private var state
    let section: AppSection
    @State private var hovered = false

    var body: some View {
        let selected = state.section == section
        Button {
            state.section = section
        } label: {
            HStack(spacing: 10) {
                SymbolTile(symbol: section.symbol, fill: section.tint, size: 26)
                Text(section.title)
                    .font(.mono(12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? AppColors.onSolid : AppColors.text)
                Spacer(minLength: 0)
                badge(selected: selected)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? AppColors.solid : (hovered ? AppColors.surfaceHover : .clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func badge(selected: Bool) -> some View {
        switch section {
        case .keys:
            Text("\(state.store.active.count)")
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(selected ? AppColors.onSolid : AppColors.secondaryText)
                .padding(.trailing, 6)
        case .leaks where !state.visibleLeaks.isEmpty:
            Text("\(Set(state.visibleLeaks.map(\.name)).count)")
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(AppColors.ink)
                .padding(.horizontal, 6)
                .background(AppColors.coral, in: Capsule())
                .padding(.trailing, 4)
        case .claudeCode where state.claude.status != .connected:
            Circle().fill(AppColors.coral).frame(width: 8, height: 8).padding(.trailing, 8)
                .help("Not connected")
        default:
            EmptyView()
        }
    }
}
