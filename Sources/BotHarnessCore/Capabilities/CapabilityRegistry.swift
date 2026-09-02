import Foundation

/// Everything the agent could do, and the machinery for finding the small part of it that
/// matters right now.
///
/// The rule this exists to enforce: **the model is never handed the whole catalogue.** Five
/// configured MCP servers already contribute forty tools; a dozen would contribute hundreds.
/// Sending them all on every turn makes an agent slower, costlier and measurably worse at
/// choosing. So the registry's real job is not storage — it is deciding what to withhold.
///
/// The model can go looking, mid-task, through two meta-tools:
///
/// - `capability.search("customer support conversations")` — names and one-liners only
/// - `capability.load("support.intercom")` — brings that provider's operations into reach
///
/// Which is what lets someone say "put these leads in HubSpot" and have the system discover
/// that it has no HubSpot capability, rather than confidently inventing one.
public actor CapabilityRegistry {

    private var providers: [String: any CapabilityProvider] = [:]
    private var capabilities: [String: Capability] = [:]
    private var healthCache: [String: ProviderHealth] = [:]

    /// Capabilities the model currently has operations for. Starts small and grows only when
    /// the model asks.
    private var loaded: Set<String> = []

    public init() {
        for capability in Self.builtIn {
            capabilities[capability.id] = capability
            loaded.insert(capability.id)     // the local machine is always in reach
        }
    }

    // MARK: Registration

    /// Register every MCP server configured on this machine.
    ///
    /// Registration does not connect. A server appears in the catalogue as `initializing`
    /// and is only spawned when something actually needs it, or when the Connections screen
    /// asks for its health.
    public func registerConfiguredMCPServers() {
        for config in MCPServerConfig.fromClaudeConfig() {
            let provider = MCPProvider(config: config)
            providers[provider.id] = provider
            healthCache[provider.id] = ProviderHealth(status: .initializing, detail: "not connected yet")
        }
    }

    public func register(_ provider: any CapabilityProvider) {
        // Replacing a provider used to drop the old one on the floor with its child process
        // still running. Anything already here is disconnected first.
        if let existing = providers[provider.id] as? MCPProvider {
            Task { await existing.disconnect() }
        }
        providers[provider.id] = provider
    }

    /// Connect to a provider and fold what it offers into the catalogue.
    @discardableResult
    public func discover(_ providerID: String) async -> ProviderHealth {
        guard let provider = providers[providerID] else {
            return ProviderHealth(status: .error, detail: "no provider called \(providerID)")
        }
        let discovered = await provider.discoverCapabilities()
        for capability in discovered { capabilities[capability.id] = capability }
        let health = await provider.health()
        healthCache[providerID] = health
        return health
    }

    /// Connect to everything. Used by the Connections screen and by `--connections`.
    public func discoverAll() async -> [(provider: String, name: String, health: ProviderHealth)] {
        var report: [(String, String, ProviderHealth)] = []
        for (id, provider) in providers.sorted(by: { $0.key < $1.key }) {
            let health = await discover(id)
            report.append((id, provider.displayName, health))
        }
        return report
    }

    // MARK: Reading

    /// Shut every provider down and forget it.
    ///
    /// `disconnect()` existed on both `MCPProvider` and `MCPClient` and had **zero callers**:
    /// not at the end of a run, not on stop, and not on quit. Every stdio MCP server this app
    /// spawned outlived it, and the Connections screen re-spawned a whole set each time it was
    /// opened, orphaning the previous ones. On a machine with 1.4 GB free that is not a tidiness
    /// problem, it is the machine filling up with abandoned node processes.
    public func shutdown() async {
        for (_, provider) in providers {
            if let mcp = provider as? MCPProvider { await mcp.disconnect() }
        }
        providers.removeAll()
        healthCache.removeAll()
        loaded.removeAll()
    }

    /// Disconnect one provider without forgetting it, so re-discovery does not leave the old
    /// process behind.
    public func disconnect(_ providerID: String) async {
        if let mcp = providers[providerID] as? MCPProvider { await mcp.disconnect() }
        healthCache.removeValue(forKey: providerID)
    }

    public func all() -> [Capability] { capabilities.values.sorted { $0.id < $1.id } }
    public func capability(_ id: String) -> Capability? { capabilities[id] }
    public func health(of providerID: String) -> ProviderHealth? { healthCache[providerID] }
    public func allHealth() -> [String: ProviderHealth] { healthCache }
    public func loadedCapabilities() -> [Capability] { loaded.compactMap { capabilities[$0] } }
    public func providerNames() -> [String: String] {
        providers.mapValues { $0.displayName }
    }

    // MARK: The meta-tools

    /// "What could I use for this?" — names and one-liners, never schemas.
    ///
    /// Unhealthy providers are still returned, marked, because "Intercom exists but needs
    /// signing in" is a far more useful answer than silence. Silence makes the model conclude
    /// the capability does not exist and invent a worse plan.
    public func search(_ query: String, limit: Int = 8) async -> [(capability: Capability, status: ProviderHealth.Status)] {
        let terms = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
        guard !terms.isEmpty else { return [] }

        var scored: [(Capability, Int)] = []
        for capability in capabilities.values {
            let haystack = ([capability.id, capability.summary, capability.provider,
                             capability.domain.rawValue, capability.domain.summary]
                            + capability.keywords + capability.operations)
                .joined(separator: " ").lowercased()
            var score = 0
            for term in terms where haystack.contains(term) { score += 1 }
            if capability.keywords.contains(where: { terms.contains($0) }) { score += 2 }
            if score > 0 { scored.append((capability, score)) }
        }
        scored.sort { a, b in a.1 == b.1 ? a.0.id < b.0.id : a.1 > b.1 }

        var results: [(Capability, ProviderHealth.Status)] = []
        for (capability, _) in scored.prefix(limit) {
            let status = healthCache[capability.provider]?.status ?? .healthy
            results.append((capability, status))
        }
        return results
    }

    /// Bring a capability's operations into reach for this run.
    public func load(_ capabilityID: String) async -> LoadOutcome {
        guard let capability = capabilities[capabilityID] else {
            // Try discovering it — the provider may be registered but never connected.
            if let provider = providers.values.first(where: { capabilityID.hasSuffix($0.id) }) {
                let health = await discover(provider.id)
                if let found = capabilities[capabilityID] {
                    loaded.insert(capabilityID)
                    return .loaded(found)
                }
                return .unavailable("\(provider.displayName) is \(health.status.displayName.lowercased()): \(health.detail)")
            }
            return .unavailable("There is no capability called \(capabilityID). Try capability.search first.")
        }

        var health = healthCache[capability.provider]
        if health == nil { health = await discover(capability.provider) }
        guard let health, health.status.isUsable else {
            let state = health?.status.displayName.lowercased() ?? "unavailable"
            return .unavailable("\(capability.provider) is \(state): \(health?.detail ?? "")")
        }
        loaded.insert(capabilityID)
        return .loaded(capability)
    }

    /// The outcome of asking for a capability. `unavailable` carries a sentence the model can
    /// relay to the user, because "Intercom needs signing in" is an answer and a failure is not.
    public enum LoadOutcome: Sendable {
        case loaded(Capability)
        case unavailable(String)
    }

    /// Run one operation, through whichever provider owns it.
    public func invoke(capability capabilityID: String, operation: String,
                       arguments: [String: Any]) async throws -> String {
        guard let capability = capabilities[capabilityID],
              let provider = providers[capability.provider]
        else { throw MCPError.server("no provider for \(capabilityID)") }
        return try await provider.invoke(operation: operation, arguments: arguments)
    }

    /// Real tool descriptors for a capability the model has just loaded.
    ///
    /// `capability.load` used to answer with a sentence — "you can now call: a, b, c" — and
    /// stop there. The operations never joined the exposed set, so the model was handed three
    /// names with no schemas and had to invent the arguments; and because `ToolRegistry` had
    /// never heard of them, `PermissionEngine` was called with a nil descriptor and skipped the
    /// authority check entirely. One missing step, two different holes.
    ///
    /// Every descriptor asks for `capability.use`, which is the permission to call something a
    /// connector provides at all. The narrower gate is upstream and unchanged: the registry
    /// only resolves operations belonging to capabilities that were explicitly loaded, and
    /// loading is itself an action the permission engine decides on.
    public func descriptors(for capabilityID: String) async -> [ToolDescriptor] {
        guard let capability = capabilities[capabilityID],
              let provider = providers[capability.provider] else { return [] }
        let details = await provider.operationDetails()

        return capability.operations.map { operation in
            let detail = details[operation]
            return ToolDescriptor(
                id: operation,
                domain: .external,
                surface: capability.surface,
                summary: detail?.summary.isEmpty == false
                    ? detail!.summary
                    : "\(operation), from \(capability.provider). \(capability.summary)",
                // An operation whose server did not describe its arguments still gets a schema,
                // because a model handed no schema at all tends to send nothing rather than to
                // ask. An empty object says "arguments exist and I was not told which".
                schema: detail?.schema ?? #"{"type":"object"}"#,
                capability: "capability.use",
                floorCategory: nil,
                keywords: capability.keywords)
        }
    }

    /// Find whichever loaded provider owns an operation name. MCP tool names are unique
    /// enough in practice that this is reliable, and it saves the model having to remember
    /// which server a tool came from.
    public func providerOwning(operation: String) -> (capability: Capability, provider: any CapabilityProvider)? {
        for id in loaded {
            guard let capability = capabilities[id],
                  capability.operations.contains(operation),
                  let provider = providers[capability.provider]
            else { continue }
            return (capability, provider)
        }
        return nil
    }

    // MARK: What ships without any connector

    /// The local machine, always available, never needing a connection.
    static let builtIn: [Capability] = [
        Capability(id: "computer.files", domain: .computer, provider: "builtin",
                   operations: ["files.read", "files.write", "files.patch", "files.search", "files.glob", "files.delete"],
                   summary: "Read, write, patch and search files on this Mac",
                   surface: .code, risk: .localWrite,
                   keywords: ["file", "folder", "read", "write", "edit", "search", "find"]),

        Capability(id: "computer.shell", domain: .computer, provider: "builtin",
                   operations: ["shell.exec", "shell.start_process", "shell.read_process", "shell.kill_process"],
                   summary: "Run commands and keep long-running processes going",
                   surface: .code, risk: .localWrite,
                   keywords: ["run", "command", "terminal", "server", "build", "test", "install"]),

        Capability(id: "computer.screen", domain: .computer, provider: "builtin",
                   operations: ["computer.state", "computer.accessibility_tree", "computer.screenshot",
                                "computer.click", "computer.type", "computer.key", "computer.launch_app"],
                   summary: "See and control the screen, keyboard and mouse of this Mac",
                   surface: .gui, risk: .localWrite,
                   keywords: ["screen", "click", "type", "app", "window", "desktop", "gui"]),

        Capability(id: "development.git", domain: .development, provider: "builtin",
                   operations: ["git.status", "git.diff", "git.commit", "git.push", "test.run"],
                   summary: "Inspect and change git repositories, and run tests",
                   surface: .code, risk: .localWrite,
                   keywords: ["git", "commit", "diff", "branch", "repo", "test"]),

        Capability(id: "research.web", domain: .research, provider: "builtin",
                   operations: ["web.search", "web.open"],
                   summary: "Search the web and read pages",
                   surface: .api, risk: .read,
                   fallbacks: ["research.perplexity"],
                   keywords: ["search", "web", "google", "look up", "documentation"]),
    ]
}
