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
public struct TaskContract: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), botID: UUID, conversationID: UUID, objective: String, urgency: Urgency = .normal, autonomy: Autonomy = .confirmBeforeChange, authority: Authority = Authority(), constraints: [String] = [], successCriteria: [SuccessCriterion] = [], spend: Spend = Spend(), startedAt: Date = Date(), closedAt: Date? = nil, closure: Closure? = nil) {
        self.id = id
        self.botID = botID
        self.conversationID = conversationID
        self.objective = objective
        self.urgency = urgency
        self.autonomy = autonomy
        self.authority = authority
        self.constraints = constraints
        self.successCriteria = successCriteria
        self.spend = spend
        self.startedAt = startedAt
        self.closedAt = closedAt
        self.closure = closure
    }
    public var id: UUID = UUID()
    public var botID: UUID
    public var conversationID: UUID

    /// The outcome this run **owns** — not the task it performs.
    ///
    /// "Look into this signup bug" and "own resolution of this signup bug" differ in terminal
    /// condition, not emphasis. The first is satisfied by an explanation. The second is not
    /// satisfied by anything short of working software.
    public var objective: String

    /// How aggressively to pursue it. Sets real budgets, not tone.
    public var urgency: Urgency = .normal

    /// How much may be decided without asking.
    public var autonomy: Autonomy = .confirmBeforeChange

    /// What may technically be executed. Enforced by the tool layer, never by the prompt.
    public var authority: Authority = Authority()

    /// What must never happen, layered above the unlowerable `SafetyFloor`.
    public var constraints: [String] = []

    /// The evidence that proves the run is finished. **The verifier decides, not the model.**
    public var successCriteria: [SuccessCriterion] = []

    /// What the model has spent so far, against `urgency.budget`.
    public var spend: Spend = Spend()

    public var startedAt: Date = Date()

    /// Set when the run ends, with why.
    public var closedAt: Date?
    public var closure: Closure?

    public enum Closure: String, Codable, Hashable {
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
public enum Urgency: String, Codable, Hashable, CaseIterable {
    /// Thoroughness over speed. Explore alternatives. Do not interrupt unnecessarily.
    case low

    /// Steady progress, direct actions, escalate after repeated failure.
    case normal

    /// Time-to-resolution first. Parallelise independent work. Skip nonessential exploration.
    case high

    /// Restore function first and investigate afterwards. Use every authorised resource.
    /// Interrupt the user only at a hard approval boundary.
    case critical

    public var displayName: String {
        switch self {
        case .low: return "Low"; case .normal: return "Normal"
        case .high: return "High"; case .critical: return "Critical"
        }
    }

    /// The behavioural instruction handed to the model. Short on purpose: the budget below is
    /// what actually enforces this, and the sentence only has to make the model's choices
    /// consistent with it.
    public var doctrine: String {
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

    /// Budgets are expressed in work, not in wall-clock thinking time.
    ///
    /// An earlier version capped "planning seconds" per urgency level. That was artificial:
    /// a wall-clock ceiling on reasoning does not map onto anything the model or the harness
    /// actually controls, and it punishes a hard problem for being hard. Steps, model calls
    /// and how many alternatives get explored before committing are real quantities.
    public var budget: Budget {
        switch self {
        case .low:      return Budget(exploreAlternatives: 3, retriesPerStrategy: 4, parallelSubagents: 1, maxSteps: 200, maxModelCalls: 120, observationDepth: .full)
        case .normal:   return Budget(exploreAlternatives: 2, retriesPerStrategy: 3, parallelSubagents: 1, maxSteps: 150, maxModelCalls: 80,  observationDepth: .standard)
        case .high:     return Budget(exploreAlternatives: 1, retriesPerStrategy: 2, parallelSubagents: 1, maxSteps: 120, maxModelCalls: 60,  observationDepth: .shallow)
        case .critical: return Budget(exploreAlternatives: 0, retriesPerStrategy: 2, parallelSubagents: 1, maxSteps: 100, maxModelCalls: 50,  observationDepth: .shallow)
        }
    }

    /// At high urgency the harness stops confirming ordinary work and confirms only what the
    /// safety floor protects. Agency without economics becomes pathological; agency without
    /// urgency scaling becomes slow.
    public var confirmsOnlyProtectedActions: Bool { self == .high || self == .critical }
}

/// Hard ceilings for a run. Exceeding one ends the run as `budgetExhausted` rather than
/// letting it wander.
public struct Budget: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(exploreAlternatives: Int, retriesPerStrategy: Int, parallelSubagents: Int, maxSteps: Int, maxModelCalls: Int, observationDepth: ObservationDepth, maxSpendUSD: Double? = nil) {
        self.exploreAlternatives = exploreAlternatives
        self.retriesPerStrategy = retriesPerStrategy
        self.parallelSubagents = parallelSubagents
        self.maxSteps = maxSteps
        self.maxModelCalls = maxModelCalls
        self.observationDepth = observationDepth
        self.maxSpendUSD = maxSpendUSD
    }
    /// How many alternative approaches to weigh before committing to one. Zero means take
    /// the first workable path — correct when something is on fire.
    public var exploreAlternatives: Int

    public var retriesPerStrategy: Int

    /// Held at 1 everywhere for now, deliberately.
    ///
    /// Parallel subagents produce state races, duplicated work, and debugging that is far
    /// harder than the problem they were spawned for. One agent has to be excellent before
    /// several are worth having. This field exists so the ceiling is visible rather than
    /// implicit, not because it is ready to be raised.
    public var parallelSubagents: Int
    public var maxSteps: Int
    public var maxModelCalls: Int
    public var observationDepth: ObservationDepth

    /// Money, in US dollars. Nil means "no explicit cap", which is only appropriate for a
    /// subscription-billed brain.
    public var maxSpendUSD: Double?

    /// How far up the observation ladder to climb before acting. See `docs/HARNESS.md`.
    public enum ObservationDepth: String, Codable, Hashable {
        case shallow    // structured state only; escalate only on failure
        case standard   // structured state, then accessibility tree
        case full       // up to and including screenshots and cropped vision
    }
}

public struct Spend: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(steps: Int = 0, modelCalls: Int = 0, promptTokens: Int = 0, completionTokens: Int = 0, usd: Double = 0) {
        self.steps = steps
        self.modelCalls = modelCalls
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.usd = usd
    }
    public var steps: Int = 0
    public var modelCalls: Int = 0
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var usd: Double = 0

    public func exceeds(_ b: Budget) -> Bool {
        if steps >= b.maxSteps || modelCalls >= b.maxModelCalls { return true }
        if let cap = b.maxSpendUSD, usd >= cap { return true }
        return false
    }
}

// MARK: - Autonomy

/// How much the bot may decide for itself. A ladder rather than a switch, because "can it act
/// on its own" is not one question.
public enum Autonomy: Int, Codable, Hashable, CaseIterable, Comparable {
    case advisory = 0             // explain only
    case assisted = 1             // suggest actions; the user executes them
    case confirmBeforeChange = 2  // read freely, confirm every write
    case autonomousWorkspace = 3  // act freely inside a scoped environment
    case autonomousOperational = 4 // act across authorised systems, confirm consequential ones
    case delegatedOperator = 5    // broad authority within explicit policy

    public static func < (a: Autonomy, b: Autonomy) -> Bool { a.rawValue < b.rawValue }

    public var displayName: String {
        switch self {
        case .advisory:              return "Advisory"
        case .assisted:              return "Assisted"
        case .confirmBeforeChange:   return "Confirm before changing"
        case .autonomousWorkspace:   return "Autonomous in its workspace"
        case .autonomousOperational: return "Autonomous across systems"
        case .delegatedOperator:     return "Delegated operator"
        }
    }

    public var explanation: String {
        switch self {
        case .advisory:              return "Explains what it would do. Changes nothing."
        case .assisted:              return "Proposes actions for you to run yourself."
        case .confirmBeforeChange:   return "Reads anything it is allowed to. Asks before every change."
        case .autonomousWorkspace:   return "Works freely inside the folder you gave it. Asks to go outside."
        case .autonomousOperational: return "Works across the systems you authorised. Asks before consequential actions."
        case .delegatedOperator:     return "Acts broadly within written policy. For work you have watched it do many times."
        }
    }

    public var mayWriteWithoutAsking: Bool { self >= .autonomousWorkspace }
    public var mayActOutsideWorkspace: Bool { self >= .autonomousOperational }
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
public struct AgencyCheck {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(intentIsClear: Bool, withinScope: Bool, authorised: Bool, reversible: Bool, hasExternalConsequence: Bool) {
        self.intentIsClear = intentIsClear
        self.withinScope = withinScope
        self.authorised = authorised
        self.reversible = reversible
        self.hasExternalConsequence = hasExternalConsequence
    }
    /// Can the bot confidently infer what the user wants here?
    public var intentIsClear: Bool
    /// Is this inside the objective, rather than adjacent to it?
    public var withinScope: Bool
    /// Does the contract's authority actually permit it?
    public var authorised: Bool
    /// Could this be undone in a minute if it turns out wrong?
    public var reversible: Bool
    /// Does it reach outside this machine — send, publish, spend, deploy?
    public var hasExternalConsequence: Bool

    public enum Verdict: Equatable {
        case act
        case ask(because: String)
    }

    /// Every condition must hold, and the failure names itself so the resulting prompt can say
    /// something specific rather than "this needs approval".
    public var verdict: Verdict {
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
public struct SuccessCriterion: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), statement: String, kind: Kind, verifiedAt: Date? = nil, evidence: String? = nil) {
        self.id = id
        self.statement = statement
        self.kind = kind
        self.verifiedAt = verifiedAt
        self.evidence = evidence
    }
    public var id: UUID = UUID()

    /// Written for the user. "Signup completes in the browser."
    public var statement: String

    public var kind: Kind

    public var verifiedAt: Date?
    public var evidence: String?

    public enum Kind: Codable, Hashable {
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

    public var isVerified: Bool { verifiedAt != nil }
}

// MARK: - Authority

/// What the bot may technically do. Enforced by the tool layer before any model reasoning is
/// consulted, so a model that has convinced itself it may delete `~/.ssh` still cannot.
public struct Authority: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(readable: [String] = [], writable: [String] = [], denied: [String] = Authority.alwaysDenied, granted: Set<String> = [], requiresApproval: Set<String> = [], selfRepair: Bool = true, maySpend: Bool = false) {
        self.readable = readable
        self.writable = writable
        self.denied = denied
        self.granted = granted
        self.requiresApproval = requiresApproval
        self.selfRepair = selfRepair
        self.maySpend = maySpend
    }
    /// Paths the bot may read.
    public var readable: [String] = []
    /// Paths the bot may write. Always a subset of readable in practice.
    public var writable: [String] = []
    /// Paths that are refused outright, overriding everything above.
    public var denied: [String] = Authority.alwaysDenied

    /// Paths no bot may ever read, whatever else it is granted.
    ///
    /// The credential file is on this list and that is not optional. Keys used to live in the
    /// keychain, where a bot with filesystem access could not reach them no matter what paths
    /// it held. They now live in a file inside Application Support, so the protection that was
    /// structural has to become explicit — without this line, moving off the keychain would be
    /// a straight downgrade rather than a trade.
    public static let alwaysDenied: [String] = [
        "~/.ssh/**",
        "~/.aws/**",
        "~/.gnupg/**",
        "~/.netrc",
        "~/.config/gh/**",
        "~/.kube/config",
        "~/.docker/config.json",
        "~/Library/Keychains/**",
        "~/Library/Cookies/**",
        "~/Library/Application Support/Bot-Harness/credentials.json",
        // The glob covers the app's own `credentials.json.tmp` and the `credentials.json.<rand>.tmp`
        // files `scripts/set-key.sh` creates. Both are complete plaintext copies of every key, and
        // a deny list can only protect what it can name — so the script was changed to use a
        // predictable prefix rather than the list being changed to guess a random one.
        "~/Library/Application Support/Bot-Harness/credentials.json.**",
    ]

    /// Paths no bot may ever *write*, though it may read them.
    ///
    /// Separate from `alwaysDenied` because the direction matters. A bot reading its own trace is
    /// how it recovers from a mistake and is worth keeping; a bot *rewriting* its own trace makes
    /// the record worthless.
    ///
    /// The chain is now keyed with an HMAC whose secret lives in the credential file, which is on
    /// the read-deny list above — so a bot that edits a trace can no longer re-chain it to match,
    /// and tampering is detected rather than merely inconvenienced. This ban is still worth
    /// keeping: detecting destruction after the fact is not the same as preventing it, and a bot
    /// that deletes its own record leaves nothing to verify.
    public static let alwaysDeniedForWriting: [String] = [
        "~/Library/Application Support/Bot-Harness/traces/**",
        "~/Library/Application Support/Bot-Harness/state.json",
    ]

    /// Bulk commands widen a deny check to *containers* of a protected path, so archiving or
    /// copying a whole tree cannot carry the keys out without ever naming them.
    public static let bulkExecutables: Set<String> = [
        "cp", "rsync", "ditto", "tar", "zip", "gzip", "gtar", "pax", "cpio",
        "mv", "scp", "sftp", "rclone", "7z", "shutil",
    ]

    /// Named capabilities, e.g. "github.commit", "shell.exec", "browser.navigate".
    public var granted: Set<String> = []
    /// Capabilities that exist but need a human first, e.g. "github.merge_main".
    public var requiresApproval: Set<String> = []

    /// Permission to fix its own environment.
    ///
    /// A surprisingly large share of agent failures are environmental — a missing dev
    /// dependency, a crashed browser, a port already in use, a stale process, an absent temp
    /// directory. An agent that must ask about each of these feels helpless, and the asking
    /// teaches the user to approve without reading. All of these are inside the workspace,
    /// all are reversible, none deserve a prompt.
    public var selfRepair: Bool = true

    /// Spending money, at all. Separate from `granted` because it is the one capability whose
    /// absence should be the default no matter how the rest is configured.
    public var maySpend: Bool = false

    public static let selfRepairActions: Set<String> = [
        "install a missing development dependency",
        "restart a crashed browser",
        "kill a stale local process holding a port it needs",
        "create a temporary directory",
        "retry a failed network request",
        "clear a local cache",
        "choose a different local port",
    ]

    // MARK: - The authority a real run gets

    /// What an ordinary run may touch: its workspace, the Desktop, and whatever the user
    /// attached.
    ///
    /// This used to be assembled inline in `BotRunner`, which put the single most consequential
    /// list in the product inside the app target — the one target the test bundle does not
    /// link. Every test that thought it was checking the boundary was checking an `Authority`
    /// it had built itself, and the list the app actually shipped was verified by reading it.
    /// It lives here now so a test can assert on the real thing.
    ///
    /// `attachments` is the only part that varies with what the user has done, and it is
    /// additive by construction: it can widen `readable` and can never widen `writable`,
    /// because dragging a file in is consent to read it and nothing else. A bot that could
    /// overwrite whatever you dropped on it would make the drop gesture dangerous, and the
    /// gesture has to stay cheap enough to use without thinking.
    public static func forWorkspace(_ workspace: String,
                                    attachments: [Attachment] = []) -> Authority {
        Authority(
            readable: [workspace + "/**", NSHomeDirectory() + "/Desktop/**"]
                + attachments.map(\.readablePattern),
            writable: [workspace + "/**"],
            // `capability.read` and `capability.use` were both missing, and their absence was
            // silent in the worst way: a capability that is in neither `granted` nor
            // `requiresApproval` is refused on every call, so `capability.search` and
            // `capability.load` — the two tools whose entire job is reaching something the
            // router did not anticipate — were dead in every run the app has ever done. The
            // model chose them, was refused, and had no way to learn why.
            granted: ["files.read", "files.write", "shell.exec", "git.read", "git.commit",
                      "web.search", "web.read", "browser.use", "computer.observe",
                      "computer.control", "memory.read", "memory.write",
                      "capability.read", "capability.use"],
            requiresApproval: ["git.push", "files.delete"],
            selfRepair: true,
            maySpend: false)
    }

    public func permits(_ capability: String) -> Bool { granted.contains(capability) }
    public func needsApproval(for capability: String) -> Bool { requiresApproval.contains(capability) }
}

// MARK: - Escalation

/// Why a run stopped to ask.
///
/// High agency does not mean never asking. It means asking only when asking is the highest
/// leverage action available — and then asking in a shape the user can answer in one word.
public struct Escalation: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(reason: Reason, completed: [String], request: String) {
        self.reason = reason
        self.completed = completed
        self.request = request
    }
    public var reason: Reason

    /// What is already done. An escalation that does not say this makes the user re-derive
    /// the state of the work before they can answer.
    public var completed: [String]

    /// The single thing being asked for, stated as a decision rather than an open question.
    /// "I need your approval to deploy commit 4af913 to production" — not "what next?"
    public var request: String

    public enum Reason: String, Codable, Hashable {
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
