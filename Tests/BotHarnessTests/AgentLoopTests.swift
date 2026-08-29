import XCTest
@testable import BotHarnessCore

/// A brain that returns a scripted sequence of turns.
///
/// The loop is the part of this system most worth testing and the part hardest to test against
/// a real model, because a real model is nondeterministic and costs money. A scripted brain
/// makes the loop's own behaviour — permission gating, verification, budget enforcement,
/// stopping — assertable without either.
final class ScriptedBrain: BrainAdapter, @unchecked Sendable {
    let name = "scripted"
    let canDriveComputer = true
    func isConfigured() async -> Bool { true }

    private var script: [BrainResponse]
    private(set) var received: [BrainRequest] = []

    init(_ script: [BrainResponse]) { self.script = script }

    func step(_ request: BrainRequest) async throws -> BrainResponse {
        received.append(request)
        guard !script.isEmpty else {
            return BrainResponse(text: "Done.", actions: [], usage: .init())
        }
        return script.removeFirst()
    }

}

extension BrainResponse {
    /// A turn where the model only speaks — which the loop treats as a completion claim.
    static func say(_ text: String) -> BrainResponse {
        BrainResponse(text: text, actions: [], usage: .init(promptTokens: 10, completionTokens: 5))
    }

    /// A turn where the model asks for one tool call.
    static func call(_ name: String, _ args: [String: Any], intent: String? = nil) -> BrainResponse {
        BrainResponse(text: nil,
                      actions: [BrainAction(id: "call-\(UUID().uuidString.prefix(4))",
                                            name: name, arguments: args, intent: intent)],
                      usage: .init(promptTokens: 10, completionTokens: 5))
    }
}

final class AgentLoopTests: XCTestCase {

    private func workspace() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bh-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBot(_ dir: URL) -> Bot {
        var bot = Bot(name: "Tester")
        bot.workspace = dir
        bot.persona = "A test bot."
        return bot
    }

    private func makeContract(_ bot: Bot, objective: String, criteria: [SuccessCriterion] = [],
                              autonomy: Autonomy = .autonomousWorkspace) -> TaskContract {
        var c = TaskContract(botID: bot.id, conversationID: UUID(), objective: objective)
        c.autonomy = autonomy
        c.successCriteria = criteria
        let path = bot.workspace!.path
        c.authority = Authority(
            readable: [path + "/**"], writable: [path + "/**"],
            granted: ["files.read", "files.write", "shell.exec", "computer.observe"],
            requiresApproval: [], selfRepair: true, maySpend: false)
        return c
    }

    private func run(_ loop: AgentLoop, goal: String) async -> [AgentLoop.Event] {
        var events: [AgentLoop.Event] = []
        for await event in await loop.run(goal: goal) { events.append(event) }
        return events
    }

    // MARK: - The loop actually executes tools

    func testItExecutesAToolAndReportsTheResult() async throws {
        let dir = try workspace()
        let bot = makeBot(dir)
        let target = dir.appendingPathComponent("hello.txt")

        let brain = ScriptedBrain([
            .call("files.write", ["path": target.path, "content": "hello from the loop"],
                  intent: "create the file the user asked for"),
            .say("Written."),
        ])

        let loop = AgentLoop(contract: makeContract(bot, objective: "write hello.txt"),
                             bot: bot, brain: brain, registry: ToolRegistry(),
                             trace: TraceWriter(root: dir, botName: "Tester"), rules: [])

        let events = await run(loop, goal: "write hello.txt")

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "the loop should have actually written the file")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hello from the loop")

        let finished = events.contains { if case .toolFinished(_, _, let ok) = $0 { return ok }; return false }
        XCTAssertTrue(finished, "the tool result should be reported back")
    }

    // MARK: - Verification decides completion, not the model

    func testItRefusesToStopUntilCriteriaAreVerified() async throws {
        let dir = try workspace()
        let bot = makeBot(dir)
        let marker = dir.appendingPathComponent("done.txt")

        // The model claims completion immediately, twice, before doing the work. The loop
        // should push back both times and only accept the third turn, once the file exists.
        let brain = ScriptedBrain([
            .say("I've identified the problem."),
            .say("It's definitely fixed now."),
            .call("files.write", ["path": marker.path, "content": "ok"], intent: "actually do it"),
            .say("Done."),
        ])

        let criteria = [SuccessCriterion(statement: "done.txt exists",
                                         kind: .command("test -f \(marker.path)"))]

        let loop = AgentLoop(contract: makeContract(bot, objective: "create done.txt", criteria: criteria),
                             bot: bot, brain: brain, registry: ToolRegistry(),
                             trace: TraceWriter(root: dir, botName: "Tester"), rules: [])

        let events = await run(loop, goal: "create done.txt")

        let last = events.last { if case .finished = $0 { return true }; return false }
        guard case .finished(let closure, _)? = last else {
            return XCTFail("the run should have finished")
        }

        XCTAssertEqual(closure, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        // Four turns: two rejected claims, the real action, and the accepted claim.
        XCTAssertEqual(brain.received.count, 4,
                       "the loop should have sent the model back in after each premature claim")
    }

    // MARK: - Authority is enforced by the tool layer

    func testItRefusesToWriteOutsideItsWorkspace() async throws {
        let dir = try workspace()
        let bot = makeBot(dir)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bh-outside-\(UUID().uuidString).txt")

        let brain = ScriptedBrain([
            .call("files.write", ["path": outside.path, "content": "should never land"],
                  intent: "write outside the workspace"),
            .say("Finished."),
        ])

        let loop = AgentLoop(contract: makeContract(bot, objective: "write a file"),
                             bot: bot, brain: brain, registry: ToolRegistry(),
                             trace: TraceWriter(root: dir, botName: "Tester"), rules: [])

        _ = await run(loop, goal: "write a file")

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                       "a write outside the granted paths must not reach the disk")
    }

    // MARK: - The budget is a real backstop

    func testItStopsWhenTheBudgetIsExhausted() async throws {
        let dir = try workspace()
        let bot = makeBot(dir)

        // A model that never finishes and never satisfies the criterion.
        //
        // Its calls must VARY. Repeating one identical call is a different failure, caught
        // earlier and more cheaply by LoopGuard, which ends the run as a completion. The
        // budget exists for the other case: an agent making endless but different calls, which
        // no repetition check can see.
        final class Endless: BrainAdapter, @unchecked Sendable {
            let name = "endless"; let canDriveComputer = false
            private var n = 0
            func isConfigured() async -> Bool { true }
            func step(_ request: BrainRequest) async throws -> BrainResponse {
                n += 1
                return .call("shell.exec", ["command": "echo \(n)"], intent: "keep going")
            }
        }

        var contract = makeContract(bot, objective: "never finishes",
                                    criteria: [SuccessCriterion(statement: "impossible",
                                                                kind: .command("false"))])
        contract.urgency = .critical   // the smallest budget: 100 steps, 50 model calls

        let loop = AgentLoop(contract: contract, bot: bot, brain: Endless(),
                             registry: ToolRegistry(),
                             trace: TraceWriter(root: dir, botName: "Tester"), rules: [])

        let events = await run(loop, goal: "never finishes")

        let last = events.last { if case .finished = $0 { return true }; return false }
        guard case .finished(let closure, _)? = last else {
            return XCTFail("the run should have ended")
        }

        XCTAssertEqual(closure, .budgetExhausted,
                       "an unsatisfiable run must end on the budget rather than looping forever")
    }
}
