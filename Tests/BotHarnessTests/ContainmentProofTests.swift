import XCTest
@testable import BotHarnessCore

/// Proof that the boundary is enforced by the kernel and not only by reading commands.
///
/// Every case here is one an adversarial pass demonstrated against the string-matching guard,
/// where it succeeded. String analysis cannot see a path an interpreter assembles at runtime, so
/// these exist to show that the sandbox catches what the parser cannot — and to fail loudly if the
/// sandbox ever silently stops confining, which is its documented failure mode.
final class ContainmentProofTests: XCTestCase {

    private var workspace: String!
    private var outside: String!

    override func setUpWithError() throws {
        workspace = NSTemporaryDirectory() + "bh-contain-\(UUID().uuidString)"
        outside = NSTemporaryDirectory() + "bh-outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workspace)
        try? FileManager.default.removeItem(atPath: outside)
    }

    /// Built exactly the way `AgentLoop` builds it. A test that constructs the executor without
    /// a sandbox proves nothing about the app — the sandbox is an optional parameter, and passing
    /// nil is the unconfined path.
    private func shell() -> ShellExecutor {
        let authority = Authority(readable: [workspace + "/**"],
                                  writable: [workspace + "/**"],
                                  granted: ["shell.exec"])
        let policy = Seatbelt.policy(for: authority,
                                     scratchDirectory: NSTemporaryDirectory() + "bh-proof-\(UUID().uuidString)")
        return ShellExecutor(authority: authority, sandbox: policy)
    }

    func testAnInterpreterCannotWriteOutsideTheWorkspaceEvenWhenTheGuardCannotSeeThePath() async throws {
        try XCTSkipUnless(Seatbelt.selfTest(), "sandbox-exec is not confining on this machine")

        // The path is assembled at runtime from an environment variable, so no amount of reading
        // the command reveals it. This is the case that defeated the parser.
        let target = outside! + "/breach.txt"
        setenv("BH_TARGET", target, 1)
        defer { unsetenv("BH_TARGET") }

        let out = await shell().run("printf x > \"$BH_TARGET\"", cwd: workspace, timeout: 10)
        XCTAssertNotEqual(out.exitCode, 0, "a runtime-assembled path escaped the workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target),
                       "the kernel must stop what the parser cannot see")
    }

    func testOrdinaryWorkInsideTheWorkspaceStillSucceeds() async {
        // The other half, and the one that matters for whether anyone keeps the guard switched on.
        let out = await shell().run("printf x > inside.txt && cat inside.txt", cwd: workspace, timeout: 10)
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/inside.txt"))
    }
}
