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

    private func insideWorkspace(_ detail: String) -> Bool {
        contract.authority.writable.contains { pattern in
            let base = (pattern as NSString).expandingTildeInPath
                .replacingOccurrences(of: "/**", with: "")
            return detail.contains(base)
        }
    }

    // MARK: - Rule matching

    /// Cheap overlap between a rule's plain-language phrasing and the proposed action.
    ///
    /// This is the deterministic fast path only. A rule like "reply to emails for me" should
    /// eventually be matched semantically by a small model — the whole point of natural
    /// language rules is that they cover intent rather than syntax. Until that exists, this
    /// matches on content words, and **anything it does not match falls through to the
    /// autonomy default**, which for a new bot means asking. Failing toward asking is the
    /// correct direction for a component that is knowingly incomplete.
    private func overlaps(_ rule: String, _ action: ProposedAction) -> Bool {
        let stop: Set<String> = ["the", "a", "an", "my", "me", "for", "to", "of", "in", "on",
                                 "and", "or", "that", "this", "it", "is", "are", "with", "i",
                                 "you", "your", "any", "some", "gave", "give", "inside"]
        let words = Set(rule.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) })
        guard !words.isEmpty else { return false }

        let text = (action.tool + " " + action.summary + " " + action.detail).lowercased()
        let hits = words.filter { text.contains($0) }.count
        // Over half the rule's content words present. A single incidental word is not a match.
        return Double(hits) / Double(words.count) > 0.5
    }
}
