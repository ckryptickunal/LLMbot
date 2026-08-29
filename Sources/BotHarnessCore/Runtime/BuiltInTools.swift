import Foundation

/// The tools that ship with the app, before any plugin is installed.
///
/// Ordered by how often they are the right answer, which is roughly the inverse of how
/// impressive they look in a demo: reading a file and running a command solve far more real
/// tasks than clicking a screen does.
extension ToolRegistry {

    public static let builtIn: [ToolDescriptor] = filesTools + shellTools + developmentTools
        + researchTools + browserTools + computerTools + memoryTools

    // MARK: Files

    public static let filesTools: [ToolDescriptor] = [
        ToolDescriptor(
            id: "files.read", domain: .files, surface: .code,
            summary: "Read a file, or a line range of one.",
            schema: #"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}"#,
            capability: "files.read", floorCategory: nil,
            keywords: ["open", "cat", "view", "contents"]),

        ToolDescriptor(
            id: "files.write", domain: .files, surface: .code,
            summary: "Write a file, replacing it if it exists.",
            schema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#,
            capability: "files.write", floorCategory: nil,
            keywords: ["create", "save", "overwrite"]),

        ToolDescriptor(
            id: "files.patch", domain: .files, surface: .code,
            summary: "Replace an exact string in a file. Preferred over rewriting a whole file.",
            schema: #"{"type":"object","properties":{"path":{"type":"string"},"find":{"type":"string"},"replace":{"type":"string"}},"required":["path","find","replace"]}"#,
            capability: "files.write", floorCategory: nil,
            keywords: ["edit", "modify", "change", "fix"]),

        ToolDescriptor(
            id: "files.search", domain: .files, surface: .code,
            summary: "Search file contents by regular expression, across a directory tree.",
            schema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"}},"required":["pattern"]}"#,
            capability: "files.read", floorCategory: nil,
            keywords: ["grep", "ripgrep", "find text", "look for", "where is"]),

        ToolDescriptor(
            id: "files.glob", domain: .files, surface: .code,
            summary: "List files matching a glob pattern, newest first.",
            schema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}"#,
            capability: "files.read", floorCategory: nil,
            keywords: ["list", "ls", "which files", "find files"]),

        ToolDescriptor(
            id: "files.delete", domain: .files, surface: .code,
            summary: "Delete a file. Refused outside the bot's workspace.",
            schema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#,
            capability: "files.delete", floorCategory: .destructiveDelete,
            keywords: ["remove", "rm", "trash"]),
    ]

    // MARK: Shell

    public static let shellTools: [ToolDescriptor] = [
        ToolDescriptor(
            id: "shell.exec", domain: .shell, surface: .code,
            summary: "Run a command and wait for it to finish. For anything that returns promptly.",
            schema: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"timeout":{"type":"integer"}},"required":["command"]}"#,
            capability: "shell.exec", floorCategory: nil,
            keywords: ["run", "terminal", "bash", "zsh", "execute", "npm", "python", "make"]),

        // The reason a separate process API exists at all: `exec` cannot run a dev server.
        // Without these, an agent asked to start something and then check it either blocks
        // forever or kills the thing it just started.
        ToolDescriptor(
            id: "shell.start_process", domain: .shell, surface: .code,
            summary: "Start a long-running process and keep working. Returns a handle.",
            schema: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"name":{"type":"string"}},"required":["command"]}"#,
            capability: "shell.exec", floorCategory: nil,
            keywords: ["dev server", "watch", "background", "daemon", "serve", "start"]),

        ToolDescriptor(
            id: "shell.read_process", domain: .shell, surface: .code,
            summary: "Read new output from a running process since you last looked.",
            schema: #"{"type":"object","properties":{"handle":{"type":"string"},"stream":{"type":"string","enum":["stdout","stderr","both"]}},"required":["handle"]}"#,
            capability: "shell.exec", floorCategory: nil,
            keywords: ["logs", "output", "stdout", "stderr", "tail"]),

        ToolDescriptor(
            id: "shell.kill_process", domain: .shell, surface: .code,
            summary: "Stop a process this bot started.",
            schema: #"{"type":"object","properties":{"handle":{"type":"string"},"signal":{"type":"string"}},"required":["handle"]}"#,
            capability: "shell.exec", floorCategory: nil,
            keywords: ["stop", "terminate", "kill"]),
    ]

    // MARK: Development

    public static let developmentTools: [ToolDescriptor] = [
        ToolDescriptor(
            id: "git.status", domain: .development, surface: .code,
            summary: "Working tree status: what changed, what is staged, which branch.",
            schema: #"{"type":"object","properties":{"cwd":{"type":"string"}}}"#,
            capability: "git.read", floorCategory: nil, keywords: ["changed", "dirty", "branch"]),

        ToolDescriptor(
            id: "git.diff", domain: .development, surface: .code,
            summary: "Show a diff of changes, staged or unstaged.",
            schema: #"{"type":"object","properties":{"cwd":{"type":"string"},"staged":{"type":"boolean"},"path":{"type":"string"}}}"#,
            capability: "git.read", floorCategory: nil, keywords: ["diff", "what changed", "review"]),

        ToolDescriptor(
            id: "git.commit", domain: .development, surface: .code,
            summary: "Stage and commit changes with a message.",
            schema: #"{"type":"object","properties":{"cwd":{"type":"string"},"message":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}}},"required":["message"]}"#,
            capability: "git.commit", floorCategory: nil, keywords: ["commit", "save changes"]),

        ToolDescriptor(
            id: "git.push", domain: .development, surface: .code,
            summary: "Push commits to a remote.",
            schema: #"{"type":"object","properties":{"cwd":{"type":"string"},"remote":{"type":"string"},"branch":{"type":"string"}}}"#,
            capability: "git.push", floorCategory: .rewritingSharedHistory,
            keywords: ["push", "publish", "upload"]),

        ToolDescriptor(
            id: "test.run", domain: .development, surface: .code,
            summary: "Run the project's tests, optionally filtered to one target.",
            schema: #"{"type":"object","properties":{"cwd":{"type":"string"},"filter":{"type":"string"}}}"#,
            capability: "shell.exec", floorCategory: nil,
            keywords: ["test", "spec", "suite", "verify", "check"]),
    ]

    // MARK: Research

    public static let researchTools: [ToolDescriptor] = [
        ToolDescriptor(
            id: "web.search", domain: .research, surface: .api,
            summary: "Search the web and get titles, URLs and snippets.",
            schema: #"{"type":"object","properties":{"query":{"type":"string"},"recency":{"type":"string"}},"required":["query"]}"#,
            capability: "web.search", floorCategory: nil,
            keywords: ["search", "google", "look up", "find out"]),

        ToolDescriptor(
            id: "web.open", domain: .research, surface: .api,
            summary: "Fetch a URL and return its readable text. Cheaper than opening a browser.",
            schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#,
            capability: "web.read", floorCategory: nil,
            keywords: ["read page", "fetch", "article", "documentation"]),
    ]

    // MARK: Browser

    public static let browserTools: [ToolDescriptor] = [
        ToolDescriptor(
            id: "browser.navigate", domain: .browser, surface: .structuredBrowser,
            summary: "Point the browser at a URL.",
            schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#,
            capability: "browser.use", floorCategory: nil, keywords: ["go to", "visit", "open"]),

        ToolDescriptor(
            id: "browser.extract", domain: .browser, surface: .structuredBrowser,
            summary: "Get the page's text or a named element's value, without a screenshot.",
            schema: #"{"type":"object","properties":{"selector":{"type":"string"}}}"#,
            capability: "browser.use", floorCategory: nil, keywords: ["read", "text", "content", "scrape"]),

        ToolDescriptor(
            id: "browser.click", domain: .browser, surface: .structuredBrowser,
            summary: "Click an element by selector or accessible name.",
            schema: #"{"type":"object","properties":{"selector":{"type":"string"},"name":{"type":"string"}}}"#,
            capability: "browser.use", floorCategory: nil, keywords: ["click", "press", "tap", "button"]),

        ToolDescriptor(
            id: "browser.type", domain: .browser, surface: .structuredBrowser,
            summary: "Type into a field identified by selector or label.",
            schema: #"{"type":"object","properties":{"selector":{"type":"string"},"text":{"type":"string"}},"required":["text"]}"#,
            capability: "browser.use", floorCategory: nil, keywords: ["type", "fill", "enter", "form"]),
    ]

    // MARK: Computer

    public static let computerTools: [ToolDescriptor] = [
        // Listed before screenshot on purpose. The structured view is cheaper, more precise,
        // and answers most questions a screenshot would have been taken to answer.
        ToolDescriptor(
            id: "computer.state", domain: .computer, surface: .api,
            summary: "What is on screen, structurally: active app, windows, displays. No image.",
            schema: #"{"type":"object","properties":{}}"#,
            capability: "computer.observe", floorCategory: nil,
            keywords: ["what app", "which window", "active", "state"]),

        ToolDescriptor(
            id: "computer.accessibility_tree", domain: .computer, surface: .api,
            summary: "The controls in a window with their roles, names and enabled state.",
            schema: #"{"type":"object","properties":{"app":{"type":"string"}}}"#,
            capability: "computer.observe", floorCategory: nil,
            keywords: ["buttons", "controls", "elements", "fields", "menu"]),

        ToolDescriptor(
            id: "computer.screenshot", domain: .computer, surface: .api,
            summary: "Capture the screen or one window. Use when structure was not enough.",
            schema: #"{"type":"object","properties":{"window":{"type":"string"},"region":{"type":"array","items":{"type":"integer"}}}}"#,
            capability: "computer.observe", floorCategory: nil,
            keywords: ["screenshot", "look", "see", "capture", "image"]),

        ToolDescriptor(
            id: "computer.click", domain: .computer, surface: .gui,
            summary: "Click at a point on screen.",
            schema: #"{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"string"},"intent":{"type":"string"}},"required":["x","y","intent"]}"#,
            capability: "computer.control", floorCategory: nil, keywords: ["click", "press", "select"]),

        ToolDescriptor(
            id: "computer.type", domain: .computer, surface: .gui,
            summary: "Type text into whatever has focus.",
            schema: #"{"type":"object","properties":{"text":{"type":"string"},"intent":{"type":"string"}},"required":["text","intent"]}"#,
            capability: "computer.control", floorCategory: nil, keywords: ["type", "enter", "write"]),

        ToolDescriptor(
            id: "computer.key", domain: .computer, surface: .gui,
            summary: "Press a key or a chord, e.g. cmd+s.",
            schema: #"{"type":"object","properties":{"keys":{"type":"string"},"intent":{"type":"string"}},"required":["keys","intent"]}"#,
            capability: "computer.control", floorCategory: nil, keywords: ["key", "shortcut", "hotkey", "escape", "enter"]),

        ToolDescriptor(
            id: "computer.launch_app", domain: .computer, surface: .api,
            summary: "Open an application by name.",
            schema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#,
            capability: "computer.control", floorCategory: nil, keywords: ["open app", "launch", "start"]),
    ]

    // MARK: Memory

    public static let memoryTools: [ToolDescriptor] = [
        ToolDescriptor(
            id: "memory.search", domain: .memory, surface: .api,
            summary: "Recall what this bot has learned that is relevant now.",
            schema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#,
            capability: "memory.read", floorCategory: nil, keywords: ["remember", "recall", "last time"]),

        ToolDescriptor(
            id: "memory.save", domain: .memory, surface: .api,
            summary: "Record something worth remembering next time, with why it mattered.",
            schema: #"{"type":"object","properties":{"text":{"type":"string"},"reason":{"type":"string"}},"required":["text"]}"#,
            capability: "memory.write", floorCategory: nil, keywords: ["remember this", "note", "learned"]),
    ]
}
