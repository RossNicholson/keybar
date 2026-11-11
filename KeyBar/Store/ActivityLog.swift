import Foundation
import Observation

/// One thing that happened to a key: when, what, who did it and, for a
/// command, which program it ran. Never the key's value.
struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    enum Action: String, Codable, Sendable {
        case ran, refused, revealed, copied, added, changed, renamed, deleted, imported, deletedEverything
    }

    enum Source: String, Codable, Sendable {
        case you, claudeCode, other
    }

    var id: String = UUID().uuidString
    var date: Date = Date()
    var action: Action
    var source: Source
    var names: [String]
    /// The program a command ran, e.g. "wrangler"
    var program: String?
    /// The folder it ran in
    var folder: String?
    /// e.g. "Exit 0 · 1 copy hidden", or why it was refused
    var detail: String?
    /// The app that asked, when it isn't Claude Code or you
    var client: String? = nil

    var sourceLabel: String {
        switch source {
        case .you: return "By you"
        case .claudeCode: return "By Claude Code"
        case .other: return "By \(client ?? "another app")"
        }
    }

    var summary: String {
        switch action {
        case .ran: return "Ran \(program ?? "a command")"
        case .refused: return "Refused \(program ?? "a command")"
        case .revealed: return "Revealed"
        case .copied: return "Copied"
        case .added: return "Added"
        case .changed: return "Changed"
        case .renamed: return "Renamed"
        case .deleted: return "Deleted"
        case .imported: return "Imported"
        case .deletedEverything: return "Deleted everything"
        }
    }
}

/// The activity log, kept in ~/.keybar/activity.json (the newest 2,000 entries)
@MainActor
@Observable
final class ActivityLog {
    private(set) var entries: [ActivityEntry] = []
    private let url: URL?
    static let limit = 2_000

    init(url: URL?) {
        self.url = url
        load()
    }

    static func live() -> ActivityLog {
        ActivityLog(url: Storage.directory.appendingPathComponent("activity.json"))
    }

    @discardableResult
    func add(_ entry: ActivityEntry) -> String {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
        return entry.id
    }

    func log(_ action: ActivityEntry.Action, _ names: [String], detail: String? = nil) {
        add(ActivityEntry(action: action, source: .you, names: names, detail: detail))
    }

    func update(_ id: String, detail: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].detail = detail
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Replaces the entries, for demo mode and screenshots
    func replace(with entries: [ActivityEntry]) {
        self.entries = entries
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([ActivityEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? Storage.writePrivate(data, to: url)
    }
}
