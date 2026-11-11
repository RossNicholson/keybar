import Foundation
import Observation

/// A stored key, without its value. Saved in ~/.keybar/index.json.
struct SecretRecord: Codable, Identifiable, Hashable, Sendable {
    /// Also the environment variable it's set as, e.g. CLOUDFLARE_API_TOKEN
    var name: String
    /// Optional, e.g. a project name. Keys without one are grouped by service.
    var group: String?
    var note: String?
    /// When set, commands may only use this key from inside these folders
    var projectFolders: [String] = []
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    /// Filed away: kept in the Keychain, but hidden and not usable by commands
    var archivedAt: Date?
    /// Where it goes in its group when ordered by hand; unordered keys follow, by name
    var position: Int?

    var id: String { name }
    var isArchived: Bool { archivedAt != nil }
    var service: Service? { ServiceCatalog.match(name) }
    var kind: String { CredentialKind.of(name) }
    var displayGroup: String { group?.nonEmpty ?? service?.name ?? "Other" }
    var isRestricted: Bool { !projectFolders.isEmpty }

    /// Whether a command run in `folder` may use this key
    func isAvailable(in folder: String) -> Bool {
        guard isRestricted else { return true }
        let path = Storage.canonical(folder)
        return projectFolders.contains { allowed in
            let base = Storage.canonical(allowed)
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }
}

enum StoreError: LocalizedError {
    case invalidName(String)
    case duplicate(String)
    case missing(String)
    case emptyValue
    case archived(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "\"\(name)\" can't be a key name. Use letters, numbers and underscores, starting with a letter, like CLOUDFLARE_API_TOKEN."
        case .duplicate(let name): return "There's already a key called \(name)."
        case .missing(let name): return "There's no key called \(name)."
        case .emptyValue: return "The key is empty."
        case .archived(let name): return "\(name) is archived. Restore it first."
        }
    }
}

/// The stored keys: names and details in the index, values in the vault
/// (the Keychain)
@MainActor
@Observable
final class SecretStore {
    private(set) var records: [SecretRecord] = []
    private(set) var lastError: String?

    private let vault: Vault
    private let indexURL: URL?

    init(vault: Vault, indexURL: URL?) {
        self.vault = vault
        self.indexURL = indexURL
        load()
    }

    static func live() -> SecretStore {
        SecretStore(vault: KeychainVault(), indexURL: Storage.directory.appendingPathComponent("index.json"))
    }

    // MARK: - Reading

    func record(_ name: String) -> SecretRecord? { records.first { $0.name == name } }

    func value(_ name: String) throws -> String {
        guard let value = try vault.read(name) else { throw StoreError.missing(name) }
        return value
    }

    /// Every value, for checking a command doesn't contain one. Never shows
    /// a Keychain dialog: a key macOS would ask about is skipped.
    func allValues() -> [String] {
        records.compactMap { try? vault.read($0.name, interactive: false) }
    }

    /// The groups in use, in display order
    var groups: [String] {
        var seen = Set<String>()
        return records.map(\.displayGroup).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0).inserted }
    }

    /// Custom group names people have typed, for suggestions
    var customGroups: [String] {
        Array(Set(records.compactMap { $0.group?.nonEmpty })).sorted()
    }

    /// Hand-ordered keys first, in their order, then the rest by name
    var sorted: [SecretRecord] {
        records.sorted { a, b in
            switch (a.position, b.position) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The keys in use: everything but the archived ones
    var active: [SecretRecord] { sorted.filter { !$0.isArchived } }
    var archived: [SecretRecord] { sorted.filter(\.isArchived) }

    /// The active keys (or the archived ones) matching `text`
    func search(_ text: String, archived: Bool = false) -> [SecretRecord] {
        let base = archived ? self.archived : active
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.service?.name.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.group?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.note?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: - Changing

    func add(name: String, value: String, group: String? = nil, note: String? = nil,
             projectFolders: [String] = [], replacing: Bool = false) throws {
        guard SecretName.isValid(name) else { throw StoreError.invalidName(name) }
        guard !value.isEmpty else { throw StoreError.emptyValue }
        let existing = record(name)
        if existing != nil && !replacing { throw StoreError.duplicate(name) }
        try vault.write(name, value: value)
        forgotten.remove(name)
        let now = Date()
        if var existing {
            existing.updatedAt = now
            if let group { existing.group = group.nonEmpty }
            if let note { existing.note = note.nonEmpty }
            if !projectFolders.isEmpty { existing.projectFolders = projectFolders }
            replace(existing)
        } else {
            records.append(SecretRecord(name: name, group: group?.nonEmpty, note: note?.nonEmpty,
                                        projectFolders: projectFolders, createdAt: now, updatedAt: now))
        }
        save()
    }

    /// Saves changed details (group, note, folders); not the value or name
    func update(_ record: SecretRecord) {
        var record = record
        record.group = record.group?.nonEmpty
        record.note = record.note?.nonEmpty
        replace(record)
        save()
    }

    func replaceValue(_ name: String, with value: String) throws {
        guard var record = record(name) else { throw StoreError.missing(name) }
        guard !value.isEmpty else { throw StoreError.emptyValue }
        try vault.write(name, value: value)
        record.updatedAt = Date()
        replace(record)
        save()
    }

    func rename(_ name: String, to newName: String) throws {
        guard name != newName else { return }
        guard SecretName.isValid(newName) else { throw StoreError.invalidName(newName) }
        guard record(newName) == nil else { throw StoreError.duplicate(newName) }
        guard var record = record(name) else { throw StoreError.missing(name) }
        let value = try self.value(name)
        try vault.write(newName, value: value)
        try vault.delete(name)
        records.removeAll { $0.name == name }
        record.name = newName
        record.updatedAt = Date()
        records.append(record)
        save()
    }

    func delete(_ name: String) throws {
        try vault.delete(name)
        records.removeAll { $0.name == name }
        save()
    }

    /// Takes a key off KeyBar's list when the Keychain won't delete it. The
    /// item stays in the Keychain (Keychain Access can remove it) and isn't
    /// brought back onto the list.
    func forget(_ name: String) {
        records.removeAll { $0.name == name }
        forgotten.insert(name)
        save()
    }

    func setArchived(_ name: String, _ archived: Bool) {
        guard var record = record(name), record.isArchived != archived else { return }
        record.archivedAt = archived ? Date() : nil
        replace(record)
        save()
    }

    /// Moves a key up (-1) or down (+1) among the keys shown with it
    func move(_ name: String, by offset: Int) {
        guard let record = record(name) else { return }
        var siblings = sorted.filter { $0.displayGroup == record.displayGroup && $0.isArchived == record.isArchived }
        guard let index = siblings.firstIndex(where: { $0.name == name }) else { return }
        let target = index + offset
        guard siblings.indices.contains(target) else { return }
        siblings.swapAt(index, target)
        for (position, var sibling) in siblings.enumerated() {
            sibling.position = position
            replace(sibling)
        }
        save()
    }

    /// Puts a key in a group (nil: back under its service)
    func setGroup(_ name: String, _ group: String?) {
        guard var record = record(name) else { return }
        record.group = group?.nonEmpty
        record.position = nil
        replace(record)
        save()
    }

    /// Renames a group you made, or (to nil) ungroups its keys
    func renameGroup(_ group: String, to newName: String?) {
        for var record in records where record.group == group {
            record.group = newName?.nonEmpty
            if newName?.nonEmpty == nil { record.position = nil }
            replace(record)
        }
        save()
    }

    /// Removes every key from the Keychain and the index
    func deleteEverything() throws {
        for name in Set(records.map(\.name) + ((try? vault.names()) ?? [])) {
            try vault.delete(name)
        }
        records = []
        forgotten = []
        save()
    }

    func markUsed(_ names: [String]) {
        let now = Date()
        for name in names {
            guard var record = record(name) else { continue }
            record.lastUsedAt = now
            replace(record)
        }
        save()
    }

    private func replace(_ record: SecretRecord) {
        if let index = records.firstIndex(where: { $0.name == record.name }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    // MARK: - The index

    private struct Index: Codable {
        var version = 1
        var secrets: [SecretRecord]
        /// Names taken off the list with `forget` while still in the Keychain
        var forgotten: [String]?
    }

    /// See `forget`
    private var forgotten: Set<String> = []

    private func load() {
        var loaded: [SecretRecord] = []
        if let indexURL, let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let index = try? decoder.decode(Index.self, from: data) {
                loaded = index.secrets
                forgotten = Set(index.forgotten ?? [])
            } else {
                lastError = "KeyBar couldn't read its list of keys (\(indexURL.path)). The keys themselves are safe in the Keychain."
            }
        }
        // The Keychain is the truth: keep what's there, add anything the index lacks
        do {
            let stored = Set(try vault.names())
            loaded.removeAll { !stored.contains($0.name) }
            // Forgotten items deleted since don't need remembering
            forgotten.formIntersection(stored)
            let known = Set(loaded.map(\.name))
            let now = Date()
            for name in stored.subtracting(known).subtracting(forgotten) where SecretName.isValid(name) {
                loaded.append(SecretRecord(name: name, createdAt: now, updatedAt: now))
            }
        } catch {
            lastError = error.localizedDescription
        }
        records = loaded
        if indexURL != nil { save() }
    }

    private func save() {
        guard let indexURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Index(secrets: sorted, forgotten: forgotten.isEmpty ? nil : forgotten.sorted()))
            try Storage.writePrivate(data, to: indexURL)
        } catch {
            lastError = "Couldn't save the list of keys: \(error.localizedDescription)"
        }
    }
}

/// ~/.keybar, readable only by this user
enum Storage {
    static var directory: URL { Bridge.directory }

    static func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A folder's real path, with ~, symlinks and dots resolved
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var result = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

extension String {
    /// nil for an empty or all-space string
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
