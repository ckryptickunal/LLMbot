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
/// with the *actual values* held for this run — read once from the Keychain at the start — and
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

    public init(secrets: [String]) {
        // Very short values would match ordinary prose, so they are not worth redacting and
        // would ruin the output if they were.
        let usable = secrets.filter { $0.count >= 8 }
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
        for account in ["gemini", "anthropic", "openai"] {
            if let value = Keychain.get(account) { values.append(value) }
        }
        return StreamingRedactor(secrets: values)
    }
}
