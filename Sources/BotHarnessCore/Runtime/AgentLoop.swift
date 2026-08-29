import Foundation

/// The loop. Everything else in this project exists to be called from here.
///
/// ```
/// observe → assemble context → ask the brain → check permission → execute
///         → observe again → verify → continue or stop
/// ```
///
/// Three properties are deliberate and worth defending:
///
/// **Observation escalates.** Structured state first, the accessibility tree next, a
/// screenshot only when those were not enough. A screenshot costs roughly 1,500 tokens and
/// tells the model less about a button than one line of the accessibility tree does.
///
/// **The verifier decides when to stop**, not the model. A turn with no tool calls is a claim
/// of completion, and claims are checked.
///
/// **Nothing executes before the permission engine has seen it**, including actions the model
/// marked safe itself. A provider's safety judgement is an input to our floor, never a
/// substitute for it.
public actor AgentLoop {

    // MARK: Events

    public enum Event: Sendable {
        case thinking
        case said(String)
        case toolStarted(id: String, tool: String, summary: String, intent: String?)
        case toolFinished(id: String, output: String, ok: Bool)
        case needsApproval(ApprovalRequest)
        case observed(String)
        case screenshot(Data)
        case verifying
        case finished(TaskContract.Closure, note: String)
        case failed(String)
    }

    // MARK: Dependencies

    private var contract: TaskContract
    private let bot: Bot
    private let brain: any BrainAdapter
    private let registry: ToolRegistry
    private let files: FileExecutor
    private let shell: ShellExecutor
    private let computer: ComputerExecutor
    private let trace: TraceWriter
    private let rules: [PermissionRule]

    /// Everything the agent could reach, most of which is deliberately not exposed.
    private let capabilities: CapabilityRegistry

    private let router = CapabilityRouter()
    private let selector = SurfaceSelector()
    private let verifier = Verifier()
    private var stuck = StuckDetector()

    private var turns: [BrainTurn] = []
    private var lastObservation = ""

    /// Handle for the server-side conversation, so each turn continues it rather than
    /// resending the whole history.
    private var interactionID: String?

    /// What the bot decided was worth remembering this run. Handed back when the run ends so
    /// the store can persist it against the bot.
    private var learned: [MemoryNote] = []

    /// Anything the bot learned during this run.
    public func memoryLearned() -> [MemoryNote] { learned }

    /// Set by the UI when the user answers an approval prompt.
    private var pendingApproval: CheckedContinuation<ApprovalRequest.Answer, Never>?

    public init(contract: TaskContract, bot: Bot, brain: any BrainAdapter, registry: ToolRegistry,
         trace: TraceWriter, rules: [PermissionRule],
         capabilities: CapabilityRegistry = CapabilityRegistry()) {
        self.capabilities = capabilities
        self.contract = contract
        self.bot = bot
        self.brain = brain
        self.registry = registry
        self.trace = trace
        self.rules = rules
        self.files = FileExecutor(authority: contract.authority)
        self.shell = ShellExecutor()
        self.computer = ComputerExecutor()
    }

    /// Called by the UI when the user taps Allow or Deny on an approval card.
    public func answerApproval(_ answer: ApprovalRequest.Answer) {
        pendingApproval?.resume(returning: answer)
        pendingApproval = nil
    }

    // MARK: - Run

    public func run(goal: String) -> AsyncStream<Event> {
        AsyncStream { continuation in
            Task {
                await self.execute(goal: goal, emit: { continuation.yield($0) })
                continuation.finish()
            }
        }
    }

    private func execute(goal: String, emit: @escaping @Sendable (Event) -> Void) async {
        await trace.record(.init(kind: .runStarted, summary: goal))
        turns.append(.init(role: .user, text: goal))

        guard await brain.isConfigured() else {
            await finish(.failed,
                         note: "\(brain.name) is not set up. Add the key in Settings (⌘,).",
                         emit: emit)
            return
        }

        let domains = router.classify(goal) ?? CapabilityRouter.alwaysOn
        // The meta-tools are always present, so a request the router did not anticipate can
        // still find its way to the right provider instead of simply failing.
        var exposed = await registry.inDomains(domains) + ToolRegistry.metaTools
        exposed = selector.rank(exposed)
        var dynamicallyLoaded: [ToolDescriptor] = []

        while true {
            // Budget. A verifier that never passes plus a model that never stops is an
            // expensive infinite loop, so this is the backstop that makes the rest safe.
            if contract.spend.exceeds(contract.urgency.budget) {
                await finish(.budgetExhausted,
                             note: "Stopped after \(contract.spend.steps) steps and \(contract.spend.modelCalls) model calls — this run's budget.",
                             emit: emit)
                return
            }

            emit(.thinking)
            contract.spend.steps += 1

            // — observe —
            let observation = await observe(emit: emit)

            // — ask the brain —
            var request = BrainRequest(
                system: systemPrompt(exposed: exposed),
                turns: turns,
                tools: exposed,
                computerUse: usesComputer(exposed) ? .desktop : .off,
                observation: observation,
                previousInteractionID: interactionID
            )
            if contract.urgency.budget.observationDepth == .full, brain.canDriveComputer {
                request.screenshot = try? await computer.screenshot()
                if let shot = request.screenshot { emit(.screenshot(shot)) }
            }

            let response: BrainResponse
            do {
                let call = await trace.record(.init(kind: .modelCall, summary: "asked \(brain.name)"))
                response = try await brain.step(request)
                contract.spend.modelCalls += 1
                contract.spend.promptTokens += response.usage.promptTokens
                contract.spend.completionTokens += response.usage.completionTokens
                contract.spend.usd += response.usage.costUSD
                if let id = response.interactionID { interactionID = id }
                await trace.complete(call, outcome: .succeeded, output: response.raw)
            } catch {
                let message = error.localizedDescription
                await trace.record(.init(kind: .modelResponse, summary: "model call failed: \(message)"))
                await finish(.failed, note: message, emit: emit)
                return
            }

            if let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turns.append(.init(role: .assistant, text: text))
                emit(.said(text))
            }

            // — a turn with no actions is a claim of completion —
            if response.actions.isEmpty {
                emit(.verifying)
                let outstanding = await checkCriteria()
                if outstanding.isEmpty {
                    // The reply was already emitted above; repeating it as a closing note
                    // would post it to the conversation twice.
                    await finish(.succeeded, note: response.text ?? "Done.",
                                 alreadySaid: response.text != nil, emit: emit)
                    return
                }
                let notice = verifier.continuationNotice(outstanding: outstanding)
                turns.append(.init(role: .user, text: notice))
                await trace.record(.init(kind: .verification, summary: "not complete: \(outstanding.count) criteria outstanding"))
                continue
            }

            // — act —
            for action in response.actions {
                let carried = await perform(action, exposed: exposed, emit: emit)
                if case .halt(let why) = carried {
                    await finish(.escalated, note: why, emit: emit)
                    return
                }
            }

            // — stuck? —
            let signature = response.actions.map(\.name).joined(separator: ",")
            let changed = await observe(quiet: true) != lastObservation
            if let signal = stuck.record(action: signature, observation: lastObservation,
                                         error: nil, stateChanged: changed) {
                await trace.record(.init(kind: .stuckDetected, summary: "\(signal)"))
                let playbook = RecoveryPlaybook.forSignal(signal)
                turns.append(.init(role: .user, text: """
                    You appear to be stuck: \(describe(signal)).

                    Do not repeat the last action. Work through these in order:
                    \(playbook.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                    """))
                stuck.reset()
            }
        }
    }

    // MARK: - One action

    private enum Carried { case carryOn, halt(String) }

    private func perform(_ action: BrainAction, exposed: [ToolDescriptor],
                         emit: @escaping @Sendable (Event) -> Void) async -> Carried {
        let tool = await registry.tool(action.name)
        let detail = describe(arguments: action.arguments)
        let summary = action.intent ?? "\(action.name) \(detail)"

        let proposed = ProposedAction(
            tool: action.name,
            summary: summary,
            detail: detail,
            botID: bot.id,
            // Gemini's own prompt-injection detector reporting `blocked` is treated as a claim
            // that this action came from page content rather than from the user.
            originatedFromUntrustedContent: action.safety?.isBlocked ?? false
        )

        let engine = PermissionEngine(contract: contract, rules: rules)
        var decision = engine.decide(proposed, tool: tool)

        // The provider asking for confirmation can only make us stricter, never more permissive.
        if action.safety?.requiresConfirmation == true, decision.outcome == .allowed {
            decision = .init(outcome: .asked,
                             reason: action.safety?.explanation ?? "the model asked for confirmation",
                             decidedBy: .safetyFloor)
        }

        await trace.record({
            var e = TraceWriter.Event(kind: .permissionCheck, summary: summary)
            e.tool = action.name
            e.arguments = detail
            e.intent = action.intent
            e.permissionOutcome = decision.outcome.rawValue
            e.permissionReason = decision.reason
            e.permissionLayer = decision.decidedBy.rawValue
            return e
        }())

        switch decision.outcome {
        case .refused:
            let message = "Refused: \(decision.reason)"
            turns.append(.init(role: .tool, text: message, toolCallID: action.id))
            emit(.toolFinished(id: action.id, output: message, ok: false))
            return .carryOn

        case .asked:
            let request = ApprovalRequest(summary: summary, detail: detail, reason: decision.reason)
            emit(.needsApproval(request))
            let answer = await withCheckedContinuation { (c: CheckedContinuation<ApprovalRequest.Answer, Never>) in
                pendingApproval = c
            }
            guard answer == .allowedOnce || answer == .allowedAlways else {
                return .halt("You declined: \(summary)")
            }

        case .allowed:
            break
        }

        // — execute —
        emit(.toolStarted(id: action.id, tool: action.name, summary: summary, intent: action.intent))
        let step = await trace.record({
            var e = TraceWriter.Event(kind: .toolProposed, summary: summary)
            e.tool = action.name
            e.arguments = detail
            e.intent = action.intent
            return e
        }())

        do {
            var output = try await dispatch(action)
            // An empty result teaches the model nothing, so it tries the same thing again.
            // Say plainly that the call succeeded and produced nothing.
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output = "(the command succeeded and produced no output)"
            }
            await trace.complete(step, outcome: .succeeded, output: output)
            turns.append(.init(role: .tool, text: output, toolCallID: action.id))
            emit(.toolFinished(id: action.id, output: output, ok: true))
        } catch {
            let message = error.localizedDescription
            await trace.complete(step, outcome: .failed, error: message)
            turns.append(.init(role: .tool, text: "Failed: \(message)", toolCallID: action.id))
            emit(.toolFinished(id: action.id, output: message, ok: false))
        }
        return .carryOn
    }

    // MARK: - Dispatch

    private func dispatch(_ action: BrainAction) async throws -> String {
        func str(_ key: String) -> String? { action.arguments[key] as? String }
        func int(_ key: String) -> Int? {
            (action.arguments[key] as? Int) ?? (action.arguments[key] as? Double).map(Int.init)
        }

        switch action.name {
        // — files —
        case "files.read":
            guard let path = str("path") else { throw Bad.missing("path") }
            return try await files.read(path, offset: int("offset"), limit: int("limit"))
        case "files.write":
            guard let path = str("path"), let content = str("content") else { throw Bad.missing("path and content") }
            return try await files.write(path, content: content)
        case "files.patch":
            guard let path = str("path"), let find = str("find"), let replace = str("replace") else { throw Bad.missing("path, find and replace") }
            return try await files.patch(path, find: find, replace: replace)
        case "files.delete":
            guard let path = str("path") else { throw Bad.missing("path") }
            return try await files.delete(path)
        case "files.search", "files.glob":
            // Tildes have to be expanded here: the path goes into a single-quoted shell
            // argument, where ~ is literal. Left unexpanded, every lookup under ~/Desktop
            // silently matched nothing.
            let workspace = bot.workspace?.path ?? NSHomeDirectory()
            var rawRoot = str("path") ?? workspace
            // A GUI app's working directory is "/", so a relative path silently means the
            // whole filesystem. Relative always means the bot's workspace.
            if rawRoot == "." || rawRoot.isEmpty { rawRoot = workspace }
            else if !rawRoot.hasPrefix("/") && !rawRoot.hasPrefix("~") {
                rawRoot = workspace + "/" + rawRoot
            }
            let root = (rawRoot as NSString).expandingTildeInPath
            let pattern = str("pattern") ?? "*"

            // `find` rather than a zsh recursive glob: predictable under `zsh -lc`, and it
            // does not depend on shell options that may or may not be set.
            let command = action.name == "files.search"
                ? "rg -n --max-count 40 -- \(shellQuote(pattern)) \(shellQuote(root)) 2>/dev/null | head -60"
                : "find \(shellQuote(root)) -maxdepth 2 -name \(shellQuote(pattern)) 2>/dev/null | head -60"
            let out = await shell.run(command)
            return out.stdout.isEmpty
                ? "No matches for \(pattern) under \(root)."
                : out.stdout

        // — shell —
        case "shell.exec":
            guard let command = str("command") else { throw Bad.missing("command") }
            let out = await shell.run(command, cwd: str("cwd") ?? bot.workspace?.path,
                                      timeout: TimeInterval(int("timeout") ?? 120))
            return format(out)
        case "shell.start_process":
            guard let command = str("command") else { throw Bad.missing("command") }
            let handle = try await shell.start(command, cwd: str("cwd") ?? bot.workspace?.path, name: str("name"))
            return "started as \(handle)"
        case "shell.read_process":
            guard let handle = str("handle") else { throw Bad.missing("handle") }
            return await shell.read(handle)
        case "shell.kill_process":
            guard let handle = str("handle") else { throw Bad.missing("handle") }
            return await shell.kill(handle)

        // — computer, both our names and Gemini's predefined ones —
        case "computer.screenshot", "take_screenshot":
            _ = try await computer.screenshot()
            return "captured"
        case "computer.state":
            return await computer.state()
        case "computer.accessibility_tree":
            return await computer.accessibilityTree()
        case "computer.click", "click_at", "click":
            guard let x = int("x"), let y = int("y") else { throw Bad.missing("x and y") }
            try await computer.click(x: x, y: y)
            return "clicked (\(x),\(y))"
        case "double_click", "double_click_at":
            guard let x = int("x"), let y = int("y") else { throw Bad.missing("x and y") }
            try await computer.click(x: x, y: y, button: .left, clicks: 2)
            return "double-clicked (\(x),\(y))"
        case "right_click", "right_click_at":
            guard let x = int("x"), let y = int("y") else { throw Bad.missing("x and y") }
            try await computer.click(x: x, y: y, button: .right)
            return "right-clicked (\(x),\(y))"
        case "move":
            guard let x = int("x"), let y = int("y") else { throw Bad.missing("x and y") }
            try await computer.moveMouse(x: x, y: y)
            return "moved to (\(x),\(y))"
        case "drag_and_drop":
            guard let sx = int("start_x"), let sy = int("start_y"),
                  let ex = int("end_x"), let ey = int("end_y") else { throw Bad.missing("start and end coordinates") }
            try await computer.dragAndDrop(fromX: sx, fromY: sy, toX: ex, toY: ey)
            return "dragged (\(sx),\(sy)) → (\(ex),\(ey))"
        case "computer.type", "type":
            guard let text = str("text") else { throw Bad.missing("text") }
            try await computer.type(text, pressEnter: (action.arguments["press_enter"] as? Bool) ?? false)
            return "typed \(text.count) characters"
        case "computer.key", "press_key":
            guard let key = str("key") ?? str("keys") else { throw Bad.missing("key") }
            try await computer.pressKey(key)
            return "pressed \(key)"
        case "hotkey":
            let keys = (action.arguments["keys"] as? [String]) ?? (str("keys")?.components(separatedBy: "+") ?? [])
            guard !keys.isEmpty else { throw Bad.missing("keys") }
            try await computer.hotkey(keys)
            return "pressed \(keys.joined(separator: "+"))"
        case "scroll":
            try await computer.scroll(dx: int("dx") ?? 0, dy: int("dy") ?? int("amount") ?? -120)
            return "scrolled"
        case "computer.launch_app":
            guard let name = str("name") else { throw Bad.missing("name") }
            return try await computer.launchApp(name)
        case "wait":
            let seconds = int("seconds") ?? 1
            try await Task.sleep(for: .seconds(min(seconds, 10)))
            return "waited \(seconds)s"

        // — research —
        //
        // These were previously advertised and unimplemented, so the model chose them and got
        // "there is no tool called web.search". A tool that exists in the catalogue and throws
        // is the same defect as a button that does nothing.
        case "web.search", "web.open":
            let query = str("query") ?? str("url") ?? ""
            guard !query.isEmpty else { throw Bad.missing("query or url") }
            if let owner = await capabilities.providerOwning(operation: "perplexity_search") {
                return try await owner.provider.invoke(
                    operation: action.name == "web.open" ? "perplexity_ask" : "perplexity_search",
                    arguments: ["query": query])
            }
            switch await capabilities.load("research.perplexity") {
            case .loaded:
                if let owner = await capabilities.providerOwning(operation: "perplexity_search") {
                    return try await owner.provider.invoke(operation: "perplexity_search",
                                                           arguments: ["query": query])
                }
                return "Web search is not available right now."
            case .unavailable(let why):
                return "No web search is connected: \(why). Say so rather than guessing an answer."
            }

        // — memory —
        case "memory.search":
            let query = (str("query") ?? "").lowercased()
            let hits = bot.memory.filter {
                query.isEmpty || $0.text.lowercased().contains(query) || $0.reason.lowercased().contains(query)
            }
            return hits.isEmpty
                ? "Nothing remembered about that yet."
                : hits.map { "- \($0.text)" + ($0.reason.isEmpty ? "" : " (\($0.reason))") }
                       .joined(separator: "\n")

        case "memory.save":
            guard let text = str("text") else { throw Bad.missing("text") }
            let note = MemoryNote(text: text, reason: str("reason") ?? "")
            learned.append(note)
            return "Noted."

        // — capability discovery —
        case "capability.search":
            guard let query = str("query") else { throw Bad.missing("query") }
            let found = await capabilities.search(query)
            guard !found.isEmpty else {
                return "Nothing matches \"\(query)\". Say so plainly rather than inventing a way to do it."
            }
            return found.map { entry in
                let mark = entry.status == .healthy ? "" : " [\(entry.status.displayName)]"
                return "\(entry.capability.id)\(mark) — \(entry.capability.summary)"
            }.joined(separator: "\n")

        case "capability.load":
            guard let id = str("id") else { throw Bad.missing("id") }
            switch await capabilities.load(id) {
            case .loaded(let capability):
                return "Loaded \(capability.id). You can now call: \(capability.operations.joined(separator: ", "))"
            case .unavailable(let why):
                return "Cannot use \(id): \(why). Tell the user what needs connecting rather than working around it."
            }

        default:
            // Anything a loaded capability owns — every MCP tool arrives here.
            if let owner = await capabilities.providerOwning(operation: action.name) {
                return try await owner.provider.invoke(operation: action.name, arguments: action.arguments)
            }
            throw Bad.unknownTool(action.name)
        }
    }

    public enum Bad: LocalizedError {
        case missing(String)
        case unknownTool(String)
        public var errorDescription: String? {
            switch self {
            case .missing(let what):   return "That call was missing \(what)."
            case .unknownTool(let n):  return "There is no tool called \(n)."
            }
        }
    }

    // MARK: - Observation

    /// Climb the ladder only as far as needed. See `docs/HARNESS.md` layer 6.
    private func observe(quiet: Bool = false, emit: (@Sendable (Event) -> Void)? = nil) async -> String {
        var parts = [await computer.state()]
        if contract.urgency.budget.observationDepth != .shallow {
            parts.append(await computer.accessibilityTree())
        }
        let processes = await shell.list()
        if processes != "no processes running" { parts.append("processes:\n" + processes) }

        let text = parts.joined(separator: "\n\n")
        lastObservation = text
        if !quiet { emit?(.observed(text)) }
        return text
    }

    // MARK: - Verification

    private func checkCriteria() async -> [String] {
        var outstanding: [String] = []
        for index in contract.successCriteria.indices {
            guard !contract.successCriteria[index].isVerified else { continue }
            let result = await verifier.verify(contract.successCriteria[index], using: shell)
            switch result {
            case .passed(let evidence):
                contract.successCriteria[index].verifiedAt = Date()
                contract.successCriteria[index].evidence = evidence
                await trace.record(.init(kind: .verification, summary: "verified: \(contract.successCriteria[index].statement)"))
            case .failed(let reason), .indeterminate(let reason):
                outstanding.append("\(contract.successCriteria[index].statement) — \(reason)")
            }
        }
        return outstanding
    }

    // MARK: - Prompt

    private func systemPrompt(exposed: [ToolDescriptor]) -> String {
        var sections: [String] = []

        if !bot.persona.isEmpty { sections.append(bot.persona) }

        sections.append("""
            YOUR OBJECTIVE
            \(contract.objective)

            You own this outcome. You are finished when every success criterion below has \
            evidence, not when you have explained what is wrong.
            """)

        if !contract.successCriteria.isEmpty {
            sections.append("SUCCESS CRITERIA\n" + contract.successCriteria
                .map { "- \($0.statement)" }.joined(separator: "\n"))
        }

        sections.append("HOW HARD TO PUSH\n" + contract.urgency.doctrine)
        sections.append("CHOOSING HOW TO ACT\n" + SurfaceSelector.doctrine)

        sections.append("""
            ACTING WITHOUT ASKING
            If an action is reversible, within what you are authorised for, and clearly \
            advances the objective, just do it. Do not ask permission for work you have \
            already been given. Ask only when something cannot be undone, costs money, \
            leaves this machine, or when two readings of the request would lead somewhere \
            materially different.

            Prefer taking a safe action that tells you something over reasoning about what \
            might be true. If you think the server might not be running, check. If you think \
            a test fails, run it.
            """)

        if !contract.constraints.isEmpty {
            sections.append("NEVER\n" + contract.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }

        if contract.authority.selfRepair {
            sections.append("""
                FIXING YOUR OWN ENVIRONMENT
                You may do these without asking: \
                \(Authority.selfRepairActions.sorted().joined(separator: "; ")).
                """)
        }

        sections.append("""
            HOW TO WRITE
            Terse, first person, and carrying decisions. Say what you did, what you found, and \
            what you are doing about it. Do not narrate your reasoning, do not list options you \
            are not taking, and do not ask for permission you already have.
            """)

        return sections.joined(separator: "\n\n")
    }

    private func usesComputer(_ exposed: [ToolDescriptor]) -> Bool {
        exposed.contains { $0.domain == .computer } && brain.canDriveComputer
    }

    // MARK: - Finish

    private func finish(_ closure: TaskContract.Closure, note: String,
                        alreadySaid: Bool = false,
                        emit: @escaping @Sendable (Event) -> Void) async {
        contract.closedAt = Date()
        contract.closure = closure
        await shell.killAll()   // never leave a server orphaned behind a finished run
        await trace.record(.init(kind: .runFinished, summary: "\(closure.rawValue): \(note)"))
        await trace.finish(.init(
            botID: bot.id, botName: bot.name, conversationID: contract.conversationID,
            goal: contract.objective, brain: brain.name,
            environment: bot.environment.rawValue, startedAt: contract.startedAt,
            outcome: closure == .succeeded ? .succeeded : .failed,
            totalCostUSD: contract.spend.usd,
            totalPromptTokens: contract.spend.promptTokens,
            totalCompletionTokens: contract.spend.completionTokens,
            closingNote: note
        ))
        emit(.finished(closure, note: alreadySaid ? "" : note))
    }

    // MARK: - Small helpers

    private func describe(arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "" }
        let pairs = arguments.keys.sorted().map { key -> String in
            let value = arguments[key]
            let text = (value as? String) ?? String(describing: value ?? "")
            return "\(key)=\(text.count > 300 ? String(text.prefix(300)) + "…" : text)"
        }
        return pairs.joined(separator: " ")
    }

    private func describe(_ signal: StuckDetector.Signal) -> String {
        switch signal {
        case .repeatingAction(let a):     return "you have run \(a) several times with the same result"
        case .repeatingObservation:       return "the screen has not changed across several steps"
        case .repeatingError(let e):      return "the same error keeps coming back: \(e)"
        case .noStateChange(let steps):   return "nothing has changed in \(steps) steps"
        case .oscillating:                return "you are alternating between two states"
        }
    }

    private func format(_ out: CommandOutput) -> String {
        var parts: [String] = []
        if !out.stdout.isEmpty { parts.append(out.stdout) }
        if !out.stderr.isEmpty { parts.append("[stderr] " + out.stderr) }
        if out.exitCode != 0 { parts.append("[exit \(out.exitCode)]") }
        return parts.isEmpty ? "(no output, exit 0)" : parts.joined(separator: "\n")
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
