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
    }

    func isRunning(_ conversationID: UUID) -> Bool { tasks[conversationID] != nil }

    // MARK: - Start

    func send(_ text: String, in conversationID: UUID) {
        guard let conversation = store.conversation(conversationID),
              let bot = store.bot(conversation.participants.first)
        else { return }

        store.append(Message(author: nil, body: .text(text)), to: conversationID)

        let contract = Self.contract(for: text, bot: bot, conversation: conversationID)
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
            self?.tasks[conversationID] = nil
            self?.loops[conversationID] = nil
        }
    }

    func stop(_ conversationID: UUID) {
        tasks[conversationID]?.cancel()
        tasks[conversationID] = nil
        loops[conversationID] = nil
        store.append(Message(body: .notice("Stopped.")), to: conversationID)
    }

    /// The user answered an approval card.
    func answer(_ answer: ApprovalRequest.Answer, for messageID: UUID, in conversationID: UUID) {
        guard let loop = loops[conversationID] else { return }

        if var conversation = store.conversation(conversationID),
           let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
           case .approval(var request) = conversation.messages[index].body {
            request.answer = answer
            request.answeredAt = Date()
            var message = conversation.messages[index]
            message.body = .approval(request)
            store.replace(message, in: conversationID)

            // "Always" writes a rule, so the user is not asked the same thing twice.
            if answer == .allowedAlways || answer == .deniedAlways {
                store.addGlobalRule(PermissionRule(
                    whenBotWantsTo: request.summary,
                    behaviour: answer == .allowedAlways ? .allowAutomatically : .neverAllow,
                    createdFromPrompt: true))
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

        case .finished(let closure, let closingNote):
            if closure == .succeeded { Task { await self.maybeSelfDescribe(bot: bot, in: id) } }
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
        }
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
           let persona = SelfDescription.tidy(text, maxLength: 600) {
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
    static func contract(for goal: String, bot: Bot, conversation: UUID) -> TaskContract {
        var contract = TaskContract(botID: bot.id, conversationID: conversation, objective: goal)

        let lower = goal.lowercased()
        if ["urgent", "asap", "right now", "broken", "down", "failing", "critical"].contains(where: lower.contains) {
            contract.urgency = .high
        }

        contract.autonomy = bot.defaultAutonomy

        let workspace = bot.workspace?.path ?? NSHomeDirectory() + "/Desktop"
        contract.authority = Authority(
            readable: [workspace + "/**", NSHomeDirectory() + "/Desktop/**"],
            writable: [workspace + "/**"],
            granted: ["files.read", "files.write", "shell.exec", "git.read", "git.commit",
                      "web.search", "web.read", "browser.use", "computer.observe",
                      "computer.control", "memory.read", "memory.write"],
            requiresApproval: ["git.push", "files.delete"],
            selfRepair: true,
            maySpend: false
        )
        return contract
    }

    /// Which brain answers for this bot.
    /// Which brain answers for this bot.
    ///
    /// Only Gemini is implemented. The others are selectable but fall back, and the composer
    /// chip says so rather than showing a name that is not the one answering — a control that
    /// reports a state the system is not in is worse than one that admits the gap.
    static func brain(for bot: Bot) -> any BrainAdapter {
        switch bot.brain {
        case .gemini(let model): return GeminiAdapter(model: model)
        default:                 return GeminiAdapter()
        }
    }

    /// True when the selected brain is not the one that will actually answer.
    static func isFallingBack(_ bot: Bot) -> Bool {
        if case .gemini = bot.brain { return false }
        return true
    }
}
