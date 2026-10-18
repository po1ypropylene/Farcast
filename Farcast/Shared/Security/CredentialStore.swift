import Foundation
import Security

struct ConnectionCredential: Codable {
    var password = ""
    var privateKey: Data?
    var keyName: String?
    var openVPNProfile: String?
    var openVPNUsername: String?
    var openVPNPassphrase: String?
    var wireGuardPrivateKey: String?
    var wireGuardPresharedKey: String?
}
struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))" }
}
struct CredentialStore {
    private static let service = "com.peterpo.farcast.credentials"
    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }
    private static var local: LocalCredentialStore { LocalCredentialStore() }
    private static func unavailable(_ status: OSStatus) -> Bool {
        [errSecMissingEntitlement, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable].contains(status)
    }
    static func load(_ id: UUID) throws -> ConnectionCredential? {
        if let credential = try local.load(id) { return credential }
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound || unavailable(status) { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(ConnectionCredential.self, from: data)
    }
    static func save(_ credential: ConnectionCredential, for id: UUID) throws {
        // Once a profile uses the local store, keep it there to avoid stale copies.
        if try local.load(id) != nil {
            try local.save(credential, for: id)
            return
        }
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(id)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            if unavailable(added) {
                try local.save(credential, for: id)
            } else if added != errSecSuccess {
                throw KeychainError(status: added)
            }
        } else if unavailable(status) {
            try local.save(credential, for: id)
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
    static func delete(_ id: UUID) throws {
        try local.delete(id)
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || unavailable(status) else {
            throw KeychainError(status: status)
        }
    }
}
