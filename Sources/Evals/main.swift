import Foundation
import BotHarnessCore

/// The eval runner.
///
///     swift run Evals                 # deterministic harness tasks
///     swift run Evals --live          # tasks needing a real model and a real Mac
///     swift run Evals --all --repeat 3
///     swift run Evals --task H04
///
/// Reports a table and a success rate. Exits non-zero if any task fails, so this can gate a
/// commit.

// MARK: - A brain that reads from a script

final class ScriptedBrain: BrainAdapter, @unchecked Sendable {
    public let name = "scripted"
    public let canDriveComputer = true
    public func isConfigured() async -> Bool { true }

    private var remaining: [BrainResponse]
    private let whenEmpty: BrainResponse

    init(_ script: [BrainResponse]) {
        self.remaining = script
        // An exhausted script keeps claiming completion. That is the correct default: it
        // exercises the verifier, and for the budget task it is the whole point.
        self.whenEmpty = .say("I believe that is done.")
    }

    public func step(_ request: BrainRequest) async throws -> BrainResponse {
        remaining.isEmpty ? whenEmpty : remaining.removeFirst()
    }
}

// MARK: - Running one task

struct Result {
    var task: EvalTask
    var passed: Bool
    var detail: String
    var seconds: Double
    var toolCalls: Int
}

func run(_ task: EvalTask) async -> Result {
    let started = Date()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bh-eval-\(task.id)-\(UUID().uuidString.prefix(6))")

    do {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("settings"),
                                                withIntermediateDirectories: true)
        try task.setUp(dir)
    } catch {
        return Result(task: task, passed: false,
                      detail: "set-up failed: \(error.localizedDescription)",
                      seconds: 0, toolCalls: 0)
    }
    defer { try? FileManager.default.removeItem(at: dir) }

    var bot = Bot(name: "Eval")
    bot.workspace = dir
    bot.persona = "A bot under test. Do the task, verify it, and stop."

    var contract = TaskContract(botID: bot.id, conversationID: UUID(), objective: task.goal)
    contract.autonomy = task.autonomy
    contract.successCriteria = task.criteria(dir)
    contract.urgency = .critical            // smallest budget, so a stuck eval ends quickly
    contract.authority = Authority(
        readable: [dir.path + "/**"],
        writable: [dir.path + "/**"],
        granted: ["files.read", "files.write", "shell.exec", "computer.observe",
                  "computer.control", "web.search", "web.read", "browser.use"],
        requiresApproval: ["files.delete"],
        selfRepair: true, maySpend: false)

    let brain: any BrainAdapter = task.kind == .harness
        ? ScriptedBrain(task.script(dir))
        : GeminiAdapter()

    let loop = AgentLoop(contract: contract, bot: bot, brain: brain,
                         registry: ToolRegistry(),
                         trace: TraceWriter(root: dir.appendingPathComponent("trace"), botName: "Eval"),
                         rules: task.rules)

    var events: [AgentLoop.Event] = []
    var toolCalls: [String] = []
    var approvals: [String] = []
    var closure: TaskContract.Closure?

    for await event in await loop.run(goal: task.goal) {
        events.append(event)
        switch event {
        case .toolStarted(_, let tool, let summary, _): toolCalls.append("\(tool) \(summary)")
        case .needsApproval(let request):
            approvals.append(request.summary)
            // Nobody is watching an eval, so an approval prompt is a denial. Tasks that
            // expect to be asked assert on `approvalsRequested` instead of on completion.
            await loop.answerApproval(.denied)
        case .finished(let c, _): closure = c
        default: break
        }
    }

    let outcome = EvalOutcome(closure: closure, events: events,
                              toolCalls: toolCalls, approvalsRequested: approvals)

    // Explicit assertion first: several tasks pass by something *not* happening.
    if let assertAfter = task.assertAfter, let failure = assertAfter(dir, outcome) {
        return Result(task: task, passed: false, detail: failure,
                      seconds: Date().timeIntervalSince(started), toolCalls: toolCalls.count)
    }

    guard task.passRequiresCriteria else {
        return Result(task: task, passed: true, detail: closure.map { $0.rawValue } ?? "finished",
                      seconds: Date().timeIntervalSince(started), toolCalls: toolCalls.count)
    }

    // Then the criteria, re-checked here rather than trusting the run's own verdict.
    let shell = ShellExecutor()
    let verifier = Verifier()
    var unmet: [String] = []
    for criterion in task.criteria(dir) {
        switch await verifier.verify(criterion, using: shell) {
        case .passed: continue
        case .failed(let why), .indeterminate(let why):
            unmet.append("\(criterion.statement) — \(why)")
        }
    }

    let passed = unmet.isEmpty
    return Result(task: task, passed: passed,
                  detail: passed ? (closure.map { $0.rawValue } ?? "finished") : unmet.joined(separator: "; "),
                  seconds: Date().timeIntervalSince(started), toolCalls: toolCalls.count)
}

// MARK: - Entry

let args = CommandLine.arguments.dropFirst()

if args.contains("--connections") {
    await Connections.run()
    exit(0)
}
let wantsLive = args.contains("--live") || args.contains("--all")
let wantsHarness = !args.contains("--live") || args.contains("--all")
let only = args.firstIndex(of: "--task").flatMap { i -> String? in
    let next = args.index(after: i)
    return next < args.endIndex ? args[next] : nil
}
let repeats = args.firstIndex(of: "--repeat").flatMap { i -> Int? in
    let next = args.index(after: i)
    return next < args.endIndex ? Int(args[next]) : nil
} ?? 1

var selected: [EvalTask] = []
if wantsHarness { selected += EvalSuite.harnessTasks }
if wantsLive { selected += EvalSuite.liveTasks }
if let only { selected = selected.filter { $0.id.hasPrefix(only) } }

guard !selected.isEmpty else {
    print("No tasks matched.")
    exit(2)
}

if selected.contains(where: { $0.kind == .live }), !CredentialStore.has("gemini") {
    print("""

    Live tasks need a Gemini key, and none is stored.
    Add one in the app under Settings (⌘,), or run: scripts/set-key.sh gemini

    Running the deterministic tasks only.

    """)
    selected = selected.filter { $0.kind == .harness }
}

print("Bot-Harness evals — \(selected.count) task\(selected.count == 1 ? "" : "s")"
      + (repeats > 1 ? ", \(repeats) runs each" : ""))
print(String(repeating: "─", count: 78))

var results: [Result] = []
for round in 1...repeats {
    for task in selected {
        let result = await run(task)
        results.append(result)
        let mark = result.passed ? "pass" : "FAIL"
        let round = repeats > 1 ? " (run \(round))" : ""
        print(String(format: "%@  %-38@ %5.1fs  %2d tools%@",
                     mark, task.id as NSString, result.seconds, result.toolCalls, round as NSString))
        if !result.passed { print("      \(result.detail)") }
    }
}

print(String(repeating: "─", count: 78))

let passed = results.filter(\.passed).count
let rate = results.isEmpty ? 0 : Int(Double(passed) / Double(results.count) * 100)
print("\(passed)/\(results.count) passed — \(rate)%")

// Per-category, because an even overall rate can hide one category failing entirely.
let byCategory = Dictionary(grouping: results, by: { $0.task.category })
for category in EvalTask.Category.allCases {
    guard let group = byCategory[category], !group.isEmpty else { continue }
    let ok = group.filter(\.passed).count
    print(String(format: "  %-22@ %d/%d", category.rawValue as NSString, ok, group.count))
}

exit(passed == results.count ? 0 : 1)
