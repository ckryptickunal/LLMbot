import XCTest
import Darwin
@testable import BotHarnessCore

/// Keys used to live in the keychain, where the operating system kept bots away from them. They
/// now live in a file, so the protections that were structural have to be tested instead of
/// assumed. Each case here corresponds to a door that opened the moment the keychain closed.
///
/// See `docs/decisions/0012-credentials-live-in-an-owner-only-file.md`.
///
/// The cases that write malformed or half-written documents run against a `CredentialStore.Store`
/// in a temporary directory, never against `CredentialStore` itself: a test that has to corrupt
/// the file to prove the store survives corruption must not be pointed at the user's real keys.
final class CredentialStoreTests: XCTestCase {

    private var scratchDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in scratchDirectories { try? FileManager.default.removeItem(at: directory) }
        scratchDirectories = []
    }

    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("credential-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    private func makeStore() throws -> CredentialStore.Store {
        CredentialStore.Store(directory: try makeDirectory())
    }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return Int((attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0) & 0o777
    }

    private func documentOnDisk(_ store: CredentialStore.Store) throws -> [String: Any] {
        let data = try Data(contentsOf: store.fileURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: The file it writes through

    func testTheTemporaryFileIsOwnerOnlyFromTheMomentItIsCreated() throws {
        let store = try makeStore()

        // A permissive umask on purpose. `Data.write(options: [.atomic])`, which this replaced,
        // takes its mode from the umask and can only be narrowed afterwards — under this umask it
        // would produce 0666 and the window would be wide open. Nothing here narrows the file
        // after the fact, so the mode asserted below can only have come from the create call.
        let previousMask = umask(0)
        defer { umask(previousMask) }

        let descriptor = try store.openTemporaryFile()
        close(descriptor)

        XCTAssertEqual(try mode(of: store.temporaryURL.path), 0o600,
                       "the save-in-progress file holds every key and must never be readable by anyone else")
    }

    func testAWriteUnderAPermissiveUmaskLeavesAnOwnerOnlyFileAndNoTemporary() throws {
        let store = try makeStore()
        let previousMask = umask(0)
        defer { umask(previousMask) }

        XCTAssertTrue(store.set("AIza-permissive-umask-value", account: "gemini"))

        XCTAssertEqual(try mode(of: store.fileURL.path), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryURL.path),
                       "a finished save must not leave a second copy of the keys behind")
        XCTAssertTrue(store.problems().isEmpty, "unexpected: \(store.problems())")
    }

    func testAStrayTemporaryIsReportedAndRemovedByRepair() throws {
        let store = try makeStore()
        store.set("AIza-value-that-is-long-enough", account: "gemini")

        // Exactly what a process killed between the write and the rename used to leave: a
        // world-readable copy of every key that nothing looks at again.
        try Data("{\"gemini\":\"AIza-value-that-is-long-enough\"}".utf8).write(to: store.temporaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: store.temporaryURL.path)

        XCTAssertTrue(store.problems().contains { $0.contains("credentials.json.tmp") },
                      "a leftover save file is a plaintext key copy and must be reported")

        XCTAssertTrue(store.repairPermissions())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.temporaryURL.path))
        XCTAssertTrue(store.problems().isEmpty, "unexpected: \(store.problems())")
    }

    func testTheFolderModeIsReportedOnlyOnceThereIsAKeyInIt() throws {
        let directory = try makeDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let store = CredentialStore.Store(directory: directory)

        // A machine that has never had a key set is not a machine with a permissions problem, and
        // a repair banner that appears when nothing is wrong is one people learn to dismiss.
        XCTAssertTrue(store.problems().isEmpty)

        store.set("AIza-value-that-is-long-enough", account: "gemini")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        XCTAssertTrue(store.problems().contains { $0.contains("folder") },
                      "a world-readable folder around the key file must be reported")
        XCTAssertTrue(store.repairPermissions())
        XCTAssertEqual(try mode(of: directory.path), 0o700)
        XCTAssertTrue(store.problems().isEmpty, "unexpected: \(store.problems())")
    }

    // MARK: A file people are invited to edit by hand

    func testANonStringValueHidesNoKeysAndSurvivesTheNextSave() throws {
        let store = try makeStore()
        let document: [String: Any] = ["gemini": "AIza-hand-edited-value", "budget": 5]
        try JSONSerialization.data(withJSONObject: document).write(to: store.fileURL)

        // A single `as? [String: String]` on the whole document made every key read as absent,
        // and the next save then wrote only the key being saved.
        XCTAssertEqual(store.get("gemini"), "AIza-hand-edited-value")
        XCTAssertEqual(store.accounts(), ["gemini"])

        XCTAssertTrue(store.set("sk-ant-added-afterwards", account: "anthropic"))

        let onDisk = try documentOnDisk(store)
        XCTAssertEqual(onDisk["gemini"] as? String, "AIza-hand-edited-value")
        XCTAssertEqual(onDisk["anthropic"] as? String, "sk-ant-added-afterwards")
        XCTAssertEqual(onDisk["budget"] as? Int, 5, "an entry we do not understand is not ours to delete")
    }

    func testAFileThatIsNotAJSONObjectIsRefusedRatherThanOverwritten() throws {
        let store = try makeStore()
        let original = "this file is not JSON at all\n"
        try Data(original.utf8).write(to: store.fileURL)

        XCTAssertFalse(store.set("AIza-would-have-clobbered-it", account: "gemini"),
                       "a save that cannot read what it is replacing must refuse, not overwrite")
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), original)
        XCTAssertNotNil(store.lastWriteFailure)
    }

    func testDeleteReportsAFailedWriteInsteadOfClaimingSuccess() throws {
        let store = try makeStore()
        store.set("AIza-value-that-is-long-enough", account: "gemini")
        XCTAssertTrue(store.delete("gemini"))

        try Data("[1, 2, 3]".utf8).write(to: store.fileURL)
        XCTAssertFalse(store.delete("gemini"),
                       "delete used to discard the write result, so a key still on disk reported as removed")
    }

    // MARK: Two writers

    func testAKeyWrittenOutOfBandIsVisibleWithoutAnExplicitReload() throws {
        let store = try makeStore()
        store.set("AIza-written-by-the-app", account: "gemini")
        XCTAssertEqual(store.get("gemini"), "AIza-written-by-the-app")   // now cached

        // What `scripts/set-key.sh` does while the app is open.
        let document = ["gemini": "AIza-written-by-the-app", "openrouter": "sk-or-written-by-the-script"]
        try JSONSerialization.data(withJSONObject: document).write(to: store.fileURL, options: [.atomic])

        XCTAssertEqual(store.get("openrouter"), "sk-or-written-by-the-script",
                       "the cache must notice the file it read has been replaced")
    }

    func testAWriterDoesNotClobberKeysAnotherWriterAddedMeanwhile() throws {
        let directory = try makeDirectory()
        let app = CredentialStore.Store(directory: directory)
        let script = CredentialStore.Store(directory: directory)

        app.set("AIza-first-value-here", account: "gemini")     // app now holds a cached copy
        script.set("sk-or-second-value", account: "openrouter") // written behind the app's back
        app.set("sk-ant-third-value", account: "anthropic")     // merged from the app's stale cache

        let reader = CredentialStore.Store(directory: directory)
        XCTAssertEqual(reader.accounts(), ["anthropic", "gemini", "openrouter"],
                       "a save must merge into what is on disk now, not into what it read at launch")
    }

    // MARK: The real store

    func testTheFileIsOwnerOnlyAfterWriting() throws {
        let account = "test-\(UUID().uuidString.prefix(8))"
        XCTAssertTrue(CredentialStore.set("value-for-permissions-check", account: account))
        defer { CredentialStore.delete(account) }

        let attributes = try FileManager.default.attributesOfItem(atPath: CredentialStore.fileURL.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "credential file must be readable only by its owner")
        XCTAssertTrue(CredentialStore.permissionsAreCorrect())
    }

    func testARoundTripReturnsTheValueAndDeleteRemovesIt() {
        let account = "test-\(UUID().uuidString.prefix(8))"
        CredentialStore.set("sk-round-trip-value", account: account)
        XCTAssertEqual(CredentialStore.get(account), "sk-round-trip-value")
        XCTAssertTrue(CredentialStore.has(account))

        CredentialStore.delete(account)
        XCTAssertNil(CredentialStore.get(account))
        XCTAssertFalse(CredentialStore.has(account))
    }

    func testWritingOneAccountLeavesTheOthersAlone() {
        let first = "test-a-\(UUID().uuidString.prefix(6))"
        let second = "test-b-\(UUID().uuidString.prefix(6))"
        defer { CredentialStore.delete(first); CredentialStore.delete(second) }

        CredentialStore.set("first-value", account: first)
        CredentialStore.set("second-value", account: second)
        // The naive implementation of a file-backed store overwrites the document on each save.
        XCTAssertEqual(CredentialStore.get(first), "first-value")
        XCTAssertEqual(CredentialStore.get(second), "second-value")
    }

    func testPermissionDriftIsDetectedAndRepairable() throws {
        let account = "test-\(UUID().uuidString.prefix(8))"
        CredentialStore.set("value", account: account)
        defer { CredentialStore.delete(account) }

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: CredentialStore.fileURL.path)
        XCTAssertFalse(CredentialStore.permissionsAreCorrect(), "a world-readable key file must be noticed")
        XCTAssertTrue(CredentialStore.repairPermissions())
        XCTAssertTrue(CredentialStore.permissionsAreCorrect())
    }

    // MARK: The floor

    func testTheCredentialFileIsOnTheFloor() {
        XCTAssertTrue(Authority.alwaysDenied.contains { $0.hasSuffix("credentials.json") },
                      "if this is ever removed, every bot can read every key")
    }

    func testFileExecutorRefusesTheCredentialFileEvenWhenTheContractAllowsEverything() async {
        // The exact shape of a stale `state.json`: a contract whose own deny list predates the
        // credential file, and whose readable list covers the whole home directory.
        let permissive = Authority(readable: ["~/**"], writable: ["~/**"], denied: [])
        let executor = FileExecutor(authority: permissive)

        do {
            _ = try await executor.read(CredentialStore.fileURL.path)
            XCTFail("a permissive contract must not be able to lower the floor")
        } catch {
            XCTAssertTrue("\(error)".contains("credentials"), "unexpected error: \(error)")
        }
    }

    // MARK: The shell, which does not go through FileExecutor at all

    func testTheShellRefusesToReadTheKeyStore() {
        let store = CredentialStore.fileURL.path
        for command in ["cat \"\(store)\"", "grep gemini '\(store)'", "cp \(store) /tmp/x"] {
            XCTAssertNotNil(ShellExecutor.forbiddenPath(in: command), "not refused: \(command)")
        }
    }

    func testTheShellStillAllowsAProjectsOwnCredentialsFile() {
        // A name-only guard would fail here, and would refuse ordinary work in any repository
        // that keeps Google client secrets under their conventional file name.
        for command in ["cat ./credentials.json",
                        "cat ~/Desktop/jewel/credentials.json",
                        "node -e \"require('./credentials.json')\""] {
            XCTAssertNil(ShellExecutor.forbiddenPath(in: command), "wrongly refused: \(command)")
        }
    }

    func testShellOutputHasKeyValuesRedacted() async {
        let key = "AIzaSy-test-value-that-should-never-be-echoed-0123"
        CredentialStore.set(key, account: "gemini-test-redaction")
        defer { CredentialStore.delete("gemini-test-redaction") }

        // Redaction matches on the value, so it holds even when the path guard is bypassed —
        // here by printing the secret without naming the file at all.
        let redactor = StreamingRedactor(secrets: [key])
        XCTAssertFalse(redactor.redact("the key is \(key)").contains(key))
    }

    func testTheRedactorCoversAnAccountNobodyHardcoded() {
        // `forRun` used to iterate ["gemini", "anthropic", "openai"], so a key under any other
        // name reached the trace in full — and the trace is hash-chained, so it stays there.
        let account = "openrouter-test-\(UUID().uuidString.prefix(6))"
        let key = "sk-or-v1-test-value-never-to-be-echoed-9876"
        CredentialStore.set(key, account: account)
        defer { CredentialStore.delete(account) }

        let redacted = StreamingRedactor.forRun().redact("the model echoed \(key) back")
        XCTAssertFalse(redacted.contains(key), "a key stored under a name we did not anticipate leaked")
    }

    func testTheRedactorLeavesValuesTooShortToBeKeysAlone() {
        // A three-character "key" would blank the word out of every message the bot writes.
        let redactor = StreamingRedactor(secrets: ["and"])
        XCTAssertEqual(redactor.redact("this and that"), "this and that")
    }
}
