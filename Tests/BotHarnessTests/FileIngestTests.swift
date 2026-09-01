import XCTest
import PDFKit
import CoreText
import AppKit
@testable import BotHarnessCore

/// The tests that matter here are the ones that build a real hostile archive and then look at the
/// disk. An extractor that refuses with a good sentence and has already written the file is worse
/// than one that never refuses, because it reads as safe — so every refusal case below asserts
/// what is on the filesystem afterwards, not what the error said.
final class FileIngestTests: XCTestCase {

    /// Everything the bot may read. `work` inside it is everything it may write, which leaves a
    /// readable-but-not-writable area to test the destination boundary against.
    private var root: URL!
    private var work: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bh-ingest-\(UUID().uuidString)")
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func ingest() -> FileIngest {
        FileIngest(authority: Authority(readable: [root.path], writable: [work.path]))
    }

    // MARK: - The two properties the whole tool exists for

    func testAZipSlipEntryLeavesTheDestinationAndItsNeighbourUntouched() async throws {
        // The benign entry comes first on purpose. An extractor that writes as it goes and checks
        // as it goes would have already written `harmless.txt` by the time it reached the escape,
        // so asserting the destination is *empty* — not merely that the escape failed — is what
        // distinguishes "plans then writes" from "writes then refuses".
        let archive = root.appendingPathComponent("slip.zip")
        try StoredZip.build([
            .init(name: "harmless.txt", data: Data("nothing wrong with me\n".utf8)),
            .init(name: "../escaped.txt", data: Data("I am outside\n".utf8)),
        ]).write(to: archive)

        let destination = work.appendingPathComponent("dest")
        let escaped = work.appendingPathComponent("escaped.txt")

        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "zip-slip")

        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path),
                       "the ../ entry was written outside the destination — this is the bug the tool exists to prevent")
        XCTAssertEqual(try contents(of: destination), [],
                       "the destination must be untouched: the benign entry preceding the escape was written anyway")
    }

    func testASymbolicLinkInARealTarGzIsRefusedAndNothingIsWritten() async throws {
        // Built by /usr/bin/tar rather than by hand, so this is the byte layout a real archive
        // has and not this test's idea of one.
        let source = root.appendingPathComponent("linky")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("docs").path,
                                                   withDestinationPath: NSHomeDirectory() + "/.ssh")
        try Data("payload\n".utf8).write(to: source.appendingPathComponent("after.txt"))
        let archive = root.appendingPathComponent("linky.tgz")
        try run("/usr/bin/tar", ["-czf", archive.path, "docs", "after.txt"], in: source)

        let destination = work.appendingPathComponent("dest")
        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "symbolic link")

        XCTAssertEqual(try contents(of: destination), [],
                       "a symbolic link is refused before anything is written, including the ordinary file after it")
    }

    // MARK: - Bombs

    func testAnEntryThatDeclaresMoreThanTheLimitIsRefusedBeforeAnyBytesAreRead() async throws {
        // Ten bytes on disk, 100 MB claimed. The claim is what every limit is checked against,
        // so this is the cheap way to be a bomb and it has to be refused on the claim alone.
        let archive = root.appendingPathComponent("bomb.zip")
        try StoredZip.build([
            .init(name: "huge.bin", data: Data("tiny bytes".utf8), declaredUncompressedSize: 100 << 20),
        ]).write(to: archive)

        let destination = work.appendingPathComponent("dest")
        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "huge.bin")
        XCTAssertEqual(try contents(of: destination), [])
    }

    func testAnArchiveWithMoreEntriesThanTheLimitIsRefused() async throws {
        let count = FileIngest.Limits.maximumArchiveEntries + 1
        let archive = root.appendingPathComponent("many.zip")
        try StoredZip.build((0..<count).map { .init(name: "f\($0).txt", data: Data("x".utf8)) })
            .write(to: archive)

        let destination = work.appendingPathComponent("dest")
        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "entries")
        XCTAssertEqual(try contents(of: destination), [])
    }

    func testAMemberThatFailsItsOwnChecksumIsReportedAsDamagedRatherThanWritten() async throws {
        let archive = root.appendingPathComponent("damaged.zip")
        try StoredZip.build([
            .init(name: "notes.txt", data: Data("the bytes are fine".utf8), declaredCRC: 0xDEAD_BEEF),
        ]).write(to: archive)

        let destination = work.appendingPathComponent("dest")
        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "checksum")
        XCTAssertEqual(try contents(of: destination), [])
    }

    // MARK: - The boundary

    func testExtractionIntoAPathOutsideTheWritableListIsRefusedAndTheDirectoryIsNotEvenCreated() async throws {
        let archive = root.appendingPathComponent("ok.zip")
        try StoredZip.build([.init(name: "a.txt", data: Data("hello\n".utf8))]).write(to: archive)

        // Readable, so the bot can see it; not writable, so it may not extract into it.
        let destination = root.appendingPathComponent("not-the-workspace")
        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "outside every path this bot may write to")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a refused destination must not be created on the way to being refused")
    }

    func testExtractingOverADirectoryThatAlreadyHasWorkInItIsRefused() async throws {
        let archive = root.appendingPathComponent("ok.zip")
        try StoredZip.build([.init(name: "a.txt", data: Data("hello\n".utf8))]).write(to: archive)
        let destination = work.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("mine\n".utf8).write(to: destination.appendingPathComponent("existing.txt"))

        await expectRefusal({ try await self.ingest().unarchive(archive.path, to: destination.path) },
                            containing: "new or empty directory")
        XCTAssertEqual(try contents(of: destination), ["existing.txt"])
    }

    // MARK: - Archives that are fine

    func testARealDeflatedZipExtractsWithByteIdenticalContents() async throws {
        let source = try makeTree()
        let archive = root.appendingPathComponent("real.zip")
        try run("/usr/bin/zip", ["-q", "-r", archive.path, "a.txt", "sub"], in: source)

        let destination = work.appendingPathComponent("dest")
        let report = try await ingest().unarchive(archive.path, to: destination.path)
        XCTAssertTrue(report.contains("Extracted 2 files"), report)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")),
                       try Data(contentsOf: source.appendingPathComponent("a.txt")))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("sub/b.txt")),
                       try Data(contentsOf: source.appendingPathComponent("sub/b.txt")))
    }

    func testARealTarGzExtractsWithByteIdenticalContents() async throws {
        let source = try makeTree()
        let archive = root.appendingPathComponent("real.tgz")
        try run("/usr/bin/tar", ["-czf", archive.path, "a.txt", "sub"], in: source)

        let destination = work.appendingPathComponent("dest")
        _ = try await ingest().unarchive(archive.path, to: destination.path)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")),
                       try Data(contentsOf: source.appendingPathComponent("a.txt")))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("sub/b.txt")),
                       try Data(contentsOf: source.appendingPathComponent("sub/b.txt")))
    }

    func testABareGzipExtractsToOneFileNamedAfterTheArchive() async throws {
        let source = try makeTree()
        try run("/usr/bin/gzip", ["-k", "a.txt"], in: source)
        let archive = source.appendingPathComponent("a.txt.gz")

        let destination = work.appendingPathComponent("dest")
        _ = try await ingest().unarchive(archive.path, to: destination.path)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.txt")),
                       try Data(contentsOf: source.appendingPathComponent("a.txt")),
                       "a bare .gz holds one member and takes its name from the file, not from the gzip header")
    }

    // MARK: - Knowing what a file is

    func testTheFormatComesFromTheBytesAndNotTheExtension() throws {
        let liar = root.appendingPathComponent("notes.txt")
        try StoredZip.build([.init(name: "a.txt", data: Data("x".utf8))]).write(to: liar)
        XCTAssertEqual(try FileIngest.archiveFormat(of: liar), .zip,
                       "a zip named .txt is still a zip")

        let honest = root.appendingPathComponent("archive.zip")
        try Data("I am only a sentence.\n".utf8).write(to: honest)
        XCTAssertNil(try FileIngest.archiveFormat(of: honest),
                     "an extension is a claim; prose named .zip is not an archive")
    }

    func testInspectOnAZipSaysWhatWillHappenBeforeItHappens() async throws {
        let archive = root.appendingPathComponent("slip.zip")
        try StoredZip.build([.init(name: "../escaped.txt", data: Data("out\n".utf8))]).write(to: archive)
        let text = try await ingest().inspect(archive.path)
        XCTAssertTrue(text.contains("REFUSAL AHEAD"), text)
        XCTAssertTrue(text.contains("../escaped.txt"), text)
    }

    func testTheStandardCrcCheckValue() {
        // 0xCBF43926 is the published check value of CRC-32/ISO-HDLC for "123456789". Pinned
        // separately because this test file uses FileIngest's own CRC to build fixtures, and a
        // wrong implementation would otherwise agree with itself.
        XCTAssertEqual(FileIngest.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Reading documents

    func testInspectAndExtractTextOnARealPdf() async throws {
        let pdf = root.appendingPathComponent("note.pdf")
        try makePDF(at: pdf, saying: "Sedimentary layers of the Kutch basin")

        let described = try await ingest().inspect(pdf.path)
        XCTAssertTrue(described.contains("1 page"), described)
        XCTAssertTrue(described.contains("text layer"), described)

        let text = try await ingest().extractText(pdf.path)
        XCTAssertTrue(text.contains("Sedimentary"), "extracted: \(text)")
        XCTAssertTrue(text.contains("Kutch"), "extracted: \(text)")
    }

    func testInspectOnACsvCountsColumnsThroughAQuotedComma() async throws {
        let csv = root.appendingPathComponent("orders.csv")
        try Data("name,address,total\n\"Rao, Meena\",\"12 Hill Rd\",4200\nSingh,Jaipur,900\n".utf8)
            .write(to: csv)

        let described = try await ingest().inspect(csv.path)
        XCTAssertTrue(described.contains("3 columns"),
                      "a comma inside a quoted field must not become a fourth column: \(described)")
        XCTAssertTrue(described.contains("2 data rows"), described)
    }

    func testAUtf16FileIsDecodedRatherThanCalledBinary() async throws {
        let file = root.appendingPathComponent("exported.txt")
        let original = "Zoë — naïve café\nsecond line\n"
        try XCTUnwrap(original.data(using: .utf16)).write(to: file)

        let text = try await ingest().extractText(file.path)
        XCTAssertTrue(text.contains("naïve café"),
                      "a UTF-16 export must come back as its own characters, not as mojibake: \(text)")

        let described = try await ingest().inspect(file.path)
        XCTAssertTrue(described.contains("Text encoding:"), described)
        XCTAssertTrue(described.contains("2 lines"), described)
    }

    func testTruncationIsAlwaysStatedInTheText() async throws {
        let file = root.appendingPathComponent("short.txt")
        try Data(String(repeating: "abcdefghij", count: 100).utf8).write(to: file)

        let text = try await ingest().extractText(file.path, maxCharacters: 100)
        XCTAssertTrue(text.contains("[TRUNCATED"),
                      "silently truncated evidence is how a model concludes something is absent")
        XCTAssertTrue(text.contains("1,000"), "the notice must name the whole file's size: \(text)")
    }

    func testAWindowedReadNeverReportsTheWindowsSizeAsTheFiles() async throws {
        // 10,000 characters, but `extractPlainText` only reads a window of four bytes per capped
        // character. The count in the truncation notice describes the window, and saying "4,096
        // characters in long.txt" about a file with 10,000 in it is the exact class of confident
        // wrong number that sends a model looking for something it was never shown.
        let file = root.appendingPathComponent("long.txt")
        try Data(String(repeating: "abcdefghij", count: 1_000).utf8).write(to: file)

        let text = try await ingest().extractText(file.path, maxCharacters: 100)
        XCTAssertTrue(text.contains("[TRUNCATED"), text)
        XCTAssertTrue(text.contains("long.txt"), text)
        XCTAssertFalse(text.contains("characters in long.txt"),
                       "a windowed count must not be presented as the file's own: \(text)")
    }

    func testPreviewOnADirectoryDescribesItRatherThanFailing() async throws {
        let source = try makeTree()
        let text = try await ingest().preview(source.path)
        XCTAssertTrue(text.contains("a directory containing"), text)
        XCTAssertTrue(text.contains("a.txt"), text)
    }

    func testExtractTextOnAnArchiveSaysToUnarchiveItFirst() async throws {
        let archive = root.appendingPathComponent("real.zip")
        try StoredZip.build([.init(name: "a.txt", data: Data("x".utf8))]).write(to: archive)
        await expectRefusal({ try await self.ingest().extractText(archive.path) },
                            containing: "Unarchive it")
    }

    // MARK: - Fixtures

    /// A source tree with a file big enough that zip and gzip actually deflate it.
    private func makeTree() throws -> URL {
        let source = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try Data(String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 60).utf8)
            .write(to: source.appendingPathComponent("a.txt"))
        try Data("nested\n".utf8).write(to: source.appendingPathComponent("sub/b.txt"))
        return source
    }

    /// A one-page PDF with a real text layer, drawn with CoreText so that PDFKit can read the
    /// characters back. A PDF made from an image would prove nothing about text extraction.
    private func makePDF(at url: URL, saying line: String) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw XCTSkip("CoreGraphics would not open a PDF context")
        }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: line,
                                            attributes: [.font: NSFont.systemFont(ofSize: 24)])
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
    }

    private func contents(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != ".DS_Store" }
            .sorted()
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "FileIngestTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")) failed: \(text)",
            ])
        }
        return text
    }

    private func expectRefusal<T>(_ work: () async throws -> T,
                                  containing needle: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("expected a refusal mentioning \"\(needle)\"; the call succeeded", file: file, line: line)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.lowercased().contains(needle.lowercased()),
                          "the refusal did not mention \"\(needle)\". It said: \(text)",
                          file: file, line: line)
        }
    }
}

// MARK: - A zip written by hand

/// Stored-only zip writer, used to build the archives no ordinary tool will make.
///
/// `/usr/bin/zip` strips `../` from entry names and refuses to write the sizes a bomb declares,
/// which is exactly why the hostile fixtures cannot come from it. The well-formed fixtures do
/// come from the real tools, so the reader is tested against both.
private enum StoredZip {

    struct Item {
        var name: String
        var data: Data = Data()
        /// 0x0014 is "made by MS-DOS"; 0x031E is "made by Unix", which is what makes the mode
        /// bits in `externalAttributes` meaningful.
        var versionMadeBy: Int = 0x0014
        var externalAttributes: UInt32 = 0
        /// A lie about the size, for the bomb cases.
        var declaredUncompressedSize: Int? = nil
        /// A lie about the checksum, for the damage case.
        var declaredCRC: UInt32? = nil
    }

    static func build(_ items: [Item]) -> Data {
        var payload = Data()
        var directory = Data()

        for item in items {
            let name = Data(item.name.utf8)
            let crc = item.declaredCRC ?? FileIngest.crc32(item.data)
            let declared = UInt32(item.declaredUncompressedSize ?? item.data.count)
            let offset = UInt32(payload.count)

            payload += le32(0x0403_4B50)
            payload += le16(10) + le16(0) + le16(0) + le16(0) + le16(0)
            payload += le32(crc) + le32(UInt32(item.data.count)) + le32(declared)
            payload += le16(name.count) + le16(0)
            payload += name + item.data

            directory += le32(0x0201_4B50)
            directory += le16(item.versionMadeBy) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0)
            directory += le32(crc) + le32(UInt32(item.data.count)) + le32(declared)
            directory += le16(name.count) + le16(0) + le16(0)
            directory += le16(0) + le16(0) + le32(item.externalAttributes) + le32(offset)
            directory += name
        }

        var out = payload
        let directoryOffset = UInt32(out.count)
        out += directory
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(items.count) + le16(items.count)
        out += le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0)
        return out
    }

    private static func le16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}
