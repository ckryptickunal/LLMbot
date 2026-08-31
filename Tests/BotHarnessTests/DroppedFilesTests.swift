import XCTest
@testable import BotHarnessCore
import UniformTypeIdentifiers

/// The drop path, tested against what a drag actually carries rather than what the old code
/// hoped it carried.
final class DroppedFilesTests: XCTestCase {

    private var file: String!

    override func setUpWithError() throws {
        file = NSTemporaryDirectory() + "bh-drop-\(UUID().uuidString)/Screen Shot 1.png"
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent)
    }

    // MARK: The case that was broken

    func testAFinderDragCarriesTheURLAsDataNotAsAnObject() {
        // This is what `public.file-url` is: the URL's dataRepresentation. Worth pinning even
        // though it was not the defect — the original theory was that the old `loadObject` call
        // could not read this, and a mutation test showed it could. Keeping the case documents
        // the representation rather than the theory.
        let carried = URL(fileURLWithPath: file).dataRepresentation
        XCTAssertEqual(DroppedFiles.path(from: carried), file,
                       "a Finder drag must resolve to a path")
    }

    func testAPlainFileURLObjectStillWorks() {
        XCTAssertEqual(DroppedFiles.path(from: URL(fileURLWithPath: file)), file)
    }

    func testAFileURLAsTextResolves() {
        let text = URL(fileURLWithPath: file).absoluteString      // file:///...%20...
        XCTAssertEqual(DroppedFiles.path(from: text), file)
    }

    func testADraggedPathStringResolves() {
        XCTAssertEqual(DroppedFiles.path(from: "  \(file!)  "), file)
    }

    // MARK: What must NOT become an attachment

    func testProseDroppedOnTheComposerStaysProse() {
        // Dragging a sentence out of a document should not silently become a broken file path.
        XCTAssertNil(DroppedFiles.path(from: "please summarise this for me"))
        XCTAssertNil(DroppedFiles.path(from: "/no/such/file/anywhere.txt"))
        XCTAssertNil(DroppedFiles.path(from: ""))
    }

    func testANonFileURLIsNotAPath() {
        XCTAssertNil(DroppedFiles.path(from: URL(string: "https://example.com/a.png")!))
    }

    // MARK: Writing it into the draft

    func testAPathWithASpaceIsQuoted() {
        // Most screenshots are called "Screen Shot …". Unquoted, the draft read as two paths and
        // the bot went looking for a file called "Screen".
        let line = DroppedFiles.draftLines(for: [file])
        XCTAssertTrue(line.hasPrefix("\""), line)
        XCTAssertTrue(line.hasSuffix("\""), line)
    }

    func testAPlainPathIsNotQuoted() {
        XCTAssertEqual(DroppedFiles.quoted("/tmp/plain.txt"), "/tmp/plain.txt")
    }

    func testTheSameFileArrivingTwiceIsAttachedOnce() {
        // One Finder drag registers a file under several type identifiers, and accepting all of
        // them — which is what makes the drop reliable — means the same path arrives repeatedly.
        XCTAssertEqual(DroppedFiles.deduplicated(["/a", "/b", "/a"]), ["/a", "/b"])
    }

    // MARK: The whole load path, against a provider registered the way Finder registers one

    func testLoadingFromAFinderStyleProviderYieldsThePath() {
        // Everything except SwiftUI's delivery of the drop: a real NSItemProvider carrying
        // `public.file-url` as data, asked for its item the way the composer now asks.
        let provider = NSItemProvider()
        let url = URL(fileURLWithPath: file)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                            visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }

        let done = expectation(description: "loaded")
        var got: [String] = []
        DroppedFiles.load(from: [provider]) { paths in got = paths; done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(got, [file], "the composer must resolve a Finder-style drop to a path")
    }

    func testLoadingSeveralFilesKeepsTheOrderTheyWereDraggedIn() {
        let second = (file as NSString).deletingLastPathComponent + "/second.txt"
        FileManager.default.createFile(atPath: second, contents: Data("y".utf8))

        let providers = [file!, second].map { path -> NSItemProvider in
            let p = NSItemProvider()
            let u = URL(fileURLWithPath: path)
            p.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier,
                                         visibility: .all) { completion in
                completion(u.dataRepresentation, nil); return nil
            }
            return p
        }

        let done = expectation(description: "loaded")
        var got: [String] = []
        DroppedFiles.load(from: providers) { paths in got = paths; done.fulfill() }
        wait(for: [done], timeout: 5)

        // The loads finish in whatever order the system chooses; the order dragged is the order
        // the person meant, so it is restored rather than left to chance.
        XCTAssertEqual(got, [file, second])
    }

    func testAProviderCarryingNothingUsableIsSkippedRatherThanHanging() {
        // A drag of something we cannot read must not leave the completion waiting forever —
        // the group has to balance even when a provider is skipped before it is entered.
        // Registers a type none of the accepted identifiers conform to, so the loop skips it.
        let useless = NSItemProvider()
        useless.registerDataRepresentation(forTypeIdentifier: "com.example.unknown-type",
                                           visibility: .all) { completion in
            completion(Data([0x00]), nil); return nil
        }
        let done = expectation(description: "loaded")
        var got: [String] = ["sentinel"]
        DroppedFiles.load(from: [useless]) { paths in got = paths; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(got, [])
    }
}
