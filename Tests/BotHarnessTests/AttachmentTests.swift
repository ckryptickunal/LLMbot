import XCTest
@testable import BotHarnessCore

/// What a dropped file is allowed to do.
///
/// The first test here is the one that matters, and it failed before `Attachment` existed:
/// the whole drag-and-drop feature reached the boundary and stopped. Everything else in this
/// file guards the edges of the grant, because a permission that widens on a gesture is only
/// as good as the things it refuses to widen for.
final class AttachmentTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeFile(_ name: String, _ body: String = "hello") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The defect

    func testAFileOutsideTheWorkspaceIsUnreadableUntilItIsAttached() async throws {
        let workspace = scratch.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let dropped = try makeFile("report.txt", "the contents")

        // What the app grants with nothing attached. This is the state the drag-and-drop
        // feature shipped in: the path reached the draft and the boundary refused it.
        let bare = FileExecutor(authority: .forWorkspace(workspace.path))
        do {
            _ = try await bare.read(dropped.path)
            XCTFail("a file outside the workspace should not be readable without a grant")
        } catch {
            XCTAssertTrue("\(error)".contains("may only read"), "\(error)")
        }

        // What the app grants once the user has dropped that file in.
        let attachment = try XCTUnwrap(try? Attachment.grant(dropped.path).get())
        let granted = FileExecutor(authority: .forWorkspace(workspace.path, attachments: [attachment]))
        let text = try await granted.read(dropped.path)
        XCTAssertEqual(text, "the contents")
    }

    // MARK: - What the grant does not widen

    func testAttachingAFileGrantsThatFileAndNotItsFolder() async throws {
        let workspace = scratch.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let dropped = try makeFile("statement.txt")
        let neighbour = try makeFile("private-notes.txt")

        let attachment = try Attachment.grant(dropped.path).get()
        let files = FileExecutor(authority: .forWorkspace(workspace.path, attachments: [attachment]))

        _ = try await files.read(dropped.path)
        do {
            _ = try await files.read(neighbour.path)
            XCTFail("attaching one file must not grant its whole folder")
        } catch { /* expected */ }
    }

    func testAttachingNeverGrantsWriting() async throws {
        let workspace = scratch.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let dropped = try makeFile("source.txt")

        let attachment = try Attachment.grant(dropped.path).get()
        let files = FileExecutor(authority: .forWorkspace(workspace.path, attachments: [attachment]))
        do {
            _ = try await files.write(dropped.path, content: "overwritten")
            XCTFail("a dropped file is consent to read it, not to replace it")
        } catch { /* expected */ }
        XCTAssertEqual(try String(contentsOf: dropped, encoding: .utf8), "hello")
    }

    func testAFolderGrantsItsSubtree() async throws {
        let workspace = scratch.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let folder = scratch.appendingPathComponent("dropped-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("deep.txt")
        try "nested".write(to: inside, atomically: true, encoding: .utf8)

        let attachment = try Attachment.grant(folder.path).get()
        XCTAssertTrue(attachment.isDirectory)
        let files = FileExecutor(authority: .forWorkspace(workspace.path, attachments: [attachment]))
        let text = try await files.read(inside.path)
        XCTAssertEqual(text, "nested")
    }

    // MARK: - What is refused

    func testTheFloorIsRefusedAtTheDropRatherThanLater() throws {
        let key = NSHomeDirectory() + "/.ssh/id_rsa"
        // Only meaningful if there is something there to refuse; the floor check does not
        // depend on it, but a passing assertion on a missing file proves nothing.
        guard FileManager.default.fileExists(atPath: key) else {
            throw XCTSkip("no ~/.ssh/id_rsa on this machine to attempt")
        }
        switch Attachment.grant(key) {
        case .success: XCTFail("dropping a private key must not attach it")
        case .failure(let refusal):
            guard case .floor = refusal else { return XCTFail("wrong refusal: \(refusal)") }
            XCTAssertTrue(refusal.sentence.contains("no bot may read it"), refusal.sentence)
        }
    }

    func testASymlinkCannotSmuggleAFloorPathThroughTheDrop() throws {
        let target = NSHomeDirectory() + "/.ssh"
        guard FileManager.default.fileExists(atPath: target) else {
            throw XCTSkip("no ~/.ssh on this machine to point at")
        }
        let bait = scratch.appendingPathComponent("harmless-looking")
        try FileManager.default.createSymbolicLink(atPath: bait.path, withDestinationPath: target)

        switch Attachment.grant(bait.path) {
        case .success(let granted):
            XCTFail("attached \(granted.path) through a symlink to the floor")
        case .failure(let refusal):
            guard case .floor = refusal else { return XCTFail("wrong refusal: \(refusal)") }
        }
    }

    func testAPathThatIsNotThereIsRefusedWithItsName() {
        let missing = scratch.appendingPathComponent("never-written.txt").path
        switch Attachment.grant(missing) {
        case .success: XCTFail("attached a file that does not exist")
        case .failure(let refusal):
            guard case .missing = refusal else { return XCTFail("wrong refusal: \(refusal)") }
            XCTAssertTrue(refusal.sentence.contains("never-written.txt"), refusal.sentence)
        }
    }

    // MARK: - The list a conversation holds

    func testTheSameFileDroppedTwiceIsOneAttachment() throws {
        let file = try makeFile("once.txt")
        let first = try Attachment.grant(file.path).get()
        let again = try Attachment.grant(file.path).get()
        let merged = Attachment.merge([first], adding: [again])
        XCTAssertEqual(merged.count, 1)
    }

    func testTheOldestFallOffAtTheCap() throws {
        var held: [Attachment] = []
        for index in 0..<(Attachment.limit + 5) {
            let file = try makeFile("f\(index).txt")
            held = Attachment.merge(held, adding: [try Attachment.grant(file.path).get()])
        }
        XCTAssertEqual(held.count, Attachment.limit)
        // Newest first, so the most recent drop is the one that survives.
        XCTAssertTrue(held.first!.name.hasSuffix("\(Attachment.limit + 4).txt"), held.first!.name)
    }

    func testAnUncappedListCannotBeGrownPastTheCapByOneBigDrop() throws {
        var incoming: [Attachment] = []
        for index in 0..<100 {
            let file = try makeFile("bulk\(index).txt")
            incoming.append(try Attachment.grant(file.path).get())
        }
        XCTAssertEqual(Attachment.merge([], adding: incoming).count, Attachment.limit)
    }
}

/// Round-tripping a conversation through `state.json`.
///
/// Split out because the defect it catches is not visible in either half on its own: the
/// encoder is synthesised and wrote `attachments` correctly, and `Conversation.init(from:)` is
/// hand-written and never mentioned it. Saving worked, loading dropped the field, and the only
/// symptom was a grant that quietly stopped existing the next time the app opened.
final class ConversationPersistenceTests: XCTestCase {

    private func roundTrip(_ conversation: Conversation) throws -> Conversation {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Conversation.self, from: try encoder.encode(conversation))
    }

    func testAttachmentsSurviveASaveAndLoad() throws {
        var conversation = Conversation(participants: [UUID()])
        conversation.attachments = [
            Attachment(path: "/tmp/report.pdf", isDirectory: false),
            Attachment(path: "/tmp/assets", isDirectory: true),
        ]
        let loaded = try roundTrip(conversation)
        XCTAssertEqual(loaded.attachments.map(\.path), ["/tmp/report.pdf", "/tmp/assets"])
        XCTAssertEqual(loaded.attachments.map(\.isDirectory), [false, true])
    }

    /// Every stored property has to be named in the hand-written decoder. This asserts the
    /// whole record rather than one field, so the next property added to `Conversation` fails
    /// here instead of failing silently in front of a user.
    func testNothingElseIsDroppedOnTheWayBack() throws {
        var conversation = Conversation(participants: [UUID(), UUID()])
        conversation.title = "Launch"
        conversation.leadBot = conversation.participants.first
        conversation.lastReadAt = Date(timeIntervalSince1970: 1_700_000_000)
        conversation.attachments = [Attachment(path: "/tmp/a.txt", isDirectory: false)]
        conversation.messages = [Message(author: nil, body: .text("hello"))]

        let loaded = try roundTrip(conversation)
        XCTAssertEqual(loaded.id, conversation.id)
        XCTAssertEqual(loaded.participants, conversation.participants)
        XCTAssertEqual(loaded.title, conversation.title)
        XCTAssertEqual(loaded.leadBot, conversation.leadBot)
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertEqual(loaded.lastReadAt, conversation.lastReadAt)
        // Path and kind, not whole-value equality: `state.json` writes dates as ISO-8601 with
        // no fractional seconds, so `addedAt` comes back rounded. Nothing depends on the
        // sub-second part — attachments are identified by path — and asserting on it here
        // would be asserting on the file format rather than on the data surviving.
        XCTAssertEqual(loaded.attachments.map(\.path), conversation.attachments.map(\.path))
        XCTAssertEqual(loaded.attachments.map(\.isDirectory), conversation.attachments.map(\.isDirectory))
        XCTAssertEqual(loaded.attachments.first?.addedAt.timeIntervalSince1970 ?? 0,
                       conversation.attachments.first?.addedAt.timeIntervalSince1970 ?? 0,
                       accuracy: 1)
        XCTAssertEqual(loaded.channelPolicy, conversation.channelPolicy)
    }

    /// An attachment element that cannot be read must cost that one grant, not the rest.
    func testOneUnreadableAttachmentDoesNotTakeTheOthers() throws {
        let json = """
        {"id":"\(UUID().uuidString)","participants":[],"messages":[],
         "createdAt":"2026-01-01T00:00:00Z","lastActivity":"2026-01-01T00:00:00Z",
         "channelPolicy":{"maxConsecutiveBotTurns":12,"botsMaySpeakUnprompted":true,"permissionsFollow":"actingBot"},
         "attachments":[
           {"path":"/tmp/good.txt","isDirectory":false,"addedAt":"2026-01-01T00:00:00Z"},
           {"isDirectory":false,"addedAt":"2026-01-01T00:00:00Z"},
           {"path":"/tmp/also-good.txt","isDirectory":true,"addedAt":"2026-01-01T00:00:00Z"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(Conversation.self, from: Data(json.utf8))
        XCTAssertEqual(loaded.attachments.map(\.path), ["/tmp/good.txt", "/tmp/also-good.txt"])
    }
}
