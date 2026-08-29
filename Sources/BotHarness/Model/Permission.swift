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
struct PermissionRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// What the bot might want to do, as the user described it.
    /// Completes the sentence "When this bot wants to …".
    var whenBotWantsTo: String

    /// What should happen.
    var behaviour: Behaviour

    /// Set when this rule was created by clicking "always allow this" on a prompt, rather
    /// than typed by hand. Useful when explaining later why something was permitted.
    var createdFromPrompt: Bool = false

    var createdAt: Date = Date()

    enum Behaviour: String, Codable, Hashable, CaseIterable {
        case allowAutomatically
        case askFirst
        case neverAllow

        var displayName: String {
            switch self {
            case .allowAutomatically: return "Allow automatically"
            case .askFirst:           return "Ask first"
            case .neverAllow:         return "Never allow"
            }
        }

        /// Lower is stronger. Used to resolve conflicts: the strongest behaviour among all
        /// matching rules wins, so `askFirst` beats `allowAutomatically` and `neverAllow`
        /// beats everything.
        var strength: Int {
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
struct ProposedAction: Hashable {
    /// The tool about to run, e.g. "shell", "files.write", "browser.click".
    var tool: String

    /// A one-line, human-readable statement of what will happen, written for the user, not
    /// for a log. "Delete 3 files in ~/Desktop/jewel/dist" — not "fs.unlink(paths=[…])".
    var summary: String

    /// The literal arguments, shown verbatim in the approval prompt. Users approve what they
    /// can see; a summary alone is not enough to consent to a shell command.
    var detail: String

    /// Which bot is asking.
    var botID: UUID

    /// Set when any part of this action's justification came from content the agent read
    /// rather than from the user — a web page, a file, an email.
    ///
    /// This is the prompt-injection tripwire. Content the agent reads is data, never
    /// instructions, so an action that exists *because a page asked for it* is escalated
    /// regardless of what the user's rules say.
    var originatedFromUntrustedContent: Bool = false
}

/// What the permission system decided, and why. Every one of these is written to the trace:
/// a permission system you cannot audit is a permission system you cannot trust.
struct PermissionDecision: Codable, Hashable {
    enum Outcome: String, Codable, Hashable {
        case allowed
        case asked
        case refused
    }

    var outcome: Outcome

    /// Plain-language reason, shown to the user if they ask why. E.g. "matched your rule
    /// 'reply to emails for me'" or "the safety floor always asks before spending money".
    var reason: String

    /// Which layer decided. Present so that "why was this allowed?" has a precise answer.
    var decidedBy: Layer

    /// The rule that matched, if the user's layer decided.
    var matchedRuleID: UUID?

    enum Layer: String, Codable, Hashable {
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
enum SafetyFloor: String, Codable, CaseIterable {
    /// Moving money in any form: transfers, trades, purchases, crypto.
    case financialTransaction

    /// Typing a password, API key, card number, or government ID into anything.
    case enteringCredentials

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

    /// Publishing or modifying anything publicly visible.
    case publishing

    /// Anything proposed because content the agent *read* asked for it.
    case instructionFromUntrustedContent

    /// What always happens when an action falls in this category, before any user rule is
    /// consulted.
    var floorBehaviour: PermissionRule.Behaviour {
        switch self {
        case .enteringCredentials, .instructionFromUntrustedContent:
            // Never delegated. The user does these themselves, in their own hands.
            return .neverAllow
        default:
            return .askFirst
        }
    }

    var explanation: String {
        switch self {
        case .financialTransaction:          return "spends or moves money"
        case .enteringCredentials:           return "would enter a password or key"
        case .destructiveDelete:             return "deletes something outside the workspace"
        case .rewritingSharedHistory:        return "rewrites history other people depend on"
        case .sendingToNewRecipient:         return "sends a message to someone new"
        case .grantingAccess:                return "grants access to your accounts"
        case .changingSystemConfiguration:   return "changes how your Mac is configured"
        case .publishing:                    return "publishes something publicly"
        case .instructionFromUntrustedContent:
            return "was requested by a web page or document, not by you"
        }
    }
}
