//
//  KeychainStore.swift
//  Burrow
//
//  Minimal generic-password storage for the one secret Burrow can hold:
//  the optional hosted-AI API key. UserDefaults stores its plist world-
//  readable on disk; the Keychain encrypts at rest and gates access on
//  the login session — table stakes before inviting OpenAI keys in.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "dev.caezium.Burrow"

    /// Read a stored secret, or nil when absent/unreadable.
    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store (upsert) a secret; an empty value deletes the entry so a
    /// cleared field leaves nothing behind.
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
