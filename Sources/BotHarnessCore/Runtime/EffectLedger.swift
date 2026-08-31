import Foundation
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

    private let url: URL
    private var entries: [String: Entry] = [:]
    private var loaded = false

    public init(root: URL) {
        self.url = root.appendingPathComponent("effects.jsonl")
    }

    /// An identity for an effect, derived from what it would *do* rather than when it was asked.
    ///
    /// Content-addressed on purpose: two attempts to send the same body to the same recipient are
    /// the same effect even though they are different tool calls in different runs with different
    /// ids. Arguments are canonicalised (sorted keys, stable encoding) so key order in the model's
    /// JSON cannot make the same action look like two.
    public static func key(tool: String, arguments: [String: Any]) -> String {
        let canonical = canonicalise(arguments)
        var hasher = SHA256()
        hasher.update(data: Data(tool.utf8))
        hasher.update(data: Data(canonical.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalise(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            return "{" + dictionary.keys.sorted()
                .map { "\($0):\(canonicalise(dictionary[$0]!))" }
                .joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(canonicalise).joined(separator: ",") + "]"
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return String(describing: value)
        }
    }

    /// What the ledger already knows about this effect, if anything.
    public func existing(_ key: String) -> Entry? {
        load()
        return entries[key]
    }

    /// Record that an effect is about to be attempted. Written *before* the attempt, so a crash
    /// mid-effect leaves `uncertain` rather than no record at all — which is the whole point.
    public func beginning(_ key: String, tool: String, summary: String) {
        load()
        let entry = Entry(key: key, tool: tool, summary: summary,
                          outcome: .uncertain, at: Date(),
                          note: "started; no result recorded yet")
        entries[key] = entry
        append(entry)
    }

    public func finished(_ key: String, outcome: Outcome, note: String = "") {
        load()
        guard var entry = entries[key] else { return }
        entry.outcome = outcome
        entry.note = note
        entries[key] = entry
        append(entry)
    }

    /// What to tell the model when it asks for an effect that already has a record.
    ///
    /// Phrased as a fact plus an instruction to verify, never as a refusal. A hard refusal would
    /// strand a run whose first attempt genuinely failed, and the model cannot tell the
    /// difference without being told what is known.
    public func advisory(for entry: Entry) -> String {
        switch entry.outcome {
        case .done:
            return "This exact action was already completed on \(Self.stamp(entry.at)) "
                 + "(\(entry.summary)). It has not been repeated. If you genuinely need it done "
                 + "again, change something about it so it is a different action."
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
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in text.split(separator: "\n") {
            // Last write wins, which is what makes the append-only file behave like a map.
            if let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) {
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
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            manager.createFile(atPath: url.path, contents: data,
                               attributes: [.posixPermissions: 0o600])
        }
    }
}
