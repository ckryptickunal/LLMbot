import XCTest
@testable import BotHarness

/// The trace is the product's evidence. A log nobody can check is a log nobody should trust,
/// so these tests assert that tampering is actually detected rather than merely discouraged.
final class TraceChainTests: XCTestCase {

    private func makeRun() async -> TraceWriter {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("botharness-tests-\(UUID().uuidString)")
        return TraceWriter(root: root, botName: "test")
    }

    func testChainIsIntactForAnUntouchedTrace() async throws {
        let writer = await makeRun()
        for i in 1...5 {
            await writer.record(.init(kind: .toolProposed, summary: "step \(i)"))
        }
        let steps = await writer.directory.appendingPathComponent("steps.jsonl")

        guard case .intact(let records) = TraceWriter.verifyChain(at: steps) else {
            return XCTFail("a freshly written trace should verify")
        }
        XCTAssertEqual(records, 5)
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

        guard case .brokenAt(let line, _) = TraceWriter.verifyChain(at: steps) else {
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

        guard case .brokenAt = TraceWriter.verifyChain(at: steps) else {
            return XCTFail("removing a record must break the chain")
        }
    }

    func testSecretsAreRedactedBeforeReachingDisk() async throws {
        let writer = await makeRun()
        await writer.record({
            var e = TraceWriter.Event(kind: .toolProposed, summary: "call the API")
            e.arguments = #"{"Authorization":"sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"}"#
            e.output = Redactor.redact("key=AIzaSyC0123456789abcdefghijklmnopqrstuvw")
            return e
        }())

        let steps = await writer.directory.appendingPathComponent("steps.jsonl")
        let text = try String(contentsOf: steps, encoding: .utf8)
        XCTAssertFalse(text.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(text.contains("AIzaSyC0123456789abcdefghijklmnopqrstuvw"))
    }
}
