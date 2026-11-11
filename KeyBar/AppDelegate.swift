import AppKit
import SwiftUI

/// Owns the menu bar item, the main window and the bridge the helper talks to.
/// KeyBar is a menu bar app: closing the window keeps it running there.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var state: AppState!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanelController?
    private var bridge: BridgeServer?
    private var policy: BridgePolicy?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't touch the Keychain or open anything when hosting unit tests
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        // `-demo YES`: sample keys in memory, for screenshots and trying the UI
        let demo = UserDefaults.standard.bool(forKey: "demo")
        #else
        let demo = false
        #endif
        state = testing || demo ? Demo.state() : AppState.live()
        state.openWindow = { [weak self] section in self?.show(section) }
        state.settings.onChange = { [weak self] in self?.applyDockSetting() }
        guard !testing else { return }

        setUpStatusItem()
        if !demo { startBridge() }
        Task { await state.updater.checkSilent() }

        let launchedByHelper = UserDefaults.standard.bool(forKey: "launchedByHelper")
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch || demo {
            show(state.store.records.isEmpty ? .keys : nil)
        } else if !launchedByHelper && !Self.launchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel?.open() }
        }
        applyDockSetting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { show(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - The bridge

    private func startBridge() {
        let policy = BridgePolicy(store: state.store, log: state.log)
        self.policy = policy
        let server = BridgeServer { request in
            // The store lives on the main thread
            DispatchQueue.main.sync { MainActor.assumeIsolated { policy.handle(request) } }
        }
        do {
            try server.start()
            bridge = server
        } catch {
            NSLog("KeyBar: couldn't start the bridge: \(error)")
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: "KeyBar")
            ?? NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyBar")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "KeyBar"
        statusItem = item

        let panel = MenuBarPanelController(statusItem: item)
        self.panel = panel
        let state = self.state!
        panel.setContent {
            MenuBarPanel(close: { [weak panel] in panel?.close() }).environment(state)
        }
        panel.onOpen = { state.claude.refresh() }
        panel.onClose = { state.hideAll() }
        state.reopenPanel = { [weak panel] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { panel?.open() }
        }
        observePanelSize()
    }

    /// The panel fits its content; refit when the keys or the connection change
    private func observePanelSize() {
        withObservationTracking {
            _ = state.store.records.count
            _ = state.claude.status
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.panel?.fitToContent()
                self?.observePanelSize()
            }
        }
    }

    // MARK: - Window

    func show(_ section: AppSection?, adding: Bool = false) {
        if let section { state.section = section }
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if adding {
            NotificationCenter.default.post(name: .keyBarAddKey, object: nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let content = ContentView()
            .environment(state)
            .frame(minWidth: 820, minHeight: 560)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KeyBar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.delegate = self
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        state.hideAll()
        DispatchQueue.main.async { self.applyDockSetting() }
    }

    private func applyDockSetting() {
        let windowOpen = window?.isVisible == true
        NSApp.setActivationPolicy(state.settings.showInDock || windowOpen ? .regular : .accessory)
    }

    /// Whether macOS opened us as a login item
    private static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 180
    }
}

extension Notification.Name {
    static let keyBarAddKey = Notification.Name("KeyBarAddKey")
}
