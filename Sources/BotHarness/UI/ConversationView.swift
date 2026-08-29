import BotHarnessCore
import SwiftUI

/// The conversation column — the centre of the product.
///
/// Bot output is prose in a wide bubble on the left. The user's hugs its content on the right.
/// Everything the bot *does*, as opposed to says, appears as a card in the same timeline, so
/// the record of the work and the record of the conversation are one thing rather than two
/// that have to be correlated.
struct ConversationView: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    @Environment(UIState.self) private var ui

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.Tint.t6).frame(height: DS.Size.hairline)
            if let conversation {
                timeline
                ActivityInspector(conversationID: conversation.id)
                Composer(conversationID: conversation.id,
                         draft: $draft,
                         focused: $composerFocused)
            } else {
                nothingSelected
            }
        }
        .background(DS.Surface.ground)
        // Focus has to wait for the window to become key. Setting @FocusState in onAppear runs
        // before that happens and is silently dropped, which leaves the app looking usable
        // while typing does nothing.
        .onChange(of: ui.focusRequests) {
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                composerFocused = true
            }
        }
        .task(id: store.selection) {
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
    }

    private var conversation: Conversation? { store.conversation(store.selection) }
    private var bot: Bot? { store.bot(conversation?.participants.first) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.md + 1) {
            if let conversation {
                Circle()
                    .fill(bot?.tint ?? DS.Ink.tertiary)
                    .frame(width: DS.Size.glyph + 6, height: DS.Size.glyph + 6)
                Text(conversation.title ?? bot?.name ?? "Untitled")
                    .font(DS.Text.title)
                    .foregroundStyle(DS.Ink.primary)
            }
            Spacer()

            IconButton("gearshape", filled: false, help: "Bot settings") {
                ui.openBotSettings()
            }
            IconButton(ui.showPanel ? "chevron.right.2" : "chevron.left.2",
                       filled: false,
                       help: ui.showPanel ? "Hide panel" : "Show panel") {
                ui.showPanel.toggle()
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .frame(height: DS.Size.rosterRow)
        // Room for the traffic lights, since the title bar is hidden.
        .padding(.top, DS.Space.md)
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.lg - 2) {
                    if let conversation {
                        if conversation.messages.isEmpty {
                            introduction
                        }
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xxl - 2)
                .padding(.vertical, DS.Space.xl + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation?.messages.count ?? 0) {
                guard let last = conversation?.messages.last else { return }
                withAnimation(DS.Motion.instant) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// What the column says before there is a bot to talk to.
    ///
    /// The one surface in this app allowed to be charming. The design system's rule is that
    /// how often a surface appears decides how much motion it earns, and this one appears on
    /// first launch and then never again — so it gets the mascot, and nothing else does.
    ///
    /// There is no composer under it on purpose: with nothing selected there is nowhere for
    /// typing to go, and a text field that silently discards what you type is worse than no
    /// text field.
    private var nothingSelected: some View {
        VStack(spacing: DS.Space.xl) {
            Spacer()
            WalkingMascot()
            VStack(spacing: DS.Space.xs + 1) {
                Text("No bot yet")
                    .font(DS.Text.title)
                    .foregroundStyle(DS.Ink.primary)
                Text("Make one, and tell it what you want done on this Mac.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.tertiary)
            }
            SecondaryButton("New bot") {
                store.createBot(name: "New Bot")
                ui.focusComposer()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.Space.xxxl)
    }

    /// What a bot with no history says for itself.
    ///
    /// The persona, not a generic greeting. An empty list teaches nobody what the app is for;
    /// the persona does, and it is the thing the user is about to edit anyway.
    @ViewBuilder private var introduction: some View {
        if let bot {
            VStack(spacing: DS.Space.lg) {
                Circle()
                    .fill(bot.tint)
                    .frame(width: DS.Size.avatarInspector - 12, height: DS.Size.avatarInspector - 12)
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
            .padding(.top, DS.Space.xxxl * 2)
        }
    }
}
