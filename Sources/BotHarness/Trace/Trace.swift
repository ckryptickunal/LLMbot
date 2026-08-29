import Foundation

/// The decision trace.
///
/// The requirement this satisfies, in the user's words: *"Maintain every decision trace,
/// maintain every change log, maintain every step that the LLM takes… for any other agent to
/// work and improve it in the future."*
///
/// Design commitments, each of which costs something and is worth it:
///
/// - **Append-only JSONL, one directory per run.** Not a database. A run's trace can be read
///   with `cat`, filtered with `grep`, and diffed. Nothing about auditing an agent should
///   require the agent's own software to be working.
/// - **Written before the action, not after.** A step is recorded as `proposed` before the
///   tool runs and amended with `completed` after. A crash mid-action therefore leaves
///   evidence of what was being attempted, which is exactly the case you most need it.
/// - **Secrets are redacted on the way in.** Not on the way out. A trace file is a file on
///   disk that will be copied, attached to issues, and read by other agents.
/// - **Screenshots live beside the trace, referenced by name.** They are the largest and most
///   sensitive artifacts, so they are separable: deleting them must not corrupt the trace.
/// - **Failures to trace never fail the work.** Every write is best-effort.
///
/// Layout on disk:
///
/// ```
/// var/traces/
///   2026-08-29T19-04-11Z-a1b2c3/       one directory per run
///     run.json                         manifest: bot, goal, model, outcome, timings, cost
///     steps.jsonl                      append-only; one object per event
///     artifacts/
///       0007-screen.png
///       0012-diff.patch
/// ```
actor TraceWriter {

    // MARK: Identity of this run

    let runID: String
    let directory: URL

    private let steps: URL
    private var sequence: Int = 0
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// - Parameter root: normally `var/traces` inside Application Support.
    init(root: URL, botName: String) {
        let stamp = TraceWriter.stampFormatter.string(from: Date())
        let slug = String(UUID().uuidString.prefix(6)).lowercased()
        self.runID = "\(stamp)-\(slug)"
        self.directory = root.appendingPathComponent(runID, isDirectory: true)
        self.steps = directory.appendingPathComponent("steps.jsonl")

        try? FileManager.default.createDirectory(
            at: directory.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: steps.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: steps)
    }

    // MARK: Recording

    /// Record an event. Returns the sequence number, which callers keep so they can amend
    /// the same step later with its result.
    @discardableResult
    func record(_ event: Event) -> Int {
        sequence += 1
        var e = event
        e.seq = sequence
        e.at = Date()
        append(e)
        return sequence
    }

    /// Amend an earlier step with how it turned out. Written as a separate line rather than
    /// by rewriting the original, because an append-only file that is never rewritten cannot
    /// be corrupted by a crash halfway through a write.
    func complete(_ seq: Int, outcome: Outcome, output: String? = nil, error: String? = nil) {
        sequence += 1
        var e = Event(kind: .completion, summary: outcome.rawValue)
        e.seq = sequence
        e.at = Date()
        e.completes = seq
        e.outcome = outcome
        e.output = output.map(Redactor.redact)
        e.error = error.map(Redactor.redact)
        append(e)
    }

    /// Store a binary artifact — usually a screenshot — and return the name to reference it
    /// by. Kept out of the JSONL so that traces stay greppable and artifacts stay deletable.
    func attach(_ data: Data, name: String) -> String {
        sequence += 1
        let filename = String(format: "%04d-%@", sequence, name)
        let url = directory.appendingPathComponent("artifacts").appendingPathComponent(filename)
        try? data.write(to: url)
        return filename
    }

    /// Write the run manifest. Called when the run ends, however it ends.
    func finish(_ manifest: RunManifest) {
        var m = manifest
        m.runID = runID
        m.finishedAt = Date()
        m.steps = sequence
        if let data = try? encoder.encode(m) {
            try? data.write(to: directory.appendingPathComponent("run.json"))
        }
        try? handle?.close()
        handle = nil
    }

    private func append(_ event: Event) {
        guard let handle, var data = try? encoder.encode(event) else { return }
        data.append(0x0A)  // newline
        try? handle.write(contentsOf: data)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - What gets recorded

extension TraceWriter {

    /// Every kind of thing worth knowing about a run. Deliberately flat: a reader with `jq`
    /// and no knowledge of this codebase should be able to follow a run end to end.
    struct Event: Codable {
        var seq: Int = 0
        var at: Date = Date()
        var kind: Kind

        /// One line, written for a human reading the log.
        var summary: String

        // — model calls —
        var model: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var costUSD: Double?
        var latencyMS: Int?

        /// The model's stated reason for the action it is about to take, as it gave it.
        /// This is the "decision" in decision trace.
        var intent: String?

        // — tool calls —
        var tool: String?
        var arguments: String?
        var output: String?
        var error: String?

        // — permission —
        var permissionOutcome: String?
        var permissionReason: String?
        var permissionLayer: String?
        var matchedRule: String?

        // — artifacts —
        var artifacts: [String]?

        // — linkage —
        /// Set on a completion event, pointing at the seq of the step it completes.
        var completes: Int?
        var outcome: Outcome?

        var kindRaw: String { kind.rawValue }

        enum Kind: String, Codable {
            case runStarted
            case userMessage
            case modelCall          // request sent
            case modelResponse      // what came back, including intent
            case permissionCheck
            case toolProposed
            case completion
            case screenshot
            case verification       // did the action actually achieve what it claimed
            case stuckDetected
            case recovery
            case memoryWritten
            case runFinished
            case note               // anything a developer wants to leave for a future reader
        }

        init(kind: Kind, summary: String) {
            self.kind = kind
            self.summary = summary
        }
    }

    enum Outcome: String, Codable {
        case succeeded
        case failed
        case refused
        case cancelled
        case timedOut
    }

    /// The manifest, written once per run. This is what a "which runs went wrong?" query
    /// reads, so it holds the summary numbers rather than requiring a scan of every step.
    struct RunManifest: Codable {
        var runID: String = ""
        var botID: UUID
        var botName: String
        var conversationID: UUID
        var goal: String
        var brain: String
        var environment: String
        var startedAt: Date
        var finishedAt: Date?
        var steps: Int = 0
        var outcome: Outcome?
        var totalCostUSD: Double = 0
        var totalPromptTokens: Int = 0
        var totalCompletionTokens: Int = 0

        /// Set when the run ended because a human stopped it, so that "failed" is not
        /// confused with "interrupted".
        var stoppedByUser: Bool = false

        /// Free text the agent writes at the end: what it concluded, what it could not do,
        /// what a future run should know. The single most useful field for the next agent.
        var closingNote: String?
    }
}

// MARK: - Redaction

/// Strips anything that looks like a credential before it reaches disk.
///
/// This runs on the way *in*, not on the way out, because a trace file is a file: it will be
/// copied into issues, pasted into chats, and read by other agents. By the time anyone thinks
/// about redacting it, it has already been somewhere.
///
/// It is a filter, not a guarantee. It catches known key shapes; it cannot catch a password
/// that looks like an English word. The real defence is that credentials live in the Keychain
/// and are never passed through the agent at all.
enum Redactor {
    private static let patterns: [NSRegularExpression] = {
        [
            #"sk-ant-[A-Za-z0-9_\-]{20,}"#,
            #"sk-[A-Za-z0-9]{32,}"#,
            #"AIza[A-Za-z0-9_\-]{30,}"#,
            #"gh[pousr]_[A-Za-z0-9]{30,}"#,
            #"xox[baprs]-[A-Za-z0-9\-]{10,}"#,
            #"eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}"#,  // JWT
            #"(?i)(authorization|api[-_]?key|token|secret|password)\s*[:=]\s*\S{8,}"#,
        ].compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func redact(_ text: String) -> String {
        var out = text
        for pattern in patterns {
            out = pattern.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: "«redacted»"
            )
        }
        return out
    }
}
