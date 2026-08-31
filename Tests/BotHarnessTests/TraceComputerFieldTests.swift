import XCTest
@testable import BotHarnessCore

/// A trace has to say which computer a step ran on, and it has to still say it after a round trip
/// through disk and the tamper-evidence chain.
///
/// The reason this is worth a test of its own: the field exists precisely because the bot's
/// *setting* is not evidence. A run configured for a container on a Mac that has none falls back
/// to the host, and a record that repeated the setting would describe work on the user's own
/// machine as having happened somewhere else.
final class TraceComputerFieldTests: XCTestCase {

    private static let key = Data(repeating: 0x5a, count: 32)

    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("botharness-computer-\(UUID().uuidString)")
    }

    func testTheComputerSurvivesTheRoundTripAndTheChainStillVerifies() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TraceWriter(root: root, botName: "test", chainKey: Self.key)

        await writer.record({
            var event = TraceWriter.Event(kind: .toolProposed, summary: "shell.exec: make")
            event.tool = "shell.exec"
            event.computer = "container:bh-3f2504e04f89"
            return event
        }())
        await writer.finish(.init(botID: UUID(), botName: "test", conversationID: UUID(),
                                  goal: "build", brain: "gemini",
                                  environment: "container:bh-3f2504e04f89",
                                  startedAt: Date(), closingNote: "done"))

        let stepsURL = await writer.directory.appendingPathComponent("steps.jsonl")
        let steps = try String(contentsOf: stepsURL, encoding: .utf8)
        XCTAssertTrue(steps.contains("\"computer\":\"container:bh-3f2504e04f89\""),
                      "the computer was not written to the trace:\n\(steps)")

        guard case .intact = TraceWriter.verifyChain(at: stepsURL, chainKey: Self.key) else {
            return XCTFail("adding the field broke the tamper-evidence chain")
        }

        let reader = TraceReader(root: root, chainKey: Self.key)
        XCTAssertEqual(reader.runs().first?.manifest?.environment, "container:bh-3f2504e04f89")
    }

    /// Traces written before the field existed must still decode, and their seals must still
    /// verify byte for byte — which is only true because the field is optional and an absent
    /// optional is omitted by the encoder rather than written as null.
    func testAStepWithoutTheFieldIsUnchanged() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TraceWriter(root: root, botName: "test", chainKey: Self.key)

        await writer.record(.init(kind: .note, summary: "a note with no machine recorded"))
        let stepsURL = await writer.directory.appendingPathComponent("steps.jsonl")
        let steps = try String(contentsOf: stepsURL, encoding: .utf8)
        XCTAssertFalse(steps.contains("\"computer\""),
                       "an absent computer should not appear in the record at all:\n\(steps)")
    }
}
