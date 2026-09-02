import Foundation

/// An MCP server, presented as a capability provider.
///
/// Connects lazily. A server that has never been needed is not spawned, which matters when
/// several of them are `npx` invocations that take a second or two and hold a Node process
/// open for as long as they live.
public actor MCPProvider: CapabilityProvider {

    public nonisolated let id: String
    public nonisolated let displayName: String

    private let client: MCPClient
    private let domain: CapabilityDomain
    private var lastHealth: ProviderHealth
    private var connectAttempted = false

    public init(config: MCPServerConfig) {
        self.id = config.id
        self.displayName = Self.knownName(config.id)
        self.domain = Self.domain(for: config.id)
        self.client = MCPClient(config: config)
        self.lastHealth = ProviderHealth(status: .initializing, detail: "not connected yet")
    }

    // MARK: Health

    public func health() async -> ProviderHealth { lastHealth }

    /// Connect if we have not already, and record what happened.
    @discardableResult
    public func ensureConnected() async -> ProviderHealth {
        if await client.isConnected {
            lastHealth = ProviderHealth(status: .healthy, detail: await client.serverName ?? id,
                                        toolCount: await client.tools.count)
            return lastHealth
        }
        connectAttempted = true
        do {
            try await client.connect()
            lastHealth = ProviderHealth(status: .healthy,
                                        detail: await client.serverName ?? id,
                                        toolCount: await client.tools.count)
        } catch {
            lastHealth = ProviderHealth(status: Self.classify(error), detail: Self.explain(error))
        }
        return lastHealth
    }

    /// Read the failure and say what the user should do about it, rather than showing them a
    /// stack of protocol vocabulary.
    private static func classify(_ error: Error) -> ProviderHealth.Status {
        let text = error.localizedDescription.lowercased()
        if text.contains("not authenticated") || text.contains("api key") || text.contains("unauthorized")
            || text.contains("401") || text.contains("missing") && text.contains("key") {
            return .needsAuth
        }
        if text.contains("could not connect") || text.contains("connection refused")
            || text.contains("timed out") || text.contains("closed") {
            return .offline
        }
        return .error
    }

    private static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.lowercased().contains("connection refused") || text.lowercased().contains("could not connect") {
            return "Not reachable — is the app running?"
        }
        return String(text.prefix(160))
    }

    // MARK: Capabilities

    public func discoverCapabilities() async -> [Capability] {
        await ensureConnected()
        let tools = await client.tools
        guard !tools.isEmpty else { return [] }

        return [Capability(
            id: "\(domain.rawValue).\(id)",
            domain: domain,
            provider: id,
            operations: tools.map(\.name),
            summary: Self.summary(for: id, toolCount: tools.count),
            surface: .api,
            risk: Self.risk(for: id),
            auth: Self.auth(for: id),
            keywords: Self.keywords(for: id) + tools.flatMap { $0.name.split(separator: "_").map(String.init) }
        )]
    }

    public func tools() async -> [MCPTool] {
        await ensureConnected()
        return await client.tools
    }

    public func operationDetails() async -> [String: (summary: String, schema: String)] {
        var out: [String: (summary: String, schema: String)] = [:]
        for tool in await tools() {
            out[tool.name] = (tool.description, tool.schema)
        }
        return out
    }

    public func invoke(operation: String, arguments: [String: Any]) async throws -> String {
        let health = await ensureConnected()
        guard health.status.isUsable else {
            throw MCPError.server("\(displayName) is \(health.status.displayName.lowercased()): \(health.detail)")
        }
        return try await client.call(operation, arguments: arguments)
    }

    public func disconnect() async { await client.disconnect() }

    // MARK: What we know about particular servers

    /// Known servers get a real name, a real domain and real search keywords. Unknown ones
    /// still work — they land in `.knowledge` and are searchable by their tool names — but
    /// naming the ones we know makes the resolver noticeably better at picking.
    private static func domain(for id: String) -> CapabilityDomain {
        switch id.lowercased() {
        case "perplexity", "reddit", "exa", "tavily":        return .research
        case "lightroom", "photos":                          return .media
        case "figma", "figma-desktop", "framer", "magic":    return .design
        case "slack", "gmail", "intercom":                   return .communication
        case "linear", "asana", "jira", "atlassian":         return .project
        case "notion", "confluence":                         return .knowledge
        case "github", "gitlab", "sentry", "vercel":         return .development
        case "drive", "google-drive", "dropbox":             return .documents
        default:                                             return .knowledge
        }
    }

    private static func knownName(_ id: String) -> String {
        switch id.lowercased() {
        case "perplexity":     return "Perplexity"
        case "lightroom":      return "Lightroom"
        case "framer":         return "Framer"
        case "figma-desktop":  return "Figma Desktop"
        case "figma":          return "Figma"
        case "magic":          return "21st.dev Magic"
        case "reddit":         return "Reddit"
        default:               return id.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private static func summary(for id: String, toolCount: Int) -> String {
        switch id.lowercased() {
        case "perplexity":
            return "Web-grounded search, questions, reasoning and deep research"
        case "lightroom":
            return "Search, rate, keyword, collect, develop and export photos in Lightroom"
        case "framer":
            return "Read and modify a Framer project: pages, components, styles, CMS"
        case "figma-desktop", "figma":
            return "Read and modify Figma designs"
        case "magic":
            return "Generate UI components"
        case "reddit":
            return "What people actually say in communities — experiences, complaints, consensus"
        default:
            return "\(toolCount) tools from \(knownName(id))"
        }
    }

    private static func risk(for id: String) -> Capability.Risk {
        switch id.lowercased() {
        case "perplexity", "reddit":              return .read
        case "lightroom":                         return .localWrite
        case "framer", "figma", "figma-desktop":  return .externalWrite
        default:                                  return .localWrite
        }
    }

    private static func auth(for id: String) -> Capability.AuthRequirement {
        switch id.lowercased() {
        case "perplexity", "magic":       return .apiKey
        case "figma-desktop", "lightroom": return .localApp
        case "framer":                     return .oauth
        default:                           return .none
        }
    }

    private static func keywords(for id: String) -> [String] {
        switch id.lowercased() {
        case "perplexity": return ["search", "research", "web", "look up", "find out", "news", "sources"]
        case "reddit":     return ["reddit", "community", "opinions", "complaints", "reviews", "sentiment", "experiences"]
        case "lightroom":  return ["photo", "photos", "image", "catalog", "raw", "edit", "export", "keyword", "rating"]
        case "framer":     return ["framer", "website", "landing page", "design", "cms", "publish"]
        case "figma-desktop", "figma": return ["figma", "design", "mockup", "component", "frame"]
        case "magic":      return ["component", "ui", "generate", "react"]
        default:           return []
        }
    }
}
