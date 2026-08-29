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

    @State private var draft = ""
    @State private var scrolled = false
    /// Height of the transcript viewport, so content can be pinned to its bottom.
    @State private var available: CGFloat = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            if let id = store.selection {
                ReadingColumn { ActivityInspector(conversationID: id) }
            }
            ReadingColumn {
                Composer(conversationID: store.selection ?? UUID(),
                         draft: $draft,
                         focused: $composerFocused)
            }
        }
        .background(DS.Surface.ground)
        // Focus has to wait for the window to become key. Setting @FocusState in onAppear runs
        // before that happens and is silently dropped, leaving the app looking usable while
        // typing does nothing.
        .task(id: store.selection) {
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
    }

    private var conversation: Conversation? { store.conversation(store.selection) }
    private var bot: Bot? { store.bot(conversation?.participants.first) }

    // MARK: Header

    /// Full titlebar height, and its hairline appears only once the transcript has scrolled —
    /// a permanent divider under a header is a line the design does not need at rest.
    private var header: some View {
        VStack(spacing: 0) {
            ReadingColumn {
                HStack(spacing: DS.Space.md) {
                    if let bot {
                        BotAvatar(bot: bot, size: DS.Size.avatarRoster - 4)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(conversation?.title ?? bot.name)
                                .font(DS.Text.title)
                                .foregroundStyle(DS.Ink.primary)
                            if !bot.label.isEmpty {
                                Text(bot.label)
                                    .font(DS.Text.micro)
                                    .foregroundStyle(DS.Ink.tertiary)
                            }
                        }
                    }
                    Spacer(minLength: DS.Space.md)

                    IconButton("gearshape", filled: false, help: "Bot settings") {
                        ui.openBotSettings()
                    }
                    IconButton("sidebar.trailing", filled: false,
                               help: ui.showPanel ? "Hide panel" : "Show panel") {
                        ui.showPanel.toggle()
                    }
                }
                .frame(height: DS.Size.titlebar)
            }
            if scrolled { Hairline() }
        }
        .dsAnimation(DS.Motion.instant, value: scrolled)
    }

    // MARK: Transcript

    private var transcript: some View {
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
                            if let conversation {
                                if conversation.messages.isEmpty {
                                    introduction
                                }
                                ForEach(conversation.messages) { message in
                                    MessageRow(message: message).id(message.id)
                                }
                            }
                        }
                        .padding(.top, DS.Space.xl)
                        // More room below than above: the last message should not sit against
                        // the composer, and the eye reads the gap as "this is the end".
                        .padding(.bottom, DS.Space.xxl)
                    }
                    // The padding lives *inside* the min-height frame. Outside it, the content
                    // is always exactly that much taller than the viewport, so the transcript
                    // is permanently scrolled by 32 points and the last message hides behind
                    // the composer.
                    // Only pin to the viewport once its height is actually known. During a
                    // live resize the reader can report zero, and a zero min-height collapses
                    // the transcript to nothing.
                    .frame(minHeight: available > 1 ? available : nil, alignment: .bottom)
                }
            }
            .defaultScrollAnchor(.bottom)
            // The transcript is always technically scrollable, because its content is pinned
            // to a viewport-height frame. A permanent scrollbar for content that fits is
            // furniture, so it appears only while scrolling.
            .scrollIndicators(.hidden)
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
            .onChange(of: conversation?.messages.count ?? 0) {
                guard let last = conversation?.messages.last else { return }
                withAnimation(DS.Motion.rowInsert) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// What a bot with no history says for itself.
    ///
    /// The persona, not a greeting. An empty list teaches nobody what the app is for; the
    /// persona does, and it is the thing the user is about to edit anyway.
    @ViewBuilder private var introduction: some View {
        if let bot {
            VStack(spacing: DS.Space.lg) {
                BotAvatar(bot: bot, size: DS.Size.avatarInspector)
                Text(bot.name)
                    .font(DS.Text.title)
                    .foregroundStyle(DS.Ink.primary)
                Text(bot.persona.isEmpty
                     ? "Give this bot a description in Settings, then tell it what to do."
                     : bot.persona)
                    .font(DS.Text.callout)
                    .foregroundStyle(bot.persona.isEmpty ? DS.Ink.tertiary : DS.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Space.xxxl)
            .padding(.bottom, DS.Space.xl)
        }
    }
}
