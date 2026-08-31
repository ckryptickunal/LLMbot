import XCTest
@testable import BotHarnessCore

/// The store-level contracts the roster's actions rest on: making a channel, renaming either
/// kind of row, changing who is in a room, and deleting the right thing.
///
/// The views themselves cannot be tested from here — the test target depends on
/// `BotHarnessCore` and the interface lives in the `BotHarness` executable — so the rules live
/// in `Store` and what is pinned here is every fact the interface asserts on the user's behalf.
/// Each of these is a sentence the app says out loud, and each would go quietly false if the
/// model underneath changed:
///
/// - the roster claims a channel's row shows the room's name, not a member's;
/// - the new-channel sheet promises that "the first bot you pick is the one that answers",
///   which is only true while `participants` is an ordered list that survives a relaunch;
/// - the rename alert promises the bot keeps its description, its history and its mark, that a
///   name the user chose will not be written over, and that renaming a room changes the name
///   and nothing else;
/// - the members menu promises that joining a room later does not take it over, and that the
///   room can never be emptied by accident;
/// - the delete item promises to delete the thing it names — a room that has lost members is
///   still a room, and deleting it must not take the last bot standing with it.
@MainActor
final class RosterActionsTests: XCTestCase {

    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func fresh() -> Store { Store(loadingFrom: url) }

    /// What the sidebar row and the conversation header both display, copied out of the view
    /// layer because the view layer is not linkable from a test. If this expression and the one
    /// in `Sidebar.title(for:)` ever disagree, the thing to fix is the view.
    private func rosterTitle(_ store: Store, _ conversation: Conversation) -> String {
        conversation.title ?? store.bot(conversation.participants.first)?.name ?? "Untitled"
    }

    /// A synchronous save, not `flush()`: `saveNow` encodes and writes on a background
    /// queue, so `flush` returns before the bytes are on disk and reopening the file races
    /// it. `saveAndWait` is the one that waits, and a reload test that does not wait is a
    /// test that passes or fails on timing rather than on behaviour.
    private func persist(_ store: Store) { store.saveAndWait() }

    // MARK: Making a channel

    func testANewChannelIsNamedSelectedAndOpen() {
        let store = fresh()
        let research = store.createBot(name: "Research")
        let outreach = store.createBot(name: "Outreach")

        let channel = store.createChannel(title: "Jewel partnerships",
                                          participants: [research.id, outreach.id],
                                          lead: research.id)

        XCTAssertTrue(channel.isChannel)
        XCTAssertEqual(store.selection, channel.id,
                       "making a channel must open it — the sheet dismisses onto whatever is selected")
        XCTAssertEqual(rosterTitle(store, channel), "Jewel partnerships",
                       "a channel row shows the room's name, never the first member's")
        XCTAssertEqual(channel.leadBot, research.id)
    }

    func testTwoParticipantsIsWhatMakesAChannelAChannel() {
        let store = fresh()
        let alone = store.createBot(name: "Alone")
        let other = store.createBot(name: "Other")

        // Why the sheet refuses to create until two bots are picked: one participant is a chat
        // whatever it is called, so a one-bot "channel" would render as a chat wearing a title.
        let single = store.createChannel(title: "Not really a room", participants: [alone.id])
        XCTAssertFalse(single.isChannel)

        let pair = store.createChannel(title: "A real room", participants: [alone.id, other.id])
        XCTAssertTrue(pair.isChannel)
    }

    func testTheOrderOfAChannelsBotsSurvivesARelaunch() {
        let store = fresh()
        let first = store.createBot(name: "Speaks")
        let second = store.createBot(name: "Listens")
        let third = store.createBot(name: "Also listens")
        let channel = store.createChannel(title: "Ordered",
                                          participants: [first.id, second.id, third.id],
                                          lead: first.id)
        persist(store)

        // `BotRunner.send` starts a loop for `participants.first`, and the sheet tells the user
        // in as many words that the bot they picked first is the one that answers. That promise
        // is only kept while this is an ordered list that round-trips through the state file —
        // storing participants as a set, or sorting them for display, would break it silently
        // and the only symptom would be the wrong bot replying weeks later.
        let reopened = Store(loadingFrom: url)
        let after = reopened.conversation(channel.id)
        XCTAssertEqual(after?.participants, [first.id, second.id, third.id])
        XCTAssertEqual(after?.leadBot, first.id)
    }

    func testAChannelOutlivesTheBotThatAnsweredInIt() {
        let store = fresh()
        let speaker = store.createBot(name: "Speaks")
        let listener = store.createBot(name: "Listens")
        let channel = store.createChannel(title: "Room",
                                          participants: [speaker.id, listener.id],
                                          lead: speaker.id)

        // Deleting a bot from the roster must not take a room down with it, and the bot that
        // answers next is the one the header will name.
        store.deleteBot(speaker.id)

        let survivor = store.conversation(channel.id)
        XCTAssertNotNil(survivor)
        XCTAssertEqual(survivor?.participants, [listener.id])
        XCTAssertEqual(rosterTitle(store, survivor!), "Room")
    }

    // MARK: Renaming

    func testRenamingABotChangesTheNameAndNothingElse() {
        let store = fresh()
        let created = store.createBot(name: "New Bot", persona: "Watches the Jewel inbox.")
        let conversationID = store.conversations.first { $0.participants == [created.id] }!.id
        store.append(Message(body: .text("first thing I asked")), to: conversationID)

        // Through the store's own rename, which is the path the roster now takes. A test that
        // rebuilt the bot by hand would pass whatever the rename did.
        XCTAssertTrue(store.renameBot(created.id, to: "Inbox"))

        let after = store.bot(created.id)!
        XCTAssertEqual(after.name, "Inbox")
        // Everything the rename alert promises is kept.
        XCTAssertEqual(after.id, created.id)
        XCTAssertEqual(after.persona, "Watches the Jewel inbox.")
        XCTAssertEqual(after.avatar.hue, created.avatar.hue,
                       "the mark is derived from the id, so a rename must not change it")
        XCTAssertEqual(after.workspace, created.workspace)
        XCTAssertEqual(store.conversation(conversationID)?.messages.count, 1,
                       "renaming is not a way to lose a conversation")
    }

    func testANameTheUserChoseIsMarkedAsTheirsAndSurvivesARelaunch() {
        let store = fresh()
        let created = store.createBot(name: "New Bot")
        XCTAssertTrue(created.nameIsAuto, "a bot names itself until somebody else does")

        store.renameBot(created.id, to: "Joby")
        persist(store)

        // `BotRunner.maybeSelfDescribe` renames a bot only while `nameIsAuto` is set. If this
        // flag were not cleared — or were not persisted — the bot would quietly rename itself
        // back after its next successful run, which is the one thing a rename must never do.
        let reopened = Store(loadingFrom: url)
        let after = reopened.bot(created.id)
        XCTAssertEqual(after?.name, "Joby")
        XCTAssertEqual(after?.nameIsAuto, false)
    }

    func testTheRosterShowsARenamedBotImmediately() {
        let store = fresh()
        let created = store.createBot(name: "New Bot")
        let conversation = store.conversations.first { $0.participants == [created.id] }!

        store.renameBot(created.id, to: "Joby")

        // A chat's row has no title of its own and reads the bot's name through the store, so
        // giving a chat a `title` on creation would leave the roster showing the old name for
        // ever with no way to change it.
        XCTAssertNil(conversation.title)
        XCTAssertEqual(rosterTitle(store, store.conversation(conversation.id)!), "Joby")
    }

    func testRenamingTrimsWhatWasTypedAndRefusesABlankName() {
        let store = fresh()
        let bot = store.createBot(name: "New Bot")
        let other = store.createBot(name: "Other")
        let room = store.createChannel(title: "Room", participants: [bot.id, other.id])

        XCTAssertTrue(store.renameBot(bot.id, to: "  Joby  "))
        XCTAssertTrue(store.renameConversation(room.id, to: "  Jewel partnerships \n"))
        XCTAssertEqual(store.bot(bot.id)?.name, "Joby")
        XCTAssertEqual(store.conversation(room.id)?.title, "Jewel partnerships")

        // Both paths refuse identically, which is what lets the roster offer one alert for a
        // bot and a room: a name made of spaces would render as a nameless row nobody could
        // find, and the alert has no way to say so while it is closing.
        XCTAssertFalse(store.renameBot(bot.id, to: "   "))
        XCTAssertFalse(store.renameConversation(room.id, to: "\n \t "))
        XCTAssertEqual(store.bot(bot.id)?.name, "Joby")
        XCTAssertEqual(store.conversation(room.id)?.title, "Jewel partnerships")
    }

    // MARK: Renaming a room

    func testARoomCanBeRenamedAfterItWasMade() {
        let store = fresh()
        let research = store.createBot(name: "Research")
        let outreach = store.createBot(name: "Outreach")
        let room = store.createChannel(title: "Jewl partnerships",
                                       participants: [research.id, outreach.id],
                                       lead: research.id)
        store.append(Message(body: .text("who have we written to?")), to: room.id)

        XCTAssertTrue(store.renameConversation(room.id, to: "Jewel partnerships"))

        let after = store.conversation(room.id)!
        XCTAssertEqual(rosterTitle(store, after), "Jewel partnerships")
        // Everything the rename alert promises a room keeps.
        XCTAssertEqual(after.participants, [research.id, outreach.id])
        XCTAssertEqual(after.leadBot, research.id)
        XCTAssertEqual(after.messages.count, 1)
    }

    func testRenamingARoomDoesNotMoveItOrMarkItUnread() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        let room = store.createChannel(title: "Room", participants: [a.id, b.id])
        store.append(Message(body: .text("hello")), to: room.id)
        store.markRead(room.id)
        let before = store.conversation(room.id)!.lastActivity

        store.renameConversation(room.id, to: "Renamed")

        // `lastActivity` orders the roster and decides the unread dot. A rename that bumped it
        // would jump the row to the top and light it up, announcing as news the thing the user
        // just did themselves — and nothing was said in the conversation at all.
        XCTAssertEqual(store.conversation(room.id)?.lastActivity, before)
        XCTAssertFalse(store.conversation(room.id)!.isUnread)
    }

    func testAChatCannotBeGivenATitleThatShadowsItsBot() {
        let store = fresh()
        let bot = store.createBot(name: "Joby")
        let chat = store.conversations.first { $0.participants == [bot.id] }!

        XCTAssertFalse(store.renameConversation(chat.id, to: "Not the bot's name"))

        // A chat's row reads the bot's name through the store. A title written onto it would
        // win for ever — renaming the bot could never change it back, and the roster and the
        // conversation header would show two different names for the same thing.
        XCTAssertNil(store.conversation(chat.id)?.title)
        store.renameBot(bot.id, to: "Inbox")
        XCTAssertEqual(rosterTitle(store, store.conversation(chat.id)!), "Inbox")
    }

    func testARenamedRoomKeepsItsNameAcrossARelaunch() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        let room = store.createChannel(title: "Wrong name", participants: [a.id, b.id])
        store.renameConversation(room.id, to: "Right name")
        persist(store)

        XCTAssertEqual(Store(loadingFrom: url).conversation(room.id)?.title, "Right name")
    }

    // MARK: Who is in the room

    func testABotCanJoinARoomAfterItWasMade() {
        let store = fresh()
        let research = store.createBot(name: "Research")
        let outreach = store.createBot(name: "Outreach")
        let books = store.createBot(name: "Books")
        let room = store.createChannel(title: "Room",
                                       participants: [research.id, outreach.id],
                                       lead: research.id)

        XCTAssertTrue(store.addParticipant(books.id, to: room.id))
        persist(store)

        // Appended, so the bot that answers is still the bot the user picked first. Inserting a
        // newcomer at the front would silently hand the room to whoever joined last.
        let after = Store(loadingFrom: url).conversation(room.id)
        XCTAssertEqual(after?.participants, [research.id, outreach.id, books.id])
        XCTAssertEqual(after?.leadBot, research.id)
    }

    func testABotCannotJoinTwiceOrOutOfNowhere() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        let room = store.createChannel(title: "Room", participants: [a.id, b.id])

        XCTAssertFalse(store.addParticipant(a.id, to: room.id), "already in the room")
        XCTAssertFalse(store.addParticipant(UUID(), to: room.id), "not a bot that exists")
        XCTAssertEqual(store.conversation(room.id)?.participants, [a.id, b.id])
    }

    func testAChatDoesNotTakeASecondMember() {
        let store = fresh()
        let bot = store.createBot(name: "Joby")
        let other = store.createBot(name: "Other")
        let chat = store.conversations.first { $0.participants == [bot.id] }!

        XCTAssertFalse(store.addParticipant(other.id, to: chat.id))

        // `deleteBot` finds the threads that only existed because of a bot by matching
        // `participants == [id]`. A chat quietly promoted to a room would stop matching, and
        // would outlive its own bot as a room nobody can talk to.
        XCTAssertEqual(store.conversation(chat.id)?.participants, [bot.id])
    }

    func testRemovingTheBotThatAnswersHandsTheRoomToTheNextOne() {
        let store = fresh()
        let first = store.createBot(name: "Speaks")
        let second = store.createBot(name: "Listens")
        let room = store.createChannel(title: "Room",
                                       participants: [first.id, second.id],
                                       lead: first.id)

        XCTAssertTrue(store.removeParticipant(first.id, from: room.id))

        let after = store.conversation(room.id)!
        XCTAssertEqual(after.participants, [second.id])
        // The lead follows the bot that answers, which is the rule `createChannel` sets. A lead
        // left pointing at a bot that is no longer in the room is a dangling id in the state
        // file: free today, because nothing reads it, and a bot that cannot be found on the day
        // delegation ships.
        XCTAssertEqual(after.leadBot, second.id)
        // The bot itself is untouched — it was removed from a room, not deleted.
        XCTAssertNotNil(store.bot(first.id))
    }

    func testTheLastMemberOfARoomCannotBeRemoved() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        let room = store.createChannel(title: "Room", participants: [a.id, b.id])
        store.removeParticipant(a.id, from: room.id)

        // An empty room has no avatar, no possible reply and no way back. Deleting the room is
        // a decision the user should make on purpose, not one they reach by unchecking one name
        // too many — which is why the members menu disables this item rather than ignoring it.
        XCTAssertFalse(store.removeParticipant(b.id, from: room.id))
        XCTAssertEqual(store.conversation(room.id)?.participants, [b.id])

        XCTAssertFalse(store.removeParticipant(a.id, from: room.id), "not in the room")
    }

    // MARK: Deleting the thing the menu names

    func testARoomThatHasLostMembersIsStillARoom() {
        let store = fresh()
        let a = store.createBot(name: "A")
        let b = store.createBot(name: "B")
        let room = store.createChannel(title: "Room", participants: [a.id, b.id])
        let chat = store.conversations.first { $0.participants == [a.id] }!

        store.deleteBot(a.id)
        let survivor = store.conversation(room.id)!

        // `Conversation.isChannel` counts participants, so by that measure this room has just
        // become a chat. The roster keys its delete item off `Store.isRoom` instead: under the
        // count, "Delete Channel" deleted the surviving bot and the bot's own separate thread.
        XCTAssertFalse(survivor.isChannel)
        XCTAssertTrue(Store.isRoom(survivor))
        XCTAssertFalse(Store.isRoom(chat), "a bot's own chat is never a room")
    }

    func testDeletingABotMovesTheLeadToSomebodyStillInTheRoom() {
        let store = fresh()
        let lead = store.createBot(name: "Lead")
        let other = store.createBot(name: "Other")
        let room = store.createChannel(title: "Room",
                                       participants: [lead.id, other.id],
                                       lead: lead.id)

        store.deleteBot(lead.id)

        XCTAssertEqual(store.conversation(room.id)?.leadBot, other.id)
    }
}
