import Foundation

/// Running commands, and keeping processes alive across turns.
///
/// The second half is the point. `exec(command) → wait → output` cannot run `npm run dev`:
/// either the agent blocks forever waiting for a server that never exits, or it kills the
/// thing it just started. An agent that cannot start a server and then go look at the page it
/// serves is not much of a computer agent, so processes are first-class here.
public actor ShellExecutor: CommandRunning {

    private var processes: [String: Running] = [:]

    /// What this bot may touch. The shell used to have none, which meant the whole per-bot
    /// readable/writable boundary evaporated the moment a bot ran `cat` instead of `files.read`.
    private let authority: Authority

    public init(authority: Authority = Authority()) { self.authority = authority }

    // MARK: - Scope

    /// Paths every bot may use regardless of its workspace, because refusing them refuses the
    /// tooling itself rather than the bot's reach.
    ///
    /// `/tmp` and `TMPDIR` are here because compilers, package managers and `git` all stage work
    /// there; the system prefixes are here because running `python3` or `node` at all means
    /// reading them. This is an allowance for *machinery*, not for the user's data — nothing
    /// under `~` is on it, and the deny floor is checked before it either way.
    private static let systemReadable: [String] = [
        "/usr/**", "/bin/**", "/sbin/**", "/opt/**", "/Library/**", "/System/**",
        "/Applications/**", "/private/etc/**", "/etc/**", "/dev/**", "/proc/**",
    ]
    private static var scratchWritable: [String] {
        ["/tmp/**", "/private/tmp/**", "/var/folders/**", "/private/var/folders/**",
         "/dev/null", "/dev/stdout", "/dev/stderr",
         NSTemporaryDirectory() + "**"]
    }

    /// Why a command was refused, or nil if it may run.
    ///
    /// Three separate questions, in order of how certain the answer is:
    ///
    /// 1. **The floor** — does anything in this command touch a path no bot may ever read? This
    ///    is checked against parsed operands, against redirect targets, against the raw text (so
    ///    `@$HOME/…` and other punctuation-wrapped forms are seen), and — for commands that copy
    ///    or archive whole trees — against *containers* of a protected path, so `cp -r` of the
    ///    parent directory is caught without ever naming the file.
    /// 2. **Write scope** — does it write outside what the bot may write?
    /// 3. **Read scope** — does it name an absolute path outside what the bot may read?
    ///
    /// What this is not: a sandbox. A path assembled at runtime (`P=$HOME; cat "$P/x"`) is
    /// invisible to any amount of string work, and pretending otherwise would be the same
    /// theatre the old guard was. Real containment needs the process to run under a profile that
    /// cannot open the file at all; this is defence in depth in front of that, not a substitute.
    func refusal(for command: String, cwd: String?) -> String? {
        let parse = ShellCommandParser.parse(command)
        let bulk = parse.commands.contains { Authority.bulkExecutables.contains($0.executable) }

        // 1. The floor.
        if let hit = Self.floorHit(parse, raw: command, bulk: bulk) {
            return "`\(hit)` holds credentials, and no bot may read it. Nothing was run."
        }

        // 2. An interpreter is a hole no amount of operand analysis closes.
        //
        // `python3 -c "print(open('/Users/…/secret').read())"` was allowed and printed the file:
        // the path lives inside a code string that does not begin with `/`, so nothing judged it.
        // `node -e "…process.env.HOME…"` was worse — it kept the literal home path off the command
        // line entirely, so even the raw-text floor scan saw nothing, and the keys came back
        // base64-encoded where value-redaction cannot reach them.
        //
        // Scanning the code string for paths (below) catches the first form and not the second,
        // and no version of that catches a path the interpreter assembles at runtime. So an
        // interpreter that is handed a program on the command line is refused outright when the
        // bot is scoped to anything narrower than the whole disk. That is a real cost — it blocks
        // a legitimate `python3 -c` one-liner — and it is the honest trade: the alternative is a
        // boundary that is decorative for anyone who knows to type `node -e`.
        if let executable = Self.inlineInterpreter(parse), !Self.hasWholeDiskRead(authority) {
            return "`\(executable)` runs a program given on the command line, and what that program "
                 + "reads cannot be checked before it runs. Use the file tools, or put the script in "
                 + "a file inside the workspace and run that. Nothing was run."
        }

        // 3. Writes. Relative targets resolve against the directory the command will actually run
        //    in, not against this process's. A GUI app's working directory is "/", so `echo x >
        //    out.txt` in a bot's own workspace was being judged as a write to `/out.txt` and
        //    refused — every relative write, copy, move and chmod inside the workspace was blocked
        //    while the same operation spelled absolutely was allowed.
        let base = cwd.map { PathGuard.expand($0) }
        for path in ShellFloor.pathsWrittenBy(parse).map({ Self.resolve($0, against: base) }) {
            if let hit = PathGuard.denied(path, by: Authority.alwaysDeniedForWriting) {
                return "`\(hit)` is the app's own record and must stay as written. Nothing was run."
            }
            if !Self.isWritable(path, authority: authority) {
                return "this bot may only write inside its workspace, and `\(path)` is outside it. Nothing was run."
            }
        }

        // 4. Reads. Absolute paths anywhere in the command, including ones embedded inside a
        //    quoted argument — an operand does not have to *start* with `/` to name a file.
        for candidate in Self.readCandidates(parse, base: base) {
            if !Self.isReadable(candidate, authority: authority) {
                return "this bot may only read inside the paths you gave it, and `\(candidate)` is outside them. Nothing was run."
            }
        }
        return nil
    }

    /// The refusal reason, for tests. Running the command would be a slower and less precise way
    /// of asking the same question.
    public func refusalForTesting(_ command: String, cwd: String?) -> String? {
        refusal(for: command, cwd: cwd)
    }

    /// Interpreters being handed a program inline, rather than a file to run.
    static func inlineInterpreter(_ parse: ShellParse) -> String? {
        // `swift` is deliberately absent. `swift build -c release` uses `-c` for the build
        // configuration, so including it would refuse the most ordinary command in this very
        // repository — the exact "guard that blocks real work" failure this pass exists to avoid.
        // Its inline form (`swift -e`) is rare enough not to be worth that.
        let interpreters: Set<String> = [
            "python", "python3", "node", "nodejs", "deno", "bun", "ruby", "perl", "php",
            "osascript", "lua", "Rscript", "tclsh",
        ]
        for command in parse.commands where interpreters.contains(command.executable) {
            // `-c`, `-e`, `-r`: the flags that mean "here is the program". A path to a script is
            // fine and is checked like any other operand — it is the inline text that cannot be.
            if command.hasFlag("c", "e", "r", "eval", "command") { return command.executable }
        }
        return nil
    }

    /// A bot that may already read everything has nothing left for this rule to protect.
    private static func hasWholeDiskRead(_ authority: Authority) -> Bool {
        authority.readable.contains { PathGuard.stem(of: $0) == "/" }
    }

    /// Resolve a possibly-relative path against the directory the command runs in.
    static func resolve(_ path: String, against base: String?) -> String {
        let expanded = PathGuard.expand(path)
        guard !expanded.hasPrefix("/") else { return expanded }
        guard let base else { return expanded }
        return URL(fileURLWithPath: base).appendingPathComponent(expanded).path
    }

    /// Absolute paths named anywhere in the command, plus relative operands resolved against cwd.
    ///
    /// Extracting from *inside* an argument matters: `find . -exec cat /etc/passwd {} ;` and
    /// `awk '{print}' /Users/x/secret` both hide a path behind punctuation or quoting that leaves
    /// the operand not starting with a slash.
    static func readCandidates(_ parse: ShellParse, base: String?) -> [String] {
        var out: [String] = []
        for command in parse.commands {
            for argument in command.operands + command.redirects.map({ $0.target }) {
                let value = argument.value
                guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("://") else { continue }
                let expanded = PathGuard.expand(value)
                if expanded.hasPrefix("/") {
                    out.append(expanded)
                } else {
                    out += Self.embeddedAbsolutePaths(in: expanded)
                }
            }
        }
        return out
    }

    /// Absolute-looking paths embedded inside a larger string.
    ///
    /// Deliberately conservative: it needs at least two path components so that a bare `/` or a
    /// division sign in an expression is not mistaken for a file.
    static func embeddedAbsolutePaths(in text: String) -> [String] {
        var found: [String] = []
        var current = ""
        var collecting = false
        // A tiny scanner rather than a regex, because the terminators are quote characters and
        // a regex for "path until a quote or whitespace" is harder to read than this is.
        for character in text {
            if collecting {
                if character.isWhitespace || character == "\"" || character == "'" || character == ")" {
                    if current.filter({ $0 == "/" }).count >= 2 { found.append(current) }
                    current = ""; collecting = false
                } else {
                    current.append(character)
                }
            } else if character == "/" {
                collecting = true
                current = "/"
            }
        }
        if collecting, current.filter({ $0 == "/" }).count >= 2 { found.append(current) }
        return found
    }

    private static func floorHit(_ parse: ShellParse, raw: String, bulk: Bool) -> String? {
        if let hit = ShellFloor.readsTheKeyStore(parse, raw: raw, bulk: bulk) { return hit }
        return nil
    }

    private static func isReadable(_ path: String, authority: Authority) -> Bool {
        if authority.readable.contains(where: { PathGuard.isInside(path, $0) }) { return true }
        if authority.writable.contains(where: { PathGuard.isInside(path, $0) }) { return true }
        if systemReadable.contains(where: { PathGuard.isInside(path, $0) }) { return true }
        if scratchWritable.contains(where: { PathGuard.isInside(path, $0) }) { return true }
        return false
    }

    private static func isWritable(_ path: String, authority: Authority) -> Bool {
        if authority.writable.contains(where: { PathGuard.isInside(path, $0) }) { return true }
        if scratchWritable.contains(where: { PathGuard.isInside(path, $0) }) { return true }
        return false
    }

    /// Every operand and redirect target in the command, expanded. Flags, URLs and bare
    /// non-path words are dropped — they are not paths and judging them produces false refusals.
    static func namedPaths(_ parse: ShellParse) -> [String] {
        var out: [String] = []
        for command in parse.commands {
            for argument in command.operands + command.redirects.map({ $0.target }) {
                let value = argument.value
                guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("://") else { continue }
                guard value.contains("/") || value.hasPrefix("~") || value.hasPrefix("$HOME") else { continue }
                out.append(PathGuard.expand(value))
            }
        }
        for redirect in parse.redirects where !redirect.target.value.isEmpty {
            out.append(PathGuard.expand(redirect.target.value))
        }
        return out
    }

    // MARK: - Secrets

    /// Two guards, because one is not enough and neither alone is honest.
    ///
    /// `FileExecutor` refuses to read the credential file, but the shell is a second door into
    /// the same filesystem: `cat ~/Library/Application\ Support/Bot-Harness/credentials.json`
    /// never touches `FileExecutor` at all. While keys lived in the keychain this did not
    /// matter, because the shell could not read them either. Now it would, so:
    ///
    /// 1. **A path guard** refuses a command whose parsed arguments name a floor path. It sees
    ///    real arguments rather than a substring, so quoting and flag order do not fool it —
    ///    but a path assembled at runtime, from a variable or a `cd`, still gets through. A
    ///    guard that claimed otherwise would be theatre.
    /// 2. **Output redaction** catches what the path guard cannot. It matches on the *value* of
    ///    each key, so a read that evades the path check still returns `«redacted»` rather than
    ///    a usable secret. This is the guard that actually holds, because it does not depend on
    ///    predicting how the file gets opened.
    ///
    /// What neither stops is an obfuscated read — `base64`, `xxd`, reading byte ranges — whose
    /// output does not contain the literal key. That residual risk is recorded in
    /// `docs/decisions/0012-credentials-live-in-an-owner-only-file.md` rather than papered over.

    public enum ShellError: LocalizedError {
        case refused(String)
        public var errorDescription: String? {
            switch self {
            case .refused(let why): return "Refused: " + why
            }
        }
    }

    /// The offending path, if the command names one no bot may read.
    ///
    /// Delegates to the same parser the permission floor uses, rather than searching the raw
    /// string. A substring search would refuse `cat ./credentials.json` in someone's own
    /// project — that name is common, and a guard that fires on ordinary work is one people
    /// learn to route around.
    static func forbiddenPath(in command: String) -> String? {
        ShellFloor.readsTheKeyStore(ShellCommandParser.parse(command), raw: command)
    }

    private func guarded(_ output: CommandOutput) -> CommandOutput {
        let redactor = StreamingRedactor.forRun()
        guard !redactor.isEmpty else { return output }
        return CommandOutput(exitCode: output.exitCode,
                             stdout: redactor.redact(output.stdout),
                             stderr: redactor.redact(output.stderr))
    }

    private final class Running: @unchecked Sendable {
        let process: Process
        let name: String
        let command: String
        let started = Date()
        private let lock = NSLock()
        private var stdoutBuffer = ""
        private var stderrBuffer = ""
        /// How far the agent has already read, so each look returns only what is new.
        private var stdoutCursor = 0
        private var stderrCursor = 0

        init(process: Process, name: String, command: String) {
            self.process = process; self.name = name; self.command = command
        }

        func appendOut(_ s: String) { lock.lock(); stdoutBuffer += s; lock.unlock() }
        func appendErr(_ s: String) { lock.lock(); stderrBuffer += s; lock.unlock() }

        /// New output only.
        ///
        /// State diffing at its simplest, and it matters: re-sending a dev server's entire
        /// log on every turn is how a long run becomes expensive for no information gained.
        func drain() -> (out: String, err: String) {
            lock.lock(); defer { lock.unlock() }
            let out = String(stdoutBuffer.dropFirst(stdoutCursor))
            let err = String(stderrBuffer.dropFirst(stderrCursor))
            stdoutCursor = stdoutBuffer.count
            stderrCursor = stderrBuffer.count
            return (out, err)
        }

        var isRunning: Bool { process.isRunning }
        var exitCode: Int32? { process.isRunning ? nil : process.terminationStatus }
    }

    // MARK: - One-shot

    /// Run a command and wait. `CommandRunning`, so the verifier can use it directly.
    public func run(_ command: String) async -> CommandOutput {
        await run(command, cwd: nil, timeout: 120)
    }

    public func run(_ command: String, cwd: String?, timeout: TimeInterval) async -> CommandOutput {
        if let why = refusal(for: command, cwd: cwd) {
            return CommandOutput(exitCode: 126, stdout: "", stderr: "Refused: " + why)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-l` is deliberately gone. A login shell sources `.zprofile`/`.zshrc`, which on a
        // developer's Mac exports API keys, tokens and cloud credentials into the environment —
        // so `env` handed a bot every secret the user has, and no path guard was ever involved.
        // `-c` keeps the user's PATH (inherited) without dumping their dotfile secrets.
        process.arguments = ["-c", command]
        process.environment = Self.sanitisedEnvironment()
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: PathGuard.expand(cwd)) }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return CommandOutput(exitCode: 127, stdout: "", stderr: "could not start: \(error.localizedDescription)")
        }

        // Drained on background threads rather than read to EOF on this one.
        //
        // The old code called `readToEnd()` before the timeout loop. That blocks until the pipe
        // closes, which for anything long-lived means *never* — so the timeout below was dead
        // code, `npm run dev` or `tail -f` hung the entire run forever, and the process was
        // never reaped. Reading concurrently is also what keeps a chatty command from deadlocking
        // on a full 64KB pipe buffer while we wait for it to exit.
        let collector = OutputCollector()
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
            try? await Task.sleep(for: .milliseconds(25))
        }

        let timedOut = process.isRunning && !cancelled
        if process.isRunning {
            // SIGTERM, a moment to exit cleanly, then SIGKILL. Terminating without the follow-up
            // leaves anything that traps SIGTERM running after we have stopped watching it.
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { try? await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        if cancelled {
            return guarded(CommandOutput(exitCode: 125, stdout: collector.stdout(),
                                         stderr: "stopped"))
        }
        if timedOut {
            return guarded(CommandOutput(exitCode: 124, stdout: collector.stdout(),
                                         stderr: "timed out after \(Int(timeout))s"))
        }
        return guarded(CommandOutput(exitCode: process.terminationStatus,
                                     stdout: collector.stdout(),
                                     stderr: collector.stderr()))
    }

    /// The child's environment, with the user's own secrets removed.
    ///
    /// A developer's shell exports `OPENAI_API_KEY`, `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN` and
    /// the rest. Those belong to the user, not to a bot, and `env` printed all of them. Anything
    /// whose name looks like a credential is dropped; the redactor cannot help here because it
    /// only knows the keys *this app* stores.
    static func sanitisedEnvironment() -> [String: String] {
        let markers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL",
                       "AUTH", "SESSION", "COOKIE", "PRIVATE", "APIKEY", "ACCESS_KEY"]
        var environment = ProcessInfo.processInfo.environment
        for name in environment.keys {
            let upper = name.uppercased()
            if markers.contains(where: { upper.contains($0) }) { environment.removeValue(forKey: name) }
        }
        // Keep the shell usable.
        environment["HOME"] = NSHomeDirectory()
        return environment
    }

    /// Thread-safe accumulation for the two readability handlers, which fire off-actor.
    final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()
        /// Bounded, so a runaway command cannot exhaust memory on a machine with 1.4 GB free.
        private let cap = 4 * 1024 * 1024
        private var truncated = false

        func appendOut(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            if outData.count < cap { outData.append(d) } else { truncated = true }
        }
        func appendErr(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            if errData.count < cap { errData.append(d) } else { truncated = true }
        }
        func stdout() -> String {
            lock.lock(); defer { lock.unlock() }
            let text = String(data: outData, encoding: .utf8) ?? ""
            return truncated ? text + "\n… output truncated at 4 MB" : text
        }
        func stderr() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: errData, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Long-running

    /// Start something and keep working. Returns a handle to read from later.
    public func start(_ command: String, cwd: String?, name: String?) throws -> String {
        if let why = refusal(for: command, cwd: cwd) { throw ShellError.refused(why) }

        // A caller-supplied name that is already in use used to overwrite the map entry, which
        // dropped the previous process's handle on the floor while it kept running — unreachable
        // and unkillable for the rest of the session. Two `start`s named "dev" is not a strange
        // thing for a model to do.
        var handle = name ?? "proc-\(processes.count + 1)"
        if let existing = processes[handle] {
            if existing.isRunning {
                throw ShellError.refused("a process called \"\(handle)\" is already running "
                                       + "(\(existing.command)). Stop it first, or use another name.")
            }
            processes.removeValue(forKey: handle)
        }
        // The generated form can collide too, once anything has been removed.
        var suffix = processes.count + 1
        while name == nil && processes[handle] != nil {
            suffix += 1
            handle = "proc-\(suffix)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = Self.sanitisedEnvironment()
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let running = Running(process: process, name: handle, command: command)
        out.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { running.appendOut(s) }
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { running.appendErr(s) }
        }

        try process.run()
        processes[handle] = running
        return handle
    }

    /// What has this process said since we last looked?
    public func read(_ handle: String) -> String {
        guard let running = processes[handle] else { return "no process called \(handle)" }
        let (out, err) = running.drain()
        var parts: [String] = []
        if !out.isEmpty { parts.append(out) }
        if !err.isEmpty { parts.append("[stderr]\n" + err) }
        if let code = running.exitCode { parts.append("[exited with \(code)]") }
        return parts.isEmpty ? "(no new output)" : parts.joined(separator: "\n")
    }

    public func status(_ handle: String) -> String {
        guard let running = processes[handle] else { return "no process called \(handle)" }
        if let code = running.exitCode { return "exited with \(code)" }
        return "running for \(Int(Date().timeIntervalSince(running.started)))s: \(running.command)"
    }

    public func list() -> String {
        guard !processes.isEmpty else { return "no processes running" }
        return processes.values
            .map { "\($0.name): \($0.isRunning ? "running" : "exited \($0.exitCode ?? -1)") — \($0.command)" }
            .sorted()
            .joined(separator: "\n")
    }

    @discardableResult
    public func kill(_ handle: String) -> String {
        guard let running = processes[handle] else { return "no process called \(handle)" }
        running.process.terminate()
        processes.removeValue(forKey: handle)
        return "stopped \(handle)"
    }

    /// Stop everything this executor started. Called when a run ends, so a bot cannot leave
    /// orphaned servers behind after it finishes.
    public func killAll() {
        for (_, running) in processes where running.isRunning { running.process.terminate() }
        processes.removeAll()
    }

    private func string(_ data: Data?) -> String {
        guard let data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
