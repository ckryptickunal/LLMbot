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
                case .screen:
                    ScreenPane(bot: currentBot, conversation: currentConversation)
                case .settings:
                    if let bot = currentBot {
                        VStack(alignment: .leading, spacing: 0) {
                            // In a channel this pane edits one member — the one that answers.
                            // Say whose settings these are, because otherwise opening the gear
                            // from a room of four bots silently shows one of them, and looks
                            // like the panel is showing the wrong thing.
                            if currentConversation?.isChannel == true {
                                Text("These are \(bot.name)'s settings — the bot that answers "
                                   + "in this channel.")
                                    .font(DS.Text.caption)
                                    .foregroundStyle(DS.Ink.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DS.Inset.pane.leading)
                                    .padding(.top, DS.Space.lg)
                            }
                            // Identity, so every piece of view state inside belongs to *this*
                            // bot. Without it the pane kept editing whichever bot was selected
                            // when the user first typed, and wrote those keystrokes into that
                            // bot's record while showing a different one.
                            BotSettingsPane(bot: bot).id(bot.id)
                        }
                    } else {
                        EmptyState(systemImage: "person.crop.circle",
                                   title: "No bot selected",
                                   message: "Pick one from the list to see its settings.")
                    }
                }
            }
        }
        // No background — see RootView. The inspector inherits the system material.
    }

    private var currentConversation: Conversation? { store.conversation(store.selection) }
    private var currentBot: Bot? { store.bot(currentConversation?.participants.first) }

    private var header: some View {
        HStack {
            if ui.panel == .settings {
                IconButton("chevron.left", filled: false, help: "Back to the screen",
                           accessibilityLabel: "Back to the screen") {
                    withAnimation(DS.Motion.instant) { ui.panel = .screen }
                }
            }
            Spacer()
            Text(ui.panel == .settings ? "Settings" : "Screen")
                .font(DS.Text.callout.weight(.semibold))
                .foregroundStyle(DS.Ink.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            // Balances the leading control so the title stays optically centred.
            if ui.panel == .settings {
                Color.clear.frame(width: DS.Size.hit, height: DS.Size.hit)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: DS.Size.rosterRow)
        .padding(.top, DS.Space.md)
    }
}

// MARK: - Screen

/// The bot's screen: the last frame it actually acted on.
///
/// When the environment is this Mac, a live mirror is recursive — the app is on the screen it
/// would be capturing. The honest answer, and the one shipped tools use, is the most recent
/// frame the agent acted on: it is what the bot saw when it decided, which is the useful thing,
/// and it costs no capture stream.
///
/// This pane used to be a hardcoded placeholder wired to nothing, so the inspector opened every
/// launch on a promise the code could not keep.
private struct ScreenPane: View {
    let bot: Bot?
    let conversation: Conversation?

    @State private var grants = ComputerExecutor.permissions

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            // The two grants the whole "your bots use your Mac" proposition depends on, said
            // where the user runs into their absence rather than only in a tab of a sheet.
            // This pane is that place by construction: without Screen Recording it can never
            // fill, so an empty state here was the app quietly failing at its one job.
            if let missing {
                StandingNotice(
                    systemImage: "lock.shield",
                    title: missing.title,
                    detail: missing.detail,
                    actionTitle: "Open System Settings",
                    action: { grant(missing.pane) }
                )
            }

            if let latest {
                ScreenshotCard(shot: latest)
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(DS.Surface.ground)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay {
                        EmptyState(
                            systemImage: "display",
                            title: "No screen yet",
                            message: bot == nil
                                ? "Pick a bot to see what it has been looking at."
                                : "Appears the first time this bot looks at a screen."
                        )
                    }
            }

            if let bot {
                Text("\(bot.name)'s screen · \(bot.environment.displayName)")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
            }
        }
        .padding(DS.Space.lg)
        .refreshingOnActivation { grants = ComputerExecutor.permissions }
    }

    /// The most recent frame in this conversation, if there is one.
    private var latest: Screenshot? {
        guard let conversation else { return nil }
        for message in conversation.messages.reversed() {
            if case .screenshot(let shot) = message.body { return shot }
        }
        return nil
    }

    /// What macOS has not granted yet, phrased for the person who has to grant it.
    ///
    /// One notice at a time, screen first, because that is the order the work needs them in:
    /// a bot that cannot see the screen has nothing to click at. Two stacked warnings in a
    /// 260-point column is also how a panel stops being read at all.
    private var missing: (title: String, detail: String, pane: String)? {
        // A container bot never touches this Mac, so warning about grants it does not use
        // would be noise — and worse, it would teach people to dismiss the warning that does
        // matter.
        guard let bot, bot.environment == .thisMac else { return nil }

        if !grants.screenRecording {
            return ("\(bot.name) cannot see this screen",
                    "macOS has not granted Screen Recording. Until it does, this bot cannot "
                  + "look at anything, so nothing will appear here.",
                    "Privacy_ScreenCapture")
        }
        if !grants.accessibility {
            return ("\(bot.name) cannot use the keyboard or mouse",
                    "macOS has not granted Accessibility. This bot can see the screen but "
                  + "cannot click or type on it.",
                    "Privacy_Accessibility")
        }
        return nil
    }

    /// Ask, then show them where to say yes.
    ///
    /// Both calls, in this order, because they do different jobs: Screen Recording can be
    /// granted from a system prompt, Accessibility cannot be granted by a prompt at all — the
    /// user has to add the app in System Settings — so opening the pane is the only thing that
    /// works for the second one and is harmless for the first.
    private func grant(_ pane: String) {
        ComputerExecutor.requestAccess()
        ComputerExecutor.openPrivacySettings(pane)
    }
}

// MARK: - Bot settings

/// The bot's identity.
///
/// The fields are Grok Bot's, because they are the right fields — name, label, description as
/// persona, notifications — plus the three they do not have: which brain answers, where its
/// computer is, and **which folder it may change**.
///
/// Every control here reads and writes the live record rather than a local copy. The local copy
/// was the bug: it outlived the selection, so typing in this pane after switching bots wrote
/// into the bot you had left.
private struct BotSettingsPane: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner
    @Environment(UIState.self) private var ui
    let bot: Bot

    @State private var confirmingDelete = false

    /// Always the current record, never a snapshot taken when the view was built.
    private var live: Bot { store.bot(bot.id) ?? bot }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            BotAvatar(bot: live, size: DS.Size.avatarInspector)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Space.md)
                .accessibilityHidden(true)

            field("Name", text: binding(\.name))
            field("Label (optional)", text: binding(\.label),
                  placeholder: "Research, marketing, admin")

            description

            workspace

            readOnly("Brain", live.brain.displayName, nil)
            readOnly("Computer", live.environment.displayName, live.environment.explanation)

            toggle("Notifications",
                   "Tell me when this bot finishes or needs me, even when the app is behind "
                 + "something else",
                   binding(\.notifies))

            Spacer(minLength: DS.Space.lg)

            VStack(spacing: DS.Space.md) {
                SecondaryButton("Share as template", systemImage: "square.and.arrow.up") {
                    exportTemplate(live)
                }
                .frame(maxWidth: .infinity)

                SecondaryButton("Delete bot", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .dsInset(DS.Inset.pane)
        .confirmationDialog("Delete \(live.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the bot and its conversation. The trace of its past runs stays "
               + "on disk. This cannot be undone.")
        }
    }

    /// Stop the work before removing the thing it was working on.
    private func delete() {
        let orphaned = store.deleteBot(live.id)
        runner.discard(orphaned)
        ui.discardDrafts(for: orphaned)
        ui.panel = .screen
    }

    // MARK: Description

    private var description: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("Description")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                if live.personaIsAuto && !live.persona.isEmpty {
                    Text("written by this bot")
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.secondary)
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Tint.t3, in: Capsule())
                        .help("Kept up to date from what you ask it to do. Editing it makes it yours.")
                }
                Spacer()
                if !live.personaIsAuto {
                    Button("Let the bot write it") {
                        var updated = live
                        updated.personaIsAuto = true
                        updated.describedAtTurn = 0
                        store.update(updated)
                    }
                    .buttonStyle(.plain)
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Ink.secondary)
                }
            }
            // Typing here takes ownership: the bot never overwrites the user's words.
            TextEditor(text: Binding(
                get: { live.persona },
                set: { newValue in
                    var updated = live
                    updated.persona = newValue
                    updated.personaIsAuto = false
                    store.update(updated)
                }))
                .font(DS.Text.callout)
                .scrollContentBackground(.hidden)
                .frame(height: DS.Window.personaEditorHeight)
                .padding(DS.Space.md)
                .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .accessibilityLabel("Bot description")
        }
    }

    // MARK: Workspace

    /// Which folder this bot may change.
    ///
    /// This is the single most consequential setting in the app and it was visible nowhere:
    /// the runtime silently defaulted it to the whole Desktop, and the composer's autonomy chip
    /// offered "works in its folder" with no way to learn or choose which folder that was.
    private var workspace: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Folder it may change")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(live.workspace?.path ?? Bot.defaultWorkspace.path)
                    .font(DS.Text.monoSmall)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(live.workspace == nil
                     ? "The default. Anything outside this folder needs your approval."
                     : "Anything outside this folder needs your approval.")
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.md) {
                    SecondaryButton("Choose…", systemImage: "folder") { chooseWorkspace() }
                    if live.workspace != nil {
                        SecondaryButton("Reset") {
                            var updated = live
                            updated.workspace = nil
                            store.update(updated)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.md)
            .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        panel.message = "This bot may change files inside the folder you pick."
        panel.directoryURL = live.workspace ?? Bot.defaultWorkspace
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = live
        updated.workspace = url
        store.update(updated)
    }

    // MARK: Editing

    private func binding<V>(_ path: WritableKeyPath<Bot, V>) -> Binding<V> {
        Binding(
            get: { live[keyPath: path] },
            set: { newValue in
                var updated = live
                updated[keyPath: path] = newValue
                store.update(updated)
            }
        )
    }

    /// Write the bot's shareable parts to a file: name, label, persona, brain, autonomy. Never
    /// its workspace path, its history, or any stored credential.
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
            Text(title).font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.primary)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.md)
                .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .accessibilityLabel(title)
        }
    }

    private func readOnly(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title).font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(value).font(DS.Text.callout).foregroundStyle(DS.Ink.primary)
                if let detail {
                    Text(detail).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.md)
            .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .accessibilityElement(children: .combine)
    }

    private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(title).font(DS.Text.callout).foregroundStyle(DS.Ink.primary)
                Text(detail)
                    .font(DS.Text.micro)
                    .foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(title)
        }
        .padding(DS.Space.lg)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}
