import Foundation

/// A capability is something the agent can *do*, named by what it achieves rather than by who
/// provides it.
///
/// The distinction is the whole point. The model should think "I need to search customer
/// conversations", not "I should call Intercom". The resolver decides that Intercom is the
/// best provider for that today, that Slack is the fallback, and that both are unavailable so
/// it had better ask. When the provider changes — and it will — nothing above this line moves.
public struct Capability: Identifiable, Sendable, Hashable {

    /// Dotted and hierarchical: `research.web`, `design.figma`, `computer.local`.
    public var id: String

    public var domain: CapabilityDomain

    /// Which provider satisfies it, e.g. "perplexity", "builtin", "lightroom".
    public var provider: String

    /// The concrete operations, as the provider names them.
    public var operations: [String]

    /// One line for the model, and for `capability.search`.
    public var summary: String

    public var surface: ActionSurface
    public var risk: Risk
    public var auth: AuthRequirement

    /// Capability ids to try when this one fails or is unavailable, in order.
    public var fallbacks: [String] = []

    /// Words that should surface this capability during a search, beyond its own text.
    public var keywords: [String] = []

    public enum Risk: String, Sendable, Codable, Hashable {
        case read           // observes only
        case localWrite     // changes something on this machine
        case externalWrite  // changes something other people can see
        case irreversible   // spends money, sends, publishes, deletes
    }

    public enum AuthRequirement: String, Sendable, Codable, Hashable {
        case none
        case apiKey
        case oauth
        case localApp       // needs an application running on this Mac
    }

    public init(id: String, domain: CapabilityDomain, provider: String, operations: [String],
                summary: String, surface: ActionSurface, risk: Risk,
                auth: AuthRequirement = .none, fallbacks: [String] = [], keywords: [String] = []) {
        self.id = id; self.domain = domain; self.provider = provider
        self.operations = operations; self.summary = summary; self.surface = surface
        self.risk = risk; self.auth = auth; self.fallbacks = fallbacks; self.keywords = keywords
    }
}

/// The top of the capability tree. Coarse on purpose: intent classification is reliable at
/// this granularity and unreliable below it.
public enum CapabilityDomain: String, Sendable, Codable, CaseIterable, Hashable {
    case research        // web, community, papers, news
    case communication   // mail, chat, messaging
    case project         // issues, tasks, tickets
    case knowledge       // notes, wikis, documents
    case development     // repos, builds, tests, deploys
    case design          // Figma, Framer, images
    case media           // photo and video libraries
    case documents       // cloud files and drives
    case computer        // this Mac, browsers, terminal
    case support         // customers and conversations
    case autonomy        // schedules, monitors, triggers, notifications

    public var summary: String {
        switch self {
        case .research:      return "search and read the web, communities and papers"
        case .communication: return "mail, chat and messaging"
        case .project:       return "issues, tasks and tickets"
        case .knowledge:     return "notes, wikis and internal documents"
        case .development:   return "repositories, builds, tests and deployments"
        case .design:        return "design files and prototypes"
        case .media:         return "photo and video libraries"
        case .documents:     return "cloud files and drives"
        case .computer:      return "this Mac: files, terminal, screen, browser"
        case .support:       return "customer conversations and support history"
        case .autonomy:      return "schedules, monitors, triggers and notifications"
        }
    }
}

// MARK: - Providers

/// Anything that can satisfy capabilities.
///
/// Built-in tools, MCP servers and future direct API clients all implement this, so the
/// registry above them never learns the difference.
public protocol CapabilityProvider: Actor {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }

    /// What this provider can do right now.
    func discoverCapabilities() async -> [Capability]

    /// Whether it is usable, and if not, why — in words a person can act on.
    func health() async -> ProviderHealth

    func invoke(operation: String, arguments: [String: Any]) async throws -> String

    /// The argument schema for each operation, keyed by operation name, and a line describing
    /// what it does.
    ///
    /// Without this, loading a capability told the model "you can now call: create_issue,
    /// list_issues" and nothing else — no arguments, no types, no description. The model then
    /// guessed an argument shape, the server rejected it, and the model guessed again. A
    /// provider that genuinely cannot describe itself returns nothing and the old behaviour
    /// stands, which is why this has a default rather than being required.
    func operationDetails() async -> [String: (summary: String, schema: String)]
}

public extension CapabilityProvider {
    func operationDetails() async -> [String: (summary: String, schema: String)] { [:] }
}

/// A provider's state.
///
/// The states that are not `healthy` are the important ones. A connector that needs a key or
/// whose app is closed must stay visible and say so — removing it from the list makes the
/// system look like it never supported the thing at all, which is both untrue and unfixable
/// from the user's side.
public struct ProviderHealth: Sendable, Hashable {
    public var status: Status
    public var detail: String
    public var toolCount: Int
    public var checkedAt: Date

    public enum Status: String, Sendable, Codable, Hashable, CaseIterable {
        case healthy
        case degraded       // works, but slowly or partially
        case needsAuth      // a key or sign-in is missing
        case initializing   // still starting
        case offline        // the process or host is not reachable
        case error          // something else went wrong

        public var isUsable: Bool { self == .healthy || self == .degraded }

        /// What the Connections screen offers to do about it.
        public var action: String? {
            switch self {
            case .healthy, .initializing: return nil
            case .degraded:               return "Check"
            case .needsAuth:              return "Connect"
            case .offline:                return "Repair"
            case .error:                  return "Reconnect"
            }
        }

        public var displayName: String {
            switch self {
            case .healthy:      return "Connected"
            case .degraded:     return "Degraded"
            case .needsAuth:    return "Needs sign-in"
            case .initializing: return "Starting"
            case .offline:      return "Offline"
            case .error:        return "Error"
            }
        }
    }

    public init(status: Status, detail: String = "", toolCount: Int = 0, checkedAt: Date = Date()) {
        self.status = status; self.detail = detail
        self.toolCount = toolCount; self.checkedAt = checkedAt
    }
}
