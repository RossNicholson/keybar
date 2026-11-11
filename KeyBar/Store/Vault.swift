import Foundation
import Security

/// Where key values live. The app uses the Keychain; tests and demo mode use
/// memory.
protocol Vault: AnyObject {
    func read(_ name: String) throws -> String?
    func write(_ name: String, value: String) throws
    func delete(_ name: String) throws
    /// Every key name stored, so keys added before the index existed are found
    func names() throws -> [String]
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

/// Each key is its own generic password item in the login keychain, under
/// the service "KeyBar". The value is only ever written there.
final class KeychainVault: Vault {
    static let service = "KeyBar"

    private func query(_ name: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if let name { query[kSecAttrAccount as String] = name }
        return query
    }

    func read(_ name: String) throws -> String? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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
        add[kSecAttrDescription as String] = "API key stored by KeyBar"
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
}

/// Keys kept in memory only, for tests and demo mode
final class MemoryVault: Vault {
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func read(_ name: String) throws -> String? { values[name] }
    func write(_ name: String, value: String) throws { values[name] = value }
    func delete(_ name: String) throws { values[name] = nil }
    func names() throws -> [String] { Array(values.keys) }
}
