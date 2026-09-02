import BotHarnessCore
import SwiftUI

/// Making a channel: a name, and the bots who are in the room.
///
/// A channel is the one object in this product that Grok Bot does not have, and until now it
/// was the one object with no way to make it — `Store.createChannel` had no caller anywhere in
/// the interface, so the roster could render channels it was impossible to create.
///
/// **The order the bots are picked in is meaningful, and the sheet says so.** `BotRunner.send`
/// starts a loop for `participants.first`, so the first bot chosen is the one that actually
/// answers. Presenting an unordered set of checkboxes would have hidden that, and presenting a
/// separate "lead" picker would have been worse: `Conversation.leadBot` is stored and nothing
/// reads it yet, so choosing a lead would have looked like a decision and been a no-op.
struct NewChannelSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    /// Ordered, not a `Set`: position one is the bot that speaks.
    @State private var chosen: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Hairline()

            if store.bots.count < 2 {
                notEnoughBots
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        SectionLabel("Who is in the room")
                        ForEach(store.bots) { bot in
                            memberRow(bot)
                        }
                        explanation
                    }
                    .dsInset(DS.Inset.pane)
                }
            }

            Hairline()
            footer
        }
        .frame(width: DS.Window.sheetWidth, height: DS.Window.sheetHeight)
        .background(DS.Surface.paperTint)
    }

    // MARK: Pieces

    private var heading: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("New channel")
                .font(DS.Text.title)
                .foregroundStyle(DS.Ink.primary)
                .accessibilityAddTraits(.isHeader)
            TextField("What is this room about?", text: $title)
                .textFieldStyle(.plain)
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.primary)
                .padding(.horizontal, DS.Space.md)
                .frame(minHeight: DS.Size.controlHeight)
                .dsWell(DS.Radius.sm)
                .onSubmit(create)
                .accessibilityLabel("Channel name")
        }
        .dsInset(DS.Inset.pane)
    }

    /// A channel needs two bots, and the honest response to having one is a way to make
    /// another — not a disabled control with no explanation.
    private var notEnoughBots: some View {
        VStack {
            EmptyState(systemImage: "person.2",
                       title: "A channel needs two bots",
                       message: "There is only one bot so far. Make another, then pick who is "
                              + "in this room.",
                       actionTitle: "New bot",
                       action: { store.createBot(name: "New Bot") })
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func memberRow(_ bot: Bot) -> some View {
        let position = chosen.firstIndex(of: bot.id)
        return Button {
            toggle(bot.id)
        } label: {
            HStack(spacing: DS.Space.lg) {
                BotAvatar(bot: bot, size: DS.Size.avatarRoster)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(bot.name)
                        .font(DS.Text.callout.weight(.medium))
                        .foregroundStyle(DS.Ink.primary)
                    Text(bot.label.isEmpty ? bot.brain.shortName : bot.label)
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.md)
                if position == 0 {
                    Text("answers here")
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.secondary)
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, DS.Space.hair)
                        .dsWellCapsule()
                        .fixedSize()
                }
                Image(systemName: position == nil ? "circle" : "checkmark.circle.fill")
                    .font(DS.Text.glyph)
                    .foregroundStyle(position == nil ? DS.Ink.secondary : DS.Accent.live)
                    .accessibilityHidden(true)
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, minHeight: DS.Size.settingsRow, alignment: .leading)
            .dsWell(DS.Radius.md)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel(for: bot, at: position))
        .accessibilityAddTraits(position == nil ? [] : .isSelected)
    }

    private func accessibilityLabel(for bot: Bot, at position: Int?) -> String {
        guard let position else { return "\(bot.name), not in this channel" }
        return position == 0
            ? "\(bot.name), in this channel, and the bot that answers"
            : "\(bot.name), in this channel"
    }

    /// What a channel does today, stated plainly.
    ///
    /// The product intends bots in a room to address each other; the runtime starts one loop
    /// for one bot. Saying so here costs a sentence and buys the thing this whole pass is
    /// about — an interface nobody has to test to find out what it really does.
    private var explanation: some View {
        Text("Everyone here shares one thread, and you can see all of it in one place. Today "
           + "the first bot you pick is the one that answers; the others are in the room and "
           + "do not speak on their own yet.")
            .font(DS.Text.micro)
            .foregroundStyle(DS.Ink.secondary)
            .lineSpacing(DS.Text.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DS.Space.md)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.md) {
            Text(countLabel)
                .font(DS.Text.micro)
                .foregroundStyle(DS.Ink.secondary)
            Spacer()
            SecondaryButton("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            PrimaryButton("Create channel", isEnabled: canCreate, action: create)
        }
        .dsInset(DS.Inset.pane)
    }

    private var countLabel: String {
        switch chosen.count {
        case 0:  return "Pick at least two bots"
        case 1:  return "One more bot to go"
        default: return "\(chosen.count) bots"
        }
    }

    // MARK: Actions

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool { !trimmedTitle.isEmpty && chosen.count >= 2 }

    private func toggle(_ id: UUID) {
        if let index = chosen.firstIndex(of: id) {
            chosen.remove(at: index)
        } else {
            chosen.append(id)
        }
    }

    private func create() {
        guard canCreate else { return }
        // The lead is recorded as the bot that will actually answer rather than left nil or
        // offered as a choice, so the state file says the same thing the app does.
        store.createChannel(title: trimmedTitle, participants: chosen, lead: chosen.first)
        dismiss()
    }
}
