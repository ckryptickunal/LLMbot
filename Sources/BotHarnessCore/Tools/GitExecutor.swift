import Foundation

/// Running `git`, as an argument array, inside a repository the bot is actually allowed to touch.
///
/// This exists rather than letting the model reach for `shell.exec "git commit -m …"`, for two
/// reasons a shell cannot give us:
///
/// 1. **A commit message is text, not code.** Through a shell, a message containing backticks or
///    `$(…)` is a command substitution the shell runs *before* git ever sees it — and a commit
///    message is the one place an agent routinely pastes prose it did not write: a bug report, a
///    user's own words, a chunk of a diff. Here the message is one element of an `arguments`
///    array and no shell is involved, so `$(rm -rf ~)` commits those nine characters and nothing
///    happens.
/// 2. **Force-pushing is unreachable.** `push` takes a remote and a branch and nothing else.
///    There is no flags parameter to smuggle `--force` through, and the two values that do exist
///    are checked for the shapes git reads as force. The permission floor calls history rewriting
///    a floor concern (`FloorCategory.rewritingSharedHistory`); a floor concern should not be
///    reachable at all from a tool, only from the user's own terminal.
///
/// What this is *not*: a replacement for the shell. Anything beyond these four operations still
/// goes through `shell.exec`, where the shell guard and the permission engine apply. The point of
/// this type is that the four operations an agent performs constantly are the four where a shell
/// is both unnecessary and dangerous.
public actor GitExecutor {

    /// What this bot may touch. Reads are judged against `readable`, writes against `writable`,
    /// exactly as `FileExecutor` does — a bot that may read a repository is not thereby allowed
    /// to commit to it.
    private let authority: Authority

    public init(authority: Authority = Authority()) { self.authority = authority }

    // MARK: - Finding git

    /// Where git is looked for, in the order the machine prefers it.
    ///
    /// Deliberately absolute paths rather than a `PATH` search: we never spawn a shell, so there
    /// is no `which`, and resolving an executable out of an inherited `PATH` would let a
    /// workspace `.envrc` or a poisoned directory decide what "git" means.
    private static let candidatePaths = [
        "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ]

    static func locateGit() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let notInstalled =
        "git is not installed anywhere this app looks (/usr/bin/git, /opt/homebrew/bin/git, "
        + "/usr/local/bin/git). Install Apple's command line tools by running `xcode-select --install` "
        + "in Terminal, then try this again."

    // MARK: - Operations

    /// Argument names mirror `git.status` in `BuiltInTools`, which passes `cwd`.
    public func status(cwd: String) async throws -> String {
        let repository = try await resolveRepository(cwd, forWriting: false)
        // `--short --branch` because the long form is three paragraphs of advice a model does not
        // need and pays tokens for. The short form is the branch, the ahead/behind count, and one
        // line per changed file, which is the whole of what the tool promises.
        return try await report(["status", "--short", "--branch"], in: repository, timeout: 30)
    }

    /// Mirrors `git.diff`: `cwd`, `staged`, `path`.
    public func diff(cwd: String, staged: Bool = false, path: String? = nil) async throws -> String {
        let repository = try await resolveRepository(cwd, forWriting: false)
        let output = try await report(Self.diffArguments(staged: staged, path: path),
                                      in: repository, timeout: 60)
        return Self.capped(output)
    }

    /// Mirrors `git.commit`: `cwd`, `message`, `paths`.
    ///
    /// Two invocations rather than `commit -a`, because `-a` silently ignores new files and an
    /// agent that "committed" without including the file it just created has told the user
    /// something untrue.
    public func commit(cwd: String, message: String, paths: [String]? = nil) async throws -> String {
        let repository = try await resolveRepository(cwd, forWriting: true)
        let commitArguments = try Self.commitArguments(message: message)

        let staged = try await run(Self.addArguments(paths: paths), in: repository, timeout: 60)
        guard staged.exitCode == 0 else { throw GitError.failed(Self.failureText(staged)) }

        let committed = try await run(commitArguments, in: repository, timeout: 60)
        guard committed.exitCode == 0 else { throw GitError.failed(Self.failureText(committed)) }
        return redacted(Self.joined(committed))
    }

    /// Mirrors `git.push`: `cwd`, `remote`, `branch`. There is no third parameter and there will
    /// not be one — see `pushArguments`.
    public func push(cwd: String, remote: String? = nil, branch: String? = nil) async throws -> String {
        let repository = try await resolveRepository(cwd, forWriting: true)
        let arguments = try Self.pushArguments(remote: remote, branch: branch)
        // Longer than the others on purpose: a push to a slow remote is normal, and killing it
        // halfway leaves the user unsure whether the commits landed.
        return try await report(arguments, in: repository, timeout: 180)
    }

    // MARK: - Argument construction

    // These are static and pure so the tests can enumerate hostile inputs against them without
    // spawning anything. The guarantee this type makes is a property of these functions, and a
    // guarantee that can only be tested by running git is one nobody tests.

    static func statusArguments() -> [String] { ["status", "--short", "--branch"] }

    static func diffArguments(staged: Bool, path: String?) -> [String] {
        var arguments = ["diff"]
        if staged { arguments.append("--cached") }
        // `--` ends option parsing, so a file literally named `-p` is a path and not a flag.
        if let path, !path.isEmpty { arguments += ["--", path] }
        return arguments
    }

    static func addArguments(paths: [String]?) -> [String] {
        guard let paths, !paths.isEmpty else { return ["add", "-A"] }
        return ["add", "--"] + paths
    }

    static func commitArguments(message: String) throws -> [String] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitError.refused(
                "A commit needs a message. Pass `message` with a sentence saying what changed and "
                + "why — an empty message makes the history useless to whoever reads it next. "
                + "Nothing was committed.")
        }
        // The untrimmed message is what gets committed: leading blank lines are the author's
        // choice and trimming is only how emptiness is judged.
        return ["commit", "-m", message]
    }

    /// The whole force-push guarantee lives here.
    ///
    /// Two spellings force a push and only one is obvious. `--force` and `-f` start with a dash,
    /// so refusing a leading dash catches them — but `git push origin +main` force-pushes too,
    /// because a leading `+` on a refspec *means* force. A guard that searched for the word
    /// "force" would wave that straight through, and the commits it destroys belong to other
    /// people. Refusing both shapes, and refusing whitespace so one argument cannot become two,
    /// leaves no argument path to a force push at all.
    static func pushArguments(remote: String?, branch: String?) throws -> [String] {
        var arguments = ["push"]

        let cleanRemote = try remote.map { try checkedRefName($0, field: "remote") }
        let cleanBranch = try branch.map { try checkedRefName($0, field: "branch") }

        if let cleanBranch {
            // A branch without a remote is meaningless to git, and defaulting to `origin` is what
            // the user means every time. Guessing here beats a refusal that teaches nothing.
            arguments += [cleanRemote ?? "origin", cleanBranch]
        } else if let cleanRemote {
            arguments.append(cleanRemote)
        }
        // Neither given: a bare `git push` uses the branch's configured upstream, which is right
        // far more often than any remote this code could invent.

        // Belt and braces. If either check above is ever loosened, this still refuses rather than
        // force-pushes: no argument in a push may open with a dash or a plus.
        if let smuggled = arguments.dropFirst().first(where: { $0.hasPrefix("-") || $0.hasPrefix("+") }) {
            throw GitError.refused(Self.forceRefusal(smuggled))
        }
        return arguments
    }

    private static func checkedRefName(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitError.refused("`\(field)` was empty. Give a name like `origin` or `main`, or leave it out "
                                   + "entirely to use the branch's configured upstream. Nothing was pushed.")
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw GitError.refused("`\(value)` is not a single \(field) name. Git remotes and branches contain no "
                                   + "spaces, and passing several words here would turn one argument into two. "
                                   + "Nothing was pushed.")
        }
        guard !trimmed.hasPrefix("-"), !trimmed.hasPrefix("+") else {
            throw GitError.refused(forceRefusal(trimmed))
        }
        return trimmed
    }

    private static func forceRefusal(_ value: String) -> String {
        "`\(value)` is not a remote or a branch name. This tool cannot force-push in any form — not "
        + "`--force`, not `--force-with-lease`, not the `+branch` refspec — because a force push "
        + "destroys commits other people already have and there is no undo for it on the remote. "
        + "Nothing was pushed. If history genuinely has to be rewritten, ask the user to do it in "
        + "their own terminal."
    }

    // MARK: - Scope

    /// The directory git will actually be run in, once it is known to be inside this bot's reach.
    ///
    /// Two checks, and the second is the one that matters. Checking `cwd` alone is not enough:
    /// git walks *up* from the working directory to find the repository, so a bot granted
    /// `~/Projects/app/src` could commit to the repository rooted at `~/Projects/app` and change
    /// files it was never given. `git rev-parse --show-toplevel` asks git where the repository
    /// really is, and that answer is judged too.
    private func resolveRepository(_ cwd: String, forWriting: Bool) async throws -> String {
        let given = try scoped(cwd, forWriting: forWriting, describing: "The directory")

        let top = try await run(["rev-parse", "--show-toplevel"], in: given, timeout: 20)
        guard top.exitCode == 0 else { throw GitError.failed(Self.failureText(top)) }
        let toplevel = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toplevel.isEmpty else {
            throw GitError.failed("git could not say where the repository rooted at `\(given)` begins. "
                                  + "Check that `\(given)` is a checked-out repository.")
        }
        if PathGuard.canonical(toplevel) == PathGuard.canonical(given) { return given }
        return try scoped(toplevel, forWriting: forWriting, describing: "The repository holding `\(cwd)` is rooted at")
    }

    /// One path, judged against the floor and then against the contract. Same order and same
    /// reasoning as `FileExecutor.resolve`: the floor is checked separately and always, because
    /// an `Authority` decoded from a `state.json` written last week does not know about paths
    /// that joined the floor since.
    ///
    /// Note what is deliberately *absent*: the scratch and system allowances `ShellExecutor`
    /// grants. Those exist so a bot can run a compiler; a repository is the user's work, not
    /// machinery, and there is no reason for a bot to commit to one it was not given.
    private func scoped(_ path: String, forWriting: Bool, describing subject: String) throws -> String {
        let expanded = PathGuard.expand(path)
        guard !expanded.isEmpty else {
            throw GitError.refused("No repository path was given. Pass `cwd` with the directory of the "
                                   + "repository to work in.")
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let real = (standardized as NSString).resolvingSymlinksInPath

        if let hit = PathGuard.denied(real, by: Authority.alwaysDenied) {
            throw GitError.refused("`\(hit)` holds credentials, and no bot may read it. Nothing was run.")
        }
        if forWriting, let hit = PathGuard.denied(real, by: Authority.alwaysDeniedForWriting) {
            throw GitError.refused("`\(hit)` is the app's own record and must stay as written. Nothing was run.")
        }
        if let hit = PathGuard.denied(real, by: authority.denied) {
            throw GitError.refused("`\(hit)` is on this bot's never-allowed list. Nothing was run.")
        }

        let allowed = forWriting ? authority.writable : authority.readable
        guard !allowed.isEmpty else {
            throw GitError.refused(forWriting
                ? "This bot has no writable paths, so it cannot commit or push anywhere. Ask the user to "
                  + "give it a workspace first. Nothing was run."
                : "This bot has no readable paths, so it cannot look at any repository. Ask the user to "
                  + "give it a workspace first. Nothing was run.")
        }
        guard allowed.contains(where: { PathGuard.isInside(real, $0) }) else {
            throw GitError.refused(forWriting
                ? "\(subject) `\(real)`, which is outside this bot's workspace. It may only change "
                  + "repositories inside the paths it was given. Nothing was run."
                : "\(subject) `\(real)`, which is outside the paths this bot was given to read. "
                  + "Nothing was run.")
        }
        return real
    }

    // MARK: - Running

    /// Run git and return its output, or throw with git's own words.
    private func report(_ arguments: [String], in directory: String, timeout: TimeInterval) async throws -> String {
        let output = try await run(arguments, in: directory, timeout: timeout)
        guard output.exitCode == 0 else { throw GitError.failed(Self.failureText(output)) }
        return redacted(Self.joined(output))
    }

    /// The one place a git process is created. No shell, ever: `arguments` is handed to
    /// `posix_spawn` as `argv`, so quoting, `$(…)`, backticks, `;` and newlines inside any element
    /// are bytes and not syntax.
    private func run(_ arguments: [String], in directory: String, timeout: TimeInterval) async throws -> CommandOutput {
        guard let executable = Self.locateGit() else { throw GitError.unavailable(Self.notInstalled) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitError.refused("There is no directory at `\(directory)`. Pass `cwd` the path of a "
                                   + "checked-out repository. Nothing was run.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // `--no-pager` guards the case where git decides stdout is interactive; a pager waiting
        // for a keypress would hang until the timeout and report nothing useful.
        process.arguments = ["--no-pager"] + arguments
        process.environment = Self.childEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // Nothing may prompt. Without this, a push needing a passphrase blocks until the timeout
        // and then says "timed out", which tells the user nothing about what to fix.
        process.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            throw GitError.unavailable("git could not be started: \(error.localizedDescription). " + Self.notInstalled)
        }

        // Drained on background threads rather than read to EOF here, for the same reason
        // `ShellExecutor` does it: a diff larger than the 64KB pipe buffer deadlocks a process
        // that is being waited on before its output is read.
        let collector = ShellExecutor.OutputCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var cancelled = false
        while process.isRunning && Date() < deadline {
            if Task.isCancelled { cancelled = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let timedOut = process.isRunning && !cancelled
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { try? await Task.sleep(for: .milliseconds(20)) }
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        if cancelled {
            throw GitError.failed("git \(arguments.first ?? "") was stopped before it finished. Whether it "
                                  + "took effect is unknown — run `git status` before trying again.")
        }
        if timedOut {
            throw GitError.failed("git \(arguments.first ?? "") did not finish within \(Int(timeout))s and was "
                                  + "stopped. If this was a push, the remote may be unreachable; check the "
                                  + "network, or run the command yourself to see what it is waiting on.")
        }
        return CommandOutput(exitCode: process.terminationStatus,
                             stdout: collector.stdout(),
                             stderr: collector.stderr())
    }

    /// The child's environment: the user's secrets stripped, plus everything that stops git
    /// waiting for a human who is not there.
    ///
    /// Reuses `ShellExecutor.sanitisedEnvironment()` rather than copying it, so the list of
    /// credential-shaped variable names has exactly one home. One consequence is worth stating
    /// plainly: that helper drops `SSH_AUTH_SOCK` (it matches on `AUTH`), so git here cannot use
    /// keys held only in the user's ssh-agent. Pushes over HTTPS with a credential helper, and
    /// over SSH with a key file ssh can read on its own, both still work; an agent-only key fails,
    /// and `explain` turns that failure into a sentence saying so.
    static func childEnvironment() -> [String: String] {
        var environment = ShellExecutor.sanitisedEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_PAGER"] = "cat"
        return environment
    }

    // MARK: - Output

    private func redacted(_ text: String) -> String {
        let redactor = StreamingRedactor.forRun()
        guard !redactor.isEmpty else { return text }
        // A diff can contain a key the user pasted into a file and is now removing. Redacting
        // here means the model reads `«redacted»` instead of a live credential.
        return redactor.redact(text)
    }

    private static func joined(_ output: CommandOutput) -> String {
        [output.stdout, output.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// What git said when it failed.
    ///
    /// stderr first because that is where git puts errors, but stdout is not discarded: "nothing
    /// to commit, working tree clean" is an exit-1 message printed on *stdout*, and dropping it
    /// would leave the model with a failure and no reason for it.
    private static func failureText(_ output: CommandOutput) -> String {
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = stderr.isEmpty ? stdout : stderr
        guard !detail.isEmpty else {
            return "git exited with status \(output.exitCode) and said nothing. Run the same command in a "
                 + "terminal to see what it is unhappy about."
        }
        return explain(detail)
    }

    /// Add the sentence git cannot know to write, where its message names a cause that is ours.
    private static func explain(_ detail: String) -> String {
        if detail.contains("xcode-select") || detail.contains("no developer tools") {
            return detail + "\n\n" + notInstalled
        }
        if detail.contains("could not read Username") || detail.contains("terminal prompts disabled") {
            return detail + "\n\nThis tool never prompts for credentials, so a remote that asks for a username "
                 + "and password cannot be pushed to from here. Ask the user to configure a git credential "
                 + "helper, or to push this one themselves."
        }
        if detail.contains("Permission denied (publickey)") {
            return detail + "\n\nGit runs here without the user's ssh-agent, so a key held only in the agent is "
                 + "not available to it. This needs a key file ssh can read on its own, or the user pushing "
                 + "this one themselves."
        }
        if detail.contains("Please tell me who you are") {
            return detail + "\n\nThis is the user's git identity, not something a bot should set for them. Ask "
                 + "them to run `git config --global user.email` and `user.name` once."
        }
        return detail
    }

    /// A diff of a large change can be megabytes, and pasting that into the conversation costs
    /// more than the diff is worth and crowds out everything else the model needs to remember.
    private static func capped(_ text: String, limit: Int = 100_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
             + "\n\n… diff truncated at \(limit) characters. Pass `path` to look at one file at a time, or "
             + "`staged` to separate what is staged from what is not."
    }

    // MARK: - Errors

    public enum GitError: LocalizedError {
        /// The bot was not allowed to do this. Nothing ran.
        case refused(String)
        /// git ran and said no. Carries git's own words.
        case failed(String)
        /// git is not usable on this machine.
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .refused(let why):    return "Refused: " + why
            case .failed(let detail):  return detail
            case .unavailable(let why): return why
            }
        }
    }
}
