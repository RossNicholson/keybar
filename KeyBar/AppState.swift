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

    /// For a key the Keychain won't delete: off the list, still in the Keychain
    func forget(_ name: String) {
        store.forget(name)
        revealed[name] = nil
        if selectedKey == name { selectedKey = nil }
        log.log(.deleted, [name], detail: "Removed from KeyBar; still in the Keychain")
    }

    func setArchived(_ name: String, _ archived: Bool) {
        store.setArchived(name, archived)
        revealed[name] = nil
        log.log(.changed, [name], detail: archived ? "Archived" : "Restored")
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

    // MARK: - Find keys

    /// What Find keys found, as candidates to import
    func plan(_ found: [FoundKey]) -> [ScanCandidate] {
        let byValue = store.namesByValue()
        return ScanPlan.make(found, stored: Set(store.records.map(\.name)), storedName: { byValue[$0] })
    }

    /// Why these candidates can't be imported as they are, or nil if they can
    func importProblem(_ candidates: [ScanCandidate]) -> String? {
        var names = Set<String>()
        for candidate in candidates where candidate.include && candidate.status != .stored {
            guard SecretName.isValid(candidate.name) else { return StoreError.invalidName(candidate.name).errorDescription }
            if store.record(candidate.name) != nil || !names.insert(candidate.name).inserted {
                return "\(candidate.name) is used twice. Give one of them another name."
            }
        }
        return nil
    }

    /// Imports the ticked candidates, and returns them marked as stored
    func importFound(_ candidates: [ScanCandidate]) throws -> [ScanCandidate] {
        if let problem = importProblem(candidates) { throw ImportProblem(message: problem) }
        var result = candidates
        var imported: [String] = []
        for index in result.indices where result[index].include && result[index].status != .stored {
            let candidate = result[index]
            try store.add(name: candidate.name, value: candidate.value, group: candidate.group,
                          note: "Found in \(candidate.whereFound)")
            result[index].status = .stored
            imported.append(candidate.name)
        }
        if !imported.isEmpty { log.log(.imported, imported, detail: "Found on this Mac") }
        return result
    }

    struct ImportProblem: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct SwapResult: Equatable {
        var files = 0
        var swapped = 0
        /// Files that couldn't be changed, with why
        var failed: [String] = []
        /// Variables left as they were, e.g. a value over several lines
        var skipped: [String] = []
    }

    /// The .env files a swap could change: the ones holding stored values
    func swappableFiles(_ candidates: [ScanCandidate]) -> [String] {
        let paths = candidates.filter { $0.status == .stored }
            .flatMap(\.sources).filter(\.canHoldReferences).map(\.path)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Swaps the values in these .env files for keybar: references, once each
    /// value is checked to be in the Keychain
    func swapReferences(_ candidates: [ScanCandidate], in files: [String]) -> SwapResult {
        var result = SwapResult()
        for path in files {
            var references: [String: (value: String, stored: String)] = [:]
            for candidate in candidates where candidate.status == .stored && candidate.sources.contains(where: { $0.path == path }) {
                // Never take a value out of a file unless KeyBar really has it
                guard (try? store.value(candidate.name)) == candidate.value else { continue }
                references[candidate.variable] = (candidate.value, candidate.name)
            }
            let label = candidates.flatMap(\.sources).first { $0.path == path }?.label ?? BridgePolicy.tidy(path)
            guard !references.isEmpty else { continue }
            do {
                let url = URL(fileURLWithPath: path)
                let text = try String(contentsOf: url, encoding: .utf8)
                let rewrite = EnvRewriter.rewrite(text, references: references)
                result.skipped += rewrite.skipped.map { "\($0) in \(label)" }
                guard !rewrite.swapped.isEmpty else { continue }
                let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
                try Data(rewrite.text.utf8).write(to: url, options: .atomic)
                if let permissions {
                    try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
                }
                result.files += 1
                result.swapped += rewrite.swapped.count
                log.log(.changed, rewrite.swapped.compactMap { references[$0]?.stored },
                        detail: "\(label) now points to KeyBar")
            } catch {
                result.failed.append("\(label): \(error.localizedDescription)")
            }
        }
        return result
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
    /// key: 0 never, -1 every time, otherwise once per this many seconds for
    /// the same keys from the same project. On (15 minutes) by default: any
    /// program running as this user could start KeyBar's helper.
    var approvalSeconds: TimeInterval = UserDefaults.standard.object(forKey: "approvalSeconds") as? Double ?? 900 {
        didSet { UserDefaults.standard.set(approvalSeconds, forKey: "approvalSeconds") }
    }

    /// A dot on the menu bar icon while Claude Code isn't connected
    var disconnectedDot: Bool = UserDefaults.standard.object(forKey: "disconnectedDot") as? Bool ?? true {
        didSet { UserDefaults.standard.set(disconnectedDot, forKey: "disconnectedDot") }
    }

    static let approvalChoices: [TimeInterval] = [-1, 900, 3600, 0]

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

    /// The folders Find keys looks through for .env files
    var scanFolders: [String] = UserDefaults.standard.stringArray(forKey: "scanFolders") ?? AppSettings.defaultScanFolders {
        didSet { UserDefaults.standard.set(scanFolders, forKey: "scanFolders") }
    }

    /// The usual places for code that this Mac has. Not Documents, Desktop or
    /// Downloads: macOS would ask about each of them.
    static var defaultScanFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Developer", "Dev", "dev", "Projects", "projects", "Code", "code", "src", "repos", "GitHub", "Sites", "workspace"]
            .map { home.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.resolvingSymlinksInPath().path }
            // Dev and dev are one folder on a Mac's usual disk
            .reduce(into: [String]()) { found, path in
                if !found.contains(where: { $0.lowercased() == path.lowercased() }) { found.append(path) }
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
