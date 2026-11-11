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
        // A demo run asks for Touch ID like the real thing; only tests skip it
        if demo && !testing { state.isDemo = false }
        state.openWindow = { [weak self] section in self?.show(section) }
        state.settings.onChange = { [weak self] in self?.applyDockSetting() }
        guard !testing else { return }

        setUpStatusItem()
        // Demo keys answer the helper too, so the whole flow can be tried
        // without real keys
        startBridge()
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

    private var statusRefresh: Timer?

    /// The key, with a coral dot when Claude Code isn't connected (unless
    /// that's turned off in Settings)
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: "KeyBar")
            ?? NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyBar")
        let showDot = state.settings.disconnectedDot && state.claude.status != .connected
        guard showDot, let symbol else {
            symbol?.isTemplate = true
            button.image = symbol
            button.toolTip = "KeyBar"
            return
        }
        let size = NSSize(width: symbol.size.width + 4, height: max(symbol.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            // Drawn each time it's shown, so the key matches the menu bar's appearance
            let keyRect = NSRect(x: 0, y: (rect.height - symbol.size.height) / 2,
                                 width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: keyRect)
            NSColor.labelColor.set()
            keyRect.fill(using: .sourceAtop)
            let dot = NSRect(x: rect.width - 6, y: rect.height - 7, width: 6, height: 6)
            NSColor(srgbRed: 0.91, green: 0.45, blue: 0.38, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "KeyBar, Claude Code not connected"
        button.image = image
        button.toolTip = "KeyBar · Claude Code isn't connected"
    }

    private func startBridge() {
        let policy = BridgePolicy(store: state.store, log: state.log, settings: state.settings)
        self.policy = policy
        let prompting = PromptGate()
        let server = BridgeServer { request in
            // The store lives on the main thread. Touch ID is asked for from
            // this background thread, so the app stays responsive meanwhile.
            let prompt = DispatchQueue.main.sync { MainActor.assumeIsolated { policy.approvalPrompt(for: request) } }
            if let prompt {
                // One prompt at a time, so a flood of requests can't stack them up
                guard prompting.enter() else {
                    return .failure("KeyBar is already waiting for the user to answer a Touch ID prompt. Try again once they have.")
                }
                // Answered before the helper stops waiting for a reply
                let allowed = OwnerCheck.confirmBlocking(prompt, timeout: Bridge.approvalTimeout)
                prompting.leave()
                guard allowed else {
                    return DispatchQueue.main.sync { MainActor.assumeIsolated { policy.declined(request) } }
                }
                DispatchQueue.main.sync { MainActor.assumeIsolated { policy.approved(request) } }
            }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { policy.handle(request) } }
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
        statusItem = item
        updateStatusIcon()

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

    /// The panel fits its content; refit when the keys or the connection
    /// change, and update the menu bar icon's dot
    private func observePanelSize() {
        withObservationTracking {
            _ = state.store.active.count
            _ = state.claude.status
            _ = state.settings.disconnectedDot
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.panel?.fitToContent()
                self?.updateStatusIcon()
                self?.observePanelSize()
            }
        }
        // Claude Code can be changed from the terminal too
        guard statusRefresh == nil else { return }
        statusRefresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.claude.refresh() }
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

/// Lets one Touch ID prompt be waiting at a time
private final class PromptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func enter() -> Bool {
        lock.withLock {
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    func leave() {
        lock.withLock { busy = false }
    }
}
