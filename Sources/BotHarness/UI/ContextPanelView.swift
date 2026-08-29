import BotHarnessCore
import SwiftUI

/// The right-hand panel: either the bot's screen or the bot's settings.
///
/// Two modes rather than two panels, because they answer the same question at different
/// zoom levels — "what is this bot doing" and "what is this bot".
struct ContextPanelView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Colour.line)
            ScrollView {
                switch ui.panel {
                case .screen:   ScreenPane(bot: currentBot)
                case .settings: SettingsPane(bot: currentBot)
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
                Button {
                    withAnimation(DS.Motion.instant) { ui.panel = .screen }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colour.inkSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(ui.panel == .settings ? "Settings" : "Screen")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.Colour.ink)
            Spacer()
            // Balances the leading chevron so the title stays optically centred.
            if ui.panel == .settings { Color.clear.frame(width: 12) }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .padding(.top, 8)
    }
}

/// The bot's screen.
///
/// When the environment is this Mac, showing a live view is recursive — the app is on the
/// screen it is capturing. The honest answer, and the one shipped tools use, is to show the
/// most recent frame the agent actually acted on rather than a live mirror: it is what the
/// bot saw when it decided, which is the useful thing, and it does not cost a capture stream.
private struct ScreenPane: View {
    let bot: Bot?

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.45))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "display")
                            .font(.system(size: 20))
                            .foregroundStyle(DS.Colour.inkTertiary)
                        Text("No screen yet")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colour.inkSecondary)
                        Text("Appears when this bot uses a computer.")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colour.inkTertiary)
                    }
                }

            if let bot {
                Text("\(bot.name)'s screen · \(bot.environment.displayName)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colour.inkTertiary)
            }
        }
        .padding(14)
    }
}

/// Bot settings. The fields are Grok Bot's, because they are the right fields: identity,
/// what it is for, whether it may interrupt you — and then the things they do not have,
/// which are the brain and the environment.
private struct SettingsPane: View {
    @Environment(Store.self) private var store
    let bot: Bot?

    @State private var draft: Bot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let working = draft ?? bot {
                Circle()
                    .fill(working.tint)
                    .frame(width: 56, height: 56)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                field("Name", text: Binding(
                    get: { working.name },
                    set: { v in mutate { $0.name = v; $0.nameIsAuto = false } }))

                field("Label (optional)", text: Binding(
                    get: { working.label },
                    set: { v in mutate { $0.label = v } }),
                    placeholder: "Research, marketing, admin")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.Colour.inkSecondary)
                    TextEditor(text: Binding(
                        get: { working.persona },
                        set: { v in mutate { $0.persona = v } }))
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .frame(height: 130)
                        .padding(7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }

                labelled("Brain") {
                    Text(working.brain.displayName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.Colour.ink)
                }

                labelled("Computer") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(working.environment.displayName)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DS.Colour.ink)
                        Text(working.environment.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colour.inkTertiary)
                    }
                }

                toggleRow(
                    "Notifications",
                    detail: "Get notified when this bot finishes or needs input",
                    isOn: Binding(
                        get: { working.notifies },
                        set: { v in mutate { $0.notifies = v } })
                )

                Spacer(minLength: 12)

                Button { exportTemplate(working) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("Share as template")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            } else {
                Text("No bot selected")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.inkTertiary)
            }
        }
        .padding(14)
    }

    /// Write the bot's shareable parts to a file: name, label, persona, brain, autonomy.
    /// Never its workspace path, its history, or anything from the Keychain.
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
        panel.nameFieldStringValue = bot.name.replacingOccurrences(of: " ", with: "-").lowercased() + ".bot.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONSerialization.data(withJSONObject: template,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url)
    }

    private func mutate(_ change: (inout Bot) -> Void) {
        guard var b = draft ?? bot else { return }
        change(&b)
        draft = b
        store.update(b)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colour.inkSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colour.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colour.inkSecondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.Colour.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colour.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(11)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
