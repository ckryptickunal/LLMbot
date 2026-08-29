import BotHarnessCore
import SwiftUI

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

    var body: some View {
        VStack(spacing: DS.Space.md) {
            field
            controls
        }
        .padding(.horizontal, DS.Space.xxl - 2)
        .padding(.bottom, DS.Space.lg + 2)
    }

    // MARK: Field

    private var field: some View {
        HStack(alignment: .bottom, spacing: DS.Space.lg - 2) {
            IconButton("plus", help: "Attach a file", action: attach)

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Text.body)
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1...10)
                .focused($focused)
                // A vertical-axis field consumes Return itself, so the key has to be caught
                // before it reaches the editor. Shift-Return falls through and inserts a
                // newline, which is what people expect from a chat box.
                .onKeyPress(.return, phases: .down) { key in
                    if key.modifiers.contains(.shift) { return .ignored }
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
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md + 1)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.pill))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.pill)
                .stroke(focused ? DS.Surface.borderStrong : .clear, lineWidth: DS.Size.hairline)
        )
        .dsAnimation(DS.Motion.instant, value: focused)
    }

    private var placeholder: String {
        guard let name = bot?.name else { return "Ask anything" }
        return "Message \(name)"
    }

    private var bot: Bot? { store.bot(store.conversation(conversationID)?.participants.first) }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    }

    private var stopButton: some View {
        Button { runner.stop(conversationID) } label: {
            RoundedRectangle(cornerRadius: DS.Radius.xs - 1)
                .fill(Color.white)
                .frame(width: DS.Space.md + 1, height: DS.Space.md + 1)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .background(DS.Accent.live, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Stop")
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
        guard !text.isEmpty else { return }
        draft = ""
        runner.send(text, in: conversationID)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        draft += (draft.isEmpty ? "" : "\n") + panel.urls.map(\.path).joined(separator: "\n")
        focused = true
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
                 tint: warns ? DS.Status.running.mark : DS.Ink.tertiary,
                 showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
    }

    private var fallingBack: Bool { BotRunner.isFallingBack(bot) }
    private var hasKey: Bool { Keychain.has("gemini") }
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
