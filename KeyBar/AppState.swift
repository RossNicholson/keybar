import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case keys, activity, claudeCode, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keys: return "Keys"
        case .activity: return "Activity"
        case .claudeCode: return "Claude Code"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .keys: return "key.fill"
        case .activity: return "clock.arrow.circlepath"
        case .claudeCode: return "terminal.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .keys: return AppColors.butter
        case .activity: return AppColors.mint
        case .claudeCode: return AppColors.peach
        case .settings: return AppColors.lilac
        }
    }
}

/// Everything the views share
@MainActor
@Observable
final class AppState {
    let store: SecretStore
    let log: ActivityLog
    let settings = AppSettings()
    let claude: ClaudeConnector
    @ObservationIgnored let updater = SelfUpdater(app: .keyBar)

    var section: AppSection = .keys
    /// The key selected in the window's Keys list
    var selectedKey: String?
    /// Keys whose value is showing, and until when
    private(set) var revealed: [String: String] = [:]
    var isDemo = false

    @ObservationIgnored var openWindow: ((AppSection?) -> Void)?
    /// Reopens the menu bar panel, which closes while Touch ID asks
    @ObservationIgnored var reopenPanel: (() -> Void)?

    init(store: SecretStore, log: ActivityLog, claude: ClaudeConnector) {
        self.store = store
        self.log = log
        self.claude = claude
    }

    static func live() -> AppState {
        AppState(store: .live(), log: .live(), claude: ClaudeConnector())
    }

    // MARK: - Showing and copying keys

    func isRevealed(_ name: String) -> Bool { revealed[name] != nil }
    func revealedValue(_ name: String) -> String? { revealed[name] }

    /// Shows a key's value for 30 seconds, after Touch ID
    func reveal(_ name: String, fromPanel: Bool = false) async {
        guard await OwnerCheck.confirm("show \(name)", required: settings.requireTouchID && !isDemo) else {
            if fromPanel { reopenPanel?() }
            return
        }
        if fromPanel { reopenPanel?() }
        do {
            let value = try store.value(name)
            revealed[name] = value
            log.log(.revealed, [name])
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.revealed[name] == value { self?.revealed[name] = nil }
            }
        } catch {
            NSSound.beep()
        }
    }

    func hide(_ name: String) {
        revealed[name] = nil
    }

    func hideAll() {
        revealed = [:]
    }

    /// Copies a key's value, after Touch ID unless it's already showing
    func copy(_ name: String, fromPanel: Bool = false) async -> Bool {
        if !isRevealed(name) {
            guard await OwnerCheck.confirm("copy \(name)", required: settings.requireTouchID && !isDemo) else {
                if fromPanel { reopenPanel?() }
                return false
            }
            if fromPanel { reopenPanel?() }
        }
        guard let value = try? store.value(name) else { NSSound.beep(); return false }
        Clipboard.copySecret(value, clearAfter: settings.clipboardSeconds)
        log.log(.copied, [name], detail: "Clipboard clears in \(AppSettings.label(forSeconds: settings.clipboardSeconds))")
        return true
    }

    // MARK: - Changing keys

    func add(name: String, value: String, group: String?, note: String?, projectFolders: [String] = []) throws {
        try store.add(name: name, value: value, group: group, note: note, projectFolders: projectFolders)
        log.log(.added, [name])
    }

    func delete(_ name: String) throws {
        try store.delete(name)
        revealed[name] = nil
        if selectedKey == name { selectedKey = nil }
        log.log(.deleted, [name])
    }

    func rename(_ name: String, to newName: String) throws {
        try store.rename(name, to: newName)
        revealed[name] = nil
        if selectedKey == name { selectedKey = newName }
        log.log(.renamed, [newName], detail: "Was \(name)")
    }

    func replaceValue(_ name: String, with value: String) throws {
        try store.replaceValue(name, with: value)
        revealed[name] = nil
        log.log(.changed, [name], detail: "New value")
    }

    func importEntries(_ entries: [EnvFile.Entry], group: String?, from file: String) throws -> Int {
        var imported: [String] = []
        for entry in entries {
            try store.add(name: entry.name, value: entry.value, group: group, note: nil, replacing: true)
            imported.append(entry.name)
        }
        if !imported.isEmpty { log.log(.imported, imported, detail: "From \(file)") }
        return imported.count
    }

    func deleteEverything() throws {
        try store.deleteEverything()
        revealed = [:]
        selectedKey = nil
        log.clear()
        log.log(.deletedEverything, [])
    }
}

/// Settings, kept in UserDefaults
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored var onChange: (() -> Void)?

    var requireTouchID: Bool = UserDefaults.standard.object(forKey: "requireTouchID") as? Bool ?? true {
        didSet { UserDefaults.standard.set(requireTouchID, forKey: "requireTouchID") }
    }

    /// How long a copied key stays on the clipboard
    var clipboardSeconds: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "clipboardSeconds")
        return stored > 0 ? stored : 20
    }() {
        didSet { UserDefaults.standard.set(clipboardSeconds, forKey: "clipboardSeconds") }
    }

    static let clipboardChoices: [TimeInterval] = [20, 60, 120]

    /// Whether to ask with Touch ID before Claude Code (or another app) uses a
    /// key: 0 never, -1 every time, otherwise once per this many seconds
    var approvalSeconds: TimeInterval = UserDefaults.standard.double(forKey: "approvalSeconds") {
        didSet { UserDefaults.standard.set(approvalSeconds, forKey: "approvalSeconds") }
    }

    static let approvalChoices: [TimeInterval] = [0, -1, 900, 3600]

    static func approvalLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 0: return "Never"
        case -1: return "Every time"
        case 900: return "15 min"
        default: return "1 hour"
        }
    }

    static func label(forSeconds seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) sec" : "\(Int(seconds / 60)) min"
    }

    var showInDock: Bool = UserDefaults.standard.bool(forKey: "showInDock") {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            onChange?()
        }
    }

    /// Whether Connect also adds the note to CLAUDE.md
    var addClaudeReminder: Bool = UserDefaults.standard.object(forKey: "addClaudeReminder") as? Bool ?? true {
        didSet { UserDefaults.standard.set(addClaudeReminder, forKey: "addClaudeReminder") }
    }

    private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var loginError: String?

    func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "macOS didn't allow that: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        if on && status == .requiresApproval {
            loginError = "Allow KeyBar in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
