import Foundation

/// Running commands, and keeping processes alive across turns.
///
/// The second half is the point. `exec(command) → wait → output` cannot run `npm run dev`:
/// either the agent blocks forever waiting for a server that never exits, or it kills the
/// thing it just started. An agent that cannot start a server and then go look at the page it
/// serves is not much of a computer agent, so processes are first-class here.
public actor ShellExecutor: CommandRunning {

    private var processes: [String: Running] = [:]

    public init() {}

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
            case .refused(let pattern):
                return "Refused: this command names \(pattern), which holds credentials and is "
                     + "never readable by a bot. Nothing was started."
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
        if let pattern = Self.forbiddenPath(in: command) {
            return CommandOutput(
                exitCode: 126, stdout: "",
                stderr: "Refused: this command names \(pattern), which holds credentials and is "
                      + "never readable by a bot. Nothing was run.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return CommandOutput(exitCode: 127, stdout: "", stderr: "could not start: \(error.localizedDescription)")
        }

        // Read before waiting. A command that fills the 64KB pipe buffer while we wait for it
        // to exit deadlocks — it blocks writing, we block waiting, neither moves.
        let outData = try? out.fileHandleForReading.readToEnd()
        let errData = try? err.fileHandleForReading.readToEnd()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            return guarded(CommandOutput(exitCode: 124,
                                         stdout: string(outData),
                                         stderr: "timed out after \(Int(timeout))s"))
        }

        return guarded(CommandOutput(
            exitCode: process.terminationStatus,
            stdout: string(outData),
            stderr: string(errData)
        ))
    }

    // MARK: - Long-running

    /// Start something and keep working. Returns a handle to read from later.
    public func start(_ command: String, cwd: String?, name: String?) throws -> String {
        if let pattern = Self.forbiddenPath(in: command) {
            throw ShellError.refused(pattern)
        }
        let handle = name ?? "proc-\(processes.count + 1)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
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
