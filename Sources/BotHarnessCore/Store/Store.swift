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

    /// Set when the state file could not be read and was set aside. The interface shows this
    /// once, because "your data is at this path" is the only useful thing to say and silence
    /// is indistinguishable from having lost it.
    public private(set) var loadFailure: LoadFailure?

    public struct LoadFailure: Equatable, Sendable {
        public let movedTo: URL
        public let reason: String
    }

    public func acknowledgeLoadFailure() { loadFailure = nil }

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

    /// Rename a bot, and record that the name is the user's.
    ///
    /// The trimming and the `nameIsAuto` flag live here rather than in the roster's alert so
    /// that both can be tested: the test bundle links `BotHarnessCore` and not the app, so a
    /// rule written in a view can only be checked by copying it into a test, where it goes
    /// stale the first time the view changes. `BotRunner.maybeSelfDescribe` renames a bot only
    /// while `nameIsAuto` is set, so clearing it here is what stops a bot writing over a name
    /// the user chose.
    ///
    /// Mutates by id rather than taking a whole `Bot`, because the bot may have described
    /// itself while the alert was open and this must change the name and nothing else.
    ///
    /// Returns false and writes nothing when the name is blank. Deliberately not surfaced as an
    /// error: nothing changed, the row still shows the old name, and a second alert saying
    /// "type something" tells the user only what they can already see.
    @discardableResult
    public func renameBot(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = bots.firstIndex(where: { $0.id == id }) else { return false }
        bots[i].name = trimmed
        bots[i].nameIsAuto = false
        scheduleSave()
        return true
    }

    /// Delete a bot and everything that only existed because of it.
    ///
    /// Returns the conversations that went with it, because the caller owns things this type
    /// must not know about — running tasks, pending approvals, live step lists, drafts — and
    /// every one of them is keyed by conversation. Deleting a bot without cancelling its work
    /// leaves a loop writing into a conversation that no longer exists.
    @discardableResult
    public func deleteBot(_ id: UUID) -> [UUID] {
        // A room survives losing one member; a chat does not, and neither does a room whose
        // last member this is. An empty room can never answer again, and the alternative —
        // leaving it in the roster with no avatar and no possible reply — is a row whose only
        // remaining use is deleting it. The ids come back so the caller can cancel the work
        // that was running in them.
        let orphaned = conversations.filter { $0.participants == [id] }.map(\.id)
        bots.removeAll { $0.id == id }
        conversations.removeAll { $0.participants == [id] }
        for i in conversations.indices {
            conversations[i].participants.removeAll { $0 == id }
            repairLead(at: i)
        }
        repairSelection()
        scheduleSave()
        return orphaned
    }

    /// Mark a conversation as seen. Called when it becomes the selection.
    ///
    /// Deliberately not debounced through `scheduleSave` alone — it is cheap, and losing it
    /// only means a row stays bold, which is a far better failure than a row going quiet about
    /// something that needs the user.
    public func markRead(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }),
              conversations[i].isUnread else { return }
        conversations[i].lastReadAt = Date()
        scheduleSave()
    }

    public func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        repairSelection()
        scheduleSave()
    }

    /// Empty a conversation without deleting it, so the bot and its settings survive.
    public func clearMessages(in id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.removeAll()
        conversations[i].lastActivity = Date()
        scheduleSave()
    }

    public func deleteMessage(_ messageID: UUID, in conversationID: UUID) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[c].messages.removeAll { $0.id == messageID }
        scheduleSave()
    }

    /// Never leave `selection` pointing at something that is gone.
    ///
    /// Every deletion path runs through here. A stale selection is not a cosmetic problem: the
    /// conversation column resolves it to nil and renders a composer that can deliver nowhere.
    private func repairSelection() {
        if let selection, conversations.contains(where: { $0.id == selection }) { return }
        selection = sortedConversations.first?.id
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

    /// A room the user made and named, as opposed to a bot's own chat.
    ///
    /// `Conversation.isChannel` counts participants, which is the right answer when a channel
    /// is created and the wrong one ever after: delete one member of a two-bot room and by that
    /// measure the room becomes a chat, whereupon the roster labels its delete item "Delete
    /// Bot" and deleting the room takes the surviving bot and that bot's own thread with it. A
    /// title is the durable mark, because only `createChannel` sets one and a chat never has
    /// one — a chat's row reads the bot's name through the store instead.
    ///
    /// Static so the roster and this type answer the question with the same expression rather
    /// than two copies that drift.
    public static func isRoom(_ conversation: Conversation) -> Bool {
        conversation.title != nil || conversation.isChannel
    }

    /// Rename a room.
    ///
    /// Refused for a chat, and the refusal is the point rather than a formality: a chat has no
    /// title of its own, so writing one would pin a name that renaming the bot can no longer
    /// change, and the roster would show a different name from the conversation header for the
    /// same bot with nothing in the interface to undo it.
    ///
    /// Blank is refused for the reason given on `renameBot`, and the two paths refuse
    /// identically so that the roster can offer one alert for both.
    @discardableResult
    public func renameConversation(_ id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = conversations.firstIndex(where: { $0.id == id }),
              Self.isRoom(conversations[i]) else { return false }
        conversations[i].title = trimmed
        // `lastActivity` is deliberately left alone. It orders the roster and decides the unread
        // mark, so bumping it would move the row to the top and light it up because the user
        // renamed it — announcing as news something that did not happen in the conversation.
        scheduleSave()
        return true
    }

    /// Add a bot to a room.
    ///
    /// Refused for a chat rather than quietly promoting it to a room: `deleteBot` finds the
    /// threads to remove by matching `participants == [id]`, so a chat with a second member in
    /// it would outlive its own bot as a room nobody can talk to.
    @discardableResult
    public func addParticipant(_ botID: UUID, to conversationID: UUID) -> Bool {
        guard bots.contains(where: { $0.id == botID }),
              let i = conversations.firstIndex(where: { $0.id == conversationID }),
              Self.isRoom(conversations[i]),
              !conversations[i].participants.contains(botID) else { return false }
        // Appended, never inserted at the front. `participants.first` is the bot that answers
        // and the new-channel sheet promises the user in as many words that the bot they picked
        // first is that bot; joining later must not hand the room to the newcomer.
        conversations[i].participants.append(botID)
        scheduleSave()
        return true
    }

    /// Remove a bot from a room.
    ///
    /// The last member cannot be removed. A room with nobody in it has no avatar, no possible
    /// reply and no way back, so the only honest thing left to do with it is delete it — which
    /// is a decision the user should make on purpose rather than reach by unchecking one name
    /// too many.
    @discardableResult
    public func removeParticipant(_ botID: UUID, from conversationID: UUID) -> Bool {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }),
              Self.isRoom(conversations[i]),
              conversations[i].participants.contains(botID),
              conversations[i].participants.count > 1 else { return false }
        conversations[i].participants.removeAll { $0 == botID }
        repairLead(at: i)
        scheduleSave()
        return true
    }

    /// Keep `leadBot` pointing at somebody who is still in the room.
    ///
    /// Nothing reads the lead yet, which is exactly why it would go wrong quietly: a dangling
    /// id costs nothing today and is a bot that cannot be found on the day delegation ships.
    /// `createChannel` sets the lead to the bot that answers, so the repair keeps that true by
    /// following the same rule — whoever is first now leads.
    private func repairLead(at index: Int) {
        guard let lead = conversations[index].leadBot,
              !conversations[index].participants.contains(lead) else { return }
        conversations[index].leadBot = conversations[index].participants.first
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

    public func updateGlobalRule(_ rule: PermissionRule) {
        guard let i = globalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        globalRules[i] = rule
        scheduleSave()
    }

    /// Remove a standing permission.
    ///
    /// The counterpart to "Always allow this" on an approval card. Without it a single
    /// mis-click grants a permission for the life of the install, which makes the whole
    /// permission system something you can only ever loosen.
    public func deleteGlobalRule(_ id: UUID) {
        globalRules.removeAll { $0.id == id }
        scheduleSave()
    }

    public func addRule(_ rule: PermissionRule, to botID: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == botID }) else { return }
        // A rule the user already wrote for this bot is replaced rather than duplicated. Clicking
        // "Always, for this bot" twice on the same prompt should not leave two identical rules
        // that both have to be found and removed.
        if let existing = bots[i].rules.firstIndex(where: {
            $0.whenBotWantsTo.caseInsensitiveCompare(rule.whenBotWantsTo) == .orderedSame
        }) {
            bots[i].rules[existing] = rule
        } else {
            bots[i].rules.append(rule)
        }
        scheduleSave()
    }

    public func updateRule(_ rule: PermissionRule, in botID: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == botID }),
              let j = bots[i].rules.firstIndex(where: { $0.id == rule.id }) else { return }
        bots[i].rules[j] = rule
        scheduleSave()
    }

    /// Remove a standing permission that applies to one bot.
    ///
    /// The counterpart to "Always, for this bot" on an approval card, and the same argument as
    /// `deleteGlobalRule`: a permission system you can only ever loosen is not one. Per-bot rules
    /// had no way to be listed or removed at all, so a single mis-click on a prompt granted
    /// something for the life of the install with nothing on screen admitting it existed.
    public func deleteRule(_ id: UUID, from botID: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == botID }) else { return }
        bots[i].rules.removeAll { $0.id == id }
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
        do {
            let doc = try decoder.decode(Document.self, from: data)
            bots = doc.bots
            conversations = doc.conversations
            globalRules = doc.globalRules
            selection = sortedConversations.first?.id
            reconcileInterruptedWork()
        } catch {
            // A corrupt state file is moved aside rather than deleted, **and the app says so**.
            //
            // Re-seeding silently is the worst possible presentation of this: after a schema
            // change the user opens the app, sees a stranger bot and an empty roster, and has
            // no reason to believe their work still exists. It does — this records where.
            let backup = stateURL.appendingPathExtension("saved-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            loadFailure = LoadFailure(movedTo: backup, reason: String(describing: error))
            seedFirstRun()
        }
    }

    /// Work that was in flight when the process stopped.
    ///
    /// Nothing resumes a run across a launch, so anything still marked open is a claim the app
    /// cannot back: a tool card that says "Running" asserts a process exists, and an approval
    /// card offers buttons wired to a loop that is gone. Both are settled here, once, before
    /// any view can render them.
    private func reconcileInterruptedWork() {
        var touched = false
        for c in conversations.indices {
            for m in conversations[c].messages.indices {
                switch conversations[c].messages[m].body {
                case .toolUse(var activity) where activity.isOpen:
                    activity.status = .interrupted
                    activity.finishedAt = activity.finishedAt ?? Date()
                    conversations[c].messages[m].body = .toolUse(activity)
                    touched = true

                case .computer(var activity) where activity.status == .running
                                               || activity.status == .waitingForApproval:
                    activity.status = .interrupted
                    activity.awaitingHuman = false
                    activity.finishedAt = activity.finishedAt ?? Date()
                    conversations[c].messages[m].body = .computer(activity)
                    touched = true

                case .approval(var request) where request.answer == nil:
                    request.answer = .expired
                    request.answeredAt = Date()
                    conversations[c].messages[m].body = .approval(request)
                    touched = true

                default:
                    break
                }
            }
        }
        if touched { scheduleSave() }
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

    /// Write immediately, cancelling any pending debounce.
    ///
    /// Called when the app is about to quit. Everything else is debounced by 400 ms, so
    /// answering an approval and pressing Cmd-Q inside that window used to lose the answer —
    /// the loop had it, the disk did not.
    /// Write now and do not return until the bytes are on disk.
    ///
    /// `saveNow` hands the encode and the write to a background queue so that typing does not
    /// stall on a multi-megabyte document. That is right for the debounced path and wrong for
    /// this one: `flush` is called when the app resigns active or is about to quit, and a caller
    /// that reopens the file immediately afterwards must see what it just wrote. Losing that
    /// guarantee silently loses the user's last messages on quit.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveAndWait()
    }

    public func saveNow() {
        let doc = Document(bots: bots, conversations: conversations, globalRules: globalRules)
        let target = stateURL
        // Encoding and writing move off the main thread; only reading the model stays on it.
        //
        // The document is every bot, every conversation and every message, pretty-printed. On a
        // long chat that is megabytes, and it was being re-encoded and written synchronously on
        // the main actor every 400 ms while the user typed — so the UI stalled in proportion to
        // how much history they had, which is exactly backwards.
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(doc) else { return }

            // Atomic: write beside the target, then rename. A crash mid-write leaves the previous
            // good document intact rather than a truncated one.
            let tmp = target.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp)
                // Owner-only. The document holds bot personas, workspace paths and the full text
                // of every conversation; it inherited the umask before this.
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: tmp.path)
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: target)
                }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
    }

    /// Serial, so two saves can never interleave into a half-written document.
    private static let writeQueue = DispatchQueue(label: "app.botharness.store.write", qos: .utility)

    /// Write synchronously and wait. Only for app termination, where returning before the bytes
    /// are on disk means losing them.
    public func saveAndWait() {
        saveNow()
        Self.writeQueue.sync(flags: .barrier) {}
    }

    // MARK: First run

    /// What a brand-new install contains. Not an empty list — an empty app teaches nobody
    /// what it is for. One bot, already useful, whose persona shows what a good persona
    /// looks like.
    private func seedFirstRun() {
        var starter = Bot(name: "Harness")
        starter.label = "General"
        starter.persona = """
            A general-purpose bot. Knows its way around this Mac and the projects on the \
            Desktop. Reads before it writes, runs things to check they work rather than \
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
