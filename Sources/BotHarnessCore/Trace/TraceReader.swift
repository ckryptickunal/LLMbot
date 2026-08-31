import Foundation

/// Reading traces back.
///
/// Writing a decision trace nobody can read is bookkeeping, not observability. This is the
/// other half: load past runs, replay their steps in order, and verify that the record has
/// not been altered since it was written.
///
/// Deliberately tolerant. A run that crashed mid-write leaves a truncated last line, and that
/// run is precisely the one you most want to look at — so a malformed line is skipped rather
/// than treated as a reason to fail loading the whole file.
public struct TraceReader: Sendable {

    public struct Run: Identifiable, Sendable {
        public var id: String            // the run directory name
        public var directory: URL
        public var manifest: TraceWriter.RunManifest?
        public var stepCount: Int
        public var startedAt: Date
        public var chain: TraceWriter.ChainStatus

        /// How the chain was signed. `chain` alone cannot tell "intact" from "intact, but
        /// written before there was anything to forge against", and presenting the second as
        /// the first is the overstatement this field exists to prevent.
        public var signing: TraceWriter.ChainReport.Signing
        /// Whether `run.json` still carries the seal its writer put on it — or, when it is
        /// `.missing`, whether there is a `run.json` at all.
        public var manifestSeal: TraceWriter.ManifestSeal

        /// Present when the run ended badly, so a list can show the reason without opening it.
        public var failureSummary: String?
    }

    public var root: URL

    /// Overrides the machine's chain key. Tests pass one so the suite never has to touch the
    /// real credential file; the app leaves it nil and gets the key `TraceWriter` signed with.
    public var chainKey: Data?

    public init(root: URL = Paths.traces, chainKey: Data? = nil) {
        self.root = root
        self.chainKey = chainKey
    }

    /// Every recorded run, newest first.
    public func runs(limit: Int = 100) -> [Run] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return [] }

        var found: [Run] = []
        for name in names where !name.hasPrefix(".") {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let steps = directory.appendingPathComponent("steps.jsonl")
            guard manager.fileExists(atPath: steps.path) else { continue }

            let manifest = readManifest(directory)
            let events = self.events(in: directory)
            let failure = events.last { $0.outcome == .failed || $0.kind == .runFinished && ($0.summary.hasPrefix("failed") || $0.summary.hasPrefix("escalated")) }

            let report = TraceWriter.inspectChain(at: steps, chainKey: chainKey)
            let seal = manifest.map { TraceWriter.verifyManifest($0, chainKey: chainKey) }
                ?? TraceWriter.ManifestSeal.missing

            found.append(Run(
                id: name,
                directory: directory,
                manifest: manifest,
                stepCount: events.count,
                startedAt: manifest?.startedAt ?? events.first?.at ?? Date.distantPast,
                chain: chainStatus(report, seal: seal, expectedRecords: manifest?.records),
                signing: report.signing,
                manifestSeal: seal,
                failureSummary: failure.map { $0.error ?? $0.summary }
            ))
        }
        return found.sorted { $0.startedAt > $1.startedAt }.prefix(limit).map { $0 }
    }

    /// Cross-check the two halves of the record against each other.
    ///
    /// The keyed chain closes the forgery a bare SHA-256 left open, but on its own it leaves one
    /// move: strip the algorithm marker from every record, re-link the file with the public
    /// SHA-256, and it reads as a trace from before signing existed — unremarkable rather than
    /// altered. The manifest is what catches that. Its seal cannot be forged without the key, so
    /// a run whose `run.json` still says "this was signed" while its steps claim to predate
    /// signing has had its steps rewritten, and this is the only place that sees both facts at
    /// once.
    ///
    /// Two moves that used to survive this comparison, both closed below.
    ///
    /// **Cutting the tail off.** Delete the last lines of `steps.jsonl` and the chain still
    /// verifies — a prefix of a hash chain is a hash chain, and no amount of hashing can make a
    /// file notice an end that is no longer there. The manifest is the only witness to how long
    /// the file was, and its count is sealed, so the two are compared here.
    ///
    /// **Deleting `run.json`.** The note that used to sit here said a run with no manifest is
    /// "visibly incomplete", and that was wrong: no manifest scored the same as an unsealed one,
    /// so deleting the file turned a caught forgery back into an unremarkable old trace. A run
    /// with no manifest whose steps also claim to predate signing is now reported as damaged,
    /// because nothing is left that could tell a genuinely old trace from a downgraded one. A run
    /// that was interrupted before it could write its manifest is the case this must not accuse,
    /// and it does not: those steps are signed, and a signed chain with no manifest still reads
    /// as intact.
    private func chainStatus(_ report: TraceWriter.ChainReport,
                             seal: TraceWriter.ManifestSeal,
                             expectedRecords: Int?) -> TraceWriter.ChainStatus {
        if seal == .sealed, report.signing == .writtenBeforeSigning {
            return .brokenAt(line: 1, reason: "re-written without the signature this run was sealed with")
        }
        if seal == .altered, case .intact = report.status {
            return .brokenAt(line: 0, reason: "the run manifest no longer matches its seal")
        }
        if case .intact(let records) = report.status, let expected = expectedRecords,
           records != expected {
            // Checked whichever way the two disagree, not only when the file is short. Nothing
            // appends to a trace after its manifest is written — `finish` closes the handle — so
            // a file longer than its manifest says has had records added to it, and that is no
            // more innocent than having them removed.
            return .brokenAt(
                line: min(records, expected) + 1,
                reason: records < expected
                    ? "the file stops \(expected - records) records before the manifest says it ended"
                    : "\(records - expected) records were added after the manifest was sealed"
            )
        }
        if seal == .missing, report.signing == .writtenBeforeSigning, case .intact = report.status {
            return .brokenAt(line: 0,
                             reason: "there is no run manifest, and unsigned steps with nothing "
                             + "to check them against prove nothing")
        }
        return report.status
    }

    public func readManifest(_ directory: URL) -> TraceWriter.RunManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("run.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TraceWriter.RunManifest.self, from: data)
    }

    /// Every step of a run, in order.
    public func events(in directory: URL) -> [TraceWriter.Event] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("steps.jsonl"),
                                     encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var events: [TraceWriter.Event] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A crashed run's last line is often half-written. Skip it and keep the rest —
            // that run is the one worth reading.
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(TraceWriter.Event.self, from: data)
            else { continue }
            events.append(event)
        }
        return events
    }

    /// Fold completion records back onto the steps they complete, so a reader sees one entry
    /// per action with its result attached rather than two entries to correlate by hand.
    public func timeline(in directory: URL) -> [Entry] {
        let events = self.events(in: directory)
        var completions: [Int: TraceWriter.Event] = [:]
        for event in events where event.kind == .completion {
            if let completes = event.completes { completions[completes] = event }
        }

        return events.compactMap { event in
            guard event.kind != .completion else { return nil }
            let done = completions[event.seq]
            return Entry(
                seq: event.seq,
                at: event.at,
                kind: event.kind,
                summary: event.summary,
                intent: event.intent,
                tool: event.tool,
                arguments: event.arguments,
                output: done?.output ?? event.output,
                error: done?.error ?? event.error,
                outcome: done?.outcome,
                permission: event.permissionOutcome.map {
                    Permission(outcome: $0, reason: event.permissionReason ?? "",
                               layer: event.permissionLayer ?? "")
                },
                model: event.model,
                tokens: (event.promptTokens ?? 0) + (event.completionTokens ?? 0),
                costUSD: event.costUSD
            )
        }
    }

    public struct Entry: Identifiable, Sendable {
        public var id: Int { seq }
        public var seq: Int
        public var at: Date
        public var kind: TraceWriter.Event.Kind
        public var summary: String
        public var intent: String?
        public var tool: String?
        public var arguments: String?
        public var output: String?
        public var error: String?
        public var outcome: TraceWriter.Outcome?
        public var permission: Permission?
        public var model: String?
        public var tokens: Int
        public var costUSD: Double?
    }

    public struct Permission: Sendable {
        public var outcome: String
        public var reason: String
        public var layer: String
    }
}
