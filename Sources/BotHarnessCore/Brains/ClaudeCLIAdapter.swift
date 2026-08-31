import Foundation

/// The local `claude` binary in headless mode, as a brain.
///
/// This exists because a Claude Code subscription is the one credential the user already has,
/// and `docs/PRODUCT.md` promises that it counts as a provider. Until this file existed the
/// promise was only in the copy: `BotRunner.brain(for:)` returned a Gemini adapter for every
/// case, so a person who followed Settings and added no key got a bot that failed on its first
/// message with an error about a provider they had never chosen.
///
/// ## The safety property this file has to hold
///
/// **The harness owns the tools. The CLI must never run one.** Claude Code is, by default, an
/// agent with a shell, a file editor and a browser. Letting it use them would route every
/// action around the permission floor, the path guard and the trace — that is, around the
/// entire spine of this product — and the user would see a bot that had already deleted the
/// file by the time they were asked. So the CLI is invoked with no tools at all and is used
/// purely as a language model that answers in a fixed envelope, and the harness executes what
/// the envelope asks for.
///
/// Four flags carry that, and each was checked against `claude 2.1.238` on this machine on
/// 2026-08-31 by reading the `system/init` line the CLI emits before it does anything:
///
/// | Flag | Verified effect |
/// |---|---|
/// | `--tools ""` | `"tools":["StructuredOutput"]` — no Bash, Read, Edit, Write or WebFetch |
/// | `--strict-mcp-config` | `"mcp_servers":[]`, so servers configured elsewhere are ignored |
/// | `--setting-sources ""` | `"plugins":[]`, and no user/project/local settings — **this is what keeps hooks out**, and a `SessionStart` hook is a shell command that would otherwise run on the user's Mac outside the harness entirely |
/// | `--permission-mode manual` | belt and braces: if a tool ever did appear, "manual" means ask a human, and `--print` has no human, so it is denied rather than run |
///
/// `StructuredOutput` is the CLI's own mechanism for `--json-schema` and cannot touch the
/// machine; it is how the envelope comes back.
///
/// **What this does not prevent, stated plainly:** these flags are the CLI's own, so the
/// guarantee is only as good as the CLI honouring them. A future version that changed the
/// meaning of `--tools ""` would reopen the hole silently. `ClaudeCLIAdapterTests` asserts the
/// four flags are present in the argument list so that removing one fails the suite, but no
/// test here can prove the CLI obeys them. If that matters more than convenience, the honest
/// answer is to use an API-key brain instead of this one.
///
/// ## Why an envelope rather than real tool calls
///
/// With `--tools ""` the model has no tool schemas, so there is no native tool-call channel to
/// parse. `--json-schema` gives a reliable one instead: the CLI validates the reply against the
/// schema and hands back a `structured_output` object on its final line. Rejected alternative:
/// exposing the harness's tools to the CLI over `--mcp-config` by running an MCP server inside
/// the app. That would produce native tool calls, and it would also mean the CLI holding a live
/// connection into the harness's executor — more moving parts, and a second path into the tool
/// layer that the permission floor would have to be taught about separately.
public struct ClaudeCLIAdapter: BrainAdapter {

    public let name: String

    /// `nil` means "whatever the CLI is configured to use", which is the right default: the
    /// user chose that in Claude Code and this app has no better opinion.
    public let model: String?

    /// The directory the CLI runs in. A coding brain with no working directory is close to
    /// useless, so this is normally the bot's workspace.
    ///
    /// The cost is that `CLAUDE.md` in that directory reaches the model as context. That is
    /// accepted rather than blocked: the model has no tools, so the worst a hostile file can do
    /// is ask for an action, and every action still goes through the permission floor before it
    /// happens. Hooks are the part that would actually execute, and `--setting-sources ""`
    /// keeps those out.
    public let workspace: String?

    /// Generous, because this is a whole agent turn rather than one HTTP call: the CLI thinks,
    /// retries its own transport errors, and can spend a minute before the first token.
    public let timeout: TimeInterval

    /// Injectable so tests can point at a binary that does not exist without touching the
    /// machine's real one.
    private let binaryOverride: String?

    public init(model: String? = nil,
                workspace: String? = nil,
                timeout: TimeInterval = 300,
                binary: String? = nil) {
        self.model = model
        self.workspace = workspace
        self.timeout = timeout
        self.binaryOverride = binary
        self.name = model.map { "claude-cli/\($0)" } ?? "claude-cli"
    }

    /// False, and this is not a limitation waiting to be lifted.
    ///
    /// Driving a screen means sending the model a screenshot every step. This adapter's only
    /// channel to the CLI is a text prompt on stdin — there is no image part, and the model has
    /// no `Read` tool it could use to open a PNG we wrote to disk, because we deliberately took
    /// its tools away. So it cannot see, and a brain that cannot see must not be handed the
    /// mouse. `BrainAdapter` documents this exact case, and `AgentLoop` reads this flag both to
    /// skip screenshot capture and to withhold the computer toolset.
    public var canDriveComputer: Bool { false }

    // MARK: - Configured

    /// The binary exists and runs.
    ///
    /// It deliberately does **not** check whether the CLI is signed in, because there is no way
    /// to ask that question cheaply and honestly. The subscription token lives in the login
    /// Keychain, not in a file — `~/.claude/.credentials.json` does not exist on a subscription
    /// install — so reading it means a Keychain prompt, and proving sign-in the other way means
    /// spending a real model call every time a run starts. Both are worse than the alternative,
    /// which is that `step()` recognises "Not logged in" and says what to do about it.
    ///
    /// Runs the subprocess off the calling actor, so this never blocks the main thread, and
    /// `--version` neither contacts the network nor starts a login.
    public func isConfigured() async -> Bool {
        guard let binary = binary() else { return false }
        let probe = await Self.execute(binary: binary, arguments: ["--version"],
                                       stdin: nil, cwd: nil, timeout: 15)
        return probe.exitCode == 0
    }

    /// Where the CLI actually installs, in the order the installers use it.
    ///
    /// A `which` lookup is not usable here: a GUI app launched from Finder inherits a bare
    /// `PATH` of `/usr/bin:/bin:/usr/sbin:/sbin`, and none of these three directories are in
    /// it. Verified on this machine: `~/.local/bin/claude` is a symlink into
    /// `~/.local/share/claude/versions/`.
    public static func locateBinary() -> String? {
        [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func binary() -> String? {
        if let binaryOverride {
            return FileManager.default.isExecutableFile(atPath: binaryOverride) ? binaryOverride : nil
        }
        return Self.locateBinary()
    }

    // MARK: - One turn

    public func step(_ request: BrainRequest) async throws -> BrainResponse {
        guard let binary = binary() else {
            throw Failure.binaryMissing
        }

        let run = await Self.execute(
            binary: binary,
            arguments: Self.commandArguments(for: request, model: model),
            stdin: Self.prompt(for: request),
            cwd: workspace,
            timeout: timeout)

        if run.timedOut {
            throw Failure.timedOut(seconds: Int(timeout))
        }

        do {
            return try Self.parse(run.stdout)
        } catch let failure as Failure {
            throw failure
        } catch {
            // Nothing parseable came back at all. stderr is where the CLI puts flag mistakes
            // ("--output-format=stream-json requires --verbose") and startup failures, so it is
            // the only useful thing to show.
            let detail = run.stderr.isEmpty ? run.stdout : run.stderr
            throw Failure.unreadableOutput(exitCode: run.exitCode, detail: String(detail.suffix(600)))
        }
    }

    // MARK: - The command

    /// Every flag, with the four safety ones first so that a diff that removes one is obvious.
    ///
    /// Deliberately absent:
    /// - `--dangerously-skip-permissions` and `--allow-dangerously-skip-permissions`. Never. They
    ///   are the two flags that would undo everything above.
    /// - `--bare`. It looks right — it skips hooks, plugins and CLAUDE.md in one flag — and it is
    ///   wrong here, because its own help says Anthropic auth becomes "strictly ANTHROPIC_API_KEY
    ///   or apiKeyHelper (OAuth and keychain are never read)". That breaks the one thing this
    ///   brain is for. Verified: with `--bare` and no key the CLI answers "Not logged in".
    /// - `--resume`. See `parse`.
    static func commandArguments(for request: BrainRequest, model: String?) -> [String] {
        var arguments = [
            // Safety. See the type comment for what each was observed to do.
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--permission-mode", "manual",

            "--print",
            "--output-format", "stream-json",
            // Not optional. Verified: without it the CLI refuses with
            // "When using --print, --output-format=stream-json requires --verbose".
            "--verbose",
            // We never resume, so a session file on disk is a second copy of the conversation
            // living somewhere the user does not know to look. Bot-Harness's own trace is the
            // record of what happened.
            "--no-session-persistence",

            // Replaces Claude Code's default system prompt rather than appending to it. The
            // default one tells the model it is a coding CLI with a shell — untrue here, and it
            // is ~9k tokens of instructions about tools it does not have. Verified: replacing it
            // dropped a turn from 16,268 prompt tokens to 880.
            "--system-prompt", systemPrompt(for: request),
            "--json-schema", envelopeSchema,
        ]
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        return arguments
    }

    /// The reply shape. `arguments` is an open object because tool schemas differ per tool and
    /// the CLI validates only what is described here; the harness validates the arguments
    /// themselves against the real schema when it runs the tool.
    static let envelopeSchema = """
    {"type":"object","properties":{\
    "say":{"type":"string","description":"What to tell the person, in your own voice. Empty if you have nothing to say this turn."},\
    "actions":{"type":"array","description":"The tool calls you want the harness to run next. Empty when you are done.","items":{"type":"object","properties":{\
    "tool":{"type":"string","description":"An exact tool id from the list you were given."},\
    "intent":{"type":"string","description":"Why you want this specific step, in one sentence."},\
    "arguments":{"type":"object","description":"Arguments matching that tool's schema."}},\
    "required":["tool","intent","arguments"]}}},\
    "required":["say","actions"]}
    """

    /// The harness's own system prompt, plus the part only this adapter knows: that the model
    /// has no hands here and what the envelope looks like.
    static func systemPrompt(for request: BrainRequest) -> String {
        var parts: [String] = []
        if !request.system.isEmpty { parts.append(request.system) }

        var protocolText = """
        HOW YOU ACT HERE

        You have no tools of your own in this session. You cannot read a file, run a command, \
        open a browser or touch this computer. The harness does all of that for you: you name \
        the tool you want and the arguments, it checks the user's permission rules, runs it, \
        and sends you the result as the next message.

        Answer with one envelope every turn: `say` is prose for the person, `actions` is the \
        list of tool calls you want run next. Leave `actions` empty when you have nothing left \
        to run. `intent` is your reason for that specific step and the person sees it, so write \
        it for them.
        """

        if request.tools.isEmpty {
            protocolText += "\n\nNo tools are available this turn, so `actions` must be empty."
        } else {
            protocolText += "\n\nTOOLS YOU MAY ASK FOR\n"
            for tool in request.tools {
                protocolText += "\n- \(tool.id) — \(tool.summary)\n  arguments: \(tool.schema)"
            }
        }
        parts.append(protocolText)

        return parts.joined(separator: "\n\n")
    }

    /// The whole conversation, rendered as one prompt.
    ///
    /// Sent on stdin rather than as the positional argument because a long transcript is easily
    /// megabytes and `argv` is capped; stdin has no such limit. Verified that the CLI reads a
    /// piped prompt with `--print` and no positional argument.
    static func prompt(for request: BrainRequest) -> String {
        var lines: [String] = []

        if let observation = request.observation, !observation.isEmpty {
            lines.append("[state of the computer]\n\(observation)")
        }

        for turn in request.turns {
            switch turn.role {
            case .user:      lines.append("[user]\n\(turn.text)")
            case .assistant: lines.append("[you said]\n\(turn.text)")
            case .tool:
                let label = turn.toolCallID.map { "[result of \($0)]" } ?? "[tool result]"
                lines.append("\(label)\n\(turn.text)")
            }
        }

        // `canDriveComputer` is false so `AgentLoop` will not attach one, but if some future
        // caller does, silence would look to the model like the screenshot was empty.
        if request.screenshot != nil {
            lines.append("[a screenshot was taken, but this brain cannot see images — "
                       + "ask for a text description of the screen instead]")
        }

        return lines.joined(separator: "\n\n")
    }

    // MARK: - Reading the stream

    /// Walk the JSONL the CLI writes to stdout.
    ///
    /// Shapes verified against `claude 2.1.238`: a `system`/`init` line, zero or more
    /// `assistant` lines whose `message.content` is an array of typed parts, housekeeping lines
    /// (`rate_limit_event`, `system`/`api_retry`, `system`/`post_turn_summary`), and one final
    /// `result` line carrying `structured_output`, `usage` and `total_cost_usd`.
    ///
    /// Unparseable lines are skipped rather than fatal: the CLI prints update notices and
    /// warnings to this stream too, and one of those must not lose a completed turn.
    static func parse(_ stream: String) throws -> BrainResponse {
        var result: [String: Any]?
        var assistantText = ""

        for line in stream.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }

            switch object["type"] as? String {
            case "result":
                result = object

            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for part in content where part["type"] as? String == "text" {
                    // `thinking` parts are an opaque signature plus reasoning the user did not
                    // ask to read, and `tool_use` parts are the StructuredOutput call itself,
                    // which arrives properly typed on the result line. Neither is prose.
                    assistantText += (part["text"] as? String) ?? ""
                }

            default:
                continue
            }
        }

        guard let result else {
            throw Failure.unreadableOutput(exitCode: nil,
                                           detail: String(stream.suffix(600)))
        }

        // `subtype` says "success" even on a failed turn — verified against a signed-out run —
        // so `is_error` is the field that actually decides.
        let resultText = (result["result"] as? String) ?? ""
        if (result["is_error"] as? Bool) == true {
            throw failure(for: resultText, stream: stream)
        }

        var text: String?
        var actions: [BrainAction] = []

        if let envelope = result["structured_output"] as? [String: Any] {
            let say = (envelope["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let say, !say.isEmpty { text = say }
            actions = self.actions(from: envelope["actions"] as? [[String: Any]] ?? [])
        } else if let parsed = try? JSONSerialization.jsonObject(with: Data(resultText.utf8)) as? [String: Any],
                  parsed["say"] != nil || parsed["actions"] != nil {
            // The schema was honoured but the CLI reported it only as a JSON string. Reading it
            // here rather than treating it as prose, because showing the user a raw JSON blob is
            // the single most obvious way for this adapter to look broken when it is working.
            let say = (parsed["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let say, !say.isEmpty { text = say }
            actions = self.actions(from: parsed["actions"] as? [[String: Any]] ?? [])
        } else {
            // No envelope at all. The model still said something, and dropping it would make the
            // conversation look dead — the exact failure GeminiAdapter's comments record.
            let fallback = resultText.isEmpty ? assistantText : resultText
            let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { text = trimmed }
        }

        var usage = BrainResponse.Usage()
        if let reported = result["usage"] as? [String: Any] {
            // Cache reads and cache writes are prompt tokens that were really sent; leaving them
            // out makes a long run look an order of magnitude cheaper than it is, and the budget
            // that stops runaway loops is spent in these units.
            usage.promptTokens = ((reported["input_tokens"] as? Int) ?? 0)
                + ((reported["cache_read_input_tokens"] as? Int) ?? 0)
                + ((reported["cache_creation_input_tokens"] as? Int) ?? 0)
            usage.completionTokens = (reported["output_tokens"] as? Int) ?? 0
        }
        // What the CLI itself reports. Under a subscription nothing is charged, so this is the
        // notional API price of the same work — kept because it is the only consumption signal
        // available and the run budget needs one, not because a bill exists.
        usage.costUSD = (result["total_cost_usd"] as? Double) ?? 0

        return BrainResponse(
            text: text,
            actions: actions,
            usage: usage,
            // The CLI's `session_id` is deliberately not returned as an interaction id.
            // `AgentLoop` would hand it back next turn and this adapter would have to `--resume`
            // it, which means the whole run depends on a session file that `--no-session-persistence`
            // does not write, and dies mid-task if it is missing. Resending a transcript the
            // harness already owns and compacts is slower and cannot fail that way.
            interactionID: nil,
            needsAction: !actions.isEmpty,
            raw: String(stream.suffix(rawTraceLimit)))
    }

    /// Traces are read by people. A single turn's stream can carry hundreds of kilobytes of
    /// base64 thinking signatures, which are unreadable and prove nothing.
    private static let rawTraceLimit = 200_000

    private static func actions(from raw: [[String: Any]]) -> [BrainAction] {
        raw.enumerated().compactMap { index, entry in
            guard let tool = entry["tool"] as? String, !tool.isEmpty else { return nil }
            return BrainAction(
                id: "claude-\(index)-\(tool)",
                name: tool,
                arguments: (entry["arguments"] as? [String: Any]) ?? [:],
                intent: entry["intent"] as? String,
                // The CLI offers no per-action safety judgement of its own. Nothing is asserted
                // here rather than asserting "allowed", because the floor treats a missing
                // decision and an allowed one very differently and only one of them is true.
                safety: nil)
        }
    }

    /// Turn the CLI's own error text into a sentence that says what to do.
    private static func failure(for resultText: String, stream: String) -> Failure {
        let haystack = (resultText + stream).lowercased()
        if haystack.contains("not logged in")
            || haystack.contains("authentication_failed")
            || haystack.contains("/login") {
            return .notSignedIn
        }
        if haystack.contains("rate_limit") && haystack.contains("rejected") {
            return .rateLimited(detail: resultText)
        }
        return .cliReportedError(detail: resultText.isEmpty
                                 ? String(stream.suffix(400))
                                 : String(resultText.prefix(400)))
    }

    // MARK: - Errors

    /// Its own type rather than a `BrainError`, because every `BrainError` case ends in "Add it
    /// in Settings (⌘,)" and none of these are fixed by adding a key. An error that names the
    /// wrong remedy costs more than one that says nothing.
    public enum Failure: LocalizedError {
        case binaryMissing
        case notSignedIn
        case rateLimited(detail: String)
        case timedOut(seconds: Int)
        case cliReportedError(detail: String)
        case unreadableOutput(exitCode: Int32?, detail: String)

        public var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "The claude command is not installed on this Mac. Install it with "
                     + "`curl -fsSL https://claude.ai/install.sh | bash`, or switch this bot to "
                     + "Gemini in the brain menu next to the message box."
            case .notSignedIn:
                return "The claude command is installed but not signed in. Open Terminal, run "
                     + "`claude`, sign in with your Claude subscription, then send this message "
                     + "again."
            case .rateLimited(let detail):
                return "Your Claude subscription has hit its usage limit, so the CLI would not "
                     + "answer. Wait for the limit to reset, or switch this bot to Gemini in the "
                     + "brain menu. The CLI said: \(detail.prefix(200))"
            case .timedOut(let seconds):
                return "The claude command did not answer within \(seconds) seconds and was "
                     + "stopped. Send the message again, or break the task into smaller steps."
            case .cliReportedError(let detail):
                // The catch-all. It cannot know the cause, so it hands over the CLI's own words
                // and names the two things that resolve most of them — running the same command
                // in Terminal, where the CLI is allowed to explain itself properly, or moving
                // the bot to a brain that does not depend on it.
                return "The claude command failed and said: \(detail). Run `claude` in Terminal "
                     + "to see the full error, or switch this bot to Gemini in the brain menu "
                     + "next to the message box."
            case .unreadableOutput(let exitCode, let detail):
                let code = exitCode.map { " (exit \($0))" } ?? ""
                return "The claude command produced no readable answer\(code). This usually means "
                     + "the installed version does not support the flags this app uses; check "
                     + "`claude --version` in Terminal. It printed: \(detail)"
            }
        }
    }

    // MARK: - Running the process

    public struct Run: Sendable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    /// Spawn, feed stdin, drain both pipes, and give up after `timeout`.
    ///
    /// Drains on the pipes' own readability handlers rather than calling `readToEnd()`, for the
    /// reason `ShellExecutor` records: reading to EOF blocks until the child exits, which makes
    /// the timeout below dead code and deadlocks on a full 64KB pipe buffer for anything chatty.
    /// A streaming JSONL turn is exactly that.
    public static func execute(binary: String,
                               arguments: [String],
                               stdin: String?,
                               cwd: String?,
                               timeout: TimeInterval) async -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = minimalEnvironment()
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input

        do { try process.run() } catch {
            return Run(exitCode: 127, stdout: "",
                       stderr: "could not start \(binary): \(error.localizedDescription)",
                       timedOut: false)
        }

        let collector = StreamCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }

        // Written and closed immediately. The CLI reads the prompt to EOF, so leaving the pipe
        // open makes it wait for input that is never coming and the timeout is the only thing
        // that ends the run.
        if let stdin { try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var cancelled = false
        while process.isRunning && Date() < deadline {
            if Task.isCancelled { cancelled = true; break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let timedOut = process.isRunning && !cancelled
        if process.isRunning {
            // SIGTERM, a moment, then SIGKILL. Terminating without the follow-up leaves anything
            // that traps SIGTERM running after we have stopped watching it.
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { try? await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        return Run(exitCode: process.isRunning ? -1 : process.terminationStatus,
                   stdout: collector.stdout(),
                   stderr: collector.stderr(),
                   timedOut: timedOut)
    }

    /// A short, explicit environment rather than the app's own.
    ///
    /// Two reasons, and the first is the one that matters. `ANTHROPIC_API_KEY` and
    /// `ANTHROPIC_BASE_URL` change who answers and who pays: inheriting a key would quietly bill
    /// a metered API for a bot the user picked *because* Settings said "no API key needed", and
    /// inheriting a base URL would send their conversation to whatever proxy their shell happens
    /// to point at. Neither is a choice this app should make on their behalf. Second, a
    /// subprocess that inherits everything inherits every token in the environment, which is the
    /// hole `ShellExecutor.sanitisedEnvironment` exists to close.
    ///
    /// `HOME` is required — it is where the CLI keeps its config, and where it looks up the
    /// login Keychain item holding the subscription token.
    static func minimalEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "HOME": NSHomeDirectory(),
            // A GUI app inherits `/usr/bin:/bin:/usr/sbin:/sbin`, which does not contain the CLI
            // or the node it may re-exec. The binary itself is invoked by absolute path; this is
            // for anything it needs to find afterwards.
            "PATH": "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
        ]
        for passthrough in ["USER", "LOGNAME", "TMPDIR", "SHELL", "TERM"] {
            if let value = parent[passthrough] { environment[passthrough] = value }
        }
        return environment
    }

    /// Locked because the pipe handlers fire on a private queue while `step` waits on another.
    private final class StreamCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        /// A cap, because nothing else bounds a stream we do not control. Trimming from the
        /// front rather than the back on purpose: the `result` line — the only one that carries
        /// the answer — is always last.
        private let limit = 32 * 1024 * 1024

        func appendOut(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            out.append(data)
            if out.count > limit { out.removeFirst(out.count - limit) }
        }

        func appendErr(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            err.append(data)
            if err.count > limit { err.removeFirst(err.count - limit) }
        }

        func stdout() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: out, as: UTF8.self)
        }

        func stderr() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: err, as: UTF8.self)
        }
    }
}
