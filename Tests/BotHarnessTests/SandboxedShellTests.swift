import XCTest
@testable import BotHarnessCore

/// The four checks the implementation plan asked for, run against the real `ShellExecutor` rather
/// than against `sandbox-exec` directly.
///
/// `SeatbeltTests` proves the profile is correct. This proves the executor actually uses it — a
/// distinction that matters, because a correct profile the spawn path never applies is the exact
/// shape of a boundary that exists only in documentation.
final class SandboxedShellTests: XCTestCase {

    private var workspace = ""
    private var outside = ""

    override func setUpWithError() throws {
        let root = Seatbelt.Policy.realPath(NSTemporaryDirectory() + "bh-shell-\(UUID().uuidString)")
        workspace = root + "/workspace"
        outside = root + "/outside"
        for path in [workspace, outside] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (workspace as NSString).deletingLastPathComponent)
    }

    private func executor(network: Bool = false) -> ShellExecutor {
        let authority = Authority(writable: [workspace + "/**"],
                                  granted: network ? ["shell.exec", "web.read"] : ["shell.exec"])
        return ShellExecutor(
            authority: authority,
            sandbox: Seatbelt.policy(for: authority,
                                     scratchDirectory: workspace + "/.bh-tmp"))
    }

    /// Check 1 — work inside the workspace is unaffected.
    func testACommandInsideTheWorkspaceRunsNormally() async {
        let output = await executor().run("touch ok.txt && echo done", cwd: workspace, timeout: 30)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("done"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/ok.txt"))
    }

    /// Check 2, first layer — a write outside the workspace, spelled plainly, never runs at all.
    ///
    /// The matcher from ADR 0014 refuses it and says so in the bot's own terms. This is the better
    /// outcome of the two: nothing is spawned, and the explanation names the path.
    func testAPlainWriteOutsideTheWorkspaceIsRefusedBeforeItRuns() async {
        let output = await executor().run("touch '\(outside)/no.txt'", cwd: workspace, timeout: 30)
        XCTAssertNotEqual(output.exitCode, 0)
        XCTAssertTrue(output.stderr.contains("Refused"), output.stderr)
        XCTAssertTrue(output.stderr.contains("outside them"), output.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/no.txt"))
    }

    /// Check 2, second layer — the case the matcher cannot see.
    ///
    /// The path is assembled at runtime, so no rule could match it and the command is allowed to
    /// start. The kernel stops the write, and the bot is told why in words it can act on. This is
    /// the single test that justifies the whole Seatbelt layer existing.
    func testARuntimeAssembledWriteIsStoppedByTheKernelAndExplained() async {
        let command = "P='\(outside)'; touch \"$P/no.txt\""
        let output = await executor().run(command, cwd: workspace, timeout: 30)

        XCTAssertNotEqual(output.exitCode, 0, "the write was neither refused nor denied")
        XCTAssertTrue(output.stderr.contains("blocked by the sandbox"),
                      "the kernel denial was not explained to the bot: \(output.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/no.txt"))
    }

    /// Check 3 — the network is closed unless the bot was granted it.
    func testTheNetworkIsClosedWithoutAWebCapability() async {
        let output = await executor().run("curl -sS --max-time 5 https://example.com",
                                          cwd: workspace, timeout: 30)
        XCTAssertNotEqual(output.exitCode, 0, "curl reached the network without a web capability")
    }

    /// The same executor without a policy must behave exactly as before, since that is what runs
    /// if `sandbox-exec` ever stops working.
    func testAnUnsandboxedExecutorStillWorks() async {
        let authority = Authority(writable: [workspace + "/**"], granted: ["shell.exec"])
        let plain = ShellExecutor(authority: authority)
        XCTAssertFalse(plain.isSandboxed)
        let output = await plain.run("echo hello", cwd: workspace, timeout: 30)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.contains("hello"))
    }

    func testTheExecutorReportsWhetherItIsSandboxed() {
        XCTAssertTrue(executor().isSandboxed)
    }

    /// A long-running process must be confined too. A sandbox that covers `shell.exec` and not
    /// `shell.start_process` is a sandbox with a documented way around it.
    func testALongRunningProcessIsAlsoConfined() async throws {
        let executor = executor()
        // Assembled at runtime for the same reason as above: the matcher would otherwise refuse
        // this before the spawn path is exercised, and the spawn path is what is under test.
        _ = try await executor.start("P='\(outside)'; touch \"$P/from-a-server.txt\"; sleep 2",
                                     cwd: workspace, name: "probe")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/from-a-server.txt"),
                       "a started process escaped the sandbox")
        await executor.killAll()
    }

    /// The self-test has to be capable of failing. A check that would pass against a profile
    /// allowing everything proves nothing, so this asserts the *inverse*: with a permissive
    /// policy the same write succeeds, which is what gives the real self-test its meaning.
    func testTheSelfTestWouldNoticeAPermissiveProfile() {
        let root = (workspace as NSString).deletingLastPathComponent
        let permissive = Seatbelt.Policy(writableRoots: [root], readOnlyCarveOuts: [],
                                         allowNetwork: false,
                                         scratchDirectory: workspace + "/.bh-tmp")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Seatbelt.executable)
        process.arguments = Seatbelt.arguments(for: "touch '\(outside)/permitted.txt'",
                                               policy: permissive)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside + "/permitted.txt"),
                      "a permissive profile also denied the write, so the self-test proves nothing")
    }
}
