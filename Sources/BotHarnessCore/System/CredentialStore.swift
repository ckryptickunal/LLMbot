import Foundation

/// Where API keys live.
///
/// A single owner-only file, not the keychain. See
/// `docs/decisions/0012-credentials-live-in-an-owner-only-file.md` for why, and for what that
/// costs — because it does cost something, and the compensating controls below are the price.
///
/// **This is a weaker store than the keychain.** The keychain encrypts at rest, ties access to
/// a code signature, and asks the user before an untrusted binary reads a secret. A file with
/// mode 0600 does none of that: anything running as this user can read it. What it buys is that
/// the app and its eval binary stop asking for the login password on every launch, which they
/// did unavoidably, because an ad-hoc-signed binary's "Always Allow" grant dies with the next
/// build.
///
/// Three things carry the weight the keychain used to:
///
/// 1. **The file is owner-read-only and its directory is owner-only.** Enforced on every write,
///    not once at creation, because a mode is not a fact you establish — it is one you keep.
/// 2. **Bots cannot read it.** The path is on the safety floor's permanent deny list, so a bot
///    with file access to its own workspace still cannot read the app's keys. Without this the
///    move would be indefensible: keys in a file inside a directory the agent can reach is a
///    strictly worse position than the keychain, not a trade.
/// 3. **Values still seed the redactor**, so a key cannot reach a trace or a stream even if a
///    tool echoes it.
public enum CredentialStore {

    /// The file. Deliberately not inside `Paths.root`'s working subdirectories, and never in
    /// `state.json` — that document is rewritten constantly and read by anything that wants to
    /// know what bots exist.
    public static var fileURL: URL {
        Paths.root.appendingPathComponent("credentials.json")
    }

    /// Shown in the About pane so the user knows exactly where their keys are.
    public static var location: String { fileURL.path }

    // MARK: Reading

    /// An in-memory copy, so a SwiftUI body that asks "is a key set?" does not hit the disk.
    ///
    /// This is the same defect that made the keychain unbearable: `Composer` holds the check in
    /// a computed property, so it re-ran on every keystroke. Against the keychain that was a
    /// password dialog; against a file it would be a read per character. Neither is acceptable,
    /// so the answer is cached and invalidated on write.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]?

        func read(_ load: () -> [String: String]) -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            if let values { return values }
            let loaded = load()
            values = loaded
            return loaded
        }

        func invalidate() {
            lock.lock(); values = nil; lock.unlock()
        }
    }

    public static func get(_ account: String) -> String? {
        let value = all()[account]
        return (value?.isEmpty == false) ? value : nil
    }

    /// Whether a credential exists, without returning it.
    ///
    /// Cheap and side-effect free by construction — there is no ACL to evaluate and no dialog
    /// to trigger, which was the entire point of the move.
    public static func has(_ account: String) -> Bool {
        get(account) != nil
    }

    /// Forget the cached copy, so the next read comes from disk.
    ///
    /// The cache is what keeps a SwiftUI body from reading the file on every keystroke, but it
    /// also means a key added by `scripts/set-key.sh` while the app is open would stay invisible
    /// until relaunch. Settings calls this when it appears, which is the moment someone would
    /// look to see whether their key took.
    public static func reload() { cache.invalidate() }

    public static func accounts() -> [String] {
        all().keys.sorted()
    }

    private static func all() -> [String: String] {
        cache.read {
            guard let data = FileManager.default.contents(atPath: fileURL.path),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return [:] }
            return parsed
        }
    }

    // MARK: Writing

    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        var values = all()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { values.removeValue(forKey: account) } else { values[account] = trimmed }
        return write(values)
    }

    public static func delete(_ account: String) {
        var values = all()
        values.removeValue(forKey: account)
        _ = write(values)
    }

    /// Write, then assert the permissions.
    ///
    /// Atomic via a temporary file and a rename, so a crash mid-write cannot leave a truncated
    /// file that reads as "no keys configured" — which would look to the user like their keys
    /// had silently vanished.
    private static func write(_ values: [String: String]) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: Paths.root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.root.path)

            let data = try JSONSerialization.data(withJSONObject: values,
                                                  options: [.prettyPrinted, .sortedKeys])
            let temporary = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: [.atomic])
            // Set the mode on the temporary file *before* it becomes the real one, so the
            // credentials are never world-readable for even an instant.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            cache.invalidate()
            return true
        } catch {
            cache.invalidate()
            return false
        }
    }

    // MARK: Health

    /// Whether the file is as locked down as it should be.
    ///
    /// Surfaced in Settings rather than assumed, because a mode that drifted — a restore from a
    /// backup, a careless `chmod`, a sync tool — is exactly the kind of thing nobody notices.
    public static func permissionsAreCorrect() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mode = attributes[.posixPermissions] as? NSNumber
        else { return true }   // absent is fine; there is nothing to protect yet
        return mode.int16Value & 0o077 == 0
    }

    /// Re-apply the intended permissions. Offered as a repair action, never done silently.
    @discardableResult
    public static func repairPermissions() -> Bool {
        (try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: fileURL.path)) != nil
    }
}
