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

    private var loops: [UUID: AgentLoop] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Approval prompts waiting on the user, keyed by the message showing them.
    private(set) var awaiting: [UUID: UUID] = [:]

    init(store: Store) { self.store = store }

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
                             rules: store.rules(for: bot.id))
        loops[conversationID] = loop

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
        case .thinking, .verifying, .observed, .screenshot:
            // Internal detail. Shown as activity state, not as timeline entries — a log of
            // every observation would bury the conversation it is supposed to explain.
            break

        case .said(let text):
            store.append(Message(author: bot.id, body: .text(text)), to: id)

        case .toolStarted(let toolID, let tool, let summary, let intent):
            let activity = ToolActivity(id: UUID(), tool: tool,
                                        summary: intent ?? summary,
                                        detail: summary, status: .running,
                                        traceID: toolID)
            store.append(Message(author: bot.id, body: .toolUse(activity)), to: id)

        case .toolFinished(let toolID, let output, let ok):
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
            let message = Message(author: bot.id, body: .approval(request))
            store.append(message, to: id)
            awaiting[message.id] = id

        case .finished(let closure, let note):
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
            store.append(Message(author: bot.id, body: .failure(message)), to: id)
        }
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
