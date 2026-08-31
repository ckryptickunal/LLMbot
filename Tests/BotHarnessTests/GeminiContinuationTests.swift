import XCTest
@testable import BotHarnessCore

/// One case, and it is the one that was wrong: a model turn carrying several function calls
/// produces several tool results, and a continuation must send all of them.
///
/// The old code sent `turns.suffix(1)`, so a turn that called four tools had three of its results
/// silently dropped. The model then reasoned about calls it never saw answered — which looks, from
/// the outside, like the model being forgetful rather than the harness losing data.
final class GeminiContinuationTests: XCTestCase {

    /// Tool results are sent as text parts labelled "Result of <call id>:" — the Interactions API
    /// takes `input` as content parts, and this adapter does not use a dedicated response type.
    private func toolResultCount(_ input: Any) -> Int {
        guard let parts = input as? [[String: Any]] else { return 0 }
        return parts.filter { ($0["text"] as? String)?.hasPrefix("Result of ") == true }.count
    }

    func testEveryToolResultSinceTheLastModelTurnIsSent() {
        let adapter = GeminiAdapter()
        let request = BrainRequest(
            system: "s",
            turns: [
                .init(role: .user, text: "do the thing"),
                .init(role: .assistant, text: "calling four tools"),
                .init(role: .tool, text: "a", toolCallID: "1"),
                .init(role: .tool, text: "b", toolCallID: "2"),
                .init(role: .tool, text: "c", toolCallID: "3"),
                .init(role: .tool, text: "d", toolCallID: "4"),
            ],
            tools: [],
            previousInteractionID: "interaction-123")

        XCTAssertEqual(toolResultCount(adapter.buildInput(request)), 4,
                       "a continuation must carry every tool result, not only the last")
    }

    func testAFirstRequestStillSendsTheWholeConversation() {
        let adapter = GeminiAdapter()
        let request = BrainRequest(
            system: "s",
            turns: [.init(role: .user, text: "hello")],
            tools: [],
            previousInteractionID: nil)
        // Nothing to continue from, so the history has to go in full.
        XCTAssertNotNil(adapter.buildInput(request))
    }
}
