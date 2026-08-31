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
        // Everything this suite can leave behind sits beside the state file and starts with its
        // name: the file itself, a temporary from an interrupted save, a copy set aside by a
        // failed load, a copy kept by a partial one.
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in siblings where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func fresh() -> Store { Store(loadingFrom: url) }

    // MARK: Damaging a real state file

    /// A state file this version of the app actually wrote, handed back as a dictionary to
    /// damage.
    ///
    /// The recovery tests below start from a real save rather than from a hand-written document,
    /// because a hand-written one stops resembling what the app saves the first time a field is
    /// added — and a test that loads a shape nothing writes proves nothing about the file on the
    /// user's disk.
    private func savedDocument(_ configure: (Store) -> Void = { _ in }) throws -> [String: Any] {
        let store = fresh()
        configure(store)
        store.flush()
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Write a damaged document where the app expects to find its state, and open it.
    private func reopen(_ document: [String: Any]) throws -> Store {
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return Store(loadingFrom: url)
    }

    private func bots(in document: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(document["bots"] as? [[String: Any]])
    }

    /// The mode of the real file, from `stat(2)`. Deliberately not read back through the same
    /// `FileManager` call that set it: the defect this guards against is a call that reports
    /// success and leaves the file at another mode.
    private func mode(of url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0, "no file at \(url.path)")
        return info.st_mode & 0o777
    }

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

    // MARK: Round trip

    /// The other half of a recovering decoder, and the half that goes wrong quietly: a decoder
    /// that reads a key by the wrong name recovers a default for it on every single load, and
    /// every field it does that to is a setting the user changed and the app forgot.
    ///
    /// Every date here is a whole number of seconds because the document is written with
    /// `.iso8601`, which does not carry fractions — a `Date()` would fail this on precision and
    /// say nothing about the decoder.
    func testAFullyPopulatedBotSurvivesASaveAndReloadUnchanged() throws {
        let store = fresh()
        var bot = store.createBot(name: "Full")
        bot.label = "Research"
        bot.persona = "Briefed on the partnership work."
        bot.avatar = Avatar(hue: 0.42, glyph: "◆")
        bot.personaIsAuto = false
        bot.nameIsAuto = false
        bot.describedAtTurn = 7
        bot.brain = .claudeCLI(model: "opus")
        bot.environment = .container
        bot.defaultAutonomy = .delegatedOperator
        bot.workspace = URL(fileURLWithPath: "/tmp/full")
        bot.enabledPlugins = ["mail", "calendar"]
        bot.rules = [PermissionRule(id: UUID(), whenBotWantsTo: "spend money",
                                    behaviour: .neverAllow, createdFromPrompt: true,
                                    createdAt: Date(timeIntervalSince1970: 1_000_000))]
        bot.notifies = false
        bot.memory = [MemoryNote(text: "The invoices live in Drive.", reason: "asked twice",
                                 learnedAt: Date(timeIntervalSince1970: 2_000_000),
                                 confirmedByUser: true, provenance: .user, scope: "/tmp",
                                 sourceRun: "run-1",
                                 expiresAt: Date(timeIntervalSince1970: 3_000_000))]
        bot.createdAt = Date(timeIntervalSince1970: 4_000_000)
        bot.templateSource = "starter"
        store.update(bot)
        store.flush()

        let reopened = Store(loadingFrom: url)

        XCTAssertEqual(reopened.recoveryLosses, [],
                       "a file this app wrote must reload with nothing recovered")
        XCTAssertNil(reopened.recoveredCopy, "and must not leave a copy behind on every launch")
        XCTAssertEqual(reopened.bot(bot.id), bot, "every field the user set comes back")
    }

    func testEveryKindOfMessageSurvivesASaveAndReloadUnchanged() throws {
        let store = fresh()
        let bot = store.createBot(name: "Talker")
        let id = store.conversations.first { $0.participants == [bot.id] }!.id
        let stamp = Date(timeIntervalSince1970: 5_000_000)
        let bodies: [Message.Body] = [
            .text("prose"),
            .toolUse(ToolActivity(tool: "shell.exec", summary: "ran it", detail: "ls",
                                  output: "a b", status: .done, startedAt: stamp,
                                  finishedAt: stamp, traceID: "trace-1")),
            .computer(ComputerActivity(task: "clicked Send", status: .done,
                                       environment: .container, screenshots: ["1.png"],
                                       awaitingHuman: false, startedAt: stamp, finishedAt: stamp)),
            .approval(ApprovalRequest(summary: "send mail", detail: "to: x", reason: "floor",
                                      answer: .allowedOnce, answeredAt: stamp)),
            .notice("Updated routine"),
            .failure("it broke"),
            .screenshot(Screenshot(path: "/tmp/1.png", caption: "looked", takenAt: stamp)),
        ]
        for body in bodies {
            store.append(Message(author: bot.id, body: body, timestamp: stamp), to: id)
        }
        store.flush()

        let reopened = Store(loadingFrom: url)

        XCTAssertEqual(reopened.recoveryLosses, [])
        XCTAssertEqual(reopened.conversation(id)?.messages.map(\.body), bodies)
        XCTAssertEqual(reopened.conversation(id)?.messages.map(\.author), bodies.map { _ in bot.id },
                       "an author read back as nil would put a bot's words in the user's voice")
    }

    func testAChannelPolicyKeepsTheValuesItWasGiven() throws {
        // Not reachable through `Store` — nothing sets a policy yet — so it is round-tripped
        // directly. Without this, a decoder that read `maxConsecutiveBotTurns` by the wrong name
        // would put every channel back to twelve turns and nothing would notice.
        let policy = ChannelPolicy(maxConsecutiveBotTurns: 3, botsMaySpeakUnprompted: false,
                                   permissionsFollow: .requestingBot)
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(ChannelPolicy.self, from: data), policy)
    }

    // MARK: Reading a file this version does not quite recognise

    /// The experiment that found the defect: take a bot the app just wrote, remove one key, and
    /// see what it costs. It used to cost every bot and every conversation in the file.
    func testRemovingAnySingleKeyFromABotStillLoadsEveryBot() throws {
        var document = try savedDocument { $0.createBot(name: "Kept") }
        let written = try bots(in: document)
        XCTAssertGreaterThanOrEqual(written.count, 2, "need a second bot to prove the others live")
        let keys = written[0].keys.sorted()
        XCTAssertGreaterThanOrEqual(keys.count, 10, "a bot with almost no keys tests almost nothing")

        for key in keys {
            var damaged = written
            damaged[0].removeValue(forKey: key)
            document["bots"] = damaged

            let store = try reopen(document)
            XCTAssertNil(store.loadFailure,
                         "a bot with no '\(key)' took the whole document down with it")
            XCTAssertEqual(store.bots.count, written.count,
                           "a bot with no '\(key)' cost the user a bot")
        }
    }

    func testAMangledFieldCostsThatFieldAndNothingElse() throws {
        var document = try savedDocument { $0.createBot(name: "Damaged") }
        var written = try bots(in: document)
        let index = try XCTUnwrap(written.firstIndex { $0["name"] as? String == "Damaged" })
        written[index]["persona"] = 42                 // a number where prose belongs
        written[index]["createdAt"] = "one o'clock"    // not a date
        written[index]["avatar"] = "blue"              // not an avatar
        document["bots"] = written

        let store = try reopen(document)

        XCTAssertEqual(store.bots.count, written.count)
        let damaged = try XCTUnwrap(store.bots.first { $0.name == "Damaged" })
        XCTAssertEqual(damaged.persona, "", "an unreadable persona falls back to none")
        XCTAssertTrue(damaged.notifies, "the fields either side of a bad one are untouched")
        XCTAssertNotNil(store.recoveryLosses.first { $0.contains("persona") },
                        "a replaced value must be on the record, not silently swallowed")
        XCTAssertNotNil(store.recoveredCopy,
                        "a file that only loaded because we filled in gaps must be kept")
    }

    func testAnUnreadableBotIsSkippedAndTheOthersSurvive() throws {
        var document = try savedDocument { store in
            store.createBot(name: "First")
            store.createBot(name: "Second")
        }
        let written = try bots(in: document)
        var entries: [Any] = written
        entries.insert("this is not a bot", at: 1)
        entries.append(NSNull())
        document["bots"] = entries

        let store = try reopen(document)

        XCTAssertNil(store.loadFailure, "one bad entry is not a reason to close the roster")
        XCTAssertEqual(store.bots.count, written.count, "every readable bot survives")
        XCTAssertTrue(store.bots.contains { $0.name == "First" })
        XCTAssertTrue(store.bots.contains { $0.name == "Second" })
        XCTAssertNotNil(store.recoveredCopy)
    }

    /// Fail closed. Recovering a rules array we could not read would open the app with a bot
    /// holding fewer restrictions than the user wrote for it.
    func testABotWhosePermissionRulesCannotBeReadIsDroppedRatherThanLoadedWithoutThem() throws {
        var document = try savedDocument { store in
            let bot = store.createBot(name: "Restricted", persona: "never spends anything")
            store.addRule(PermissionRule(whenBotWantsTo: "spend money", behaviour: .neverAllow),
                          to: bot.id)
        }
        var written = try bots(in: document)
        let index = try XCTUnwrap(written.firstIndex { $0["name"] as? String == "Restricted" })
        // A behaviour a later version added and this one has never heard of.
        written[index]["rules"] = [["id": UUID().uuidString,
                                    "whenBotWantsTo": "spend money",
                                    "behaviour": "allowInsideWorkspace",
                                    "createdFromPrompt": false,
                                    "createdAt": "2026-08-31T00:00:00Z"]]
        document["bots"] = written

        let store = try reopen(document)

        XCTAssertFalse(store.bots.contains { $0.name == "Restricted" },
                       "a bot must not open holding rules we could not read in full")
        XCTAssertEqual(store.bots.count, written.count - 1, "only that bot is dropped")
        XCTAssertNil(store.loadFailure, "the other bots still open")

        // Dropped from memory is not dropped from the disk: the next save writes memory over the
        // file, so the copy is the only thing standing between this and losing the bot.
        let kept = try XCTUnwrap(store.recoveredCopy)
        let text = try String(contentsOf: kept, encoding: .utf8)
        XCTAssertTrue(text.contains("never spends anything"), "the dropped bot is still on disk")
        XCTAssertEqual(mode(of: kept), 0o600, "the copy holds what the original held")
    }

    func testAMessageThatCannotBeReadKeepsItsPlaceInTheConversation() throws {
        var conversationID: UUID!
        var document = try savedDocument { store in
            let bot = store.createBot(name: "Talker")
            conversationID = store.conversations.first { $0.participants == [bot.id] }!.id
            store.append(Message(author: bot.id, body: .text("first")), to: conversationID)
            store.append(Message(author: bot.id, body: .text("second")), to: conversationID)
        }
        var conversations = try XCTUnwrap(document["conversations"] as? [[String: Any]])
        let index = try XCTUnwrap(conversations.firstIndex {
            ($0["id"] as? String) == conversationID.uuidString
        })
        var messages = try XCTUnwrap(conversations[index]["messages"] as? [[String: Any]])
        messages[0]["body"] = "a shape this version has never seen"
        conversations[index]["messages"] = messages
        document["conversations"] = conversations

        let store = try reopen(document)

        let kept = try XCTUnwrap(store.conversation(conversationID)).messages
        XCTAssertEqual(kept.count, 2, "an unreadable message must not take the conversation")
        guard case .failure = kept[0].body else {
            return XCTFail("the gap must be visible, not a message that quietly disappeared")
        }
        guard case .text(let second) = kept[1].body else { return XCTFail("expected the second") }
        XCTAssertEqual(second, "second", "the messages either side are untouched")
        XCTAssertNotNil(store.recoveredCopy)
    }

    func testOpeningTheSameDamagedFileTwiceKeepsOneCopyOfIt() throws {
        var document = try savedDocument { $0.createBot(name: "Damaged") }
        var written = try bots(in: document)
        written[0]["persona"] = 42
        document["bots"] = written

        let first = try reopen(document)
        let copy = try XCTUnwrap(first.recoveredCopy)

        // The app heals this at its next save, but a user who opens it and quits without
        // touching anything never reaches that save — and every launch would leave another
        // copy of the whole document behind.
        let second = Store(loadingFrom: url)
        XCTAssertEqual(second.recoveredCopy, copy, "the same bytes must not be copied twice")

        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".recovered-"
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) }
        XCTAssertEqual(copies.count, 1)
    }

    /// The one recovery this file deliberately refuses to make.
    func testUnreadableGlobalRulesFailTheLoadRatherThanLooseningIt() throws {
        var document = try savedDocument()
        var rules = try XCTUnwrap(document["globalRules"] as? [[String: Any]])
        let index = try XCTUnwrap(rules.firstIndex { $0["behaviour"] as? String == "neverAllow" })
        rules[index]["behaviour"] = "allowInsideWorkspace"
        document["globalRules"] = rules

        let store = try reopen(document)

        let failure = try XCTUnwrap(store.loadFailure,
                                    "opening with fewer rules than the user wrote is the one "
                                  + "outcome worse than not opening")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.movedTo.path),
                      "nothing is deleted; the file is set aside and the user is told where")
    }

    // MARK: File permissions

    func testTheStateFileIsOwnerOnlyWhenItIsFirstWritten() {
        let store = fresh()
        store.flush()
        XCTAssertEqual(mode(of: url), 0o600,
                       "the document holds every persona, path and message the user has")
    }

    /// The defect: `saveNow` chmod-ed the temporary and then called `replaceItemAt`, which keeps
    /// the *target's* mode and discards the replacement's — so the chmod was undone on every save
    /// after the first, and a file that had ever been 0644 stayed 0644 forever.
    func testTheStateFileStaysOwnerOnlyAcrossSavesAndReloads() throws {
        let store = fresh()
        store.createBot(name: "First")
        store.flush()

        // A file that has drifted wide: restored from a backup, copied by a sync tool, or
        // written by a version of this app that saved at the umask.
        XCTAssertEqual(chmod(url.path, 0o644), 0)

        store.createBot(name: "Second")
        store.flush()
        XCTAssertEqual(mode(of: url), 0o600, "a save must not inherit the old file's mode")

        let reopened = Store(loadingFrom: url)
        XCTAssertEqual(reopened.bots.count, 3, "the save that narrowed the file also kept it")
        reopened.createBot(name: "Third")
        reopened.flush()
        XCTAssertEqual(mode(of: url), 0o600)
        XCTAssertEqual(Store(loadingFrom: url).bots.count, 4, "and the document still reads back")
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
