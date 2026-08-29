import Foundation

/// Decides, for one proposed action, whether it happens, asks, or is refused.
///
/// Evaluation order is fixed and matters:
///
/// 1. **The floor**, which no user rule can lower.
/// 2. **The user's rules**, strongest behaviour winning — *ask* always beats *allow*.
/// 3. **The autonomy level**, as the default when nothing matched.
///
/// Every decision returns its reason and which layer produced it, because the trace has to be
/// able to answer "why was this allowed?" with something better than "it was".
public struct PermissionEngine {

    public let contract: TaskContract
    public let rules: [PermissionRule]

    public func decide(_ action: ProposedAction, tool: ToolDescriptor?) -> PermissionDecision {

        // 1. The floor. Checked first so that an over-generous user rule cannot reach it.
        if action.originatedFromUntrustedContent {
            return .init(outcome: .refused,
                         reason: "this was asked for by a page or document rather than by you, so it is not treated as an instruction",
                         decidedBy: .safetyFloor)
        }
        // 1a. A shell command is judged by what it would actually run.
        //
        // This runs *before* the text scan below and can only add decisions, never remove one.
        // The text scan stays because it covers the tools that are not shell commands, and
        // because two nets that miss different things beat one net.
        if let command = shellCommand(in: action) {
            switch ShellFloor.judge(command, insideWorkspace: pathInsideWorkspace) {
            case .unreadable(let why):
                // The whole reason this value exists. "I could not tell" must reach a person;
                // it must never quietly become "nothing found".
                return .init(outcome: .asked,
                             reason: "this command could not be read closely enough to judge — \(why)",
                             decidedBy: .safetyFloor)
            case .floor(let floor, let why):
                switch floor.floorBehaviour {
                case .neverAllow:
                    return .init(outcome: .refused,
                                 reason: "\(why), which is never delegated",
                                 decidedBy: .safetyFloor)
                case .askFirst, .allowAutomatically:
                    return .init(outcome: .asked,
                                 reason: "\(why), so it needs your approval",
                                 decidedBy: .safetyFloor)
                }
            case .clear:
                break
            }
        }

        if let floor = classify(action, tool: tool) {
            switch floor.floorBehaviour {
            case .neverAllow:
                return .init(outcome: .refused,
                             reason: "this \(floor.explanation), which is never delegated",
                             decidedBy: .safetyFloor)
            case .askFirst, .allowAutomatically:
                return .init(outcome: .asked,
                             reason: "this \(floor.explanation), so it always needs your approval",
                             decidedBy: .safetyFloor)
            }
        }

        // 2. Authority. A capability that was never granted is not a question for the user
        //    mid-run; it is a boundary the contract already drew.
        if let tool {
            if contract.authority.needsApproval(for: tool.capability) {
                return .init(outcome: .asked,
                             reason: "\(tool.capability) is set to ask first for this bot",
                             decidedBy: .userRule)
            }
            if !contract.authority.permits(tool.capability) {
                return .init(outcome: .refused,
                             reason: "this bot does not have \(tool.capability)",
                             decidedBy: .safetyFloor)
            }
        }

        // 3. The user's rules. Strongest match wins.
        let matched = rules.filter { overlaps($0.whenBotWantsTo, action) }
        if let strongest = matched.min(by: { $0.behaviour.strength < $1.behaviour.strength }) {
            switch strongest.behaviour {
            case .neverAllow:
                return .init(outcome: .refused,
                             reason: "your rule says never: \"\(strongest.whenBotWantsTo)\"",
                             decidedBy: .userRule, matchedRuleID: strongest.id)
            case .askFirst:
                return .init(outcome: .asked,
                             reason: "your rule says ask first: \"\(strongest.whenBotWantsTo)\"",
                             decidedBy: .userRule, matchedRuleID: strongest.id)
            case .allowAutomatically:
                return .init(outcome: .allowed,
                             reason: "your rule allows it: \"\(strongest.whenBotWantsTo)\"",
                             decidedBy: .userRule, matchedRuleID: strongest.id)
            }
        }

        // 4. Nothing matched. Fall back to how autonomous this bot is.
        let writes = tool.map { $0.capability.contains("write") || $0.capability.contains("exec")
                                || $0.capability.contains("control") || $0.capability.contains("delete") } ?? true
        if !writes {
            return .init(outcome: .allowed, reason: "reading is always allowed", decidedBy: .defaultPolicy)
        }
        if contract.autonomy.mayWriteWithoutAsking {
            return .init(outcome: .allowed,
                         reason: "this bot works autonomously in its workspace",
                         decidedBy: .defaultPolicy)
        }
        return .init(outcome: .asked,
                     reason: "this bot asks before making changes",
                     decidedBy: .defaultPolicy)
    }

    // MARK: - Floor classification

    /// Which floor category, if any, an action lands in.
    ///
    /// Deliberately conservative and deterministic. This runs before any model reasoning, so
    /// it cannot ask a model what a command means — and it should not, because the whole point
    /// of a floor is that it holds when the model is wrong.
    private func classify(_ action: ProposedAction, tool: ToolDescriptor?) -> SafetyFloor? {
        if let declared = tool?.floorCategory {
            // A delete inside the workspace is ordinary work, not a floor event. Outside it,
            // it is exactly what the floor is for.
            if declared == .destructiveDelete, insideWorkspace(action.detail) { return nil }
            return declared
        }

        let text = (action.summary + " " + action.detail).lowercased()

        if contains(text, ["rm -rf /", "rm -rf ~", "mkfs", "diskutil erase", "dd if=", ":(){"]) {
            return .destructiveDelete
        }
        if contains(text, ["push --force", "push -f", "reset --hard origin", "branch -d", "filter-branch"]) {
            return .rewritingSharedHistory
        }
        if contains(text, ["password", "passwd", "api key", "secret", "credential", "2fa", "otp", "one-time code"]) {
            return .enteringCredentials
        }
        if contains(text, ["stripe", "checkout", "purchase", "buy now", "payment", "transfer", "wire ", "invoice", "subscribe"]) {
            return .financialTransaction
        }
        if contains(text, ["send email", "send message", "reply to", "post to", "tweet", "publish", "deploy to production"]) {
            return .sendingToNewRecipient
        }
        if contains(text, ["oauth", "authorize", "grant access", "accept terms", "sign up", "create account"]) {
            return .grantingAccess
        }
        if contains(text, ["system settings", "systemsetup", "csrutil", "spctl", "tccutil", "sudo "]) {
            return .changingSystemConfiguration
        }
        return nil
    }

    private func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// The command text of a shell action, or nil when this is not one.
    private func shellCommand(in action: ProposedAction) -> String? {
        guard action.tool.hasPrefix("shell.") else { return nil }
        guard let command = action.arguments["command"], !command.isEmpty else { return nil }
        return command
    }

    /// Whether a resolved path is somewhere this bot may already write. Prefix matching on a
    /// real path, unlike `insideWorkspace(_:)` below, which searches a rendered string.
    private func pathInsideWorkspace(_ path: String) -> Bool {
        contract.authority.writable.contains { pattern in
            let base = (pattern as NSString).expandingTildeInPath
                .replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "/*", with: "")
            guard !base.isEmpty, base != "/" else { return false }
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    private func insideWorkspace(_ detail: String) -> Bool {
        contract.authority.writable.contains { pattern in
            let base = (pattern as NSString).expandingTildeInPath
                .replacingOccurrences(of: "/**", with: "")
            return detail.contains(base)
        }
    }

    // MARK: - Rule matching

    /// Does this rule govern this action?
    ///
    /// The eval suite caught the first version of this being dangerously naive. A rule reading
    /// *"push code to a remote"* failed to match `git push origin main`, because only one of
    /// its three content words ("push") appears in the command — "code" and "remote" do not.
    /// A user's safety rule silently did nothing, which is the worst possible failure for this
    /// component.
    ///
    /// Two changes fix it:
    ///
    /// **A lexicon of what dangerous verbs actually look like in practice.** Users write
    /// "push code to a remote"; commands say `git push`. Users write "spend money"; commands
    /// say `stripe` or `checkout`. Bridging that gap deterministically is worth more than any
    /// amount of cleverness about word overlap.
    ///
    /// **An asymmetric threshold.** A near-miss on a *restricting* rule counts as a match; a
    /// near-miss on a *permitting* rule does not. Being unsure should never widen what a bot
    /// may do, and should always narrow it. That asymmetry is the whole safety argument for
    /// keeping a fuzzy matcher in this position at all.
    ///
    /// This is still the deterministic fast path. Genuinely understanding "reply to emails for
    /// me" needs a small model, and that remains the plan — but it must never be the *only*
    /// thing standing between a rule and the action it was written to stop.
    private func overlaps(_ rule: String, _ action: ProposedAction) -> Bool {
        let ruleText = rule.lowercased()
        let actionText = (action.tool + " " + action.summary + " " + action.detail).lowercased()

        // What people say, and what it looks like when it happens.
        let lexicon: [(phrases: [String], signals: [String])] = [
            (["push", "publish code", "upload code"],       ["git push", "git.push", "gh release"]),
            (["commit"],                                     ["git commit", "git.commit"]),
            (["merge"],                                      ["git merge", "merge_main", "gh pr merge"]),
            (["delete", "remove", "erase", "trash"],         ["rm ", "rm -", "unlink", "files.delete", "rmdir"]),
            (["send", "email", "mail", "message", "reply"],  ["mail", "sendmail", "smtp", "gmail", "message", "send"]),
            (["post", "tweet", "publish"],                   ["post", "tweet", "publish"]),
            (["spend", "buy", "purchase", "pay", "money"],   ["stripe", "checkout", "payment", "purchase", "billing"]),
            (["deploy", "release", "ship"],                  ["deploy", "vercel", "fly deploy", "kubectl apply"]),
            (["install"],                                    ["install", "brew ", "npm i", "pip install"]),
            (["restart", "reboot"],                          ["restart", "reboot", "kill "]),
            (["browse", "website", "web", "internet"],       ["browser.", "http", "curl", "web."]),
            (["read", "look at", "open"],                    ["files.read", "cat ", "web.read"]),
            (["change files", "edit", "modify", "write"],    ["files.write", "files.patch", "> ", "tee "]),
            (["run", "command", "shell", "terminal"],        ["shell.exec", "shell."]),
        ]

        var strongSignal = false
        for entry in lexicon where entry.phrases.contains(where: { ruleText.contains($0) }) {
            if entry.signals.contains(where: { actionText.contains($0) }) { strongSignal = true; break }
        }

        // Plain word overlap, as a secondary signal.
        let stop: Set<String> = ["the", "a", "an", "my", "me", "for", "to", "of", "in", "on",
                                 "and", "or", "that", "this", "it", "is", "are", "with", "i",
                                 "you", "your", "any", "some", "gave", "give", "inside", "from"]
        let words = Set(ruleText
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) })
        let overlap = words.isEmpty ? 0
            : Double(words.filter { actionText.contains(stem($0)) }.count) / Double(words.count)

        // Restricting rules match on any strong signal or a third of the words. Permitting
        // rules need a strong signal or a clear majority. Uncertainty narrows, never widens.
        let behaviour = rules.first { $0.whenBotWantsTo.lowercased() == ruleText }?.behaviour
        let restricting = behaviour != .allowAutomatically
        return restricting ? (strongSignal || overlap >= 0.34)
                           : (strongSignal || overlap > 0.6)
    }

    /// Crude suffix stripping so "pushes" and "pushing" match "push". Not linguistics — just
    /// enough that a plural in a rule does not defeat it.
    private func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > 4 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}
