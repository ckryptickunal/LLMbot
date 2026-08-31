import Foundation

/// How `state.json` is read when it does not say quite what this version of the app expects.
///
/// The document holds every bot the user has, every rule they wrote and the whole text of every
/// conversation, and it is also a file this app invites them to open and edit by hand. Against
/// that, synthesised `Codable` has exactly one response to an absent key, a renamed field or a
/// typed digit: throw. A throw at any depth fails the whole document, so one bad key in one bot
/// used to cost the user every bot they had — the failure `MemoryNote`'s hand-written decoder
/// was added to prevent, reappearing one level up.
///
/// These types invert that default. A field that cannot be read falls back to a value that is
/// safe to hold; an element that cannot be read is skipped and the rest of the array survives;
/// only a shape with nothing left in it to recover is allowed to fail the load.
///
/// The direction of every fallback is chosen to fail closed. Where no fallback is safe — a
/// bot's permission rules, most of all — the decoder still throws on purpose, and says so at
/// the line where it does. "Recover as much as possible" is the right instinct for a persona
/// and the wrong one for a rule, because the part that could not be read may be the part that
/// says no.

/// One element of an array in `state.json`, decoded so that a damaged element cannot throw.
///
/// Decoding `[Bot]` directly stops at the first element it cannot read and takes the document
/// with it. Catching that and carrying on is not possible either: an unkeyed container does not
/// advance past a value whose decode threw, so a `while !isAtEnd` loop that catches spins on the
/// same bad element forever. Wrapping each element in a type whose own decoder never throws
/// sidesteps both — the array decodes, and the failures arrive as `nil`s to be filtered out.
struct Recoverable<Element: Decodable>: Decodable {
    let element: Element?

    init(from decoder: Decoder) throws {
        do {
            element = try Element(from: decoder)
        } catch {
            element = nil
            decoder.recoveryLog?.lost("\(Element.self): \(String(describing: error))")
        }
    }
}

/// What a load could not read, gathered while it reads.
///
/// Exists so the loader can tell "this file decoded cleanly" from "this file decoded because we
/// filled in the gaps", and keep a copy of the original in the second case. Without it every
/// recovery is silent and the next save overwrites the evidence.
///
/// Locked, though a decode only ever runs on one thread. `JSONDecoder.userInfo` is typed as
/// `Sendable`, so this has to be safe to hand across threads or be an unchecked promise that it
/// is — and a promise the compiler cannot check, made about a type that exists to record
/// failures, is a poor trade for one uncontended lock per damaged field.
final class RecoveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func lost(_ what: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(what)
    }

    var losses: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var isEmpty: Bool { losses.isEmpty }
}

extension CodingUserInfoKey {
    /// Carries the `RecoveryLog` down to every nested decoder. `userInfo` rather than a global,
    /// so two loads can never write into each other's record.
    static let recoveryLog = CodingUserInfoKey(rawValue: "app.botharness.recoveryLog")!
}

extension Decoder {
    var recoveryLog: RecoveryLog? { userInfo[.recoveryLog] as? RecoveryLog }
}

/// A keyed container that recovers rather than throws, and records what it had to recover.
///
/// The recording is the reason this is a type rather than an extension on
/// `KeyedDecodingContainer`: a container has no route back to the decoder's `userInfo`, so an
/// extension can recover a mangled field but cannot tell anyone it did.
struct Recovery<Key: CodingKey> {

    /// The plain container, for the few fields that are decoded strictly on purpose. Reaching
    /// for this is a decision to let the record fail rather than load it wrong.
    let container: KeyedDecodingContainer<Key>

    private let log: RecoveryLog?

    /// What is being decoded, in the words a person would use — "a bot", "a conversation". Only
    /// ever read back out of the loss record.
    private let subject: String

    init(_ decoder: Decoder, of subject: String, keyedBy: Key.Type) throws {
        self.container = try decoder.container(keyedBy: Key.self)
        self.log = decoder.recoveryLog
        self.subject = subject
    }

    /// The value at `key`, or `fallback`.
    ///
    /// An absent key is not recorded as a loss: it is what every file written before the field
    /// existed looks like, and there is nothing there that could have been kept. A key that is
    /// present and unreadable is recorded, because a value the user set is being replaced.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        do {
            return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        } catch {
            note(key, error)
            return fallback
        }
    }

    /// The same, for a field whose absence is already a meaningful value.
    func optional<T: Decodable>(_ key: Key) -> T? {
        do {
            return try container.decodeIfPresent(T.self, forKey: key)
        } catch {
            note(key, error)
            return nil
        }
    }

    /// Every element at `key` that could be read, with the rest skipped and recorded.
    ///
    /// Never throws, including when the key holds something that is not an array: inside a
    /// record, an unreadable list of notes is worth less than the record it hangs off. The two
    /// arrays where that is not true — the document's own bots and conversations — are decoded
    /// through `container` instead, so that a `bots` key holding a string fails the load rather
    /// than quietly presenting the user with an empty roster and overwriting the real one.
    func elements<Element: Decodable>(_ key: Key, of type: Element.Type) -> [Element] {
        do {
            let wrapped = try container.decodeIfPresent([Recoverable<Element>].self, forKey: key)
            return wrapped?.compactMap(\.element) ?? []
        } catch {
            note(key, error)
            return []
        }
    }

    func contains(_ key: Key) -> Bool { container.contains(key) }

    /// Record something the surrounding decoder could not keep, when the loss is not one field.
    func lost(_ what: String) { log?.lost("\(subject): \(what)") }

    private func note(_ key: Key, _ error: Error) {
        log?.lost("\(subject).\(key.stringValue): \(String(describing: error))")
    }
}
