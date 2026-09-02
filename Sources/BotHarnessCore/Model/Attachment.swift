import Foundation

/// A file the user handed to a bot, by dragging it onto the window or choosing it in the
/// attach panel.
///
/// This type exists because dropping a file was theatre. The path landed in the draft, the bot
/// called `files.inspect`, and the boundary refused it — a run may read its workspace and the
/// Desktop, and almost nothing anyone drags in lives in either. So the person performed the
/// most explicit act of consent the Mac has, picking the file up and putting it in the window,
/// and the app answered "this bot may only read inside the paths you gave it". Everything
/// downstream of the drop worked; the file was simply never granted.
///
/// **The grant comes from the gesture, never from the text.** Nothing in this file parses a
/// message. A model that writes `~/.ssh/id_rsa` into its reply has attached nothing: only a
/// drop or the open panel calls `grant`, and both of those are a human moving a physical
/// pointer. That separation is the entire safety argument for widening a run's authority at
/// all, and it is why this is its own type rather than four lines in the composer — a path the
/// user pointed at and a path the model typed must never travel by the same road.
public struct Attachment: Codable, Hashable, Identifiable, Sendable {

    public init(path: String, isDirectory: Bool, addedAt: Date = Date()) {
        self.path = path
        self.isDirectory = isDirectory
        self.addedAt = addedAt
    }

    /// The path is the identity. Dragging the same file in twice is one attachment, not two.
    public var id: String { path }

    /// Absolute, symlinks already resolved. Stored resolved because that is the form the
    /// boundary compares in: `FileExecutor` resolves before it checks, so a grant recorded as
    /// the symlink would be a grant that never matches anything.
    public let path: String

    public let isDirectory: Bool
    public var addedAt: Date

    public var name: String { (path as NSString).lastPathComponent }

    /// What this grant becomes in `Authority.readable`.
    ///
    /// A file grants exactly itself and not its folder. Dragging in one bank statement is not
    /// consent to read the rest of `~/Documents`, and the difference between those two costs
    /// one character to write and is the whole point of doing this per-file.
    public var readablePattern: String { isDirectory ? path + "/**" : path }

    // MARK: - Granting

    /// Why a dropped path was not granted.
    ///
    /// Refusals are values rather than a silent `nil` because the user has to be told. A file
    /// that is dropped, disappears, and then produces "I cannot read that" three messages later
    /// is the failure this whole change exists to remove; replacing it with a different silent
    /// failure would not be an improvement.
    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing is there. A drag from an app that promises a file it never writes, or a text
        /// selection that looked like a path.
        case missing(String)
        /// The path is on the floor every bot is held to, whoever drops it.
        case floor(path: String, hit: String)

        public var sentence: String {
            switch self {
            case .missing(let path):
                return "There is nothing at \(path), so it was not attached."
            case .floor(let path, let hit):
                return "\(((path as NSString).lastPathComponent)) was not attached: `\(hit)` holds credentials, and no bot may read it."
            }
        }
    }

    /// Turn a path the user pointed at into a grant, or say why not.
    ///
    /// The floor is checked *here* as well as in `FileExecutor`, and the duplication is
    /// deliberate. The executor's check is what makes it safe; this one is what makes it
    /// honest. Without it, dropping `~/.ssh/id_rsa` would appear to work — the path would sit
    /// in the draft looking attached — and the refusal would arrive later, from the bot,
    /// phrased as the bot's own limitation rather than as the app declining the drop.
    public static func grant(_ path: String) -> Result<Attachment, Refusal> {
        let expanded = PathGuard.expand(path)
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        // Resolved before the floor check, not after. A symlink in Downloads pointing at
        // `~/.ssh` is otherwise a hole straight through this, and it is exactly the shape of
        // thing that ends up in a Downloads folder without the owner noticing.
        let real = (standardized.path as NSString).resolvingSymlinksInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory) else {
            return .failure(.missing(real))
        }
        if let hit = PathGuard.denied(real, by: Authority.alwaysDenied) {
            return .failure(.floor(path: real, hit: hit))
        }
        return .success(Attachment(path: real, isDirectory: isDirectory.boolValue))
    }

    /// How many attachments one conversation may hold.
    ///
    /// A cap rather than no cap because every entry is scanned on every path check the run
    /// makes — each file read, each shell command, each glob — so an uncapped list turns the
    /// boundary into a linear walk of everything ever dragged into that conversation. Thirty-two
    /// is well past what anyone attaches by hand and far short of where the scan is noticeable.
    public static let limit = 32

    /// Fold new grants into the ones a conversation already holds.
    ///
    /// Newest wins on a repeat, so re-dropping a file after replacing it on disk refreshes the
    /// date rather than being ignored, and the oldest fall off the end at the cap. Order is
    /// most-recent-first because that is the order a person looks for them in.
    public static func merge(_ existing: [Attachment], adding incoming: [Attachment],
                             limit: Int = Attachment.limit) -> [Attachment] {
        var seen = Set<String>()
        return (incoming + existing)
            .filter { seen.insert($0.path).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
