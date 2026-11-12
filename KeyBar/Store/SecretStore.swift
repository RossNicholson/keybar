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
    /// Set for a key that's a whole file (a .json service account, a .p8):
    /// the file's name. Commands get the path to a private copy of it.
    var fileName: String?
    /// When the key stops working, for a reminder beforehand
    var expiresAt: Date?
    /// Where it's been sent (GitHub Actions secrets, Cloudflare), so a new
    /// value can be sent to the same places
    var destinations: [Destination]?
    /// When to ask with Touch ID before a command uses it; nil follows Settings
    var approval: KeyApproval?
    /// Commands get a placeholder and a local address instead of the key, and
    /// KeyBar adds the key to their requests to the service (see KeyProxy)
    var proxied: Bool?

    var id: String { name }
    var usesProxy: Bool { proxied == true && KeyProxy.route(for: self) != nil }
    var isFile: Bool { fileName != nil }
    var sentTo: [Destination] { destinations ?? [] }

    /// Days until it expires (negative once it has), or nil without a date
    func daysUntilExpiry(from now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiresAt)).day
    }

    /// Expired, or expiring within `KeyHealth.soonDays`
    var expiresSoon: Bool { (daysUntilExpiry() ?? .max) <= KeyHealth.soonDays }
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

/// A key's own rule for asking with Touch ID before a command uses it
enum KeyApproval: String, Codable, Sendable, CaseIterable {
    /// Every use, whatever Settings says: for the keys that matter most
    case everyTime
    /// Never: for a throwaway test key. `keybar run` still asks.
    case never
}

/// The details that travel with a synced key, in its Keychain item: when
/// it was last used stays on each Mac
struct SyncedDetails: Codable, Equatable {
    var group: String?
    var note: String?
    var projectFolders: [String]
    var createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?
    var position: Int?
    var fileName: String?
    var expiresAt: Date?
    var destinations: [Destination]?
    var approval: KeyApproval?
    var proxied: Bool?

    init(_ record: SecretRecord) {
        group = record.group
        note = record.note
        projectFolders = record.projectFolders
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        archivedAt = record.archivedAt
        position = record.position
        fileName = record.fileName
        expiresAt = record.expiresAt
        destinations = record.destinations
        approval = record.approval
        proxied = record.proxied
    }

    func apply(to record: inout SecretRecord) {
        record.group = group
        record.note = note
        record.projectFolders = projectFolders
        record.createdAt = createdAt
        record.updatedAt = updatedAt
        record.archivedAt = archivedAt
        record.position = position
        record.fileName = fileName
        record.expiresAt = expiresAt
        record.destinations = destinations
        record.approval = approval
        record.proxied = proxied
    }

    var encoded: Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> SyncedDetails? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncedDetails.self, from: data)
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
        SecretStore(vault: LiveVault.live(), indexURL: Storage.directory.appendingPathComponent("index.json"))
    }

    /// The Keychain vault that can sync, in the app (not in tests or demo mode)
    var live: LiveVault? { vault as? LiveVault }
    var syncs: Bool { live?.syncs ?? false }

    // MARK: - Reading

    func record(_ name: String) -> SecretRecord? { records.first { $0.name == name } }

    func value(_ name: String) throws -> String {
        guard let value = try vault.read(name) else { throw StoreError.missing(name) }
        return value
    }

    /// A value read without a Keychain dialog, or nil if macOS would ask
    func quietValue(_ name: String) -> String? {
        try? vault.read(name, interactive: false)
    }

    /// Every value, for checking a command doesn't contain one. Never shows
    /// a Keychain dialog: a key macOS would ask about is skipped.
    func allValues() -> [String] {
        records.compactMap { try? vault.read($0.name, interactive: false) }
    }

    /// Which stored key holds each value, for spotting keys KeyBar already
    /// has. Never shows a Keychain dialog, like `allValues`.
    func namesByValue() -> [String: String] {
        var names: [String: String] = [:]
        for record in records {
            if let value = try? vault.read(record.name, interactive: false), names[value] == nil {
                names[value] = record.name
            }
        }
        return names
    }

    /// The groups in use, in display order
    var groups: [String] {
        var seen = Set<String>()
        return records.map(\.displayGroup).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0).inserted }
    }

    /// Custom group names people have typed, for suggestions
    var customGroups: [String] {
        Array(Set(records.compactMap { $0.group?.nonEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The group as it's already spelled, so "madrobot" joins "MadRobot"
    /// instead of starting a second group
    func existingGroup(_ group: String?) -> String? {
        guard let typed = group?.nonEmpty else { return nil }
        return customGroups.first { $0.caseInsensitiveCompare(typed) == .orderedSame } ?? typed
    }

    /// Puts keys whose groups differ only in capitals into one group, spelled
    /// as the oldest key has it
    private func joinGroupSpellings() {
        let grouped = Dictionary(grouping: records.filter { $0.group?.nonEmpty != nil }) { $0.group!.lowercased() }
        var changed = false
        for (_, members) in grouped where Set(members.map(\.group)).count > 1 {
            let spelling = members.min { $0.createdAt < $1.createdAt }!.group
            for var record in members where record.group != spelling {
                record.group = spelling
                replace(record)
                changed = true
            }
        }
        if changed { save() }
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
             projectFolders: [String] = [], fileName: String? = nil, expiresAt: Date? = nil,
             replacing: Bool = false) throws {
        guard SecretName.isValid(name) else { throw StoreError.invalidName(name) }
        guard !value.isEmpty else { throw StoreError.emptyValue }
        let group = group.map { existingGroup($0) ?? "" }
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
            if let fileName { existing.fileName = fileName }
            if let expiresAt { existing.expiresAt = expiresAt }
            replace(existing)
        } else {
            replace(SecretRecord(name: name, group: group?.nonEmpty, note: note?.nonEmpty,
                                 projectFolders: projectFolders, createdAt: now, updatedAt: now,
                                 fileName: fileName, expiresAt: expiresAt))
        }
        save()
    }

    /// Saves changed details (group, note, folders); not the value or name
    func update(_ record: SecretRecord) {
        var record = record
        record.group = existingGroup(record.group)
        record.note = record.note?.nonEmpty
        replace(record)
        save()
    }

    /// `fileName` set: the new value is that file's contents
    func replaceValue(_ name: String, with value: String, fileName: String? = nil) throws {
        guard var record = record(name) else { throw StoreError.missing(name) }
        guard !value.isEmpty else { throw StoreError.emptyValue }
        try vault.write(name, value: value)
        if let fileName { record.fileName = fileName }
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
        replace(record)
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
        record.group = existingGroup(group)
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
        joinGroupSpellings()
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

    /// Remembers that a key went to `destination`, replacing an earlier send
    /// to the same place
    func recordSend(_ name: String, to destination: Destination) {
        guard var record = record(name) else { return }
        var sent = record.sentTo.filter { !$0.samePlace(as: destination) }
        sent.append(destination)
        record.destinations = sent
        replace(record)
        save()
    }

    func forgetSend(_ name: String, _ destination: Destination) {
        guard var record = record(name) else { return }
        let sent = record.sentTo.filter { !$0.samePlace(as: destination) }
        record.destinations = sent.isEmpty ? nil : sent
        replace(record)
        save()
    }

    func setExpiry(_ name: String, _ date: Date?) {
        guard var record = record(name), record.expiresAt != date else { return }
        record.expiresAt = date
        replace(record)
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
            let before = records[index]
            records[index] = record
            if SyncedDetails(before) != SyncedDetails(record) { push(record) }
        } else {
            records.append(record)
            push(record)
        }
    }

    /// Saves a key's details with it in the Keychain (only synced keys keep them)
    private func push(_ record: SecretRecord) {
        if let data = SyncedDetails(record).encoded { try? vault.setDetails(record.name, data) }
    }

    // MARK: - iCloud Keychain

    /// Picks up keys added, changed or deleted on another Mac
    func refresh() {
        let merged = merge(records)
        if merged != records {
            records = merged
            save()
        }
        joinGroupSpellings()
    }

    /// Moves this Mac's keys into iCloud Keychain and starts syncing. A key
    /// iCloud already has under the same name with another value (from
    /// another Mac) keeps that name; this Mac's copy gets a new one.
    /// Returns those renames, old name to new.
    @discardableResult
    func moveToICloud(_ live: LiveVault) throws -> [String: String] {
        var renamed: [String: String] = [:]
        let theirs = Set(try live.iCloud.names())
        var taken = theirs.union(try live.thisMac.names()).union(records.map(\.name))
        for name in try live.thisMac.names().sorted() {
            guard let value = try live.thisMac.read(name) else { continue }
            var target = name
            if theirs.contains(name), let existing = try live.iCloud.read(name), existing != value {
                target = Self.freeName(name, taken: taken)
                taken.insert(target)
                renamed[name] = target
            }
            try live.iCloud.write(target, value: value)
            try live.thisMac.delete(name)
            if target != name, var record = record(name) {
                records.removeAll { $0.name == name }
                record.name = target
                records.append(record)
            }
        }
        live.syncs = true
        records = merge(records)
        save()
        return renamed
    }

    /// Stops syncing, keeping a copy of every synced key on this Mac. The
    /// iCloud copies stay for the other Macs.
    func keepOnThisMac(_ live: LiveVault) throws {
        let mine = Set(try live.thisMac.names())
        for name in try live.iCloud.names() where !mine.contains(name) {
            if let value = try live.iCloud.read(name) { try live.thisMac.write(name, value: value) }
        }
        live.syncs = false
        refresh()
    }

    /// NAME_2, NAME_3… the first not in `taken`
    static func freeName(_ name: String, taken: Set<String>) -> String {
        var number = 2
        while taken.contains("\(name)_\(number)") { number += 1 }
        return "\(name)_\(number)"
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
        records = merge(loaded)
        if indexURL != nil { save() }
        joinGroupSpellings()
    }

    /// `base` brought in line with the Keychain, which is the truth: keeps
    /// what's there, adds anything missing, and takes synced keys' details
    /// from their items
    private func merge(_ base: [SecretRecord]) -> [SecretRecord] {
        var merged = base
        do {
            let stored = Set(try vault.names())
            merged.removeAll { !stored.contains($0.name) }
            // Forgotten items deleted since don't need remembering
            forgotten.formIntersection(stored)
            let known = Set(merged.map(\.name))
            let now = Date()
            for name in stored.subtracting(known).subtracting(forgotten) where SecretName.isValid(name) {
                merged.append(SecretRecord(name: name, createdAt: now, updatedAt: now))
            }
            let synced = try vault.details()
            for index in merged.indices {
                if let data = synced[merged[index].name], let details = SyncedDetails.decode(data) {
                    details.apply(to: &merged[index])
                } else {
                    push(merged[index])
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        return merged
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
