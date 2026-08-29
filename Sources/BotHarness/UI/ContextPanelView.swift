import BotHarnessCore
import SwiftUI

/// The right-hand panel: the bot's screen, or the bot itself.
///
/// Two modes rather than two panels, because they answer the same question at different zoom
/// levels — "what is this bot doing" and "what is this bot".
struct ContextPanelView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                switch ui.panel {
                case .screen:   ScreenPane(bot: currentBot)
                case .settings: BotSettingsPane(bot: currentBot)
                }
            }
        }
        .background(DS.Colour.panel)
    }

    private var currentBot: Bot? {
        store.bot(store.conversation(store.selection)?.participants.first)
    }

    private var header: some View {
        HStack {
            if ui.panel == .settings {
                IconButton("chevron.left", filled: false, help: "Back to the screen") {
                    withAnimation(DS.Motion.instant) { ui.panel = .screen }
                }
            }
            Spacer()
            Text(ui.panel == .settings ? "Settings" : "Screen")
                .font(DS.Text.secondary.weight(.semibold))
                .foregroundStyle(DS.Colour.ink)
            Spacer()
            // Balances the leading control so the title stays optically centred.
            if ui.panel == .settings {
                Color.clear.frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
            }
        }
        .padding(.horizontal, DS.Space.lg + 2)
        .frame(height: DS.Size.rowHeight)
        .padding(.top, DS.Space.md)
    }
}

// MARK: - Screen

/// The bot's screen.
///
/// When the environment is this Mac, a live mirror is recursive — the app is on the screen it
/// would be capturing. The honest answer, and the one shipped tools use, is the most recent
/// frame the agent actually acted on: it is what the bot saw when it decided, which is the
/// useful thing, and it costs no capture stream.
private struct ScreenPane: View {
    let bot: Bot?

    var body: some View {
        VStack(spacing: DS.Space.lg - 2) {
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(DS.Colour.ground)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    EmptyState(
                        systemImage: "display",
                        title: "No screen yet",
                        message: "Appears when this bot uses a computer."
                    )
                }

            if let bot {
                Text("\(bot.name)'s screen · \(bot.environment.displayName)")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Colour.inkTertiary)
            }
        }
        .padding(DS.Space.lg + 2)
    }
}

// MARK: - Bot settings

/// The bot's identity.
///
/// The fields are Grok Bot's, because they are the right fields — name, label, description as
/// persona, notifications — plus the two they do not have: which brain answers, and where its
/// computer is.
private struct BotSettingsPane: View {
    @Environment(Store.self) private var store
    let bot: Bot?

    @State private var draft: Bot?

    var body: some View {
        if let working = draft ?? bot {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Circle()
                    .fill(working.tint)
                    .frame(width: DS.Size.avatarLarge, height: DS.Size.avatarLarge)
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Space.md)

                field("Name", text: binding(\.name, on: working))
                field("Label (optional)", text: binding(\.label, on: working),
                      placeholder: "Research, marketing, admin")

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    Text("Description")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Colour.inkSecondary)
                    TextEditor(text: binding(\.persona, on: working))
                        .font(DS.Text.secondary)
                        .scrollContentBackground(.hidden)
                        .frame(height: 130)
                        .padding(DS.Space.sm + 1)
                        .background(DS.Colour.fill, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }

                readOnly("Brain", working.brain.displayName, nil)
                readOnly("Computer", working.environment.displayName, working.environment.explanation)

                toggle("Notifications",
                       "Get notified when this bot finishes or needs input",
                       binding(\.notifies, on: working))

                Spacer(minLength: DS.Space.lg)

                SecondaryButton("Share as template", systemImage: "square.and.arrow.up") {
                    exportTemplate(working)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(DS.Space.lg + 2)
        } else {
            EmptyState(systemImage: "person.crop.circle",
                       title: "No bot selected",
                       message: "Pick one from the list to see its settings.")
        }
    }

    // MARK: Editing

    private func binding<V>(_ path: WritableKeyPath<Bot, V>, on working: Bot) -> Binding<V> {
        Binding(
            get: { working[keyPath: path] },
            set: { newValue in
                var updated = working
                updated[keyPath: path] = newValue
                draft = updated
                store.update(updated)
            }
        )
    }

    /// Write the bot's shareable parts to a file: name, label, persona, brain, autonomy. Never
    /// its workspace path, its history, or anything from the Keychain.
    private func exportTemplate(_ bot: Bot) {
        let template: [String: Any] = [
            "name": bot.name,
            "label": bot.label,
            "description": bot.persona,
            "brain": bot.brain.displayName,
            "autonomy": bot.defaultAutonomy.displayName,
            "environment": bot.environment.rawValue,
        ]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = bot.name
            .replacingOccurrences(of: " ", with: "-").lowercased() + ".bot.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONSerialization.data(withJSONObject: template,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url)
    }

    // MARK: Pieces

    private func field(_ title: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title).font(DS.Text.caption).foregroundStyle(DS.Colour.inkSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(DS.Text.secondary)
                .foregroundStyle(DS.Colour.ink)
                .padding(.horizontal, DS.Space.md + 1)
                .padding(.vertical, DS.Space.sm + 1)
                .background(DS.Colour.fill, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }

    private func readOnly(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title).font(DS.Text.caption).foregroundStyle(DS.Colour.inkSecondary)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(value).font(DS.Text.secondary).foregroundStyle(DS.Colour.ink)
                if let detail {
                    Text(detail).font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.md + 1)
            .padding(.vertical, DS.Space.sm + 1)
            .background(DS.Colour.fill, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg - 2) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(title).font(DS.Text.secondary).foregroundStyle(DS.Colour.ink)
                Text(detail)
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Colour.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(DS.Space.lg - 1)
        .background(DS.Colour.fill, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}
