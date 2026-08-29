import Foundation

/// The contract that governs a run.
///
/// A bot that asks "I found the issue, would you like me to fix it?" is not being careful; it
/// is being useless in a way that resembles carefulness. A bot that deploys to production
/// because it inferred you would want that is worse. The distance between those two failures
/// is not personality, and it cannot be prompted into existence — telling a model to "take
/// ownership" produces a model that writes more confidently and behaves identically.
///
/// What changes behaviour is machinery: budgets, defaults, capabilities, escalation rules,
/// and above all what the system will accept as *finished*. That machinery is this type.
///
/// See `docs/TASK-CONTRACT.md` for the reasoning behind each field.
struct TaskContract: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var botID: UUID
    var conversationID: UUID

    /// The outcome this run **owns** — not the task it performs.
    ///
    /// "Look into this signup bug" and "own resolution of this signup bug" differ in terminal
    /// condition, not emphasis. The first is satisfied by an explanation. The second is not
    /// satisfied by anything short of working software.
    var objective: String

    /// How aggressively to pursue it. Sets real budgets, not tone.
    var urgency: Urgency = .normal

    /// How much may be decided without asking.
    var autonomy: Autonomy = .confirmBeforeChange

    /// What may technically be executed. Enforced by the tool layer, never by the prompt.
    var authority: Authority = Authority()

    /// What must never happen, layered above the unlowerable `SafetyFloor`.
    var constraints: [String] = []

    /// The evidence that proves the run is finished. **The verifier decides, not the model.**
    var successCriteria: [SuccessCriterion] = []

    /// What the model has spent so far, against `urgency.budget`.
    var spend: Spend = Spend()

    var startedAt: Date = Date()

    /// Set when the run ends, with why.
    var closedAt: Date?
    var closure: Closure?

    enum Closure: String, Codable, Hashable {
        case succeeded          // every success criterion verified
        case escalated          // handed back to the user, with a reason
        case budgetExhausted
        case refused            // the safety floor said no
        case stoppedByUser
        case failed
    }
}

// MARK: - Urgency

/// Urgency with operational consequences. A level that does not change what the harness
/// actually does is decoration.
enum Urgency: String, Codable, Hashable, CaseIterable {
    /// Thoroughness over speed. Explore alternatives. Do not interrupt unnecessarily.
    case low

    /// Steady progress, direct actions, escalate after repeated failure.
    case normal

    /// Time-to-resolution first. Parallelise independent work. Skip nonessential exploration.
    case high

    /// Restore function first and investigate afterwards. Use every authorised resource.
    /// Interrupt the user only at a hard approval boundary.
    case critical

    var displayName: String {
        switch self {
        case .low: return "Low"; case .normal: return "Normal"
        case .high: return "High"; case .critical: return "Critical"
        }
    }

    /// The behavioural instruction handed to the model. Short on purpose: the budget below is
    /// what actually enforces this, and the sentence only has to make the model's choices
    /// consistent with it.
    var doctrine: String {
        switch self {
        case .low:
            return "Optimise for thoroughness. Explore alternatives before committing. Do not interrupt the user unnecessarily."
        case .normal:
            return "Make steady progress. Prefer direct actions. Escalate after repeated failure."
        case .high:
            return "Prioritise time to resolution. Run independent work in parallel. Skip exploration that is not on the path. Escalate blockers quickly."
        case .critical:
            return "Restore functionality first and investigate root cause afterwards. Use every resource you are authorised for. Interrupt the user only when an action needs their approval."
        }
    }

    var budget: Budget {
        switch self {
        case .low:      return Budget(planningSeconds: 120, retriesPerStrategy: 4, parallelSubagents: 1, maxSteps: 200, maxModelCalls: 120, observationDepth: .full)
        case .normal:   return Budget(planningSeconds: 60,  retriesPerStrategy: 3, parallelSubagents: 2, maxSteps: 150, maxModelCalls: 80,  observationDepth: .standard)
        case .high:     return Budget(planningSeconds: 20,  retriesPerStrategy: 2, parallelSubagents: 3, maxSteps: 120, maxModelCalls: 60,  observationDepth: .shallow)
        case .critical: return Budget(planningSeconds: 10,  retriesPerStrategy: 2, parallelSubagents: 4, maxSteps: 100, maxModelCalls: 50,  observationDepth: .shallow)
        }
    }

    /// At high urgency the harness stops confirming ordinary work and confirms only what the
    /// safety floor protects. Agency without economics becomes pathological; agency without
    /// urgency scaling becomes slow.
    var confirmsOnlyProtectedActions: Bool { self == .high || self == .critical }
}

/// Hard ceilings for a run. Exceeding one ends the run as `budgetExhausted` rather than
/// letting it wander.
struct Budget: Codable, Hashable {
    var planningSeconds: Int
    var retriesPerStrategy: Int
    var parallelSubagents: Int
    var maxSteps: Int
    var maxModelCalls: Int
    var observationDepth: ObservationDepth

    /// Money, in US dollars. Nil means "no explicit cap", which is only appropriate for a
    /// subscription-billed brain.
    var maxSpendUSD: Double?

    /// How far up the observation ladder to climb before acting. See `docs/HARNESS.md`.
    enum ObservationDepth: String, Codable, Hashable {
        case shallow    // structured state only; escalate only on failure
        case standard   // structured state, then accessibility tree
        case full       // up to and including screenshots and cropped vision
    }
}

struct Spend: Codable, Hashable {
    var steps: Int = 0
    var modelCalls: Int = 0
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var usd: Double = 0

    func exceeds(_ b: Budget) -> Bool {
        if steps >= b.maxSteps || modelCalls >= b.maxModelCalls { return true }
        if let cap = b.maxSpendUSD, usd >= cap { return true }
        return false
    }
}

// MARK: - Autonomy

/// How much the bot may decide for itself. A ladder rather than a switch, because "can it act
/// on its own" is not one question.
enum Autonomy: Int, Codable, Hashable, CaseIterable, Comparable {
    case advisory = 0             // explain only
    case assisted = 1             // suggest actions; the user executes them
    case confirmBeforeChange = 2  // read freely, confirm every write
    case autonomousWorkspace = 3  // act freely inside a scoped environment
    case autonomousOperational = 4 // act across authorised systems, confirm consequential ones
    case delegatedOperator = 5    // broad authority within explicit policy

    static func < (a: Autonomy, b: Autonomy) -> Bool { a.rawValue < b.rawValue }

    var displayName: String {
        switch self {
        case .advisory:              return "Advisory"
        case .assisted:              return "Assisted"
        case .confirmBeforeChange:   return "Confirm before changing"
        case .autonomousWorkspace:   return "Autonomous in its workspace"
        case .autonomousOperational: return "Autonomous across systems"
        case .delegatedOperator:     return "Delegated operator"
        }
    }

    var explanation: String {
        switch self {
        case .advisory:              return "Explains what it would do. Changes nothing."
        case .assisted:              return "Proposes actions for you to run yourself."
        case .confirmBeforeChange:   return "Reads anything it is allowed to. Asks before every change."
        case .autonomousWorkspace:   return "Works freely inside the folder you gave it. Asks to go outside."
        case .autonomousOperational: return "Works across the systems you authorised. Asks before consequential actions."
        case .delegatedOperator:     return "Acts broadly within written policy. For work you have watched it do many times."
        }
    }

    var mayWriteWithoutAsking: Bool { self >= .autonomousWorkspace }
    var mayActOutsideWorkspace: Bool { self >= .autonomousOperational }
}

// MARK: - The agency rule

/// The single decision that produces high agency without recklessness.
///
/// > If an action is **reversible**, within **granted authority**, and clearly advances the
/// > **stated objective**, perform it without asking.
///
/// Discovering a missing CSS import should not produce "should I add it?" It should produce
/// adding the import, running the build, opening the page, checking it renders, and carrying
/// on. This type is what makes that the default rather than a hope.
struct AgencyCheck {
    /// Can the bot confidently infer what the user wants here?
    var intentIsClear: Bool
    /// Is this inside the objective, rather than adjacent to it?
    var withinScope: Bool
    /// Does the contract's authority actually permit it?
    var authorised: Bool
    /// Could this be undone in a minute if it turns out wrong?
    var reversible: Bool
    /// Does it reach outside this machine — send, publish, spend, deploy?
    var hasExternalConsequence: Bool

    enum Verdict: Equatable {
        case act
        case ask(because: String)
    }

    /// Every condition must hold, and the failure names itself so the resulting prompt can say
    /// something specific rather than "this needs approval".
    var verdict: Verdict {
        if !intentIsClear          { return .ask(because: "there are two reasonable readings of what you want here") }
        if !withinScope            { return .ask(because: "this is outside what you asked for") }
        if !authorised             { return .ask(because: "this bot does not have authority for that") }
        if !reversible             { return .ask(because: "this cannot be undone") }
        if hasExternalConsequence  { return .ask(because: "this affects something outside your machine") }
        return .act
    }
}

// MARK: - Success

/// One piece of evidence that the objective was met.
///
/// The most important field in the contract, because it is what stops a run being over when
/// the model says it is. Prefer `.deterministic`: a command whose exit code answers the
/// question is worth more than a model's opinion about a screenshot.
struct SuccessCriterion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// Written for the user. "Signup completes in the browser."
    var statement: String

    var kind: Kind

    var verifiedAt: Date?
    var evidence: String?

    enum Kind: Codable, Hashable {
        /// A command whose exit code decides it. Cheapest and most trustworthy.
        case command(String)
        /// An HTTP request whose status decides it.
        case http(url: String, expectStatus: Int)
        /// A file exists, or changed after a given moment.
        case fileChanged(path: String)
        /// Text that must be present in a tool's output.
        case outputContains(String)
        /// A model judges a screenshot or a body of text. The weakest kind; use last.
        case judged(question: String)
    }

    var isVerified: Bool { verifiedAt != nil }
}

// MARK: - Authority

/// What the bot may technically do. Enforced by the tool layer before any model reasoning is
/// consulted, so a model that has convinced itself it may delete `~/.ssh` still cannot.
struct Authority: Codable, Hashable {
    /// Paths the bot may read.
    var readable: [String] = []
    /// Paths the bot may write. Always a subset of readable in practice.
    var writable: [String] = []
    /// Paths that are refused outright, overriding everything above.
    var denied: [String] = ["~/.ssh/**", "~/.aws/**", "~/Library/Keychains/**"]

    /// Named capabilities, e.g. "github.commit", "shell.exec", "browser.navigate".
    var granted: Set<String> = []
    /// Capabilities that exist but need a human first, e.g. "github.merge_main".
    var requiresApproval: Set<String> = []

    /// Permission to fix its own environment.
    ///
    /// A surprisingly large share of agent failures are environmental — a missing dev
    /// dependency, a crashed browser, a port already in use, a stale process, an absent temp
    /// directory. An agent that must ask about each of these feels helpless, and the asking
    /// teaches the user to approve without reading. All of these are inside the workspace,
    /// all are reversible, none deserve a prompt.
    var selfRepair: Bool = true

    /// Spending money, at all. Separate from `granted` because it is the one capability whose
    /// absence should be the default no matter how the rest is configured.
    var maySpend: Bool = false

    static let selfRepairActions: Set<String> = [
        "install a missing development dependency",
        "restart a crashed browser",
        "kill a stale local process holding a port it needs",
        "create a temporary directory",
        "retry a failed network request",
        "clear a local cache",
        "choose a different local port",
    ]

    func permits(_ capability: String) -> Bool { granted.contains(capability) }
    func needsApproval(for capability: String) -> Bool { requiresApproval.contains(capability) }
}

// MARK: - Escalation

/// Why a run stopped to ask.
///
/// High agency does not mean never asking. It means asking only when asking is the highest
/// leverage action available — and then asking in a shape the user can answer in one word.
struct Escalation: Codable, Hashable {
    var reason: Reason

    /// What is already done. An escalation that does not say this makes the user re-derive
    /// the state of the work before they can answer.
    var completed: [String]

    /// The single thing being asked for, stated as a decision rather than an open question.
    /// "I need your approval to deploy commit 4af913 to production" — not "what next?"
    var request: String

    enum Reason: String, Codable, Hashable {
        case permissionNotHeld
        case irreversibleChoice
        case ambiguousIntent
        case missingCredential
        case humanPresenceRequired   // CAPTCHA, 2FA, a physical key
        case legalOrFinancial
        case repeatedFailure         // across genuinely different strategies, not retries
        case dependencyUnavailable
    }
}
