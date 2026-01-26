import Foundation
import Security

class KeychainService {
    private let service = "com.vilya.ssh"

    enum KeychainError: Error, LocalizedError {
        case duplicateItem, itemNotFound, unexpectedStatus(OSStatus), invalidData
        var errorDescription: String? {
            switch self {
            case .duplicateItem: return "Item already exists"
            case .itemNotFound: return "Item not found"
            case .unexpectedStatus(let s): return "Keychain error: \(s)"
            case .invalidData: return "Invalid data"
            }
        }
    }

    func storePrivateKey(_ key: String, withId id: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.invalidData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey.\(id)",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "privateKey.\(id)"]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
        } else if status != errSecSuccess { throw KeychainError.unexpectedStatus(status) }
    }

    func getPrivateKey(withId id: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "privateKey.\(id)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw status == errSecItemNotFound ? KeychainError.itemNotFound : KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return key
    }

    func storePublicKey(_ key: String, withId id: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.invalidData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "publicKey.\(id)",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "publicKey.\(id)"]
            SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    func getPublicKey(withId id: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "publicKey.\(id)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw status == errSecItemNotFound ? KeychainError.itemNotFound : KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return key
    }

    func deleteKeyPair(withId id: String) {
        let privateQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "privateKey.\(id)"]
        let publicQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "publicKey.\(id)"]
        SecItemDelete(privateQuery as CFDictionary)
        SecItemDelete(publicQuery as CFDictionary)
    }
}
