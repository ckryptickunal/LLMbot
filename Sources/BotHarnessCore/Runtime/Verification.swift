import Foundation

/// Verification, stuck detection, and recovery.
///
/// These three are the difference between a demo and a tool, and none of them is model
/// intelligence. They are harness playbooks: deterministic responses to situations that recur
/// in every long run and that a model handles inconsistently when left to improvise.

// MARK: - Verification

/// Decides whether an action actually achieved anything, and whether a run is actually over.
///
/// The rule this enforces: **"I performed the action" never means "the objective succeeded."**
/// A model that clicked Save believes it saved. The harness asks whether anything saved.
public struct Verifier {

    public init() {}

    public enum Result: Equatable {
        case passed(evidence: String)
        case failed(reason: String)
        /// No deterministic check exists and no judge was available. Treated as failure for
        /// completion purposes: an unverifiable success criterion is not a met one.
        case indeterminate(reason: String)

        var isPass: Bool { if case .passed = self { return true }; return false }
    }

    /// Check one success criterion.
    ///
    /// Deterministic kinds are answered by running something. Only `.judged` needs a model,
    /// and it is deliberately last in `SuccessCriterion.Kind` so that writing one feels like
    /// the fallback it is.
    public func verify(_ criterion: SuccessCriterion, using runner: CommandRunning) async -> Result {
        switch criterion.kind {
        case .command(let cmd):
            let out = await runner.run(cmd)
            return out.exitCode == 0
                ? .passed(evidence: "`\(cmd)` exited 0")
                : .failed(reason: "`\(cmd)` exited \(out.exitCode): \(out.stderr.prefix(400))")

        case .http(let url, let expect):
            let out = await runner.run("curl -s -o /dev/null -w '%{http_code}' --max-time 15 '\(url)'")
            let code = Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            return code == expect
                ? .passed(evidence: "\(url) returned \(code)")
                : .failed(reason: "\(url) returned \(code), expected \(expect)")

        case .fileChanged(let path):
            let expanded = (path as NSString).expandingTildeInPath
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
                  let modified = attrs[.modificationDate] as? Date
            else { return .failed(reason: "\(path) does not exist") }
            return .passed(evidence: "\(path) last modified \(modified)")

        case .outputContains(let needle):
            return .indeterminate(reason: "needs the output of the step that produced '\(needle)'")

        case .judged(let question):
            return .indeterminate(reason: "needs a model to answer: \(question)")
        }
    }

    /// Whether the run may declare itself finished.
    ///
    /// This is what creates agency. A model that says "I've identified the likely problem" on
    /// a contract whose objective is resolution gets sent back in, and it gets sent back in by
    /// the harness rather than by the user noticing.
    public func completion(of contract: TaskContract) -> Completion {
        let unmet = contract.successCriteria.filter { !$0.isVerified }
        if contract.successCriteria.isEmpty {
            return .cannotTell("this task has no success criteria, so there is nothing to check against")
        }
        return unmet.isEmpty ? .complete : .notComplete(outstanding: unmet.map(\.statement))
    }

    public enum Completion: Equatable {
        case complete
        case notComplete(outstanding: [String])
        case cannotTell(String)
    }

    /// The message sent back to the model when it stops early. Deliberately flat and factual —
    /// it states what remains, not that the model was wrong.
    public func continuationNotice(outstanding: [String]) -> String {
        let list = outstanding.map { "- \($0)" }.joined(separator: "\n")
        return """
        Not finished. These success criteria are not yet verified:

        \(list)

        Keep going until each one has evidence, or escalate if you are genuinely blocked.
        """
    }
}

/// Anything that can run a command. A protocol so the verifier is testable without a shell,
/// and so it works identically against a container later.
public protocol CommandRunning: Sendable {
    func run(_ command: String) async -> CommandOutput
}

public struct CommandOutput: Sendable {

    /// Memberwise initialiser, public so the app and tests can build one.
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

// MARK: - Stuck detection

/// Notices that a run has stopped making progress, before the step budget notices for it.
///
/// The failure this prevents is the expensive one: an agent that retries the same click
/// fourteen times, each retry costing a screenshot and a model call, and each one failing for
/// the reason the first one did. The response to being stuck is never "try again" — it is
/// always "change strategy".
public struct StuckDetector {

    public init() {}
    /// How many identical observations before we call it.
    public var repeatThreshold = 3
    /// How many steps with no state change at all before we call it.
    public var noChangeThreshold = 4

    private var recentActions: [String] = []
    private var recentObservations: [String] = []
    private var recentErrors: [String] = []
    private var stepsWithoutChange = 0

    public enum Signal: Equatable {
        case repeatingAction(String)
        case repeatingObservation
        case repeatingError(String)
        case noStateChange(steps: Int)
        case oscillating(between: String, and: String)
    }

    /// Record a step and return a signal if the run has stopped progressing.
    ///
    /// `observation` should be a cheap digest — a hash of the screen, the URL, the exit code —
    /// not the full content.
    public mutating func record(action: String, observation: String, error: String?, stateChanged: Bool) -> Signal? {
        recentActions.append(action)
        recentObservations.append(observation)
        if let error { recentErrors.append(error) }
        if recentActions.count > 8 { recentActions.removeFirst() }
        if recentObservations.count > 8 { recentObservations.removeFirst() }
        if recentErrors.count > 8 { recentErrors.removeFirst() }

        stepsWithoutChange = stateChanged ? 0 : stepsWithoutChange + 1

        if let e = recentErrors.last, tail(recentErrors, repeatThreshold).allSatisfy({ $0 == e }),
           recentErrors.count >= repeatThreshold {
            return .repeatingError(e)
        }
        if tail(recentActions, repeatThreshold).allSatisfy({ $0 == action }),
           recentActions.count >= repeatThreshold {
            return .repeatingAction(action)
        }
        if tail(recentObservations, repeatThreshold).allSatisfy({ $0 == observation }),
           recentObservations.count >= repeatThreshold {
            return .repeatingObservation
        }
        if stepsWithoutChange >= noChangeThreshold {
            return .noStateChange(steps: stepsWithoutChange)
        }
        // A ↔ B ↔ A ↔ B: two states alternating is progress-shaped but is not progress.
        if recentObservations.count >= 4 {
            let last4 = Array(recentObservations.suffix(4))
            if last4[0] == last4[2], last4[1] == last4[3], last4[0] != last4[1] {
                return .oscillating(between: last4[0], and: last4[1])
            }
        }
        return nil
    }

    public mutating func reset() {
        recentActions.removeAll(); recentObservations.removeAll()
        recentErrors.removeAll(); stepsWithoutChange = 0
    }

    private func tail<T>(_ array: [T], _ n: Int) -> ArraySlice<T> { array.suffix(n) }
}

// MARK: - Recovery

/// What to do when something failed, in order, without asking the model to invent it.
///
/// Each playbook ends at "ask the user" — but only after genuinely different strategies have
/// been tried, which is what makes an eventual escalation credible rather than lazy.
public enum RecoveryPlaybook {

    /// A GUI click did not do what it should have.
    ///
    /// The first step is the one most agents skip and the one that most often ends the
    /// problem: check whether the click actually worked and the observation was just stale.
    public static let clickFailed: [String] = [
        "Check whether the state changed anyway — the action may have worked and the screenshot may be stale.",
        "Re-read the accessibility tree; the control may have moved, been renamed, or be disabled.",
        "Retry by accessible name or element identifier rather than by coordinate.",
        "Scroll the element into view and retry.",
        "Retry visually at a fresh screenshot's coordinates.",
        "Reload or restart the view, then retry once.",
        "Switch surface: if there is an API, a command, or a DOM selector for this, use that instead.",
        "Escalate: say what was attempted, what was observed, and what you need.",
    ]

    /// A test failed. The instruction that matters is *minimally* — the common failure is an
    /// agent that rewrites a module to fix an assertion.
    public static let testFailed: [String] = [
        "Read the actual failure output before changing anything.",
        "Locate the implementation the failing assertion covers.",
        "Form one hypothesis about the cause and state it.",
        "Patch minimally — change what is wrong, not what is nearby.",
        "Re-run only that test.",
        "When it passes, run the full suite to check nothing else broke.",
    ]

    /// A command failed for what looks like an environment problem. These are the failures
    /// that make an agent feel helpless, so `Authority.selfRepair` covers most of them.
    public static let environmentFailed: [String] = [
        "Read the error. Distinguish a missing dependency from a wrong invocation.",
        "If a dependency is missing and self-repair is authorised, install it and retry.",
        "If a port is in use, identify the process; if it is stale and yours, stop it and retry.",
        "If a service is not running, start it and wait for it to become ready.",
        "If the working directory or a required path is missing, create it.",
        "Retry once. If it fails the same way, stop retrying and change approach.",
        "Escalate only if the fix needs a credential or a permission you do not hold.",
    ]

    /// A page did not load or behaved unexpectedly.
    public static let browserFailed: [String] = [
        "Check the actual HTTP status and the page text before assuming the browser is at fault.",
        "Wait for the network to settle and re-read; the page may simply not have finished.",
        "Dismiss any cookie or consent overlay, choosing the most private option.",
        "If redirected to a sign-in page, stop — do not attempt to log in. Escalate for credentials.",
        "Try the page's underlying API or feed if one exists.",
        "Escalate with the URL, the status, and what was expected.",
    ]

    public static func forSignal(_ signal: StuckDetector.Signal) -> [String] {
        switch signal {
        case .repeatingAction, .repeatingObservation, .oscillating:
            return clickFailed
        case .repeatingError(let e) where e.lowercased().contains("not found")
                                      || e.lowercased().contains("no such")
                                      || e.lowercased().contains("command not found"):
            return environmentFailed
        case .repeatingError, .noStateChange:
            return [
                "Stop repeating the last action; it has failed identically more than once.",
                "State what you expected to happen and what actually happened.",
                "Change surface or change approach — do not retry the same way again.",
                "If no different approach exists, escalate with both observations.",
            ]
        }
    }
}
