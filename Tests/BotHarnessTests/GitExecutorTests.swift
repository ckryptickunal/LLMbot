import XCTest
@testable import BotHarnessCore

/// What `GitExecutor` promises, stated as things that must stay impossible.
///
/// The two that matter are the reason the type exists at all: a commit message is never parsed by
/// a shell, and there is no argument path that force-pushes. Both are written as the hostile input
/// rather than as a happy path, so a later simplification of the argument builders fails here
/// instead of quietly handing the model a shell.
final class GitExecutorTests: XCTestCase {

    private var repo: URL!

    // MARK: - A throwaway repository

    override func setUpWithError() throws {
        try XCTSkipIf(GitExecutor.locateGit() == nil, "git is not installed on this machine")

        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-harness-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try rawGit(["init", "--quiet"])
        // Set locally, not globally: the test must not touch the user's own git identity, and a
        // machine whose global config has signing on would otherwise fail every commit here.
        try rawGit(["config", "user.email", "test@bot-harness.invalid"])
        try rawGit(["config", "user.name", "Bot Harness Test"])
        try rawGit(["config", "commit.gpgsign", "false"])
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    private var scopedToRepo: Authority {
        Authority(readable: [repo.path], writable: [repo.path])
    }

    /// git run directly, bypassing the executor, so the test can set the repository up and read
    /// back what actually landed in it.
    @discardableResult
    private func rawGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(GitExecutor.locateGit()))
        process.arguments = arguments
        process.currentDirectoryURL = repo
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func write(_ contents: String, to name: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - A commit message is text, never code

    func testACommitMessageWithShellMetacharactersReachesGitAsOneLiteralArgument() async throws {
        let canary = repo.appendingPathComponent("canary-must-not-exist.txt")
        try write("one", to: "file.txt")

        // Every shape that would execute if this message were ever pasted into a shell string:
        // command substitution in both spellings, a command separator, quotes that would end an
        // argument, and a newline.
        let message = """
        fix `touch \(canary.path)` and $(touch \(canary.path)); rm -rf . \
        with "double" and 'single' quotes
        """

        let git = GitExecutor(authority: scopedToRepo)
        _ = try await git.commit(cwd: repo.path, message: message)

        let recorded = try rawGit(["log", "-1", "--format=%B"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recorded, message, "the message git recorded is not the message that was passed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path),
                       "a command substitution inside the commit message was executed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("file.txt").path),
                      "`rm -rf .` inside the commit message was executed")
    }

    func testTheMessageIsExactlyOneElementOfTheArgumentArray() throws {
        let message = "$(whoami) `id` \"x\" ; echo pwned"
        let arguments = try GitExecutor.commitArguments(message: message)
        XCTAssertEqual(arguments, ["commit", "-m", message])
        XCTAssertEqual(arguments.filter { $0 == message }.count, 1,
                       "the message was split or duplicated across arguments")
    }

    func testAPathBeginningWithADashCannotBecomeAFlag() {
        // `--` ends git's option parsing, so a file called `-n` is staged rather than read as a
        // flag to `git add`.
        let arguments = GitExecutor.addArguments(paths: ["-n", "--dry-run", "src/main.swift"])
        XCTAssertEqual(arguments, ["add", "--", "-n", "--dry-run", "src/main.swift"])
        XCTAssertEqual(GitExecutor.addArguments(paths: nil), ["add", "-A"])
        XCTAssertEqual(GitExecutor.diffArguments(staged: true, path: "-p"), ["diff", "--cached", "--", "-p"])
    }

    // MARK: - Authority

    func testARepositoryOutsideTheBotsReadableAuthorityIsRefused() async {
        let git = GitExecutor(authority: Authority(readable: ["/tmp/somewhere-this-bot-was-given"],
                                                   writable: []))
        do {
            let output = try await git.status(cwd: repo.path)
            XCTFail("status was allowed outside the bot's authority and returned: \(output)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside"),
                          "unexpected refusal text: \(error.localizedDescription)")
        }
    }

    func testAReadableButNotWritableRepositoryRefusesACommit() async throws {
        try write("one", to: "file.txt")
        let git = GitExecutor(authority: Authority(readable: [repo.path], writable: []))

        // Reading is fine.
        _ = try await git.status(cwd: repo.path)

        do {
            let output = try await git.commit(cwd: repo.path, message: "should never land")
            XCTFail("committed into a read-only repository and returned: \(output)")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("writable"),
                          "unexpected refusal text: \(error.localizedDescription)")
        }
        XCTAssertTrue(try rawGit(["log", "--oneline"]).isEmpty, "a commit was created anyway")
    }

    func testABotWithNoPathsAtAllCanDoNothing() async {
        let git = GitExecutor(authority: Authority())
        do {
            _ = try await git.status(cwd: repo.path)
            XCTFail("a bot with no readable paths was allowed to read a repository")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no readable paths"),
                          "unexpected refusal text: \(error.localizedDescription)")
        }
    }

    // MARK: - Empty commit messages

    func testAnEmptyCommitMessageIsRefused() async throws {
        try write("one", to: "file.txt")
        let git = GitExecutor(authority: scopedToRepo)

        for message in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(try GitExecutor.commitArguments(message: message),
                                 "the builder accepted \(message.debugDescription)")
            do {
                _ = try await git.commit(cwd: repo.path, message: message)
                XCTFail("committed with an empty message: \(message.debugDescription)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("needs a message"),
                              "unexpected refusal text: \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(try rawGit(["log", "--oneline"]).isEmpty, "a commit was created anyway")
    }

    // MARK: - Force-pushing is unreachable

    func testNoArgumentPathCanProduceAForcePush() {
        // Both spellings git understands as force, plus the neighbours that are just as
        // destructive, plus the two shapes that would smuggle a second argument in.
        let hostile = [
            "--force", "-f", "--force-with-lease", "--force-if-includes",
            "+main", "+refs/heads/main:refs/heads/main", "+HEAD:main",
            "--mirror", "--delete", "-d", "--receive-pack=touch /tmp/pwned",
            "origin --force", "main\n--force", "\t-f",
        ]
        for value in hostile {
            XCTAssertThrowsError(try GitExecutor.pushArguments(remote: value, branch: nil),
                                 "accepted it as a remote: \(value.debugDescription)")
            XCTAssertThrowsError(try GitExecutor.pushArguments(remote: "origin", branch: value),
                                 "accepted it as a branch: \(value.debugDescription)")
            XCTAssertThrowsError(try GitExecutor.pushArguments(remote: value, branch: value),
                                 "accepted it as both: \(value.debugDescription)")
        }
    }

    func testNothingAPushBuildsEverBeginsWithADashOrAPlus() throws {
        for remote in [nil, "origin", "upstream"] {
            for branch in [nil, "main", "feature/thing", "release+1", "HEAD:main"] {
                guard let arguments = try? GitExecutor.pushArguments(remote: remote, branch: branch) else { continue }
                XCTAssertEqual(arguments.first, "push")
                for argument in arguments.dropFirst() {
                    XCTAssertFalse(argument.hasPrefix("-"), "option-shaped argument: \(argument)")
                    XCTAssertFalse(argument.hasPrefix("+"), "force refspec: \(argument)")
                }
            }
        }
    }

    func testAnOrdinaryPushBuildsThePlainCommand() throws {
        XCTAssertEqual(try GitExecutor.pushArguments(remote: nil, branch: nil), ["push"])
        XCTAssertEqual(try GitExecutor.pushArguments(remote: "origin", branch: "main"), ["push", "origin", "main"])
        XCTAssertEqual(try GitExecutor.pushArguments(remote: "upstream", branch: nil), ["push", "upstream"])
        // A branch with no remote is meaningless to git, so `origin` is filled in rather than
        // refused — a refusal there would teach the model nothing it could act on.
        XCTAssertEqual(try GitExecutor.pushArguments(remote: nil, branch: "main"), ["push", "origin", "main"])
    }

    // MARK: - It actually works

    func testStatusAndDiffReportRealChanges() async throws {
        try write("one\n", to: "file.txt")
        let git = GitExecutor(authority: scopedToRepo)

        let untracked = try await git.status(cwd: repo.path)
        XCTAssertTrue(untracked.contains("file.txt"), "status did not mention the new file: \(untracked)")

        _ = try await git.commit(cwd: repo.path, message: "add file")
        try write("one\ntwo\n", to: "file.txt")

        let diff = try await git.diff(cwd: repo.path)
        XCTAssertTrue(diff.contains("+two"), "diff did not show the added line: \(diff)")

        let stagedDiff = try await git.diff(cwd: repo.path, staged: true)
        XCTAssertTrue(stagedDiff.isEmpty, "nothing is staged, so the staged diff should be empty")
    }

    func testAFailingGitCommandReturnsGitsOwnWords() async throws {
        let git = GitExecutor(authority: scopedToRepo)
        do {
            // Nothing has changed, so git refuses with exit 1 and an explanation on stdout.
            let output = try await git.commit(cwd: repo.path, message: "nothing to say")
            XCTFail("an empty commit was reported as success: \(output)")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("nothing to commit"),
                          "git's own reason was lost: \(error.localizedDescription)")
        }
    }
}
