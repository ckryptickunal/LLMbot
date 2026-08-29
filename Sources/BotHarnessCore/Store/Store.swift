import Foundation
import Observation

/// The single owner of application state.
///
/// Every mutation goes through here. Views observe it; the runtime asks it for things and
/// tells it what happened. Nothing else writes to disk.
///
/// Persistence is one JSON document rewritten atomically on change, debounced. For a single
/// user with tens of bots and thousands of messages this is fast enough by a wide margin, and
/// it buys something worth more than speed: the user can open `state.json`, read it, edit it,
/// and back it up, without this app existing. A database would take that away for a
/// performance win nobody would notice.
///
/// Revisit if a single conversation exceeds roughly 10,000 messages or the document exceeds
/// ~50 MB, at which point message bodies should move to per-conversation files.
@MainActor
@Observable
public final class Store {

    // MARK: State

    public private(set) var bots: [Bot] = []
    public private(set) var conversations: [Conversation] = []

    /// Global rules, applied to every bot in addition to that bot's own.
    public private(set) var globalRules: [PermissionRule] = []

    /// Which conversation the UI is showing.
    public var selection: UUID?

    // MARK: Lifecycle

    public init(loadingFrom url: URL = Paths.state) {
        self.stateURL = url
        load()
    }

    private let stateURL: URL
    private var saveTask: Task<Void, Never>?

    // MARK: Reading

    public func bot(_ id: UUID?) -> Bot? {
        guard let id else { return nil }
        return bots.first { $0.id == id }
    }

    public func conversation(_ id: UUID?) -> Conversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }

    /// Conversations in sidebar order: most recently active first, which is what a messaging
    /// app does and what makes the list feel alive rather than filed.
    public var sortedConversations: [Conversation] {
        conversations.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Every rule that governs this bot, strongest-first. Global rules and the bot's own are
    /// pooled deliberately: a user who writes "never spend money" once should not have to
    /// write it again for every bot they create.
    public func rules(for botID: UUID) -> [PermissionRule] {
        let own = bot(botID)?.rules ?? []
        return (globalRules + own).sorted { $0.behaviour.strength < $1.behaviour.strength }
    }

    // MARK: Writing — bots

    @discardableResult
    public func createBot(name: String, persona: String = "") -> Bot {
        var bot = Bot(name: name)
        bot.persona = persona
        bot.avatar.hue = Double(abs(bot.id.hashValue % 360)) / 360.0
        bots.append(bot)

        // A bot with no conversation is a bot you cannot talk to, so they are created together.
        let conversation = Conversation(participants: [bot.id])
        conversations.append(conversation)
        selection = conversation.id

        scheduleSave()
        return bot
    }

    public func update(_ bot: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[i] = bot
        scheduleSave()
    }

    public func deleteBot(_ id: UUID) {
        bots.removeAll { $0.id == id }
        // A channel survives losing one member; a chat does not.
        conversations.removeAll { $0.participants == [id] }
        for i in conversations.indices {
            conversations[i].participants.removeAll { $0 == id }
        }
        scheduleSave()
    }

    // MARK: Writing — conversations

    @discardableResult
    public func createChannel(title: String, participants: [UUID], lead: UUID? = nil) -> Conversation {
        var c = Conversation(participants: participants)
        c.title = title
        c.leadBot = lead
        conversations.append(c)
        selection = c.id
        scheduleSave()
        return c
    }

    @discardableResult
    public func append(_ message: Message, to conversationID: UUID) -> UUID {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return message.id
        }
        conversations[i].messages.append(message)
        conversations[i].lastActivity = message.timestamp
        scheduleSave()
        return message.id
    }

    /// Replace a message in place. Used constantly while streaming: the assistant's reply is
    /// appended once and then rewritten as tokens arrive, rather than appending a message per
    /// token.
    public func replace(_ message: Message, in conversationID: UUID) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == message.id })
        else { return }
        conversations[c].messages[m] = message
        conversations[c].lastActivity = Date()
        // Deliberately not saved on every token — see `scheduleSave`.
        scheduleSave()
    }

    // MARK: Writing — rules

    public func addGlobalRule(_ rule: PermissionRule) {
        globalRules.append(rule)
        scheduleSave()
    }

    public func addRule(_ rule: PermissionRule, to botID: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == botID }) else { return }
        bots[i].rules.append(rule)
        scheduleSave()
    }

    // MARK: Persistence

    private struct Document: Codable {
        var version: Int = 1
        var bots: [Bot]
        var conversations: [Conversation]
        var globalRules: [PermissionRule]
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else {
            seedFirstRun()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let doc = try? decoder.decode(Document.self, from: data) else {
            // A corrupt state file is moved aside rather than deleted. Losing a user's bots
            // silently is unacceptable; losing them loudly with a copy on disk is survivable.
            let backup = stateURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            seedFirstRun()
            return
        }
        bots = doc.bots
        conversations = doc.conversations
        globalRules = doc.globalRules
        selection = sortedConversations.first?.id
    }

    /// Debounced so that streaming a reply does not write the whole document per token.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        let doc = Document(bots: bots, conversations: conversations, globalRules: globalRules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(doc) else { return }

        // Atomic: write beside the target, then rename. A crash mid-write leaves the previous
        // good document intact rather than a truncated one.
        let tmp = stateURL.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(stateURL, withItemAt: tmp)
    }

    // MARK: First run

    /// What a brand-new install contains. Not an empty list — an empty app teaches nobody
    /// what it is for. One bot, already useful, whose persona shows what a good persona
    /// looks like.
    private func seedFirstRun() {
        var starter = Bot(name: "Harness")
        starter.label = "General"
        starter.persona = """
            Kunal's general-purpose bot. Knows its way around his Mac and his projects on \
            ~/Desktop. Reads before it writes, runs things to check they work rather than \
            assuming, and says plainly when something failed. Reports what it did and what \
            it concluded, not how it thought.
            """
        starter.brain = .gemini(model: GeminiAdapter.defaultModel)
        starter.environment = .thisMac
        bots = [starter]

        let c = Conversation(participants: [starter.id])
        conversations = [c]
        selection = c.id

        // The floor is built in and separate from these; these are the defaults a first-time
        // user gets so that "ask me before anything scary" is true before they configure it.
        globalRules = [
            PermissionRule(whenBotWantsTo: "read files, search, or look something up on the web",
                           behaviour: .allowAutomatically),
            PermissionRule(whenBotWantsTo: "change files inside the folder I gave it",
                           behaviour: .allowAutomatically),
            PermissionRule(whenBotWantsTo: "run a shell command that changes anything",
                           behaviour: .askFirst),
            PermissionRule(whenBotWantsTo: "send a message, email, or post on my behalf",
                           behaviour: .askFirst),
            PermissionRule(whenBotWantsTo: "spend money",
                           behaviour: .neverAllow),
        ]
        saveNow()
    }
}
