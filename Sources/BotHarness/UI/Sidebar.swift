import BotHarnessCore
import SwiftUI

/// The roster.
///
/// Rows are bots and channels, ordered by most recent activity. Each carries identity (avatar,
/// name), just enough of the last message to know whether it needs you, and — the part that was
/// missing — a mark when it *does* need you.
///
/// **A `List` with a selection binding, not a stack of tap gestures.** That one choice supplies
/// arrow-key navigation, type-to-select, a real focus ring, VoiceOver rows that announce
/// themselves as selectable, working context menus, and the system's own selection material.
/// The hand-rolled version had none of those, and painted its selection with an opaque fill
/// that flattened the sidebar's vibrancy — the exact thing the design tokens forbid.
struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    @Environment(UIState.self) private var ui
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var library: LibrarySheet.Tab?
    @State private var accountOpen = false
    @State private var createOpen = false
    @State private var makingChannel = false
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    /// Which rows are selected, as a set.
    ///
    /// macOS lists are multi-selectable by convention — ⇧-click for a range, ⌘-click for one
    /// more, ⌘A for all — and `List` gives all of that for free once its selection binding holds
    /// a `Set`. `Store.selection` stays single, because it answers a different question: which
    /// conversation the detail pane is showing. The two are kept in step below.
    @State private var selected: Set<UUID> = []
    @State private var pendingDeletion: DeletionRequest?

    /// One or more rows the user has asked to delete, held until they confirm.
    ///
    /// Carries whole `Conversation` values rather than ids: the confirmation names what is about
    /// to be destroyed, and by the time the user answers, a row may already be gone.
    private struct DeletionRequest: Identifiable {
        let id = UUID()
        let conversations: [Conversation]
    }
    /// Both are conditions the user cannot change from inside this app, so they are read when
    /// the window comes back to the front rather than held as a live subscription.
    @State private var keyFileIsExposed = false
    @State private var computerGrants = ComputerExecutor.permissions
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            search

            if filtered.isEmpty {
                EmptyState(
                    systemImage: query.isEmpty ? "person.2" : "magnifyingglass",
                    title: query.isEmpty ? "No bots yet" : "Nothing matches",
                    message: query.isEmpty
                        ? "Make one and tell it what you want done."
                        : "Try a different word, or clear the search.",
                    actionTitle: query.isEmpty ? "New bot" : "Clear search",
                    action: query.isEmpty ? { newBot() } : { query = "" }
                )
                .padding(.horizontal, DS.Space.lg)
                Spacer()
            } else {
                List(selection: $selected) {
                    ForEach(filtered) { conversation in
                        SidebarRow(conversation: conversation, matching: query)
                            .tag(conversation.id)
                            .contextMenu { menu(for: conversation) }
                    }
                }
                // The Delete key, on the list itself, so the keyboard route exists without a
                // menu. macOS guidance asks for keyboard-only work styles to be possible.
                .onDeleteCommand { askToDeleteSelection() }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                // Room to scroll clear of the footer, and a soft edge where it meets it.
                //
                // The list ends exactly where the footer's hairline begins, so whatever row
                // happens to straddle that line is sliced through — usually through the middle
                // of an avatar, which reads as a rendering fault rather than as a list that
                // continues below the fold. The padding gives the content somewhere to go; the
                // mask dissolves the last few points instead of cutting them.
                //
                // A mask rather than an overlay because the roster deliberately has no
                // background of its own — it inherits the window's material — so there is no
                // colour an overlay could fade to without banding against it.
                .safeAreaPadding(.bottom, DS.Space.sm)
                // As much room at the top as the top fade is tall. The fade is constant, so
                // without this inset it dissolved the first row's title even when the list had
                // never been scrolled — the roster opened with its first bot beheaded. At rest
                // the content starts just past the fade; scrolled, rows dissolve into it,
                // which is the only moment the fade is for.
                .safeAreaPadding(.top, DS.Space.lg)
                // Both edges, and measured in points rather than in percent.
                //
                // The fade used to be the last 6% of the list, which is not a length: on a short
                // window that is barely a hairline and on a tall one it washes out most of a row.
                // A fixed height dissolves the same amount of a row wherever the list ends.
                //
                // The top got no treatment at all, which was the more visible half of the bug —
                // a scrolled roster cut its first row straight through the middle of an avatar,
                // with a hard edge and nothing above it to explain the cut.
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: DS.Space.lg)
                        Color.black
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: DS.Space.xl)
                    }
                )
            }

            footer
        }
        // No background: the roster is the functional layer and inherits the window's
        // material, which is what makes it read as a native sidebar.
        .sheet(item: $library) { LibrarySheet(tab: $0) }
        // Attached to the roster rather than to the popover that offers it: a sheet presented
        // from inside a popover's own view tree races the popover's dismissal and sometimes
        // never appears.
        // The store is handed over explicitly rather than left to be inherited. A sheet is
        // presented from a different part of the view hierarchy, and `@Environment(Store.self)`
        // traps rather than degrades if it is not there — the same reason the Settings scene
        // passes it in by hand.
        .sheet(isPresented: $makingChannel) { NewChannelSheet().environment(store) }
        // ⇧⌘N raises a counter rather than reaching into this view's state, because the menu bar
        // is built where the scene is and the sheet belongs to the roster.
        .onChange(of: ui.newChannelRequests) { makingChannel = true }
        .onChange(of: ui.focusSearchRequests) { searchFocused = true }
        // Opening a conversation is what marks it read. Doing it on selection rather than on
        // scroll means the mark means "you looked at this", which is what a person expects.
        .onChange(of: store.selection, initial: true) { _, id in
            if let id { store.markRead(id) }
            // Something outside the roster changed which conversation is open — ⌘N, a
            // notification, a deletion repairing the selection. The row highlight has to follow
            // it, or the list shows one thing selected while the pane shows another.
            if let id, !selected.contains(id) { selected = [id] }
            ui.selectionCount = max(selected.count, id == nil ? 0 : 1)
        }
        .onChange(of: selected, initial: true) { _, rows in
            ui.selectionCount = max(rows.count, store.selection == nil ? 0 : 1)
            // One row selected means "open it". Several means the user is picking a batch, and
            // opening whichever they touched last would yank the pane around under them, so the
            // pane holds still as long as what it is showing is still in the batch.
            if rows.count == 1 {
                if store.selection != rows.first { store.selection = rows.first }
            } else if rows.count > 1, let current = store.selection, !rows.contains(current) {
                store.selection = filtered.first { rows.contains($0.id) }?.id
            }
        }
        // ⌘⌫ from the menu bar. The roster owns the selection, so the command asks rather than
        // reaching in — the same pattern ⇧⌘N already uses.
        .onChange(of: ui.deleteSelectionRequests) { askToDeleteSelection() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { request in
            Button(request.conversations.count == 1 ? "Delete" : "Delete \(request.conversations.count)",
                   role: .destructive) { confirmDelete(request.conversations) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { request in
            Text(deletionMessage(for: request.conversations))
        }
        // Rename is an alert rather than an inline editable row on purpose: a list row that
        // becomes a text field on a second click is the pattern Finder uses for files, and it
        // fights arrow-key navigation in a list that also uses a selection binding.
        //
        // One alert for both kinds of row. Which object the name is stored on is this app's
        // business, not the user's, so the item, the field and the buttons are the same either
        // way and only the sentence underneath differs — because the promises differ.
        .alert("Rename", isPresented: Binding(get: { renaming != nil },
                                              set: { if !$0 { renaming = nil } }),
               presenting: renaming) { target in
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename(target) }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { target in
            Text(target.explanation)
        }
    }

    private var deletionTitle: String {
        guard let request = pendingDeletion else { return "Delete?" }
        guard let only = request.conversations.first, request.conversations.count == 1 else {
            return "Delete \(request.conversations.count) items?"
        }
        return "Delete \(title(for: only))?"
    }

    /// What is about to be destroyed, named.
    ///
    /// A batch lists what it is going to remove rather than saying "3 items", up to a point: the
    /// whole reason a person multi-selects is that the rows look alike, and "Delete 40 items?"
    /// with no names is a dialog nobody can check before agreeing to it.
    private func deletionMessage(for conversations: [Conversation]) -> String {
        let tail = " The trace of past runs stays on disk. This cannot be undone."
        guard let only = conversations.first, conversations.count == 1 else {
            let names = conversations.prefix(5).map { title(for: $0) }.joined(separator: ", ")
            let rest = conversations.count > 5 ? ", and \(conversations.count - 5) more" : ""
            return "This removes \(names)\(rest), and everything they have done." + tail
        }
        return "This removes \(title(for: only)) and everything it has done." + tail
    }

    /// Ask about whatever is selected. Does nothing when nothing is selected, so the Delete key
    /// on an empty roster is a no-op rather than a dialog about nothing.
    private func askToDeleteSelection() {
        var rows = filtered.filter { selected.contains($0.id) }
        // Falling back to the open conversation is not a workaround for the set being empty —
        // it is the behaviour people expect. `List` drops its selection set in situations the
        // user does not think of as deselecting (the roster losing focus while they work in the
        // transcript, the row set changing underneath it), and "delete" with one conversation
        // plainly open in front of you should never answer "delete what?".
        if rows.isEmpty, let open = store.selection.flatMap({ store.conversation($0) }) {
            rows = [open]
        }
        guard !rows.isEmpty else { return }
        pendingDeletion = DeletionRequest(conversations: rows)
    }

    // MARK: Actions

    private func newBot() {
        store.createBot(name: "New Bot")
        ui.focusComposer()
    }

    /// `menuItem` has already closed the popover by the time this runs, and the sheet hangs off
    /// the roster rather than off the popover, so there is nothing here to sequence.
    private func newChannel() {
        makingChannel = true
    }

    /// Both kinds of row commit through the store, which owns the trimming, the refusal of a
    /// blank name and — for a bot — the flag that stops it renaming itself back.
    ///
    /// None of that lives here on purpose: the test bundle links `BotHarnessCore` and not this
    /// target, so a rule written in the view could only be checked by copying it into a test,
    /// where it would go stale the first time one of the two paths changed.
    private func commitRename(_ target: RenameTarget) {
        let typed = renameText
        renaming = nil
        switch target {
        case .bot(let bot):          store.renameBot(bot.id, to: typed)
        case .room(let conversation): store.renameConversation(conversation.id, to: typed)
        }
    }

    private func refreshStandingConditions() {
        keyFileIsExposed = !CredentialStore.permissionsAreCorrect()
        computerGrants = ComputerExecutor.permissions
    }

    private var computerConsentIsIncomplete: Bool {
        !computerGrants.screenRecording || !computerGrants.accessibility
    }

    /// Stop the work before removing the thing it was working on.
    ///
    /// A loop left running against a deleted conversation writes into nothing, holds an
    /// approval nobody can answer, and never stops. The runner is told first, then the store.
    private func confirmDelete(_ conversations: [Conversation]) {
        pendingDeletion = nil
        selected.removeAll()
        for conversation in conversations { delete(conversation) }
    }

    private func delete(_ conversation: Conversation) {
        runner.discard([conversation.id])
        ui.discardDrafts(for: [conversation.id])
        // `Store.isRoom` rather than `Conversation.isChannel`. A room that has lost members is
        // down to one participant, and by the participant count it looks exactly like that
        // bot's own chat — so this branch used to delete the bot, and the bot's separate
        // thread, when the user asked to delete a room.
        if let botID = conversation.participants.first, !Store.isRoom(conversation) {
            let orphaned = store.deleteBot(botID)
            runner.discard(orphaned, bots: [botID])
            ui.discardDrafts(for: orphaned)
        } else {
            store.deleteConversation(conversation.id)
        }
    }

    @ViewBuilder private func menu(for conversation: Conversation) -> some View {
        Button("Open") { store.selection = conversation.id }
        // Every row can be renamed now. A bot's name is a field on the bot and a room's is
        // `Conversation.title`; the store writes both, so the item reads the same in both menus
        // and the alert it opens is the same alert. A channel used to be nameable only at the
        // moment it was made, which meant a channel named by mistake was named that for ever.
        if Store.isRoom(conversation) {
            Button("Rename…") {
                renameText = conversation.title ?? ""
                renaming = .room(conversation)
            }
            members(of: conversation)
        } else if let bot = store.bot(conversation.participants.first) {
            Button("Rename…") { renameText = bot.name; renaming = .bot(bot) }
        }
        if runner.isRunning(conversation.id) {
            Button("Stop Run") { runner.stop(conversation.id) }
        }
        Divider()
        Button("Clear Messages") { store.clearMessages(in: conversation.id) }
        // Right-clicking inside a multi-selection acts on the whole selection, which is what
        // every macOS list does. Right-clicking a row *outside* it acts on that row alone.
        if selected.count > 1, selected.contains(conversation.id) {
            Button("Delete \(selected.count) Items", role: .destructive) {
                askToDeleteSelection()
            }
        } else {
            Button(Store.isRoom(conversation) ? "Delete Channel" : "Delete Bot",
                   role: .destructive) {
                pendingDeletion = DeletionRequest(conversations: [conversation])
            }
        }
    }

    /// Who is in the room, changeable after the room was made.
    ///
    /// A menu of checkmarks rather than a second sheet: the decision is one bot at a time, and
    /// a sheet would have to repeat the ordering rule the new-channel sheet already explains.
    /// The bot that answers is marked here for the same reason it is marked there — removing it
    /// hands the room to whoever is next, and that belongs in front of the click rather than
    /// being discovered afterwards.
    @ViewBuilder private func members(of conversation: Conversation) -> some View {
        // The room as the store has it now rather than as the row captured it when the menu was
        // built. A checkmark here is a claim about who is in the room at this moment, and the
        // control next to it is the thing that changes that.
        let live = store.conversation(conversation.id) ?? conversation
        Menu("Members") {
            ForEach(store.bots) { bot in
                let isMember = live.participants.contains(bot.id)
                Toggle(isOn: Binding(
                    get: { isMember },
                    set: { wanted in
                        if wanted {
                            store.addParticipant(bot.id, to: conversation.id)
                        } else {
                            store.removeParticipant(bot.id, from: conversation.id)
                        }
                    }
                )) {
                    Text(live.participants.first == bot.id
                         ? "\(bot.name) — answers here"
                         : bot.name)
                }
                // The last member cannot be removed: a room with nobody in it can never answer
                // and there is nothing left to do with it but delete it. Disabled rather than
                // silently refused on click, because a control that does nothing is exactly the
                // dead end this pass exists to remove.
                .disabled(isMember && live.participants.count == 1)
            }
        }
    }

    // MARK: Filtering

    private var filtered: [Conversation] {
        let all = store.sortedConversations
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { matches(trimmed, $0) }
    }

    /// Searches everything the timeline can show, not only prose.
    ///
    /// Previously only `.text` bodies were searched, so a tool card, a notice or a failure —
    /// most of what a working conversation contains — was unfindable.
    private func matches(_ needle: String, _ conversation: Conversation) -> Bool {
        if title(for: conversation).localizedCaseInsensitiveContains(needle) { return true }
        if let bot = store.bot(conversation.participants.first),
           bot.label.localizedCaseInsensitiveContains(needle) { return true }
        return conversation.messages.contains { Self.searchText(of: $0).localizedCaseInsensitiveContains(needle) }
    }

    static func searchText(of message: Message) -> String {
        switch message.body {
        case .text(let t):       return t
        case .toolUse(let a):    return a.summary + " " + a.detail
        case .computer(let a):   return a.task
        case .approval(let a):   return a.summary + " " + a.detail
        case .notice(let n):     return n
        case .failure(let f):    return f
        case .screenshot(let s): return s.caption
        }
    }

    private func title(for c: Conversation) -> String {
        c.title ?? store.bot(c.participants.first)?.name ?? "Untitled"
    }

    // MARK: Pieces

    /// The one place anything new is made.
    ///
    /// A popover rather than a bare button, because there are two things to make and channels
    /// are the product's own idea. `Store.createChannel` existed with no caller at all: the
    /// header, the keyboard and the empty state all made bots, so the differentiating object
    /// was unreachable from the interface that is supposed to be its only interface.
    ///
    /// A popover rather than a `Menu` for the reason recorded on the account row below: `Menu`
    /// insets its own label and there is no supported way to take those insets off, which
    /// pushes the control off the column's edge.
    private var header: some View {
        HStack {
            Spacer()
            IconButton("plus", filled: false, help: "New bot or channel",
                       accessibilityLabel: "New bot or channel") { createOpen.toggle() }
                .popover(isPresented: $createOpen, arrowEdge: .bottom) { createMenu }
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: DS.Size.rosterRow)
    }

    private var createMenu: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            menuItem("person.crop.circle.badge.plus", "New bot", closing: $createOpen) {
                newBot()
            }
            menuItem("person.2.badge.plus", "New channel…", closing: $createOpen) {
                newChannel()
            }
            Text("A channel is one thread with several bots in it.")
                .font(DS.Text.micro)
                .foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.md)
        .frame(minWidth: DS.Window.popoverMin)
    }

    private var search: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "magnifyingglass")
                .font(DS.Text.glyphSmall)
                .foregroundStyle(DS.Ink.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .frame(minWidth: DS.Size.fieldMin / 2)
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.primary)
                .focused($searchFocused)
                .accessibilityLabel("Search conversations")
                // Escape clears rather than dismissing focus into nothing, which is what the
                // field appearing to be stuck used to feel like.
                .onExitCommand { if query.isEmpty { searchFocused = false } else { query = "" } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Text.glyphSmall)
                        .foregroundStyle(DS.Ink.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.md)
        .dsWell(DS.Radius.sm)
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.sm)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            // The one condition in this app that is about the user's safety rather than their
            // work, and it was legible in exactly one place: Settings → Providers, evaluated on
            // the frame that pane appeared. A world-readable key file is not something anyone
            // goes looking for, so it has to come to them. The roster footer is the only
            // surface that is on screen whenever the app is.
            if keyFileIsExposed {
                StandingNotice(
                    systemImage: "lock.open",
                    title: "Your key file can be read by others",
                    detail: "It should be readable only by you. A restore from a backup or a "
                          + "sync tool can quietly change that.",
                    actionTitle: "Lock it down",
                    tint: DS.Status.failed.mark,
                    action: repairKeyFilePermissions
                )
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.md)
            }

            Hairline()

            Button { library = .connections } label: {
                // `app.connected.to.app.below.fill` drew as a faint diagonal stroke with two
                // dots at the 13-point size this row uses — illegible, much lighter than the
                // icons beside it, and read as a stray mark rather than a control. A plug is
                // legible small and says the right thing about a list of connectors.
                footerRow("powerplug", "Connections")
            }
            .buttonStyle(.plain)

            // The badge, not a second banner. The two macOS grants have a home already — the
            // Computers tab, with the buttons that ask for them — so what was missing was not
            // another explanation but any reason to go there.
            Button { library = .computers } label: {
                footerRow("desktopcomputer", "Computers",
                          warning: computerConsentIsIncomplete
                                 ? "Screen Recording or Accessibility has not been granted yet"
                                 : nil)
            }
            .buttonStyle(.plain)

            // A Button with a popover rather than a Menu.
            //
            // `Menu` applies its own internal insets to whatever label it is given, so the
            // account row sat several points right of the two above it and broke the column's
            // left edge. There is no supported way to remove those insets, and compensating
            // with a negative padding is a number that goes wrong the moment the style
            // changes. A button that opens a popover is fully ours to align.
            Button { accountOpen.toggle() } label: {
                footerRow("person.crop.circle", "This Mac")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $accountOpen, arrowEdge: .top) {
                accountMenu
            }
        }
        .padding(.bottom, DS.Space.sm)
        .refreshingOnActivation(refreshStandingConditions)
    }

    /// Tighten the mode back to owner-only, and re-ask rather than assume it worked.
    ///
    /// Done from a button and never silently: the file belongs to the user, and an app that
    /// quietly changes permissions on files in the user's home directory is doing the thing
    /// this notice is warning about.
    private func repairKeyFilePermissions() {
        CredentialStore.repairPermissions()
        keyFileIsExposed = !CredentialStore.permissionsAreCorrect()
    }

    private var accountMenu: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            SettingsLink {
                menuLabel("gearshape", "Settings…")
            }
            .buttonStyle(.plain)
            .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.xs))
            .simultaneousGesture(TapGesture().onEnded { accountOpen = false })

            menuItem("sparkles", "Skills…", closing: $accountOpen) { library = .skills }
            menuItem("clock.arrow.circlepath", "Activity…", closing: $accountOpen) {
                openWindow(id: "activity")
            }

            Hairline().padding(.vertical, DS.Space.xs)

            menuItem("folder", "Open trace folder", closing: $accountOpen) {
                NSWorkspace.shared.open(Paths.traces)
            }
            menuItem("internaldrive", "Open data folder", closing: $accountOpen) {
                NSWorkspace.shared.open(Paths.root)
            }

            Hairline().padding(.vertical, DS.Space.xs)

            menuItem("power", "Quit Bot-Harness", closing: $accountOpen) { NSApp.terminate(nil) }
        }
        .padding(DS.Space.md)
        .frame(minWidth: DS.Window.popoverMin)
    }

    private func menuLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(DS.Text.glyphSmall)
                .foregroundStyle(DS.Ink.secondary)
                .frame(width: DS.Space.lg)
                .accessibilityHidden(true)
            Text(title).font(DS.Text.caption).foregroundStyle(DS.Ink.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.md)
        .frame(minHeight: DS.Size.hit)
        .contentShape(Rectangle())
    }

    /// Which popover this item belongs to is a parameter rather than a captured property,
    /// because there are now two of them and an item that closed the wrong one would leave a
    /// menu hanging open over the sheet it had just presented.
    private func menuItem(_ icon: String, _ title: String, closing: Binding<Bool>,
                          action: @escaping () -> Void) -> some View {
        Button {
            closing.wrappedValue = false
            action()
        } label: {
            menuLabel(icon, title)
        }
        .buttonStyle(.plain)
        .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.xs))
    }

    private func footerRow(_ icon: String, _ label: String,
                           warning: String? = nil) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(DS.Text.glyph)
                .foregroundStyle(DS.Ink.secondary)
                // A fixed gutter, so every label in the footer starts on the same pixel
                // whatever the width of its icon.
                .frame(width: DS.Space.xl, alignment: .center)
                .accessibilityHidden(true)
            Text(label)
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.primary)
            Spacer()
            if warning != nil {
                Circle()
                    .fill(DS.Status.awaitingApproval.mark)
                    .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: DS.Size.hit + DS.Space.xs, alignment: .leading)
        .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .contentShape(Rectangle())
        .help(warning ?? "")
        // A coloured dot is not a status on its own — the app's own rule. VoiceOver and a
        // greyscale screenshot both get the sentence instead.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(warning.map { "\(label). \($0)" } ?? label)
    }
}

// MARK: - What the rename alert is pointed at

/// A bot's name lives on the bot and a room's lives on the conversation. That difference is
/// this app's problem, not the user's, so it is absorbed here: one alert, one field, one pair
/// of buttons, and only the sentence underneath changes — because a bot can rename itself after
/// a run and a room cannot, and promising the wrong one would be a lie in either direction.
private enum RenameTarget: Identifiable {
    case bot(Bot)
    case room(Conversation)

    var id: UUID {
        switch self {
        case .bot(let bot):           return bot.id
        case .room(let conversation): return conversation.id
        }
    }

    var explanation: String {
        switch self {
        case .bot(let bot):
            return "\(bot.name) will keep its description, its history and its folder. "
                 + "A name you choose is yours — the bot will not write over it."
        case .room(let conversation):
            return "\(conversation.title ?? "This channel") will keep everyone in it and "
                 + "everything said in it. Only the name in the roster changes."
        }
    }
}

// MARK: - One row

private struct SidebarRow: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    let conversation: Conversation
    var matching: String = ""

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            avatar
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.sm) {
                    Text(title)
                        .font(DS.Text.body.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                    if let state {
                        // A word, not only a colour — the roster has to survive greyscale and
                        // colour-blindness like every other status in the app.
                        Text(state.word)
                            .font(DS.Text.micro.weight(.semibold))
                            .foregroundStyle(state.label)
                            .fixedSize()
                    } else {
                        Text(relativeTime)
                            .font(DS.Text.micro)
                            .foregroundStyle(DS.Ink.secondary)
                            .fixedSize()
                    }
                }
                HStack(spacing: DS.Space.sm) {
                    Text(preview)
                        .font(DS.Text.callout)
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if conversation.isUnread && state == nil {
                        Circle()
                            .fill(DS.Accent.live)
                            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .dsInset(DS.Inset.row)
        // Avatar plus two lines. A fixed floor keeps the list on a rhythm whether a preview
        // is one line or empty.
        .frame(minHeight: DS.Size.rosterRow + DS.Space.xl, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// What this conversation needs from the user right now, if anything.
    ///
    /// The roster's whole job in a delegate-and-glance product, and it had none of it: an
    /// approval prompt rendered in exactly the muted style of an idle preview.
    private var state: DS.Status? {
        if runner.awaiting.values.contains(conversation.id) { return .awaitingApproval }
        if runner.isRunning(conversation.id) { return .running }
        return nil
    }

    private var title: String {
        conversation.title ?? store.bot(conversation.participants.first)?.name ?? "Untitled"
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if let state { parts.append(state.word) }
        else if conversation.isUnread { parts.append("unread") }
        parts.append(preview)
        parts.append(relativeTime)
        return parts.joined(separator: ", ")
    }

    /// Channels show stacked marks; a chat shows the bot's own.
    @ViewBuilder private var avatar: some View {
        if conversation.isChannel {
            let members = Array(conversation.participants.prefix(3).enumerated())
            ZStack(alignment: .leading) {
                ForEach(members, id: \.offset) { index, id in
                    if let member = store.bot(id) {
                        BotAvatar(bot: member, size: DS.Size.avatarRoster)
                            .overlay(Circle().stroke(DS.Surface.paperTint, lineWidth: 1.5))
                            .offset(x: CGFloat(index) * DS.Space.md)
                    }
                }
            }
            // Room for every avatar in the stack, not just the first two: the frame used to be
            // one offset wide regardless of how many were drawn, so the third was clipped.
            .frame(width: DS.Size.avatarRoster + CGFloat(max(0, members.count - 1)) * DS.Space.md,
                   height: DS.Size.avatarRoster, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            if let bot = store.bot(conversation.participants.first) {
                BotAvatar(bot: bot, size: DS.Size.avatarRoster).accessibilityHidden(true)
            } else {
                Circle().fill(DS.Tint.t3)
                    .frame(width: DS.Size.avatarRoster, height: DS.Size.avatarRoster)
                    .accessibilityHidden(true)
            }
        }
    }

    private var preview: String {
        // While searching, show the line that actually matched rather than the last message,
        // which usually has nothing to do with why the row is on screen.
        let needle = matching.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty,
           let hit = conversation.messages.last(where: {
               Sidebar.searchText(of: $0).localizedCaseInsensitiveContains(needle)
           }) {
            return Sidebar.searchText(of: hit).replacingOccurrences(of: "\n", with: " ")
        }
        guard let last = conversation.messages.last else { return "No messages yet" }
        switch last.body {
        case .text(let t):       return t.replacingOccurrences(of: "\n", with: " ")
        case .toolUse(let a):    return a.summary
        case .computer(let a):   return a.task
        case .approval(let a):   return "Needs your approval — \(a.summary)"
        case .notice(let n):     return n
        case .failure(let f):    return f
        case .screenshot(let s): return s.caption
        }
    }

    private var relativeTime: String {
        // A conversation created microseconds ago is not in the future. Clamping removes the
        // "in 0s" every freshly made bot used to show.
        let now = Date()
        let when = min(conversation.lastActivity, now)
        if now.timeIntervalSince(when) < 45 { return "now" }
        return Self.formatter.localizedString(for: when, relativeTo: now)
    }

    /// One formatter for the whole roster. Allocating one per row per render is measurable on
    /// a list that re-renders on every keystroke of search.
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
