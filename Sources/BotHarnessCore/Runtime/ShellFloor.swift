import Foundation

// The safety floor's opinion of a shell command, taken from its structure rather than its text.
//
// `ShellCommandParser` answers "what would run"; this answers "and is that something the user
// has to be asked about". Keeping the two apart matters: the parser has no policy in it and can
// be tested against a shell, and the policy has no string-scanning in it and can be read by
// someone deciding whether they agree with it.
//
// See `docs/decisions/0010-parse-shell-before-judging-it.md`.

public enum ShellFloor {

    public enum Outcome: Equatable {
        /// Nothing here is a floor matter. It may still be caught by a user rule.
        case clear
        case floor(SafetyFloor, because: String)
        /// The command could not be read. **Not the same as clear**, and the caller must ask.
        case unreadable(because: String)
    }

    /// - Parameter insideWorkspace: whether a path is somewhere this bot may already write.
    ///   Deleting inside the workspace is the job; deleting outside it is the floor.
    public static func judge(_ command: String,
                             insideWorkspace: (String) -> Bool = { _ in false }) -> Outcome {

        let parse = ShellCommandParser.parse(command)
        guard parse.readable else {
            return .unreadable(because: parse.unreadableReason ?? "it could not be read")
        }

        // Ordered by severity: the first thing found is what the user is told, so the most
        // alarming reading of a command has to be the one that wins.
        for check in [privilegeEscalation, diskDestruction, remoteCode,
                      credentialFiles, systemConfiguration, sharedHistory] {
            if let outcome = check(parse) { return outcome }
        }
        if let outcome = recursiveDelete(parse, insideWorkspace: insideWorkspace) { return outcome }
        return .clear
    }

    // MARK: - The checks

    private static func privilegeEscalation(_ parse: ShellParse) -> Outcome? {
        guard let command = parse.commands.first(where: { ["sudo", "doas", "su"].contains($0.executable) })
        else { return nil }
        return .floor(.changingSystemConfiguration, because: "it runs `\(command.executable)`")
    }

    private static func diskDestruction(_ parse: ShellParse) -> Outcome? {
        for command in parse.commands {
            if command.executable.hasPrefix("mkfs") || command.executable.hasPrefix("newfs")
                || command.executable == "fdisk" {
                return .floor(.destructiveDelete, because: "`\(command.executable)` formats a disk")
            }
            if command.executable == "diskutil",
               command.operands.contains(where: { operand in
                   let verb = operand.value.lowercased()
                   return verb.hasPrefix("erase") || verb.hasPrefix("reformat")
                       || verb == "partitiondisk" || verb == "zerodisk" || verb == "secureerase"
               }) {
                return .floor(.destructiveDelete, because: "it erases or repartitions a disk")
            }
            // `dd` is harmless reading and catastrophic writing; `of=` is which one it is.
            if command.executable == "dd",
               command.operands.contains(where: { $0.value.hasPrefix("of=") }) {
                return .floor(.destructiveDelete, because: "`dd` writes directly to `of=`")
            }
        }
        return nil
    }

    /// `curl … | sh`, and the several other spellings of the same idea.
    private static func remoteCode(_ parse: ShellParse) -> Outcome? {
        let fetchers: Set<String> = ["curl", "wget", "ftp", "nc", "ncat", "scp", "sftp"]
        let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python",
                                        "python3", "ruby", "perl", "node", "deno", "bun", "osascript"]

        // Same pipeline, fetcher upstream of an interpreter: the classic install-script shape.
        for pipeline in Set(parse.commands.map(\.pipeline)) {
            let members = parse.pipelineMembers(pipeline)
            guard let fetch = members.firstIndex(where: { fetchers.contains($0.executable) }),
                  let run = members.lastIndex(where: { interpreters.contains($0.executable) }),
                  fetch < run
            else { continue }
            return .floor(.runningUnreviewedCode,
                          because: "`\(members[fetch].executable)` downloads something and pipes it straight into `\(members[run].executable)`")
        }

        // `sh -c "$(curl …)"` — different shape, same act. The parser has already pulled the
        // fetcher out of the substitution, so all that is left is to notice the pairing.
        let fetched = parse.commands.filter { fetchers.contains($0.executable) }
        if !fetched.isEmpty {
            for command in parse.commands where interpreters.contains(command.executable) {
                let takesSomethingUnknown = command.arguments.contains(where: \.isDynamic)
                if takesSomethingUnknown {
                    return .floor(.runningUnreviewedCode,
                                  because: "`\(command.executable)` is handed the output of `\(fetched[0].executable)`")
                }
            }
        }
        return nil
    }

    /// Anything that would write where the keys live grants somebody access.
    private static func credentialFiles(_ parse: ShellParse) -> Outcome? {
        let guarded = [".ssh/", ".aws/", ".gnupg/", ".netrc", "authorized_keys",
                       ".config/gh/", ".kube/config", ".docker/config.json"]
        for path in writtenPaths(parse) where guarded.contains(where: { path.contains($0) }) {
            return .floor(.grantingAccess, because: "it writes to `\(path)`")
        }
        return nil
    }

    private static func systemConfiguration(_ parse: ShellParse) -> Outcome? {
        let tools: Set<String> = ["csrutil", "spctl", "tccutil", "nvram", "systemsetup", "scutil",
                                  "pmset", "launchctl", "dscl", "networksetup", "softwareupdate",
                                  "visudo", "chsh", "dseditgroup"]
        if let command = parse.commands.first(where: { tools.contains($0.executable) }) {
            return .floor(.changingSystemConfiguration, because: "`\(command.executable)` changes system configuration")
        }
        if let command = parse.commands.first(where: { $0.executable == "crontab" && !$0.hasFlag("l") }) {
            _ = command
            return .floor(.changingSystemConfiguration, because: "it edits the crontab")
        }
        let guarded = ["/etc/", "/private/etc/", "launchagents/", "launchdaemons/",
                       ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile", "/etc/hosts"]
        for path in writtenPaths(parse) {
            let lowered = path.lowercased()
            if guarded.contains(where: { lowered.contains($0) }) {
                return .floor(.changingSystemConfiguration, because: "it writes to `\(path)`")
            }
        }
        return nil
    }

    private static func sharedHistory(_ parse: ShellParse) -> Outcome? {
        for command in parse.commands where command.executable == "git" {
            let verbs = command.operands.map { $0.value.lowercased() }
            if verbs.contains("push"),
               command.hasFlag("f", "force", "force-with-lease", "delete", "d") {
                return .floor(.rewritingSharedHistory, because: "it force-pushes or deletes a remote branch")
            }
            if verbs.contains("filter-branch") || verbs.contains("filter-repo") {
                return .floor(.rewritingSharedHistory, because: "it rewrites every commit in the history")
            }
            if verbs.contains("reset"), command.hasFlag("hard"),
               command.operands.contains(where: { $0.value.contains("origin/") || $0.value.contains("upstream/") }) {
                return .floor(.rewritingSharedHistory, because: "it hard-resets onto a remote branch")
            }
            if verbs.contains("branch"), command.hasFlag("D") {
                return .floor(.rewritingSharedHistory, because: "it force-deletes a branch")
            }
        }
        return nil
    }

    /// The one this whole exercise started from.
    private static func recursiveDelete(_ parse: ShellParse,
                                        insideWorkspace: (String) -> Bool) -> Outcome? {
        for command in parse.commands {
            var targets: [ShellArgument] = []

            if command.executable == "rm", command.hasFlag("r", "R", "recursive", "rf", "fr", "Rf", "fR") {
                targets = command.operands
            } else if command.executable == "find",
                      command.hasFlag("delete") || command.operands.contains(where: { $0.value == "-delete" }) {
                targets = command.operands.filter { !$0.value.hasPrefix("-") }
            } else if command.executable == "shred" || command.executable == "srm" {
                targets = command.operands
            }
            guard !targets.isEmpty else { continue }

            for target in targets {
                // A delete pointed at something we cannot resolve is the *most* alarming case,
                // not the least: nobody can say what it would remove, which is precisely when
                // a person should look.
                if target.isDynamic {
                    return .floor(.destructiveDelete,
                                  because: "it deletes `\(target.raw)`, and what that expands to is not knowable from here")
                }
                let path = expand(target.value)
                if isRootOrHome(path) {
                    return .floor(.destructiveDelete, because: "it recursively deletes `\(target.value)`")
                }
                if !insideWorkspace(path) {
                    return .floor(.destructiveDelete,
                                  because: "it recursively deletes `\(target.value)`, which is outside this bot's workspace")
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Every path this command would write to: redirect targets, plus the destination operand
    /// of the commands whose whole job is to put bytes somewhere.
    private static func writtenPaths(_ parse: ShellParse) -> [String] {
        var paths: [String] = []
        for redirect in parse.redirects where redirect.writes && !redirect.isDevNull {
            if !redirect.target.value.isEmpty { paths.append(expand(redirect.target.value)) }
        }
        for command in parse.commands {
            switch command.executable {
            case "tee":
                paths += command.operands.map { expand($0.value) }
            case "cp", "mv", "install", "ln", "rsync":
                if let destination = command.operands.last { paths.append(expand(destination.value)) }
            case "chmod", "chown", "chgrp", "xattr":
                paths += command.operands.dropFirst().map { expand($0.value) }
            case "defaults":
                if command.operands.first?.value == "write" {
                    paths += command.operands.dropFirst().prefix(1).map { $0.value }
                }
            default:
                break
            }
        }
        return paths
    }

    /// Only the expansions that can be done without running anything: `~` and `$HOME`.
    private static func expand(_ path: String) -> String {
        var expanded = path
        let home = NSHomeDirectory()
        if expanded == "~" || expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst(1)
        }
        for form in ["$HOME", "${HOME}"] where expanded.hasPrefix(form) {
            expanded = home + expanded.dropFirst(form.count)
        }
        return expanded
    }

    private static func isRootOrHome(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return ["/", "/Users", "/System", "/Applications", "/Library", "/usr", "/bin", "/var",
                NSHomeDirectory()].contains(trimmed)
    }
}
