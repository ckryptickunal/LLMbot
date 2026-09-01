import Foundation
import CryptoKit

/// The failure log: what keeps going wrong, across every run.
///
/// This is not another trace. `TraceWriter` answers *"what happened in this run"* — it is
/// per-run, hash-chained, and complete. It is the wrong shape for the question a person
/// actually asks on a Monday morning: *"what keeps failing, and is it getting better or
/// worse?"* Answering that means reading across every run at once, which nothing else here
/// does.
///
/// Three commitments, each of which costs something:
///
/// - **One append-only JSONL file for all runs.** A trace directory per run is right for
///   auditing a single run and useless for spotting a pattern across forty of them. This file
///   is small, greppable, and readable with `cat` after the app is deleted.
/// - **A stable signature, computed on the way in.** Raw failure messages never group: they
///   carry paths, pids, ports, uuids, byte counts and timings, so the same problem in two
///   directories looks like two problems. `FailureSignature` normalises those out before
///   hashing. Without it this file is a pile, not a report.
/// - **Redacted on the way in, like the trace.** Failure messages quote commands, and a command
///   is where a key ends up. Redaction happens before the line is written, because a file that
///   is only ever appended to cannot be edited afterwards.
///
/// The `recovered` flag is the field that earns its place. A failure the agent retried past
/// costs seconds; a failure that ended the run costs the user their whole task and their
/// attention. Ranking without that distinction reports the loudest problem rather than the
/// worst one.
///
/// Rooted at a URL given to `init` rather than at `Paths.root`, so tests and evals write beside
/// their own traces and never into the real user's history.
public final class FailureLog: @unchecked Sendable {

    /// The file. Public because the point of a plain-text record is that other tools read it.
    public let fileURL: URL

    /// Guards the handle and the file. `TraceWriter` is an actor and gets serialisation from
    /// that; this cannot be, because it is called from `catch` blocks all over the tool layer,
    /// including synchronous ones, and an actor would make every one of those `await`. A lock
    /// around a handful of short appends is the cheaper trade.
    private let lock = NSLock()
    private var handle: FileHandle?

    /// Seeded once, for the same reason `TraceWriter` seeds once: a file whose lines were
    /// scrubbed against different secret sets is not auditable.
    private let valueRedactor: StreamingRedactor

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sorted keys are not for the machine — nothing here is hash-chained. They are so a
        // human diffing two days of this file sees changed values rather than reordered keys.
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// - Parameters:
    ///   - root: the directory the file lives in — normally the same `var/traces` the run
    ///     traces are written to, so a user who copies that directory copies the history too.
    ///   - extraSecrets: values beyond the credential store that must never reach this file.
    public init(root: URL, extraSecrets: [String] = []) {
        self.fileURL = root.appendingPathComponent("failures.jsonl")
        self.valueRedactor = StreamingRedactor.forRun(extra: extraSecrets)

        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        self.handle = FailureLog.openForAppending(fileURL)
    }

    deinit { try? handle?.close() }

    /// Opened `O_APPEND` rather than by seeking to the end.
    ///
    /// Two copies of the app, or an eval running while the app is open, both hold this file.
    /// `O_APPEND` makes each write land at the real end of the file as one operation; a seek
    /// followed by a write has a window between the two in which the other writer moves the
    /// end, and the loser's line lands on top of the winner's. There is no Foundation API for
    /// the flag, so this is `open(2)` — chosen over adding a dependency, and over accepting
    /// interleaved corruption.
    private static func openForAppending(_ url: URL) -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        // Re-asserted rather than trusted to the creation mode, which the umask can narrow and
        // an earlier version's file would not have at all. This file holds real commands.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - Recording

    /// Record a failure. Returns the record's id, which `markRecovered` takes.
    ///
    /// `recovered` defaults to false because at the moment a tool throws, nobody knows yet.
    /// Writing the line now and amending it later is the same trade `TraceWriter` makes with
    /// `proposed`/`completed`: a run that dies before it can amend still leaves the evidence
    /// that it failed, which is precisely the run you most want in the report.
    @discardableResult
    public func record(source: String,
                       message: String,
                       bot: String? = nil,
                       run: String? = nil,
                       recovered: Bool = false,
                       at: Date = Date()) -> String {
        // Redact first, normalise second. The other order would hash the secret into the
        // signature — a signature is a hash, but it is derived from text that also gets stored
        // as `pattern`, and a key in the pattern is a key in the file.
        let safe = scrub(message)
        let record = FailureRecord(
            id: UUID().uuidString,
            at: at,
            source: source,
            signature: FailureSignature.signature(source: source, message: safe),
            pattern: FailureSignature.normalise(safe),
            message: safe,
            bot: bot.map(scrub),
            run: run,
            recovered: recovered
        )
        append(record)
        return record.id
    }

    /// Amend an earlier failure to say the run carried on past it.
    ///
    /// A separate line rather than a rewrite, so a crash halfway through cannot corrupt what
    /// was already true.
    public func markRecovered(_ id: String, at: Date = Date()) {
        append(FailureAmendment(amends: id, at: at, recovered: true))
    }

    private func append<T: Encodable>(_ value: T) {
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        // Best-effort, like every other write in the trace layer: failing to record a failure
        // must never turn into a second failure the user has to deal with.
        try? handle?.write(contentsOf: data)
    }

    private func scrub(_ text: String) -> String {
        Redactor.redact(valueRedactor.redact(text))
    }

    // MARK: - Reading

    /// Everything in the file, oldest first, with amendments folded in.
    public func records() -> [FailureRecord] { load().records }

    /// The read, with the part callers need to be honest about.
    ///
    /// A line that will not parse is skipped rather than treated as the end of the file. The
    /// common case is not corruption at all: it is the last line of a process that was killed
    /// mid-write. Stopping there would throw away every later line for the sake of one, and a
    /// history that silently shortens itself is worse than one with a hole in it — so the hole
    /// is counted and reported instead.
    public func load() -> (records: [FailureRecord], unreadableLines: Int) {
        lock.lock()
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        lock.unlock()

        var records: [FailureRecord] = []
        var recovered: Set<String> = []
        var unreadable = 0

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8) else { unreadable += 1; continue }
            if let record = try? FailureLog.decoder.decode(FailureRecord.self, from: data) {
                records.append(record)
            } else if let amendment = try? FailureLog.decoder.decode(FailureAmendment.self, from: data) {
                if amendment.recovered { recovered.insert(amendment.amends) }
            } else {
                unreadable += 1
            }
        }

        // Applied after the whole file is read, because an amendment can only ever appear after
        // the record it amends and a single pass would have to look backwards.
        for index in records.indices where recovered.contains(records[index].id) {
            records[index].recovered = true
        }
        records.sort { $0.at < $1.at }
        return (records, unreadable)
    }

    // MARK: - Pruning

    /// Keep the newest `newest` failures and drop the rest. Returns how many were kept.
    ///
    /// This is also the repair path, and deliberately so: it rewrites the file from records
    /// that parsed, so a line nothing can read leaves with the pruning rather than living in
    /// the file forever. Amendments are folded into the records they amend on the way out, so
    /// pruning never orphans one.
    @discardableResult
    public func prune(keeping newest: Int) -> Int {
        let kept = Array(load().records.suffix(max(0, newest)))
        var body = Data()
        for record in kept {
            guard var line = try? encoder.encode(record) else { continue }
            line.append(0x0A)
            body.append(line)
        }

        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil

        // Written to a sibling and moved into place. A truncate-then-write would leave the file
        // empty for the length of the write, and a crash in that window costs the entire
        // history — which is the one thing pruning exists to protect.
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent("failures.jsonl.pruning-\(UUID().uuidString.prefix(6))")
        guard (try? body.write(to: temporary, options: .atomic)) != nil else {
            handle = FailureLog.openForAppending(fileURL)
            return 0
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: temporary.path)
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        handle = FailureLog.openForAppending(fileURL)
        return kept.count
    }
}

// MARK: - Records

/// One failure, as it is stored.
public struct FailureRecord: Codable, Sendable, Equatable {
    public var id: String
    public var at: Date
    /// The tool or subsystem: `shell`, `browser`, `files`, `git`, `brain.gemini`.
    public var source: String
    /// The grouping key. See `FailureSignature`.
    public var signature: String
    /// The normalised message the signature was computed from.
    ///
    /// Stored rather than recomputed for one reason that matters more than the cost: it is what
    /// lets a person read the report and check that the grouping matches the grouping they
    /// would have done. A signature is twelve hex characters and proves nothing to a reader.
    public var pattern: String
    /// The message as it was thrown, redacted.
    public var message: String
    public var bot: String?
    public var run: String?
    /// Whether the run carried on past this. False also means "not known to have recovered",
    /// which is the honest reading for a run that died before it could say.
    public var recovered: Bool
}

/// An amendment: the run recovered from a failure written earlier.
struct FailureAmendment: Codable {
    var amends: String
    var at: Date
    var recovered: Bool
}

// MARK: - Signatures

/// Turns a failure message into a key that groups the same problem across runs.
///
/// The whole value of this file rests on this type. A raw message never groups, because it
/// carries the things that differ between two occurrences of one problem: the directory, the
/// pid, the port, the uuid, the byte count, the elapsed seconds. Normalising those to
/// placeholders is what makes "this happened eleven times this week" a sentence that can be
/// said at all.
///
/// The trade runs in both directions and only one of them is safe to get wrong. Normalising too
/// little splits one problem into eleven singletons and the report says nothing. Normalising
/// too much merges genuinely different problems and the report says something false. So the
/// rules here replace only what is *volatile by construction*, and specifically do **not**
/// touch small bare integers: `-1743` and `-600` are different AppleEvent failures with
/// different fixes, and `git exited with status 128` is not `status 1`. Losing those would be
/// merging on the very number that identifies the problem.
public enum FailureSignature {

    /// Ordered. URLs run before paths because a URL contains a path, and absolute paths run
    /// before relative ones for the same reason.
    private static let rules: [(NSRegularExpression, String)] = {
        let sources: [(String, String)] = [
            (#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"#, "<time>"),
            (#"\b\d{1,2}:\d{2}:\d{2}\b"#, "<time>"),
            // osascript's `12:34: execution error:` — a position in a script the user never
            // wrote, which differs every time the same failure happens.
            (#"\b\d+:\d+:(?=\s)"#, "<pos>:"),
            (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "<uuid>"),
            // The tail cannot end on punctuation, so a URL that ends a clause leaves its comma
            // or full stop behind instead of swallowing it and making the pattern unreadable.
            (#"\b[a-zA-Z][a-zA-Z0-9+.\-]*://(?:[^\s"'`<>]*[^\s"'`<>.,;:!?)\]])?"#, "<url>"),
            // Absolute and home paths. The last character cannot be a dot, so a path ending a
            // sentence keeps the full stop instead of swallowing it.
            (#"~?/(?:[A-Za-z0-9._@%+\-]+/)+(?:[A-Za-z0-9._@%+\-]*[A-Za-z0-9_@%+\-])?"#, "<path>"),
            // Relative paths need two separators before they count. One is not enough: "and/or"
            // is not a path, and a rule that says it is starts eating prose.
            (#"\b[A-Za-z0-9._@%+\-]+/(?:[A-Za-z0-9._@%+\-]+/)+[A-Za-z0-9._@%+\-]*"#, "<path>"),
            (#"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, "<ip>"),
            (#":\d{2,5}\b"#, ":<port>"),
            // Hex blobs — commit ids, hashes, handles. Required to contain a digit so an
            // ordinary eight-letter word made only of a–f cannot match.
            (#"\b(?=[0-9a-fA-F]{8,}\b)[0-9a-fA-F]*\d[0-9a-fA-F]*\b"#, "<hex>"),
            (#"(?i)\bpid[ =]\d+"#, "pid <pid>"),
            (#"(?i)\b\d+(?:\.\d+)?\s?(?:bytes|byte|kb|mb|gb|kib|mib|gib|characters|chars)\b"#, "<size>"),
            (#"(?i)\b\d+(?:\.\d+)?\s?(?:ms|s|seconds|second|minutes|minute|hours|hour)\b"#, "<duration>"),
            // Six digits and up is a count, a timestamp or an offset, never an error code worth
            // keeping. Four and five are left alone on purpose — see the type comment.
            (#"\b\d{6,}\b"#, "<n>"),
            (#"\s+"#, " "),
        ]
        return sources.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()

    /// The readable form: the message with everything volatile replaced by a placeholder.
    public static func normalise(_ message: String) -> String {
        var out = message
        for (pattern, replacement) in rules {
            out = pattern.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: replacement
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The grouping key: twelve hex characters over the source and the normalised message.
    ///
    /// The source is part of the hash so that identical wording from two subsystems stays two
    /// problems. "timed out" from the browser and "timed out" from the shell have nothing in
    /// common but the words, and a report that merges them sends the reader to the wrong place.
    ///
    /// Case-folded before hashing. Case is not a difference worth splitting a group on — one
    /// executor lowercases the text it quotes and another does not — while the stored `pattern`
    /// keeps its original case because a person has to read it.
    public static func signature(source: String, message: String) -> String {
        let body = source.lowercased() + "\n" + normalise(message).lowercased()
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}

// MARK: - The report

extension FailureLog {

    /// What deserves attention, and whether it is getting worse.
    ///
    /// This is the reason the file exists. Everything above it is bookkeeping.
    ///
    /// - Parameters:
    ///   - since: the start of the window. The period immediately before it, of the same
    ///     length, is the comparison — which is what makes "worse" mean something.
    ///   - now: the end of the window. A parameter rather than `Date()` so the report is a
    ///     function of its inputs and can be tested.
    public func report(since: Date, now: Date = Date()) -> FailureReport {
        let read = load()
        let length = max(now.timeIntervalSince(since), 1)
        let previousStart = since.addingTimeInterval(-length)

        let current = read.records.filter { $0.at >= since && $0.at <= now }
        let previous = read.records.filter { $0.at >= previousStart && $0.at < since }

        var previousCounts: [String: Int] = [:]
        for record in previous { previousCounts[record.signature, default: 0] += 1 }

        var groups: [FailureReport.Group] = []
        for (signature, records) in Dictionary(grouping: current, by: \.signature) {
            guard let newest = records.max(by: { $0.at < $1.at }) else { continue }
            let unrecovered = records.filter { !$0.recovered }.count
            let before = previousCounts[signature] ?? 0
            groups.append(.init(
                signature: signature,
                source: newest.source,
                pattern: newest.pattern,
                count: records.count,
                unrecovered: unrecovered,
                previousCount: before,
                lastSeen: newest.at,
                bots: Set(records.compactMap(\.bot)).sorted(),
                trend: before == 0 ? .new
                     : records.count > before ? .worse(from: before)
                     : records.count < before ? .better(from: before)
                     : .steady
            ))
        }

        // Ranked by weight, not by count, and this is the one design decision in the file that
        // a reader is most likely to want to argue with, so: a failure that ended the run cost
        // the user their whole task and their attention — they had to come back and restart it.
        // A failure the agent recovered from cost seconds and nobody noticed. Those are not the
        // same event twenty times over, so counting them the same makes the report rank the
        // noisiest problem instead of the worst one, which is how a report becomes something
        // nobody reads.
        //
        // Twenty to one is deliberately steep enough to satisfy the case that motivated it:
        // three failures that each ended a run must outrank thirty that always recovered
        // (30 against 15). It is a judgement, not a measurement — but the direction of the
        // judgement is the part that matters, and getting it backwards is the failure mode.
        groups.sort { left, right in
            if left.weight != right.weight { return left.weight > right.weight }
            if left.unrecovered != right.unrecovered { return left.unrecovered > right.unrecovered }
            if left.count != right.count { return left.count > right.count }
            if left.lastSeen != right.lastSeen { return left.lastSeen > right.lastSeen }
            // Ties break on the signature so the same input always produces the same order.
            // A report whose rows shuffle between runs cannot be diffed against yesterday's.
            return left.signature < right.signature
        }

        return FailureReport(
            since: since,
            until: now,
            groups: groups,
            total: current.count,
            unrecovered: current.filter { !$0.recovered }.count,
            previousTotal: previous.count,
            previousUnrecovered: previous.filter { !$0.recovered }.count,
            unreadableLines: read.unreadableLines
        )
    }
}

/// The answer to "what keeps failing, and is it getting worse".
public struct FailureReport: Sendable, Equatable {

    public enum Trend: Sendable, Equatable {
        case new
        case worse(from: Int)
        case better(from: Int)
        case steady
    }

    /// One problem, seen however many times.
    public struct Group: Sendable, Equatable {
        public var signature: String
        public var source: String
        public var pattern: String
        public var count: Int
        public var unrecovered: Int
        public var previousCount: Int
        public var lastSeen: Date
        public var bots: [String]
        public var trend: Trend

        public var recoveredCount: Int { count - unrecovered }

        /// Attention, not volume. See the comment on the sort in `report(since:)`.
        public var weight: Double { Double(unrecovered) * 10 + Double(recoveredCount) * 0.5 }
    }

    public var since: Date
    public var until: Date
    /// Ranked: the thing to fix first is `groups.first`.
    public var groups: [Group]
    public var total: Int
    public var unrecovered: Int
    public var previousTotal: Int
    public var previousUnrecovered: Int
    public var unreadableLines: Int

    /// Whether the period got worse, measured the same way the ranking is.
    ///
    /// Compared on weight rather than on raw count, for the same reason: a week that traded ten
    /// recoveries for one dead end got worse, and a count would call it a big improvement.
    public var trend: Trend {
        let now = Double(unrecovered) * 10 + Double(total - unrecovered) * 0.5
        let before = Double(previousUnrecovered) * 10 + Double(previousTotal - previousUnrecovered) * 0.5
        if before == 0 { return now > 0 ? .new : .steady }
        // A tenth either way is noise, not a trend. Without a band the report calls every
        // period "worse" or "better" and the word stops carrying information.
        if now > before * 1.1 { return .worse(from: previousTotal) }
        if now < before * 0.9 { return .better(from: previousTotal) }
        return .steady
    }

    /// The report, in the voice the product uses: what failed, what it cost, what I conclude.
    public var text: String {
        var lines: [String] = []
        let window = FailureReport.describe(since: since, until: until)

        guard total > 0 else {
            lines.append("Nothing failed in \(window).")
            if previousTotal > 0 {
                lines.append("\(FailureReport.plural(previousTotal, "failure")) the period before, so this is a clean run of it.")
            }
            if unreadableLines > 0 { lines.append(FailureReport.unreadableNote(unreadableLines)) }
            return lines.joined(separator: "\n")
        }

        let recovered = total - unrecovered
        var headline = "\(FailureReport.plural(unrecovered, "dead end")) and "
                     + "\(FailureReport.plural(recovered, "recovery", plural: "recoveries")) in \(window)"
        if previousTotal > 0 || previousUnrecovered > 0 {
            headline += ", against \(previousUnrecovered) and \(previousTotal - previousUnrecovered) the period before"
        }
        switch trend {
        case .worse:  headline += ". Worse."
        case .better: headline += ". Better."
        case .steady: headline += ". About the same."
        case .new:    headline += ". Nothing to compare it against."
        }
        lines.append(headline)
        lines.append("")

        // Five is where a daily report stops being read. Everything else is still in the file
        // and still in `groups`; this is the part a person looks at over coffee.
        for (index, group) in groups.prefix(5).enumerated() {
            lines.append("\(index + 1). \(group.source) — \(FailureReport.plural(group.count, "failure")), "
                       + "\(FailureReport.outcomePhrase(group)). \(FailureReport.trendPhrase(group.trend))")
            lines.append("   \(FailureReport.clip(group.pattern))")
        }
        if groups.count > 5 {
            lines.append("")
            lines.append("\(groups.count - 5) more kinds below these, all smaller.")
        }

        lines.append("")
        if let worst = groups.first, worst.unrecovered > 0 {
            let cost = worst.unrecovered == worst.count
                ? "every one of its \(FailureReport.plural(worst.count, "failure")) ended the run"
                : "\(worst.unrecovered) of its \(worst.count) ended the run"
            lines.append("\(worst.source) is what I would fix first: \(cost).")
        } else {
            lines.append("Nothing here ended a run. I recovered from all of it, so this is noise to clean up rather than something to stop and fix.")
        }
        if unreadableLines > 0 { lines.append(FailureReport.unreadableNote(unreadableLines)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Phrasing

    private static func unreadableNote(_ count: Int) -> String {
        // Said out loud rather than swallowed. A report that quietly drops evidence is worse
        // than one that admits it lost some.
        "\(FailureReport.plural(count, "line")) in the log would not parse. I skipped past them; the rest of the history is intact."
    }

    private static func plural(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(plural ?? noun + "s")"
    }

    private static func outcomePhrase(_ group: Group) -> String {
        if group.unrecovered == 0 { return group.count == 1 ? "it recovered" : "all recovered" }
        if group.unrecovered == group.count {
            return group.count == 1 ? "it ended the run" : "every one ended the run"
        }
        return "\(group.unrecovered) ended the run"
    }

    private static func trendPhrase(_ trend: Trend) -> String {
        switch trend {
        case .new:               return "New this period."
        case .worse(let from):   return "Up from \(from)."
        case .better(let from):  return "Down from \(from)."
        case .steady:            return "Unchanged."
        }
    }

    /// Cosmetic only — the signature already decided what groups.
    private static func clip(_ pattern: String, limit: Int = 140) -> String {
        pattern.count <= limit ? pattern : String(pattern.prefix(limit - 1)) + "…"
    }

    private static func describe(since: Date, until: Date) -> String {
        let seconds = until.timeIntervalSince(since)
        if seconds < 7200 { return "the last \(plural(Int((seconds / 60).rounded()), "minute"))" }
        if seconds < 172_800 { return "the last \(plural(Int((seconds / 3600).rounded()), "hour"))" }
        return "the last \(plural(Int((seconds / 86_400).rounded()), "day"))"
    }
}
