import XCTest
@testable import BotHarnessCore

/// Keys used to live in the keychain, where the operating system kept bots away from them. They
/// now live in a file, so the protections that were structural have to be tested instead of
/// assumed. Each case here corresponds to a door that opened the moment the keychain closed.
///
/// See `docs/decisions/0012-credentials-live-in-an-owner-only-file.md`.
final class CredentialStoreTests: XCTestCase {

    // MARK: The file itself

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
}
