import XCTest
@testable import BotHarnessCore

/// The ledger exists to stop a stopped-and-restarted run from sending the same email twice. These
/// pin the two ways that goes wrong: recording too little (a duplicate effect) and recording too
/// much (ordinary commands refused as "already done").
final class EffectLedgerTests: XCTestCase {

    func testTheSameEffectHasTheSameKeyRegardlessOfArgumentOrder() {
        let a = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z", "body": "hi"])
        let b = EffectLedger.key(tool: "mail.send", arguments: ["body": "hi", "to": "x@y.z"])
        XCTAssertEqual(a, b, "key order in the model's JSON must not make one action look like two")
    }

    func testDifferentContentIsADifferentEffect() {
        let a = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z", "body": "hi"])
        let b = EffectLedger.key(tool: "mail.send", arguments: ["to": "x@y.z", "body": "hello"])
        XCTAssertNotEqual(a, b)
    }

    func testReadOnlyShellCommandsAreNotTreatedAsEffects() {
        // The first version of this ledgered every shell.exec, which meant running `ls` in two
        // consecutive runs got the second one refused as already completed.
        for command in ["ls", "ls -la ~/Desktop", "cat README.md", "grep -r foo .",
                        "echo hello", "pwd", "which node"] {
            XCTAssertFalse(AgentLoop.commandChangesSomething(command), "wrongly an effect: \(command)")
        }
    }

    func testMutatingShellCommandsAreEffects() {
        for command in ["rm -rf build", "git push origin main", "npm install",
                        "echo x > out.txt", "mv a b", "curl -X POST https://x.example -d @f"] {
            XCTAssertTrue(AgentLoop.commandChangesSomething(command), "missed effect: \(command)")
        }
    }

    func testAnUnreadableCommandIsTreatedAsAnEffect() {
        // Erring towards "yes" costs one advisory message; erring towards "no" costs a duplicated
        // side effect.
        XCTAssertTrue(AgentLoop.commandChangesSomething("rm -rf \"$UNCLOSED"))
    }

    func testAnInterruptedEffectIsRememberedAsUncertainNotFailed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("botharness-ledger-\(UUID().uuidString)")
        let ledger = EffectLedger(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"])
        await ledger.beginning(key, tool: "mail.send", summary: "mail to a@b.c")

        // Nothing recorded a result — the crash case. It must read as "we do not know",
        // because recording it as failed would let a retry send the message twice.
        let entry = await ledger.existing(key)
        XCTAssertEqual(entry?.outcome, .uncertain)
        let advice = await ledger.advisory(for: try XCTUnwrap(entry))
        XCTAssertTrue(advice.contains("never confirmed"), advice)
    }

    func testACompletedEffectIsNotRepeated() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("botharness-ledger-\(UUID().uuidString)")
        let ledger = EffectLedger(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = EffectLedger.key(tool: "mail.send", arguments: ["to": "a@b.c"])
        await ledger.beginning(key, tool: "mail.send", summary: "mail to a@b.c")
        await ledger.finished(key, outcome: .done, note: "sent")

        // A fresh ledger over the same file: this is the across-runs case the whole type exists
        // for, so reading it back from disk rather than memory is the point of the test.
        let reopened = EffectLedger(root: root)
        let entry = await reopened.existing(key)
        XCTAssertEqual(entry?.outcome, .done)
    }
}
