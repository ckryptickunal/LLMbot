import AppKit
import BotHarnessCore
import SwiftUI
import UniformTypeIdentifiers

/// The composer.
///
/// This control had three separate dead ends in its first version and together they made the
/// whole app inert: a vertical-axis `TextField` swallows Return so `.onSubmit` never fired,
/// there was no send button to fall back on, and nothing ever took focus. You could type and
/// there was no way to send.
///
/// Now: Return sends, Shift-Return makes a newline, the send button appears when there is
/// something to send, and the field takes focus when a conversation opens.
struct Composer: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner

    let conversationID: UUID
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    @State private var dropping = false

    var body: some View {
        VStack(spacing: DS.Space.md) {
            // The mascot stands on the composer, which is where Kunal asked for it twice —
            // the same place Claude Code puts it.
            //
            // It belongs here rather than in the empty-conversation block: there it was
            // orphaned in the middle of the column with nothing beneath it, which read as a
            // drawing hanging in space rather than a character standing on something. The
            // floor of its stage is the bottom of this view, so at rest its feet are one
            // `md` above the field, and it walks the width of the field it is standing on.
            //
            // It also carries the run's state, which is the reason it earns permanent space:
            // the field you are typing into is the thing you are already looking at, so it is
            // where "working", "needs you" and "that failed" cost nothing to notice.
            MascotView(mascotState)
            if let blocker { preflight(blocker) }
            field
            controls
        }
        .padding(.bottom, DS.Space.lg)
    }

    /// Why this bot cannot answer yet, if it cannot.
    ///
    /// Without this the first run of the app is: type a message, wait, get a failure bubble.
    /// The only warning was a ten-point triangle inside a chip. Saying it before the send makes
    /// the first minute a setup step instead of an error.
    private var blocker: String? {
        guard bot != nil else { return nil }
        guard !CredentialStore.has("gemini") else { return nil }
        return "This bot answers with Gemini, and there is no key saved yet."
    }

    private func preflight(_ message: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "key.horizontal")
                .font(DS.Text.glyphSmall)
                .foregroundStyle(DS.Status.running.mark)
                .accessibilityHidden(true)
            Text(message)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.md)
            SettingsLink { Text("Add a key").font(DS.Text.caption.weight(.medium)) }
                .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityElement(children: .combine)
    }

    /// True while an input method is composing in the focused editor.
    ///
    /// `hasMarkedText()` is exactly the state where the characters on screen are a candidate
    /// rather than committed text. A failed cast means no editor is focused, which is not a
    /// composition, so the fallback is the ordinary path.
    private var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    // MARK: Field

    private var field: some View {
        HStack(alignment: .bottom, spacing: DS.Space.lg) {
            IconButton("plus", help: "Attach a file",
                       accessibilityLabel: "Attach a file", action: attach)

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Text.body)
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1...10)
                // The field is the one thing in the row allowed to take the slack, and it has
                // a floor so a long attachment path cannot squeeze it to nothing.
                .frame(minWidth: DS.Size.fieldMin, maxWidth: .infinity)
                .focused($focused)
                .accessibilityLabel(placeholder)
                // A vertical-axis field consumes Return itself, so the key has to be caught
                // before it reaches the editor. Shift-Return falls through and inserts a
                // newline, which is what people expect from a chat box.
                //
                // The composition check is not optional. An input method — Japanese, Chinese,
                // Korean, and every other one that composes — uses Return to *confirm* the
                // candidate it is showing. Intercepting that sends a half-finished word and
                // loses the rest, and the user has no way to tell what happened. While there
                // is marked text the key belongs to the input method, not to us.
                .onKeyPress(.return, phases: .down) { key in
                    if key.modifiers.contains(.shift) { return .ignored }
                    if isComposing { return .ignored }
                    send()
                    return .handled
                }
                // Redundant on purpose: if the field ever does emit a submit, losing the
                // message because the other path missed it would be unforgivable. Clearing
                // the draft synchronously prevents a double send.
                .onSubmit(send)

            if runner.isRunning(conversationID) {
                stopButton
            } else {
                sendButton
            }
        }
        .dsInset(DS.Inset.composer)
        // Hugs its content. A maxHeight here does not cap growth, it *claims* the space:
        // the VStack offers the composer everything left over and a maxHeight accepts it, so
        // an empty field rendered as a 220-point pill. Growth is already bounded by the
        // field's own line limit.
        .frame(minHeight: DS.Size.composerMin)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.pill))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.pill)
                .stroke(focused ? DS.Surface.borderStrong : .clear, lineWidth: DS.Size.hairline)
        )
        .dsAnimation(DS.Motion.instant, value: focused)
        // Dropping a file on the composer is how a Mac user attaches one. Before this the only
        // path was a button that pasted absolute paths as text, and dragging anything onto the
        // window did nothing at all — in an app whose whole subject is files.
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            attach(providers)
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: DS.Radius.pill)
                    .stroke(DS.Accent.live, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
        }
        .dsAnimation(DS.Motion.instant, value: dropping)
    }

    private var placeholder: String {
        guard let name = bot?.name else { return "Message a bot" }
        if runner.isRunning(conversationID) { return "\(name) is working — Stop to interrupt" }
        return "Message \(name)"
    }

    private var bot: Bot? { store.bot(store.conversation(conversationID)?.participants.first) }

    /// What the mascot is doing, taken from what the runner is doing.
    ///
    /// Ordered by what the user most needs to see: being blocked on you beats being busy, and
    /// being busy beats how the last run ended.
    private var mascotState: MascotState {
        if runner.awaiting.values.contains(conversationID) { return .waiting }
        if runner.isRunning(conversationID) { return .working }
        switch runner.live[conversationID]?.last?.kind {
        case .failed:   return .stumped
        case .finished: return .pleased
        default:        break
        }
        guard let conversation = store.conversation(conversationID) else { return .asleep }
        // Nothing has ever happened here. Asleep is the honest state, and it is the one moment
        // the walk would be claiming activity that does not exist.
        return conversation.messages.isEmpty ? .asleep : .walking
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runner.canSend(in: conversationID)
    }

    // MARK: Buttons

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(DS.Text.glyphBold)
                .foregroundStyle(canSend ? Color.white : DS.Ink.quaternary)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .background(canSend ? DS.Accent.live : DS.Tint.t3, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!canSend)
        .dsAnimation(DS.Motion.instant, value: canSend)
        .help("Send (Return)")
        .accessibilityLabel("Send message")
    }

    private var stopButton: some View {
        Button { runner.stop(conversationID) } label: {
            RoundedRectangle(cornerRadius: DS.Radius.xs)
                .fill(Color.white)
                .frame(width: DS.Space.md, height: DS.Space.md)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .background(DS.Accent.live, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Stop this run")
        .accessibilityLabel("Stop this run")
    }

    // MARK: Controls
    //
    // Two chips, not fifteen modes: which brain answers, and how much it may decide alone.

    private var controls: some View {
        HStack(spacing: DS.Space.md) {
            if let bot {
                BrainChip(bot: bot)
                AutonomyChip(bot: bot)
            }
            Spacer()
        }
        .padding(.horizontal, DS.Space.xs)
    }

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // The draft is only cleared once the runner has actually accepted it. Clearing first
        // and then discovering the conversation was gone destroyed the message with nothing
        // to show for it.
        guard !text.isEmpty, runner.canSend(in: conversationID) else { return }
        runner.send(text, in: conversationID)
        draft = ""
    }

    /// Add dropped files to the draft, one path per line.
    private func attach(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    append(paths: [url.path])
                }
            }
        }
    }

    private func append(paths: [String]) {
        guard !paths.isEmpty else { return }
        draft += (draft.isEmpty ? "" : "\n") + paths.joined(separator: "\n")
        focused = true
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        append(paths: panel.urls.map(\.path))
    }
}

// MARK: - Chips

/// Which model answers for this bot. Changed here rather than buried in settings, because it
/// is a per-message decision as often as a per-bot one.
struct BrainChip: View {
    @Environment(Store.self) private var store
    let bot: Bot

    var body: some View {
        Menu {
            Section("Gemini") {
                option(.gemini(model: GeminiAdapter.defaultModel), "Gemini 3.7 Flash",
                       "Best for using the computer")
                option(.gemini(model: GeminiAdapter.cheapModel), "Gemini 3.5 Flash-Lite",
                       "Faster and cheaper")
            }
            Section("Not wired up yet") {
                option(.claudeCode, "Claude Code", "Subscription, no key — adapter not written")
                option(.anthropic(model: "claude-opus-5"), "Claude Opus 5", "Adapter not written")
                option(.openAI(model: "gpt-5"), "GPT-5", "Adapter not written")
            }
            Divider()
            Button("Set up keys…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } label: {
            Chip(label, systemImage: warns ? "exclamationmark.triangle.fill" : "brain",
                 tint: warns ? DS.Status.running.mark : DS.Ink.secondary,
                 showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
    }

    private var fallingBack: Bool { BotRunner.isFallingBack(bot) }
    private var hasKey: Bool { CredentialStore.has("gemini") }
    private var warns: Bool { fallingBack || !hasKey }

    /// Says what will actually answer, not what is selected. A control that reports a state
    /// the system is not in is worse than one that admits the gap.
    private var label: String {
        fallingBack ? "\(bot.brain.shortName) → Gemini" : bot.brain.shortName
    }

    private var helpText: String {
        if fallingBack { return "No adapter for this model yet — Gemini answers instead" }
        return hasKey ? "Model" : "This model has no key yet"
    }

    private func option(_ brain: BrainSpec, _ title: String, _ detail: String) -> some View {
        Button {
            var updated = bot
            updated.brain = brain
            store.update(updated)
        } label: {
            if bot.brain == brain {
                Label("\(title) — \(detail)", systemImage: "checkmark")
            } else {
                Text("\(title) — \(detail)")
            }
        }
    }
}

/// How much the bot may decide for itself. Three names, not six rungs — the ladder underneath
/// keeps its full resolution, but nobody should have to think in those terms to send a message.
struct AutonomyChip: View {
    @Environment(Store.self) private var store
    let bot: Bot

    var body: some View {
        Menu {
            mode(.confirmBeforeChange, "Ask", "Reads anything. Asks before changing anything.")
            mode(.autonomousWorkspace, "Work", "Works in its folder. Asks before anything consequential.")
            mode(.autonomousOperational, "Autopilot", "Acts across what you authorised. Asks rarely.")
        } label: {
            Chip(label, systemImage: icon, showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How much this bot decides on its own")
    }

    private var label: String {
        switch bot.defaultAutonomy {
        case .autonomousOperational, .delegatedOperator: return "Autopilot"
        case .autonomousWorkspace:                        return "Work"
        default:                                          return "Ask"
        }
    }

    private var icon: String {
        switch bot.defaultAutonomy {
        case .autonomousOperational, .delegatedOperator: return "bolt.fill"
        case .autonomousWorkspace:                        return "play.fill"
        default:                                          return "hand.raised"
        }
    }

    private func mode(_ level: Autonomy, _ title: String, _ detail: String) -> some View {
        Button {
            var updated = bot
            updated.defaultAutonomy = level
            store.update(updated)
        } label: {
            if bot.defaultAutonomy == level {
                Label("\(title) — \(detail)", systemImage: "checkmark")
            } else {
                Text("\(title) — \(detail)")
            }
        }
    }
}
