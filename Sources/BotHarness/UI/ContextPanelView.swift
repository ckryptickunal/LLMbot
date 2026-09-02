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
                            BotSettingsPane(bot: bot, conversation: currentConversation?.id)
                                .id(bot.id)
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

    /// Left-aligned and the same height as the conversation's own header.
    ///
    /// It was centred, and 28 points tall with 8 of top padding — 36 against the 52 of the header
    /// on the other side of the divider. So the two titles sat at different heights across a
    /// vertical line that invites exactly that comparison, and the panel's title was the only
    /// centred one in an app whose every other header is left-aligned. Centring also needed an
    /// invisible spacer to balance the back button, which is a thing to keep in step forever.
    private var header: some View {
        HStack(spacing: DS.Space.md) {
            if ui.panel == .settings {
                IconButton("chevron.left", filled: false, help: "Back to the screen",
                           accessibilityLabel: "Back to the screen") {
                    withAnimation(DS.Motion.instant) { ui.panel = .screen }
                }
            }
            Text(ui.panel == .settings ? "Settings" : "Screen")
                .font(DS.Text.callout.weight(.semibold))
                .foregroundStyle(DS.Ink.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.lg)
        .frame(height: DS.Size.titlebar)
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
                        // A bot working inside its own Linux machine has no screen at all, so
                        // "appears the first time this bot looks at a screen" is a promise that
                        // can never be kept. Say what is actually true of that machine instead.
                        EmptyState(
                            systemImage: bot?.environment == .container ? "cube" : "display",
                            title: bot?.environment == .container ? "No screen" : "No screen yet",
                            message: bot == nil
                                ? "Pick a bot to see what it has been looking at."
                                : bot?.environment == .container
                                    ? "This bot works inside its own Linux machine, which has no "
                                    + "display. Its work shows up in the conversation and in its "
                                    + "folder."
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
    /// Attachments belong to the conversation, not the bot, so this pane needs to know which
    /// one it is looking at to show them.
    let conversation: UUID?

    @State private var confirmingDelete = false
    @State private var containerReady: ContainerRuntime.Availability = .notInstalled

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

            attached

            readOnly("Brain", live.brain.displayName, nil)
            computer

            toggle("Notifications",
                   "Tell me when this bot finishes or needs me, even when the app is behind "
                 + "something else",
                   binding(\.notifies))

            standingPermissions

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

    /// What this bot has been allowed to do without asking again.
    ///
    /// Answering "Always, for this bot" on an approval card writes one of these. Until this
    /// existed there was no way to see that it had happened, and no way to take it back — so a
    /// single mis-click granted something for the life of the install, invisibly. Global rules
    /// have had a list in Settings for a while; these did not, which made the per-bot half of the
    /// permission model the half you could only ever loosen.
    @ViewBuilder private var standingPermissions: some View {
        let rules = live.rules
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionLabel("Allowed without asking")
            if rules.isEmpty {
                Text("Nothing yet. Choosing \"Always, for this bot\" on an approval adds it here, "
                   + "and you can take it back from here too.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rules) { rule in
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        Image(systemName: rule.behaviour == .neverAllow ? "nosign" : "checkmark.circle.fill")
                            .font(DS.Text.glyphSmall)
                            .foregroundStyle(rule.behaviour == .neverAllow
                                             ? DS.Status.failed.mark : DS.Status.done.mark)
                            .accessibilityHidden(true)
                        Text(rule.whenBotWantsTo)
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.sm)
                        IconButton("xmark", help: "Remove this permission") {
                            store.deleteRule(rule.id, from: live.id)
                        }
                    }
                }
            }
        }
    }

    /// Stop the work before removing the thing it was working on.
    private func delete() {
        let botID = live.id
        let orphaned = store.deleteBot(botID)
        runner.discard(orphaned, bots: [botID])
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

    // MARK: Computer

    /// Which machine this bot works on.
    ///
    /// Offered even when the container tool is not installed, and honest about it: the option is
    /// visible with the reason it cannot be picked, because hiding it entirely means nobody
    /// discovers the feature exists. Picking it on a Mac without the tool is prevented here
    /// rather than failing later — but a bot that *already* has the setting keeps working
    /// regardless, falling back to this Mac at run time.
    private var computer: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Computer").font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Picker("", selection: environmentBinding) {
                    ForEach(EnvironmentKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("Which computer this bot works on")

                Text(live.environment.explanation)
                    .font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if live.environment == .container, !containerReady.isReady {
                    Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Status.running.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.md)
            .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .task { containerReady = await runner.containerAvailability() }
    }

    private var unavailableReason: String {
        // What the fallback actually is, rather than what it is meant to be. On a machine where
        // the self-test failed there is no sandbox to fall back into, and saying otherwise would
        // be the app claiming a boundary it does not have.
        // `knownWorking`, not `isWorking` — see `Seatbelt.knownWorking`. This is a view body.
        let fallback: String
        switch Seatbelt.knownWorking {
        case true:  fallback = "this bot works on your Mac, sandboxed."
        case false: fallback = "this bot works on your Mac, unsandboxed."
        default:    fallback = "this bot works on your Mac."
        }
        switch containerReady {
        case .notInstalled:
            return "Not set up on this Mac yet — Computers → Its own computer explains the "
                 + "one-time install. Until then \(fallback)"
        case .serviceStopped:
            return "The container service is not running. Computers → Its own computer can "
                 + "start it. Until then \(fallback)"
        case .failing(let detail):
            return "The container tool reported: \(detail). Until that is fixed \(fallback)"
        case .ready:
            return ""
        }
    }

    private var environmentBinding: Binding<EnvironmentKind> {
        Binding(
            get: { live.environment },
            set: { kind in
                var updated = live
                updated.environment = kind
                store.update(updated)
            }
        )
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

    // MARK: Attached files

    /// Files the user handed this conversation, and the only place they can be taken back.
    ///
    /// Sits directly under the workspace because it answers the same question — what may this
    /// bot read — and because it is the only part of that answer the user changes by accident.
    /// Dragging a file in is a permission grant made with a gesture that does not feel like
    /// one, so it has to be visible somewhere without being hunted for, exactly as
    /// `standingPermissions` argues for the rules an approval card writes.
    @ViewBuilder private var attached: some View {
        let files = conversation.flatMap { store.conversation($0) }?.attachments ?? []
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Files you attached")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(files) { file in
                        HStack(alignment: .top, spacing: DS.Space.md) {
                            Image(systemName: file.isDirectory ? "folder" : "doc")
                                .font(DS.Text.glyphSmall)
                                .foregroundStyle(DS.Ink.secondary)
                                // `folder` is a narrower glyph than `doc`, so without a fixed
                                // box the two rows start their names at different x positions
                                // and the list reads as ragged.
                                .frame(width: DS.Size.glyphSmall, alignment: .center)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text(file.name)
                                    .font(DS.Text.caption)
                                    .foregroundStyle(DS.Ink.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.path)
                                    .font(DS.Text.micro)
                                    .foregroundStyle(DS.Ink.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: DS.Space.sm)
                            IconButton("xmark", help: "Stop this bot reading \(file.name)") {
                                if let conversation { store.detach(file.path, from: conversation) }
                            }
                        }
                    }
                    Text(files.contains(where: \.isDirectory)
                         ? "This bot may read these. A folder includes everything inside it. It cannot write to any of them."
                         : "This bot may read these, and cannot write to them.")
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.md)
                .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
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
