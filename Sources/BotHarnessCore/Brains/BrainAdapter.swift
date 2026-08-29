import Foundation

/// A model that can look at a situation and say what to do next.
///
/// **The harness owns the computer; the model provider does not.** Every capability in this
/// app — the executor, the permission floor, the trace, the verifier — lives behind this
/// protocol and knows nothing about which model is answering. That is deliberate and it is
/// worth the indirection: the best computer-use model in six months is unlikely to be the
/// best one today, and swapping it should be one file rather than a rewrite.
public protocol BrainAdapter: Sendable {
    /// Stable identifier for traces and cost accounting.
    var name: String { get }

    /// Whether this brain can drive a screen, as opposed to only talk.
    ///
    /// Borrowed from bloks, which splits providers into tool-running and chat-only. It is a
    /// real distinction and it bites: a Claude Code subscription is an excellent coding brain
    /// and cannot reach computer use at all through the CLI's print mode.
    var canDriveComputer: Bool { get }

    /// Whether the credential or binary this brain needs is actually present.
    func isConfigured() async -> Bool

    /// One turn: here is the situation, tell me the next action.
    func step(_ request: BrainRequest) async throws -> BrainResponse
}

// MARK: - What goes in

public struct BrainRequest: Sendable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(system: String, turns: [BrainTurn], tools: [ToolDescriptor], computerUse: ComputerUseMode = .off, screenshot: Data? = nil, observation: String? = nil) {
        self.system = system
        self.turns = turns
        self.tools = tools
        self.computerUse = computerUse
        self.screenshot = screenshot
        self.observation = observation
    }
    /// Persona, doctrine, contract, loaded skills. Assembled by the context router.
    public var system: String

    /// The conversation so far, already compacted.
    public var turns: [BrainTurn]

    /// Tool schemas currently exposed. Small on purpose — see `CapabilityRouter`.
    public var tools: [ToolDescriptor]

    /// Whether to attach the computer-use toolset, and for which environment.
    public var computerUse: ComputerUseMode = .off

    /// The most recent screenshot, if the observation ladder climbed that far.
    public var screenshot: Data?

    /// Structured observation: active app, windows, accessibility tree digest. Cheaper than
    /// a screenshot and usually sufficient, so it is sent even when a screenshot is not.
    public var observation: String?

    public enum ComputerUseMode: Sendable, Equatable {
        case off
        case desktop
        case browser
    }
}

public struct BrainTurn: Sendable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(role: Role, text: String, toolCallID: String? = nil) {
        self.role = role
        self.text = text
        self.toolCallID = toolCallID
    }
    public enum Role: String, Sendable { case user, assistant, tool }
    public var role: Role
    public var text: String
    /// Set on `.tool` turns so the model can match a result to the call it made.
    public var toolCallID: String?
}

// MARK: - What comes back

public struct BrainResponse: Sendable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(text: String? = nil, actions: [BrainAction], usage: Usage, raw: String? = nil) {
        self.text = text
        self.actions = actions
        self.usage = usage
        self.raw = raw
    }
    /// Prose for the user, if the model said anything.
    public var text: String?

    /// What it wants to do next. Empty means it believes it is finished — which the verifier,
    /// not the model, gets to decide.
    public var actions: [BrainAction]

    public var usage: Usage

    /// The raw response body, kept for the trace.
    ///
    /// Present because this adapter is written against a documented wire format that has not
    /// yet been exercised against a live key. When the first real run disagrees with the
    /// documentation, this is the field that will say how.
    public var raw: String?

    public struct Usage: Sendable {
        public var promptTokens: Int = 0
        public var completionTokens: Int = 0
        public var costUSD: Double = 0

        public init(promptTokens: Int = 0, completionTokens: Int = 0, costUSD: Double = 0) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.costUSD = costUSD
        }
    }
}

/// One thing the model wants done.
public struct BrainAction: Sendable, Identifiable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: String, name: String, arguments: [String: Any], intent: String? = nil, safety: SafetyDecision? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.intent = intent
        self.safety = safety
    }
    public var id: String
    /// Tool name: "files.read", or a computer-use action like "click_at".
    public var name: String
    /// Arguments as JSON.
    public var arguments: [String: Any]

    /// **The model's stated reason for this specific step.**
    ///
    /// Gemini returns this on every computer-use action as `intent`. It is the single most
    /// valuable field for the decision trace, because it is what makes the log answer *why*
    /// rather than only *what*, and it is what a permission prompt shows the user.
    public var intent: String?

    /// The provider's own safety judgement, when it offers one. Treated as an input to our
    /// floor, never as the decision — Google's docs are explicit that a disabled policy is
    /// only a preference and the model may still ask.
    public var safety: SafetyDecision?

    public struct SafetyDecision: Sendable {
        public var decision: String   // "allowed" | "require_confirmation" | "blocked"
        public var explanation: String

        public var requiresConfirmation: Bool { decision == "require_confirmation" }
        public var isBlocked: Bool { decision == "blocked" }

        public init(decision: String, explanation: String) {
            self.decision = decision
            self.explanation = explanation
        }
    }
}

// MARK: - Errors

public enum BrainError: LocalizedError {
    case notConfigured(String)
    case http(status: Int, body: String)
    case malformedResponse(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            return "\(what) is not set up yet. Add it in Settings (⌘,)."
        case .http(let status, let body):
            return "The model returned HTTP \(status): \(body.prefix(300))"
        case .malformedResponse(let detail):
            return "Could not read the model's response: \(detail)"
        case .refused(let why):
            return "The model declined: \(why)"
        }
    }
}
