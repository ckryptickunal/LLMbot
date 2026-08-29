import Foundation

/// A bot is a named agent with a persistent identity. It is the central object of the
/// product: everything a user configures, they configure on a bot.
///
/// Bots are plain `Codable` values. All mutation goes through `Store`, which owns
/// persistence and is the only place that writes to disk.
struct Bot: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    // MARK: Identity — what the user sees

    /// What you call it. Shown in the sidebar and the chat header.
    var name: String

    /// Optional short tag, e.g. "Research, marketing, admin". Purely for the user's own
    /// filing; the bot never sees it.
    var label: String = ""

    /// The persona and standing instructions, written in plain language about the user and
    /// the job. This becomes the system prompt.
    ///
    /// Grok Bot's own examples are the model to follow — they read as briefings, not as
    /// prompt engineering: "Runs corporate partnership outreach for JewelAI: finds the right
    /// big-company owners, drafts warm founder emails from kunal@araviai.com, and never leads
    /// with selling the company."
    var persona: String = ""

    /// Deterministic visual identity, derived from `id` so it is stable across renames.
    var avatar: Avatar = Avatar()

    // MARK: Capability — what it can do

    /// Which model runs this bot. Per bot, never global: a routine that watches an inbox
    /// should not cost what a bot that writes code costs.
    var brain: BrainSpec = .claudeCode

    /// Where this bot's computer is.
    var environment: EnvironmentKind = .thisMac

    /// The directory this bot treats as home. File and shell tools are scoped to it unless
    /// a permission rule widens that.
    var workspace: URL?

    /// Identifiers of the plugins this bot may reach for. A subset of what is installed;
    /// giving every bot every tool is how you get a bot that does the wrong thing well.
    var enabledPlugins: Set<String> = []

    /// Rules layered over the global floor. See `PermissionRule`.
    var rules: [PermissionRule] = []

    // MARK: Behaviour

    /// Whether this bot may interrupt you when it finishes or gets stuck.
    var notifies: Bool = true

    /// What it has learned that should outlive any single conversation. Written by the bot,
    /// editable by the user, injected into every system prompt.
    var memory: [MemoryNote] = []

    var createdAt: Date = Date()

    /// Templates carry everything above except credentials, history, and workspace paths.
    var templateSource: String?
}

/// Where a bot's computer lives.
///
/// The abstraction exists from day one even though only `thisMac` ships first. Retrofitting
/// it later would mean rewriting every tool, because the tools are written against the
/// environment, not against macOS.
enum EnvironmentKind: String, Codable, Hashable, CaseIterable {
    /// The user's real machine. Real files, real logged-in browser sessions, real apps.
    /// Enormously more useful, and the reason the permission system exists.
    case thisMac

    /// A disposable container. Cannot touch anything that matters, and correspondingly
    /// cannot help with most of what the user actually wants.
    case container

    var displayName: String {
        switch self {
        case .thisMac:   return "This Mac"
        case .container: return "Container"
        }
    }

    var explanation: String {
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
enum BrainSpec: Codable, Hashable {
    /// Google's Gemini API over HTTPS, using a key from the Keychain.
    case gemini(model: String)

    /// The local `claude` binary in headless streaming mode. Billed to the user's Claude
    /// subscription, so no API key is required.
    case claudeCLI(model: String?)

    /// Anthropic's API directly, for users who have a key rather than a subscription.
    case anthropic(model: String)

    case openAI(model: String)

    /// The default brain: the signed-in `claude` CLI, which needs no API key.
    static var claudeCode: BrainSpec { .claudeCLI(model: nil) }

    var displayName: String {
        switch self {
        case .gemini(let m):    return m
        case .claudeCLI(let m): return m.map { "Claude Code · \($0)" } ?? "Claude Code"
        case .anthropic(let m): return m
        case .openAI(let m):    return m
        }
    }

    /// The Keychain account this brain needs, or nil if it needs no key.
    var keychainAccount: String? {
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
struct Avatar: Codable, Hashable {
    /// Index into the palette. Derived from the bot's id on creation.
    var hue: Double = Double.random(in: 0...1)
    var glyph: String = "●"
}

/// Something the bot learned that should survive the conversation it learned it in.
///
/// Kept deliberately small and structured rather than as a vector store: for a single user
/// with a handful of bots, a short list of explicit facts that the user can read and delete
/// beats a similarity search they cannot inspect.
struct MemoryNote: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var text: String
    /// Why this was worth remembering. Present so the user can judge whether to keep it.
    var reason: String = ""
    var learnedAt: Date = Date()
    /// Set when the user edits or confirms a note the bot wrote.
    var confirmedByUser: Bool = false
}
