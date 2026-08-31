import BotHarnessCore
import SwiftUI

/// The conversation column.
///
/// Everything here hangs off one decision: the transcript lives in a centred reading column
/// rather than filling the pane. Prose past roughly ninety characters a line stops being
/// comfortable, and a chat stretched across a wide display is the clearest sign a layout was
/// only ever looked at in one window size. The header and composer align to the same column,
/// so the eye follows a single left edge from the top of the window to the bottom.
struct ConversationView: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    @Environment(UIState.self) private var ui

    @State private var scrolled = false
    @State private var atBottom = true
    /// Height of the transcript viewport, so content can be pinned to its bottom.
    @State private var available: CGFloat = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if let conversation {
                transcript(conversation)
                ReadingColumn { ActivityInspector(conversationID: conversation.id) }
                ReadingColumn {
                    Composer(conversationID: conversation.id,
                             draft: ui.draftBinding(for: conversation.id),
                             focused: $composerFocused)
                }
            } else {
                nothingSelected
            }
        }
        .background(DS.Surface.ground)
        // Focus has to wait for the window to become key. Setting @FocusState in onAppear runs
        // before that happens and is silently dropped, leaving the app looking usable while
        // typing does nothing.
        .task(id: store.selection) {
            guard store.selection != nil else { return }
            try? await Task.sleep(for: .milliseconds(120))
            // Only claim focus if nothing else has it. Re-focusing on every selection change
            // used to steal the caret out of the search field mid-word.
            guard !composerFocused else { return }
            composerFocused = true
        }
        .onChange(of: ui.focusComposerRequests) { composerFocused = true }
    }

    private var conversation: Conversation? { store.conversation(store.selection) }
    private var bot: Bot? { store.bot(conversation?.participants.first) }

    // MARK: Nothing selected

    /// What the column says when there is no conversation.
    ///
    /// There is deliberately no composer here. It used to render against a throwaway
    /// conversation id, so it looked completely live — placeholder, attach button, send button —
    /// and quietly destroyed anything typed into it.
    private var nothingSelected: some View {
        VStack(spacing: DS.Space.lg) {
            Spacer()
            EmptyState(systemImage: "bubble.left.and.bubble.right",
                       title: "No bot selected",
                       message: "Pick one from the list, or make a new one to get started.",
                       actionTitle: "New bot",
                       action: {
                           store.createBot(name: "New Bot")
                           ui.focusComposer()
                       })
            Spacer()
        }
        // Width only. The two Spacers already do the vertical work, and a `maxHeight` here
        // would claim the space rather than fill it — the same trap the composer documents.
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    /// Full titlebar height, and its hairline appears only once the transcript has scrolled —
    /// a permanent divider under a header is a line the design does not need at rest.
    private var header: some View {
        VStack(spacing: 0) {
            ReadingColumn {
                HStack(spacing: DS.Space.md) {
                    if let conversation, conversation.isChannel {
                        channelIdentity(conversation)
                    } else if let bot {
                        BotAvatar(bot: bot, size: DS.Size.avatarRoster)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(conversation?.title ?? bot.name)
                                .font(DS.Text.title)
                                .foregroundStyle(DS.Ink.primary)
                            if !bot.label.isEmpty {
                                Text(bot.label)
                                    .font(DS.Text.micro)
                                    .foregroundStyle(DS.Ink.secondary)
                            }
                        }
                    }
                    Spacer(minLength: DS.Space.md)

                    if conversation != nil {
                        IconButton("gearshape", filled: false, help: "Bot settings",
                                   accessibilityLabel: "Bot settings") {
                            ui.openBotSettings()
                        }
                    }
                    IconButton(ui.showPanel ? "sidebar.trailing" : "sidebar.leading",
                               filled: false,
                               help: ui.showPanel ? "Hide panel (⌥⌘2)" : "Show panel (⌥⌘2)",
                               accessibilityLabel: ui.showPanel ? "Hide panel" : "Show panel") {
                        ui.showPanel.toggle()
                        ui.panelClosedByWindow = false
                    }
                }
                .frame(height: DS.Size.titlebar)
            }
            if scrolled { Hairline() }
        }
        .dsAnimation(DS.Motion.instant, value: scrolled)
    }

    /// A channel's own identity line: the room's name and who is in it.
    ///
    /// Without this branch a channel wore the first member's avatar and label, which reads as
    /// a chat with that one bot — the roster already draws stacked marks for a channel, and a
    /// header that disagreed with the row that opened it is worse than one that says nothing.
    private func channelIdentity(_ conversation: Conversation) -> some View {
        let members = conversation.participants.compactMap { store.bot($0) }
        return HStack(spacing: DS.Space.md) {
            // Negative spacing rather than offsets, and exactly one avatar-minus-reveal wide,
            // so the stack overlaps by the same eight points the roster row uses. Two stacks
            // of the same three marks with different overlaps look like a mistake.
            HStack(spacing: -DS.Space.xl) {
                ForEach(members.prefix(3)) { member in
                    BotAvatar(bot: member, size: DS.Size.avatarRoster)
                        .overlay(Circle().stroke(DS.Surface.ground, lineWidth: DS.Size.hairline))
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title ?? "Channel")
                    .font(DS.Text.title)
                    .foregroundStyle(DS.Ink.primary)
                Text(memberSummary(members))
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title ?? "Channel"), \(memberSummary(members))")
    }

    private func memberSummary(_ members: [Bot]) -> String {
        guard let first = members.first else { return "No bots in this channel" }
        let others = members.count - 1
        guard others > 0 else { return "\(first.name) answers here" }
        return "\(first.name) answers · \(others) other bot\(others == 1 ? "" : "s") in the room"
    }

    // MARK: Transcript

    /// What the list actually contains: messages, with a date line wherever the day changes.
    private enum Row: Identifiable {
        case day(Date)
        case message(Message)

        var id: String {
            switch self {
            case .day(let date):    return "day-\(date.timeIntervalSince1970)"
            case .message(let m):   return m.id.uuidString
            }
        }
    }

    private func rows(of conversation: Conversation) -> [Row] {
        var out: [Row] = []
        var lastDay: Date?
        let calendar = Calendar.current
        for message in conversation.messages {
            let day = calendar.startOfDay(for: message.timestamp)
            if day != lastDay {
                out.append(.day(day))
                lastDay = day
            }
            out.append(.message(message))
        }
        return out
    }

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A zero-height sentinel at the top reports whether the content has moved,
                // which is what drives the header hairline.
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .named("transcript")).minY) { _, y in
                            let isScrolled = y < -2
                            if isScrolled != scrolled { scrolled = isScrolled }
                        }
                }
                .frame(height: 0)

                // Messages sit at the bottom, against the composer, the way every messaging
                // app does it. Top-aligned content leaves a void above the input that is the
                // single clearest tell that a chat layout has not been looked at.
                ReadingColumn {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        LazyVStack(alignment: .leading, spacing: DS.Space.lg) {
                            if conversation.messages.isEmpty {
                                introduction
                            }
                            ForEach(rows(of: conversation)) { row in
                                switch row {
                                case .day(let date):
                                    DaySeparator(date: date)
                                case .message(let message):
                                    MessageRow(message: message,
                                               conversationID: conversation.id)
                                        .id(message.id)
                                }
                            }
                        }
                        .padding(.top, DS.Space.xl)
                        // More room below than above: the last message should not sit against
                        // the composer, and the eye reads the gap as "this is the end".
                        .padding(.bottom, DS.Space.xxl)

                        // Reports whether the end of the transcript is on screen, which is what
                        // decides between following a stream and leaving a reader alone.
                        GeometryReader { geo in
                            Color.clear
                                .onChange(of: geo.frame(in: .named("transcript")).maxY,
                                          initial: true) { _, y in
                                    let visible = y <= available + DS.Space.xxl
                                    if visible != atBottom { atBottom = visible }
                                }
                        }
                        .frame(height: 0)
                        .id(Self.bottomAnchor)
                    }
                    // Deliberately *not* pinned to a viewport-height frame.
                    //
                    // Forcing the content to at least the viewport's height is what made the
                    // transcript permanently scrollable even when three messages fitted with
                    // room to spare, which in turn meant a full-height scrollbar sitting there
                    // for ever — and the previous answer to that was to hide scrollbars
                    // entirely, overriding the system's "always show" setting for everyone.
                    // `defaultScrollAnchor(.bottom)` already puts short content against the
                    // composer, which was the only thing the pinning was for.
                }
            }
            .defaultScrollAnchor(.bottom)
            // Follows the system preference rather than overriding it. `.hidden` removed the
            // only position affordance the transcript had, including for people who have asked
            // for scrollbars to be visible at all times.
            .scrollIndicators(.automatic)
            .coordinateSpace(name: "transcript")
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { available = geo.size.height }
                        .onChange(of: geo.size.height) { _, height in
                            guard height > 1 else { return }
                            available = height
                        }
                }
            }
            // Follow the conversation only while the reader is already at the end.
            //
            // Two bugs in one: scrolling fired on message *count*, so a reply streaming into an
            // existing bubble ran off the bottom of the window unwatched — and it fired
            // unconditionally, so a person reading history was yanked back to the present by
            // every new message.
            .onChange(of: signature(conversation)) {
                guard atBottom else { return }
                withAnimation(DS.Motion.rowInsert) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        withAnimation(DS.Motion.rowInsert) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(DS.Text.caption.weight(.medium))
                            .foregroundStyle(DS.Ink.primary)
                            .padding(.horizontal, DS.Space.lg)
                            .frame(height: DS.Size.hit)
                            .background(DS.Surface.raised, in: Capsule())
                            .overlay(Capsule().stroke(DS.Tint.t6, lineWidth: DS.Size.hairline))
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.bottom, DS.Space.lg)
                    .transition(.opacity)
                }
            }
            .dsAnimation(DS.Motion.instant, value: atBottom)
        }
    }

    private static let bottomAnchor = "transcript-bottom"

    /// Changes whenever anything in the transcript changes, including a reply growing in place.
    private func signature(_ conversation: Conversation) -> String {
        let last = conversation.messages.last
        return "\(conversation.messages.count)-\(last?.id.uuidString ?? "")-\(bodyLength(last))"
    }

    private func bodyLength(_ message: Message?) -> Int {
        guard let message else { return 0 }
        return Sidebar.searchText(of: message).count
    }

    /// What a bot with no history says for itself.
    ///
    /// The persona, not a greeting. An empty list teaches nobody what the app is for; the
    /// persona does, and it is the thing the user is about to edit anyway.
    @ViewBuilder private var introduction: some View {
        if let conversation, conversation.isChannel {
            channelIntroduction(conversation)
        } else if let bot {
            VStack(spacing: DS.Space.lg) {
                BotAvatar(bot: bot, size: DS.Size.avatarInspector)
                    .accessibilityHidden(true)
                Text(bot.name)
                    .font(DS.Text.title)
                    .foregroundStyle(DS.Ink.primary)
                Text(bot.persona.isEmpty
                     ? "Give this bot a description in Settings, then tell it what to do."
                     : bot.persona)
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .frame(maxWidth: DS.Window.proseMax)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            // Centred in what is left of the column rather than pinned to the composer. The
            // bottom-anchored transcript turned this from a hero into a footnote sitting on
            // top of the input.
            .padding(.vertical, DS.Space.xxxl)
        }
    }

    /// What a brand-new channel says for itself.
    ///
    /// A channel has no persona to show, and falling through to the first member's would have
    /// been the wrong answer twice: it describes one bot rather than the room, and it hides
    /// that the room is what the user just made. So this shows the roster, names the bot that
    /// answers, and states the limit — the same sentence the sheet that made it used, because
    /// somebody who made a channel a week ago should not have to remember it.
    private func channelIntroduction(_ conversation: Conversation) -> some View {
        let members = conversation.participants.compactMap { store.bot($0) }
        return VStack(spacing: DS.Space.lg) {
            HStack(spacing: -DS.Space.xl) {
                ForEach(members.prefix(3)) { member in
                    BotAvatar(bot: member, size: DS.Size.avatarInspector)
                        .overlay(Circle().stroke(DS.Surface.ground, lineWidth: DS.Size.hairline))
                }
            }
            .accessibilityHidden(true)

            Text(conversation.title ?? "Channel")
                .font(DS.Text.title)
                .foregroundStyle(DS.Ink.primary)

            Text(members.map(\.name).joined(separator: ", "))
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Window.proseMax)
                .fixedSize(horizontal: false, vertical: true)

            Text("Everyone here shares one thread. Today \(members.first?.name ?? "the first bot") "
               + "is the one that answers; the others are in the room and do not speak on their "
               + "own yet.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .frame(maxWidth: DS.Window.proseMax)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xxxl)
    }
}

/// The date line between one day's messages and the next.
///
/// The transcript is described as the record of the work, and a record with no time axis is
/// a list. Every message carried a timestamp that nothing rendered.
private struct DaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Rectangle().fill(DS.Tint.t6).frame(height: DS.Size.hairline)
            Text(label)
                .font(DS.Text.micro.weight(.medium))
                .foregroundStyle(DS.Ink.secondary)
                .fixedSize()
            Rectangle().fill(DS.Tint.t6).frame(height: DS.Size.hairline)
        }
        .padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }
}
