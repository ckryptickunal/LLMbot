import XCTest
@testable import BotHarnessCore

/// The ledger exists to stop a stopped-and-restarted run from sending the same email twice. These
/// pin the two ways that goes wrong: recording too little (a duplicate effect) and recording too
/// much (ordinary commands refused as "already done").
final class EffectLedgerTests: XCTestCase {

    // MARK: - Identity

    func testTheSameEffectHasTheSameKeyRegardlessOfArgumentOrder() {
        let a = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z", "body": "hi"])
        let b = EffectLedger.key(tool: "mail.send", arguments: ["body": "hi", "to": "x@y.z"])
        XCTAssertEqual(a, b, "key order in the model's JSON must not make one action look like two")
    }

    func testDifferentContentIsADifferentEffect() {
        let a = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z", "body": "hi"])
        let b = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z", "body": "hello"])
        XCTAssertNotEqual(a, b)
    }

    /// The exact pair the old encoding collided on. `{k:v,k:v}` by concatenation, with nothing
    /// escaped, let one value's comma and colon reproduce the shape of a second key: a note whose
    /// body happens to mention an address suppressed the mail actually addressed to it.
    func testAValueContainingSeparatorsIsNotMistakenForMoreKeys() {
        let note = EffectLedger.key(tool: "mail.send",
                                    arguments: ["body": "hi,to:bob@example.com"])
        let mail = EffectLedger.key(tool: "mail.send",
                                    arguments: ["to": "bob@example.com", "body": "hi"])
        XCTAssertNotEqual(note, mail,
                          "a comma inside a value must not read as the boundary between two keys")
    }

    func testAScalarsTypeIsPartOfItsIdentity() {
        // A number, a bool and their string spellings all rendered identically before, so
        // `{"dry_run": true}` and `{"dry_run": "true"}` were one effect.
        let keys = [
            EffectLedger.key(tool: "deploy", arguments: ["dry_run": true]),
            EffectLedger.key(tool: "deploy", arguments: ["dry_run": "true"]),
            EffectLedger.key(tool: "deploy", arguments: ["dry_run": 1]),
            EffectLedger.key(tool: "deploy", arguments: ["dry_run": "1"]),
            EffectLedger.key(tool: "deploy", arguments: ["dry_run": NSNull()]),
        ]
        XCTAssertEqual(Set(keys).count, keys.count, "distinct values shared a key")
    }

    func testAListIsNotTheSameAsItsFlattenedText() {
        let list = EffectLedger.key(tool: "mail.send", arguments: ["to": ["a@x.z", "b@x.z"]])
        let text = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@x.z,b@x.z"])
        XCTAssertNotEqual(list, text)
    }

    func testTheToolIsPartOfTheIdentity() {
        let a = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z"])
        let b = EffectLedger.key(tool: "mail.draft", arguments: ["to": "x@y.z"])
        XCTAssertNotEqual(a, b)
    }

    // MARK: - What counts as an effect at all

    func testReadOnlyShellCommandsAreNotTreatedAsEffects() {
        // The first version of this ledgered every shell.exec, which meant running `ls` in two
        // consecutive runs got the second one refused as already completed.
        for command in ["ls", "ls -la ~/Desktop", "cat README.md", "grep -r foo .",
                        "echo hello", "pwd", "which node"] {
            XCTAssertFalse(AgentLoop.commandChangesSomething(command), "wrongly an effect: \(command)")
        }
    }

    func testMutatingShellCommandsAreEffects() {
        for command in ["rm -rf build", "git push origin main", "npm install",
                        "echo x > out.txt", "mv a b", "curl -X POST https://x.example -d @f"] {
            XCTAssertTrue(AgentLoop.commandChangesSomething(command), "missed effect: \(command)")
        }
    }

    func testAnUnreadableCommandIsTreatedAsAnEffect() {
        // Erring towards "yes" costs one advisory message; erring towards "no" costs a duplicated
        // side effect.
        XCTAssertTrue(AgentLoop.commandChangesSomething("rm -rf \"$UNCLOSED"))
    }

    // MARK: - Recording

    func testAnInterruptedEffectIsRememberedAsUncertainNotFailed() async throws {
        let root = Self.temporaryRoot()
        let ledger = EffectLedger(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"])
        await ledger.beginning(key, tool: "mail.send", summary: "mail to a@b.c")

        // Nothing recorded a result — the crash case. It must read as "we do not know",
        // because recording it as failed would let a retry send the message twice.
        let entry = await ledger.existing(key)
        XCTAssertEqual(entry?.outcome, .uncertain)
        let advice = await ledger.advisory(for: try XCTUnwrap(entry))
        XCTAssertTrue(advice.contains("never confirmed"), advice)
    }

    func testACompletedEffectIsNotRepeated() async {
        let root = Self.temporaryRoot()
        let ledger = EffectLedger(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"])
        await ledger.beginning(key, tool: "mail.send", summary: "mail to a@b.c")
        await ledger.finished(key, outcome: .done, note: "sent")

        // A fresh ledger over the same file: this is the across-runs case the whole type exists
        // for, so reading it back from disk rather than memory is the point of the test.
        let reopened = EffectLedger(root: root)
        let entry = await reopened.existing(key)
        XCTAssertEqual(entry?.outcome, .done)
    }

    // MARK: - Expiry

    /// The failure that makes people switch a safety feature off: one `npm install` a year ago
    /// and every later run is answered with "already completed on 31 Aug at 16:07".
    func testACompletedEffectStopsSuppressingOnceTheRetryWindowHasPassed() async throws {
        let key = EffectLedger.key(tool: "shell.exec", arguments: ["command": "npm install"])
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let old = Date().addingTimeInterval(-3 * 60 * 60)
        try Self.write([Self.line(key: key, tool: "shell.exec", summary: "npm install",
                                  outcome: "done", at: old, note: "completed")], to: root)

        let stale = await EffectLedger(root: root).existing(key)
        XCTAssertNil(stale, "a completed install three hours ago must not refuse today's run")

        // The control: inside the window it still suppresses, which is the retry-after-a-stop
        // case the ledger is actually for.
        let fresh = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let recent = Date().addingTimeInterval(-60)
        try Self.write([Self.line(key: key, tool: "shell.exec", summary: "npm install",
                                  outcome: "done", at: recent, note: "completed")], to: fresh)
        let ledger = EffectLedger(root: fresh)
        let recorded = await ledger.existing(key)
        let entry = try XCTUnwrap(recorded, "a repeat one minute later is a retry")

        // The advisory has to say when repeats resume, or the model's only route past it is to
        // disguise the action — which is what the old wording invited.
        let resumes = recent.addingTimeInterval(EffectLedger.completedSuppressionWindow)
        let advice = await ledger.advisory(for: entry)
        XCTAssertTrue(advice.contains(Self.humanStamp(resumes)), advice)
    }

    /// The other half of the trade: an unconfirmed send still warns the next morning, because
    /// "this may already have gone out" does not stop being true in fifteen minutes.
    func testAnUnconfirmedEffectWarnsForLongerThanACompletedOneSuppresses() async throws {
        let key = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"])

        let overnight = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: overnight) }
        try Self.write([Self.line(key: key, tool: "mail.send", summary: "mail to a@b.c",
                                  outcome: "uncertain",
                                  at: Date().addingTimeInterval(-9 * 60 * 60),
                                  note: "timed out")], to: overnight)
        let warned = await EffectLedger(root: overnight).existing(key)
        XCTAssertEqual(warned?.outcome, .uncertain, "nine hours is well inside the warning window")

        let ancient = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: ancient) }
        try Self.write([Self.line(key: key, tool: "mail.send", summary: "mail to a@b.c",
                                  outcome: "uncertain",
                                  at: Date().addingTimeInterval(-25 * 60 * 60),
                                  note: "timed out")], to: ancient)
        let expired = await EffectLedger(root: ancient).existing(key)
        XCTAssertNil(expired,
                     "a warning that never expires is a refusal wearing a warning's clothes")
    }

    func testAStampFromTheFutureDoesNotFreezeTheLedger() async throws {
        // A clock nudged forward — a restored backup, a machine whose date was briefly wrong —
        // must not buy an action a year of refusals while the calendar catches up.
        let key = EffectLedger.key(tool: "shell.exec", arguments: ["command": "npm install"])
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write([Self.line(key: key, tool: "shell.exec", summary: "npm install",
                                  outcome: "done",
                                  at: Date().addingTimeInterval(365 * 24 * 60 * 60),
                                  note: "completed")], to: root)
        let entry = await EffectLedger(root: root).existing(key)
        XCTAssertNil(entry)
    }

    // MARK: - Secrets

    func testASecretInAnArgumentDoesNotReachTheFile() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two kinds of secret, because two redactors have to run: one with a shape a pattern
        // knows, one with no shape at all, which only a value-seeded redactor can catch.
        let shaped = "sk-ant-api03-0000000000000000000000000000000000000000"
        let shapeless = "correct-horse-battery-staple"
        let command = "curl -H 'Authorization: Bearer \(shaped)' https://x.example/\(shapeless)"

        let ledger = EffectLedger(root: root, extraSecrets: [shapeless])
        let key = EffectLedger.key(tool: "shell.exec", arguments: ["command": command])
        await ledger.beginning(key, tool: "shell.exec", summary: "shell.exec \(command)")
        await ledger.finished(key, outcome: .failed, note: "exit 6 running \(command)")

        let written = try String(contentsOf: root.appendingPathComponent("effects.jsonl"),
                                 encoding: .utf8)
        XCTAssertFalse(written.contains(shaped), "an API key reached effects.jsonl verbatim")
        XCTAssertFalse(written.contains(shapeless), "a stored credential reached effects.jsonl")
        XCTAssertTrue(written.contains("«redacted»"), written)

        // Also not held in memory, because the summary and the note are quoted back to the model
        // in the advisory and from there into the transcript.
        let recorded = await ledger.existing(key)
        let entry = try XCTUnwrap(recorded)
        XCTAssertFalse(entry.summary.contains(shaped))
        XCTAssertFalse(entry.note.contains(shapeless))
    }

    // MARK: - Disk

    func testTheLedgerFileAndItsDirectoryAreOwnerOnly() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default

        // Start from a file somebody else created readable — a restore, an older build, a
        // looser umask. Asserting the mode only at creation would leave this one wide open.
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        manager.createFile(atPath: root.appendingPathComponent("effects.jsonl").path,
                           contents: Data(), attributes: [.posixPermissions: 0o644])

        let ledger = EffectLedger(root: root)
        await ledger.beginning(EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"]),
                               tool: "mail.send", summary: "mail to a@b.c")

        XCTAssertEqual(try Self.mode(of: root.appendingPathComponent("effects.jsonl")), 0o600)
        XCTAssertEqual(try Self.mode(of: root), 0o700)
    }

    func testACorruptLineDoesNotLoseTheRest() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"])
        let last = EffectLedger.key(tool: "mail.send", arguments: ["to": "z@b.c"])
        let now = Date()

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var data = Data()
        data.append(Data((Self.line(key: first, tool: "mail.send", summary: "mail to a@b.c",
                                    outcome: "uncertain", at: now, note: "timed out") + "\n").utf8))
        data.append(Data("{\"key\": truncated jso\n".utf8))
        // A record cut off mid-append, ending inside a multi-byte character. Decoding the whole
        // file as UTF-8 first returns nil for *every* line when this is present, which is how one
        // torn write used to lose the unconfirmed records either side of it.
        data.append(contentsOf: [0x7B, 0x22, 0x73, 0x22, 0x3A, 0x22, 0xE2, 0x82, 0x0A])
        data.append(Data((Self.line(key: last, tool: "mail.send", summary: "mail to z@b.c",
                                    outcome: "uncertain", at: now, note: "timed out") + "\n").utf8))
        try data.write(to: root.appendingPathComponent("effects.jsonl"))

        let ledger = EffectLedger(root: root)
        let before = await ledger.existing(first)
        let after = await ledger.existing(last)
        XCTAssertEqual(before?.outcome, .uncertain, "the record before the torn line was lost")
        XCTAssertEqual(after?.outcome, .uncertain, "the record after the torn line was lost")
    }

    // MARK: - Helpers

    private static func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("botharness-ledger-\(UUID().uuidString)")
    }

    /// A ledger line written by hand, so the tests pin the on-disk format rather than whatever
    /// the encoder happens to emit — the file has to stay legible without this app.
    private static func line(key: String, tool: String, summary: String,
                             outcome: String, at: Date, note: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: at)
        return #"{"at":"\#(stamp)","key":"\#(key)","note":"\#(note)","outcome":"\#(outcome)","#
             + #""summary":"\#(summary)","tool":"\#(tool)"}"#
    }

    private static func write(_ lines: [String], to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: root.appendingPathComponent("effects.jsonl"), atomically: true,
                   encoding: .utf8)
    }

    private static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func humanStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM 'at' HH:mm"
        return formatter.string(from: date)
    }
}
