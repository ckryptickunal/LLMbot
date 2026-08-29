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

        /// Present when the run ended badly, so a list can show the reason without opening it.
        public var failureSummary: String?
    }

    public var root: URL

    public init(root: URL = Paths.traces) { self.root = root }

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

            found.append(Run(
                id: name,
                directory: directory,
                manifest: manifest,
                stepCount: events.count,
                startedAt: manifest?.startedAt ?? events.first?.at ?? Date.distantPast,
                chain: TraceWriter.verifyChain(at: steps),
                failureSummary: failure.map { $0.error ?? $0.summary }
            ))
        }
        return found.sorted { $0.startedAt > $1.startedAt }.prefix(limit).map { $0 }
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
