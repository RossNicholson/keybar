import Foundation
import Security

/// Where key values live. The app uses the Keychain; tests and demo mode use
/// memory.
protocol Vault: AnyObject {
    /// `interactive` false never shows a Keychain dialog: an item macOS would
    /// ask about reads as an error instead
    func read(_ name: String, interactive: Bool) throws -> String?
    func write(_ name: String, value: String) throws
    func delete(_ name: String) throws
    /// Every key name stored, so keys added before the index existed are found
    func names() throws -> [String]
    /// A key's details (group, note, folders) kept with it, so they sync
    /// with the key. Only synced keys have them.
    func details() throws -> [String: Data]
    func setDetails(_ name: String, _ data: Data) throws
}

extension Vault {
    func read(_ name: String) throws -> String? { try read(name, interactive: true) }
    func details() throws -> [String: Data] { [:] }
    func setDetails(_ name: String, _ data: Data) throws {}
}

enum VaultError: LocalizedError {
    case keychain(OSStatus)
    case notText

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain said: \(message)"
        case .notText:
            return "That Keychain item isn't text."
        }
    }
}

/// Each key is its own generic password item under the service "KeyBar":
/// in this Mac's login keychain, or in iCloud Keychain, which syncs it to the
/// user's other Macs. The value is only ever written there.
final class KeychainVault: Vault {
    enum Place {
        /// The login keychain, on this Mac only
        case thisMac
        /// The data protection keychain, synced by iCloud Keychain. Needs the
        /// keychain-access-groups entitlement, which only a build signed with
        /// KeyBar's provisioning profile has.
        case iCloud
    }

    static let service = "KeyBar"
    private let service: String
    let place: Place

    /// `service` is only changed by tests, to keep clear of real keys
    init(service: String = KeychainVault.service, place: Place = .thisMac) {
        self.service = service
        self.place = place
    }

    private func query(_ name: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if place == .iCloud {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = true
        }
        if let name { query[kSecAttrAccount as String] = name }
        return query
    }

    func read(_ name: String, interactive: Bool) throws -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive && place == .thisMac { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw VaultError.notText }
        return value
    }

    func write(_ name: String, value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw VaultError.keychain(status) }
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "KeyBar: \(name)"
        add[kSecAttrDescription as String] = place == .iCloud ? "API key stored by KeyBar, synced by iCloud Keychain" : "API key stored by KeyBar"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw VaultError.keychain(added) }
    }

    func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }

    func names() throws -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func details() throws -> [String: Data] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        var details: [String: Data] = [:]
        for item in result as? [[String: Any]] ?? [] {
            if let name = item[kSecAttrAccount as String] as? String, let data = item[kSecAttrGeneric as String] as? Data {
                details[name] = data
            }
        }
        return details
    }

    func setDetails(_ name: String, _ data: Data) throws {
        let status = SecItemUpdate(query(name) as CFDictionary, [kSecAttrGeneric as String: data] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}

/// The app's keys: in iCloud Keychain while sync is on, else on this Mac.
/// Reads look in both places, so a key is found while it's being moved, and
/// a write leaves one copy only.
final class LiveVault: Vault {
    let thisMac: Vault
    let iCloud: Vault
    /// Whether new and changed keys go to iCloud Keychain
    var syncs: Bool

    init(thisMac: Vault, iCloud: Vault, syncs: Bool) {
        self.thisMac = thisMac
        self.iCloud = iCloud
        self.syncs = syncs
    }

    static func live() -> LiveVault {
        LiveVault(thisMac: KeychainVault(), iCloud: KeychainVault(place: .iCloud),
                  syncs: UserDefaults.standard.bool(forKey: AppSettings.syncKey))
    }

    private var first: Vault { syncs ? iCloud : thisMac }
    private var second: Vault { syncs ? thisMac : iCloud }

    func read(_ name: String, interactive: Bool) throws -> String? {
        if let value = try first.read(name, interactive: interactive) { return value }
        // Off, iCloud's copies are another Mac's business
        return syncs ? try second.read(name, interactive: interactive) : nil
    }

    func write(_ name: String, value: String) throws {
        try first.write(name, value: value)
        if syncs { try? thisMac.delete(name) }
    }

    func delete(_ name: String) throws {
        try first.delete(name)
        if syncs { try thisMac.delete(name) }
    }

    func names() throws -> [String] {
        guard syncs else { return try thisMac.names() }
        return Array(Set(try iCloud.names() + thisMac.names()))
    }

    func details() throws -> [String: Data] { syncs ? try iCloud.details() : [:] }

    func setDetails(_ name: String, _ data: Data) throws {
        if syncs { try iCloud.setDetails(name, data) }
    }

    /// Whether this copy of KeyBar can use iCloud Keychain at all: a build
    /// without KeyBar's provisioning profile is refused (missing entitlement)
    var iCloudAvailable: Bool {
        do {
            _ = try iCloud.names()
            return true
        } catch VaultError.keychain(let status) where status == errSecMissingEntitlement {
            return false
        } catch {
            return true
        }
    }
}

/// Keys kept in memory only, for tests and demo mode
final class MemoryVault: Vault {
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    private var extra: [String: Data] = [:]

    func read(_ name: String, interactive: Bool) throws -> String? { values[name] }
    func write(_ name: String, value: String) throws { values[name] = value }
    func delete(_ name: String) throws { values[name] = nil; extra[name] = nil }
    func names() throws -> [String] { Array(values.keys) }
    func details() throws -> [String: Data] { extra }
    func setDetails(_ name: String, _ data: Data) throws {
        if values[name] != nil { extra[name] = data }
    }
}
