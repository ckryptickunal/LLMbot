import XCTest
@testable import BotHarnessCore

/// The failure log only earns its place if two things hold: the same problem in two different
/// runs lands in one group, and the report ranks by what a failure cost rather than by how
/// often it fired. Everything here is aimed at one of those two, or at the ways the file can
/// be damaged in between.
///
/// Every message used below is copied from a real throw site in `Sources/BotHarnessCore/Tools/`,
/// because a signature that groups messages invented for a test proves nothing about the
/// messages this app actually produces.
final class FailureLogTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("failurelog-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeLog(secrets: [String] = []) -> FailureLog {
        FailureLog(root: root, extraSecrets: secrets)
    }

    private func rawFile() -> String {
        (try? String(contentsOf: root.appendingPathComponent("failures.jsonl"), encoding: .utf8)) ?? ""
    }

    // MARK: - Grouping: the same problem must group

    /// The refusal a bot hits when it writes outside its workspace. Two runs, two projects,
    /// two paths — one problem. If these do not group, the report shows every occurrence as a
    /// singleton and says nothing at all.
    func testTheSameRefusalInDifferentDirectoriesGroups() {
        let a = FailureSignature.signature(source: "shell", message:
            "Refused: this bot may only write inside its workspace, and "
            + "`/Users/kunal/Desktop/project-a/out.txt` is outside it. Nothing was run.")
        let b = FailureSignature.signature(source: "shell", message:
            "Refused: this bot may only write inside its workspace, and "
            + "`/Users/someone/work/deep/nested/build/out.txt` is outside it. Nothing was run.")
        XCTAssertEqual(a, b, "the same refusal in two directories has to be one problem")
    }

    /// Timeouts differ by the number of seconds they waited, which is a property of the
    /// configuration and not of the failure.
    func testTheSameTimeoutAtDifferentDurationsGroups() {
        let a = FailureSignature.signature(source: "git",
            message: "git push did not finish within 120s and was stopped.")
        let b = FailureSignature.signature(source: "git",
            message: "git push did not finish within 300s and was stopped.")
        XCTAssertEqual(a, b)
    }

    /// Ports, pids and uuids are the three things most likely to be different every single time.
    func testVolatileIdentifiersAreNormalisedOut() {
        let a = FailureSignature.signature(source: "browser",
            message: "could not reach 127.0.0.1:9222 (pid 48213) for run 3f2a9c1e-77bd-4d0f-9a1b-2c3d4e5f6071")
        let b = FailureSignature.signature(source: "browser",
            message: "could not reach 127.0.0.1:51844 (pid 991) for run 0c1d2e3f-aaaa-4bbb-8ccc-ddddeeeeffff")
        XCTAssertEqual(a, b)
        XCTAssertEqual(FailureSignature.normalise(
            "could not reach 127.0.0.1:9222 (pid 48213) for run 3f2a9c1e-77bd-4d0f-9a1b-2c3d4e5f6071"),
            "could not reach <ip>:<port> (pid <pid>) for run <uuid>",
            "the normalised form is what a person reads in the report; it has to stay legible")
    }

    // MARK: - Grouping: different problems must not

    /// A read refusal and a write refusal are different failures with different fixes. A
    /// normaliser aggressive enough to merge them would make the report actively misleading.
    func testAReadRefusalDoesNotGroupWithAWriteRefusal() {
        let write = FailureSignature.signature(source: "shell", message:
            "Refused: this bot may only write inside its workspace, and `/Users/k/a/out.txt` is outside it. Nothing was run.")
        let read = FailureSignature.signature(source: "shell", message:
            "Refused: this bot may only read inside the paths you gave it, and `/Users/k/a/out.txt` is outside them. Nothing was run.")
        XCTAssertNotEqual(write, read)
    }

    /// Exit statuses and AppleEvent codes are small integers that *identify* the problem.
    /// Normalising numbers wholesale is the obvious implementation and it is wrong: it merges
    /// "the repository is not there" with "the push was rejected".
    func testSmallErrorCodesKeepProblemsApart() {
        let a = FailureSignature.signature(source: "git",
            message: "git exited with status 128 and said nothing.")
        let b = FailureSignature.signature(source: "git",
            message: "git exited with status 1 and said nothing.")
        XCTAssertNotEqual(a, b, "an exit status is the identity of the failure, not noise")

        let denied = FailureSignature.signature(source: "browser",
            message: "The browser answered -1743: not authorized to send Apple events.")
        let missing = FailureSignature.signature(source: "browser",
            message: "The browser answered -600: the application isn't running.")
        XCTAssertNotEqual(denied, missing)
    }

    /// Identical wording from two subsystems sends the reader to two different places.
    func testTheSameWordingFromTwoSubsystemsStaysSeparate() {
        XCTAssertNotEqual(
            FailureSignature.signature(source: "shell", message: "timed out after 30s"),
            FailureSignature.signature(source: "browser", message: "timed out after 30s")
        )
    }

    /// The normaliser must not eat ordinary prose on its way past. "and/or" is not a path.
    func testOrdinaryProseSurvivesNormalisation() {
        XCTAssertEqual(FailureSignature.normalise("read and/or write was refused"),
                       "read and/or write was refused")
    }

    // MARK: - Ranking

    /// The case the whole ranking exists for. Thirty browser retries that all recovered cost
    /// the user nothing; three shell refusals that ended the run cost them three tasks. Sorting
    /// by count puts the browser first, which is the wrong answer.
    func testARareDeadEndOutranksACommonRecoveredFailure() {
        let log = makeLog()
        let now = Date()
        for i in 0..<30 {
            log.record(source: "browser", message: "The browser is not running.",
                       bot: "Scout", run: "r\(i)", recovered: true,
                       at: now.addingTimeInterval(-Double(i) * 60))
        }
        for i in 0..<3 {
            log.record(source: "shell",
                       message: "Refused: this bot may only write inside its workspace, and "
                              + "`/Users/k/p\(i)/out.txt` is outside it. Nothing was run.",
                       bot: "Scout", run: "s\(i)", recovered: false,
                       at: now.addingTimeInterval(-Double(i) * 600))
        }

        let report = log.report(since: now.addingTimeInterval(-86_400), now: now)
        XCTAssertEqual(report.groups.first?.source, "shell",
                       "three dead ends have to outrank thirty recoveries")
        XCTAssertEqual(report.groups.first?.count, 3)
        // Stated explicitly so the test fails if someone "fixes" the ranking back to counting.
        XCTAssertGreaterThan(report.groups.last?.count ?? 0, report.groups.first?.count ?? 0,
                             "the lower-ranked group is the more frequent one; that is the point")
        XCTAssertTrue(report.text.contains("shell is what I would fix first"),
                      "the summary has to name the same thing the ranking chose:\n\(report.text)")
    }

    /// Ties must not shuffle between runs, or yesterday's report cannot be diffed against today's.
    func testRankingIsStableForIdenticalWeights() {
        let now = Date()
        func order() -> [String] {
            let log = FailureLog(root: root.appendingPathComponent(UUID().uuidString))
            for source in ["git", "files", "browser"] {
                log.record(source: source, message: "it broke", recovered: true, at: now)
            }
            return log.report(since: now.addingTimeInterval(-3600), now: now).groups.map(\.signature)
        }
        XCTAssertEqual(order(), order())
    }

    // MARK: - Trend

    /// "Is this getting worse" is the question a daily report answers. The comparison window is
    /// the same length as the reported one, immediately before it.
    func testTrendComparesAgainstThePreviousEqualPeriod() {
        let log = makeLog()
        let now = Date()
        let day: TimeInterval = 86_400
        let message = "The browser is not running."

        for i in 0..<10 {
            log.record(source: "browser", message: message, recovered: true,
                       at: now.addingTimeInterval(-day - Double(i) * 60))
        }
        for i in 0..<2 {
            log.record(source: "browser", message: message, recovered: true,
                       at: now.addingTimeInterval(-Double(i) * 60))
        }

        let report = log.report(since: now.addingTimeInterval(-day), now: now)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.trend, .better(from: 10))
        XCTAssertEqual(report.trend, .better(from: 10))
        XCTAssertTrue(report.text.contains("Down from 10."), report.text)
    }

    /// A problem nobody has seen before is worth saying so about, and it cannot be expressed as
    /// a percentage of zero.
    func testAFirstSightingIsReportedAsNew() {
        let log = makeLog()
        let now = Date()
        log.record(source: "files", message: "Refused to touch /Users/k/.env: `.env` holds credentials.",
                   recovered: false, at: now.addingTimeInterval(-60))
        let report = log.report(since: now.addingTimeInterval(-3600), now: now)
        XCTAssertEqual(report.groups.first?.trend, .new)
        XCTAssertTrue(report.text.contains("New this period."), report.text)
    }

    /// Trading recoveries for dead ends is a period getting worse, even though the total fell.
    /// Measuring the trend on raw count would call this a large improvement.
    func testFewerFailuresButMoreDeadEndsReadsAsWorse() {
        let log = makeLog()
        let now = Date()
        let day: TimeInterval = 86_400
        for i in 0..<10 {
            log.record(source: "browser", message: "The browser is not running.", recovered: true,
                       at: now.addingTimeInterval(-day - Double(i) * 60))
        }
        for i in 0..<3 {
            log.record(source: "shell", message: "Refused: `/Users/k/p\(i)/.env` holds credentials. Nothing was run.",
                       recovered: false, at: now.addingTimeInterval(-Double(i) * 60))
        }

        let report = log.report(since: now.addingTimeInterval(-day), now: now)
        XCTAssertLessThan(report.total, report.previousTotal, "fewer failures overall")
        XCTAssertEqual(report.trend, .worse(from: 10), "but every one of them ended the run")
        XCTAssertTrue(report.text.contains("Worse."), report.text)
    }

    func testAnEmptyPeriodSaysSo() {
        let log = makeLog()
        let now = Date()
        let report = log.report(since: now.addingTimeInterval(-86_400), now: now)
        XCTAssertEqual(report.total, 0)
        XCTAssertTrue(report.text.contains("Nothing failed in the last 24 hours"), report.text)
    }

    // MARK: - Recovery

    /// The flag is written before anyone knows the answer, then amended. A run that dies before
    /// it can amend leaves the failure standing as a dead end, which is the honest reading.
    func testAnAmendmentTurnsAFailureIntoARecovery() {
        let log = makeLog()
        let now = Date()
        let id = log.record(source: "shell", message: "timed out after 30s", run: "r1", at: now)
        XCTAssertEqual(log.records().first?.recovered, false)

        log.markRecovered(id)
        XCTAssertEqual(log.records().count, 1, "an amendment is not a second failure")
        XCTAssertEqual(log.records().first?.recovered, true)

        let report = log.report(since: now.addingTimeInterval(-3600), now: now.addingTimeInterval(1))
        XCTAssertEqual(report.unrecovered, 0)
        XCTAssertEqual(report.groups.first?.recoveredCount, 1)
    }

    // MARK: - Redaction

    /// Failure messages quote the command that failed, and a command is exactly where a key
    /// ends up. The file is append-only, so a secret that reaches it cannot be taken back out.
    func testNoSecretReachesTheFile() {
        let literal = "postgres://bot:hunter2-correct-horse@db.internal:5432/prod"
        let log = makeLog(secrets: [literal])
        let patterned = "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGG1234"

        log.record(source: "shell",
                   message: "Refused: `psql \(literal)` failed, and the retry with "
                          + "Authorization: Bearer \(patterned) failed too.",
                   bot: "Scout", run: "r1")

        let raw = rawFile()
        XCTAssertFalse(raw.contains("hunter2-correct-horse"), "a literal secret reached the file")
        XCTAssertFalse(raw.contains(patterned), "a key-shaped secret reached the file")
        XCTAssertTrue(raw.contains("«redacted»"), "something should have been redacted:\n\(raw)")

        // The stored pattern is derived from the message, so it is a second way out of the file.
        let stored = log.records().first
        XCTAssertNotNil(stored)
        XCTAssertFalse(stored?.pattern.contains("hunter2-correct-horse") ?? true)
        XCTAssertFalse(stored?.message.contains(patterned) ?? true)
    }

    // MARK: - Damage

    /// A line nothing can read costs that line and nothing else. Treating it as the end of the
    /// file would throw away every later run for the sake of one bad write.
    func testACorruptLineDoesNotCostTheRestOfTheHistory() {
        let log = makeLog()
        let now = Date()
        log.record(source: "shell", message: "first", at: now.addingTimeInterval(-300))

        // A whole junk line in the middle, then a half-written one at the end: the second is
        // what a process killed mid-write actually leaves behind.
        let file = root.appendingPathComponent("failures.jsonl")
        let handle = try? FileHandle(forWritingTo: file)
        try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data("{ this is not json at all\n".utf8))
        try? handle?.close()

        log.record(source: "shell", message: "second", at: now.addingTimeInterval(-200))

        let tail = try? FileHandle(forWritingTo: file)
        try? tail?.seekToEnd()
        try? tail?.write(contentsOf: Data("{\"id\":\"truncated\",\"at\":".utf8))
        try? tail?.close()

        let read = log.load()
        XCTAssertEqual(read.records.map(\.message), ["first", "second"])
        XCTAssertEqual(read.unreadableLines, 2)

        let report = log.report(since: now.addingTimeInterval(-86_400), now: now)
        XCTAssertEqual(report.total, 2)
        XCTAssertTrue(report.text.contains("would not parse"),
                      "the report has to admit it skipped something:\n\(report.text)")
    }

    // MARK: - Pruning

    func testPruningKeepsTheNewest() {
        let log = makeLog()
        let now = Date()
        for i in 0..<5 {
            log.record(source: "shell", message: "failure \(i)",
                       at: now.addingTimeInterval(-Double(5 - i) * 60))
        }

        XCTAssertEqual(log.prune(keeping: 2), 2)
        XCTAssertEqual(log.records().map(\.message), ["failure 3", "failure 4"])
        XCTAssertEqual(rawFile().split(separator: "\n").count, 2,
                       "pruning has to shrink the file, not just the read")

        // The file is still a working log afterwards.
        log.record(source: "shell", message: "failure 5", at: now)
        XCTAssertEqual(log.records().map(\.message), ["failure 3", "failure 4", "failure 5"])
    }

    /// Pruning is also the repair path: it rewrites from what parsed, so an unreadable line
    /// leaves with it instead of sitting in the file forever. And a recovery recorded as an
    /// amendment must survive the rewrite, or pruning would quietly turn recoveries into dead
    /// ends and make every later report wrong.
    func testPruningDropsCorruptionAndKeepsAmendments() {
        let log = makeLog()
        let now = Date()
        let id = log.record(source: "shell", message: "kept", at: now.addingTimeInterval(-60))
        log.markRecovered(id)

        let handle = try? FileHandle(forWritingTo: root.appendingPathComponent("failures.jsonl"))
        try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data("garbage\n".utf8))
        try? handle?.close()
        XCTAssertEqual(log.load().unreadableLines, 1)

        XCTAssertEqual(log.prune(keeping: 10), 1)
        let after = log.load()
        XCTAssertEqual(after.unreadableLines, 0, "pruning should have taken the bad line with it")
        XCTAssertEqual(after.records.first?.recovered, true,
                       "the amendment has to survive as a folded-in value")
    }
}
