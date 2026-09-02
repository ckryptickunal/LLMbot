import Foundation

/// A conversation is either a **chat** with one bot or a **channel** containing several.
///
/// They are one type rather than two because almost everything about them is identical —
/// a message list, a title, a last-activity timestamp — and the differences are better
/// expressed as a roster of one versus a roster of many than as parallel hierarchies.
public struct Conversation: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), participants: [UUID], title: String? = nil, leadBot: UUID? = nil, messages: [Message] = [], createdAt: Date = Date(), lastActivity: Date = Date(), channelPolicy: ChannelPolicy = ChannelPolicy()) {
        self.id = id
        self.participants = participants
        self.title = title
        self.leadBot = leadBot
        self.messages = messages
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.channelPolicy = channelPolicy
    }
    public var id: UUID = UUID()

    /// The bots taking part, in display order. Exactly one for a chat, two or more for a
    /// channel.
    public var participants: [UUID]

    /// Channels are named by the user; chats take their name from the bot.
    public var title: String?

    /// In a channel, the bot allowed to delegate to the others. Nil in a chat.
    public var leadBot: UUID?

    public var messages: [Message] = []
    public var createdAt: Date = Date()
    public var lastActivity: Date = Date()

    /// Channels need this and chats do not: in a room with several bots, something has to
    /// stop two of them talking to each other forever. See `ChannelPolicy`.
    public var channelPolicy: ChannelPolicy = ChannelPolicy()

    /// When the user last had this conversation open.
    ///
    /// Optional on purpose, in two senses: it is absent from every state file written before
    /// this existed, and a conversation that has never been read is a real state rather than a
    /// missing value. Drives the roster's unread mark — without it, a bot that answered while
    /// you were reading a different one leaves no trace at all in the list.
    public var lastReadAt: Date?

    /// Files the user handed to this conversation by dropping them in or choosing them in the
    /// attach panel.
    ///
    /// Saved with the conversation rather than held for the session, because the alternative is
    /// worse in exactly the way this feature was already broken: you drop a PDF, quit for the
    /// night, come back and ask a follow-up about it, and the bot says it cannot read the file
    /// you can see in the transcript. The grant is narrow, it names one file each, and it is
    /// legible in `state.json` — so a person who wants to know what their bots may read can
    /// read the list rather than infer it.
    ///
    /// Absent from every state file written before this existed, hence the default. See
    /// `Attachment` for why a grant may only come from a gesture.
    public var attachments: [Attachment] = []

    /// True when something has happened here since the user last looked.
    public var isUnread: Bool {
        guard let lastReadAt else { return !messages.isEmpty }
        return lastActivity > lastReadAt
    }

    public var isChannel: Bool { participants.count > 1 }

    /// Decoded leniently, for the reason set out in `LenientDecoding.swift`. A conversation is
    /// the user's record of what happened; a field this version does not recognise is not a
    /// reason to hand back an empty roster and overwrite it at the next save.
    public init(from decoder: Decoder) throws {
        let recovery = try Recovery(decoder, of: "a conversation", keyedBy: CodingKeys.self)

        id = recovery.value(.id, or: UUID())

        // Element by element, so one unreadable id costs the room one member rather than all of
        // them. A conversation can end up with nobody in it that way, and it is still kept: it
        // can no longer answer, but the messages already in it are the user's, and deleting a
        // thread to tidy up a field we could not read is not this decoder's decision to make.
        participants = recovery.elements(.participants, of: UUID.self)

        title = recovery.optional(.title)
        leadBot = recovery.optional(.leadBot)
        messages = recovery.elements(.messages, of: Message.self)
        createdAt = recovery.value(.createdAt, or: Date())
        lastActivity = recovery.value(.lastActivity, or: Date())
        channelPolicy = recovery.value(.channelPolicy, or: ChannelPolicy())

        // Nil is a real state here — a conversation nobody has opened — so an unreadable value
        // falls back to it and the row shows as unread. Being told about something twice is a
        // better failure than never being told at all.
        lastReadAt = recovery.optional(.lastReadAt)

        // Element by element, and empty when unreadable. This is a permission list, so the
        // direction of the fallback is the one that grants nothing: a grant that cannot be read
        // is a grant the user has to make again, which costs them one drag. The opposite
        // failure costs them a file they did not know a bot could still read.
        //
        // Adding the property was not enough on its own, and the gap was invisible from the
        // code: the encoder is synthesised and wrote the field correctly, this decoder is
        // hand-written and simply did not mention it, so every attachment survived being saved
        // and vanished on the next launch. Anything added to this type from here needs a line
        // here too.
        attachments = recovery.elements(.attachments, of: Attachment.self)
    }
}

/// The rules that keep a room of bots from becoming a feedback loop.
///
/// These are genuinely unsolved design problems, not settled ones. They are written down as
/// explicit knobs rather than buried as constants so that when the first channel misbehaves,
/// the thing to change is obvious.
public struct ChannelPolicy: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(maxConsecutiveBotTurns: Int = 12, botsMaySpeakUnprompted: Bool = true, permissionsFollow: PermissionInheritance = .actingBot) {
        self.maxConsecutiveBotTurns = maxConsecutiveBotTurns
        self.botsMaySpeakUnprompted = botsMaySpeakUnprompted
        self.permissionsFollow = permissionsFollow
    }
    /// How many consecutive bot-to-bot messages may pass with no human message before the
    /// channel pauses and asks the user whether to continue. Prevents runaway loops and
    /// runaway spend.
    public var maxConsecutiveBotTurns: Int = 12

    /// Whether a bot may speak without being addressed by name or by the lead.
    public var botsMaySpeakUnprompted: Bool = true

    /// When bot A asks bot B to do something, whose permission rules apply.
    ///
    /// `.actingBot` is the safe default and the only one implemented first: B does the work,
    /// so B's rules govern it. The alternative — inheriting the requester's rules — would let
    /// a permissive bot launder work through a restricted one.
    public var permissionsFollow: PermissionInheritance = .actingBot

    public enum PermissionInheritance: String, Codable, Hashable {
        case actingBot
        case requestingBot
    }

    /// Decoded leniently. Each fallback is this type's own shipped default, so a policy with one
    /// unreadable knob keeps the other two rather than resetting all three.
    public init(from decoder: Decoder) throws {
        let recovery = try Recovery(decoder, of: "a channel policy", keyedBy: CodingKeys.self)
        maxConsecutiveBotTurns = recovery.value(.maxConsecutiveBotTurns, or: 12)
        botsMaySpeakUnprompted = recovery.value(.botsMaySpeakUnprompted, or: true)
        // `.actingBot` for the reason given on the property: the alternative lets a permissive
        // bot launder work through a restricted one, so it is not a value to fall back to.
        permissionsFollow = recovery.value(.permissionsFollow, or: .actingBot)
    }
}

/// One entry in a conversation.
///
/// A message is a envelope plus a body. Splitting them means the timeline can hold prose,
/// tool activity, permission prompts and system notices without four parallel arrays, and
/// the UI can render any of them in date order without special cases.
public struct Message: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), author: UUID? = nil, body: Body, timestamp: Date = Date(), routineID: UUID? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.timestamp = timestamp
        self.routineID = routineID
    }
    public var id: UUID = UUID()

    /// Who said it. Nil means the user.
    public var author: UUID?

    public var body: Body
    public var timestamp: Date = Date()

    /// Set on messages produced while a routine was running, so the UI can show that this
    /// happened on a schedule rather than because someone asked.
    public var routineID: UUID?

    public enum Body: Codable, Hashable {
        /// Ordinary prose, from the user or a bot. Markdown.
        case text(String)

        /// The bot used a tool. Rendered as a card in the timeline.
        case toolUse(ToolActivity)

        /// The bot used a computer. Rendered as the Computer card, which doubles as the
        /// door for the user to take over.
        case computer(ComputerActivity)

        /// A permission prompt, answered or still open. Kept in the timeline rather than
        /// shown as a modal so that the record of what was approved lives with the work it
        /// approved.
        case approval(ApprovalRequest)

        /// Muted, centred, no bubble. "Updated routine ⏱ Jewel partnership reply watch."
        case notice(String)

        /// Something went wrong, stated plainly.
        case failure(String)

        /// What the bot saw. Posted whenever it looks at a screen, so the user watches the
        /// work rather than reading a description of it.
        ///
        /// Stores a path, never the image bytes: the conversation document is rewritten on
        /// every change, and a run with thirty screenshots in it would make that unusable.
        case screenshot(Screenshot)
    }

    /// Decoded leniently, for the reason set out in `LenientDecoding.swift`.
    ///
    /// A body this version cannot read becomes a visible failure line in place rather than a
    /// message that quietly disappears from the middle of a transcript. The timestamp and the
    /// author survive, so the gap sits where the message was instead of at the end.
    ///
    /// `ToolActivity`, `ComputerActivity` and `ApprovalRequest` are deliberately *not* given
    /// decoders like this one. A half-read tool card would claim a status nothing established —
    /// "Done", or worse, an approval showing an answer that was not the one given — and a card
    /// that lies about what happened is worse than a line admitting it could not be read.
    public init(from decoder: Decoder) throws {
        let recovery = try Recovery(decoder, of: "a message", keyedBy: CodingKeys.self)

        id = recovery.value(.id, or: UUID())

        // The one field that fails the message rather than recovering. `author` is nil for the
        // user, so an unreadable id would fall back to nil and put a bot's words in the user's
        // voice — and the transcript is what the next run is built from, so that is not a
        // cosmetic mistake. It is a bot's own output coming back as something the user said.
        author = try recovery.container.decodeIfPresent(UUID.self, forKey: .author)

        do {
            body = try recovery.container.decode(Body.self, forKey: .body)
        } catch {
            recovery.lost("body: \(String(describing: error))")
            body = .failure("This message could not be read, so the app kept its place in the "
                          + "conversation rather than dropping it. The original is in the copy "
                          + "of the state file kept beside it.")
        }

        timestamp = recovery.value(.timestamp, or: Date())
        routineID = recovery.optional(.routineID)
    }
}

/// An image of what the bot saw, and why it looked.
public struct Screenshot: Identifiable, Codable, Hashable {

    public init(id: UUID = UUID(), path: String, caption: String, takenAt: Date = Date()) {
        self.id = id; self.path = path; self.caption = caption; self.takenAt = takenAt
    }

    public var id: UUID = UUID()
    /// Absolute path to the PNG, inside the run's artifact directory.
    public var path: String
    /// What the bot was doing when it looked. Shown under the image.
    public var caption: String
    public var takenAt: Date = Date()
}

/// A tool call, from proposal through result.
public struct ToolActivity: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), tool: String, summary: String, detail: String = "", output: String = "", status: Status = .running, startedAt: Date = Date(), finishedAt: Date? = nil, traceID: String? = nil) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.output = output
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.traceID = traceID
    }
    public var id: UUID = UUID()
    public var tool: String

    /// One line, written for the user. "Read 4 files in src/auth".
    public var summary: String

    /// The literal arguments and output, shown when the card is expanded. Truncated for
    /// display; the trace on disk keeps the full text.
    public var detail: String = ""
    public var output: String = ""

    public var status: Status = .running
    public var startedAt: Date = Date()
    public var finishedAt: Date?

    /// Links this card to the trace record on disk, so "show me exactly what happened here"
    /// is one click rather than a search.
    public var traceID: String?

    public enum Status: String, Codable, Hashable {
        case running, done, failed, refused, waitingForApproval

        /// The app stopped while this was running, so nobody knows how it ended.
        ///
        /// Distinct from `failed` on purpose: a failure is a result, and this is the absence
        /// of one. A card that still says "Running" after a relaunch asserts that work is
        /// happening when the process that was doing it no longer exists.
        case interrupted
    }

    /// True for a status that can still change on its own. Used to sweep work whose process
    /// died — see `Store.reconcileInterruptedWork`.
    public var isOpen: Bool {
        status == .running || status == .waitingForApproval
    }
}

/// The Computer card. Grok Bot's single best interface idea: one element that is
/// simultaneously the progress indicator, the explanation, and the takeover door.
public struct ComputerActivity: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), task: String, status: ToolActivity.Status = .running, environment: EnvironmentKind = .thisMac, screenshots: [String] = [], awaitingHuman: Bool = false, startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id
        self.task = task
        self.status = status
        self.environment = environment
        self.screenshots = screenshots
        self.awaitingHuman = awaitingHuman
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
    public var id: UUID = UUID()

    /// The task the computer was given, in the words the bot used.
    /// "Enter the 8-character Atomicwork code from …, then submit"
    public var task: String

    public var status: ToolActivity.Status = .running

    /// Which machine this ran on.
    public var environment: EnvironmentKind = .thisMac

    /// Filenames of screenshots captured during this activity, relative to the run's artifact
    /// directory. The scrubber in the trace viewer plays these back in order.
    public var screenshots: [String] = []

    /// Set when the bot has handed control back and is waiting for the user to do something
    /// it is not allowed to do — paste a code, solve a CAPTCHA, log in.
    public var awaitingHuman: Bool = false

    public var startedAt: Date = Date()
    public var finishedAt: Date?
}

/// A permission prompt as it appears in the timeline.
public struct ApprovalRequest: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), summary: String, detail: String, reason: String, answer: Answer? = nil, answeredAt: Date? = nil) {
        self.id = id
        self.summary = summary
        self.detail = detail
        self.reason = reason
        self.answer = answer
        self.answeredAt = answeredAt
    }
    public var id: UUID = UUID()

    /// What the bot wants to do, in one line the user can act on without expanding anything.
    public var summary: String

    /// The literal command, message, or arguments. Users approve what they can see.
    public var detail: String

    /// Why it is being asked rather than simply done.
    public var reason: String

    public var answer: Answer?
    public var answeredAt: Date?

    public enum Answer: String, Codable, Hashable {
        case allowedOnce
        case allowedAlways   // also writes a PermissionRule
        case denied
        case deniedAlways    // also writes a PermissionRule
        /// The run that asked this is gone, so the question can no longer be answered.
        /// Recorded rather than deleted: the record of what was asked survives either way.
        case expired

        /// Whether answering this way permitted the action.
        public var permitted: Bool { self == .allowedOnce || self == .allowedAlways }

        /// Whether answering this way should also write a standing rule.
        public var writesRule: Bool { self == .allowedAlways || self == .deniedAlways }
    }
}
