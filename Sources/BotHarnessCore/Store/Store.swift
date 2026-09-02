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

    // MARK: Writing — attachments

    /// Record what the user attached, and hand back what was refused so the interface can say
    /// so out loud.
    ///
    /// The refusals are returned rather than logged because the user is standing right there
    /// with their hand still on the trackpad. A drop that quietly does nothing is the failure
    /// this whole path exists to remove — it is not an improvement to swap one silent failure
    /// for another one a layer up.
    public struct AttachResult: Sendable {
        public var granted: [Attachment] = []
        public var refused: [Attachment.Refusal] = []
    }

    @discardableResult
    public func attach(_ paths: [String], to conversationID: UUID) -> AttachResult {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return AttachResult()
        }
        var result = AttachResult()
        for path in paths {
            switch Attachment.grant(path) {
            case .success(let attachment): result.granted.append(attachment)
            case .failure(let refusal): result.refused.append(refusal)
            }
        }
        guard !result.granted.isEmpty else { return result }
        conversations[i].attachments = Attachment.merge(conversations[i].attachments,
                                                        adding: result.granted)
        scheduleSave()
        return result
    }

    /// Take a grant back. The user gave it, so the user can withdraw it.
    public func detach(_ path: String, from conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[i].attachments.contains(where: { $0.path == path }) else { return }
        conversations[i].attachments.removeAll { $0.path == path }
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

        /// Spelled out rather than synthesised. The synthesised enum is generated on demand and
        /// is not in scope for a member that names it in its own signature, which `records`
        /// below does; writing it here also pins the on-disk key names to something a schema
        /// change has to touch on purpose.
        private enum CodingKeys: String, CodingKey {
            case version, bots, conversations, globalRules
        }

        init(bots: [Bot], conversations: [Conversation], globalRules: [PermissionRule]) {
            self.bots = bots
            self.conversations = conversations
            self.globalRules = globalRules
        }

        /// Read so that one damaged record cannot cost the user every undamaged one.
        ///
        /// `Bot` and `Conversation` recover their own fields (see `LenientDecoding.swift`); this
        /// is the level that decides what happens when a whole record, or a whole array, is
        /// unreadable.
        init(from decoder: Decoder) throws {
            let recovery = try Recovery(decoder, of: "the state file", keyedBy: CodingKeys.self)
            version = recovery.value(.version, or: 1)
            bots = try Self.records(.bots, of: Bot.self, in: recovery.container)
            conversations = try Self.records(.conversations, of: Conversation.self,
                                             in: recovery.container)

            // Strict, and the one thing in this file that can still fail the whole load.
            //
            // Every other recovery here trades a field for the rest of the document. That trade
            // is wrong for the global rules, because the rule we could not read may be the one
            // that says no, and a roster that opens governed by fewer rules than the user wrote
            // is worse than a roster that does not open. Failing keeps the file, moves it aside
            // under a name the user is shown, and starts from the safe defaults.
            //
            // Absent is a different thing and stays fine: a file written before global rules
            // existed simply has none, and the built-in floor still applies to every bot.
            globalRules = try recovery.container
                .decodeIfPresent([PermissionRule].self, forKey: .globalRules) ?? []
        }

        /// The document's own arrays, decoded element by element so that a single bad entry is
        /// skipped and the rest are kept.
        ///
        /// Absent is fine — a file written before the key existed. Present but holding something
        /// that is not an array, an explicit `null` included, is not: quietly loading zero bots
        /// would show the user an empty roster and then write it over their real one at the next
        /// save, which is the total loss this whole decoder exists to prevent. That throws, and
        /// the loader keeps the file and says where it went.
        private static func records<T: Decodable>(
            _ key: CodingKeys, of type: T.Type,
            in container: KeyedDecodingContainer<CodingKeys>
        ) throws -> [T] {
            guard container.contains(key) else { return [] }
            return try container.decode([Recoverable<T>].self, forKey: key).compactMap(\.element)
        }
    }

    /// A copy of the state file, kept when the file loaded but not all of it could be read.
    /// Nil on a clean load. See `preserveOriginal`.
    private(set) var recoveredCopy: URL?

    /// What that load could not read, one line each, in the decoder's words.
    private(set) var recoveryLosses: [String] = []

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else {
            seedFirstRun()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Carries the record of what had to be recovered down to every nested decoder, so the
        // loader can tell a clean read from one that filled in gaps.
        let log = RecoveryLog()
        decoder.userInfo[.recoveryLog] = log
        do {
            let doc = try decoder.decode(Document.self, from: data)
            bots = doc.bots
            conversations = doc.conversations
            globalRules = doc.globalRules
            selection = sortedConversations.first?.id
            if !log.isEmpty { preserveOriginal(log.losses, of: data) }
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

    /// Keep the file that could not be read in full.
    ///
    /// Whatever the decoder could not recover — a skipped bot, a message body it could not
    /// parse — exists nowhere but this file, and the next save writes memory straight over it.
    /// One copy is the difference between "the app lost a bot" and "the app lost a bot and here
    /// is the bot". It costs one file copy on a load that has already gone wrong.
    ///
    /// Deliberately does **not** set `loadFailure`. That sheet tells the user their file "was
    /// set aside" and the app "started fresh", and here neither is true: their real bots opened
    /// and the file is still where it was. Showing it anyway would be a worse lie than saying
    /// nothing, so a partial recovery needs its own notice in the interface — which is work in
    /// `RootView`, not here.
    private func preserveOriginal(_ losses: [String], of data: Data) {
        recoveryLosses = losses

        // A file that keeps failing the same way is copied once, not once per launch. The app
        // heals the damage at its next save, so normally there is one copy and then no more
        // reason to make any — but a user who opens the app and quits without touching anything
        // never reaches that save, and the document is megabytes on a long chat, so a copy per
        // launch is a disk filling up. Compared by content rather than by "a copy exists", so
        // that a *different* loss later still gets its own copy.
        if let existing = existingCopies().first(where: {
            (try? Data(contentsOf: $0)) == data
        }) {
            recoveredCopy = existing
            return
        }

        let copy = stateURL.appendingPathExtension("recovered-\(Int(Date().timeIntervalSince1970))")
        guard (try? FileManager.default.copyItem(at: stateURL, to: copy)) != nil else { return }
        // The copy holds everything the original held, so it gets the original's protection
        // rather than the umask's idea of one.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        recoveredCopy = copy
    }

    private func existingCopies() -> [URL] {
        let directory = stateURL.deletingLastPathComponent()
        let prefix = stateURL.lastPathComponent + ".recovered-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map(directory.appendingPathComponent)
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

            // Owner-only from the instant the file exists, rather than written at the umask and
            // narrowed afterwards. The document holds every bot persona, every workspace path
            // and the full text of every conversation, and the gap between `write` and `chmod`
            // is a window in which all of that is world-readable — permanently, if the process
            // dies inside it. A temporary left by a killed save is removed first so `O_EXCL` has
            // something to guarantee: it means this never writes into a file another process is
            // holding open.
            try? FileManager.default.removeItem(at: tmp)
            let descriptor = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { return }
            // The umask can only narrow the mode above, never widen it, so this is not a
            // correctness fix — it is so the mode does not depend on the umask of whoever
            // launched the app.
            fchmod(descriptor, 0o600)

            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            do {
                try handle.write(contentsOf: data)
                // fsync before the rename, for the reason `CredentialStore` gives: without it a
                // power loss can land the new name over an empty file, which reads back as "no
                // bots" — the exact loss the atomic write exists to prevent.
                try handle.synchronize()
            } catch {
                close(descriptor)
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            close(descriptor)

            // rename(2) rather than `FileManager.replaceItemAt`, which was the bug here.
            // replaceItemAt keeps the *target's* mode and discards the replacement's, so every
            // save after the first put this document back to whatever the first one inherited
            // from the umask — 0644 in a normal login session — and the chmod above was undone
            // as fast as it was applied. rename lands the descriptor opened at 0600 and nothing
            // copies attributes back over it. Exactly this was found and fixed in
            // `CredentialStore`; the same call had the same effect one file away.
            guard rename(tmp.path, target.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return
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
