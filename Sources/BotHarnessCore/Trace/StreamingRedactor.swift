import Foundation

/// Redacts known secret values from a stream, across chunk boundaries.
///
/// `Redactor` already strips things that *look* like credentials from whole strings. This
/// solves the two problems that leaves.
///
/// **Chunk boundaries.** Streamed text arrives in fragments. Redacting each fragment on its own
/// leaks any secret that straddles two of them — which is precisely what happens when a model
/// echoes a key back token by token. This holds the tail of the buffer back until it is long
/// enough that no known secret could still be spanning the edge.
///
/// **Shapes no pattern knows.** Regexes catch `sk-…` and `AIza…`. They do not catch a base URL,
/// a refresh token, or a bearer string with no distinctive prefix. So this redactor is seeded
/// with the *actual values* held for this run — read once from the credential store — and
/// matches those literally.
///
/// It matters here more than in most places: the trace is append-only and hash-chained, so a
/// leaked key cannot be edited out afterwards without breaking the chain. Redaction has to
/// happen on the way in or not at all.
public struct StreamingRedactor {

    /// Known secret values, longest first so a longer secret containing a shorter one is
    /// matched whole rather than leaving a fragment behind.
    private let secrets: [String]
    private let longest: Int
    private var buffer = ""

    /// The shortest value worth matching literally.
    ///
    /// Eight characters is a judgement, not a measurement: below it a stored value is not a key
    /// any provider issues — it is a placeholder, a truncated paste, or a mistake — while a short
    /// run of characters is very likely to occur in ordinary prose, and redacting it would blank
    /// words out of the model's own output. Above it the trade goes the other way: a false
    /// «redacted» costs a reader one confusing line, and a missed key is permanent, because the
    /// trace is hash-chained and cannot be edited afterwards.
    private static let shortestWorthMatching = 8

    public init(secrets: [String]) {
        let usable = secrets.filter { $0.count >= Self.shortestWorthMatching }
        self.secrets = usable.sorted { $0.count > $1.count }
        self.longest = usable.map(\.count).max() ?? 0
    }

    public var isEmpty: Bool { secrets.isEmpty }

    /// Feed a chunk; get back everything that is now safe to emit.
    ///
    /// Holds back `longest - 1` characters, which is the most that a secret could still be
    /// straddling. Anything before that point cannot be part of a match completed by a later
    /// chunk, so it is safe to release.
    public mutating func push(_ chunk: String) -> String {
        guard longest > 0 else { return chunk }
        buffer += chunk

        // Scrub the whole buffer *before* deciding what to release. Releasing first and
        // scrubbing the released part was the bug the tests caught: a secret spanning the
        // release point had its head emitted and only its tail redacted.
        buffer = scrub(buffer)

        // After scrubbing, any complete secret is gone. Only a partially-arrived one can
        // remain, and it can be at most `longest - 1` characters, so hold that much back.
        guard buffer.count >= longest else { return "" }
        let releasable = buffer.count - (longest - 1)
        let index = buffer.index(buffer.startIndex, offsetBy: releasable)
        let head = String(buffer[..<index])
        buffer = String(buffer[index...])
        return head
    }

    /// Drain whatever is still held back. Always call this, or the tail of the stream is lost.
    public mutating func finish() -> String {
        defer { buffer = "" }
        return scrub(buffer)
    }

    /// One-shot convenience for text that is not streamed.
    public func redact(_ text: String) -> String { scrub(text) }

    private func scrub(_ text: String) -> String {
        guard !secrets.isEmpty, !text.isEmpty else { return text }
        var out = text
        for secret in secrets where out.contains(secret) {
            out = out.replacingOccurrences(of: secret, with: "«redacted»")
        }
        return out
    }

    /// Every secret this run could plausibly emit, read once at the start.
    ///
    /// Reads the values rather than pattern-matching them afterwards, which is the whole point:
    /// a base URL or a refresh token has no recognisable shape.
    public static func forRun(extra: [String] = []) -> StreamingRedactor {
        var values: [String] = extra
        // Every account in the store, not a fixed list of three. `CredentialStore` accepts any
        // name and `scripts/set-key.sh` documents its argument as `<gemini|anthropic|openai|...>`,
        // so a key stored as "openrouter" or "groq" used to stream through untouched — into a
        // trace that is append-only and hash-chained, where it could not be removed afterwards.
        // That is the compensating control ADR 0012 leans on hardest, and it was covering three
        // names out of an open set.
        for account in CredentialStore.accounts() {
            if let value = CredentialStore.get(account) { values.append(value) }
        }
        return StreamingRedactor(secrets: values)
    }
}
