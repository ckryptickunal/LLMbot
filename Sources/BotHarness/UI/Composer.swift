import SwiftUI
import BotHarnessCore

/// The composer.
///
/// This control had three separate dead ends in its first version, and together they made the
/// whole app inert: a `TextField` with `axis: .vertical` swallows Return as a newline so
/// `.onSubmit` never fires, there was no send button to fall back on, and nothing ever took
/// focus. You could type and there was no way to send.
///
/// Now: Return sends, Shift-Return makes a newline, the send button appears when there is
/// something to send, and the field takes focus when the conversation opens.
struct Composer: View {
    @Environment(Store.self) private var store
    @Environment(BotRunner.self) private var runner

    let conversationID: UUID
    @Binding var draft: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                attachButton

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DS.Colour.ink)
                    .lineLimit(1...10)
                    .focused($focused)
                    // A vertical-axis field consumes Return itself, so the key has to be
                    // caught before it reaches the editor. Shift-Return falls through and
                    // inserts a newline, which is what people expect from a chat box.
                    .onKeyPress(.return, phases: .down) { key in
                        if key.modifiers.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
                    // Redundant on purpose. A vertical-axis field usually swallows Return so
                    // this never fires — but when it does, losing the message because the
                    // other path missed it would be unforgivable, and a double send is
                    // prevented by draft being cleared synchronously.
                    .onSubmit(send)

                if isRunning {
                    stopButton
                } else {
                    sendButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(focused ? Color.white.opacity(0.14) : Color.clear, lineWidth: 1)
            )
            .animation(DS.Motion.instant, value: focused)

            controls
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private var isRunning: Bool { runner.isRunning(conversationID) }
    private var bot: Bot? { store.bot(store.conversation(conversationID)?.participants.first) }

    private var placeholder: String {
        guard let name = bot?.name else { return "Ask anything" }
        return "Message \(name)"
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Buttons

    private var attachButton: some View {
        Button {
            attach()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colour.inkSecondary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Attach a file")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSend ? DS.Colour.ground : DS.Colour.inkTertiary)
                .frame(width: 24, height: 24)
                .background(canSend ? DS.Colour.ink : Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!canSend)
        // Enter/exit rather than a hard swap, so the control does not pop.
        .animation(DS.Motion.instant, value: canSend)
        .help("Send (Return)")
    }

    private var stopButton: some View {
        Button {
            runner.stop(conversationID)
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(DS.Colour.ground)
                .frame(width: 9, height: 9)
                .frame(width: 24, height: 24)
                .background(DS.Colour.ink, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Stop")
    }

    // MARK: Controls under the box

    /// Two chips, not fifteen modes: which brain answers, and how much it may decide alone.
    private var controls: some View {
        HStack(spacing: 8) {
            if let bot {
                BrainChip(bot: bot)
                AutonomyChip(bot: bot)
            }
            Spacer()
            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text("Working")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colour.inkSecondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .animation(DS.Motion.instant, value: isRunning)
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
        let paths = panel.urls.map(\.path).joined(separator: "\n")
        draft += (draft.isEmpty ? "" : "\n") + paths
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
            Button("Set up keys…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        } label: {
            chip(icon: "brain",
                 text: BotRunner.isFallingBack(bot) ? "\(bot.brain.shortName) → Gemini" : bot.brain.shortName,
                 warn: !isReady || BotRunner.isFallingBack(bot))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(BotRunner.isFallingBack(bot)
              ? "No adapter for this model yet — Gemini answers instead"
              : (isReady ? "Model" : "This model has no key yet"))
    }

    /// Whether the brain that will actually answer has what it needs.
    private var isReady: Bool { Keychain.has("gemini") }

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

    private func chip(icon: String, text: String, warn: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : icon)
                .font(.system(size: 9))
                .foregroundStyle(warn ? DS.Colour.running : DS.Colour.inkTertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colour.inkSecondary)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(DS.Colour.inkTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05), in: Capsule())
        .contentShape(Capsule())
    }
}

/// How much the bot may decide for itself. Three names, not six rungs — the ladder underneath
/// has six, but nobody should have to think in those terms to send a message.
struct AutonomyChip: View {
    @Environment(Store.self) private var store
    let bot: Bot

    var body: some View {
        Menu {
            mode(.confirmBeforeChange, "Ask", "Reads anything. Asks before changing anything.")
            mode(.autonomousWorkspace, "Work", "Works in its folder. Asks before anything consequential.")
            mode(.autonomousOperational, "Autopilot", "Acts across what you authorised. Asks rarely.")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colour.inkTertiary)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colour.inkSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(DS.Colour.inkTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How much this bot decides on its own")
    }

    private var label: String {
        switch bot.defaultAutonomy {
        case .autonomousOperational, .delegatedOperator: return "Autopilot"
        case .autonomousWorkspace:                       return "Work"
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

// MARK: - Press feedback

/// Every pressable thing should acknowledge the press. Subtle scale, fast ease-out — the
/// point is that the interface is visibly listening, not that anything is animated.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
