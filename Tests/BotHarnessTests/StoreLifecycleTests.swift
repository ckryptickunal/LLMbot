import XCTest
@testable import BotHarnessCore

/// The paths that lose or corrupt a user's work.
///
/// Each of these was a real defect found in the UX audit, and each is here because the failure
/// is silent: nothing crashes, nothing logs, the interface simply shows something untrue.
@MainActor
final class StoreLifecycleTests: XCTestCase {

    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func fresh() -> Store { Store(loadingFrom: url) }

    // MARK: Selection

    func testDeletingTheSelectedBotMovesSelectionSomewhereReal() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        store.selection = store.conversations.first { $0.participants == [a.id] }?.id

        store.deleteBot(a.id)

        XCTAssertNotNil(store.selection, "deleting a bot must not strand the selection at nil")
        XCTAssertEqual(store.conversation(store.selection)?.participants, [b.id])
    }

    func testDeletingEveryBotLeavesNoSelection() {
        // A fresh store is seeded with one bot, so "empty" means deleting that one too.
        let store = fresh()
        store.createBot(name: "Only")
        for bot in store.bots { store.deleteBot(bot.id) }

        XCTAssertNil(store.selection)
        XCTAssertTrue(store.conversations.isEmpty)
    }

    func testDeletingABotReportsTheConversationsThatWentWithIt() {
        let store = fresh()
        let bot = store.createBot(name: "Doomed")
        let conversation = store.conversations.first { $0.participants == [bot.id] }!

        let orphaned = store.deleteBot(bot.id)

        // The caller needs these to cancel running work; without them a loop keeps writing
        // into a conversation that no longer exists.
        XCTAssertEqual(orphaned, [conversation.id])
    }

    func testDeletingAChannelMemberKeepsTheChannel() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        let channel = store.createChannel(title: "Room", participants: [a.id, b.id])

        store.deleteBot(a.id)

        let survivor = store.conversation(channel.id)
        XCTAssertNotNil(survivor, "a channel survives losing one member")
        XCTAssertEqual(survivor?.participants, [b.id])
    }

    // MARK: Interrupted work

    func testAReloadSettlesWorkWhoseProcessIsGone() {
        let store = fresh()
        let bot = store.createBot(name: "Worker")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id

        store.append(Message(author: bot.id, body: .toolUse(
            ToolActivity(tool: "shell.exec", summary: "run something", status: .running))), to: id)
        store.append(Message(author: bot.id, body: .computer(
            ComputerActivity(task: "click something", status: .running, awaitingHuman: true))), to: id)
        store.append(Message(author: bot.id, body: .approval(
            ApprovalRequest(summary: "delete something", detail: "rm -rf x", reason: "floor"))), to: id)
        store.flush()

        // A relaunch: nothing resumes, so nothing may still claim to be in progress.
        let reopened = Store(loadingFrom: url)
        let messages = reopened.conversation(id)!.messages

        guard case .toolUse(let tool) = messages[0].body else { return XCTFail("expected a tool") }
        XCTAssertEqual(tool.status, .interrupted)
        XCTAssertNotNil(tool.finishedAt)

        guard case .computer(let computer) = messages[1].body else { return XCTFail("expected a computer") }
        XCTAssertEqual(computer.status, .interrupted)
        XCTAssertFalse(computer.awaitingHuman, "a card cannot wait for a person after the run is gone")

        guard case .approval(let approval) = messages[2].body else { return XCTFail("expected an approval") }
        XCTAssertEqual(approval.answer, .expired,
                       "an unanswerable prompt must resolve, not keep offering live buttons")
    }

    func testAnAnsweredApprovalIsNotRewrittenOnReload() {
        let store = fresh()
        let bot = store.createBot(name: "Worker")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        var request = ApprovalRequest(summary: "send mail", detail: "…", reason: "floor")
        request.answer = .allowedOnce
        store.append(Message(author: bot.id, body: .approval(request)), to: id)
        store.flush()

        let reopened = Store(loadingFrom: url)
        guard case .approval(let after) = reopened.conversation(id)!.messages[0].body
        else { return XCTFail("expected an approval") }
        XCTAssertEqual(after.answer, .allowedOnce, "history is not rewritten")
    }

    func testFinishedWorkSurvivesAReloadUnchanged() {
        let store = fresh()
        let bot = store.createBot(name: "Worker")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        store.append(Message(author: bot.id, body: .toolUse(
            ToolActivity(tool: "files.read", summary: "read", status: .done))), to: id)
        store.flush()

        let reopened = Store(loadingFrom: url)
        guard case .toolUse(let tool) = reopened.conversation(id)!.messages[0].body
        else { return XCTFail("expected a tool") }
        XCTAssertEqual(tool.status, .done)
    }

    // MARK: Persistence

    func testFlushWritesWithoutWaitingForTheDebounce() {
        let store = fresh()
        let bot = store.createBot(name: "Quick")
        store.flush()

        let reopened = Store(loadingFrom: url)
        XCTAssertTrue(reopened.bots.contains { $0.id == bot.id },
                      "quitting inside the debounce window must not lose the change")
    }

    func testAnUnreadableStateFileIsKeptAndReported() throws {
        try Data("this is not the document".utf8).write(to: url)
        let store = fresh()

        let failure = try XCTUnwrap(store.loadFailure,
                                    "silently re-seeding presents as total data loss")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.movedTo.path),
                      "the original must still be on disk")
        XCTAssertFalse(store.bots.isEmpty, "the app still opens")
        try? FileManager.default.removeItem(at: failure.movedTo)
    }

    // MARK: Rules

    func testRulesCanBeChangedAndRemoved() {
        // The seeded rules are real rules; this one is identified by id, not by position.
        let store = fresh()
        let seeded = store.globalRules.count
        let rule = PermissionRule(whenBotWantsTo: "send email", behaviour: .allowAutomatically)
        store.addGlobalRule(rule)
        XCTAssertEqual(store.globalRules.count, seeded + 1)

        var edited = rule
        edited.behaviour = .neverAllow
        store.updateGlobalRule(edited)
        XCTAssertEqual(store.globalRules.first { $0.id == rule.id }?.behaviour, .neverAllow)

        // The counterpart to "Always allow this". Without it, one mis-click grants a standing
        // permission for the life of the install.
        store.deleteGlobalRule(rule.id)
        XCTAssertNil(store.globalRules.first { $0.id == rule.id })
        XCTAssertEqual(store.globalRules.count, seeded, "only the named rule is removed")
    }

    func testASeededInstallStartsWithRulesAndOneBot() {
        let store = fresh()
        XCTAssertEqual(store.bots.count, 1)
        XCTAssertFalse(store.globalRules.isEmpty)
        XCTAssertNotNil(store.selection)
        // The maintainer's own name and habits do not belong in every install of a public app.
        XCTAssertFalse(store.bots[0].persona.contains("Kunal"))
    }

    // MARK: Unread

    func testUnreadClearsWhenTheConversationIsOpened() {
        let store = fresh()
        let bot = store.createBot(name: "Talker")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        store.append(Message(author: bot.id, body: .text("something happened")), to: id)

        XCTAssertTrue(store.conversation(id)!.isUnread)
        store.markRead(id)
        XCTAssertFalse(store.conversation(id)!.isUnread)
    }

    func testAConversationWithNoMessagesIsNotUnread() {
        let store = fresh()
        let bot = store.createBot(name: "Silent")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        XCTAssertFalse(store.conversation(id)!.isUnread)
    }

    // MARK: Messages

    func testClearingAConversationKeepsTheBot() {
        let store = fresh()
        let bot = store.createBot(name: "Keeper")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        store.append(Message(body: .text("hi")), to: id)

        store.clearMessages(in: id)

        XCTAssertTrue(store.conversation(id)!.messages.isEmpty)
        XCTAssertNotNil(store.bot(bot.id))
    }

    func testDeletingOneMessageLeavesTheRest() {
        let store = fresh()
        let bot = store.createBot(name: "Keeper")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        let first = Message(body: .text("one"))
        store.append(first, to: id)
        store.append(Message(body: .text("two")), to: id)

        store.deleteMessage(first.id, in: id)

        XCTAssertEqual(store.conversation(id)!.messages.count, 1)
    }

    // MARK: Workspace

    func testABotsFolderHasOneDefinitionEverywhere() {
        var bot = Bot(name: "Scoped")
        XCTAssertEqual(bot.effectiveWorkspace, Bot.defaultWorkspace)

        let chosen = URL(fileURLWithPath: "/tmp/scoped")
        bot.workspace = chosen
        XCTAssertEqual(bot.effectiveWorkspace, chosen)
    }
}
