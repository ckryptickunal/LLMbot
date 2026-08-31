import XCTest
@testable import BotHarnessCore

/// The kernel half of the shell boundary.
///
/// These execute real commands through `sandbox-exec` rather than asserting on generated text. A
/// profile that reads correctly and denies nothing is the exact failure this file exists to catch,
/// and it is invisible in a string comparison.
///
/// Denials are asserted by *reason*, not by exit code. An earlier version of this file checked only
/// for a nonzero status, and one test passed while writing to a path that did not exist — the
/// command failed with "No such file or directory" and the test read that as the sandbox holding.
/// A security test that cannot tell EPERM from ENOENT is worse than no test.
final class SeatbeltTests: XCTestCase {

    /// Deliberately not `String!`. The implicitly-unwrapped form interpolates as `Optional("…")`,
    /// which silently corrupts every path built by interpolation — and did.
    private var scratch = ""

    override func setUpWithError() throws {
        let path = NSTemporaryDirectory() + "bh-seatbelt-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // Resolved the way the profile resolves it. Foundation's `resolvingSymlinksInPath()` is the
        // wrong tool and would make these tests lie: it strips a leading `/private`, the opposite
        // of what the kernel does.
        scratch = Seatbelt.Policy.realPath(path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    // MARK: Harness

    private struct Outcome {
        var status: Int32
        var errors: String

        var succeeded: Bool { status == 0 }
        /// The kernel refused it, as opposed to the command failing for an unrelated reason.
        var wasDenied: Bool { status != 0 && errors.contains("Operation not permitted") }
    }

    private func run(_ command: String, _ policy: Seatbelt.Policy) -> Outcome {
        try? FileManager.default.createDirectory(atPath: policy.scratchDirectory,
                                                 withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Seatbelt.executable)
        process.arguments = Seatbelt.arguments(for: command, policy: policy)
        // Mirrors what `ShellExecutor` hands a sandboxed process: a TMPDIR the profile allows.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "HOME": NSHomeDirectory(),
                               "TMPDIR": policy.scratchDirectory]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return Outcome(status: -1, errors: "\(error)") }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus,
                       errors: String(decoding: data, as: UTF8.self))
    }

    private func policy(writable: [String], carveOuts: [String] = [],
                        network: Bool = false) -> Seatbelt.Policy {
        Seatbelt.Policy(writableRoots: writable, readOnlyCarveOuts: carveOuts,
                        allowNetwork: network, scratchDirectory: scratch + "/tmp")
    }

    private func makeWorkspace(_ name: String = "work") throws -> String {
        let path = scratch + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: The mechanism itself

    func testSeatbeltIsConfiningOnThisMachine() {
        // If this fails, every other test here is meaningless, and the app's launch check will
        // already have said so on stderr.
        XCTAssertTrue(Seatbelt.selfTest(),
                      "sandbox-exec is not confining writes on this OS build")
    }

    // MARK: Writes

    func testAWriteInsideTheWorkspaceSucceeds() throws {
        let workspace = try makeWorkspace()
        let outcome = run("touch '\(workspace)/ok.txt'", policy(writable: [workspace]))
        XCTAssertTrue(outcome.succeeded, "denied a write it should allow: \(outcome.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace + "/ok.txt"))
    }

    func testAWriteOutsideTheWorkspaceIsDeniedByTheKernel() throws {
        let workspace = try makeWorkspace()
        let outside = scratch + "/outside.txt"

        let outcome = run("touch '\(outside)'", policy(writable: [workspace]))
        XCTAssertTrue(outcome.wasDenied, "expected a permission denial, got: \(outcome.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    /// The case string-matching cannot see, and the reason this layer exists at all.
    func testAPathAssembledAtRuntimeIsStillDenied() throws {
        let workspace = try makeWorkspace()
        let outside = scratch + "/assembled.txt"

        // No absolute path appears as a literal anywhere in this command, so the guard that reads
        // commands as text has nothing to match on.
        let command = "P='\(scratch)'; touch \"$P/assembled.txt\""
        let outcome = run(command, policy(writable: [workspace]))
        XCTAssertTrue(outcome.wasDenied,
                      "a runtime-assembled path was not denied by the kernel: \(outcome.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    /// Invisible in review: in SBPL the last matching rule wins, so the carve-out denies must come
    /// after the allows. Reversing the two blocks grants write access to every `.git` in the
    /// workspace and reads identically in a diff.
    func testACarveOutInsideAWritableRootStaysReadOnly() throws {
        let workspace = try makeWorkspace("repo")
        let git = workspace + "/.git"
        try FileManager.default.createDirectory(atPath: git, withIntermediateDirectories: true)

        let policy = policy(writable: [workspace], carveOuts: [git])
        XCTAssertTrue(run("touch '\(workspace)/file.txt'", policy).succeeded,
                      "the workspace itself must stay writable")

        let denied = run("touch '\(git)/HEAD'", policy)
        XCTAssertTrue(denied.wasDenied,
                      "the carve-out is not applied — check rule order: \(denied.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: git + "/HEAD"))
    }

    func testTheScratchDirectoryIsWritableSoBuildToolsWork() throws {
        let workspace = try makeWorkspace()
        // Almost every compiler and package manager needs a temp directory. Without one, a
        // sandboxed build fails in ways that look like the sandbox is broken rather than working.
        let outcome = run("touch \"$TMPDIR/staged\"", policy(writable: [workspace]))
        XCTAssertTrue(outcome.succeeded, "TMPDIR is not writable: \(outcome.errors)")
    }

    // MARK: Reads

    func testReadingIsNotNarrowedByTheProfile() throws {
        // Reads are governed before execution by the executor's own scope checks. A read-deny
        // profile stops interpreters loading their standard library, which reads as a broken app.
        let workspace = try makeWorkspace()
        XCTAssertTrue(run("cat /etc/hosts > /dev/null", policy(writable: [workspace])).succeeded)
    }

    // MARK: Network

    func testNetworkIsDeniedWhenTheBotHasNoWebCapability() throws {
        let workspace = try makeWorkspace()
        // The cheapest observable outbound attempt that needs no listener on the other end. Under
        // `(deny network*)` the socket cannot be opened at all.
        let outcome = run("nc -z -w 2 1.1.1.1 443", policy(writable: [workspace]))
        XCTAssertFalse(outcome.succeeded, "an outbound connection succeeded under (deny network*)")
    }

    // MARK: Profile text

    func testDenyDefaultComesFirst() {
        let lines = Seatbelt.profile(for: policy(writable: [scratch]))
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "(version 1)")
        XCTAssertEqual(lines.dropFirst().first, "(deny default)")
    }

    func testNetworkRuleFollowsThePolicy() {
        XCTAssertTrue(Seatbelt.profile(for: policy(writable: [scratch]))
            .contains("(deny network*)"))
        XCTAssertTrue(Seatbelt.profile(for: policy(writable: [scratch], network: true))
            .contains("(allow network-outbound)"))
    }

    /// A workspace path is user data, and user data spliced into a policy language is an injection
    /// site. The escaped text still *contains* `(allow default)` — inside a string literal, inert —
    /// so asserting that substring is absent would fail on correctly escaped input, which is the
    /// opposite of the intent. The property that matters is that the parser never leaves the
    /// literal, checked two ways: no line is that rule, and the profile still denies.
    func testAPathContainingQuotesCannotInjectARule() throws {
        let workspace = try makeWorkspace()
        let hostile = "/tmp/evil\") (allow default) (deny file-read* (subpath \"/x"
        let hostilePolicy = policy(writable: [workspace, hostile])
        let text = Seatbelt.profile(for: hostilePolicy)

        XCTAssertTrue(text.contains("\\\""), "the quote should have been escaped")
        let rules = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(rules.contains { $0.hasPrefix("(allow default)") },
                       "a quote in a path escaped its literal and injected a rule")

        let outcome = run("touch '\(scratch)/injected.txt'", hostilePolicy)
        XCTAssertTrue(outcome.wasDenied,
                      "a hostile path changed what the profile enforces: \(outcome.errors)")
    }

    func testSymlinkedRootsAreResolved() throws {
        // /tmp is a symlink to /private/tmp. `realpath` needs the directory to exist, which is why
        // the executor creates a workspace before building a profile for it.
        let linked = "/tmp/bh-symlink-check-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: linked) }

        XCTAssertTrue(Seatbelt.profile(for: policy(writable: [linked]))
            .contains("/private" + linked),
                      "writable roots must be resolved through symlinks")
    }

    func testGlobSuffixesAreStrippedFromRoots() {
        // Authority paths are written as globs (`~/Desktop/**`); SBPL wants a subpath.
        let text = Seatbelt.profile(for: policy(writable: [scratch + "/**"]))
        XCTAssertTrue(text.contains("(allow file-write* (subpath \"\(scratch)\"))"),
                      "expected a plain subpath rule, got:\n\(text)")
        XCTAssertFalse(text.contains("**"))
    }

    // MARK: Policy derivation

    func testTheProfileCarvesOutGitAndTheAppsOwnState() {
        let derived = Seatbelt.policy(for: Authority(writable: [scratch + "/**"], granted: []),
                                      scratchDirectory: scratch + "/tmp")
        XCTAssertTrue(derived.readOnlyCarveOuts.contains(scratch + "/.git"),
                      "a bot may work in a repository without rewriting its history")
        XCTAssertTrue(derived.readOnlyCarveOuts.contains { $0.contains("Bot-Harness") },
                      "a bot may not edit the rules that govern it")
    }

    func testNetworkFollowsWhatTheBotWasGranted() {
        XCTAssertFalse(Seatbelt.policy(for: Authority(writable: [scratch]),
                                       scratchDirectory: scratch).allowNetwork)
        XCTAssertTrue(Seatbelt.policy(for: Authority(writable: [scratch], granted: ["web.read"]),
                                      scratchDirectory: scratch).allowNetwork)
    }

    func testRootIsNeverAWritableRoot() {
        let derived = Seatbelt.policy(for: Authority(writable: ["/", "/**"]),
                                      scratchDirectory: scratch)
        XCTAssertFalse(derived.writableRoots.contains("/"),
                       "granting the whole disk defeats the profile entirely")
    }

    // MARK: Invocation

    func testTheArgumentVectorRunsTheCommandUnderAProfile() {
        let argv = Seatbelt.arguments(for: "echo hi", policy: policy(writable: [scratch]))
        XCTAssertEqual(argv.first, "-p")
        XCTAssertEqual(argv.dropFirst().first?.hasPrefix("(version 1)"), true)
        XCTAssertEqual(Array(argv.suffix(3)), ["/bin/zsh", "-c", "echo hi"])
    }
}

/// A regression guard for a crash, not a feature test.
///
/// `Seatbelt.isWorking` runs the self-test on first read, and the self-test spawns a subprocess.
/// A settings panel read it from inside a SwiftUI body and the app died silently — no crash
/// report, no Swift runtime message, just an exit. `knownWorking` exists so a view can ask without
/// ever triggering that, and this test fails if someone routes it back through `isWorking`.
final class SeatbeltViewSafetyTests: XCTestCase {

    func testTheViewFacingAnswerIsCheapEnoughForABodyEvaluation() {
        // A spawn is ~100ms. A cached read is nanoseconds. Two orders of magnitude of headroom
        // means this cannot fail for timing noise, only for someone reintroducing the spawn.
        let started = Date()
        for _ in 0..<1_000 { _ = Seatbelt.knownWorking }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05,
                          "reading knownWorking is doing real work — it must never spawn anything")
    }

    func testTheCachedAnswerAgreesWithTheRealOne() {
        // Reading `isWorking` here is fine: this is a test, not a view.
        let real = Seatbelt.isWorking
        XCTAssertEqual(Seatbelt.knownWorking, real,
                       "the cached answer drifted from the one the runtime uses")
    }
}
