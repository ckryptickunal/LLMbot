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
    @Binding var showContext: Bool
    @Binding var contextPanel: RootView.ContextPanel

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            timeline
            composer
        }
        .background(Theme.ground)
    }

    private var conversation: Conversation? { store.conversation(store.selection) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            if let c = conversation {
                Circle()
                    .fill(store.bot(c.participants.first)?.tint ?? Theme.tertiary)
                    .frame(width: 18, height: 18)
                Text(c.title ?? store.bot(c.participants.first)?.name ?? "Untitled")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.primary)
            }
            Spacer()

            Button {
                contextPanel = .settings
                showContext = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Bot settings")

            Button {
                showContext.toggle()
            } label: {
                Image(systemName: showContext ? "chevron.right.2" : "chevron.left.2")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(showContext ? "Hide panel" : "Show panel")
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
                withAnimation(Motion.routine) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 10) {
            Button {
                // Attachments — not yet implemented.
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.primary)
                .lineLimit(1...8)
                .onSubmit(send)

            Button {
                // Voice input — not yet implemented.
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ground)
                    .frame(width: 26, height: 26)
                    .background(Theme.primary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var placeholder: String {
        guard let c = conversation else { return "Message" }
        let name = c.title ?? store.bot(c.participants.first)?.name ?? "bot"
        return "Message \(name)"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = store.selection else { return }
        draft = ""
        runner.send(text, in: id)
    }
}

/// What a bot with no history says for itself. An empty list teaches nobody what the app is
/// for; the persona does, because it is the thing the user is about to edit anyway.
private struct EmptyConversation: View {
    let bot: Bot?

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(bot?.tint ?? Theme.tertiary)
                .frame(width: 44, height: 44)
            Text(bot?.name ?? "Bot")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            if let persona = bot?.persona, !persona.isEmpty {
                Text(persona)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Text("Give this bot a description in Settings, then tell it what to do.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}
