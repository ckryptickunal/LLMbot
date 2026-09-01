import Foundation
import Compression
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Turning a file a person dropped into the chat into something a model can actually reason
/// about: what it is, what is in it, and — for an archive — its contents on disk.
///
/// **Why this exists.** Before it, the only way in was `files.read`, which is `String(contentsOf:)`
/// with UTF-8 assumed. A PDF arrived as a page of binary garbage, a Word document as XML wrapped
/// in zip noise, a Latin-1 CSV as mojibake, and a zip could not be opened at all. Worse, a 200 MB
/// CSV read whole destroyed the run it was meant to help. Every one of those failures looks to the
/// model like "the file is empty or corrupt", which is the most expensive wrong conclusion an
/// agent can reach about evidence it was given.
///
/// **The shape of the fix.** `inspect` first — cheap facts that decide what to do next — then one
/// of `extractText`, `preview` or `unarchive`. Everything is capped, and every cap that bites is
/// stated in the returned text, because silently truncated evidence is how a model concludes
/// something is absent when it was merely cut off.
///
/// **What the caller still owes.** Nothing here wraps its result in an untrusted-content
/// envelope. That belongs at the dispatch boundary in `AgentLoop`, where every other tool applies
/// it, so that there is one place to audit rather than one per tool. A document body returned from
/// `extractText`, `preview`, `inspect` or the entry names in `unarchive` is attacker-controlled
/// text and must be enveloped there.
public actor FileIngest {

    private let authority: Authority
    /// The read-side boundary is `FileExecutor`'s, not a second copy of it. `PathGuard`'s own
    /// header records that this guard was independently reimplemented three times and was a hole
    /// each time; a fourth reimplementation for reads would be the same mistake with a new name.
    private let files: FileExecutor

    public init(authority: Authority) {
        self.authority = authority
        self.files = FileExecutor(authority: authority)
    }

    // MARK: - Caps

    /// Every limit in one place, so a refusal can quote the number that caused it.
    ///
    /// These are chosen against the context window rather than against the disk. Roughly four
    /// characters make a token, so 40,000 characters is about 10,000 tokens: a document a model
    /// can hold alongside its actual task. 400,000 is about 100,000 tokens, which is most of a
    /// window — that is a ceiling for a caller who has decided it needs the whole thing, not a
    /// default. The archive numbers are chosen against the machine instead: this app runs on a
    /// real Mac with no snapshot, so an extraction that fills the disk is not recoverable by
    /// restarting anything.
    public enum Limits {
        /// What `extractText` returns when the caller does not say.
        public static let defaultTextCharacters = 40_000
        /// The most `extractText` will return however large a number the caller passes.
        public static let maximumTextCharacters = 400_000
        /// What `preview` returns when the caller does not say: enough to recognise a file.
        public static let defaultPreviewCharacters = 4_000

        /// How much of a file `inspect` will read to count lines, rows and columns. Counting is
        /// worth doing and is not worth reading 200 MB for, so past this point the counts are
        /// reported honestly as "at least N, over the first 8 MB".
        public static let inspectionWindowBytes = 8 << 20

        /// A document handed to PDFKit or NSAttributedString is parsed by a framework we do not
        /// control, in this process. A ceiling keeps a hostile file from being a memory problem.
        public static let maximumDocumentBytes = 256 << 20

        /// Archive bounds. An archive that declares more than these is refused before a single
        /// byte is written, with the real numbers in the message.
        public static let maximumArchiveEntries = 4_096
        public static let maximumArchiveBytes = 256 << 20
        public static let maximumEntryBytes = 64 << 20
        /// gzip has no random access, so a `.gz` or `.tar.gz` is inflated in memory. This bounds
        /// the *compressed* input; `maximumArchiveBytes` bounds what comes out.
        public static let maximumCompressedInMemoryBytes = 64 << 20
        /// Expansion beyond this ratio, on an archive large enough to matter, is a bomb rather
        /// than a well-compressed file. Text compresses about 4:1 and a tar of near-identical
        /// files can reach 100:1 honestly, so the threshold is well clear of anything real.
        public static let maximumExpansionRatio = 500
        public static let ratioAppliesAboveBytes = 32 << 20
    }

    // MARK: - 1. Inspect

    /// What this file IS and the cheap facts that decide what to do with it next.
    ///
    /// Deliberately prose rather than JSON. The consumer is a model choosing its next tool call,
    /// and a sentence saying "this PDF has 40 pages and no extractable text, so it is a scan"
    /// changes behaviour in a way that `{"pages": 40, "hasText": false}` does not.
    public func inspect(_ path: String) async throws -> String {
        let url = try await readable(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw IngestError.missing("There is no file at \(url.path). Check the path, or list the containing directory first.")
        }
        if isDirectory.boolValue { return try describeDirectory(url) }

        let size = try byteCount(of: url)
        let type = Self.uniformType(of: url)
        let kind = try Self.classify(url: url, type: type, size: size)
        var lines = [Self.headline(url: url, type: type, size: size, kind: kind)]

        switch kind {
        case .pdf:            lines += try describePDF(url)
        case .richDocument(let documentType):
            lines += try await describeRichDocument(url, documentType: documentType, size: size)
        case .image:          lines += describeImage(url)
        case .archive(let f): lines += try describeArchive(url, format: f, size: size)
        case .delimitedText:  lines += try describeDelimited(url, size: size)
        case .plainText:      lines += try describePlainText(url, size: size)
        case .directory:      break
        case .opaque:
            lines.append("No text layer and no reader here for this type. `files.read` will return raw bytes; a shell tool may know more.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 2. Extract text

    /// Plain text out of a document, with the reader chosen by what the file actually is.
    ///
    /// - Parameter maxCharacters: clamped to `Limits.maximumTextCharacters`. Truncation is always
    ///   reported in the returned text; it is never silent.
    public func extractText(_ path: String, maxCharacters: Int = Limits.defaultTextCharacters) async throws -> String {
        let cap = min(max(1, maxCharacters), Limits.maximumTextCharacters)
        let url = try await readable(path)
        let size = try byteCount(of: url)
        let type = Self.uniformType(of: url)
        let kind = try Self.classify(url: url, type: type, size: size)

        switch kind {
        case .directory:
            throw IngestError.wrongKind("\(url.lastPathComponent) is a directory, not a document. Call inspect on it to list what is inside, then extract text from one of the files.")
        case .image:
            throw IngestError.wrongKind("\(url.lastPathComponent) is an image (\(Self.name(of: type))). It has no text layer to extract. Show it to a vision-capable brain, or run OCR on it, instead.")
        case .archive(let format):
            throw IngestError.wrongKind("\(url.lastPathComponent) is a \(format.label) archive. Unarchive it into a directory you may write to, then extract text from the files inside.")
        case .opaque:
            throw IngestError.wrongKind("\(url.lastPathComponent) is \(Self.name(of: type)), which has no text reader here. If you believe it is really text, say so and read it with files.read.")
        case .pdf:
            return try extractPDF(url, cap: cap)
        case .richDocument(let documentType):
            guard size <= Limits.maximumDocumentBytes else {
                throw IngestError.tooLarge("\(url.lastPathComponent) is \(Self.humanBytes(size)); this reader refuses documents over \(Self.humanBytes(Limits.maximumDocumentBytes)) because the whole file is parsed in memory.")
            }
            let whole = try await Self.attributedPlainText(at: url, documentType: documentType)
            return Self.capped(whole, at: cap, describing: url.lastPathComponent)
        case .delimitedText, .plainText:
            return try extractPlainText(url, size: size, cap: cap)
        }
    }

    // MARK: - 3. Unarchive

    /// Extract a zip, tar, tar.gz, tgz or gz into a directory the bot may write to.
    ///
    /// This is the dangerous one, so the order of operations is the point: the whole archive is
    /// listed and every entry name is resolved and checked *before* anything is written. An
    /// extractor that writes first and validates after has already lost.
    @discardableResult
    public func unarchive(_ path: String, to destination: String) async throws -> String {
        let archiveURL = try await readable(path)
        let size = try byteCount(of: archiveURL)
        let root = try writableDirectory(destination)

        // Magic bytes, not the extension. The extension is a claim by whoever named the file and
        // the whole point of this function is not to trust that person. It also means an
        // extensionless download still opens.
        guard let format = try Self.archiveFormat(of: archiveURL) else {
            throw IngestError.wrongKind("\(archiveURL.lastPathComponent) is not a zip, tar, tar.gz, tgz or gz — its first bytes match none of them. Use inspect to find out what it actually is.")
        }

        let source = try Self.byteSource(for: archiveURL, format: format)
        let entries = try Self.listEntries(source.source, format: source.format, archiveName: archiveURL.lastPathComponent)
        try Self.assertNotABomb(entries, compressedBytes: size, archiveName: archiveURL.lastPathComponent)

        // Resolve and check every destination first. A refusal here has written nothing.
        var planned: [(entry: ArchiveEntry, url: URL)] = []
        for entry in entries {
            if entry.isSymbolicLink {
                // A symlink inside an archive is the second half of a zip-slip: extract
                // `docs -> /Users/x/.ssh`, then let a later entry write `docs/authorized_keys`
                // straight through it. Every path check in this function operates on names, and
                // a name cannot see through a link that does not exist yet — so links are refused
                // outright rather than checked. Nothing a bot needs from an archive is a symlink.
                throw IngestError.refusedEntry("\(archiveURL.lastPathComponent) contains a symbolic link, \"\(entry.name)\" pointing at \"\(entry.linkTarget ?? "?")\". A link inside an archive can redirect a later entry outside the destination, so nothing was extracted. Extract it with a shell tool if you have decided it is safe.")
            }
            if let kind = entry.unsupportedKind {
                // The same argument as the symlink above, one step weaker: a hard link, a device
                // node or a fifo is not a regular file, and writing it as an empty regular file
                // would hand back an archive that looks extracted and is not. Refused whole, in
                // the planning pass, so nothing has been written when this fires.
                throw IngestError.refusedEntry("\(archiveURL.lastPathComponent) contains a \(kind), \"\(entry.name)\"\(entry.linkTarget.map { " pointing at \"\($0)\"" } ?? ""). This extractor writes only regular files and directories, so nothing was extracted. Unpack it with a shell tool if you have decided it is safe.")
            }
            let target = try safeDestination(for: entry.name, under: root, archiveName: archiveURL.lastPathComponent)
            planned.append((entry, target))
        }

        var filesWritten = 0
        var directoriesWritten = 0
        var bytesWritten = 0
        for step in planned {
            if step.entry.isDirectory {
                try FileManager.default.createDirectory(at: step.url, withIntermediateDirectories: true)
                directoriesWritten += 1
                continue
            }
            let data = try Self.data(for: step.entry, in: source.source, archiveName: archiveURL.lastPathComponent)
            try FileManager.default.createDirectory(at: step.url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Mode bits from the archive are deliberately not restored. An archive that can mark
            // its own payload executable has done half the work of getting itself run; a person
            // who genuinely needs `+x` can say so.
            try data.write(to: step.url, options: .atomic)
            filesWritten += 1
            bytesWritten += data.count
        }

        let topLevel = Self.topLevelNames(of: entries)
        var out = "Extracted \(filesWritten) file\(filesWritten == 1 ? "" : "s")"
        if directoriesWritten > 0 { out += " and \(directoriesWritten) director\(directoriesWritten == 1 ? "y" : "ies")" }
        out += " (\(Self.humanBytes(bytesWritten))) from \(archiveURL.lastPathComponent) into \(root.path)."
        if !topLevel.isEmpty {
            out += "\nTop level: \(topLevel.prefix(20).joined(separator: ", "))"
            if topLevel.count > 20 { out += ", and \(topLevel.count - 20) more" }
            out += "."
        }
        return out
    }

    // MARK: - 4. Preview

    /// The first N characters of whatever this is, already converted to text.
    ///
    /// For anything with no text at all — an image, an archive, a directory — this returns the
    /// `inspect` description rather than an error. "Just show me what is in this" is a question,
    /// and the description answers it; a refusal would make the caller run a second tool to learn
    /// something this call already knew.
    public func preview(_ path: String, maxCharacters: Int = Limits.defaultPreviewCharacters) async throws -> String {
        do {
            return try await extractText(path, maxCharacters: maxCharacters)
        } catch IngestError.wrongKind {
            return try await inspect(path)
        }
    }

    // MARK: - Boundary

    private func readable(_ path: String) async throws -> URL {
        URL(fileURLWithPath: try await files.assertReadable(path))
    }

    /// The write-side check for an extraction destination.
    ///
    /// This mirrors `FileExecutor.resolve(_:forWriting: true)` rather than calling it, because
    /// `FileExecutor` publishes only a read assertion and that file is owned by another agent in
    /// this session. It is the one duplication in this file and it should be collapsed into a
    /// public `assertWritable` on `FileExecutor` the moment that file is free to edit — a second
    /// copy of a boundary check is exactly the drift `PathGuard`'s header warns about.
    private func writableDirectory(_ path: String) throws -> URL {
        let expanded = PathGuard.expand(path)
        guard !expanded.isEmpty else {
            throw IngestError.denied("No destination was given. Pass a directory inside the workspace to extract into.")
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        let real = URL(fileURLWithPath: (standardized.path as NSString).resolvingSymlinksInPath)

        if let hit = PathGuard.denied(real.path, by: Authority.alwaysDenied) {
            throw IngestError.denied("Refused to extract into \(real.path): `\(hit)` holds credentials, and no bot may touch it.")
        }
        if let hit = PathGuard.denied(real.path, by: Authority.alwaysDeniedForWriting) {
            throw IngestError.denied("Refused to extract into \(real.path): `\(hit)` is the app's own record and must stay as written.")
        }
        if let hit = PathGuard.denied(real.path, by: authority.denied) {
            throw IngestError.denied("Refused to extract into \(real.path): `\(hit)` is on this bot's never-allowed list.")
        }
        guard !authority.writable.isEmpty else {
            throw IngestError.denied("This bot has no writable paths, so there is nowhere to extract to. Ask the user to grant a workspace.")
        }
        guard authority.writable.contains(where: { PathGuard.isInside(real.path, $0) }) else {
            throw IngestError.denied("Refused to extract into \(real.path): it is outside every path this bot may write to. Extract into the workspace instead.")
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: real.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw IngestError.denied("\(real.path) is a file, not a directory. Give a directory to extract into.")
            }
            let existing = try FileManager.default.contentsOfDirectory(atPath: real.path)
                .filter { $0 != ".DS_Store" }
            // Extracting over a directory that already has work in it lets an archive replace
            // files nobody asked it to touch, and the damage is invisible until someone opens
            // the wrong version. A new directory costs one line and makes the overwrite explicit.
            guard existing.isEmpty else {
                throw IngestError.denied("\(real.path) already contains \(existing.count) item\(existing.count == 1 ? "" : "s"). Extract into a new or empty directory so the archive cannot overwrite work in place.")
            }
        } else {
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        }
        return URL(fileURLWithPath: (real.path as NSString).resolvingSymlinksInPath)
    }

    /// The zip-slip defence. Every archive entry name goes through here before anything is written.
    ///
    /// Three things have to be true, and only the third is the one people remember:
    ///
    /// 1. The name must not be absolute and must not start with `~` or `$`. `PathGuard.expand`
    ///    substitutes `~` and `$HOME` *anywhere* in a string — that is what makes it correct for
    ///    scanning a command line — so an entry literally named `~/.ssh/authorized_keys` would be
    ///    expanded into the home directory by the very function checking it. Rejected by shape,
    ///    before any expansion happens.
    /// 2. The resolved path must be inside the destination. `standardizedFileURL` collapses `..`,
    ///    and `PathGuard.isInside` compares whole path components with symlinks resolved and case
    ///    folded — which matters here because the home volume is case-insensitive.
    /// 3. It must not land on anything the floor protects, even if the destination somehow does.
    private func safeDestination(for entryName: String, under root: URL, archiveName: String) throws -> URL {
        let name = entryName.replacingOccurrences(of: "\\", with: "/")
        guard !name.isEmpty else {
            throw IngestError.refusedEntry("\(archiveName) contains an entry with an empty name. Nothing was extracted.")
        }
        guard !name.hasPrefix("/"), !name.hasPrefix("~"), !name.contains("$"), !name.contains("\0") else {
            throw IngestError.refusedEntry("\(archiveName) contains an entry named \"\(entryName)\", which is an absolute or home-relative path rather than a name inside the archive. Nothing was extracted.")
        }

        let candidate = URL(fileURLWithPath: name, relativeTo: root).standardizedFileURL
        guard PathGuard.isInside(candidate.path, root.path) else {
            throw IngestError.refusedEntry("\(archiveName) contains an entry named \"\(entryName)\", which resolves to \(candidate.path) — outside the destination \(root.path). This is a zip-slip attempt. Nothing was extracted.")
        }
        if let hit = PathGuard.denied(candidate.path, by: Authority.alwaysDenied) {
            throw IngestError.refusedEntry("\(archiveName) contains an entry named \"\(entryName)\", which lands on `\(hit)`. Nothing was extracted.")
        }
        if let hit = PathGuard.denied(candidate.path, by: Authority.alwaysDeniedForWriting) {
            throw IngestError.refusedEntry("\(archiveName) contains an entry named \"\(entryName)\", which would overwrite `\(hit)`. Nothing was extracted.")
        }
        if let hit = PathGuard.denied(candidate.path, by: authority.denied) {
            throw IngestError.refusedEntry("\(archiveName) contains an entry named \"\(entryName)\", which lands on `\(hit)`, on this bot's never-allowed list. Nothing was extracted.")
        }
        return candidate
    }

    private func byteCount(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values.isDirectory == true { return 0 }
        return values.fileSize ?? 0
    }

    // MARK: - Errors

    /// Every case is a sentence that tells the model what to do next. A model cannot act on a code.
    public enum IngestError: LocalizedError, Equatable {
        case missing(String)
        case denied(String)
        case wrongKind(String)
        case tooLarge(String)
        case malformed(String)
        case refusedEntry(String)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let s), .denied(let s), .wrongKind(let s), .tooLarge(let s),
                 .malformed(let s), .refusedEntry(let s), .unreadable(let s):
                return s
            }
        }
    }
}

// MARK: - What a file is

extension FileIngest {

    /// The reader this file needs. Not the extension — the extension is a claim.
    enum Kind {
        case directory
        case pdf
        case richDocument(NSAttributedString.DocumentType)
        case image
        case archive(ArchiveFormat)
        /// CSV or TSV: text, but with rows and columns worth counting.
        case delimitedText
        case plainText
        /// Nothing here can read it as text.
        case opaque
    }

    /// The uniform type, asked of the filesystem first and guessed from the extension only as a
    /// fallback. The filesystem's answer accounts for a file whose extension was stripped by a
    /// download, which is common enough to matter.
    static func uniformType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        return UTType(filenameExtension: url.pathExtension)
    }

    static func name(of type: UTType?) -> String {
        guard let type else { return "of an unrecognised type" }
        return type.localizedDescription ?? type.identifier
    }

    /// Classification order matters, and the interesting case is a `.docx`.
    ///
    /// A `.docx` is a zip, and a magic-byte test would say so. Here the declared uniform type wins
    /// for reading, so `extractText` on a Word document gets its text rather than a list of XML
    /// parts. `unarchive` deliberately uses the opposite rule and goes by magic bytes, so a caller
    /// who explicitly asks to unzip a `.docx` still can.
    static func classify(url: URL, type: UTType?, size: Int) throws -> Kind {
        // First, because everything below this line opens the file. A directory reaching the
        // magic-byte sniff throws a Cocoa error about saving a file, which is both wrong and
        // unactionable; `extractText` already has the sentence to say instead.
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .directory }
        if let type {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .rtfd) || type == .rtfd { return .richDocument(.rtfd) }
            if type.conforms(to: .rtf) { return .richDocument(.rtf) }
            if type.conforms(to: .html) { return .richDocument(.html) }
            if type.identifier == "org.openxmlformats.wordprocessingml.document" { return .richDocument(.officeOpenXML) }
            if type.identifier == "com.microsoft.word.doc" { return .richDocument(.docFormat) }
            if type.identifier == "com.apple.webarchive" { return .richDocument(.webArchive) }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) { return .delimitedText }
        }
        switch url.pathExtension.lowercased() {
        case "csv", "tsv": return .delimitedText
        case "docx":       return .richDocument(.officeOpenXML)
        case "doc":        return .richDocument(.docFormat)
        default:           break
        }
        if let format = try archiveFormat(of: url) { return .archive(format) }
        if let type, type.conforms(to: .text) { return .plainText }
        // No declared type worth trusting, so ask the bytes. A file that decodes as text and is
        // not peppered with control characters is text, whatever it is called.
        if size > 0, looksLikeText(try head(of: url, bytes: 8 << 10).data) { return .plainText }
        return .opaque
    }

    /// Does this byte prefix read as text?
    ///
    /// A NUL byte settles it — no text encoding this reads produces one — and beyond that the
    /// test is the share of control characters, because a UTF-16 or Latin-1 file will not decode
    /// as UTF-8 and would otherwise be called binary.
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if data.contains(0) { return false }
        guard let (text, _, _) = decode(data) else { return false }
        let control = text.unicodeScalars.filter {
            $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        return control * 100 < max(1, text.unicodeScalars.count)
    }

    // MARK: Bytes in

    /// Read at most `bytes` from the front of a file, and say whether there was more.
    ///
    /// A bounded read is the whole reason `inspect` can be called on a 200 MB CSV without
    /// thinking about it.
    static func head(of url: URL, bytes: Int) throws -> (data: Data, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: bytes) ?? Data()
        let more = (try handle.read(upToCount: 1)?.isEmpty == false)
        return (data, more)
    }

    /// Decode bytes to text and say which encoding was used.
    ///
    /// Order is deliberate. UTF-8 first because it is nearly always right and its failure is
    /// unambiguous. Then `NSString.stringEncoding(for:)`, which is Foundation's own detector and
    /// is what turns a Latin-1 export from a bank or a CRM into readable text instead of
    /// mojibake — the failure this whole function exists for. Windows-1252 last, lossily, marked
    /// as a guess, because returning "here is the text, I had to guess the encoding" beats
    /// returning nothing at all.
    static func decode(_ data: Data) -> (text: String, encoding: String, guessed: Bool)? {
        guard !data.isEmpty else { return ("", "UTF-8", false) }
        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8", false) }

        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: data,
                                          encodingOptions: nil,
                                          convertedString: &converted,
                                          usedLossyConversion: &lossy)
        if raw != 0, let converted {
            let encoding = String.Encoding(rawValue: raw)
            let label = String.localizedName(of: encoding)
            return (converted as String, label.isEmpty ? "encoding \(raw)" : label, lossy.boolValue)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return (text, "Windows-1252 (guessed; nothing else decoded it)", true)
        }
        return nil
    }

    /// The same decode, for a prefix that may have cut a multi-byte character in half.
    ///
    /// Without this, a bounded read of a UTF-8 file fails to decode roughly three times in four
    /// whenever the cut lands mid-character, and the file is reported as binary. Dropping up to
    /// three trailing bytes costs nothing and removes the whole class of false negative.
    static func decodePrefix(_ data: Data) -> (text: String, encoding: String, guessed: Bool)? {
        for drop in 0...min(3, data.count) {
            let slice = data.dropLast(drop)
            if let result = decode(Data(slice)) { return result }
        }
        return nil
    }

    // MARK: Formatting

    static func humanBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func headline(url: URL, type: UTType?, size: Int, kind: Kind) -> String {
        let identifier = type.map { " · \($0.identifier)" } ?? ""
        return "\(url.path) — \(name(of: type))\(identifier), \(humanBytes(size))."
    }

    /// Truncate to a cap and say so, in the returned text, every time.
    ///
    /// The notice is a full sentence rather than an ellipsis because the reader is a model
    /// deciding whether something is absent from a document. "…" reads as style; this reads as a
    /// fact about the evidence.
    static func capped(_ text: String, at cap: Int, describing name: String) -> String {
        guard text.count > cap else { return text }
        let kept = String(text.prefix(cap))
        return kept + "\n\n[TRUNCATED: this is the first \(grouped(cap)) of \(grouped(text.count)) characters in \(name). The rest was not read. Do not conclude that anything is absent from this document on the basis of this excerpt — call again with a larger maxCharacters if you need more.]"
    }
}

// MARK: - Descriptions

extension FileIngest {

    func describeDirectory(_ url: URL) throws -> String {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: url.path).sorted()
        var lines = ["\(url.path) — a directory containing \(names.count) item\(names.count == 1 ? "" : "s")."]
        // Shallow on purpose. A deep walk of a home directory is minutes of work and pages of
        // output for a question that was "what is in here".
        let shown = names.prefix(50)
        for name in shown {
            let child = url.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                lines.append("  \(name)/")
            } else {
                let size = (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                lines.append("  \(name) — \(Self.humanBytes(size))")
            }
        }
        if names.count > shown.count {
            lines.append("  … and \(names.count - shown.count) more, not listed.")
        }
        return lines.joined(separator: "\n")
    }

    func describePDF(_ url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else {
            throw IngestError.unreadable("PDFKit could not open \(url.lastPathComponent). It is probably damaged or encrypted; if you have the password, it has to be removed outside this tool.")
        }
        if document.isEncrypted && document.isLocked {
            return ["\(document.pageCount) pages, and the document is locked. No text can be read until it is unlocked outside this tool."]
        }
        var lines = ["\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")."]
        // Whether there is a text layer is the fact that decides the next move, so it is worth
        // three pages of work to answer. A scan and a born-digital PDF look identical from the
        // outside and need completely different handling.
        let probed = min(3, document.pageCount)
        var sampled = ""
        for index in 0..<probed {
            sampled += document.page(at: index)?.string ?? ""
        }
        let meaningful = sampled.trimmingCharacters(in: .whitespacesAndNewlines).count
        if meaningful < 20 {
            lines.append("No extractable text in the first \(probed) page\(probed == 1 ? "" : "s"), so this is almost certainly a scan or an image-only export. extractText will return nothing useful; it needs OCR or a vision-capable brain instead.")
        } else {
            lines.append("Has a real text layer (\(Self.grouped(meaningful)) characters in the first \(probed) page\(probed == 1 ? "" : "s")). Read it with extractText.")
        }
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Title recorded in the file: \(title)")
        }
        return lines
    }

    func describeRichDocument(_ url: URL, documentType: NSAttributedString.DocumentType, size: Int) async throws -> [String] {
        guard size <= Limits.maximumDocumentBytes else {
            return ["Larger than the \(Self.humanBytes(Limits.maximumDocumentBytes)) this reader will parse, so it was not opened."]
        }
        do {
            let text = try await Self.attributedPlainText(at: url, documentType: documentType)
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            return ["Readable as text: \(Self.grouped(text.count)) characters, about \(Self.grouped(words)) words. Read it with extractText."]
        } catch {
            return ["Could not be converted to text: \(error.localizedDescription)"]
        }
    }

    func describeImage(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ["Dimensions could not be read; the file may be truncated."]
        }
        // ImageIO reads the header only. Decoding the pixels to learn the size would be the
        // expensive way to answer a question that is in the first few dozen bytes.
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var lines = ["\(width) × \(height) pixels."]
        if let model = properties[kCGImagePropertyColorModel] as? String { lines.append("Colour model: \(model).") }
        let frames = CGImageSourceGetCount(source)
        if frames > 1 { lines.append("\(frames) frames — animated or multi-page.") }
        lines.append("There is no text layer to extract. Show it to a vision-capable brain, or run OCR.")
        return lines
    }

    func describeArchive(_ url: URL, format: ArchiveFormat, size: Int) throws -> [String] {
        let source = try Self.byteSource(for: url, format: format)
        let entries = try Self.listEntries(source.source, format: source.format, archiveName: url.lastPathComponent)
        let total = entries.reduce(0) { $0 + $1.uncompressedSize }
        let fileCount = entries.filter { !$0.isDirectory }.count
        var lines = ["\(Self.grouped(entries.count)) entries (\(Self.grouped(fileCount)) files), \(Self.humanBytes(total)) uncompressed."]
        if total > 0 && size > 0 {
            lines.append("Expands about \(max(1, total / max(1, size)))× from \(Self.humanBytes(size)) on disk.")
        }
        let escaping = entries.filter { Self.escapesByName($0.name) }
        if !escaping.isEmpty {
            lines.append("REFUSAL AHEAD: \(escaping.count) entr\(escaping.count == 1 ? "y" : "ies") name a path outside the archive, starting with \"\(escaping[0].name)\". unarchive will refuse this file whole. Do not try to work around it.")
        }
        if let odd = entries.first(where: { $0.unsupportedKind != nil }) {
            lines.append("REFUSAL AHEAD: contains a \(odd.unsupportedKind!), \"\(odd.name)\", which unarchive will not write.")
        }
        if entries.contains(where: { $0.isSymbolicLink }) {
            lines.append("REFUSAL AHEAD: contains symbolic links, which unarchive refuses because a link can redirect a later entry outside the destination.")
        }
        if entries.count > Limits.maximumArchiveEntries || total > Limits.maximumArchiveBytes {
            lines.append("REFUSAL AHEAD: over the extraction limits of \(Self.grouped(Limits.maximumArchiveEntries)) entries and \(Self.humanBytes(Limits.maximumArchiveBytes)).")
        }
        let top = Self.topLevelNames(of: entries)
        if !top.isEmpty {
            lines.append("Top level: \(top.prefix(20).joined(separator: ", "))\(top.count > 20 ? ", and \(top.count - 20) more" : "").")
        }
        return lines
    }

    /// A name that would escape its archive, judged by shape alone. `inspect` uses this to warn;
    /// the actual refusal is `safeDestination`, which resolves the path rather than guessing.
    static func escapesByName(_ name: String) -> Bool {
        let normalised = name.replacingOccurrences(of: "\\", with: "/")
        if normalised.hasPrefix("/") || normalised.hasPrefix("~") || normalised.contains("$") { return true }
        return normalised.split(separator: "/").contains("..")
    }

    static func topLevelNames(of entries: [ArchiveEntry]) -> [String] {
        var seen: [String] = []
        var set = Set<String>()
        for entry in entries {
            let head = entry.name.split(separator: "/").first.map(String.init) ?? entry.name
            let label = entry.name.contains("/") ? head + "/" : head
            if set.insert(label).inserted { seen.append(label) }
        }
        return seen
    }

    func describeDelimited(_ url: URL, size: Int) throws -> [String] {
        let (data, truncated) = try Self.head(of: url, bytes: Limits.inspectionWindowBytes)
        guard let (text, encoding, guessed) = Self.decodePrefix(data) else {
            return ["Could not be decoded as text in any encoding tried, so it is not really a delimited file."]
        }
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let rows = Self.delimitedRows(text, delimiter: delimiter)
        var lines: [String] = []
        if let header = rows.first {
            lines.append("\(header.count) columns: \(header.joined(separator: ", ")).")
        }
        let body = max(0, rows.count - 1)
        // "At least" rather than a number, when the window cut the file short. Reporting the
        // count of a prefix as the count of the file is the kind of confident wrong number that
        // sends a model down a path it cannot recover from.
        if truncated {
            lines.append("At least \(Self.grouped(body)) data rows — counted over the first \(Self.humanBytes(data.count)) of \(Self.humanBytes(size)); the file was not read to the end.")
        } else {
            lines.append("\(Self.grouped(body)) data rows.")
        }
        lines.append("Text encoding: \(encoding)\(guessed ? " — detected, not certain" : "").")
        return lines
    }

    /// Split delimited text into rows and fields, honouring RFC 4180 quoting.
    ///
    /// Splitting on the delimiter without this counts a quoted address containing a comma as two
    /// columns, and then reports a column count that is wrong for most real exports.
    static func delimitedRows(_ text: String, delimiter: Character, limit: Int = 200_000) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let c = characters[index]
            if inQuotes {
                if c == "\"" {
                    // A doubled quote inside a quoted field is one literal quote, not the end.
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\""); index += 2; continue
                    }
                    inQuotes = false; index += 1; continue
                }
                field.append(c); index += 1; continue
            }
            switch c {
            case "\"":      inQuotes = true
            case delimiter: row.append(field); field = ""
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
                if rows.count >= limit { return rows }
            case "\r":      break
            default:        field.append(c)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    func describePlainText(_ url: URL, size: Int) throws -> [String] {
        let (data, truncated) = try Self.head(of: url, bytes: Limits.inspectionWindowBytes)
        guard let (text, encoding, guessed) = Self.decodePrefix(data) else {
            return ["Could not be decoded as text in any encoding tried. Treat it as binary."]
        }
        let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let lineCount = text.hasSuffix("\n") ? newlines : newlines + 1
        var lines: [String] = []
        if truncated {
            lines.append("At least \(Self.grouped(lineCount)) lines — counted over the first \(Self.humanBytes(data.count)) of \(Self.humanBytes(size)); the file was not read to the end.")
        } else {
            lines.append("\(Self.grouped(lineCount)) lines, \(Self.grouped(text.count)) characters.")
        }
        lines.append("Text encoding: \(encoding)\(guessed ? " — detected, not certain" : "").")
        let longest = text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0
        if longest > 2_000 {
            lines.append("Longest line is \(Self.grouped(longest)) characters — this is probably minified or a single-line data blob rather than prose.")
        }
        return lines
    }
}

// MARK: - Text out

extension FileIngest {

    func extractPDF(_ url: URL, cap: Int) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw IngestError.unreadable("PDFKit could not open \(url.lastPathComponent). It is probably damaged or encrypted.")
        }
        if document.isEncrypted && document.isLocked {
            throw IngestError.denied("\(url.lastPathComponent) is password-protected and PDFKit cannot open it. The password has to be removed outside this tool.")
        }
        var out = ""
        var lastPage = 0
        // Page by page rather than `document.string`, so that when the cap bites we can say which
        // pages were read. "The first 12 of 340 pages" is actionable; "40,000 characters" is not.
        for index in 0..<document.pageCount {
            guard out.count < cap else { break }
            if let page = document.page(at: index)?.string {
                out += page
                if !page.hasSuffix("\n") { out += "\n" }
            }
            lastPage = index + 1
        }
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IngestError.unreadable("\(url.lastPathComponent) has \(document.pageCount) pages and no extractable text at all — it is a scan or an image-only export. Nothing was returned because there is nothing to return, not because the file is empty. It needs OCR or a vision-capable brain.")
        }
        if out.count > cap || lastPage < document.pageCount {
            let kept = String(out.prefix(cap))
            return kept + "\n\n[TRUNCATED: this is pages 1–\(lastPage) of \(document.pageCount) in \(url.lastPathComponent), cut at \(Self.grouped(cap)) characters. The remaining pages were not read. Do not conclude that anything is absent from this document on the basis of this excerpt.]"
        }
        return out
    }

    func extractPlainText(_ url: URL, size: Int, cap: Int) throws -> String {
        // Four bytes per character is the worst case for UTF-8 and for every encoding tried here,
        // so reading `cap * 4` bytes guarantees enough to fill the cap without ever reading a
        // 200 MB file to hand back 40,000 characters.
        let window = min(size, max(4 << 10, cap * 4))
        let (data, _) = try Self.head(of: url, bytes: window)
        guard let (text, encoding, guessed) = Self.decodePrefix(data) else {
            throw IngestError.unreadable("\(url.lastPathComponent) did not decode as text in UTF-8, in the encoding Foundation detected, or in Windows-1252. It is binary; inspect it instead.")
        }
        // `capped` is told what it is actually counting. Without this it reported the window's
        // length as the file's — "the first 100 of 4,096 characters in long.txt" for a file with
        // 10,000 characters in it — which is precisely the confident wrong number this whole
        // file exists to stop producing.
        let windowed = window < size
        var out = Self.capped(text, at: cap,
                              describing: windowed ? "the first \(Self.humanBytes(window)) of \(url.lastPathComponent)"
                                                   : url.lastPathComponent)
        if windowed {
            out += "\n\n[TRUNCATED: read the first \(Self.humanBytes(window)) of \(Self.humanBytes(size)) in \(url.lastPathComponent). The rest was not read.]"
        }
        if guessed {
            out = "[Decoded as \(encoding). Characters may be wrong if that guess is wrong.]\n" + out
        }
        return out
    }

    /// RTF, RTFD, HTML, DOC, DOCX and web archives, all through `NSAttributedString`.
    ///
    /// On the main thread, always. The HTML importer is built on WebKit and Apple documents it as
    /// main-thread-only; the Office importers have historically had the same requirement. Calling
    /// them from this actor's executor is the kind of bug that reproduces once a week on someone
    /// else's machine, so the hop is unconditional rather than per-format.
    @MainActor
    static func attributedPlainText(at url: URL, documentType: NSAttributedString.DocumentType) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        do {
            let attributed = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            let text = attributed.string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IngestError.unreadable("\(url.lastPathComponent) opened but contains no text — it is empty, or all of its content is images.")
            }
            return text
        } catch let error as IngestError {
            throw error
        } catch {
            throw IngestError.unreadable("\(url.lastPathComponent) could not be read as \(documentType.rawValue): \(error.localizedDescription). If the extension is wrong about what the file is, inspect it first.")
        }
    }
}

// MARK: - Archives

/// Why these readers are written here rather than shelled out to `/usr/bin/unzip` and `/usr/bin/tar`.
///
/// Shelling out was the obvious cheap route and it was rejected for three reasons, in order of
/// how much they matter:
///
/// 1. **`unzip` treats an entry name as a shell glob.** `unzip -p archive.zip 'notes[1].txt'`
///    does not extract the entry called `notes[1].txt`; it matches a pattern. There is no
///    "literal name" flag in Info-ZIP. So the name this tool validated and the name the
///    extractor acted on would not reliably be the same string, which is the exact gap every
///    check in this file exists to close.
/// 2. **Listing and extracting would be two separate reads of the file.** Anything that can
///    rewrite the archive between `tar -t` and `tar -x` gets the validation applied to one set
///    of names and the extraction applied to another. Reading the bytes once, into memory or a
///    memory map, and answering both questions from that one copy removes the window entirely.
/// 3. `tar -x` restores symbolic links and modes by default, so the safety of the whole
///    operation would rest on getting a list of flags right rather than on never writing a link.
///
/// What was given up: zip64, encrypted zips, and every compression method other than stored and
/// deflate. Each is refused by name in an error that says what to do instead, which is the honest
/// trade — a reader that silently mishandled them would be worse than one that says it cannot.
extension FileIngest {

    /// What the first bytes of the file say it is. Never the extension.
    enum ArchiveFormat: Equatable {
        case zip
        case tar
        /// A gzip stream. What is *inside* it is not known until it is inflated, which is why
        /// `byteSource` can hand back a different format than the one it was given.
        case gzip

        var label: String {
            switch self {
            case .zip:  return "zip"
            case .tar:  return "tar"
            case .gzip: return "gzip"
            }
        }
    }

    /// One entry, as the archive declares it. Every number here is a claim by whoever built the
    /// file, which is why `assertNotABomb` checks them against limits and `data(for:in:)` checks
    /// the bytes it actually produces against `uncompressedSize` rather than trusting it.
    struct ArchiveEntry {
        let name: String
        let isDirectory: Bool
        /// True only for a real symbolic link. `unarchive` refuses the whole archive on this.
        let isSymbolicLink: Bool
        /// Where the link points, when the archive says. Reported in the refusal so the person
        /// reading it can see what the archive was trying to do.
        let linkTarget: String?
        /// A member that is neither a regular file, a directory nor a symbolic link: a hard
        /// link, a device node, a fifo. Named rather than booleanised because the refusal quotes
        /// it, and "contains a hard link" and "contains a character device" are different facts.
        let unsupportedKind: String?
        let uncompressedSize: Int
        /// Where to find the bytes. Never a second read of the file — always an offset into the
        /// one copy `byteSource` produced.
        let location: EntryLocation

        init(name: String,
             isDirectory: Bool,
             isSymbolicLink: Bool = false,
             linkTarget: String? = nil,
             unsupportedKind: String? = nil,
             uncompressedSize: Int,
             location: EntryLocation) {
            self.name = name
            self.isDirectory = isDirectory
            self.isSymbolicLink = isSymbolicLink
            self.linkTarget = linkTarget
            self.unsupportedKind = unsupportedKind
            self.uncompressedSize = uncompressedSize
            self.location = location
        }
    }

    enum EntryLocation: Equatable {
        /// A tar member: the body is stored uncompressed at this offset in the source bytes.
        case tarBody(offset: Int)
        /// A zip member: the local header is at this offset, and the central directory said this
        /// much about it. The local header's own sizes are deliberately not trusted — they are
        /// zero whenever the writer used a data descriptor.
        case zipMember(localHeaderOffset: Int, compressedSize: Int, method: UInt16, crc32: UInt32)
        /// The whole source is the content: a bare `.gz`, which holds exactly one unnamed member.
        case wholeSource
        /// A member with no bytes: a directory, or a member the reader refuses to write.
        case none
    }

    /// The archive's bytes, read exactly once.
    struct ByteSource {
        let bytes: Data
        /// The name to give the single member of a bare `.gz`.
        ///
        /// Taken from the *file name on disk*, not from the FNAME field in the gzip header. The
        /// header field is attacker-controlled and invisible to the person who dropped the file,
        /// so `report.pdf.gz` holding an FNAME of `../../.zshrc` would extract to a name nobody
        /// asked for. It would still be caught by `safeDestination`, but a name the user can see
        /// is the better default and costs nothing.
        let memberName: String
    }

    // MARK: Sniffing

    /// Identify an archive by its first bytes.
    ///
    /// Returns nil for anything that is not one of the three containers this reads, which is how
    /// `classify` decides a file is not an archive at all.
    static func archiveFormat(of url: URL) throws -> ArchiveFormat? {
        let (head, _) = try head(of: url, bytes: 1024)
        return archiveFormat(ofBytes: head)
    }

    static func archiveFormat(ofBytes head: Data) -> ArchiveFormat? {
        if head.count >= 4, byte(head, 0) == 0x50, byte(head, 1) == 0x4B {
            // "PK\3\4" is a local header, "PK\5\6" an empty archive's end record, "PK\7\8" a
            // spanned archive. All three are zips; only the first is what a normal file starts
            // with, and refusing the other two by sniff would misreport an empty zip as garbage.
            let third = byte(head, 2)
            if third == 0x03 || third == 0x05 || third == 0x07 { return .zip }
        }
        if head.count >= 2, byte(head, 0) == 0x1F, byte(head, 1) == 0x8B { return .gzip }
        if looksLikeTar(head) { return .tar }
        return nil
    }

    /// A tar has no magic number at the front — the "ustar" marker sits 257 bytes in, and a
    /// pre-POSIX tar does not have that either. So the fallback is the header checksum, which is
    /// a strong enough test in practice: 512 arbitrary bytes agreeing with an octal sum written
    /// at offset 148 is not something a non-tar does by accident.
    static func looksLikeTar(_ data: Data) -> Bool {
        guard data.count >= 512 else { return false }
        if let magic = string(data, at: 257, length: 5), magic == "ustar" { return true }
        return tarChecksumMatches(data, at: 0)
    }

    static func tarChecksumMatches(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 512 <= data.count else { return false }
        guard let declared = octal(data, at: offset + 148, length: 8) else { return false }
        var sum = 0
        for index in 0..<512 {
            // The checksum field itself counts as eight spaces, by definition.
            sum += (index >= 148 && index < 156) ? 32 : Int(byte(data, offset + index))
        }
        return sum == declared
    }

    // MARK: Reading the bytes once

    /// Get the archive's bytes into a form the entry readers can address, and say what those
    /// bytes turned out to be.
    ///
    /// The returned format can differ from the one passed in, and that is the point: a `.tar.gz`
    /// arrives as `.gzip` and leaves as `.tar` once inflated. Deciding that by inspecting the
    /// inflated bytes rather than by looking for `.tgz` in the name means a gzipped tar with the
    /// wrong extension still extracts, and a `.tgz` that is really a gzipped JPEG does not.
    static func byteSource(for url: URL, format: ArchiveFormat) throws -> (source: ByteSource, format: ArchiveFormat) {
        switch format {
        case .zip, .tar:
            // Memory-mapped where the system thinks that is safe, so a 200 MB zip costs address
            // space rather than resident memory. The entry readers only touch headers plus the
            // one member being extracted.
            let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
            return (ByteSource(bytes: bytes, memberName: ""), format)

        case .gzip:
            let compressed = try byteCountOnDisk(url)
            guard compressed <= Limits.maximumCompressedInMemoryBytes else {
                throw IngestError.tooLarge("\(url.lastPathComponent) is \(humanBytes(compressed)) of gzip, and gzip has no random access so the whole thing has to be inflated in memory. The ceiling is \(humanBytes(Limits.maximumCompressedInMemoryBytes)). Decompress it with a shell tool and work on the result.")
            }
            let raw = try Data(contentsOf: url)
            let inflated = try gunzip(raw, limit: Limits.maximumArchiveBytes, archiveName: url.lastPathComponent)
            if looksLikeTar(inflated) {
                return (ByteSource(bytes: inflated, memberName: ""), .tar)
            }
            return (ByteSource(bytes: inflated, memberName: gzipMemberName(for: url)), .gzip)
        }
    }

    /// The name for the single member of a bare `.gz`: the file's own name with the compression
    /// extension taken off.
    static func gzipMemberName(for url: URL) -> String {
        var name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.hasSuffix(".tgz") {
            name = String(name.dropLast(4)) + ".tar"
        } else if lower.hasSuffix(".gz") {
            name = String(name.dropLast(3))
        }
        // A file literally called ".gz" leaves nothing behind, and an empty name would be
        // refused by `safeDestination` with a message about the archive rather than about this.
        return name.isEmpty ? "contents" : name
    }

    static func byteCountOnDisk(_ url: URL) throws -> Int {
        (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Listing

    static func listEntries(_ source: ByteSource, format: ArchiveFormat, archiveName: String) throws -> [ArchiveEntry] {
        switch format {
        case .tar:
            return try tarEntries(source.bytes, archiveName: archiveName)
        case .gzip:
            // A bare gzip stream holds one member and no metadata worth trusting.
            return [ArchiveEntry(name: source.memberName,
                                 isDirectory: false,
                                 uncompressedSize: source.bytes.count,
                                 location: .wholeSource)]
        case .zip:
            return try zipEntries(source.bytes, archiveName: archiveName)
        }
    }

    // MARK: Limits

    /// Refuse an archive that is a bomb, before a single byte is written.
    ///
    /// All four numbers are declared by the archive rather than measured, which is fine here
    /// because this is a ceiling test: an archive that lies *downwards* about its sizes is caught
    /// again in `data(for:in:)`, where the bytes actually produced are compared with what was
    /// declared and a mismatch is a refusal.
    static func assertNotABomb(_ entries: [ArchiveEntry], compressedBytes: Int, archiveName: String) throws {
        guard entries.count <= Limits.maximumArchiveEntries else {
            throw IngestError.tooLarge("\(archiveName) declares \(grouped(entries.count)) entries and this extractor refuses more than \(grouped(Limits.maximumArchiveEntries)). Nothing was extracted. Unpack it with a shell tool if you have decided it is safe.")
        }
        if let big = entries.first(where: { $0.uncompressedSize > Limits.maximumEntryBytes }) {
            throw IngestError.tooLarge("\(archiveName) contains an entry, \"\(big.name)\", that declares \(humanBytes(big.uncompressedSize)) — over the \(humanBytes(Limits.maximumEntryBytes)) limit for a single file. Nothing was extracted.")
        }
        let total = entries.reduce(0) { $0 + $1.uncompressedSize }
        guard total <= Limits.maximumArchiveBytes else {
            throw IngestError.tooLarge("\(archiveName) declares \(humanBytes(total)) of content, over the \(humanBytes(Limits.maximumArchiveBytes)) this extractor will write. Nothing was extracted; this machine has no snapshot to roll back to.")
        }
        if total > Limits.ratioAppliesAboveBytes, compressedBytes > 0 {
            let ratio = total / compressedBytes
            guard ratio <= Limits.maximumExpansionRatio else {
                throw IngestError.tooLarge("\(archiveName) is \(humanBytes(compressedBytes)) on disk and declares \(humanBytes(total)) of content — an expansion of about \(grouped(ratio))×, past the \(grouped(Limits.maximumExpansionRatio))× this extractor allows. That is a decompression bomb rather than a well-compressed file. Nothing was extracted.")
            }
        }
    }

    // MARK: Bytes out

    /// The bytes of one entry, taken from the copy of the archive already in hand.
    static func data(for entry: ArchiveEntry, in source: ByteSource, archiveName: String) throws -> Data {
        switch entry.location {
        case .none:
            return Data()

        case .wholeSource:
            return source.bytes

        case .tarBody(let offset):
            guard offset >= 0, offset + entry.uncompressedSize <= source.bytes.count else {
                throw IngestError.malformed("\(archiveName) says \"\(entry.name)\" is \(humanBytes(entry.uncompressedSize)) starting at byte \(grouped(offset)), which runs past the end of the file. The archive is truncated or damaged.")
            }
            let start = source.bytes.startIndex + offset
            return source.bytes.subdata(in: start..<(start + entry.uncompressedSize))

        case .zipMember(let headerOffset, let compressedSize, let method, let crc):
            return try zipMemberData(source.bytes,
                                     entry: entry,
                                     localHeaderOffset: headerOffset,
                                     compressedSize: compressedSize,
                                     method: method,
                                     declaredCRC: crc,
                                     archiveName: archiveName)
        }
    }

    // MARK: Little-endian and octal readers

    /// Every read here is bounds-checked against the slice it was given, because every offset in
    /// an archive is a number an attacker chose.
    static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        guard offset >= 0, offset < data.count else { return 0 }
        return data[data.startIndex + offset]
    }

    static func u16(_ data: Data, _ offset: Int) -> Int {
        Int(byte(data, offset)) | (Int(byte(data, offset + 1)) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(byte(data, offset))
            | (UInt32(byte(data, offset + 1)) << 8)
            | (UInt32(byte(data, offset + 2)) << 16)
            | (UInt32(byte(data, offset + 3)) << 24)
    }

    /// A NUL-padded fixed-width string field, as tar stores names.
    static func string(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= data.count else { return nil }
        let start = data.startIndex + offset
        var slice = data.subdata(in: start..<(start + length))
        if let terminator = slice.firstIndex(of: 0) { slice = slice.prefix(upTo: terminator) }
        // Tar fields are bytes, not necessarily UTF-8. Falling back to Latin-1 (which cannot
        // fail) keeps a file with a mis-encoded name visible in the listing instead of making
        // the whole archive unreadable; the name is validated by shape either way.
        return String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1)
    }

    /// Tar numbers are NUL- or space-terminated octal.
    ///
    /// GNU's base-256 extension (high bit set in the first byte) is used only for values past
    /// 8 GB, which every limit in this file refuses long before. It returns nil rather than being
    /// parsed, and the caller turns that into a sentence.
    static func octal(_ data: Data, at offset: Int, length: Int) -> Int? {
        guard offset >= 0, offset + length <= data.count else { return nil }
        if byte(data, offset) & 0x80 != 0 { return nil }
        var value = 0
        var sawDigit = false
        for index in 0..<length {
            let c = byte(data, offset + index)
            if c == 0 || c == 0x20 { if sawDigit { break } else { continue } }
            guard c >= 0x30, c <= 0x37 else { return nil }
            value = value * 8 + Int(c - 0x30)
            sawDigit = true
        }
        return sawDigit ? value : 0
    }
}

// MARK: - tar

extension FileIngest {

    /// Walk a tar's 512-byte headers.
    ///
    /// Handles ustar (prefix + name), GNU long names (`L`/`K` members whose body is the next
    /// member's name) and PAX (`x` members carrying `path=`/`linkpath=`/`size=`). Those three
    /// cover everything BSD tar, GNU tar and macOS Archive Utility produce; anything else is
    /// refused by name rather than guessed at.
    static func tarEntries(_ bytes: Data, archiveName: String) throws -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var offset = 0
        var longName: String?
        var longLink: String?
        var pax: [String: String] = [:]

        while offset + 512 <= bytes.count {
            if isZeroBlock(bytes, at: offset) { break }   // Two of these end the archive; one is enough to stop.
            guard tarChecksumMatches(bytes, at: offset) else {
                throw IngestError.malformed("\(archiveName) has a damaged tar header \(grouped(offset)) bytes in — its checksum does not match. Nothing was extracted.")
            }
            guard let declaredSize = octal(bytes, at: offset + 124, length: 12) else {
                throw IngestError.malformed("\(archiveName) declares an entry size this reader cannot parse — it uses tar's base-256 extension, which only appears for files over 8 GB. Nothing was extracted.")
            }
            let typeFlag = byte(bytes, offset + 156)
            let bodyOffset = offset + 512
            let padded = ((declaredSize + 511) / 512) * 512
            guard declaredSize >= 0, bodyOffset + declaredSize <= bytes.count else {
                throw IngestError.malformed("\(archiveName) is truncated: an entry claims \(humanBytes(declaredSize)) of content that is not in the file. Nothing was extracted.")
            }

            // The three carrier types hold metadata for the *next* real member, not content.
            switch typeFlag {
            case UInt8(ascii: "L"):
                longName = string(bytes, at: bodyOffset, length: declaredSize)
                offset = bodyOffset + padded
                continue
            case UInt8(ascii: "K"):
                longLink = string(bytes, at: bodyOffset, length: declaredSize)
                offset = bodyOffset + padded
                continue
            case UInt8(ascii: "x"), UInt8(ascii: "X"):
                pax = paxRecords(bytes, at: bodyOffset, length: declaredSize)
                offset = bodyOffset + padded
                continue
            case UInt8(ascii: "g"):
                // A global extended header applies to the rest of the archive and carries nothing
                // this reader uses. Skipped rather than merged, so it cannot rename anything.
                offset = bodyOffset + padded
                continue
            default:
                break
            }

            let rawName = longName ?? pax["path"] ?? ustarName(bytes, at: offset)
            let linkName = longLink ?? pax["linkpath"] ?? string(bytes, at: offset + 157, length: 100)
            // A PAX `size` record overrides the header field, which is how tar stores a member
            // larger than the octal field can hold.
            let size = pax["size"].flatMap(Int.init) ?? declaredSize
            guard bodyOffset + size <= bytes.count else {
                throw IngestError.malformed("\(archiveName) is truncated: \"\(rawName)\" claims \(humanBytes(size)) of content that is not in the file. Nothing was extracted.")
            }
            longName = nil
            longLink = nil
            pax = [:]

            let name = rawName.isEmpty ? "" : rawName
            switch typeFlag {
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                // '7' is a contiguous file, which on every filesystem this runs on is a regular
                // file with a different name in the spec.
                entries.append(ArchiveEntry(name: name,
                                            isDirectory: name.hasSuffix("/"),
                                            uncompressedSize: name.hasSuffix("/") ? 0 : size,
                                            location: name.hasSuffix("/") ? .none : .tarBody(offset: bodyOffset)))
            case UInt8(ascii: "5"):
                entries.append(ArchiveEntry(name: name, isDirectory: true, uncompressedSize: 0, location: .none))
            case UInt8(ascii: "2"):
                entries.append(ArchiveEntry(name: name,
                                            isDirectory: false,
                                            isSymbolicLink: true,
                                            linkTarget: linkName,
                                            uncompressedSize: 0,
                                            location: .none))
            case UInt8(ascii: "1"):
                entries.append(ArchiveEntry(name: name,
                                            isDirectory: false,
                                            linkTarget: linkName,
                                            unsupportedKind: "hard link",
                                            uncompressedSize: 0,
                                            location: .none))
            default:
                let kind: String
                switch typeFlag {
                case UInt8(ascii: "3"): kind = "character device"
                case UInt8(ascii: "4"): kind = "block device"
                case UInt8(ascii: "6"): kind = "fifo"
                default:                kind = "an entry of unsupported type '\(Character(UnicodeScalar(typeFlag)))'"
                }
                entries.append(ArchiveEntry(name: name,
                                            isDirectory: false,
                                            unsupportedKind: kind,
                                            uncompressedSize: 0,
                                            location: .none))
            }
            offset = bodyOffset + ((size + 511) / 512) * 512
        }
        return entries
    }

    static func isZeroBlock(_ data: Data, at offset: Int) -> Bool {
        guard offset + 512 <= data.count else { return false }
        for index in 0..<512 where byte(data, offset + index) != 0 { return false }
        return true
    }

    /// ustar splits a long name across `prefix` (155 bytes at 345) and `name` (100 bytes at 0).
    static func ustarName(_ bytes: Data, at offset: Int) -> String {
        let name = string(bytes, at: offset, length: 100) ?? ""
        guard let magic = string(bytes, at: offset + 257, length: 5), magic == "ustar",
              let prefix = string(bytes, at: offset + 345, length: 155), !prefix.isEmpty else {
            return name
        }
        return prefix + "/" + name
    }

    /// PAX records are `"%d %s=%s\n"`, where the leading number is the length of the whole record
    /// including itself. Parsed by that length rather than by splitting on newlines, because a
    /// value is allowed to contain one.
    static func paxRecords(_ bytes: Data, at offset: Int, length: Int) -> [String: String] {
        var records: [String: String] = [:]
        var cursor = 0
        while cursor < length {
            var digits = ""
            var scan = cursor
            while scan < length, byte(bytes, offset + scan) != UInt8(ascii: " ") {
                digits.append(Character(UnicodeScalar(byte(bytes, offset + scan))))
                scan += 1
                if digits.count > 10 { return records }
            }
            guard let recordLength = Int(digits), recordLength > 0, cursor + recordLength <= length else { return records }
            let payloadStart = scan + 1
            let payloadLength = cursor + recordLength - payloadStart - 1   // drop the trailing newline
            guard payloadLength > 0,
                  let payload = string(bytes, at: offset + payloadStart, length: payloadLength) else { return records }
            if let equals = payload.firstIndex(of: "=") {
                records[String(payload[payload.startIndex..<equals])] = String(payload[payload.index(after: equals)...])
            }
            cursor += recordLength
        }
        return records
    }
}

// MARK: - gzip and raw DEFLATE

extension FileIngest {

    /// Inflate a gzip stream, including the concatenated-member form `cat a.gz b.gz` produces.
    ///
    /// The gzip container itself is parsed here because Apple's Compression framework does not
    /// implement it — `COMPRESSION_ZLIB` is raw DEFLATE per RFC 1951, with no header and no
    /// trailer. The header is eleven lines of well-specified field skipping, which is a better
    /// trade than shelling out to `/usr/bin/gzip` and losing the output cap that makes a gzip
    /// bomb a refusal instead of a full disk.
    static func gunzip(_ input: Data, limit: Int, archiveName: String) throws -> Data {
        guard input.count >= 18 else {
            throw IngestError.malformed("\(archiveName) is only \(input.count) bytes, which is too short to be a gzip file. It is truncated.")
        }
        var out = Data()
        var offset = 0

        while offset + 18 <= input.count {
            guard byte(input, offset) == 0x1F, byte(input, offset + 1) == 0x8B else { break }
            guard byte(input, offset + 2) == 8 else {
                throw IngestError.malformed("\(archiveName) is gzip but uses compression method \(byte(input, offset + 2)); only DEFLATE (method 8) exists in practice, so this file is damaged.")
            }
            let flags = byte(input, offset + 3)
            var cursor = offset + 10
            if flags & 0x04 != 0 { cursor += 2 + u16(input, cursor) }          // FEXTRA
            if flags & 0x08 != 0 { cursor = afterCString(input, from: cursor) } // FNAME
            if flags & 0x10 != 0 { cursor = afterCString(input, from: cursor) } // FCOMMENT
            if flags & 0x02 != 0 { cursor += 2 }                                // FHCRC
            guard cursor < input.count else {
                throw IngestError.malformed("\(archiveName) has a gzip header that runs past the end of the file. It is truncated.")
            }

            let (chunk, consumed) = try inflateRaw(input,
                                                   from: cursor,
                                                   limit: limit - out.count,
                                                   describing: archiveName)
            out.append(chunk)
            // The 8-byte trailer is CRC32 then the uncompressed size modulo 2^32. Neither is
            // checked: the size field is only 32 bits so it is meaningless for the sizes this
            // refuses anyway, and the inflater already fails on a corrupt stream.
            cursor += consumed + 8
            offset = cursor
        }
        guard !out.isEmpty || input.count <= 20 else {
            throw IngestError.malformed("\(archiveName) starts with the gzip marker but no member inflated. It is damaged.")
        }
        return out
    }

    static func afterCString(_ data: Data, from offset: Int) -> Int {
        var cursor = offset
        while cursor < data.count, byte(data, cursor) != 0 { cursor += 1 }
        return cursor + 1
    }

    /// Raw DEFLATE, with a hard ceiling on the output.
    ///
    /// The cap is the whole reason this is streamed rather than handed to a one-shot API: a
    /// 40 KB gzip that expands to 10 GB is four lines of Python to make, and the only defence
    /// that works is to stop inflating rather than to check the size afterwards.
    ///
    /// - Returns: the inflated bytes and how many input bytes the stream consumed, which is how
    ///   the gzip reader finds the trailer and any member after it.
    static func inflateRaw(_ input: Data, from start: Int, limit: Int, describing archiveName: String) throws -> (output: Data, consumed: Int) {
        guard start < input.count else { return (Data(), 0) }
        guard limit > 0 else {
            throw IngestError.tooLarge("\(archiveName) inflates to more than \(humanBytes(Limits.maximumArchiveBytes)), which is where this reader stops. Nothing was extracted.")
        }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw IngestError.unreadable("The system's decompressor would not start, so \(archiveName) could not be inflated.")
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        var consumed = 0
        var failure: IngestError?

        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base + start
            stream.src_size = input.count - start

            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                // FINALIZE because the entire input is present in one buffer. Without it, the
                // call returns OK with nothing consumed once the source runs out and the loop
                // never ends.
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
                if output.count > limit {
                    failure = .tooLarge("\(archiveName) inflates past \(humanBytes(limit)) and was stopped there. A file that expands this far is a decompression bomb; nothing was extracted.")
                    return
                }
                if status == COMPRESSION_STATUS_ERROR {
                    failure = .malformed("\(archiveName) is not a valid DEFLATE stream — the decompressor rejected it \(grouped(consumedSoFar(stream, input, start))) bytes in. The file is damaged or truncated.")
                    return
                }
            } while status == COMPRESSION_STATUS_OK
            consumed = (input.count - start) - stream.src_size
        }
        if let failure { throw failure }
        return (output, consumed)
    }

    private static func consumedSoFar(_ stream: compression_stream, _ input: Data, _ start: Int) -> Int {
        (input.count - start) - stream.src_size
    }
}

// MARK: - zip

extension FileIngest {

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    /// Read a zip's central directory.
    ///
    /// The central directory at the end of the file is the authority, not the local headers: a
    /// local header's sizes are zero whenever the writer streamed the file and put the real
    /// numbers in a trailing data descriptor, and an archive can carry a local header for a
    /// member the directory does not list. Reading the directory means the list this validates is
    /// the list an ordinary unzip would act on.
    static func zipEntries(_ bytes: Data, archiveName: String) throws -> [ArchiveEntry] {
        guard bytes.count >= 22 else {
            throw IngestError.malformed("\(archiveName) is \(bytes.count) bytes, too short to be a zip. It is truncated.")
        }
        // The end record is last, except for an optional comment of up to 65,535 bytes, so it is
        // found by scanning backwards rather than by seeking to a fixed place.
        let floor = max(0, bytes.count - (22 + 65_535))
        var end = -1
        var scan = bytes.count - 22
        while scan >= floor {
            if u32(bytes, scan) == endOfCentralDirectorySignature { end = scan; break }
            scan -= 1
        }
        guard end >= 0 else {
            throw IngestError.malformed("\(archiveName) has no zip end-of-central-directory record. It is truncated, or it is a multi-part archive whose other parts are missing.")
        }

        let declaredCount = u16(bytes, end + 10)
        let directorySize = u32(bytes, end + 12)
        let directoryOffset = u32(bytes, end + 16)
        // 0xFFFF and 0xFFFFFFFF are the sentinels that say "the real value is in the zip64
        // record". Zip64 is not implemented here — every archive it exists for is past the size
        // this extractor writes anyway — so it is refused by name rather than misread.
        guard declaredCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw IngestError.wrongKind("\(archiveName) uses the zip64 extension, which this reader does not implement. Every zip64 archive is larger than this extractor would write anyway. Unpack it with `ditto -x -k` in a shell tool if you have decided it is safe.")
        }
        guard Int(directoryOffset) + Int(directorySize) <= bytes.count else {
            throw IngestError.malformed("\(archiveName) says its index of \(grouped(Int(directorySize))) bytes starts \(grouped(Int(directoryOffset))) bytes in, which runs past the end of the file. It is truncated or damaged.")
        }

        var entries: [ArchiveEntry] = []
        var cursor = Int(directoryOffset)
        for index in 0..<declaredCount {
            guard cursor + 46 <= bytes.count, u32(bytes, cursor) == centralDirectorySignature else {
                throw IngestError.malformed("\(archiveName) has a damaged index: entry \(index + 1) of \(declaredCount) does not start where the file says it does. Nothing was extracted.")
            }
            let versionMadeBy = u16(bytes, cursor + 4)
            let flags = u16(bytes, cursor + 8)
            let method = UInt16(u16(bytes, cursor + 10))
            let crc = u32(bytes, cursor + 16)
            let compressedSize = Int(u32(bytes, cursor + 20))
            let uncompressedSize = Int(u32(bytes, cursor + 24))
            let nameLength = u16(bytes, cursor + 28)
            let extraLength = u16(bytes, cursor + 30)
            let commentLength = u16(bytes, cursor + 32)
            let externalAttributes = u32(bytes, cursor + 38)
            let localHeaderOffset = Int(u32(bytes, cursor + 42))
            guard let name = string(bytes, at: cursor + 46, length: nameLength) else {
                throw IngestError.malformed("\(archiveName) has an entry name that runs past the end of the file. It is truncated.")
            }

            // Bit 0 of the general-purpose flags is the encryption bit. An encrypted member
            // cannot be read here and would otherwise be written out as ciphertext under a
            // plausible name, which is worse than a refusal.
            guard flags & 0x0001 == 0 else {
                throw IngestError.wrongKind("\(archiveName) is encrypted — \"\(name)\" needs a password this tool cannot ask for. Nothing was extracted. Decrypt it outside this tool first.")
            }
            guard method == 0 || method == 8 else {
                throw IngestError.wrongKind("\(archiveName) stores \"\(name)\" with compression method \(method); this reader implements only stored (0) and deflate (8), which is everything ordinary zip tools produce. Nothing was extracted. Unpack it with a shell tool if you have decided it is safe.")
            }

            // The MS-DOS directory bit, or the trailing slash every zip writer also sets.
            let isDirectory = name.hasSuffix("/") || (externalAttributes & 0x10) != 0
            // Unix mode lives in the high 16 bits of the external attributes, and only when the
            // "version made by" host byte says Unix (3). S_IFLNK is 0xA000.
            let unixMode = (externalAttributes >> 16) & 0xFFFF
            let madeOnUnix = (versionMadeBy >> 8) == 3
            let isSymbolicLink = madeOnUnix && (unixMode & 0xF000) == 0xA000

            var linkTarget: String?
            if isSymbolicLink, uncompressedSize > 0, uncompressedSize <= 4_096 {
                // A zip symlink stores its target as the member's content. Read here, bounded,
                // so the refusal can say where the link pointed instead of "?" — which is the
                // difference between a person understanding the refusal and ignoring it.
                if let target = try? zipBytes(bytes,
                                              name: name,
                                              localHeaderOffset: localHeaderOffset,
                                              compressedSize: compressedSize,
                                              uncompressedSize: uncompressedSize,
                                              method: method,
                                              declaredCRC: crc,
                                              archiveName: archiveName) {
                    linkTarget = String(data: target, encoding: .utf8)
                }
            }

            entries.append(ArchiveEntry(
                name: name,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink,
                linkTarget: linkTarget,
                uncompressedSize: (isDirectory || isSymbolicLink) ? 0 : uncompressedSize,
                location: (isDirectory || isSymbolicLink)
                    ? .none
                    : .zipMember(localHeaderOffset: localHeaderOffset,
                                 compressedSize: compressedSize,
                                 method: method,
                                 crc32: crc)))

            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func zipMemberData(_ bytes: Data,
                              entry: ArchiveEntry,
                              localHeaderOffset: Int,
                              compressedSize: Int,
                              method: UInt16,
                              declaredCRC: UInt32,
                              archiveName: String) throws -> Data {
        try zipBytes(bytes,
                     name: entry.name,
                     localHeaderOffset: localHeaderOffset,
                     compressedSize: compressedSize,
                     uncompressedSize: entry.uncompressedSize,
                     method: method,
                     declaredCRC: declaredCRC,
                     archiveName: archiveName)
    }

    /// One member's bytes, checked against what the directory declared.
    ///
    /// Both checks matter and neither is cosmetic. The size check is a security check: every
    /// limit in `assertNotABomb` is applied to declared sizes, so a member that inflates to more
    /// than it declared would walk straight past all of them. The CRC check is an honesty check —
    /// it is how "the archive is damaged" becomes a fact rather than a guess.
    static func zipBytes(_ bytes: Data,
                         name: String,
                         localHeaderOffset: Int,
                         compressedSize: Int,
                         uncompressedSize: Int,
                         method: UInt16,
                         declaredCRC: UInt32,
                         archiveName: String) throws -> Data {
        guard localHeaderOffset >= 0, localHeaderOffset + 30 <= bytes.count,
              u32(bytes, localHeaderOffset) == localHeaderSignature else {
            throw IngestError.malformed("\(archiveName) says \"\(name)\" starts \(grouped(localHeaderOffset)) bytes in, and there is no zip member header there. The archive is damaged.")
        }
        // The local header's name and extra lengths are read from the local header even though
        // the sizes are not: they are how the body's offset is found, and they are allowed to
        // differ from the central directory's copies.
        let nameLength = u16(bytes, localHeaderOffset + 26)
        let extraLength = u16(bytes, localHeaderOffset + 28)
        let bodyOffset = localHeaderOffset + 30 + nameLength + extraLength
        guard compressedSize >= 0, bodyOffset >= 0, bodyOffset + compressedSize <= bytes.count else {
            throw IngestError.malformed("\(archiveName) says \"\(name)\" is \(humanBytes(compressedSize)) of data that runs past the end of the file. The archive is truncated.")
        }

        let start = bytes.startIndex + bodyOffset
        let body = bytes.subdata(in: start..<(start + compressedSize))
        let output: Data
        if method == 0 {
            output = body
        } else {
            // Cap the inflation at the declared size plus nothing. A member that produces more
            // than it declared has defeated the bomb check, so the inflater is told to stop
            // exactly there and the size comparison below turns that into a refusal.
            let (inflated, _) = try inflateRaw(body, from: 0, limit: max(1, uncompressedSize), describing: archiveName)
            output = inflated
        }
        guard output.count == uncompressedSize else {
            throw IngestError.malformed("\(archiveName) declares \"\(name)\" as \(grouped(uncompressedSize)) bytes and it unpacked to \(grouped(output.count)). The archive is damaged, or it is lying about its sizes to get past the extraction limits. Nothing further was extracted.")
        }
        guard crc32(output) == declaredCRC else {
            throw IngestError.malformed("\(archiveName) failed its own checksum on \"\(name)\" — the stored bytes do not match what the archive says they should be. The file is damaged in transit or on disk.")
        }
        return output
    }

    /// The standard CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) that zip stores.
    ///
    /// Written out rather than reached for in a framework because there isn't one: CryptoKit has
    /// SHA and MD5 but no CRC, and zlib's `crc32` is not exposed to Swift without a module map.
    /// Sixteen lines is cheaper than either.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()
}
