import Foundation
import CryptoKit

/// The secret that makes the trace's hash chain mean something.
///
/// Until this existed the chain was a bare SHA-256 over each record, re-derived at verification
/// time with the same public algorithm and no key. That detects a truncated file and a careless
/// edit, and nothing else: anything able to rewrite `steps.jsonl` could rewrite every hash after
/// it and hand back a file that verifies perfectly. The docs called that tamper-evident. It was
/// not. An HMAC fixes it only if the key is somewhere the adversary — a bot running on this
/// machine with shell and file access — cannot reach.
///
/// **Where the key lives, and why there.** Inside `credentials.json`, under a reserved account
/// name, next to the API keys. That file is the *only* path under Application Support on
/// `Authority.alwaysDenied`, the safety floor's permanent read-deny list, so a bot cannot `cat`
/// it, cannot open it with the file tool, and cannot carry it out inside a `cp -r` of the
/// containing directory. A sibling file — `trace-key.json`, say — would be covered by none of
/// that, and a chain key the bot can read is a chain key the bot can re-sign with, which is
/// precisely the position we are trying to leave.
///
/// **Why not the keychain**, which is the obvious answer. `docs/decisions/0012` moved the API
/// keys off it because a grant is bound to a code signature and dies with the next build, so
/// every launch asked for the login password. The eval binary and the test bundle are signed
/// differently again. A keychain-backed chain key would therefore make `swift test` either
/// prompt for a password or fail, and a tamper-evidence scheme that cannot run in the test
/// suite is a scheme nobody will be able to prove still works in six months.
///
/// **What an attacker who can read this key can still do: everything.** With the key they can
/// edit any record, re-sign the whole chain, and leave a file that verifies clean. The HMAC does
/// not make that impossible; it raises the bar from "any process that can write the traces
/// directory" to "any process that can also read the credential file". That is deliberately the
/// same bar that protects the API keys — and if it falls, the keys are already gone, so a forged
/// trace is not the worst thing that happened. The bar it actually raises is against the bot
/// itself, which is the adversary the trace exists to keep honest.
public enum TraceChainKey {

    /// The reserved account name. Prefixed so it cannot collide with a provider ("gemini",
    /// "anthropic", "openai") and so a human opening `credentials.json` can see at a glance that
    /// this entry is not one of their API keys.
    public static let account = "trace.chain-hmac"

    /// The key for this machine, generated on first use.
    ///
    /// Returns `nil` when there is no key and one cannot be persisted. The caller then writes an
    /// unsigned chain, which verification reports honestly as "written before chain signing".
    /// The rejected alternative was to sign with an in-memory key that was never stored: it makes
    /// tamper detection work for the length of the process and then leaves every past run
    /// permanently unverifiable, which reads to a user exactly like tampering.
    public static func current() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        if let stored = decode(CredentialStore.get(account)) {
            cached = stored
            return stored
        }

        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard CredentialStore.set(fresh.base64EncodedString(), account: account) else { return nil }

        // Read back rather than trusting what we just generated. Two runs starting at the same
        // moment both find no key and both write one; the file holds exactly one of them, and
        // every trace on this machine has to be checkable with the same key or the loser's run
        // verifies as tampered.
        let settled = decode(CredentialStore.get(account)) ?? fresh
        cached = settled
        return settled
    }

    /// Base64 rather than raw bytes because `credentials.json` is a JSON document a person is
    /// expected to be able to open and read. A binary blob smuggled into a string field would
    /// break that promise for no gain.
    private static func decode(_ value: String?) -> Data? {
        guard let value, let data = Data(base64Encoded: value), data.count == 32 else { return nil }
        return data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Data?
}
