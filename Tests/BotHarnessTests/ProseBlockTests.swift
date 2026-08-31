import XCTest
@testable import BotHarnessCore

/// The transcript renderer's split between prose and code.
///
/// This exists because of one specific failure: a bot answering a question about files replies
/// with a fenced shell block, and inline-only markdown flattened it — language tag leaked into
/// the sentence, newlines gone, two commands fused into one line. In an app whose bots write
/// shell commands, handing someone a copyable-looking string that is wrong is a real hazard,
/// not a typographic one.
final class ProseBlockTests: XCTestCase {

    private func kinds(_ text: String) -> [String] {
        ProseBlock.parse(text).map {
            if case .code = $0 { return "code" } else { return "prose" }
        }
    }

    private func codeBodies(_ text: String) -> [String] {
        ProseBlock.parse(text).compactMap {
            if case .code(_, let body) = $0 { return body } else { return nil }
        }
    }

    func testPlainProseIsOneBlock() {
        XCTAssertEqual(kinds("just a sentence"), ["prose"])
    }

    func testEmptyTextProducesNothing() {
        XCTAssertEqual(ProseBlock.parse("").count, 0)
        XCTAssertEqual(ProseBlock.parse("   \n  ").count, 0)
    }

    func testAFenceIsSeparatedFromTheProseAroundIt() {
        let text = "Here is the plan:\n```bash\nmkdir -p a\nmv b a/\n```\nDry run first."
        XCTAssertEqual(kinds(text), ["prose", "code", "prose"])
    }

    func testNewlinesInsideAFenceSurvive() {
        let text = "x\n```\nmkdir -p a\nmv b a/\n```"
        // The exact failure from the audit: two commands must not become one line.
        XCTAssertEqual(codeBodies(text), ["mkdir -p a\nmv b a/"])
    }

    func testTheLanguageTagNeverLeaksIntoTheProse() {
        let blocks = ProseBlock.parse("```bash\nls\n```")
        guard case .code(let language, let body) = blocks[0] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "bash")
        XCTAssertEqual(body, "ls")
        XCTAssertFalse(body.contains("bash"))
    }

    func testAFenceWithNoLanguageHasNone() {
        let blocks = ProseBlock.parse("```\nls\n```")
        guard case .code(let language, _) = blocks[0] else { return XCTFail("expected code") }
        XCTAssertNil(language)
    }

    func testTwoFencesStayApart() {
        let text = "one\n```\na\n```\ntwo\n```\nb\n```\nthree"
        XCTAssertEqual(kinds(text), ["prose", "code", "prose", "code", "prose"])
        XCTAssertEqual(codeBodies(text), ["a", "b"])
    }

    /// A stream is rendered while it arrives, so a half-written fence is the normal case rather
    /// than an error. It must still come out as code — not as prose with backticks in it.
    func testAnUnclosedFenceIsStillTreatedAsCode() {
        let blocks = ProseBlock.parse("here:\n```bash\nrm -rf /tmp/x")
        XCTAssertEqual(kinds("here:\n```bash\nrm -rf /tmp/x"), ["prose", "code"])
        guard case .code(_, let body) = blocks[1] else { return XCTFail("expected code") }
        XCTAssertEqual(body, "rm -rf /tmp/x")
    }

    func testAnIndentedFenceMarkerStillOpensABlock() {
        XCTAssertEqual(kinds("x\n   ```\na\n   ```\ny"), ["prose", "code", "prose"])
    }

    func testProseKeepsItsInlineMarkdownUntouched() {
        let blocks = ProseBlock.parse("tidy the **screenshots** in `~/Desktop`")
        guard case .prose(let body) = blocks[0] else { return XCTFail("expected prose") }
        XCTAssertTrue(body.contains("**screenshots**"), "inline markdown is rendered downstream")
    }

    func testBlankProseBetweenFencesIsDropped() {
        XCTAssertEqual(kinds("```\na\n```\n\n```\nb\n```"), ["code", "code"])
    }

    func testTextWithNoFenceIsNeverSplit() {
        let text = "a sentence with a stray ` backtick"
        XCTAssertEqual(kinds(text), ["prose"])
    }
}
