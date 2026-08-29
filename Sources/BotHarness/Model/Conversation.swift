import Foundation

/// A conversation is either a **chat** with one bot or a **channel** containing several.
///
/// They are one type rather than two because almost everything about them is identical —
/// a message list, a title, a last-activity timestamp — and the differences are better
/// expressed as a roster of one versus a roster of many than as parallel hierarchies.
struct Conversation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// The bots taking part, in display order. Exactly one for a chat, two or more for a
    /// channel.
    var participants: [UUID]

    /// Channels are named by the user; chats take their name from the bot.
    var title: String?

    /// In a channel, the bot allowed to delegate to the others. Nil in a chat.
    var leadBot: UUID?

    var messages: [Message] = []
    var createdAt: Date = Date()
    var lastActivity: Date = Date()

    /// Channels need this and chats do not: in a room with several bots, something has to
    /// stop two of them talking to each other forever. See `ChannelPolicy`.
    var channelPolicy: ChannelPolicy = ChannelPolicy()

    var isChannel: Bool { participants.count > 1 }
}

/// The rules that keep a room of bots from becoming a feedback loop.
///
/// These are genuinely unsolved design problems, not settled ones. They are written down as
/// explicit knobs rather than buried as constants so that when the first channel misbehaves,
/// the thing to change is obvious.
struct ChannelPolicy: Codable, Hashable {
    /// How many consecutive bot-to-bot messages may pass with no human message before the
    /// channel pauses and asks the user whether to continue. Prevents runaway loops and
    /// runaway spend.
    var maxConsecutiveBotTurns: Int = 12

    /// Whether a bot may speak without being addressed by name or by the lead.
    var botsMaySpeakUnprompted: Bool = true

    /// When bot A asks bot B to do something, whose permission rules apply.
    ///
    /// `.actingBot` is the safe default and the only one implemented first: B does the work,
    /// so B's rules govern it. The alternative — inheriting the requester's rules — would let
    /// a permissive bot launder work through a restricted one.
    var permissionsFollow: PermissionInheritance = .actingBot

    enum PermissionInheritance: String, Codable, Hashable {
        case actingBot
        case requestingBot
    }
}

/// One entry in a conversation.
///
/// A message is a envelope plus a body. Splitting them means the timeline can hold prose,
/// tool activity, permission prompts and system notices without four parallel arrays, and
/// the UI can render any of them in date order without special cases.
struct Message: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// Who said it. Nil means the user.
    var author: UUID?

    var body: Body
    var timestamp: Date = Date()

    /// Set on messages produced while a routine was running, so the UI can show that this
    /// happened on a schedule rather than because someone asked.
    var routineID: UUID?

    enum Body: Codable, Hashable {
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
    }
}

/// A tool call, from proposal through result.
struct ToolActivity: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var tool: String

    /// One line, written for the user. "Read 4 files in src/auth".
    var summary: String

    /// The literal arguments and output, shown when the card is expanded. Truncated for
    /// display; the trace on disk keeps the full text.
    var detail: String = ""
    var output: String = ""

    var status: Status = .running
    var startedAt: Date = Date()
    var finishedAt: Date?

    /// Links this card to the trace record on disk, so "show me exactly what happened here"
    /// is one click rather than a search.
    var traceID: String?

    enum Status: String, Codable, Hashable {
        case running, done, failed, refused, waitingForApproval
    }
}

/// The Computer card. Grok Bot's single best interface idea: one element that is
/// simultaneously the progress indicator, the explanation, and the takeover door.
struct ComputerActivity: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// The task the computer was given, in the words the bot used.
    /// "Enter the 8-character Atomicwork code from …, then submit"
    var task: String

    var status: ToolActivity.Status = .running

    /// Which machine this ran on.
    var environment: EnvironmentKind = .thisMac

    /// Filenames of screenshots captured during this activity, relative to the run's artifact
    /// directory. The scrubber in the trace viewer plays these back in order.
    var screenshots: [String] = []

    /// Set when the bot has handed control back and is waiting for the user to do something
    /// it is not allowed to do — paste a code, solve a CAPTCHA, log in.
    var awaitingHuman: Bool = false

    var startedAt: Date = Date()
    var finishedAt: Date?
}

/// A permission prompt as it appears in the timeline.
struct ApprovalRequest: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// What the bot wants to do, in one line the user can act on without expanding anything.
    var summary: String

    /// The literal command, message, or arguments. Users approve what they can see.
    var detail: String

    /// Why it is being asked rather than simply done.
    var reason: String

    var answer: Answer?
    var answeredAt: Date?

    enum Answer: String, Codable, Hashable {
        case allowedOnce
        case allowedAlways   // also writes a PermissionRule
        case denied
        case deniedAlways
    }
}
