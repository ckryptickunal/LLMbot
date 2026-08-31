import XCTest
@testable import BotHarnessCore

/// The half of a bot's own computer that cannot be tested without one.
///
/// Skipped unless `BOTHARNESS_LIVE_CONTAINER=1` *and* the tool is installed. Both conditions
/// matter: the environment variable stops these from running by accident in a normal `swift test`
/// (they create VMs, pull a Debian image and take minutes), and the executable check stops them
/// from failing on a machine that simply does not have it.
///
/// Run them with:
///
///     BOTHARNESS_LIVE_CONTAINER=1 swift test --filter ContainerLiveTests
///
/// **These have not been executed.** `container` is not installed on the machine this was written
/// on, so what they assert is the specification for the live path, not a verified result. Anyone
/// who installs the tool should run them first and fix what they find — see ADR 0015.
final class ContainerLiveTests: XCTestCase {

    private var workspace = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOTHARNESS_LIVE_CONTAINER"] == "1",
                          "set BOTHARNESS_LIVE_CONTAINER=1 to run the live container tests")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ContainerRuntime.executable),
                          "container is not installed at \(ContainerRuntime.executable)")

        workspace = NSTemporaryDirectory() + "bh-live-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !workspace.isEmpty { try? FileManager.default.removeItem(atPath: workspace) }
    }

    func testAServiceThatIsRunningReportsReady() async {
        let runtime = ContainerRuntime()
        var availability = await runtime.availability()
        if availability == .serviceStopped { availability = await runtime.startService() }
        XCTAssertEqual(availability, .ready, "could not bring the container service up")
    }

    func testACommandRunsInsideLinuxAndNotOnTheMac() async throws {
        let runtime = ContainerRuntime()
        let ready = await runtime.availability().isReady
        try XCTSkipUnless(ready, "container service is not running")
        let botID = UUID()
        addTeardownBlock { await runtime.destroy(botID: botID) }

        let output = await runtime.exec("uname -s", botID: botID, workspace: workspace,
                                        timeout: 300)
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("Linux"),
                      "expected Linux, got \(output.stdout) — this ran on the Mac")
    }

    func testTheWorkspaceIsSharedBothWays() async throws {
        let runtime = ContainerRuntime()
        let ready = await runtime.availability().isReady
        try XCTSkipUnless(ready, "container service is not running")
        let botID = UUID()
        addTeardownBlock { await runtime.destroy(botID: botID) }

        try "from the host".write(toFile: workspace + "/host.txt", atomically: true, encoding: .utf8)
        let read = await runtime.exec("cat /work/host.txt", botID: botID, workspace: workspace,
                                      timeout: 120)
        XCTAssertEqual(read.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "from the host")

        _ = await runtime.exec("echo 'from the guest' > /work/guest.txt", botID: botID,
                               workspace: workspace, timeout: 120)
        XCTAssertEqual(try String(contentsOfFile: workspace + "/guest.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "from the guest")
    }

    /// The isolation claim, stated as a test. If this fails, the Computers tab is lying to the
    /// user about what a container protects them from.
    func testTheMacsHomeDirectoryIsNotVisibleFromInside() async throws {
        let runtime = ContainerRuntime()
        let ready = await runtime.availability().isReady
        try XCTSkipUnless(ready, "container service is not running")
        let botID = UUID()
        addTeardownBlock { await runtime.destroy(botID: botID) }

        let listing = await runtime.exec("ls \(NSHomeDirectory()) 2>&1 || true",
                                         botID: botID, workspace: workspace, timeout: 120)
        XCTAssertFalse(listing.stdout.contains("Library"),
                       "the Mac's home directory is readable from inside the container")
    }

    /// Nothing from the credential store may reach a guest. The runtime builds a guest environment
    /// from scratch rather than inheriting one, and this is the check that says so out loud.
    func testNoHostSecretsLeakIntoTheGuestEnvironment() async throws {
        let runtime = ContainerRuntime()
        let ready = await runtime.availability().isReady
        try XCTSkipUnless(ready, "container service is not running")
        let botID = UUID()
        addTeardownBlock { await runtime.destroy(botID: botID) }

        setenv("BH_LEAK_CANARY", "this-must-not-appear", 1)
        defer { unsetenv("BH_LEAK_CANARY") }

        let env = await runtime.exec("env", botID: botID, workspace: workspace, timeout: 120)
        XCTAssertFalse(env.stdout.contains("this-must-not-appear"),
                       "a host environment variable reached the container")
        XCTAssertFalse(env.stdout.contains("ANTHROPIC_API_KEY"))
    }

    /// A workspace that moved between launches must not keep serving the old folder. This is the
    /// one behaviour that cannot be checked without a real mount, and the one most likely to be
    /// wrong: `prepared` is empty at launch, so the reuse path has to verify rather than assume.
    func testAMovedWorkspaceIsRemounted() async throws {
        let runtime = ContainerRuntime()
        let ready = await runtime.availability().isReady
        try XCTSkipUnless(ready, "container service is not running")
        let botID = UUID()
        addTeardownBlock { await runtime.destroy(botID: botID) }

        try "first".write(toFile: workspace + "/which.txt", atomically: true, encoding: .utf8)
        _ = try await runtime.prepare(botID: botID, workspace: workspace)

        let moved = NSTemporaryDirectory() + "bh-live-moved-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: moved) }
        try "second".write(toFile: moved + "/which.txt", atomically: true, encoding: .utf8)

        let output = await runtime.exec("cat /work/which.txt", botID: botID, workspace: moved,
                                        timeout: 300)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "second",
                       "the container is still serving the previous workspace")
    }

    func testGarbageCollectionRemovesOnlyOwnerlessComputers() async throws {
        let runtime = ContainerRuntime()
        let ready = await runtime.availability().isReady
        try XCTSkipUnless(ready, "container service is not running")
        let kept = UUID(), dropped = UUID()
        addTeardownBlock { await runtime.destroy(botID: kept) }

        _ = try await runtime.prepare(botID: kept, workspace: workspace)
        _ = try await runtime.prepare(botID: dropped, workspace: workspace)

        await runtime.collectGarbage(keeping: [kept])

        let alive = await runtime.exec("echo alive", botID: kept, workspace: workspace, timeout: 120)
        XCTAssertEqual(alive.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "alive",
                       "garbage collection removed a container that still has a bot")
    }
}
