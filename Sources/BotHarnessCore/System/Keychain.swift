import Foundation
import Security

/// Credential storage.
///
/// The rule this enforces: **the model never sees a secret.** Bots refer to credentials by
/// name — "the Gemini key", "my GitHub token" — and the tool layer resolves the name to a
/// value at the moment of use. A key therefore never enters a prompt, never enters a trace,
/// and never enters a config file the user might commit to a public repository.
///
/// This repository is public. That is not a hypothetical concern.
public enum Keychain {
    /// One service for everything Bot-Harness stores, with the provider as the account.
    /// Matches the pattern already used by Fable (`app.fable.keys`), so the two apps'
    /// credentials stay separate in Keychain Access.
    public static let service = "app.botharness.keys"

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }  // empty means "remove"

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Available after first unlock so routines can run while the screen is locked,
        // but never synced to iCloud and never leaving this device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// Whether a credential exists, without reading it. Used by settings screens and by
    /// `doctor.sh` so that checking configuration never pulls a secret into memory.
    public static func has(_ account: String) -> Bool {
        SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
        ] as CFDictionary, nil) == errSecSuccess
    }
}
