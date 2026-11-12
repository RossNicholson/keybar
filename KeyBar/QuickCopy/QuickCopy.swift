import AppKit
import SwiftUI

/// The quick copy box: ⌥⌘K from any app, type a few letters, Enter copies
/// the key (after Touch ID). Esc or clicking away closes it.
@MainActor
final class QuickCopyController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: QuickCopyView(close: { [weak self] in self?.close() },
                                                                  copy: { [weak self] name in self?.copy(name) })
            .environment(state))
        place(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func copy(_ name: String) {
        close()
        Task { _ = await state.copy(name) }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // the box draws its own: the panel is bigger than it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    /// A third of the way down the screen with the mouse, like Spotlight
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = QuickCopyView.size
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 4))
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }
}

/// A borderless panel that can still take typing
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickCopyView: View {
    @Environment(AppState.self) private var state
    let close: () -> Void
    let copy: (String) -> Void
    @State private var text = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private static let maxResults = 7
    /// Room for the most results; the panel around the box is clear
    static let size = NSSize(width: 480, height: 340)

    private var results: [SecretRecord] {
        Array(state.store.search(text).prefix(Self.maxResults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(AppColors.secondaryText)
                TextField("Copy a key…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.mono(15))
                    .foregroundStyle(AppColors.text)
                    .focused($focused)
                    .onSubmit(copySelected)
                Text(GlobalHotKey.displayName)
                    .font(.mono(9.5))
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if !results.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, record in
                        Button { copy(record.name) } label: {
                            HStack(spacing: 10) {
                                ServiceTile(record: record, size: 22)
                                Text(record.name)
                                    .font(.mono(11.5, weight: .semibold))
                                    .foregroundStyle(AppColors.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(record.displayGroup)
                                    .font(.mono(9.5))
                                    .foregroundStyle(AppColors.secondaryText)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(index == selected ? AppColors.surfaceHover : .clear,
                                        in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            } else if !text.isEmpty {
                Text("No keys match \"\(text)\"")
                    .font(.mono(10.5))
                    .foregroundStyle(AppColors.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 460)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.window, style: .continuous).strokeBorder(AppColors.hairline))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .onAppear { focused = true }
        .onChange(of: text) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func copySelected() {
        guard results.indices.contains(selected) else { return }
        copy(results[selected].name)
    }
}
