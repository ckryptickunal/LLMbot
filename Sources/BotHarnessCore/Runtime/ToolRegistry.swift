import Foundation

/// Everything the bot can invoke, and — more importantly — the machinery that keeps almost all
/// of it out of the model's context.
///
/// The registry can hold hundreds of tools. The model is shown five to fifteen. Presenting a
/// large tool list on every turn makes an agent slower, more expensive, and measurably worse
/// at choosing, so the registry's real job is not storage but *withholding*.

// MARK: - Domains

/// The unit the router works in. Tools are loaded by domain, never individually, because
/// intent classification is reliable at this granularity and unreliable below it.
public enum ToolDomain: String, Codable, CaseIterable, Hashable {
    case research      // searching and reading the web
    case browser       // driving a real browser
    case computer      // screen, keyboard, mouse, accessibility
    case shell         // commands and long-running processes
    case files         // read, write, patch, search
    case development   // git, github, docker, tests, builds
    case memory        // what this bot has learned
    case external      // MCP servers and connectors, namespaced by plugin

    public var summary: String {
        switch self {
        case .research:    return "search the web and read pages"
        case .browser:     return "drive a browser: navigate, click, extract, download"
        case .computer:    return "use the screen, keyboard and mouse of a computer"
        case .shell:       return "run commands and manage long-running processes"
        case .files:       return "read, write, patch and search files"
        case .development: return "git, GitHub, Docker, tests and builds"
        case .memory:      return "recall and record what this bot has learned"
        case .external:    return "installed plugins and connected services"
        }
    }
}

/// Which of the three action surfaces a tool represents.
///
/// This is the single highest-leverage classification in the harness, because it drives the
/// selector in `SurfaceSelector`. An agent that pixel-drives everything is the common failure
/// mode of computer-use demos; an agent that knows `rg authCallback` beats clicking a search
/// box is the difference between a demo and a tool.
public enum ActionSurface: String, Codable, Hashable, Comparable {
    /// A real API — typed, structured, no parsing, no ambiguity. Always preferred.
    case api
    /// Shell or a script. Machine-readable, deterministic, cheap.
    case code
    /// Structured browser access: DOM, selectors, CDP. Reliable where it applies.
    case structuredBrowser
    /// Pixels and synthesized input. Expensive, slow, and sometimes the only option.
    case gui
    /// Asking the user. Always available, and almost always the wrong first choice.
    case human

    /// Lower is cheaper and more reliable, so lower sorts first.
    public var cost: Int {
        switch self {
        case .api: return 0; case .code: return 1; case .structuredBrowser: return 2
        case .gui: return 3; case .human: return 4
        }
    }

    public static func < (a: ActionSurface, b: ActionSurface) -> Bool { a.cost < b.cost }
}

// MARK: - Tools

/// One invocable capability.
public struct ToolDescriptor: Identifiable, Codable, Hashable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(id: String, domain: ToolDomain, surface: ActionSurface, summary: String, schema: String, capability: String, floorCategory: SafetyFloor? = nil, keywords: [String] = []) {
        self.id = id
        self.domain = domain
        self.surface = surface
        self.summary = summary
        self.schema = schema
        self.capability = capability
        self.floorCategory = floorCategory
        self.keywords = keywords
    }
    /// Namespaced: "files.read", "github.create_issue", "computer.click".
    public var id: String

    public var domain: ToolDomain
    public var surface: ActionSurface

    /// One line, written for the model. This is what `tool.search` matches against and what
    /// the model reads when deciding, so it must say what the tool is *for*, not how it works.
    public var summary: String

    /// JSON Schema for the arguments. Only sent once the tool is in the active set.
    public var schema: String

    /// The capability name checked against `Authority` before this runs.
    public var capability: String

    /// Which `SafetyFloor` category this can land in, if any. Used to pre-classify rather than
    /// waiting for a model to notice that a shell command is about to delete something.
    public var floorCategory: SafetyFloor?

    /// Words that should pull this tool in during discovery, beyond its own name and summary.
    public var keywords: [String] = []
}

// MARK: - The registry

/// Holds every tool; hands out very few.
public actor ToolRegistry {
    private var tools: [String: ToolDescriptor] = [:]

    public init(_ initial: [ToolDescriptor] = ToolRegistry.builtIn) {
        for t in initial { tools[t.id] = t }
    }

    public func register(_ tool: ToolDescriptor) { tools[tool.id] = tool }
    public func register(contentsOf list: [ToolDescriptor]) { for t in list { tools[t.id] = t } }
    public func remove(_ id: String) { tools.removeValue(forKey: id) }

    public func all() -> [ToolDescriptor] { Array(tools.values).sorted { $0.id < $1.id } }
    public func tool(_ id: String) -> ToolDescriptor? { tools[id] }
    public func inDomains(_ domains: Set<ToolDomain>) -> [ToolDescriptor] {
        tools.values.filter { domains.contains($0.domain) }.sorted { $0.id < $1.id }
    }

    /// Mid-run discovery: "what could I use for this?"
    ///
    /// Returns names and one-line summaries only — never schemas. The model then calls
    /// `describe` or `load` for the handful it actually wants, which is what keeps a registry
    /// of hundreds affordable.
    public func search(_ query: String, limit: Int = 10) -> [(id: String, summary: String)] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }

        func score(_ t: ToolDescriptor) -> Int {
            let haystack = (t.id + " " + t.summary + " " + t.keywords.joined(separator: " ") + " " + t.domain.rawValue).lowercased()
            var s = 0
            for term in terms {
                if t.id.lowercased().contains(term) { s += 3 }
                else if t.keywords.contains(where: { $0.lowercased().contains(term) }) { s += 2 }
                else if haystack.contains(term) { s += 1 }
            }
            return s
        }

        // Written as explicit steps rather than a chain: the equivalent one-expression
        // version of this defeats Swift's type-checker and hangs the build.
        var scored: [(tool: ToolDescriptor, points: Int)] = []
        for tool in tools.values {
            let points = score(tool)
            if points > 0 { scored.append((tool: tool, points: points)) }
        }
        scored.sort { a, b in
            if a.points != b.points { return a.points > b.points }
            return a.tool.id < b.tool.id
        }

        var results: [(id: String, summary: String)] = []
        for entry in scored.prefix(limit) {
            results.append((id: entry.tool.id, summary: entry.tool.summary))
        }
        return results
    }

    /// Full schema for one tool.
    public func describe(_ id: String) -> ToolDescriptor? { tools[id] }
}

// MARK: - The capability router

/// Decides which domains this turn needs, so the registry can expose only those.
///
/// Classification is keyword-first and model-second on purpose. Most turns are unambiguous —
/// "run the tests", "read that file", "what's on the page" — and spending a model call to
/// discover that is latency for nothing. The model is consulted only when keywords are silent
/// or contradictory.
public struct CapabilityRouter {

    /// Domains that are always available, because a run that cannot read a file or record what
    /// it learned is crippled regardless of the task.
    public static let alwaysOn: Set<ToolDomain> = [.files, .memory]

    private static let signals: [ToolDomain: [String]] = [
        .research: ["search", "look up", "find out", "research", "who is", "what is", "compare",
                    "competitor", "news", "documentation", "docs for", "google"],
        .browser: ["website", "web page", "url", "browser", "chrome", "click the", "form",
                   "log in to", "download from", "scrape", "checkout", "dashboard"],
        .computer: ["screen", "app", "window", "click", "type into", "finder", "notes",
                    "messages", "mail", "photoshop", "figma", "open the app", "desktop"],
        .shell: ["run", "command", "terminal", "install", "start the", "server", "process",
                 "npm", "pnpm", "python", "build", "compile", "logs"],
        .files: ["file", "folder", "directory", "read", "write", "edit", "rename", "patch"],
        .development: ["git", "commit", "branch", "pull request", "pr ", "repo", "test",
                       "deploy", "docker", "github", "merge", "diff", "issue"],
        .memory: ["remember", "forget", "you said", "last time", "previously", "note that"],
    ]

    /// Cheap pass. Returns nil when it has no confident opinion, which is the signal to ask a
    /// model rather than guess.
    public func classify(_ text: String) -> Set<ToolDomain>? {
        let lower = text.lowercased()
        var hits: Set<ToolDomain> = []
        for (domain, words) in Self.signals where words.contains(where: { lower.contains($0) }) {
            hits.insert(domain)
        }
        guard !hits.isEmpty else { return nil }
        return hits.union(Self.alwaysOn)
    }

    /// The prompt used when the keyword pass is silent. Kept here rather than in the brain so
    /// that the router owns its own fallback and can be tested without a model.
    public func classificationPrompt(for text: String) -> String {
        let list = ToolDomain.allCases.map { "- \($0.rawValue): \($0.summary)" }.joined(separator: "\n")
        return """
        Which capability domains does this request need? Answer with a comma-separated list of \
        domain names and nothing else. Choose as few as will do the job.

        Domains:
        \(list)

        Request: \(text)
        """
    }

    public func parse(_ modelAnswer: String) -> Set<ToolDomain> {
        let names = modelAnswer.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        let parsed = Set(names.compactMap(ToolDomain.init(rawValue:)))
        return parsed.isEmpty ? Self.alwaysOn : parsed.union(Self.alwaysOn)
    }
}

// MARK: - The surface selector

/// Chooses *how* to do something, given several tools that could all achieve it.
///
/// The rule, in strict order: a real API, then code, then structured browser access, then the
/// GUI, and only then the user. "Find authCallback in my repository" is `rg authCallback`, not
/// opening an editor and clicking a search field. "What is my PR status" is the GitHub API, not
/// a browser. But "change this Photoshop setting" has no surface except the GUI.
///
/// Applying this one rule consistently is worth more to perceived capability than almost any
/// other single thing in the harness.
public struct SurfaceSelector {

    /// Rank candidate tools by how cheap and reliable their surface is.
    public func rank(_ candidates: [ToolDescriptor]) -> [ToolDescriptor] {
        candidates.sorted { a, b in
            a.surface == b.surface ? a.id < b.id : a.surface < b.surface
        }
    }

    /// The best available way to do something, or nil when only the user can.
    public func choose(_ candidates: [ToolDescriptor], authority: Authority) -> ToolDescriptor? {
        rank(candidates).first { authority.permits($0.capability) || authority.needsApproval(for: $0.capability) }
    }

    /// The instruction that goes into the system prompt. Stated as preference rather than
    /// prohibition, because there are real cases for every surface and a hard ban produces
    /// worse behaviour than a strong default.
    public static let doctrine = """
        Choose the cheapest surface that will actually work, in this order:

        1. A real API or tool, if one exists for this.
        2. Shell or a short script, if the thing is machine-readable.
        3. Structured browser access — selectors and page text — for the web.
        4. The screen, keyboard and mouse, when nothing above can reach it.
        5. Asking the user, when none of the above can.

        Searching a repository is ripgrep, not clicking through an editor. Checking a pull \
        request is the GitHub API, not a browser. Renaming two hundred files is one command, \
        not two hundred clicks. Use the screen when the thing genuinely has no other interface.
        """
}
