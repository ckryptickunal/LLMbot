import Foundation
import Darwin
import CryptoKit

/// A durable record of side effects that already happened, so a repeated attempt does not repeat
/// the effect.
///
/// The problem this solves is specific and it is not "the model called the same tool twice".
/// `AgentLoop` already suppresses an identical call inside one run with `callSignatures`, but that
/// set lives in memory and dies with the loop. The cases that matter all cross that boundary:
///
/// - A run is stopped, or crashes, after the email was sent but before the model saw the result.
///   The user re-sends the same instruction and it sends again.
/// - A tool times out. The effect landed; the answer did not. The model, reasonably, retries.
/// - The app quits mid-run and the user starts the same task tomorrow.
///
/// The distinction that makes this useful rather than merely tidy is the **uncertain** state. A
/// timeout is not a failure and it is not a success — it is "we do not know". Recording it as
/// either is a lie, and both lies are expensive: recorded as failure, the retry duplicates the
/// effect; recorded as success, a genuinely failed action is never retried. So an effect that
/// times out is written as `uncertain`, and the next attempt is *told* it is uncertain and asked
/// to check before acting rather than silently proceeding.
///
/// **A record stops mattering.** What the ledger suppresses is a *retry*, not a repeat. A
/// completed record used to last forever, which meant one `npm install` bought a permanent
/// refusal: every later run, tomorrow or a year later, was answered with "this exact action was
/// already completed on 31 Aug at 16:07" and did not run. That is the shape of safety feature
/// people switch off. See `completedSuppressionWindow` for how long each outcome now speaks for.
///
/// Kept as JSONL next to the traces, for the same reason everything else here is: if the app is
/// deleted, the record of what it did must survive and stay legible.
public actor EffectLedger {

    public enum Outcome: String, Codable {
        case done
        case failed
        /// The effect may or may not have happened. Nobody knows, and pretending otherwise is
        /// how a retry sends the same message twice.
        case uncertain
    }

    public struct Entry: Codable, Sendable {
        public let key: String
        public let tool: String
        public let summary: String
        public var outcome: Outcome
        public let at: Date
        public var note: String
    }

    // MARK: - How long a record speaks for

    /// How long a *completed* effect suppresses an identical one.
    ///
    /// Short, and deliberately so. A `done` record means the tool returned and its result was
    /// handed back to the model — the thing the ledger protects against, a lost result, has
    /// already not happened. The only window in which a repeat is more likely a retry than a
    /// new intention is the one right after the run that was interrupted: the user watches a run
    /// stop, and asks again. Minutes, not days.
    ///
    /// Rejected, in order of how attractive they looked:
    ///
    /// - **No expiry** (what this replaced). Correct exactly once per action, ever. Ordinary
    ///   repeatable work — an install, a build, a deploy, a nightly sync — is refused forever,
    ///   and the refusal names a date months in the past, which reads as a bug rather than a
    ///   safeguard.
    /// - **One window for every outcome.** Any single number is wrong twice: fifteen minutes is
    ///   too short to still be warning about an email that may or may not have gone out
    ///   overnight, and a day is far too long to be refusing `npm install`. The two states are
    ///   protecting against different things, so they get different windows.
    /// - **A list of "repeatable" tools kept here.** The ledger sees `shell.exec` for both
    ///   `npm install` and `curl -X POST /charge`; it cannot tell them apart from the tool name,
    ///   and the caller already can — `AgentLoop.isOutwardEffect` parses the command before it
    ///   ever asks for a key. A second, worse copy of that judgement here would disagree with
    ///   the first one eventually.
    /// - **Blocking a genuinely new run on the grounds that it was done once.** That is not this
    ///   type's job. "You already did this last month" is a question for the person, and the
    ///   person is the one asking.
    public static let completedSuppressionWindow: TimeInterval = 15 * 60

    /// How long an *unresolved* effect keeps warning: a day.
    ///
    /// Longer than the completed window because the states are not symmetrical. An unconfirmed
    /// send is the case the whole type exists for, the cost of saying so is one advisory the
    /// model can act on, and "an attempt yesterday evening may already have taken effect" is
    /// still worth knowing this morning. It is finite for the same reason the other one is: a
    /// warning that never expires is a refusal wearing a warning's clothes.
    ///
    /// `failed` shares this window even though it suppresses nothing — after a day the note
    /// explaining a failure is stale enough that repeating it to the model is noise.
    public static let unresolvedWarningWindow: TimeInterval = 24 * 60 * 60

    static func window(for outcome: Outcome) -> TimeInterval {
        switch outcome {
        case .done: return completedSuppressionWindow
        case .uncertain, .failed: return unresolvedWarningWindow
        }
    }

    /// Whether a record still has anything to say about an attempt happening now.
    static func speaksFor(_ entry: Entry, now: Date) -> Bool {
        // Absolute distance, not `now - at`. A stamp in the future means the clock moved —
        // a timezone fix, a restored backup, a machine whose date was briefly wrong — and
        // treating a negative age as "very recent" would freeze the ledger into refusing that
        // action until the calendar caught up, which for a clock a year fast is a year.
        abs(now.timeIntervalSince(entry.at)) <= window(for: entry.outcome)
    }

    private let url: URL
    private let secrets: StreamingRedactor
    private var entries: [String: Entry] = [:]
    private var loaded = false

    /// - Parameter extraSecrets: values to redact beyond the ones in the credential store, in
    ///   the same shape `TraceWriter` takes them. Tests use it; nothing in the app needs to.
    public init(root: URL, extraSecrets: [String] = []) {
        self.url = root.appendingPathComponent("effects.jsonl")
        self.secrets = StreamingRedactor.forRun(extra: extraSecrets)
    }

    /// An identity for an effect, derived from what it would *do* rather than when it was asked.
    ///
    /// Content-addressed on purpose: two attempts to send the same body to the same recipient are
    /// the same effect even though they are different tool calls in different runs with different
    /// ids. Arguments are canonicalised (sorted keys, stable encoding) so key order in the model's
    /// JSON cannot make the same action look like two.
    /// - Parameter environment: the computer the effect lands on, for tools where that is part
    ///   of what the effect *is*. `nil` for everything else, and omitted from the hash entirely
    ///   when nil, so keys for tools that do not pass it are unchanged.
    ///
    ///   Only shell tools pass it. A build, an install or a `mkdir` performed inside a bot's
    ///   Linux machine has not been performed on the Mac, and suppressing the second one tells
    ///   the bot a directory exists that does not — a false premise it then works from. The
    ///   opposite mistake is possible too: a `curl -X POST` reaches the same third party from
    ///   either computer, so changing a bot's environment can let one such command run a second
    ///   time. That is the narrower and less confusing failure, and it only occurs when the user
    ///   changes the setting between runs. The tools whose whole purpose is an outward,
    ///   irreversible effect — `mail.send`, `message.send`, `capability.invoke` — deliberately do
    ///   not pass an environment, so their identity is unchanged and unaffected by any of this.
    public static func key(tool: String, arguments: [String: Any],
                           environment: String? = nil) -> String {
        var hasher = SHA256()
        // The scheme name is hashed in so that changing the encoding below can only ever make
        // old keys stop matching. Without it a future encoding could hand an existing record to
        // a caller who meant something else by the same bytes, and a ledger that mixes up two
        // effects is worse than one with no history at all.
        hasher.update(data: Data(keyScheme.utf8))
        hasher.update(data: Data(canonicalise(tool).utf8))
        hasher.update(data: Data(canonicalise(arguments).utf8))
        if let environment {
            hasher.update(data: Data(canonicalise("env:" + environment).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let keyScheme = "botharness.effect-key.2"

    /// A self-delimiting rendering of a JSON-shaped value: `tag:byteCount:bytes` for every
    /// scalar, an element count on every container.
    ///
    /// The point is injectivity. Two different values must never render to the same string,
    /// because on this type a collision does not lose a cache hit — it silently suppresses a
    /// real, outward, irreversible effect on the grounds that an unrelated one already ran.
    ///
    /// The previous encoding concatenated `{k:v,k:v}` with no escaping and no type tag, so a
    /// value containing the punctuation reproduced the shape of extra keys. Demonstrated:
    ///
    ///     ["body": "hi,to:bob@example.com"]              -> {body:hi,to:bob@example.com}
    ///     ["to": "bob@example.com", "body": "hi"]        -> {body:hi,to:bob@example.com}
    ///
    /// — one mail to bob, one note mentioning him, the same key. Untagged scalars collided the
    /// same way: `1`, `1.0`, `true`, `"1"` and `"true"` were all one value.
    ///
    /// Rejected: `JSONSerialization` with `.sortedKeys`, which is shorter and also unambiguous
    /// for strings. It throws on anything it does not consider valid JSON — a `Date`, a
    /// non-finite number, a value some adapter forgot to convert — and the only two ways to
    /// answer a throw here are to crash or to return no key, and returning no key means silently
    /// not recording an effect. This encoding has no failure case.
    private static func canonicalise(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            // Sorted keys: the model's JSON key order is not part of what the action does.
            let body = dictionary.keys.sorted()
                .map { canonicalise($0) + canonicalise(dictionary[$0]!) }
                .joined()
            return "d:\(dictionary.count):" + body
        case let array as [Any]:
            return "a:\(array.count):" + array.map(canonicalise).joined()
        case let string as String:
            return "s:\(string.utf8.count):" + string
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            // Checked by CoreFoundation type rather than `as? Bool`, which succeeds for the
            // number 1 and would tag every 1 as `true` — reintroducing the collision from the
            // other side.
            return number.boolValue ? "b:1:1" : "b:1:0"
        case let number as NSNumber:
            // `1` and `1.0` deliberately land on the same rendering. A round trip through JSON
            // decides which of the two you get, and treating them as different effects would let
            // the same action through twice.
            let text = number.stringValue
            return "n:\(text.utf8.count):" + text
        case is NSNull:
            return "z:0:"
        default:
            // Anything not JSON-shaped still gets a length and a tag of its own, so it cannot
            // be confused with a string that happens to describe the same way.
            let text = String(describing: value)
            return "x:\(text.utf8.count):" + text
        }
    }

    /// What the ledger already knows about this effect, if anything — and only while that
    /// knowledge is still current. An expired record is not deleted, it simply stops answering;
    /// the line stays in the file because the file is the record of what the app did.
    public func existing(_ key: String) -> Entry? {
        load()
        guard let entry = entries[key], Self.speaksFor(entry, now: Date()) else { return nil }
        return entry
    }

    /// Record that an effect is about to be attempted. Written *before* the attempt, so a crash
    /// mid-effect leaves `uncertain` rather than no record at all — which is the whole point.
    public func beginning(_ key: String, tool: String, summary: String) {
        load()
        // The summary is the caller's rendering of the raw arguments, so it carries whatever
        // the model put in them — verified: a `shell.exec` of a curl with an Authorization
        // header wrote the bearer token verbatim into effects.jsonl. The key itself is a hash
        // and cannot leak; the prose beside it can, and did. `TraceWriter` runs both redactors
        // over everything it writes, and this file sits in the same directory, read by the same
        // people.
        let entry = Entry(key: key, tool: tool, summary: scrub(summary),
                          outcome: .uncertain, at: Date(),
                          note: "started; no result recorded yet")
        entries[key] = entry
        append(entry)
    }

    public func finished(_ key: String, outcome: Outcome, note: String = "") {
        load()
        guard var entry = entries[key] else { return }
        entry.outcome = outcome
        // Notes are error text, and error text quotes the command that produced it.
        entry.note = scrub(note)
        entries[key] = entry
        append(entry)
    }

    /// Both redactors, in the order `TraceWriter` uses them.
    ///
    /// Values first, patterns second. A known secret is replaced whole, so the regex pass never
    /// sees a fragment of one; the other order risks a pattern chewing the middle out of a value
    /// and leaving its head and tail behind, which looks redacted and is not.
    private func scrub(_ text: String) -> String {
        Redactor.redact(secrets.redact(text))
    }

    /// What to tell the model when it asks for an effect that already has a record.
    ///
    /// Phrased as a fact plus an instruction to verify, never as a refusal. A hard refusal would
    /// strand a run whose first attempt genuinely failed, and the model cannot tell the
    /// difference without being told what is known.
    public func advisory(for entry: Entry) -> String {
        switch entry.outcome {
        case .done:
            let resumes = Self.stamp(entry.at.addingTimeInterval(Self.completedSuppressionWindow))
            // Says when suppression ends rather than "change something about it so it is a
            // different action", which was the old advice and was close to instructing the model
            // to disguise a repeat in order to get it past a safeguard.
            return "This exact action completed on \(Self.stamp(entry.at)) "
                 + "(\(entry.summary)) and has not been repeated. If you are retrying because the "
                 + "result was lost, treat it as done. Identical repeats stop being suppressed at "
                 + "\(resumes) and run normally after that; if it has to happen sooner, say what "
                 + "you are repeating and why."
        case .uncertain:
            return "This exact action was attempted on \(Self.stamp(entry.at)) and the result was "
                 + "never confirmed (\(entry.note)). It may already have taken effect. Check "
                 + "before doing it again — do not simply retry."
        case .failed:
            return "This exact action was attempted on \(Self.stamp(entry.at)) and failed "
                 + "(\(entry.note)). Retrying is reasonable."
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM 'at' HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Disk

    private func load() {
        guard !loaded else { return }
        loaded = true
        // Read bytes and split on the newline byte rather than decoding the file to a String
        // first. A process killed mid-append leaves a truncated last record, and the truncation
        // can land inside a multi-byte character; `String(contentsOf:encoding:)` returns nil for
        // the *whole file* in that case, so one torn line cost every record in the ledger —
        // including the unconfirmed ones, which are the only records that matter.
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // Last write wins, which is what makes the append-only file behave like a map.
            // A line that will not decode is skipped rather than fatal: skipping costs at most
            // one missing advisory, refusing to load costs all of them.
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                entries[entry.key] = entry
            }
        }
    }

    private func append(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        // Re-asserted on every append rather than established once at creation. The directory is
        // the traces root, which outlives every run in it and is made by whichever writer gets
        // there first; a mode is not a fact you establish, it is one you keep.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // `open` with the mode and O_APPEND rather than create-then-narrow: the file is never
        // briefly group- or world-readable, and the kernel puts each record at the end of the
        // file atomically, so two writers cannot interleave halves of two lines.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // Narrows a file left behind by an earlier version, a restore, or a looser umask.
        // `open` applies the mode only when it creates the file, so this is not redundant.
        _ = fchmod(descriptor, 0o600)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(descriptor, base.advanced(by: written), raw.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    // A signal interrupted the call before any bytes moved; retrying is what
                    // keeps a half-written line out of the file.
                    continue
                } else {
                    // Out of space, or a broken descriptor. Stop rather than spin: the line is
                    // lost, and a lost line is survivable because `load` skips what it cannot
                    // parse. A busy loop here would not be.
                    break
                }
            }
        }
    }
}
