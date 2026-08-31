import Foundation

/// The permission system, which is the spine of this product rather than a feature of it.
///
/// Two layers, and the lower one cannot be lowered:
///
/// 1. **The floor** (`SafetyFloor`) — built in, not user-editable. Actions that always stop
///    and ask, or always refuse, no matter what rules exist.
/// 2. **The user's rules** (`PermissionRule`) — natural language, per bot and global.
///
/// When two rules both apply, **ask beats allow**. This is stated, deterministic, and
/// deliberately borrowed from Grok Bot, whose wording is "'Ask first' takes priority if
/// rules conflict." An over-broad allow can therefore never silently swallow a narrower ask.

// MARK: - What the user writes

/// A single rule, written in plain language.
///
/// The user writes "reply to emails for me" and picks "Allow automatically". They do not
/// write `Bash(git push:*)`. That glob syntax is correct for a developer tool and wrong for
/// this one, because the person who most needs to constrain a bot is the person least able
/// to express constraints as patterns.
public struct PermissionRule: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), whenBotWantsTo: String, behaviour: Behaviour, createdFromPrompt: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.whenBotWantsTo = whenBotWantsTo
        self.behaviour = behaviour
        self.createdFromPrompt = createdFromPrompt
        self.createdAt = createdAt
    }
    public var id: UUID = UUID()

    /// What the bot might want to do, as the user described it.
    /// Completes the sentence "When this bot wants to …".
    public var whenBotWantsTo: String

    /// What should happen.
    public var behaviour: Behaviour

    /// Set when this rule was created by clicking "always allow this" on a prompt, rather
    /// than typed by hand. Useful when explaining later why something was permitted.
    public var createdFromPrompt: Bool = false

    public var createdAt: Date = Date()

    public enum Behaviour: String, Codable, Hashable, CaseIterable {
        case allowAutomatically
        case askFirst
        case neverAllow

        public var displayName: String {
            switch self {
            case .allowAutomatically: return "Allow automatically"
            case .askFirst:           return "Ask first"
            case .neverAllow:         return "Never allow"
            }
        }

        /// Lower is stronger. Used to resolve conflicts: the strongest behaviour among all
        /// matching rules wins, so `askFirst` beats `allowAutomatically` and `neverAllow`
        /// beats everything.
        public var strength: Int {
            switch self {
            case .neverAllow:         return 0
            case .askFirst:           return 1
            case .allowAutomatically: return 2
            }
        }
    }
}

// MARK: - What the system decides

/// A proposed action, described in enough detail that both a human and a model can judge it.
public struct ProposedAction: Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(tool: String, summary: String, detail: String, botID: UUID,
                arguments: [String: String] = [:],
                originatedFromUntrustedContent: Bool = false) {
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.botID = botID
        self.arguments = arguments
        self.originatedFromUntrustedContent = originatedFromUntrustedContent
    }
    /// The tool about to run, e.g. "shell", "files.write", "browser.click".
    public var tool: String

    /// A one-line, human-readable statement of what will happen, written for the user, not
    /// for a log. "Delete 3 files in ~/Desktop/jewel/dist" — not "fs.unlink(paths=[…])".
    public var summary: String

    /// The literal arguments, shown verbatim in the approval prompt. Users approve what they
    /// can see; a summary alone is not enough to consent to a shell command.
    public var detail: String

    /// Which bot is asking.
    public var botID: UUID

    /// The tool's arguments as they were actually given, before anything rendered them for a
    /// human. The floor judges these; `summary` and `detail` are for the person reading the
    /// approval prompt. Keeping the two apart is the point: a floor that reads prose is a
    /// floor whose input is written by the thing it constrains.
    public var arguments: [String: String] = [:]

    /// Set when any part of this action's justification came from content the agent read
    /// rather than from the user — a web page, a file, an email.
    ///
    /// This is the prompt-injection tripwire. Content the agent reads is data, never
    /// instructions, so an action that exists *because a page asked for it* is escalated
    /// regardless of what the user's rules say.
    public var originatedFromUntrustedContent: Bool = false
}

/// What the permission system decided, and why. Every one of these is written to the trace:
/// a permission system you cannot audit is a permission system you cannot trust.
public struct PermissionDecision: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(outcome: Outcome, reason: String, decidedBy: Layer, matchedRuleID: UUID? = nil) {
        self.outcome = outcome
        self.reason = reason
        self.decidedBy = decidedBy
        self.matchedRuleID = matchedRuleID
    }
    public enum Outcome: String, Codable, Hashable {
        case allowed
        case asked
        case refused
    }

    public var outcome: Outcome

    /// Plain-language reason, shown to the user if they ask why. E.g. "matched your rule
    /// 'reply to emails for me'" or "the safety floor always asks before spending money".
    public var reason: String

    /// Which layer decided. Present so that "why was this allowed?" has a precise answer.
    public var decidedBy: Layer

    /// The rule that matched, if the user's layer decided.
    public var matchedRuleID: UUID?

    public enum Layer: String, Codable, Hashable {
        case safetyFloor
        case userRule
        case defaultPolicy
    }
}

// MARK: - The floor

/// Categories of action that the built-in floor governs. These are not configurable, and no
/// user rule can lower them — mirroring Grok Bot's "Built-in safety checks always apply."
///
/// The floor is deliberately short. A long list of special cases is a list nobody reads and
/// which lulls people into thinking it is exhaustive. Each entry here is something that is
/// either irreversible, spends money, or gives away access.
public enum SafetyFloor: String, Codable, CaseIterable {
    /// Moving money in any form: transfers, trades, purchases, crypto.
    case financialTransaction

    /// Typing a password, API key, card number, or government ID into anything.
    case enteringCredentials

    /// Sending data from this machine to another one — an upload, a copy to a remote host, a
    /// socket. Separate from `runningUnreviewedCode`, which is the same tools pointed the other
    /// way. This one is the exfiltration direction, and nothing watched it before: value
    /// redaction cannot see a secret that leaves inside a request body.
    case sendingDataOffTheMachine

    /// Reading the file this app keeps API keys in.
    ///
    /// Its own keys, specifically. A bot that can read them can spend the user's money on any
    /// machine, not just this one, and can do it long after the run ends — so this is refused
    /// outright rather than offered as a prompt. There is no legitimate task on the other side
    /// of that dialog, and a prompt the user can only sensibly answer one way is not a choice,
    /// it is a trap with a button on it.
    case readingSecrets

    /// Deleting outside the bot's workspace, emptying trash, or any hard delete.
    case destructiveDelete

    /// `git push --force`, history rewrites, branch deletion on a remote.
    case rewritingSharedHistory

    /// Sending a message — mail, chat, DM, calendar invite — to someone the user has not
    /// already corresponded with in this thread.
    case sendingToNewRecipient

    /// Granting OAuth scopes, accepting terms, creating accounts.
    case grantingAccess

    /// Changing system settings, security settings, or TCC grants.
    case changingSystemConfiguration

    /// Running code fetched from the network without anyone reading it first — `curl … | sh`
    /// and its relatives. Added because it is the one genuinely common shell shape that none
    /// of the categories above describes: it is not a delete, not a config change, and not a
    /// grant, but it can become all three a second later.
    case runningUnreviewedCode

    /// Publishing or modifying anything publicly visible.
    case publishing

    /// Anything proposed because content the agent *read* asked for it.
    case instructionFromUntrustedContent

    /// What always happens when an action falls in this category, before any user rule is
    /// consulted.
    public var floorBehaviour: PermissionRule.Behaviour {
        switch self {
        case .enteringCredentials, .readingSecrets, .instructionFromUntrustedContent:
            // Never delegated. The user does these themselves, in their own hands.
            return .neverAllow
        default:
            return .askFirst
        }
    }

    public var explanation: String {
        switch self {
        case .financialTransaction:          return "spends or moves money"
        case .enteringCredentials:           return "would enter a password or key"
        case .readingSecrets:                return "would read your stored API keys"
        case .sendingDataOffTheMachine:      return "would send data to another machine"
        case .destructiveDelete:             return "deletes something outside the workspace"
        case .rewritingSharedHistory:        return "rewrites history other people depend on"
        case .sendingToNewRecipient:         return "sends a message to someone new"
        case .grantingAccess:                return "grants access to your accounts"
        case .changingSystemConfiguration:   return "changes how your Mac is configured"
        case .runningUnreviewedCode:         return "runs code off the internet without showing it to you"
        case .publishing:                    return "publishes something publicly"
        case .instructionFromUntrustedContent:
            return "was requested by a web page or document, not by you"
        }
    }
}
