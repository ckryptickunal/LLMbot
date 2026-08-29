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

    /// Values already read in this process, so one launch costs at most one authorisation
    /// per account.
    ///
    /// Why cache a secret in memory: every reader here already holds the value for as long
    /// as it needs it — `StreamingRedactor` keeps all three for the life of a run, and the
    /// Gemini adapter holds one per turn. The cache adds no exposure that did not exist, and
    /// it removes the thing that made the app unusable: an unsigned build re-authorising on
    /// every single read. The rejected alternative was caching in `AgentLoop` instead, which
    /// fixes one caller and leaves every other one prompting.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    public static func get(_ account: String) -> String? {
        lock.lock()
        if let hit = cache[account] { lock.unlock(); return hit }
        lock.unlock()

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

        lock.lock()
        cache[account] = value
        lock.unlock()
        return value
    }

    /// Drops the in-process copy. Called on every write and delete so a key changed in
    /// Settings takes effect on the next turn rather than after a relaunch.
    private static func forget(_ account: String) {
        lock.lock()
        cache[account] = nil
        lock.unlock()
    }

    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        forget(account)
        guard !value.isEmpty else { return true }  // empty means "remove"

        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Available after first unlock so routines can run while the screen is locked,
        // but never synced to iCloud and never leaving this device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        // Written by this process, so it owns the item's ACL. Seeding the cache means the
        // very first use after saving a key in Settings needs no authorisation at all.
        lock.lock()
        cache[account] = value
        lock.unlock()
        return true
    }

    public static func delete(_ account: String) {
        forget(account)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// Whether a credential exists, without reading it. Used by settings screens, by the
    /// composer's model picker, and by `doctor.sh`.
    ///
    /// **This must never prompt, and getting that wrong is not obvious.** A keychain item's
    /// ACL guards its *data*, not its attributes. Asking for `kSecReturnData: false` and
    /// nothing else does not describe an attribute query — it leaves the query with no
    /// return type at all, so the Security framework falls back to fetching the data, hits
    /// the ACL, and macOS asks the user for their login password. That is what made the app
    /// demand a password on every keystroke: this call sits in a SwiftUI computed property
    /// (`Composer.swift`), and an eval run tripped it before doing any work at all.
    ///
    /// Asking for attributes explicitly is what makes it an attribute query. Verified with an
    /// ad-hoc-signed probe against an item whose ACL trusted only `/usr/bin/security`:
    /// `errSecSuccess`, no data blob returned, no dialog.
    public static func has(_ account: String) -> Bool {
        var out: CFTypeRef?
        return SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out) == errSecSuccess
    }
}
