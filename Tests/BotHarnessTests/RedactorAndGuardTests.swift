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

/// The pattern redactor, at the level of one string, where the two halves of the trade are
/// visible together: what it must catch, and what it must leave alone.
final class RedactorPatternTests: XCTestCase {

    private func assertRedacted(_ text: String, keeping surviving: String? = nil,
                                _ message: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        let out = Redactor.redact(text)
        XCTAssertTrue(out.contains("«redacted»"), message, file: file, line: line)
        if let surviving {
            XCTAssertTrue(out.contains(surviving),
                          "\(surviving) is not the secret and should have survived",
                          file: file, line: line)
        }
    }

    /// The header as it is actually written. The old rule wanted eight non-space characters
    /// immediately after the colon, and what is actually there is "Bearer" — six, then a space —
    /// so the key behind it went into the trace verbatim.
    func testRedactsAKeyBehindABearerScheme() {
        let text = "Authorization: Bearer sk-proj-LEAK1abc123DEF456ghi789JKL012mno"
        let out = Redactor.redact(text)
        XCTAssertFalse(out.contains("LEAK1abc123"), "the key behind the scheme word must go")
        XCTAssertTrue(out.contains("«redacted»"))
    }

    func testRedactsASchemeWordWithNoRecognisableKeyAfterIt() {
        // The value here matches no vendor prefix at all; only the label rule can catch it, so
        // this fails if the scheme skip is removed and the `sk-` rule is left to do the work.
        assertRedacted("Authorization: Basic ZmFrZTp1c2VyOnBhc3N3b3JkMTIz",
                       "a Basic credential is a credential")
    }

    func testRedactsTheCurrentOpenAIProjectKeyFormat() {
        // `sk-[A-Za-z0-9]{32,}` broke on the hyphen four characters in, so the format most keys
        // in circulation are issued in matched nothing.
        assertRedacted("sk-proj-LEAK2abc123DEF456ghi789JKL012mno", "sk-proj- is still an sk key")
    }

    func testRedactsGitLabAndStripeKeys() {
        assertRedacted("glpat-LEAK3abc123DEF456ghi7", "a GitLab token matched no rule at all")
        assertRedacted("rk_live_LEAK4abc123DEF456ghi789", "a Stripe restricted key is live access")
        assertRedacted("sk_live_LEAK5abc123DEF456ghi789", "a Stripe secret key is full access")
    }

    func testRedactsADatabaseURLCarryingItsPassword() {
        let out = Redactor.redact("psql postgres://user:password@host/db failed")
        XCTAssertFalse(out.contains("user:password"), "the credentials in a URL are credentials")
        XCTAssertTrue(out.contains("psql"), "the line around it must stay readable")
    }

    func testRedactsAKeyInsideAJSONBody() {
        let out = Redactor.redact(#"{"api_key":"LEAK6abc123DEF456ghi789"}"#)
        XCTAssertFalse(out.contains("LEAK6abc123"))
        XCTAssertTrue(out.contains("}"), "stopping at the quote keeps the body readable")
    }

    // MARK: - What it must not touch

    /// The cost of letting the `sk-` rule accept hyphens. Without a word boundary in front of it,
    /// `sk-` occurs inside ordinary hyphenated English and this sentence comes back with a hole
    /// in it — and a trace with words blanked out of it is one nobody trusts.
    func testLeavesOrdinaryHyphenatedProseAlone() {
        let prose = "ran the task-oriented-agent-workflow again and it worked"
        XCTAssertEqual(Redactor.redact(prose), prose)
    }

    func testLeavesURLsWithNoCredentialsInThemAlone() {
        for url in ["https://docs.example.com/guides/postgres-setup",
                    "http://localhost:8080/health"] {
            XCTAssertEqual(Redactor.redact(url), url, "\(url) carries no secret")
        }
    }

    func testLeavesALabelWithNothingSecretAfterItAlone() {
        // Eight characters is the floor, and "Bearer" alone is six with nothing behind it.
        let text = "Authorization: Bearer"
        XCTAssertEqual(Redactor.redact(text), text)
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
