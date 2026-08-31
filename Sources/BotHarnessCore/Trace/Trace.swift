import Foundation
import CryptoKit

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
///   disk that will be copied, attached to issues, and read by other agents. Two redactors run,
///   not one: `Redactor` for the shapes a key has, and a `StreamingRedactor` seeded with the
///   actual credential values for the secrets that have no shape at all — a database URL with
///   a password in it, a bearer string, a refresh token. The regex can never catch those.
/// - **Screenshots live beside the trace, referenced by name.** They are the largest and most
///   sensitive artifacts, so they are separable: deleting them must not corrupt the trace.
/// - **Every line carries a keyed hash of the line before it.** Borrowed from bloks, whose audit
///   log is hash-chained and signed. The chain used to be a bare SHA-256, which was a mistake
///   worth naming: verification re-derived it with the same public algorithm and no key, so
///   anything that could rewrite the file could re-chain it and hand back something that
///   verified perfectly. It caught accidents and nothing else. The link is now an HMAC under a
///   key held where a bot cannot read it — see `TraceChainKey` for where, and for what an
///   attacker who *can* read it still gets.
/// - **Owner-only on disk.** The directory is 0700 and every file in it 0600, asserted on each
///   run rather than inherited from the umask. A trace holds real commands, real paths and real
///   file contents; it is not a thing to leave group-readable because a shell was configured
///   loosely.
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
public actor TraceWriter {

    // MARK: Identity of this run

    public let runID: String
    public let directory: URL

    /// Where traces live. Exposed so anything else that must write beside them —
    /// the effect ledger — lands in the same place, which is what keeps a test or an
    /// eval from writing into the real user's data directory.
    public let tracesRoot: URL

    private let steps: URL
    private var sequence: Int = 0
    private var handle: FileHandle?

    /// Hash of the previous record, or the genesis marker for the first one.
    private var previousHash: String = TraceWriter.genesis
    /// `.sortedKeys` is not cosmetic here. The chain hashes the encoded bytes, so the
    /// encoding has to be deterministic — without stable key ordering a record's hash cannot
    /// be recomputed, and every trace fails verification for no reason.
    private let encoder: JSONEncoder = TraceWriter.canonicalEncoder

    /// The HMAC key for this run's chain, or `nil` if the machine has none and could not make
    /// one. `nil` means the chain falls back to the old unkeyed SHA-256 and verification says
    /// so out loud. That is a deliberate trade against the house rule that a failure to trace
    /// never fails the work: an unsigned trace is worth much more than no trace, and it is
    /// reported as unsigned rather than quietly passed off as evidence.
    private let chainKey: SymmetricKey?
    private let chainAlgorithm: String?

    /// Seeded once, at construction, and never again for the life of the writer.
    ///
    /// Re-seeding per record would re-read the credential store on every line, but cost is the
    /// smaller reason. The larger one is that a trace whose records were scrubbed against
    /// different secret sets is not auditable: whether a value appears would depend on when in
    /// the run it was written, and "why is the key visible on line 40 but not line 12" is not a
    /// question a person should have to answer about an audit log.
    private let valueRedactor: StreamingRedactor

    public static var canonicalEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// - Parameters:
    ///   - root: normally `var/traces` inside Application Support.
    ///   - extraSecrets: values beyond the credential store that must never reach this trace.
    ///   - chainKey: overrides the machine's chain key. Tests pass one so the suite never has
    ///     to touch the real credential file; nothing in the app does.
    public init(root: URL, botName: String, extraSecrets: [String] = [], chainKey: Data? = nil) {
        let stamp = TraceWriter.stampFormatter.string(from: Date())
        let slug = String(UUID().uuidString.prefix(6)).lowercased()
        self.runID = "\(stamp)-\(slug)"
        self.tracesRoot = root
        self.directory = root.appendingPathComponent(runID, isDirectory: true)
        self.steps = directory.appendingPathComponent("steps.jsonl")

        let key = chainKey ?? TraceChainKey.current()
        self.chainKey = key.map { SymmetricKey(data: $0) }
        self.chainAlgorithm = key == nil ? nil : TraceWriter.hmacAlgorithm

        // The chain key is seeded into the redactor alongside the API keys. It should never
        // pass through a tool's output, but if it ever does, a trace that leaks the key that
        // signs it is a trace that proves nothing.
        self.valueRedactor = StreamingRedactor.forRun(
            extra: extraSecrets + (key.map { [$0.base64EncodedString()] } ?? [])
        )

        let manager = FileManager.default
        // Assert the mode on the traces root as well as on this run's directory. A mode is not
        // something you establish once; it is something you keep, and the root outlives every
        // run in it. Doing it here rather than where the directory is first made means it is
        // re-checked on every single run, which is the only schedule that actually holds.
        try? manager.createDirectory(at: root, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? manager.createDirectory(
            at: directory.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        manager.createFile(atPath: steps.path, contents: nil,
                           attributes: [.posixPermissions: 0o600])
        self.handle = try? FileHandle(forWritingTo: steps)
    }

    // MARK: Recording

    /// Record an event. Returns the sequence number, which callers keep so they can amend
    /// the same step later with its result.
    @discardableResult
    public func record(_ event: Event) -> Int {
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
    public func complete(_ seq: Int, outcome: Outcome, output: String? = nil, error: String? = nil) {
        sequence += 1
        var e = Event(kind: .completion, summary: outcome.rawValue)
        e.seq = sequence
        e.at = Date()
        e.completes = seq
        e.outcome = outcome
        e.output = output
        e.error = error
        append(e)
    }

    /// Store a binary artifact — usually a screenshot — and return the name to reference it
    /// by. Kept out of the JSONL so that traces stay greppable and artifacts stay deletable.
    public func attach(_ data: Data, name: String) -> String {
        sequence += 1
        let filename = String(format: "%04d-%@", sequence, name)
        let url = directory.appendingPathComponent("artifacts").appendingPathComponent(filename)
        TraceWriter.writeOwnerOnly(data, to: url)
        return filename
    }

    /// Write the run manifest. Called when the run ends, however it ends.
    public func finish(_ manifest: RunManifest) {
        var m = manifest
        m.runID = runID
        m.finishedAt = Date()
        m.steps = sequence

        // The manifest used to go to disk with no redaction whatever, which was the widest hole
        // in the whole trace: `goal` is the user's own message, and the message someone pastes a
        // key into is exactly the one that starts a run about that key. The two free-text fields
        // get the same treatment every appended record gets. The rest are identifiers this app
        // generated itself — a UUID, a model name, an enum — where there is no secret to catch
        // and a regex could only corrupt something.
        m.goal = scrub(m.goal)
        m.closingNote = m.closingNote.map(scrub)

        // Seal the manifest with the same key the chain uses. This is what makes a *downgrade*
        // visible: an attacker who re-chains `steps.jsonl` with the public SHA-256 and strips
        // the algorithm marker produces a file that is internally consistent and would otherwise
        // read as "written before chain signing". They cannot forge this seal, so the manifest
        // keeps saying the run was signed and the mismatch shows.
        m.chainSeal = nil
        if let chainKey, let body = try? encoder.encode(m) {
            m.chainSeal = TraceWriter.hex(HMAC<SHA256>.authenticationCode(for: body, using: chainKey))
        }

        if let data = try? encoder.encode(m) {
            TraceWriter.writeOwnerOnly(data, to: directory.appendingPathComponent("run.json"))
        }
        try? handle?.close()
        handle = nil
    }

    /// Encode, chain, write. The hash covers the record *including* `prev`, so altering any
    /// earlier line invalidates every line after it rather than only itself.
    private func append(_ event: Event) {
        guard let handle else { return }
        var chained = event

        // Redact here rather than at each call site. Every path into the trace goes through
        // this function, so this is the one place that can guarantee it — and a guarantee
        // that depends on every caller remembering is not one.
        chained.summary = scrub(chained.summary)
        chained.intent = chained.intent.map(scrub)
        chained.arguments = chained.arguments.map(scrub)
        chained.output = chained.output.map(scrub)
        chained.error = chained.error.map(scrub)
        chained.permissionReason = chained.permissionReason.map(scrub)

        chained.prev = previousHash
        chained.hashAlgorithm = chainAlgorithm
        // Cleared explicitly rather than assumed nil: a caller can hand `record` an event it
        // built by copying another one, and a stale hash in the body would be hashed into the
        // link and make the record unverifiable for a reason nobody could see.
        chained.hash = nil
        guard let body = try? encoder.encode(chained) else { return }

        let hash = TraceWriter.link(over: body, with: chainKey)
        chained.hash = hash
        previousHash = hash

        guard var data = try? encoder.encode(chained) else { return }
        data.append(0x0A)  // newline
        try? handle.write(contentsOf: data)
    }

    /// Both redactors, in this order.
    ///
    /// Values first, patterns second. A known secret is replaced whole, so the regex pass never
    /// sees a fragment of one; the other order risks a pattern chewing the middle out of a value
    /// and leaving its head and tail behind, which is worse than not redacting at all because it
    /// looks redacted.
    private func scrub(_ text: String) -> String {
        Redactor.redact(valueRedactor.redact(text))
    }

    public static let genesis = "genesis"

    /// The marker written into every signed record. Its absence is what identifies a trace from
    /// before the chain was keyed.
    public static let hmacAlgorithm = "hmac-sha256"

    // MARK: Verification

    /// Re-derive every hash and report the first line that does not match.
    ///
    /// Deliberately a static function over a path rather than a method on a live writer: the
    /// point of verification is to run it on a file somebody handed you, long after the
    /// process that wrote it is gone.
    public static func verifyChain(at stepsFile: URL, chainKey: Data? = nil) -> ChainStatus {
        inspectChain(at: stepsFile, chainKey: chainKey).status
    }

    /// Verification with the part `ChainStatus` cannot say: *how* the chain was signed.
    ///
    /// A trace written before the chain was keyed still verifies — its SHA-256 links are intact
    /// and nothing about it is suspicious — but calling that "intact" without qualification
    /// overstates what it proves. `signing` carries the distinction so a reader can be told
    /// "written before chain signing" instead of a green tick it has not earned.
    public static func inspectChain(at stepsFile: URL, chainKey: Data? = nil) -> ChainReport {
        guard let text = try? String(contentsOf: stepsFile, encoding: .utf8) else {
            return ChainReport(status: .unreadable, signing: .empty, records: 0)
        }
        let key = (chainKey ?? TraceChainKey.current()).map { SymmetricKey(data: $0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = canonicalEncoder

        var expectedPrev = genesis
        var line = 0
        var sawSigned = false
        var sawUnsigned = false

        func broken(_ reason: String) -> ChainReport {
            ChainReport(status: .brokenAt(line: line, reason: reason),
                        signing: sawSigned ? .signed : .writtenBeforeSigning,
                        records: line - 1)
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            line += 1
            guard let data = raw.data(using: .utf8),
                  var event = try? decoder.decode(Event.self, from: data),
                  let claimed = event.hash
            else { return broken("line is not a readable trace record") }

            if event.prev != expectedPrev {
                return broken("does not follow the previous record")
            }

            let algorithm = event.hashAlgorithm
            event.hash = nil
            guard let body = try? encoder.encode(event) else {
                return broken("could not be re-encoded for checking")
            }

            let recomputed: String
            switch algorithm {
            case nil:
                // One trace, one scheme. A file that starts signed and turns unsigned partway
                // down is not a legacy trace; it is somebody appending records they could not
                // sign, which is the cheapest possible forgery and has to be caught here.
                if sawSigned { return broken("record is not signed like the ones before it") }
                sawUnsigned = true
                recomputed = hex(SHA256.hash(data: body))
            case hmacAlgorithm:
                if sawUnsigned { return broken("record is signed but the ones before it are not") }
                guard let key else {
                    return ChainReport(status: .unreadable, signing: .keyUnavailable, records: line - 1)
                }
                sawSigned = true
                recomputed = hex(HMAC<SHA256>.authenticationCode(for: body, using: key))
            default:
                return broken("record was written with an unrecognised hash algorithm")
            }

            if recomputed != claimed {
                return broken("contents do not match the recorded hash")
            }
            expectedPrev = claimed
        }

        let signing: ChainReport.Signing =
            line == 0 ? .empty : (sawSigned ? .signed : .writtenBeforeSigning)
        return ChainReport(status: .intact(records: line), signing: signing, records: line)
    }

    /// Whether the manifest still carries the seal the writer put on it.
    ///
    /// Checked separately from the step chain because the two fail differently: a manifest that
    /// was never sealed is an old run, while a manifest whose seal no longer matches is somebody
    /// editing the goal or the closing note — the two fields a person would most want to change
    /// after the fact.
    public static func verifyManifest(_ manifest: RunManifest, chainKey: Data? = nil) -> ManifestSeal {
        guard let claimed = manifest.chainSeal else { return .writtenBeforeSigning }
        guard let key = (chainKey ?? TraceChainKey.current()).map({ SymmetricKey(data: $0) }) else {
            return .keyUnavailable
        }
        var m = manifest
        m.chainSeal = nil
        guard let body = try? canonicalEncoder.encode(m) else { return .altered }
        return hex(HMAC<SHA256>.authenticationCode(for: body, using: key)) == claimed ? .sealed : .altered
    }

    /// The link written into a record: keyed when there is a key, and the old bare digest when
    /// there is not, so that a machine without a key still produces a readable, self-consistent
    /// trace rather than none at all.
    private static func link(over body: Data, with key: SymmetricKey?) -> String {
        guard let key else { return hex(SHA256.hash(data: body)) }
        return hex(HMAC<SHA256>.authenticationCode(for: body, using: key))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Create the file with its mode already set rather than writing and then chmod-ing.
    /// Between those two calls the file exists with whatever the umask allowed, and a trace
    /// holds real commands and real file contents — a window of one syscall is still a window.
    /// `setAttributes` runs afterwards anyway, because `createFile` overwriting a file that
    /// already exists is not documented to reset its mode.
    private static func writeOwnerOnly(_ data: Data, to url: URL) {
        let manager = FileManager.default
        manager.createFile(atPath: url.path, contents: data,
                           attributes: [.posixPermissions: 0o600])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public enum ChainStatus: Equatable, Sendable {
        case intact(records: Int)
        case brokenAt(line: Int, reason: String)
        case unreadable
    }

    /// What verification found, including the part that does not fit in `ChainStatus`.
    public struct ChainReport: Equatable, Sendable {
        public var status: ChainStatus
        public var signing: Signing
        public var records: Int

        public enum Signing: Equatable, Sendable {
            /// Every record carries an HMAC this machine could check.
            case signed
            /// Bare SHA-256 links throughout: written before the chain was keyed. Intact, but
            /// it proves only that nobody edited it carelessly.
            case writtenBeforeSigning
            /// Signed with a key this machine does not hold, so nothing can be said either way.
            case keyUnavailable
            case empty
        }
    }

    public enum ManifestSeal: Equatable, Sendable {
        case sealed
        case writtenBeforeSigning
        case altered
        case keyUnavailable
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
    public struct Event: Codable {
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

        // — tamper evidence —
        /// Hash of the preceding record, or "genesis" for the first.
        var prev: String?
        /// The link over this record with `hash` itself omitted. Set at write time.
        var hash: String?
        /// How `hash` was computed. Absent on records written before the chain was keyed, which
        /// is the only thing that tells those traces apart from tampered ones — so it is part of
        /// the hashed body, not metadata beside it.
        var hashAlgorithm: String?

        var kindRaw: String { kind.rawValue }

        public enum Kind: String, Codable, Sendable {
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

    public enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        case refused
        case cancelled
        case timedOut
    }

    /// The manifest, written once per run. This is what a "which runs went wrong?" query
    /// reads, so it holds the summary numbers rather than requiring a scan of every step.
    public struct RunManifest: Codable {
        public var runID: String = ""
        public var botID: UUID
        public var botName: String
        public var conversationID: UUID
        public var goal: String
        public var brain: String
        public var environment: String
        public var startedAt: Date
        public var finishedAt: Date?
        public var steps: Int = 0
        public var outcome: Outcome?
        public var totalCostUSD: Double = 0
        public var totalPromptTokens: Int = 0
        public var totalCompletionTokens: Int = 0

        /// Set when the run ended because a human stopped it, so that "failed" is not
        /// confused with "interrupted".
        public var stoppedByUser: Bool = false

        /// Free text the agent writes at the end: what it concluded, what it could not do,
        /// what a future run should know. The single most useful field for the next agent.
        public var closingNote: String?

        /// HMAC over this manifest with the field itself omitted. Absent on runs written before
        /// the chain was keyed.
        public var chainSeal: String?
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
/// that looks like an English word, or a database URL, or a bearer token with no prefix. That
/// gap is why `TraceWriter` runs a value-seeded `StreamingRedactor` before this one rather than
/// treating this as the whole defence.
public enum Redactor {
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

    public static func redact(_ text: String) -> String {
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
