import BotHarnessCore
import SwiftUI

/// The conversation column — the centre of the product.
///
/// Bot output is prose, left-aligned in a wide bubble. The user's is a hugging pill on the
/// right. Everything the bot *does*, as opposed to says, appears as a card in the same
/// timeline, so that the record of the work and the record of the conversation are one thing.
struct ConversationView: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    @Environment(UIState.self) private var ui

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Colour.line)
            timeline
            if let id = store.selection {
                ActivityInspector(conversationID: id)
            }
            Composer(conversationID: store.selection ?? UUID(),
                     draft: $draft,
                     focused: $composerFocused)
        }
        .background(DS.Colour.ground)
        // Focus has to wait for the window to become key. Setting @FocusState directly in
        // onAppear runs before that happens and is silently dropped, which leaves the app
        // looking usable while typing does nothing.
        .task(id: store.selection) {
            try? await Task.sleep(for: .milliseconds(120))
            composerFocused = true
        }
    }

    private var conversation: Conversation? { store.conversation(store.selection) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            if let c = conversation {
                Circle()
                    .fill(store.bot(c.participants.first)?.tint ?? DS.Colour.inkTertiary)
                    .frame(width: 18, height: 18)
                Text(c.title ?? store.bot(c.participants.first)?.name ?? "Untitled")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.Colour.ink)
            }
            Spacer()

            Button {
                ui.openBotSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.inkSecondary)
            }
            .buttonStyle(.plain)
            .help("Bot settings")

            Button {
                ui.showPanel.toggle()
            } label: {
                Image(systemName: ui.showPanel ? "chevron.right.2" : "chevron.left.2")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.inkSecondary)
            }
            .buttonStyle(.plain)
            .help(ui.showPanel ? "Hide panel" : "Show panel")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .padding(.top, 8)
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let c = conversation {
                        if c.messages.isEmpty {
                            EmptyConversation(bot: store.bot(c.participants.first))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        }
                        ForEach(c.messages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation?.messages.count ?? 0) {
                guard let last = conversation?.messages.last else { return }
                withAnimation(DS.Motion.instant) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Composer

}

/// What a bot with no history says for itself. An empty list teaches nobody what the app is
/// for; the persona does, because it is the thing the user is about to edit anyway.
private struct EmptyConversation: View {
    let bot: Bot?

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(bot?.tint ?? DS.Colour.inkTertiary)
                .frame(width: 44, height: 44)
            Text(bot?.name ?? "Bot")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colour.ink)
            if let persona = bot?.persona, !persona.isEmpty {
                Text(persona)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Text("Give this bot a description in Settings, then tell it what to do.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.inkTertiary)
            }
        }
    }
}
