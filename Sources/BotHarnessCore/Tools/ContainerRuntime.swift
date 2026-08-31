import Foundation

/// A bot's own computer: a real Linux machine, one per bot, that it can do anything inside.
///
/// The point is not isolation for its own sake. A bot on `This Mac` cannot `apt-get install`
/// anything, cannot leave a build tree lying around, and cannot run a server on port 8080
/// without that being *your* port 8080. A bot with its own computer can do all of it, and
/// throwing the machine away costs nothing. Its workspace folder is shared into the machine at
/// `/work`, so the files it produces are real files on your Mac and everything else — packages,
/// caches, half-finished builds — lives and dies inside.
///
/// **Everything here degrades to nothing.** The tool this needs is not installed by default and
/// this app will not install it: it ships as a signed package that wants an admin password,
/// which is the user's decision to make, not ours. So every entry point answers "not available"
/// cleanly, the app runs exactly as it did before, and the interface says what is missing and
/// what installing it would buy. A bot whose computer is unavailable falls back to This Mac
/// rather than failing — see `AgentLoop`.
///
/// See `docs/decisions/0015-a-bot-can-have-its-own-linux-computer.md`.
public actor ContainerRuntime {

    /// Hardcoded, like `sandbox-exec` and for the same reason: a boundary you locate by asking
    /// `PATH` is a boundary `PATH` can replace.
    public static let executable = "/usr/local/bin/container"

    /// Debian rather than Alpine. Alpine is smaller and its musl libc breaks a large fraction of
    /// Python wheels and prebuilt binaries — which the agent would then have to diagnose, badly,
    /// on its own. `slim` keeps it to roughly 100 MB unpacked.
    public static let defaultImage = "docker.io/library/debian:stable-slim"

    /// Refuse to pull under this much free disk. An image download that fills the disk breaks
    /// far more than this feature.
    public static let requiredFreeBytes: Int64 = 2_000_000_000

    /// One runtime for the whole app.
    ///
    /// Containers outlive a single run — that is most of their value, since a warm machine with
    /// its packages already installed is the difference between a two-second command and a
    /// two-minute one. A per-run instance would re-probe and re-prepare every time.
    public static let shared = ContainerRuntime()

    public init() {}

    // MARK: - Availability

    public enum Availability: Equatable, Sendable {
        /// Installed, the service is up, and a container can be created right now.
        case ready
        /// The tool is not on this Mac. Not an error: the ordinary state of a fresh install.
        case notInstalled
        /// Installed, but the background service is not running.
        case serviceStopped
        /// Installed and reachable, but something is wrong that the user has to see.
        case failing(String)

        public var isReady: Bool { self == .ready }
    }

    private var cachedAvailability: Availability?
    /// Containers this process has already prepared, so a warm run costs no subprocesses.
    private var prepared: Set<String> = []
    /// The workspace each prepared container was created against, so a moved workspace is
    /// noticed rather than silently serving a stale mount.
    private var mountedWorkspace: [String: String] = [:]

    /// Whether a bot's own computer is possible right now.
    ///
    /// Cached after the first answer because it costs a subprocess and the answer changes only
    /// when the user installs something. `refresh()` drops the cache — the Computers tab calls
    /// it when it comes forward, which is exactly when a user might have just installed.
    public func availability() async -> Availability {
        if let cachedAvailability { return cachedAvailability }
        let result = await probe()
        cachedAvailability = result
        return result
    }

    public func refresh() { cachedAvailability = nil }

    private func probe() async -> Availability {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            return .notInstalled
        }
        let status = await run([Self.executable, "system", "status"], timeout: 15)
        if status.exitCode == 0 { return .ready }
        // A stopped service and a broken install look different in stderr, and the user needs a
        // different action for each: one is a button, the other is a reinstall.
        let text = (status.stderr + status.stdout).lowercased()
        if text.contains("not running") || text.contains("no such file")
            || text.contains("connection") || text.contains("could not connect") {
            return .serviceStopped
        }
        return .failing(Self.firstLine(status.stderr.isEmpty ? status.stdout : status.stderr))
    }

    /// Start the background service. The user asks for this explicitly from the Computers tab;
    /// nothing starts it at launch, because a VM service spinning up behind an app the user has
    /// just opened is a surprise, and it may want a password.
    public func startService() async -> Availability {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            cachedAvailability = .notInstalled
            return .notInstalled
        }
        let result = await run([Self.executable, "system", "start"], timeout: 120)
        cachedAvailability = nil
        if result.exitCode != 0 {
            let message = Self.firstLine(result.stderr.isEmpty ? result.stdout : result.stderr)
            cachedAvailability = .failing(message)
            return .failing(message)
        }
        return await availability()
    }

    // MARK: - Names and paths

    /// One container per bot, derivable from the bot's id so nothing has to be stored.
    ///
    /// Lower-cased hex prefix: container names are DNS-ish, and a UUID's uppercase and dashes
    /// are not universally accepted.
    public nonisolated static func name(for botID: UUID) -> String {
        let hex = botID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "bh-" + String(hex.prefix(12))
    }

    /// Where the workspace appears inside the machine.
    public static let guestWorkspace = "/work"

    /// Translate a path the model wrote in guest terms into a host path, and back.
    ///
    /// One function, used by the floor, the approval card and the file tools, because three
    /// implementations of this is three chances for the boundary check and the thing executed to
    /// disagree about which file is meant.
    public nonisolated static func hostPath(fromGuest path: String, workspace: String) -> String {
        guard path == guestWorkspace || path.hasPrefix(guestWorkspace + "/") else { return path }
        let tail = String(path.dropFirst(guestWorkspace.count))
        return workspace + tail
    }

    public nonisolated static func guestPath(fromHost path: String, workspace: String) -> String {
        guard path == workspace || path.hasPrefix(workspace + "/") else { return path }
        let tail = String(path.dropFirst(workspace.count))
        return guestWorkspace + tail
    }

    // MARK: - Lifecycle

    public enum Failure: LocalizedError, Equatable {
        case notInstalled
        case serviceStopped
        case diskFull(freeBytes: Int64)
        case refusedWorkspace(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "This bot's own computer needs Apple's container tool, which is not "
                     + "installed on this Mac. Computers → Container explains the one-time setup."
            case .serviceStopped:
                return "The container service is not running. Computers → Container has a button "
                     + "to start it."
            case .diskFull(let free):
                let gb = Double(free) / 1_000_000_000
                return String(format: "Not enough free disk to build this bot's computer — %.1f GB "
                            + "free, and about 2 GB is needed.", gb)
            case .refusedWorkspace(let path):
                return "This bot's folder is \(path), which is too broad to share into a "
                     + "container. Give the bot a specific project folder in its settings first."
            case .commandFailed(let detail):
                return "This bot's computer could not be prepared: \(detail)"
            }
        }
    }

    /// Make sure this bot's machine exists and is running, and return its name.
    ///
    /// Idempotent and cheap on the warm path: once a container is known-prepared in this
    /// process, this returns immediately.
    @discardableResult
    public func prepare(botID: UUID, workspace: String) async throws -> String {
        let name = Self.name(for: botID)
        let workspace = URL(fileURLWithPath: PathGuard.expand(workspace))
            .resolvingSymlinksInPath().path

        // A container whose workspace has moved is serving the wrong folder. Rebuild rather than
        // silently mounting what the bot used to have.
        if prepared.contains(name), mountedWorkspace[name] == workspace { return name }

        switch await availability() {
        case .notInstalled:   throw Failure.notInstalled
        case .serviceStopped: throw Failure.serviceStopped
        case .failing(let m): throw Failure.commandFailed(m)
        case .ready:          break
        }

        // Sharing the home directory or the disk root into a container is not a workspace, it is
        // handing over the machine. The bot's folder must be a folder.
        guard Self.isShareable(workspace) else { throw Failure.refusedWorkspace(workspace) }
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)

        if mountedWorkspace[name] != nil && mountedWorkspace[name] != workspace {
            await destroy(botID: botID)
        }

        try await ensureImage()

        // Already running from an earlier launch? Reuse it — a warm machine is the whole point.
        let existing = await run([Self.executable, "list", "--all", "--quiet"], timeout: 20)
        let names = existing.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if names.contains(name) {
            _ = await run([Self.executable, "start", name], timeout: 60)
        } else {
            // `sleep infinity` keeps the machine warm so each command is an `exec` rather than a
            // fresh boot. Memory and CPU are capped: a runaway build inside the container must
            // not take the Mac down with it.
            let create = await run([
                Self.executable, "run", "--detach",
                "--name", name,
                "--volume", "\(workspace):\(Self.guestWorkspace)",
                "--memory", "2g", "--cpus", "2",
                Self.defaultImage,
                "sleep", "infinity",
            ], timeout: 180)
            guard create.exitCode == 0 else {
                throw Failure.commandFailed(Self.firstLine(create.stderr.isEmpty ? create.stdout : create.stderr))
            }
        }

        prepared.insert(name)
        mountedWorkspace[name] = workspace
        return name
    }

    /// Whether a folder is specific enough to hand to a container.
    static func isShareable(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let forbidden = ["/", "/Users", "/System", "/Library", "/Applications",
                         "/usr", "/bin", "/etc", "/var", NSHomeDirectory()]
        return !forbidden.contains(trimmed) && trimmed.hasPrefix("/")
    }

    private func ensureImage() async throws {
        let listed = await run([Self.executable, "image", "list", "--quiet"], timeout: 30)
        let short = Self.defaultImage.replacingOccurrences(of: "docker.io/library/", with: "")
        if listed.stdout.contains(short) || listed.stdout.contains(Self.defaultImage) { return }

        // Check the disk before the download, not after it fails.
        if let free = Self.freeDiskBytes(), free < Self.requiredFreeBytes {
            throw Failure.diskFull(freeBytes: free)
        }
        let pull = await run([Self.executable, "image", "pull", Self.defaultImage], timeout: 900)
        guard pull.exitCode == 0 else {
            throw Failure.commandFailed(Self.firstLine(pull.stderr.isEmpty ? pull.stdout : pull.stderr))
        }
    }

    /// Run one command inside the bot's machine.
    public func exec(_ command: String, botID: UUID, workspace: String,
                     timeout: TimeInterval) async -> CommandOutput {
        do {
            let name = try await prepare(botID: botID, workspace: workspace)
            let result = await run([
                Self.executable, "exec", "--workdir", Self.guestWorkspace,
                name, "/bin/sh", "-c", command,
            ], timeout: timeout)

            // A machine that died between preparation and this command: restart once, then give
            // up honestly. Retrying forever on a container that cannot start is a hang.
            if result.exitCode != 0, Self.looksDead(result) {
                prepared.remove(name)
                if let retryName = try? await prepare(botID: botID, workspace: workspace) {
                    return await run([
                        Self.executable, "exec", "--workdir", Self.guestWorkspace,
                        retryName, "/bin/sh", "-c", command,
                    ], timeout: timeout)
                }
            }
            return result
        } catch {
            return CommandOutput(exitCode: 127, stdout: "",
                                 stderr: (error as? Failure)?.errorDescription
                                      ?? error.localizedDescription)
        }
    }

    private static func looksDead(_ output: CommandOutput) -> Bool {
        let text = (output.stderr + output.stdout).lowercased()
        return text.contains("not running") || text.contains("no such container")
            || text.contains("not found")
    }

    /// Throw away a bot's machine. Called when the bot is deleted.
    public func destroy(botID: UUID) async {
        let name = Self.name(for: botID)
        prepared.remove(name)
        mountedWorkspace.removeValue(forKey: name)
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else { return }
        _ = await run([Self.executable, "stop", "--time", "5", name], timeout: 30)
        _ = await run([Self.executable, "delete", "--force", name], timeout: 30)
    }

    /// Remove machines whose bot no longer exists.
    ///
    /// Only ever touches names this app assigns, and only when no live bot owns them, so a
    /// container belonging to anything else on the Mac is never a candidate.
    public func collectGarbage(keeping botIDs: [UUID]) async {
        guard case .ready = await availability() else { return }
        let owned = Set(botIDs.map { Self.name(for: $0) })
        let listed = await run([Self.executable, "list", "--all", "--quiet"], timeout: 20)
        for line in listed.stdout.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("bh-"), !owned.contains(name) else { continue }
            _ = await run([Self.executable, "stop", "--time", "5", name], timeout: 30)
            _ = await run([Self.executable, "delete", "--force", name], timeout: 30)
        }
    }

    /// Total size of downloaded images, for the Computers tab.
    public func imageSummary() async -> String? {
        guard case .ready = await availability() else { return nil }
        let listed = await run([Self.executable, "image", "list", "--quiet"], timeout: 20)
        let count = listed.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 image downloaded" : "\(count) images downloaded"
    }

    public func removeUnusedImages() async {
        guard case .ready = await availability() else { return }
        _ = await run([Self.executable, "image", "prune"], timeout: 120)
    }

    // MARK: - Subprocess

    /// Run the CLI and collect its output.
    ///
    /// Deliberately its own small implementation rather than reaching for `ShellExecutor`: that
    /// type enforces a bot's path authority and will soon wrap everything in Seatbelt, neither
    /// of which applies to us talking to a local daemon on the user's behalf. Reusing it would
    /// mean the container tool is subject to the sandbox meant for the bot's commands.
    private func run(_ argv: [String], timeout: TimeInterval) async -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        // No secrets reach a container. The environment is the obvious leak and the easiest to
        // forget, so it is built from nothing rather than filtered.
        process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                               "HOME": NSHomeDirectory()]

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return CommandOutput(exitCode: 127, stdout: "",
                                 stderr: "could not start the container tool: \(error.localizedDescription)")
        }

        // Both pipes drained concurrently: a chatty pull fills a 64 KB buffer and deadlocks
        // anything that waits for exit before reading.
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
        while process.isRunning && Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let timedOut = process.isRunning
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { try? await Task.sleep(for: .milliseconds(25)) }
            if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()

        if timedOut {
            return CommandOutput(exitCode: 124, stdout: collector.stdout(),
                                 stderr: "the container tool did not answer within \(Int(timeout))s")
        }
        return CommandOutput(exitCode: process.terminationStatus,
                             stdout: collector.stdout(), stderr: collector.stderr())
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? "no detail given"
        return String(line.prefix(200))
    }

    static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }
}
