import AppKit
import BotHarnessCore
import Foundation
import Observation

/// Bridges the agent loop to the interface.
///
/// Owns the running loops, turns their events into messages in the conversation, and holds the
/// approval prompts the user has to answer. The views never see a loop; the loop never sees a
/// view.
@MainActor
@Observable
final class BotRunner {

    private let store: Store
    private let registry = ToolRegistry()

    /// One capability registry for the whole app, so MCP servers are connected once and
    /// their connections are reused across runs rather than respawned per message.
    private let capabilities = CapabilityRegistry()
    private var capabilitiesReady = false

    private var loops: [UUID: AgentLoop] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Approval prompts waiting on the user, keyed by the message showing them.
    private(set) var awaiting: [UUID: UUID] = [:]

    /// What the agent is doing right now, per conversation.
    ///
    /// Kept separately from the message timeline on purpose. Observations, model calls and
    /// verification passes happen several times per tool call; posting each as a message would
    /// bury the conversation they are supposed to explain. They belong behind a disclosure the
    /// user opens when they want to know, and ignores when they do not.
    private(set) var live: [UUID: [LiveStep]] = [:]

    struct LiveStep: Identifiable, Sendable {
        let id = UUID()
        var at = Date()
        var kind: Kind
        var text: String
        var detail: String?

        enum Kind: Sendable {
            case thinking, observing, tool, result, verifying, approval, finished, failed

            var icon: String {
                switch self {
                case .thinking:  return "brain"
                case .observing: return "eye"
                case .tool:      return "wrench.and.screwdriver"
                case .result:    return "arrow.turn.down.right"
                case .verifying: return "checkmark.seal"
                case .approval:  return "hand.raised"
                case .finished:  return "flag.checkered"
                case .failed:    return "exclamationmark.triangle"
                }
            }
        }
    }

    private func note(_ kind: LiveStep.Kind, _ text: String, detail: String? = nil, in id: UUID) {
        var steps = live[id] ?? []
        steps.append(LiveStep(kind: kind, text: text, detail: detail))
        // A long run can produce hundreds of steps; keep the tail, which is what anyone
        // watching actually wants to see.
        if steps.count > 300 { steps.removeFirst(steps.count - 300) }
        live[id] = steps
    }

    func clearLive(_ id: UUID) { live[id] = [] }

    init(store: Store) {
        self.store = store
        Task { await capabilities.registerConfiguredMCPServers() }

        // Every MCP server is a child process this app spawned. `CapabilityRegistry.shutdown`
        // existed to stop them and had no callers, so quitting left one process per connected
        // server running with nothing attached to its pipes — invisible unless you go looking
        // in Activity Monitor, and cumulative across launches.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [capabilities] _ in
            // Synchronous on purpose: the process is about to go, and a detached Task is not
            // guaranteed to run at all. Each `disconnect` terminates a child and returns.
            let done = DispatchSemaphore(value: 0)
            Task { await capabilities.shutdown(); done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
        // Machines belonging to bots that no longer exist. Only ever names this app assigns,
        // and only when no live bot owns them, so nothing else on the Mac is a candidate.
        // Silent when the container tool is not installed, which is the ordinary case.
        let owners = store.bots.map(\.id)
        Task { await ContainerRuntime.shared.collectGarbage(keeping: owners) }
    }

    /// Whether a bot can currently be given its own computer, for the settings picker.
    func containerAvailability() async -> ContainerRuntime.Availability {
        await ContainerRuntime.shared.availability()
    }

    func isRunning(_ conversationID: UUID) -> Bool { tasks[conversationID] != nil }

    // MARK: - Start

    /// Whether a message can be sent right now. The composer asks before enabling Return.
    ///
    /// A conversation runs one loop at a time. Without this, sending mid-run replaced the loop
    /// and task handles while the first loop kept running: two loops interleaving messages into
    /// one transcript, Stop reaching only the newer one, and the first one's completion nilling
    /// out the second one's handles on its way out.
    func canSend(in conversationID: UUID) -> Bool {
        !isRunning(conversationID) && store.conversation(conversationID) != nil
    }

    func send(_ text: String, in conversationID: UUID) {
        guard canSend(in: conversationID),
              let conversation = store.conversation(conversationID),
              let bot = store.bot(conversation.participants.first)
        else { return }

        store.append(Message(author: nil, body: .text(text)), to: conversationID)

        let contract = Self.contract(for: text, bot: bot, conversation: conversationID,
                                     attachments: conversation.attachments)
        let brain = Self.brain(for: bot)
        let trace = TraceWriter(root: Paths.traces, botName: bot.name)
        let loop = AgentLoop(contract: contract, bot: bot, brain: brain,
                             registry: registry, trace: trace,
                             rules: store.rules(for: bot.id),
                             capabilities: capabilities)
        loops[conversationID] = loop

        live[conversationID] = []
        tasks[conversationID] = Task { [weak self] in
            for await event in await loop.run(goal: text) {
                await self?.handle(event, bot: bot, conversationID: conversationID)
            }
            // Persist what the run learned. Until now `memoryLearned()` existed and had zero
            // callers, so every note a bot saved was collected into a per-run array and thrown
            // away when the loop was deallocated — the model was told "Noted." and nothing was.
            await self?.persistMemory(from: loop, botID: bot.id)
            self?.tasks[conversationID] = nil
            self?.loops[conversationID] = nil
        }
    }

    /// Fold a finished run's notes into the bot the user actually keeps.
    ///
    /// Deliberately does not merge blindly: a note that supersedes an earlier one removes it, a
    /// note the run asked to forget is dropped, and exact duplicates are collapsed. Appending
    /// without this is how a memory list becomes a hundred restatements of the same fact and
    /// stops being something anyone reads.
    private func persistMemory(from loop: AgentLoop, botID: UUID) async {
        let changes = await loop.memoryChanges()
        guard !changes.learned.isEmpty || !changes.forgotten.isEmpty else { return }
        guard var bot = store.bot(botID) else { return }

        bot.memory.removeAll { changes.forgotten.contains($0.id) }
        let superseded = Set(changes.learned.compactMap { $0.supersedes })
        bot.memory.removeAll { superseded.contains($0.id) }

        for note in changes.learned {
            let already = bot.memory.contains {
                $0.text.caseInsensitiveCompare(note.text) == .orderedSame
            }
            if !already { bot.memory.append(note) }
        }
        // A cap, because nothing else bounds this. The user can see and delete notes, but a bot
        // that saves one a run would otherwise grow its own prompt forever.
        //
        // `suffix(200)` was wrong in the way that matters: new notes are appended, so keeping the
        // last 200 keeps the bot's most recent guesses and evicts the notes the person actually
        // wrote. What the user confirmed is the last thing that should go.
        if bot.memory.count > 200 {
            let mine = bot.memory.filter { $0.confirmedByUser || $0.provenance == .user }
            let rest = bot.memory.filter { !($0.confirmedByUser || $0.provenance == .user) }
            bot.memory = mine + rest.suffix(max(0, 200 - mine.count))
        }
        store.update(bot)
    }

    func stop(_ conversationID: UUID) {
        tasks[conversationID]?.cancel()
        tasks[conversationID] = nil
        loops[conversationID] = nil
        settleOpenWork(in: conversationID)
        store.append(Message(body: .notice("Stopped.")), to: conversationID)
    }

    /// Everything a stopped or vanished run leaves behind.
    ///
    /// Cancelling the task stops the work; it does not correct the record of it. Without this,
    /// a stopped run leaves tool cards saying "Running" for ever, an approval card whose
    /// buttons are wired to a loop that no longer exists, and an `awaiting` entry that keeps
    /// the composer's mascot hopping for an answer nobody can give.
    private func settleOpenWork(in conversationID: UUID) {
        for (messageID, id) in awaiting where id == conversationID {
            awaiting.removeValue(forKey: messageID)
        }
        guard let conversation = store.conversation(conversationID) else { return }
        for message in conversation.messages {
            switch message.body {
            case .toolUse(var activity) where activity.isOpen:
                activity.status = .interrupted
                activity.finishedAt = Date()
                var updated = message
                updated.body = .toolUse(activity)
                store.replace(updated, in: conversationID)

            case .computer(var activity) where activity.status == .running
                                           || activity.status == .waitingForApproval:
                activity.status = .interrupted
                activity.awaitingHuman = false
                activity.finishedAt = Date()
                var updated = message
                updated.body = .computer(activity)
                store.replace(updated, in: conversationID)

            case .approval(var request) where request.answer == nil:
                request.answer = .expired
                request.answeredAt = Date()
                var updated = message
                updated.body = .approval(request)
                store.replace(updated, in: conversationID)

            default:
                break
            }
        }
    }

    /// Tear down everything belonging to conversations that are being deleted.
    ///
    /// Called before the store removes them. A loop left running against a deleted
    /// conversation writes into nothing and never stops.
    func discard(_ conversationIDs: [UUID], bots discardedBots: [UUID] = []) {
        for id in conversationIDs {
            tasks[id]?.cancel()
            tasks[id] = nil
            loops[id] = nil
            live[id] = nil
            for (messageID, owner) in awaiting where owner == id {
                awaiting.removeValue(forKey: messageID)
            }
        }
        // A deleted bot's computer goes with it. Left behind it is a running Linux VM with a
        // mount into a folder whose owner no longer exists — invisible in this app, and costing
        // memory until the Mac restarts.
        for botID in discardedBots {
            Task { await ContainerRuntime.shared.destroy(botID: botID) }
        }
    }

    /// The last thing the user actually asked for, for the retry button on a failure.
    func lastUserRequest(in conversationID: UUID) -> String? {
        guard let conversation = store.conversation(conversationID) else { return nil }
        for message in conversation.messages.reversed() where message.author == nil {
            if case .text(let text) = message.body, !text.isEmpty { return text }
        }
        return nil
    }

    /// The user answered an approval card.
    func answer(_ answer: ApprovalRequest.Answer, for messageID: UUID, in conversationID: UUID) {
        // The run may be gone — the app was relaunched, or the user pressed Stop. The card
        // must still resolve, because the alternative is three enabled buttons that do
        // nothing at all and can never be dismissed.
        guard let loop = loops[conversationID] else {
            settleOpenWork(in: conversationID)
            return
        }

        if var conversation = store.conversation(conversationID),
           let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
           case .approval(var request) = conversation.messages[index].body {
            request.answer = answer
            request.answeredAt = Date()
            var message = conversation.messages[index]
            message.body = .approval(request)
            store.replace(message, in: conversationID)

            // "Always" writes a rule, so the user is not asked the same thing twice. Both
            // directions: "never allow this" is as much an answer as "always allow this", and
            // a system that can only be loosened is not a permission system.
            //
            // Scoped to the bot whose chat it was answered in, not to the whole roster. It used
            // to call addGlobalRule, so allowing one action once inside one bot's conversation
            // silently granted it to every bot the user owned — including ones created later. The
            // button says "Always allow" beside a named bot's message, and nothing on screen
            // suggested it meant "always, for everyone", so the widest possible reading was the
            // one the code took. `Store.addRule(_:to:)` already existed for this and had no
            // callers at all.
            //
            // A deny is a different case and stays global on purpose: the user saying "never do
            // this" is a statement about the action, and narrowing it to one bot would mean the
            // next bot asks them the same question again.
            if answer.writesRule {
                let rule = PermissionRule(
                    whenBotWantsTo: request.summary,
                    behaviour: answer == .allowedAlways ? .allowAutomatically : .neverAllow,
                    createdFromPrompt: true)
                if answer == .allowedAlways, let botID = conversation.participants.first {
                    store.addRule(rule, to: botID)
                } else {
                    // A channel has several participants and no single owner for the grant, so a
                    // rule written there stays global rather than being attributed to whichever
                    // bot happens to be listed first.
                    store.addGlobalRule(rule)
                }
            }
        }

        awaiting.removeValue(forKey: messageID)
        Task { await loop.answerApproval(answer) }
    }

    // MARK: - Events → messages

    private func handle(_ event: AgentLoop.Event, bot: Bot, conversationID id: UUID) {
        switch event {
        case .thinking:
            note(.thinking, "Thinking", in: id)

        case .verifying:
            note(.verifying, "Checking whether it is actually done", in: id)

        case .observed(let observation):
            let first = observation.split(separator: "\n").first.map(String.init) ?? "Looked at the computer"
            note(.observing, "Looked at the computer", detail: first, in: id)

        case .screenshot(let path, let caption):
            note(.observing, caption, detail: "screenshot", in: id)
            store.append(Message(author: bot.id,
                                 body: .screenshot(Screenshot(path: path, caption: caption))),
                         to: id)

        case .said(let text):
            note(.thinking, "Replied", detail: String(text.prefix(200)), in: id)
            store.append(Message(author: bot.id, body: .text(text)), to: id)

        case .toolStarted(let toolID, let tool, let summary, let intent):
            // The intent is the model's own stated reason for this step — the closest thing
            // to visible thinking that the API actually provides.
            note(.tool, intent ?? summary, detail: tool, in: id)
            let activity = ToolActivity(id: UUID(), tool: tool,
                                        summary: intent ?? summary,
                                        detail: summary, status: .running,
                                        traceID: toolID)
            store.append(Message(author: bot.id, body: .toolUse(activity)), to: id)

        case .toolFinished(let toolID, let output, let ok):
            note(ok ? .result : .failed,
                 ok ? "Result" : "That failed",
                 detail: String(output.prefix(300)), in: id)
            guard var conversation = store.conversation(id),
                  let index = conversation.messages.lastIndex(where: {
                      if case .toolUse(let a) = $0.body { return a.traceID == toolID }
                      return false
                  }),
                  case .toolUse(var activity) = conversation.messages[index].body
            else { return }
            activity.status = ok ? .done : .failed
            activity.output = String(output.prefix(4000))
            activity.finishedAt = Date()
            var message = conversation.messages[index]
            message.body = .toolUse(activity)
            store.replace(message, in: id)

        case .needsApproval(let request):
            note(.approval, "Waiting for you", detail: request.summary, in: id)
            let message = Message(author: bot.id, body: .approval(request))
            store.append(message, to: id)
            awaiting[message.id] = id
            notify(.needsApproval, request.summary, bot: bot, in: id)

        case .finished(let closure, let closingNote):
            if closure == .succeeded { Task { await self.maybeSelfDescribe(bot: bot, in: id) } }
            notify(closure == .succeeded ? .finished : .failed,
                   closingNote.isEmpty ? closure.rawValue : closingNote, bot: bot, in: id)
            note(closure == .succeeded ? .finished : .failed,
                 closure == .succeeded ? "Done" : closure.rawValue,
                 detail: closingNote.isEmpty ? nil : String(closingNote.prefix(200)), in: id)
            let note = closingNote
            switch closure {
            case .succeeded:
                // An empty note means the bot already said its piece this turn.
                if !note.isEmpty {
                    store.append(Message(author: bot.id, body: .text(note)), to: id)
                }
            case .escalated:
                store.append(Message(author: bot.id, body: .notice(note)), to: id)
            case .budgetExhausted:
                store.append(Message(author: bot.id, body: .notice(note)), to: id)
            default:
                store.append(Message(author: bot.id, body: .failure(note)), to: id)
            }

        case .failed(let message):
            note(.failed, "Failed", detail: message, in: id)
            store.append(Message(author: bot.id, body: .failure(message)), to: id)
            notify(.failed, message, bot: bot, in: id)
        }
    }

    /// Notify, unless the user is demonstrably already watching this conversation.
    private func notify(_ kind: Notifier.Kind, _ body: String, bot: Bot, in id: UUID) {
        guard bot.notifies,
              !Notifier.isWatching(id, selection: store.selection)
        else { return }
        Notifier.post(kind, body: "\(bot.name): \(body)", conversationID: id)
    }

    // MARK: - The bot writing itself

    /// After a successful run, let the bot bring its own name and description up to date.
    ///
    /// This is the behaviour the user noticed in Grok Bot: the description is not something you
    /// type, it is what the bot has learned it does. Runs quietly in the background — a failure
    /// here must never surface, because nobody asked for it and it is not what they were doing.
    private func maybeSelfDescribe(bot: Bot, in conversationID: UUID) async {
        guard let conversation = store.conversation(conversationID),
              SelfDescription.shouldRegenerate(bot: bot, conversation: conversation),
              let current = store.bot(bot.id)
        else { return }

        let history = SelfDescription.history(of: conversation)
        guard !history.isEmpty else { return }

        let brain = Self.brain(for: current)
        guard await brain.isConfigured() else { return }

        var updated = current

        // Name first, and only while it is still the placeholder — renaming a bot the user has
        // been talking to for a week would be disorienting even if the new name were better.
        if updated.nameIsAuto, Self.isPlaceholderName(updated.name) {
            if let reply = try? await brain.step(BrainRequest(
                system: "You name things well. Answer with the name only.",
                turns: [.init(role: .user, text: SelfDescription.namePrompt(history: history))],
                tools: [])),
               let text = reply.text,
               let name = SelfDescription.tidy(text, maxLength: 28) {
                updated.name = name
            }
        }

        if let reply = try? await brain.step(BrainRequest(
            system: "You write short, concrete descriptions of what someone does. Answer with the description only.",
            turns: [.init(role: .user, text: SelfDescription.describePrompt(
                bot: updated, history: history,
                existing: updated.persona.isEmpty ? nil : updated.persona))],
            tools: [])),
           let text = reply.text,
           let persona = SelfDescription.tidy(text, maxLength: 600),
           // A description that talks about permissions is not a description. Keeping the old one
           // is the safe failure here: a persona is injected into every future system prompt, so
           // accepting "never asks before deleting" would write a permission into the bot's own
           // standing orders without the user ever seeing a dialog.
           SelfDescription.isAcceptable(persona) {
            updated.persona = persona
            updated.describedAtTurn = conversation.messages.filter { $0.author == nil }.count
        }

        guard updated.name != current.name || updated.persona != current.persona else { return }
        store.update(updated)
        note(.finished, "Updated its own description", detail: updated.persona, in: conversationID)
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "new bot" || lowered == "harness" || lowered.isEmpty
    }

    // MARK: - Contract construction

    /// Turn a sentence into a contract.
    ///
    /// The user types "fix the login bug", not an objective with success criteria. Normalising
    /// it here is what makes the difference between an agent that explains a problem and one
    /// that owns fixing it — see `docs/TASK-CONTRACT.md`.
    ///
    /// This is currently a deterministic first pass. Inferring good criteria is genuinely a
    /// model's job and belongs here next; what is deliberate is that a run with *no* criteria
    /// is treated as unverifiable rather than as trivially complete.
    static func contract(for goal: String, bot: Bot, conversation: UUID,
                         attachments: [Attachment] = []) -> TaskContract {
        var contract = TaskContract(botID: bot.id, conversationID: conversation, objective: goal)

        let lower = goal.lowercased()
        if ["urgent", "asap", "right now", "broken", "down", "failing", "critical"].contains(where: lower.contains) {
            contract.urgency = .high
        }

        contract.autonomy = bot.defaultAutonomy

        // The list itself lives in `Authority.forWorkspace`, in the core, so a test can assert
        // on the authority the app actually ships rather than on one it built for itself.
        // Attachments are what the user dropped into this conversation: without them the drop
        // gesture reaches the boundary and stops, which is how it shipped.
        contract.authority = .forWorkspace(bot.effectiveWorkspace.path, attachments: attachments)
        return contract
    }

    /// Which brain answers for this bot.
    ///
    /// Every case now returns the adapter it names. There is deliberately no `default` that
    /// substitutes Gemini: that is what this function used to do, and it meant a bot set to
    /// Claude Code answered as Gemini, failed with an error about a Gemini key the user had
    /// never been asked for, and had no way to find out why. Silently answering as something
    /// else is worse than not answering, because only one of the two is debuggable.
    ///
    /// The two brains without an adapter return `UnbuiltBrain`, which fails on the first call
    /// with a sentence naming the actual problem and the actual remedy.
    static func brain(for bot: Bot) -> any BrainAdapter {
        switch bot.brain {
        case .gemini(let model):
            return GeminiAdapter(model: model)

        case .claudeCLI(let model):
            // The workspace is passed through because the CLI is a coding brain and a coding
            // brain with no working directory is close to useless. See the adapter for what
            // that costs and which flag pays for it.
            return ClaudeCLIAdapter(model: model, workspace: bot.effectiveWorkspace.path)

        case .anthropic(let model):
            return UnbuiltBrain(
                label: "anthropic/\(model)",
                explanation: "This bot is set to \(model) through Anthropic's API, and this "
                           + "build has no adapter for it — an Anthropic key changes nothing "
                           + "until one exists. Pick Claude Code or Gemini in the brain menu "
                           + "next to the message box. Claude Code runs the same models on "
                           + "your subscription and needs no key.")

        case .openAI(let model):
            return UnbuiltBrain(
                label: "openai/\(model)",
                explanation: "This bot is set to \(model), and this build has no adapter for "
                           + "OpenAI — a key changes nothing until one exists. Pick Claude Code "
                           + "or Gemini in the brain menu next to the message box.")
        }
    }

    /// True when the selected brain will not answer at all.
    ///
    /// The name is older than the behaviour: nothing falls back to anything now. It still
    /// answers the question the composer's chip actually asks — "is the model on this button
    /// the one that will reply?" — so it kept its callers rather than churning them.
    static func isFallingBack(_ bot: Bot) -> Bool {
        switch bot.brain {
        case .gemini, .claudeCLI:  return false
        case .anthropic, .openAI:  return true
        }
    }
}

/// A brain that is named in the interface and does not exist yet.
///
/// It reports itself as configured and then throws. That reads backwards, and the alternative
/// is worse: `AgentLoop` answers a false `isConfigured()` with one fixed sentence — "… is not
/// set up. Add the key in Settings (⌘,)" — which for a missing adapter is a remedy that cannot
/// work. Sending the failure through `step()` instead is what lets the message say the true
/// thing, which is that no key will help and the user needs to choose a different brain.
struct UnbuiltBrain: BrainAdapter {
    let label: String
    let explanation: String

    var name: String { label }
    var canDriveComputer: Bool { false }

    func isConfigured() async -> Bool { true }

    func step(_ request: BrainRequest) async throws -> BrainResponse {
        throw Unavailable(explanation: explanation)
    }

    struct Unavailable: LocalizedError {
        let explanation: String
        var errorDescription: String? { explanation }
    }
}
