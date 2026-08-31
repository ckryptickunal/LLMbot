import Foundation

/// The kernel-enforced half of the shell boundary.
///
/// `ShellExecutor.refusal(for:cwd:)` reads a command and decides whether to run it. That is
/// judgement, and its own doc comment is honest about the limit: a path assembled at runtime —
/// `P=$HOME; cat "$P/x"` — is invisible to any amount of string work. This is the other half.
/// The command runs under a Seatbelt profile that the kernel enforces, so a write outside the
/// bot's workspace fails at `open(2)` no matter how the path was spelled, assembled, or hidden
/// inside an interpreter.
///
/// **Deprecated and load-bearing.** `man sandbox-exec` says "DEPRECATED" and has for years.
/// It is nonetheless the mechanism Claude Code and Codex CLI both ship for their macOS
/// sandboxes, and this project verified a deny-default profile actually blocking writes and DNS
/// on this exact OS build. Apple has given no compatibility commitment, so every use of it is
/// behind this one type, and `selfTest()` proves the mechanism still works at launch rather
/// than assuming it.
///
/// See `docs/decisions/0020-shell-commands-run-inside-seatbelt.md`.
public enum Seatbelt {

    /// Hardcoded, never resolved from `PATH`.
    ///
    /// Copied deliberately from Codex, whose source carries the reason: only `/usr/bin` is
    /// considered, "to defend against an attacker trying to inject a malicious version on the
    /// PATH". A sandbox you locate by asking the environment is a sandbox the environment can
    /// replace with `/bin/true`.
    public static let executable = "/usr/bin/sandbox-exec"

    // MARK: - Policy

    /// What a command is allowed to touch, in the form the kernel can enforce.
    public struct Policy: Sendable, Equatable {
        /// Directories the command may write inside. Already real paths — see `Policy.init`.
        public var writableRoots: [String]
        /// Subpaths inside those roots that stay read-only. The bot's own git history and this
        /// app's configuration live here: a bot may work in a repository without rewriting its
        /// history, and may not edit the rules that govern it.
        public var readOnlyCarveOuts: [String]
        /// Whether the command may reach the network at all.
        public var allowNetwork: Bool
        /// A writable scratch directory, exported as `TMPDIR`. Almost every compiler, package
        /// manager and `git` invocation needs one; without it a "sandboxed" build fails in ways
        /// that look like the sandbox is broken rather than working.
        public var scratchDirectory: String

        public init(writableRoots: [String], readOnlyCarveOuts: [String] = [],
                    allowNetwork: Bool, scratchDirectory: String) {
            // Symlinks are the classic profile mismatch: `/tmp` is a link to `/private/tmp`, so a
            // profile written for the first never matches the path the kernel actually checks.
            self.writableRoots = writableRoots.map(Self.realPath).uniqued()
            self.readOnlyCarveOuts = readOnlyCarveOuts.map(Self.realPath).uniqued()
            self.allowNetwork = allowNetwork
            self.scratchDirectory = Self.realPath(scratchDirectory)
        }

        /// The path the *kernel* will check, which is not the one Foundation hands back.
        ///
        /// `URL.resolvingSymlinksInPath()` actively un-resolves the three prefixes that matter
        /// most here: it strips a leading `/private` from `/private/var`, `/private/tmp` and
        /// `/private/etc` as a documented convenience. The sandbox canonicalises the other way, so
        /// a profile built from Foundation's answer names a subpath the kernel never matches — and
        /// every write into a workspace under `/tmp` or `/var/folders` was denied while the
        /// profile read as correct. Verified directly: a profile naming `/tmp/x` denies a write to
        /// `/tmp/x/f`; the same profile naming `/private/tmp/x` allows it.
        ///
        /// `realpath(3)` gives the kernel's answer, but only for a path that exists. A workspace
        /// that has not been created yet still needs a usable rule, so the deepest existing
        /// ancestor is resolved and the remainder appended — which is what makes
        /// `/tmp/not-created-yet` come out as `/private/tmp/not-created-yet` rather than
        /// unresolved.
        static func realPath(_ path: String) -> String {
            let expanded = PathGuard.expand(path)
                .replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "/*", with: "")
            guard expanded.hasPrefix("/") else { return expanded }

            var components = expanded.split(separator: "/").map(String.init)
            var trailing: [String] = []
            while !components.isEmpty {
                let candidate = "/" + components.joined(separator: "/")
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                if realpath(candidate, &buffer) != nil {
                    let resolved = String(cString: buffer)
                    return trailing.isEmpty ? resolved
                                            : resolved + "/" + trailing.joined(separator: "/")
                }
                trailing.insert(components.removeLast(), at: 0)
            }
            return expanded
        }
    }

    /// The policy for one run, derived from what the bot was actually granted.
    ///
    /// Reads are deliberately *not* narrowed here. The existing executor already refuses reads
    /// outside the bot's scope before anything runs, and a read-deny profile that is even
    /// slightly wrong stops `python3` from loading its own standard library — a failure mode
    /// that reads as "the app is broken", not "the boundary held". Writes and the network are
    /// where a mistake is irreversible, so those are what the kernel enforces.
    public static func policy(for authority: Authority, scratchDirectory: String) -> Policy {
        var roots = authority.writable.map(Policy.realPath).filter { !$0.isEmpty && $0 != "/" }
        // Nothing to write means nothing to allow — the profile still runs, and denies everything.
        roots = roots.uniqued()

        // Carve-outs sit *inside* writable roots, so they need the roots to exist first.
        var carveOuts: [String] = []
        for root in roots {
            carveOuts.append(root + "/.git")
        }
        carveOuts.append(Paths.root.path)   // the app's own state, traces and credential file

        return Policy(writableRoots: roots,
                      readOnlyCarveOuts: carveOuts,
                      allowNetwork: authority.permits("web.read") || authority.permits("browser.use"),
                      scratchDirectory: scratchDirectory)
    }

    // MARK: - Profile

    /// The Seatbelt profile text for a policy.
    ///
    /// Structure matters and is not cosmetic. `(deny default)` comes first so anything not
    /// named below is refused; the allows follow; the carve-out denies come **last**, because
    /// in SBPL the last matching rule wins. Reversing those two blocks silently grants write
    /// access to every `.git` directory in the workspace — which is why `SeatbeltTests` proves
    /// the ordering by executing it rather than by reading it.
    public static func profile(for policy: Policy) -> String {
        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "",
            "; Reading is governed before execution by the executor's own scope checks. A profile",
            "; that also narrows reads breaks interpreters loading their own standard library,",
            "; which reads as a broken app rather than as a boundary holding.",
            "(allow file-read*)",
            "",
            "; Running anything at all needs these.",
            "(allow process-exec)",
            "(allow process-fork)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow signal (target self))",
            "(allow file-write-data (literal \"/dev/null\") (literal \"/dev/stdout\") (literal \"/dev/stderr\") (literal \"/dev/dtracehelper\"))",
            "(allow file-ioctl (literal \"/dev/tty\") (literal \"/dev/null\"))",
            "",
        ]

        if policy.allowNetwork {
            lines.append("; This bot may reach the network.")
            lines.append("(allow network-outbound)")
            lines.append("(allow network-bind)")
            lines.append("(allow system-socket)")
        } else {
            lines.append("; No network capability was granted, so the kernel refuses it outright.")
            lines.append("(deny network*)")
        }
        lines.append("")

        lines.append("; Writable work areas.")
        for root in policy.writableRoots {
            lines.append("(allow file-write* (subpath \(quote(root))))")
        }
        lines.append("(allow file-write* (subpath \(quote(policy.scratchDirectory))))")
        lines.append("")

        // Last block: deny wins over the allows above it.
        lines.append("; Carve-outs. These sit inside writable roots and stay read-only, so a bot")
        lines.append("; can work in a repository without rewriting its history, and cannot edit the")
        lines.append("; rules that govern it. Written last on purpose: the final match wins.")
        for carveOut in policy.readOnlyCarveOuts {
            lines.append("(deny file-write* (subpath \(quote(carveOut))))")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// SBPL string literal.
    ///
    /// A workspace path may contain a quote or a backslash — rare, but a path is user data, and
    /// user data spliced into a policy language without escaping is how a boundary becomes a
    /// syntax error at best and an injected `(allow default)` at worst.
    static func quote(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            default:   escaped.append(character)
            }
        }
        return "\"" + escaped + "\""
    }

    // MARK: - Invocation

    /// The argument vector that runs `command` under `policy`.
    ///
    /// Kept separate from the running of it so a test can assert the shape without spawning
    /// anything, and so `ShellExecutor` has exactly one place to call.
    public static func arguments(for command: String, policy: Policy) -> [String] {
        // The scratch directory is exported as TMPDIR and allowed by the profile, but nothing
        // created it — so `$TMPDIR/anything` failed for a reason that looks exactly like the
        // sandbox denying it, which is the worst possible way for this to break. Created here
        // because this is the one funnel every caller goes through, app and tests alike.
        try? FileManager.default.createDirectory(atPath: policy.scratchDirectory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return ["-p", profile(for: policy), "/bin/zsh", "-c", command]
    }

    // MARK: - Self-test

    /// Whether Seatbelt actually confines anything on this machine, right now.
    ///
    /// Runs once at launch. The mechanism is deprecated, so "it worked when this was written"
    /// is not a guarantee that survives an OS update — and the failure mode that matters is the
    /// silent one, where the profile is ignored and every command runs unconfined while the app
    /// still says "sandboxed". This proves a known-denied write is actually denied.
    ///
    /// A `false` result never disables the shell. Refusing to work is worse than working with a
    /// stated limitation; what must not happen is claiming a boundary that is not there.
    /// Whether Seatbelt is confining anything on this machine, tested once per launch.
    ///
    /// The test spawns a process, so it is done once and remembered. Anything that needs the
    /// answer synchronously — the decision of whether to build a profile for a run — reads this.
    /// Compute `isWorking` now, off whatever thread calls this, so nothing later has to wait.
    ///
    /// Called once at launch. Without it the first read of `isWorking` runs the self-test wherever
    /// that read happens — and the first read turned out to be a SwiftUI view body, which spawns a
    /// subprocess in the middle of a layout pass and takes the app down with it. The lazy static
    /// is still correct on its own; this only decides *where* the one-time cost is paid.
    public static func warmUp() {
        Task.detached(priority: .utility) { _ = isWorking }
    }

    /// The answer if it is already known, without ever computing it.
    ///
    /// **Views must read this, never `isWorking`.** Reading `isWorking` runs the self-test if it
    /// has not run yet, and the self-test spawns a subprocess — which took the app down when the
    /// first read happened to be a SwiftUI body evaluating a settings panel. `nil` means "not
    /// known yet", and the honest thing to render for `nil` is wording that claims nothing.
    public static var knownWorking: Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedWorking
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var cachedWorking: Bool?

    public static let isWorking: Bool = {
        let working = selfTest()
        stateLock.lock()
        cachedWorking = working
        stateLock.unlock()
        if !working {
            let warning = "Bot-Harness: sandbox-exec is not confining commands on this system. "
                        + "Shell commands run unconfined, and runs record that they were not "
                        + "sandboxed.\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        return working
    }()

    public static func selfTest() -> Bool {
        let scratch = NSTemporaryDirectory() + "bh-seatbelt-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let forbidden = scratch + "/denied.txt"
        // Writable root is a directory that does not contain `forbidden`, so writing it must fail.
        let policy = Policy(writableRoots: [scratch + "/allowed"],
                            readOnlyCarveOuts: [],
                            allowNetwork: false,
                            scratchDirectory: scratch + "/allowed")
        try? FileManager.default.createDirectory(atPath: scratch + "/allowed",
                                                 withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(for: "touch \(shellQuote(forbidden))", policy: policy)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()

        // The write must have failed *and* left nothing behind.
        return !FileManager.default.fileExists(atPath: forbidden)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension Array where Element: Hashable {
    /// Order-preserving deduplication. A profile with the same subpath twice is valid but noise.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
