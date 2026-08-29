import Foundation
import CryptoKit

/// Keeps screenshots from eating a run.
///
/// Taken from rakazo, which solves this in two stages, and both matter:
///
/// **Frame deduplication.** If the screen has not changed, the new capture is byte-identical
/// in every way that counts. Sending it again costs roughly 1,500 tokens to tell the model
/// something it already knows, and — worse — an agent that sees the same frame twice often
/// concludes its action did nothing and retries it.
///
/// **Keep-last-N pruning.** Older frames are dropped from the context as new ones arrive. A
/// twenty-step GUI task otherwise carries twenty images forward, and by step ten the prompt is
/// mostly stale pictures of a screen that has since changed.
///
/// The two together are the difference between a computer-use run that is expensive and one
/// that is unaffordable.
public struct ScreenshotBudget: Sendable {

    /// How many frames stay in context. Three covers "before, during, after" for one action,
    /// which is what the model actually reasons over.
    public var keepLast: Int = 3

    private var recentHashes: [String] = []
    private var kept: [String] = []

    public init(keepLast: Int = 3) { self.keepLast = keepLast }

    public enum Decision: Sendable, Equatable {
        /// Send it, and drop these older frames.
        case send(pruning: [String])
        /// The screen has not changed since the last capture.
        case unchanged
    }

    /// Decide what to do with a freshly captured frame.
    ///
    /// - Parameter identifier: how the caller refers to this frame later, usually its filename.
    public mutating func consider(_ image: Data, identifier: String) -> Decision {
        let hash = Self.fingerprint(image)

        if recentHashes.last == hash {
            return .unchanged
        }

        recentHashes.append(hash)
        kept.append(identifier)
        if recentHashes.count > 8 { recentHashes.removeFirst() }

        var pruning: [String] = []
        while kept.count > keepLast {
            pruning.append(kept.removeFirst())
        }
        return .send(pruning: pruning)
    }

    /// A cheap content fingerprint.
    ///
    /// Hashing the whole PNG is exact but brittle: two captures of a genuinely static screen
    /// can still differ by a cursor blink or a clock tick, and then dedup never fires. Hashing
    /// a coarse sample instead — every 97th byte, a prime so it does not align with row
    /// stride — is tolerant of tiny changes and still catches "nothing happened".
    static func fingerprint(_ data: Data) -> String {
        var sampled = Data()
        sampled.reserveCapacity(data.count / 97 + 8)
        var index = data.startIndex
        while index < data.endIndex {
            sampled.append(data[index])
            index = data.index(index, offsetBy: 97, limitedBy: data.endIndex) ?? data.endIndex
        }
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { sampled.append(contentsOf: $0) }
        return SHA256.hash(data: sampled).map { String(format: "%02x", $0) }.joined()
    }
}
