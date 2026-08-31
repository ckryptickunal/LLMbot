import XCTest
import CryptoKit
@testable import BotHarnessCore

/// The trace is the product's evidence. A log nobody can check is a log nobody should trust,
/// so these tests assert that tampering is actually detected rather than merely discouraged.
///
/// Every writer here is handed an explicit chain key. That is not only isolation: it is what
/// lets the suite forge a trace the way an attacker would — with the app's own encoder, its own
/// canonical form, and full knowledge of the algorithm — and still be caught.
final class TraceChainTests: XCTestCase {

    /// A fixed key so the tests never touch the machine's real one, and so a forged file can be
    /// checked against the same key that wrote the original.
    private static let key = Data(repeating: 0x5a, count: 32)

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("botharness-tests-\(UUID().uuidString)")
    }

    private func makeRun(root: URL? = nil, secrets: [String] = []) async -> TraceWriter {
        TraceWriter(root: root ?? makeRoot(), botName: "test",
                    extraSecrets: secrets, chainKey: Self.key)
    }

    // MARK: - The chain holds

    func testChainIsIntactForAnUntouchedTrace() async throws {
        let writer = await makeRun()
        for i in 1...5 {
            await writer.record(.init(kind: .toolProposed, summary: "step \(i)"))
        }
        let steps = await writer.directory.appendingPathComponent("steps.jsonl")

        let report = TraceWriter.inspectChain(at: steps, chainKey: Self.key)
        guard case .intact(let records) = report.status else {
            return XCTFail("a freshly written trace should verify")
        }
        XCTAssertEqual(records, 5)
        XCTAssertEqual(report.signing, .signed, "a trace written today must carry signatures")
    }

    func testEditingARecordBreaksTheChain() async throws {
        let writer = await makeRun()
        await writer.record(.init(kind: .toolProposed, summary: "delete one file"))
        await writer.record(.init(kind: .toolProposed, summary: "delete another file"))
        await writer.record(.init(kind: .completion, summary: "done"))

        let steps = await writer.directory.appendingPathComponent("steps.jsonl")
        var text = try String(contentsOf: steps, encoding: .utf8)

        // The scenario that matters: someone quietly rewrites what an action claimed to do.
        text = text.replacingOccurrences(of: "delete another file", with: "read another file")
        try text.write(to: steps, atomically: true, encoding: .utf8)

        guard case .brokenAt(let line, _) = TraceWriter.verifyChain(at: steps, chainKey: Self.key) else {
            return XCTFail("editing a record must break the chain")
        }
        XCTAssertEqual(line, 2, "the break should be reported at the edited record")
    }

    func testDeletingARecordBreaksTheChain() async throws {
        let writer = await makeRun()
        for i in 1...4 { await writer.record(.init(kind: .toolProposed, summary: "step \(i)")) }

        let steps = await writer.directory.appendingPathComponent("steps.jsonl")
        var lines = try String(contentsOf: steps, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.remove(at: 1)  // excise the second step entirely
        try lines.joined(separator: "\n").write(to: steps, atomically: true, encoding: .utf8)

        guard case .brokenAt = TraceWriter.verifyChain(at: steps, chainKey: Self.key) else {
            return XCTFail("removing a record must break the chain")
        }
    }

    // MARK: - The signature is what makes the chain evidence

    /// The defect this closes. An unkeyed chain proves nothing against anything that can write
    /// the file, because re-deriving the hashes needs no secret. So the attacker here does what
    /// the old scheme allowed: edit a record, then re-link the whole file with the app's own
    /// canonical encoder and a plain SHA-256.
    ///
    /// The test asserts both halves, and the second is the one that gives it teeth: the forged
    /// file *is* self-consistent under the old rule. If anyone reverts the chain to a bare
    /// digest, the first assertion fails and the second still passes.
    func testRechainingAnEditedRecordIsCaughtByTheSignature() async throws {
        let writer = await makeRun()
        await writer.record(.init(kind: .toolProposed, summary: "rm -rf ~/Documents/invoices"))
        await writer.record(.init(kind: .completion, summary: "succeeded"))
        await writer.record(.init(kind: .runFinished, summary: "succeeded: tidied up"))
        let steps = await writer.directory.appendingPathComponent("steps.jsonl")

        try rechainWithBareSHA256(steps, strippingAlgorithm: false) { events in
            events[0].summary = "ls ~/Documents/invoices"
        }

        XCTAssertTrue(try bareSHA256ChainIsSelfConsistent(steps),
                      "the forgery must be one an unkeyed verifier would accept, or this test "
                      + "proves nothing about the signature")

        guard case .brokenAt = TraceWriter.verifyChain(at: steps, chainKey: Self.key) else {
            return XCTFail("a re-chained edit must be caught by the keyed link")
        }
    }

    /// Traces on disk from before the chain was keyed must not suddenly read as forged. Somebody
    /// opening an old run should be told it predates signing, not accused.
    func testATraceWrittenBeforeSigningIsReportedAsLegacyNotTampered() async throws {
        let writer = await makeRun()
        for i in 1...3 { await writer.record(.init(kind: .toolProposed, summary: "step \(i)")) }
        let steps = await writer.directory.appendingPathComponent("steps.jsonl")

        // Strip the algorithm marker and re-link with the old public digest: byte for byte, a
        // trace the previous writer would have produced.
        try rechainWithBareSHA256(steps, strippingAlgorithm: true) { _ in }

        let report = TraceWriter.inspectChain(at: steps, chainKey: Self.key)
        guard case .intact(let records) = report.status else {
            return XCTFail("an old trace still verifies; it is not evidence of tampering")
        }
        XCTAssertEqual(records, 3)
        XCTAssertEqual(report.signing, .writtenBeforeSigning,
                       "and it must be reported as unsigned rather than given a clean bill")
    }

    /// Half-signed is not legacy. Appending records nobody could sign is the cheapest forgery
    /// available — the genuine lines are left untouched and two unsigned ones are chained onto
    /// the end — so a file that changes scheme part-way down has to read as a break.
    func testUnsignedRecordsAppendedToASignedTraceAreABreak() async throws {
        let writer = await makeRun()
        for i in 1...3 { await writer.record(.init(kind: .toolProposed, summary: "step \(i)")) }
        let steps = await writer.directory.appendingPathComponent("steps.jsonl")

        var text = try String(contentsOf: steps, encoding: .utf8)
        text += try forgeUnsignedTail(after: text, count: 2)
        try text.write(to: steps, atomically: true, encoding: .utf8)

        guard case .brokenAt(let line, _) = TraceWriter.verifyChain(at: steps, chainKey: Self.key) else {
            return XCTFail("unsigned records appended to a signed trace must break it")
        }
        XCTAssertEqual(line, 4, "the break is the first record that stopped being signed")
    }

    /// The one move the keyed chain cannot see on its own: rewrite every record with the public
    /// algorithm so the whole file claims to predate signing. The manifest's seal is what
    /// catches it, and only the reader sees both facts at once.
    func testDowngradingASignedTraceToTheUnkeyedSchemeIsVisible() async throws {
        let root = makeRoot()
        let writer = await makeRun(root: root)
        await writer.record(.init(kind: .toolProposed, summary: "transfer the balance"))
        await writer.record(.init(kind: .completion, summary: "succeeded"))
        await writer.finish(.init(botID: UUID(), botName: "test", conversationID: UUID(),
                                  goal: "move money", brain: "gemini", environment: "mac",
                                  startedAt: Date(), closingNote: "done"))
        let steps = await writer.directory.appendingPathComponent("steps.jsonl")

        try rechainWithBareSHA256(steps, strippingAlgorithm: true) { events in
            events[0].summary = "check the balance"
        }

        // Read back through the reader, which is the only place the manifest and the steps are
        // compared with each other.
        let runs = TraceReader(root: root, chainKey: Self.key).runs()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.manifestSeal, .sealed, "the seal cannot be forged without the key")
        XCTAssertEqual(run.signing, .writtenBeforeSigning)
        guard case .brokenAt = run.chain else {
            return XCTFail("a sealed run whose steps claim to predate signing has been rewritten")
        }
    }

    // MARK: - Redaction

    func testSecretsAreRedactedBeforeReachingDisk() async throws {
        let writer = await makeRun()
        await writer.record({
            var e = TraceWriter.Event(kind: .toolProposed, summary: "call the API")
            e.arguments = #"{"Authorization":"sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"}"#
            e.output = "key=AIzaSyC0123456789abcdefghijklmnopqrstuvw"
            return e
        }())

        let steps = await writer.directory.appendingPathComponent("steps.jsonl")
        let text = try String(contentsOf: steps, encoding: .utf8)
        XCTAssertFalse(text.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(text.contains("AIzaSyC0123456789abcdefghijklmnopqrstuvw"))
    }

    /// The gap the regex cannot close. A database URL carrying a password has no key shape at
    /// all, so the only thing that can catch it is knowing the value — which is what seeding the
    /// writer from the credential store buys.
    func testAValueShapedSecretIsScrubbedFromAnAppendedRecord() async throws {
        let secret = "postgres://app:tr0ub4dor-and-three@db.internal:5432/prod"
        XCTAssertEqual(Redactor.redact(secret), secret,
                       "if the pattern redactor already catches this, the test is not testing "
                       + "value-based redaction")

        let writer = await makeRun(secrets: [secret])
        await writer.record({
            var e = TraceWriter.Event(kind: .completion, summary: "connected")
            e.output = "psql: connecting to \(secret) … ok"
            return e
        }())

        let steps = await writer.directory.appendingPathComponent("steps.jsonl")
        let text = try String(contentsOf: steps, encoding: .utf8)
        XCTAssertFalse(text.contains(secret), "a known secret value must not reach the trace")
        XCTAssertFalse(text.contains("tr0ub4dor-and-three"))
        XCTAssertTrue(text.contains("«redacted»"))
    }

    /// `run.json` used to be written with no redaction at all, and `goal` is the user's own
    /// message — the single most likely place for a pasted key to be sitting.
    func testSecretsInTheGoalAndClosingNoteDoNotReachTheManifest() async throws {
        let valueSecret = "postgres://app:tr0ub4dor-and-three@db.internal:5432/prod"
        let shapedSecret = "sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"

        let writer = await makeRun(secrets: [valueSecret])
        await writer.finish(.init(
            botID: UUID(), botName: "test", conversationID: UUID(),
            goal: "rotate \(shapedSecret) and point the app at \(valueSecret)",
            brain: "gemini", environment: "mac", startedAt: Date(),
            closingNote: "left the old key \(shapedSecret) in place"
        ))

        let manifest = await writer.directory.appendingPathComponent("run.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertFalse(text.contains("abcdefghijklmnopqrstuvwxyz0123456789"),
                       "a key pasted into the goal must not survive into the manifest")
        XCTAssertFalse(text.contains(valueSecret))
        XCTAssertFalse(text.contains("tr0ub4dor-and-three"),
                       "the closing note and the goal get the same treatment as a step record")
        XCTAssertTrue(text.contains("«redacted»"))
    }

    /// Editing the manifest is the quiet version of editing the trace: change the goal, and the
    /// run is about something else.
    func testEditingTheManifestBreaksItsSeal() async throws {
        let writer = await makeRun()
        await writer.finish(.init(botID: UUID(), botName: "test", conversationID: UUID(),
                                  goal: "delete the archive", brain: "gemini",
                                  environment: "mac", startedAt: Date(), closingNote: "done"))
        let url = await writer.directory.appendingPathComponent("run.json")

        let reader = TraceReader(root: URL(fileURLWithPath: "/"), chainKey: Self.key)
        let directory = await writer.directory
        XCTAssertEqual(TraceWriter.verifyManifest(try XCTUnwrap(reader.readManifest(directory)),
                                                  chainKey: Self.key), .sealed)

        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "delete the archive", with: "list the archive")
        try text.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(TraceWriter.verifyManifest(try XCTUnwrap(reader.readManifest(directory)),
                                                  chainKey: Self.key), .altered)
    }

    // MARK: - On disk

    /// A trace holds real commands, real paths and real file contents. It is not a thing to
    /// leave at whatever the umask happened to be.
    func testTraceFilesAreOwnerOnly() async throws {
        let writer = await makeRun()
        await writer.record(.init(kind: .toolProposed, summary: "step"))
        _ = await writer.attach(Data([0x89, 0x50, 0x4E, 0x47]), name: "screen.png")
        await writer.finish(.init(botID: UUID(), botName: "test", conversationID: UUID(),
                                  goal: "g", brain: "gemini", environment: "mac",
                                  startedAt: Date()))
        let directory = await writer.directory

        for (path, expected) in [
            (directory.path, 0o700),
            (directory.appendingPathComponent("artifacts").path, 0o700),
            (directory.appendingPathComponent("steps.jsonl").path, 0o600),
            (directory.appendingPathComponent("run.json").path, 0o600),
            (directory.appendingPathComponent("artifacts/0002-screen.png").path, 0o600),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(mode & 0o777, expected, "wrong mode on \(path)")
        }
    }

    /// The key has to be the same one on the next read, or every trace written before now
    /// verifies as tampered. Touches the real credential file, which is where the app puts it
    /// and the only place this path can honestly be exercised.
    func testTheMachineChainKeyIsStable() throws {
        guard let first = TraceChainKey.current() else {
            throw XCTSkip("no chain key on this machine and one could not be written")
        }
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(TraceChainKey.current(), first)
    }

    // MARK: - Forging, the way an attacker with the source would

    private func readEvents(_ steps: URL) throws -> [TraceWriter.Event] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: steps, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(TraceWriter.Event.self, from: Data($0.utf8)) }
    }

    /// Rewrite the file the way the unkeyed scheme allowed: apply an edit, then re-link every
    /// record with a plain SHA-256 over the app's own canonical encoding.
    private func rechainWithBareSHA256(_ steps: URL, strippingAlgorithm: Bool,
                                       edit: (inout [TraceWriter.Event]) -> Void) throws {
        var events = try readEvents(steps)
        edit(&events)
        if strippingAlgorithm {
            for index in events.indices { events[index].hashAlgorithm = nil }
        }

        let encoder = TraceWriter.canonicalEncoder
        var previous = TraceWriter.genesis
        var lines: [String] = []
        for original in events {
            var event = original
            event.prev = previous
            event.hash = nil
            let body = try encoder.encode(event)
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            event.hash = hash
            previous = hash
            lines.append(String(decoding: try encoder.encode(event), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: steps, atomically: true, encoding: .utf8)
    }

    /// Two more records chained onto the end of `text` with no signature at all.
    private func forgeUnsignedTail(after text: String, count: Int) throws -> String {
        let encoder = TraceWriter.canonicalEncoder
        var previous = try XCTUnwrap(readLastHash(text))
        var out = ""
        for i in 1...count {
            var event = TraceWriter.Event(kind: .note, summary: "appended \(i)")
            event.seq = 100 + i
            event.prev = previous
            event.hashAlgorithm = nil
            event.hash = nil
            let body = try encoder.encode(event)
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            event.hash = hash
            previous = hash
            out += String(decoding: try encoder.encode(event), as: UTF8.self) + "\n"
        }
        return out
    }

    private func readLastHash(_ text: String) -> String? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let last = text.split(separator: "\n", omittingEmptySubsequences: true).last,
              let event = try? decoder.decode(TraceWriter.Event.self, from: Data(last.utf8))
        else { return nil }
        return event.hash
    }

    /// Exactly what `verifyChain` did before it was keyed. Used to prove a forgery would have
    /// passed the old check.
    private func bareSHA256ChainIsSelfConsistent(_ steps: URL) throws -> Bool {
        let encoder = TraceWriter.canonicalEncoder
        var expected = TraceWriter.genesis
        for var event in try readEvents(steps) {
            guard let claimed = event.hash, event.prev == expected else { return false }
            event.hash = nil
            let body = try encoder.encode(event)
            let recomputed = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            if recomputed != claimed { return false }
            expected = claimed
        }
        return true
    }
}
