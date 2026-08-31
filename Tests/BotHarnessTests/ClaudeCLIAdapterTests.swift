import XCTest
@testable import BotHarnessCore

/// Tests for the brain that drives the local `claude` command.
///
/// **Nothing here installs, signs into, or spends money on the CLI.** Every stream in this file
/// is a fixture captured from `claude 2.1.238` on 2026-08-31 and pasted in, so the suite is the
/// same on a machine that has never heard of Claude Code. The one case that genuinely needs the
/// binary skips itself when it is absent.
///
/// The argument tests are the load-bearing ones. They exist because the flags they check are
/// the only thing standing between this adapter and a CLI that would run shell commands on the
/// user's Mac without the permission floor ever seeing them — see `ClaudeCLIAdapter`'s type
/// comment. A future simplification that drops one should fail here rather than ship.
final class ClaudeCLIAdapterTests: XCTestCase {

    private func request(tools: [ToolDescriptor] = [], turns: [BrainTurn] = [],
                         system: String = "You are Joby.") -> BrainRequest {
        BrainRequest(system: system, turns: turns, tools: tools)
    }

    private let readTool = ToolDescriptor(
        id: "files.read", domain: .files, surface: .code,
        summary: "Read a file, or a line range of one.",
        schema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#,
        capability: "files.read")

    // MARK: - The flags that keep the CLI's hands off the machine

    func testTheCLIIsGivenNoToolsOfItsOwn() {
        let arguments = ClaudeCLIAdapter.commandArguments(for: request(), model: nil)
        guard let index = arguments.firstIndex(of: "--tools") else {
            return XCTFail("--tools is missing, so the CLI keeps its shell, editor and browser")
        }
        // The empty string is the CLI's own spelling for "disable all tools". Verified: the
        // init line comes back as "tools":["StructuredOutput"] and nothing else.
        XCTAssertEqual(arguments[index + 1], "")
    }

    func testMCPServersAndSettingsAreShutOut() {
        let arguments = ClaudeCLIAdapter.commandArguments(for: request(), model: nil)
        XCTAssertTrue(arguments.contains("--strict-mcp-config"),
                      "without this the CLI loads every MCP server the user has configured")

        guard let sources = arguments.firstIndex(of: "--setting-sources") else {
            return XCTFail("--setting-sources is missing, so project hooks would load and run")
        }
        XCTAssertEqual(arguments[sources + 1], "")
    }

    func testPermissionModeNeverAutoApproves() {
        let arguments = ClaudeCLIAdapter.commandArguments(for: request(), model: nil)
        guard let index = arguments.firstIndex(of: "--permission-mode") else {
            return XCTFail("--permission-mode is missing")
        }
        // "manual" means ask a human, and `--print` has none, so a tool that somehow appeared
        // is denied. "bypassPermissions", "dontAsk", "auto" and "acceptEdits" all mean the
        // opposite and none of them may ever be the value here.
        XCTAssertEqual(arguments[index + 1], "manual")
    }

    func testTheDangerousFlagsAreNeverPassed() {
        let arguments = ClaudeCLIAdapter.commandArguments(for: request(), model: nil)
        for flag in ["--dangerously-skip-permissions",
                     "--allow-dangerously-skip-permissions",
                     "--add-dir",
                     "--mcp-config",
                     "--allowedTools",
                     "--allowed-tools"] {
            XCTAssertFalse(arguments.contains(flag), "\(flag) must never be sent")
        }
    }

    /// Not a safety flag, but the CLI refuses to start without it: "When using --print,
    /// --output-format=stream-json requires --verbose". Losing it turns every turn into a
    /// startup error.
    func testStreamingOutputCarriesTheFlagItRequires() {
        let arguments = ClaudeCLIAdapter.commandArguments(for: request(), model: nil)
        XCTAssertTrue(arguments.contains("--print"))
        XCTAssertTrue(arguments.contains("--verbose"))
        guard let format = arguments.firstIndex(of: "--output-format") else {
            return XCTFail("--output-format is missing")
        }
        XCTAssertEqual(arguments[format + 1], "stream-json")
    }

    func testTheModelIsOnlySentWhenTheBotChoseOne() {
        XCTAssertFalse(ClaudeCLIAdapter.commandArguments(for: request(), model: nil).contains("--model"))
        let pinned = ClaudeCLIAdapter.commandArguments(for: request(), model: "opus")
        guard let index = pinned.firstIndex(of: "--model") else { return XCTFail("--model missing") }
        XCTAssertEqual(pinned[index + 1], "opus")
    }

    func testTheEnvironmentCannotChangeWhoAnswersOrWhoPays() {
        let environment = ClaudeCLIAdapter.minimalEnvironment()
        // Inheriting either of these silently bills a metered API, or ships the conversation to
        // a proxy, for a brain the user picked because Settings said "no API key needed".
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
        // HOME is where the CLI finds its config and its Keychain item. Without it there is no
        // subscription to bill.
        XCTAssertEqual(environment["HOME"], NSHomeDirectory())
        XCTAssertTrue((environment["PATH"] ?? "").contains(".local/bin"))
    }

    // MARK: - The prompt

    func testTheModelIsToldItHasNoHands() {
        let prompt = ClaudeCLIAdapter.systemPrompt(for: request(tools: [readTool]))
        XCTAssertTrue(prompt.contains("You are Joby."), "the harness's own system prompt is kept")
        XCTAssertTrue(prompt.contains("no tools of your own"))
        XCTAssertTrue(prompt.contains("files.read"))
        XCTAssertTrue(prompt.contains("Read a file, or a line range of one."))
        XCTAssertTrue(prompt.contains(#""path""#), "the tool's schema has to reach the model")
    }

    func testWithNoToolsTheModelIsToldToAskForNothing() {
        let prompt = ClaudeCLIAdapter.systemPrompt(for: request(tools: []))
        XCTAssertTrue(prompt.contains("`actions` must be empty"))
    }

    func testTheTranscriptIsRenderedWithToolResultsAttributed() {
        let text = ClaudeCLIAdapter.prompt(for: request(turns: [
            .init(role: .user, text: "read the hosts file"),
            .init(role: .assistant, text: "Reading it now."),
            .init(role: .tool, text: "127.0.0.1 localhost", toolCallID: "files.read-0"),
        ]))
        XCTAssertTrue(text.contains("[user]\nread the hosts file"))
        XCTAssertTrue(text.contains("[you said]\nReading it now."))
        XCTAssertTrue(text.contains("[result of files.read-0]\n127.0.0.1 localhost"))
    }

    /// The adapter reports `canDriveComputer == false`, so `AgentLoop` never attaches one. If a
    /// future caller does anyway, saying nothing would read to the model as an empty screen.
    func testAScreenshotIsAdmittedToRatherThanDropped() {
        var withImage = request()
        withImage.screenshot = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(ClaudeCLIAdapter.prompt(for: withImage).contains("cannot see images"))
    }

    func testThisBrainDoesNotDriveTheComputer() {
        XCTAssertFalse(ClaudeCLIAdapter().canDriveComputer)
    }

    // MARK: - Reading the stream

    func testAnEnvelopeBecomesProseAndActions() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.oneToolCall)

        XCTAssertEqual(response.text, "Let me take a look at the repository contents.")
        XCTAssertEqual(response.actions.count, 2)

        XCTAssertEqual(response.actions[0].name, "shell.exec")
        XCTAssertEqual(response.actions[0].arguments["command"] as? String, "ls -la")
        XCTAssertEqual(response.actions[0].intent, "List the top-level files in the repo")

        XCTAssertEqual(response.actions[1].name, "files.read")
        XCTAssertEqual(response.actions[1].arguments["path"] as? String, "README.md")

        XCTAssertNotEqual(response.actions[0].id, response.actions[1].id,
                          "two calls in one turn need distinct ids or the trace cannot pair them")
        XCTAssertTrue(response.needsAction)
        // The CLI's safety judgement is absent rather than assumed. The floor treats a missing
        // decision and an allowed one differently, and only one of them is true here.
        XCTAssertNil(response.actions[0].safety)
    }

    func testCachedPromptTokensAreCountedAsSpend() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.oneToolCall)
        // 880 fresh + 3289 cache reads + 5936 cache writes. Counting only `input_tokens` makes a
        // long run look an order of magnitude cheaper than it is, and the budget that stops a
        // runaway loop is spent in these units.
        XCTAssertEqual(response.usage.promptTokens, 10_105)
        XCTAssertEqual(response.usage.completionTokens, 311)
        XCTAssertEqual(response.usage.costUSD, 0.008256, accuracy: 0.000001)
    }

    /// The session id is deliberately not returned: `AgentLoop` would hand it back and the
    /// adapter would have to `--resume` a session that `--no-session-persistence` never wrote.
    func testNoInteractionIDIsClaimed() throws {
        XCTAssertNil(try ClaudeCLIAdapter.parse(Fixtures.oneToolCall).interactionID)
    }

    func testAPlainReplyCarriesNoActions() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.plainAnswer)
        XCTAssertEqual(response.text, "Hi there, friend!")
        XCTAssertTrue(response.actions.isEmpty)
        XCTAssertFalse(response.needsAction)
    }

    func testThinkingAndTheStructuredOutputCallAreNotShownAsProse() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.thinkingThenEnvelope)
        // The stream carries an opaque thinking signature, a prose draft, and the envelope
        // holding a tidied version of the same sentence. Showing all three would print the
        // answer twice with a wall of base64 between.
        XCTAssertEqual(response.text, "I cannot reach that file from here.")
        XCTAssertFalse(response.text?.contains("EpYHCqgB") ?? false)
    }

    /// The envelope arrives as a JSON string in `result` with no `structured_output` beside it.
    /// Treating that as prose would print a raw JSON blob into the conversation, which is the
    /// most obvious way for a working adapter to look broken.
    func testAnEnvelopeIsStillReadWhenItArrivesOnlyAsAString() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.envelopeAsStringOnly)
        XCTAssertEqual(response.text, "Checking that now.")
        XCTAssertEqual(response.actions.first?.name, "files.read")
    }

    func testProseSurvivesWhenTheModelIgnoresTheSchema() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.noEnvelope)
        XCTAssertEqual(response.text, "There are four files in that folder.")
        XCTAssertTrue(response.actions.isEmpty)
    }

    func testNoiseInTheStreamDoesNotLoseTheTurn() throws {
        // The CLI prints update notices and warnings onto the same stream, and a rate-limit
        // event and a retry are normal. None of them may cost us a completed answer.
        let response = try ClaudeCLIAdapter.parse(Fixtures.withNoise)
        XCTAssertEqual(response.text, "Hi there, friend!")
    }

    func testAnActionWithNoToolNameIsDropped() throws {
        let response = try ClaudeCLIAdapter.parse(Fixtures.actionMissingToolName)
        XCTAssertEqual(response.actions.count, 1)
        XCTAssertEqual(response.actions[0].name, "files.read")
    }

    // MARK: - Failures that say what to do

    func testASignedOutCLIExplainsHowToSignIn() {
        XCTAssertThrowsError(try ClaudeCLIAdapter.parse(Fixtures.notLoggedIn)) { error in
            guard case ClaudeCLIAdapter.Failure.notSignedIn = error else {
                return XCTFail("expected notSignedIn, got \(error)")
            }
            let sentence = error.localizedDescription
            XCTAssertTrue(sentence.contains("not signed in"))
            XCTAssertTrue(sentence.contains("Terminal"), "the remedy has to name where to do it")
        }
    }

    /// `subtype` reads "success" even on a failed turn — verified against a real signed-out run
    /// — so anything keying off it instead of `is_error` reports a failure as an answer.
    func testTheFailedTurnStillCallsItselfSuccess() {
        XCTAssertTrue(Fixtures.notLoggedIn.contains(#""subtype":"success""#))
        XCTAssertThrowsError(try ClaudeCLIAdapter.parse(Fixtures.notLoggedIn))
    }

    func testAUsageLimitIsNotReportedAsABrokenApp() {
        XCTAssertThrowsError(try ClaudeCLIAdapter.parse(Fixtures.rateLimited)) { error in
            guard case ClaudeCLIAdapter.Failure.rateLimited = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("usage limit"))
        }
    }

    func testAStreamWithNoResultLineIsAnError() {
        XCTAssertThrowsError(try ClaudeCLIAdapter.parse("not json at all\n{\"type\":\"system\"}")) { error in
            guard case ClaudeCLIAdapter.Failure.unreadableOutput = error else {
                return XCTFail("expected unreadableOutput, got \(error)")
            }
            // The likeliest cause is a CLI too old for these flags, so the sentence has to send
            // the user somewhere they can check that.
            XCTAssertTrue(error.localizedDescription.contains("claude --version"))
        }
    }

    func testEveryFailureNamesSomethingToDo() {
        let failures: [ClaudeCLIAdapter.Failure] = [
            .binaryMissing,
            .notSignedIn,
            .rateLimited(detail: "five_hour"),
            .timedOut(seconds: 300),
            .cliReportedError(detail: "boom"),
            .unreadableOutput(exitCode: 1, detail: "boom"),
        ]
        for failure in failures {
            let sentence = failure.errorDescription ?? ""
            XCTAssertFalse(sentence.isEmpty, "\(failure) has no message")
            XCTAssertTrue(sentence.count > 40, "\(failure) is too terse to act on: \(sentence)")
        }
    }

    func testAMissingBinaryIsNotConfiguredAndSaysSo() async {
        let adapter = ClaudeCLIAdapter(binary: "/nonexistent/claude")
        let configured = await adapter.isConfigured()
        XCTAssertFalse(configured)

        do {
            _ = try await adapter.step(request())
            XCTFail("a missing binary must not appear to answer")
        } catch let failure as ClaudeCLIAdapter.Failure {
            guard case .binaryMissing = failure else { return XCTFail("got \(failure)") }
            XCTAssertTrue(failure.localizedDescription.contains("install"))
        } catch {
            XCTFail("expected a ClaudeCLIAdapter.Failure, got \(error)")
        }
    }

    /// A schema the CLI cannot parse fails every single turn, and it fails at the far end where
    /// the message is about flags rather than about JSON. Cheap to check here.
    func testTheEnvelopeSchemaIsValidJSON() throws {
        let data = Data(ClaudeCLIAdapter.envelopeSchema.utf8)
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["say"])
        XCTAssertNotNil(properties["actions"])
        XCTAssertEqual(schema["required"] as? [String], ["say", "actions"])
    }

    // MARK: - The cases that need the real thing

    /// Skips rather than fails where the CLI is not installed, which is most machines that will
    /// ever run this suite. All it proves is that the binary we would spawn is runnable — never
    /// that it is signed in, because that would cost a real model call.
    func testTheInstalledBinaryRunsWhenThereIsOne() async throws {
        guard let path = ClaudeCLIAdapter.locateBinary() else {
            throw XCTSkip("no claude command on this machine")
        }
        let probe = await ClaudeCLIAdapter.execute(binary: path, arguments: ["--version"],
                                                   stdin: nil, cwd: nil, timeout: 30)
        XCTAssertEqual(probe.exitCode, 0, "claude --version failed: \(probe.stderr)")
        XCTAssertTrue(probe.stdout.contains("Claude Code"), "unexpected version line: \(probe.stdout)")
    }

    /// The only test here that spends a real model call, so it is off unless asked for:
    ///
    ///     BOTHARNESS_LIVE_CLAUDE=1 ./scripts/test.sh
    ///
    /// It is worth having despite that, because every other test in this file agrees with a
    /// fixture rather than with the CLI. Fixtures go stale silently; this is the one that
    /// notices when a new version of Claude Code changes the contract underneath us — including
    /// the part that matters most, which is that the tools really are gone.
    func testALiveTurnComesBackAsAnEnvelope() async throws {
        guard ProcessInfo.processInfo.environment["BOTHARNESS_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("set BOTHARNESS_LIVE_CLAUDE=1 to spend a real model call")
        }
        guard let path = ClaudeCLIAdapter.locateBinary() else {
            throw XCTSkip("no claude command on this machine")
        }

        let live = request(tools: [readTool],
                           turns: [.init(role: .user, text: "Read /etc/hosts for me.")])
        let run = await ClaudeCLIAdapter.execute(
            binary: path,
            arguments: ClaudeCLIAdapter.commandArguments(for: live, model: nil),
            stdin: ClaudeCLIAdapter.prompt(for: live),
            cwd: nil,
            timeout: 180)

        // The CLI announces its own tool list before it does anything. This is the assertion
        // that would catch `--tools ""` quietly ceasing to mean what it means today.
        XCTAssertTrue(run.stdout.contains(#""tools":["StructuredOutput"]"#),
                      "the CLI came up with tools of its own: \(run.stdout.prefix(1200))")
        XCTAssertTrue(run.stdout.contains(#""mcp_servers":[]"#))

        let response = try ClaudeCLIAdapter.parse(run.stdout)
        XCTAssertEqual(response.actions.first?.name, "files.read",
                       "expected the model to ask the harness to read the file")
        XCTAssertNotNil(response.actions.first?.intent, "the trace and the approval card need this")
        XCTAssertGreaterThan(response.usage.promptTokens, 0)
    }
}

// MARK: - Fixtures

/// Captured from `claude 2.1.238` and trimmed to the fields the adapter reads. Kept verbatim in
/// shape — key names, nesting, and the `"subtype":"success"` on a failed turn — because it is
/// exactly those details that the parser gets wrong when someone rewrites it from memory.
private enum Fixtures {

    static let oneToolCall = """
    {"type":"system","subtype":"init","session_id":"8ae9","tools":["StructuredOutput"],"mcp_servers":[],"permissionMode":"default","plugins":[]}
    {"type":"assistant","message":{"model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"Let me take a look at the repository contents."}]},"session_id":"8ae9"}
    {"is_error":false,"num_turns":2,"session_id":"8ae9","total_cost_usd":0.008256,"usage":{"input_tokens":880,"cache_read_input_tokens":3289,"cache_creation_input_tokens":5936,"output_tokens":311},"subtype":"success","type":"result","result":"{\\"say\\":\\"…\\"}","structured_output":{"say":"Let me take a look at the repository contents.","actions":[{"tool":"shell.exec","intent":"List the top-level files in the repo","arguments":{"command":"ls -la"}},{"tool":"files.read","intent":"Read the README","arguments":{"path":"README.md"}}]}}
    """

    static let plainAnswer = """
    {"type":"system","subtype":"init","session_id":"d450","tools":["StructuredOutput"]}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi there, friend!"}]},"session_id":"d450"}
    {"is_error":false,"session_id":"d450","total_cost_usd":0.0377,"usage":{"input_tokens":2,"output_tokens":10},"subtype":"success","type":"result","result":"Hi there, friend!","structured_output":{"say":"Hi there, friend!","actions":[]}}
    """

    static let thinkingThenEnvelope = """
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"EpYHCqgBCBEYAipA3f0l8rV"}]},"session_id":"8ae9"}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I don't have a files.read tool available in this session, so I can't open it."}]},"session_id":"8ae9"}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01J","name":"StructuredOutput","input":{"say":"I cannot reach that file from here.","actions":[]}}]},"session_id":"8ae9"}
    {"is_error":false,"session_id":"8ae9","total_cost_usd":0.1,"usage":{"input_tokens":2,"output_tokens":519},"subtype":"success","type":"result","result":"{}","structured_output":{"say":"I cannot reach that file from here.","actions":[]}}
    """

    static let envelopeAsStringOnly = """
    {"is_error":false,"session_id":"aaaa","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":20},"subtype":"success","type":"result","result":"{\\"say\\":\\"Checking that now.\\",\\"actions\\":[{\\"tool\\":\\"files.read\\",\\"intent\\":\\"open it\\",\\"arguments\\":{\\"path\\":\\"/etc/hosts\\"}}]}"}
    """

    static let noEnvelope = """
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"There are four files in that folder."}]},"session_id":"bbbb"}
    {"is_error":false,"session_id":"bbbb","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":20},"subtype":"success","type":"result","result":"There are four files in that folder."}
    """

    static let withNoise = """
    Update available: 2.1.240
    {"type":"system","subtype":"init","session_id":"d450","tools":["StructuredOutput"]}
    {"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"error_status":401,"error":"authentication_failed","session_id":"d450"}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"},"session_id":"d450"}
    {"type":"system","subtype":"post_turn_summary","status_category":"review_ready","session_id":"d450"}
    {"is_error":false,"session_id":"d450","total_cost_usd":0.03,"usage":{"input_tokens":2,"output_tokens":10},"subtype":"success","type":"result","result":"Hi there, friend!","structured_output":{"say":"Hi there, friend!","actions":[]}}
    """

    static let actionMissingToolName = """
    {"is_error":false,"session_id":"cccc","total_cost_usd":0.01,"usage":{"input_tokens":1,"output_tokens":1},"subtype":"success","type":"result","result":"{}","structured_output":{"say":"ok","actions":[{"intent":"no tool named","arguments":{}},{"tool":"files.read","intent":"open it","arguments":{"path":"a"}}]}}
    """

    /// A real signed-out run. Note `terminal_reason:"api_error"` alongside `subtype:"success"`.
    static let notLoggedIn = """
    {"type":"system","subtype":"init","session_id":"c5a1","tools":[],"apiKeySource":"none"}
    {"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"session_id":"c5a1","error":"authentication_failed","is_api_error_message":true}
    {"is_error":true,"session_id":"c5a1","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"permission_denials":[],"terminal_reason":"api_error","subtype":"success","type":"result","result":"Not logged in · Please run /login"}
    """

    static let rateLimited = """
    {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","overageStatus":"rejected"},"session_id":"eeee"}
    {"is_error":true,"session_id":"eeee","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"terminal_reason":"api_error","subtype":"success","type":"result","result":"Claude usage limit reached (rate_limit). Your limit resets at 3pm."}
    """
}
