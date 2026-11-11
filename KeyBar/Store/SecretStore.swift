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

    var id: String { name }
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

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "\"\(name)\" can't be a key name. Use letters, numbers and underscores, starting with a letter, like CLOUDFLARE_API_TOKEN."
        case .duplicate(let name): return "There's already a key called \(name)."
        case .missing(let name): return "There's no key called \(name)."
        case .emptyValue: return "The key is empty."
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

    var sorted: [SecretRecord] {
        records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func search(_ text: String) -> [SecretRecord] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
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

    /// Removes every key from the Keychain and the index
    func deleteEverything() throws {
        for name in Set(records.map(\.name) + ((try? vault.names()) ?? [])) {
            try vault.delete(name)
        }
        records = []
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
    }

    private func load() {
        var loaded: [SecretRecord] = []
        if let indexURL, let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let index = try? decoder.decode(Index.self, from: data) {
                loaded = index.secrets
            } else {
                lastError = "KeyBar couldn't read its list of keys (\(indexURL.path)). The keys themselves are safe in the Keychain."
            }
        }
        // The Keychain is the truth: keep what's there, add anything the index lacks
        do {
            let stored = Set(try vault.names())
            loaded.removeAll { !stored.contains($0.name) }
            let known = Set(loaded.map(\.name))
            let now = Date()
            for name in stored.subtracting(known) where SecretName.isValid(name) {
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
            let data = try encoder.encode(Index(secrets: sorted))
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
