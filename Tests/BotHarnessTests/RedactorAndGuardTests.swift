import XCTest
@testable import BotHarnessCore

/// The streaming redactor exists because of one specific failure: a secret split across two
/// stream chunks. These assert that case directly, because it is the one a naive
/// implementation gets wrong and the one nobody notices until a key is in a log.
final class StreamingRedactorTests: XCTestCase {

    private let key = "AIzaSyC0123456789abcdefghijklmnopqrstuvw"

    func testRedactsASecretThatArrivesWhole() {
        var redactor = StreamingRedactor(secrets: [key])
        var out = redactor.push("the key is \(key) ok")
        out += redactor.finish()
        XCTAssertFalse(out.contains(key))
        XCTAssertTrue(out.contains("«redacted»"))
    }

    func testRedactsASecretSplitAcrossChunks() {
        var redactor = StreamingRedactor(secrets: [key])
        let midpoint = key.index(key.startIndex, offsetBy: 17)
        var out = redactor.push("here it is: " + String(key[..<midpoint]))
        out += redactor.push(String(key[midpoint...]) + " and that is all")
        out += redactor.finish()

        XCTAssertFalse(out.contains(key), "a secret straddling a chunk boundary must still be caught")
        XCTAssertTrue(out.contains("«redacted»"))
        XCTAssertTrue(out.contains("and that is all"), "surrounding text must survive")
    }

    func testRedactsASecretSplitOneCharacterAtATime() {
        // The worst case, and the one token-by-token streaming actually produces.
        var redactor = StreamingRedactor(secrets: [key])
        var out = ""
        for character in "prefix \(key) suffix" { out += redactor.push(String(character)) }
        out += redactor.finish()
        XCTAssertFalse(out.contains(key))
        XCTAssertTrue(out.contains("prefix"))
        XCTAssertTrue(out.contains("suffix"))
    }

    func testEmitsEverythingWhenThereAreNoSecrets() {
        var redactor = StreamingRedactor(secrets: [])
        var out = redactor.push("nothing to hide")
        out += redactor.finish()
        XCTAssertEqual(out, "nothing to hide")
    }

    func testPrefersTheLongerOfTwoOverlappingSecrets() {
        // A short secret contained in a longer one must not leave the longer one's tail behind.
        var redactor = StreamingRedactor(secrets: ["abcdefgh", "abcdefghijklmnop"])
        var out = redactor.push("value=abcdefghijklmnop.")
        out += redactor.finish()
        XCTAssertFalse(out.contains("ijklmnop"), "the longer secret should be matched whole")
    }

    func testIgnoresValuesTooShortToBeSecrets() {
        // Redacting a 3-character "secret" would destroy ordinary prose.
        var redactor = StreamingRedactor(secrets: ["the"])
        var out = redactor.push("the quick brown fox")
        out += redactor.finish()
        XCTAssertEqual(out, "the quick brown fox")
    }
}

/// The loop guard's contract is not only that it trips, but that tripping is a *completion*.
final class LoopGuardTests: XCTestCase {

    func testTripsAfterSixIdenticalCalls() {
        var guardian = LoopGuard()
        var explanation: String?
        for _ in 1...6 {
            explanation = guardian.record(tool: "files.glob", arguments: "pattern=*")
        }
        XCTAssertNotNil(explanation)
        XCTAssertTrue(explanation!.contains("files.glob"), "the message should name the tool")
        XCTAssertTrue(explanation!.contains("6"), "the message should say how many times")
    }

    func testDoesNotTripWhenArgumentsChange() {
        var guardian = LoopGuard()
        for i in 1...20 {
            let explanation = guardian.record(tool: "files.read", arguments: "path=/f\(i)")
            XCTAssertNil(explanation, "varied calls are progress, not a loop")
        }
    }

    func testResetsWhenADifferentToolIntervenes() {
        var guardian = LoopGuard()
        for _ in 1...5 { _ = guardian.record(tool: "shell.exec", arguments: "ls") }
        _ = guardian.record(tool: "files.read", arguments: "path=/a")
        for _ in 1...5 {
            XCTAssertNil(guardian.record(tool: "shell.exec", arguments: "ls"),
                         "the streak should have restarted")
        }
    }
}
