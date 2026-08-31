import Foundation
import Darwin

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
/// Four things carry the weight the keychain used to:
///
/// 1. **The file is owner-read-only and its directory is owner-only.** Enforced on every write,
///    not once at creation, because a mode is not a fact you establish — it is one you keep.
///    The file is *created* at 0600 rather than created and then narrowed; see `openTemporaryFile`.
/// 2. **Bots cannot read it.** The path is on the safety floor's permanent deny list, so a bot
///    with file access to its own workspace still cannot read the app's keys. Without this the
///    move would be indefensible: keys in a file inside a directory the agent can reach is a
///    strictly worse position than the keychain, not a trade.
/// 3. **Values still seed the redactor**, so a key cannot reach a trace or a stream even if a
///    tool echoes it. `StreamingRedactor.forRun` seeds from `accounts()`, so this covers every
///    account the user has stored and not a fixed list of provider names.
/// 4. **The file is excluded from backups.** The keychain was carried to Time Machine and to a
///    migrated account too, but encrypted and re-locked to the new machine. Cleartext keys
///    copied onto every backup disk is the one difference from the keychain that a user has no
///    way to see, so `isExcludedFromBackup` is set on every write.
public extension Notification.Name {
    /// Posted after the key file is changed *through this process* — a save or a removal in
    /// Settings. Views that render "is a key set?" listen for it, because they read the store
    /// during render and nothing else tells them to render again: the user's actual first
    /// experience was saving a key in Settings and returning to a main window still demanding
    /// one. Carries no payload, least of all a key.
    static let credentialsDidChange = Notification.Name("app.botharness.credentialsDidChange")
}

public enum CredentialStore {

    /// The real store. Everything public here forwards to it.
    ///
    /// It is an object over a directory rather than free functions over a constant path so the
    /// tests can point a second instance at a temporary directory. The cases most worth testing
    /// — a hand-edited document with a non-string value in it, a temporary file left by a killed
    /// save, two writers racing — are precisely the ones that would destroy the user's real keys
    /// if the test ran against the real path.
    static let shared = Store(directory: Paths.root)

    /// The file. Deliberately not inside `Paths.root`'s working subdirectories, and never in
    /// `state.json` — that document is rewritten constantly and read by anything that wants to
    /// know what bots exist.
    public static var fileURL: URL { shared.fileURL }

    /// Shown in the About pane so the user knows exactly where their keys are.
    public static var location: String { shared.fileURL.path }

    // MARK: Reading

    public static func get(_ account: String) -> String? { shared.get(account) }

    /// Whether a credential exists, without returning it.
    ///
    /// Cheap and side-effect free by construction — there is no ACL to evaluate and no dialog
    /// to trigger, which was the entire point of the move.
    public static func has(_ account: String) -> Bool { shared.get(account) != nil }

    public static func accounts() -> [String] { shared.accounts() }

    /// Forget the cached copy, so the next read comes from disk.
    ///
    /// Kept, but no longer load-bearing: the cache now carries the file's identity and reloads
    /// itself when the file on disk is not the one it read. A key added by `scripts/set-key.sh`
    /// while the app is open becomes visible on the next read whether or not anybody calls this.
    public static func reload() { shared.reload() }

    // MARK: Writing

    @discardableResult
    public static func set(_ value: String, account: String) -> Bool {
        shared.set(value, account: account)
    }

    /// Reports failure the way `set` does. It used to return nothing and discard the write's
    /// result, so a delete that could not be written told the user the key was gone while it was
    /// still on disk, waiting to reappear at the next launch.
    @discardableResult
    public static func delete(_ account: String) -> Bool { shared.delete(account) }

    /// Why the last write refused, in a sentence fit to show someone. `nil` after a write that
    /// worked. A `false` return says a save did not happen; this says what to do about it.
    public static var lastWriteFailure: String? { shared.lastWriteFailure }

    // MARK: Health

    /// Whether the store is as locked down as it should be.
    ///
    /// Surfaced in Settings rather than assumed, because a mode that drifted — a restore from a
    /// backup, a careless `chmod`, a sync tool — is exactly the kind of thing nobody notices.
    public static func permissionsAreCorrect() -> Bool { shared.problems().isEmpty }

    /// The same check, with the reasons. One line per problem, already phrased for a person.
    public static func permissionProblems() -> [String] { shared.problems() }

    /// Re-apply the intended permissions. Offered as a repair action, never done silently.
    @discardableResult
    public static func repairPermissions() -> Bool { shared.repairPermissions() }

    // MARK: Errors

    public enum Failure: Error, CustomStringConvertible {
        /// The file exists and its bytes could not be read at all.
        case unreadable(String)
        /// The file exists and is not a JSON object. Writing would replace whatever the user
        /// actually has in there, so we do not write.
        case notAnObject(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .unreadable(let detail):  return "The key file could not be read: \(detail)"
            case .notAnObject(let path):
                return "\(path) is not a JSON object, so it was left alone rather than "
                     + "overwritten. Fix or move the file, then save again."
            case .writeFailed(let detail): return "The key file could not be written: \(detail)"
            }
        }
    }
}

extension CredentialStore {

    /// One credentials file and the cache in front of it.
    final class Store: @unchecked Sendable {

        let directory: URL
        let fileURL: URL

        /// The save in progress. A sibling of the real file on purpose: `rename(2)` is only
        /// atomic within one filesystem, and the system temporary directory need not be on the
        /// same one as Application Support.
        var temporaryURL: URL { fileURL.appendingPathExtension("tmp") }

        init(directory: URL) {
            self.directory = directory
            self.fileURL = directory.appendingPathComponent("credentials.json")
        }

        // MARK: Cache

        /// An in-memory copy, so a SwiftUI body that asks "is a key set?" does not hit the disk.
        ///
        /// This is the same defect that made the keychain unbearable: `Composer` holds the check
        /// in a computed property, so it re-ran on every keystroke. Against the keychain that was
        /// a password dialog; against a file it would be a read per character.
        ///
        /// The cache is stamped with the file's identity and reloads when that changes, so it
        /// cannot go stale behind a key written by `scripts/set-key.sh` in another terminal. It
        /// is never the basis of a write; see `mutate`.
        private let cacheLock = NSLock()
        private var cached: [String: String]?
        private var cachedStamp: Stamp?
        private var writeFailure: String?

        /// What the cache last read, cheap enough to check on every keystroke. Inode as well as
        /// size and time because every write lands a newly created file, so the inode alone
        /// catches a replacement, and time alone would not catch two writes inside one clock tick.
        private struct Stamp: Equatable {
            let inode: UInt64
            let size: Int64
            let seconds: Int
            let nanoseconds: Int
        }

        private func stamp() -> Stamp? {
            var info = stat()
            guard stat(fileURL.path, &info) == 0 else { return nil }   // absent: nothing to stamp
            return Stamp(inode: info.st_ino, size: Int64(info.st_size),
                         seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        }

        func reload() {
            cacheLock.lock(); cached = nil; cachedStamp = nil; cacheLock.unlock()
        }

        var lastWriteFailure: String? {
            cacheLock.lock(); defer { cacheLock.unlock() }
            return writeFailure
        }

        // MARK: Reading

        func get(_ account: String) -> String? {
            let value = values()[account]
            return (value?.isEmpty == false) ? value : nil
        }

        func accounts() -> [String] { values().keys.sorted() }

        private func values() -> [String: String] {
            cacheLock.lock(); defer { cacheLock.unlock() }
            // Stamp first, read second. The other order can hand back content newer than the
            // stamp it is filed under, which would then look current forever; this order can only
            // reload once more than it needed to.
            let current = stamp()
            if let cached, cachedStamp == current { return cached }
            let loaded = (try? strings(in: readDocument())) ?? [:]
            cached = loaded
            cachedStamp = current
            return loaded
        }

        /// The file as JSON. Reads without the cross-process lock on purpose: every write lands
        /// by `rename(2)`, so a reader sees either the whole old file or the whole new one and
        /// there is no torn state to lock against.
        ///
        /// Throws only when the file exists and cannot be understood. An absent file is an empty
        /// document, not an error — that is a machine that has never had a key set.
        private func readDocument() throws -> [String: Any] {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch { throw Failure.unreadable("\(error.localizedDescription)") }

            // A zero-byte file holds no keys, so treating it as empty and writing over it cannot
            // lose anything. Anything else that fails to parse might, which is why only this case
            // is forgiven.
            guard !data.isEmpty else { return [:] }

            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let document = object as? [String: Any]
            else { throw Failure.notAnObject(fileURL.path) }
            return document
        }

        /// The credentials in a document.
        ///
        /// Tolerant by construction: the file is meant to be human-editable, and one hand-typed
        /// `"budget": 5` used to make the entire store decode as empty — every key invisible in
        /// Settings, and destroyed by the next save, which would have written only the key being
        /// saved. Entries that are not strings are not credentials; they are ignored here and
        /// carried through untouched on write.
        private func strings(in document: [String: Any]) -> [String: String] {
            document.compactMapValues { $0 as? String }
        }

        // MARK: Writing

        @discardableResult
        func set(_ value: String, account: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return mutate { values in
                if trimmed.isEmpty { values.removeValue(forKey: account) }
                else { values[account] = trimmed }
            }
        }

        @discardableResult
        func delete(_ account: String) -> Bool {
            mutate { $0.removeValue(forKey: account) }
        }

        /// Read the file, apply one change, write it back — all inside a lock no other process
        /// can hold at the same time.
        ///
        /// The read is from disk and never from the cache. Merging into the cache is what let the
        /// app destroy a key: open the app, run `scripts/set-key.sh openrouter` in a terminal,
        /// save a different key in Settings, and the openrouter key was gone, because the app
        /// wrote back the map it had loaded at launch.
        private func mutate(_ change: (inout [String: String]) -> Void) -> Bool {
            do {
                try prepareDirectory()
                let (document, freshStamp) = try withExclusiveLock { () -> ([String: Any], Stamp?) in
                    var document = try readDocument()
                    let before = strings(in: document)
                    var after = before
                    change(&after)

                    for key in before.keys where after[key] == nil { document.removeValue(forKey: key) }
                    for (key, value) in after { document[key] = value }

                    try writeAtomically(document)
                    // Stamped inside the lock: sampling after releasing it would file our content
                    // under a stamp another writer had already moved past, and the cache would
                    // then never notice it was stale.
                    return (document, stamp())
                }
                cacheLock.lock()
                cached = strings(in: document)
                cachedStamp = freshStamp
                writeFailure = nil
                cacheLock.unlock()
                // After the cache reflects the write, never inside the lock. Listeners will
                // read back through this store on receipt, and a post made while the lock is
                // held invites them to deadlock against it.
                NotificationCenter.default.post(name: .credentialsDidChange, object: nil)
                return true
            } catch {
                cacheLock.lock()
                cached = nil
                cachedStamp = nil
                writeFailure = "\(error)"
                cacheLock.unlock()
                return false
            }
        }

        private func prepareDirectory() throws {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        /// Create the file a save is written into, owner-only from the instant it exists.
        ///
        /// Internal rather than private so a test can stat it. The mode of this file *at the
        /// moment of creation* is the whole point, and a test that raced a write to observe it
        /// would be a flaky test of a security property, which is worse than none.
        ///
        /// The predecessor was `data.write(to: temporary, options: [.atomic])` followed by a
        /// `chmod` — which creates the file at the process umask (0644 in a normal login session)
        /// and narrows it afterwards. That is a real window in which every key is world-readable,
        /// and if the process dies inside it the 0644 copy stays on disk forever.
        func openTemporaryFile() throws -> Int32 {
            // A temporary left by a killed save is a plaintext copy of every key. Remove it
            // before O_EXCL trips over it — and O_EXCL rather than a plain O_CREAT so we can
            // never write into a file some other process is holding open.
            try? FileManager.default.removeItem(at: temporaryURL)

            let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else {
                throw Failure.writeFailed("\(temporaryURL.path): \(String(cString: strerror(errno)))")
            }
            // The umask can only narrow the mode above, never widen it, so this is not a
            // correctness fix — it is so the mode does not depend on the umask of whoever
            // launched the app. A 0400 file would pass every check here and then confuse the
            // next person who runs `ls -l`.
            fchmod(descriptor, 0o600)
            return descriptor
        }

        private func writeAtomically(_ document: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: document,
                                                  options: [.prettyPrinted, .sortedKeys])
            let descriptor = try openTemporaryFile()
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            do {
                try handle.write(contentsOf: data)
                // fsync before the rename: without it a power loss can land the new name over
                // an empty file, which reads back as "no keys configured" — the exact failure
                // the atomic write exists to prevent.
                try handle.synchronize()
            } catch {
                close(descriptor)
                try? FileManager.default.removeItem(at: temporaryURL)
                throw Failure.writeFailed("\(error.localizedDescription)")
            }
            close(descriptor)

            // rename(2) rather than `FileManager.replaceItemAt`. Measured on this machine:
            // replaceItemAt keeps the *original* file's mode, so replacing a file that had
            // drifted to 0644 with our 0600 temporary produced a 0644 file again. rename lands
            // the descriptor we created at 0600 and nothing copies attributes back over it.
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temporaryURL)
                throw Failure.writeFailed("\(fileURL.path): \(reason)")
            }
            excludeFromBackup(fileURL)
        }

        /// Keep the cleartext keys off Time Machine and out of Migration Assistant.
        ///
        /// Only the file, deliberately not the directory: `state.json`, the traces and the
        /// screenshots live beside it, and those are exactly what someone would want back after
        /// a disk failure. Excluding their folder to protect one file in it would be a quiet way
        /// to lose everything else.
        ///
        /// Failure is ignored on purpose. The keys are already stored by this point; refusing a
        /// save because a backup attribute would not set would be a worse outcome than a key
        /// that gets backed up.
        private func excludeFromBackup(_ url: URL) {
            var url = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? url.setResourceValues(resourceValues)
        }

        /// Serialise read-modify-write against every other writer, in this process or another.
        ///
        /// `flock(2)` on the *directory*, not on a lock file of its own: the store file is
        /// replaced by rename on every write, so a lock on its descriptor guards an inode the
        /// next writer will never open, and a sidecar lock file would be one more thing in
        /// Application Support that the bots' deny list does not know about. Verified on this
        /// machine that a second process is excluded by a directory lock.
        /// `scripts/set-key.sh` takes the same lock on the same directory.
        private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
            let descriptor = open(directory.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw Failure.writeFailed("\(directory.path): \(String(cString: strerror(errno)))")
            }
            defer { close(descriptor) }   // closing releases the lock even if `body` throws

            // Polled rather than a blocking LOCK_EX. Settings saves on the main thread, and a
            // blocking wait would freeze the window for as long as some other process held the
            // lock. Five seconds is far longer than any write here takes, so reaching the end of
            // it means something is wrong and saying so beats hanging.
            let deadline = Date().addingTimeInterval(5)
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else {
                    throw Failure.writeFailed("another process is holding the key file")
                }
                usleep(20_000)
            }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }

        // MARK: Health

        /// Everything wrong with the store's permissions right now, phrased for a person.
        func problems() -> [String] {
            let manager = FileManager.default
            var found: [String] = []

            let fileExists = manager.fileExists(atPath: fileURL.path)
            let strayTemporary = manager.fileExists(atPath: temporaryURL.path)

            if fileExists, let mode = mode(of: fileURL.path), mode & 0o077 != 0 {
                found.append("credentials.json is mode \(octal(mode)) — other accounts on this "
                           + "Mac can read your keys.")
            }
            if strayTemporary {
                // Reported whatever its mode is: it is a second copy of every key that nothing
                // owns, nothing rewrites, and nobody would think to look for.
                found.append("credentials.json.tmp was left by an interrupted save and holds a "
                           + "copy of every key.")
            }
            // The folder is only worth complaining about once there is something in it to
            // protect. It is created at the default 0755, so checking unconditionally would show
            // a repair banner to someone who has never saved a key — and a banner that appears
            // when nothing is wrong is one people learn to dismiss.
            if fileExists || strayTemporary, let mode = mode(of: directory.path), mode & 0o077 != 0 {
                found.append("The Bot-Harness folder is mode \(octal(mode)) — it should be "
                           + "reachable only by you.")
            }
            return found
        }

        @discardableResult
        func repairPermissions() -> Bool {
            let manager = FileManager.default
            var repaired = true

            // Deleted, not chmod-ed. A stray temporary is either a duplicate of keys that are
            // already in credentials.json, or the tail of a save that failed and was reported as
            // failed. Keeping a plaintext copy nobody manages is the worse of the two risks, so
            // this deletes it and says so here rather than silently.
            if manager.fileExists(atPath: temporaryURL.path) {
                repaired = ((try? manager.removeItem(at: temporaryURL)) != nil) && repaired
            }
            if manager.fileExists(atPath: fileURL.path) {
                repaired = ((try? manager.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: fileURL.path)) != nil) && repaired
                excludeFromBackup(fileURL)
            }
            if manager.fileExists(atPath: directory.path) {
                repaired = ((try? manager.setAttributes([.posixPermissions: 0o700],
                                                        ofItemAtPath: directory.path)) != nil) && repaired
            }
            return repaired
        }

        private func mode(of path: String) -> Int16? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let number = attributes[.posixPermissions] as? NSNumber
            else { return nil }
            return number.int16Value
        }

        private func octal(_ mode: Int16) -> String { String(format: "%03o", Int(mode) & 0o777) }
    }
}
