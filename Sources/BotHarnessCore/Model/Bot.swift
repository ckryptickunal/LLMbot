import Foundation

/// A bot is a named agent with a persistent identity. It is the central object of the
/// product: everything a user configures, they configure on a bot.
///
/// Bots are plain `Codable` values. All mutation goes through `Store`, which owns
/// persistence and is the only place that writes to disk.
public struct Bot: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), name: String, label: String = "", persona: String = "", avatar: Avatar = Avatar(), brain: BrainSpec = .claudeCode, environment: EnvironmentKind = .thisMac, workspace: URL? = nil, enabledPlugins: Set<String> = [], rules: [PermissionRule] = [], notifies: Bool = true, memory: [MemoryNote] = [], createdAt: Date = Date(), templateSource: String? = nil) {
        self.id = id
        self.name = name
        self.label = label
        self.persona = persona
        self.avatar = avatar
        self.brain = brain
        self.environment = environment
        self.workspace = workspace
        self.enabledPlugins = enabledPlugins
        self.rules = rules
        self.notifies = notifies
        self.memory = memory
        self.createdAt = createdAt
        self.templateSource = templateSource
    }
    public var id: UUID = UUID()

    // MARK: Identity — what the user sees

    /// What you call it. Shown in the sidebar and the chat header.
    public var name: String

    /// Optional short tag, e.g. "Research, marketing, admin". Purely for the user's own
    /// filing; the bot never sees it.
    public var label: String = ""

    /// The persona and standing instructions, written in plain language about the user and
    /// the job. This becomes the system prompt.
    ///
    /// Grok Bot's own examples are the model to follow — they read as briefings, not as
    /// prompt engineering: "Runs corporate partnership outreach for JewelAI: finds the right
    /// big-company owners, drafts warm founder emails from kunal@araviai.com, and never leads
    /// with selling the company."
    public var persona: String = ""

    /// Deterministic visual identity, derived from `id` so it is stable across renames.
    public var avatar: Avatar = Avatar()

    /// Whether the description is the bot's own or the user's.
    ///
    /// Set to false the instant someone edits it by hand, and never set back. A bot that
    /// rewrites words you typed is not helpful; the user always wins.
    public var personaIsAuto: Bool = true

    /// Same for the name.
    public var nameIsAuto: Bool = true

    /// How many user turns had happened when the description was last written, so it can
    /// settle instead of churning on every message.
    public var describedAtTurn: Int = 0

    // MARK: Capability — what it can do

    /// Which model runs this bot. Per bot, never global: a routine that watches an inbox
    /// should not cost what a bot that writes code costs.
    public var brain: BrainSpec = .gemini(model: "gemini-3.7-flash")

    /// Where this bot's computer is.
    public var environment: EnvironmentKind = .thisMac

    /// How much this bot decides on its own, as a starting point for each run.
    ///
    /// Surfaced in the composer as three names — Ask, Work, Autopilot — because nobody should
    /// have to think in six rungs to send a message. The ladder underneath keeps its full
    /// resolution for contracts that need it.
    public var defaultAutonomy: Autonomy = .confirmBeforeChange

    /// The directory this bot treats as home. File and shell tools are scoped to it unless
    /// a permission rule widens that.
    public var workspace: URL?

    /// Identifiers of the plugins this bot may reach for. A subset of what is installed;
    /// giving every bot every tool is how you get a bot that does the wrong thing well.
    public var enabledPlugins: Set<String> = []

    /// Rules layered over the global floor. See `PermissionRule`.
    public var rules: [PermissionRule] = []

    // MARK: Behaviour

    /// Whether this bot may interrupt you when it finishes or gets stuck.
    public var notifies: Bool = true

    /// What it has learned that should outlive any single conversation. Written by the bot,
    /// editable by the user, injected into every system prompt.
    public var memory: [MemoryNote] = []

    public var createdAt: Date = Date()

    /// Templates carry everything above except credentials, history, and workspace paths.
    public var templateSource: String?
}

/// Where a bot's computer lives.
///
/// The abstraction exists from day one even though only `thisMac` ships first. Retrofitting
/// it later would mean rewriting every tool, because the tools are written against the
/// environment, not against macOS.
public enum EnvironmentKind: String, Codable, Hashable, CaseIterable {
    /// The user's real machine. Real files, real logged-in browser sessions, real apps.
    /// Enormously more useful, and the reason the permission system exists.
    case thisMac

    /// A disposable container. Cannot touch anything that matters, and correspondingly
    /// cannot help with most of what the user actually wants.
    case container

    public var displayName: String {
        switch self {
        case .thisMac:   return "This Mac"
        case .container: return "Container"
        }
    }

    public var explanation: String {
        switch self {
        case .thisMac:
            return "Your real files, your signed-in browser, your apps. Guarded by permissions."
        case .container:
            return "A throwaway Linux machine. Nothing it does can affect your Mac."
        }
    }
}

/// Which model answers for this bot, and how hard it thinks.
///
/// `claudeCLI` is deliberately first-class rather than a fallback: a Claude Code subscription
/// is a brain, and treating the local CLI as a provider is what lets someone with no API key
/// at all use this app.
public enum BrainSpec: Codable, Hashable {
    /// Google's Gemini API over HTTPS, using a key from the Keychain.
    case gemini(model: String)

    /// The local `claude` binary in headless streaming mode. Billed to the user's Claude
    /// subscription, so no API key is required.
    case claudeCLI(model: String?)

    /// Anthropic's API directly, for users who have a key rather than a subscription.
    case anthropic(model: String)

    case openAI(model: String)

    /// The default brain: the signed-in `claude` CLI, which needs no API key.
    public static var claudeCode: BrainSpec { .claudeCLI(model: nil) }

    public var displayName: String {
        switch self {
        case .gemini(let m):    return m
        case .claudeCLI(let m): return m.map { "Claude Code · \($0)" } ?? "Claude Code"
        case .anthropic(let m): return m
        case .openAI(let m):    return m
        }
    }

    /// Short enough for a chip. "gemini-3.7-flash" becomes "Gemini 3.7 Flash".
    public var shortName: String {
        switch self {
        case .gemini(let m):
            return m.replacingOccurrences(of: "gemini-", with: "Gemini ")
                    .replacingOccurrences(of: "-flash-lite", with: " Flash-Lite")
                    .replacingOccurrences(of: "-flash", with: " Flash")
        case .claudeCLI:        return "Claude Code"
        case .anthropic(let m): return m.replacingOccurrences(of: "claude-", with: "Claude ").capitalized
        case .openAI(let m):    return m.uppercased()
        }
    }

    /// The Keychain account this brain needs, or nil if it needs no key.
    public var keychainAccount: String? {
        switch self {
        case .gemini:    return "gemini"
        case .anthropic: return "anthropic"
        case .openAI:    return "openai"
        case .claudeCLI: return nil   // billed to the signed-in CLI
        }
    }
}

/// A stable, generated visual identity. Real image avatars can come later; what matters now
/// is that two bots never look alike in the sidebar.
public struct Avatar: Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(hue: Double = Double.random(in: 0...1), glyph: String = "●") {
        self.hue = hue
        self.glyph = glyph
    }
    /// Index into the palette. Derived from the bot's id on creation.
    public var hue: Double = Double.random(in: 0...1)
    public var glyph: String = "●"
}

/// Something the bot learned that should survive the conversation it learned it in.
///
/// Kept deliberately small and structured rather than as a vector store: for a single user
/// with a handful of bots, a short list of explicit facts that the user can read and delete
/// beats a similarity search they cannot inspect.
public struct MemoryNote: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: UUID = UUID(), text: String, reason: String = "", learnedAt: Date = Date(), confirmedByUser: Bool = false) {
        self.id = id
        self.text = text
        self.reason = reason
        self.learnedAt = learnedAt
        self.confirmedByUser = confirmedByUser
    }
    public var id: UUID = UUID()
    public var text: String
    /// Why this was worth remembering. Present so the user can judge whether to keep it.
    public var reason: String = ""
    public var learnedAt: Date = Date()
    /// Set when the user edits or confirms a note the bot wrote.
    public var confirmedByUser: Bool = false
}
