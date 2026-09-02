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
    @Environment(UIState.self) private var ui

    let conversationID: UUID
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    @State private var dropping = false
    /// Counts sends, only so the arrow can bounce once per send.
    @State private var sends = 0
    /// Bumped when the key file changes, so `blocker` is re-asked. The banner reads the
    /// credential store during render, and a key saved in the Settings window changes nothing
    /// this view observes — the user's actual first experience was saving a key and returning
    /// to a composer still demanding one.
    @State private var keyEdition = 0

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
            if let problems = ui.attachmentProblems[conversationID], !problems.isEmpty {
                attachmentProblem(problems)
            }
            if let blocker { preflight(blocker) }
            // Below the preflight banner, not above it. The comment above describes the mascot
            // standing one `md` above the field, and that was true only when no banner was
            // showing — with one present it stood on the banner instead, a third of the way
            // across, which reads as a drawing dropped into empty space rather than a character
            // standing on the thing you type into.
            MascotView(mascotState)
            field
            controls
        }
        .padding(.bottom, DS.Space.lg)
        // A key saved or removed in Settings re-renders this view the same second, which is
        // what makes the banner disappear while the person is still looking at it.
        .onReceive(NotificationCenter.default.publisher(for: .credentialsDidChange)) { _ in
            keyEdition += 1
        }
    }

    /// Why this bot cannot answer yet, if it cannot.
    ///
    /// Without this the first run of the app is: type a message, wait, get a failure bubble.
    /// The only warning was a ten-point triangle inside a chip. Saying it before the send makes
    /// the first minute a setup step instead of an error.
    ///
    /// Asks about the bot's *own* brain — the same rule `BrainChip.unavailable` already
    /// records. It used to ask only about Gemini, so a bot answering with Claude Code ran
    /// happily underneath a banner demanding a Gemini key it would never use. The other brains
    /// stay the chip's job: their warnings are about the chip's own choice, not about a key
    /// the user has to go and fetch.
    private var blocker: String? {
        guard let bot, case .gemini = bot.brain else { return nil }
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
            SettingsLink {
                Text("Add a key")
                    .font(DS.Text.caption.weight(.medium))
                    // The accent, because this is the banner's one action and it rendered as
                    // plain white text — a button that does not look like one.
                    .foregroundStyle(DS.Accent.live)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Surface.paper, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Surface.border, lineWidth: DS.Size.hairline)
        )
        .accessibilityElement(children: .combine)
    }

    /// What a drop declined to attach, and why.
    ///
    /// In the same slot as the key banner and styled the same, because it is the same kind of
    /// thing: a condition standing between you and sending, stated where you are already
    /// looking. It is dismissed rather than timed out — the whole reason it exists is that a
    /// drop which quietly did nothing left the person believing the file was attached, and a
    /// message that disappears on its own recreates that at a delay.
    private func attachmentProblem(_ sentences: [String]) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(DS.Text.glyphSmall)
                .foregroundStyle(DS.Status.awaitingApproval.mark)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(sentences, id: \.self) { sentence in
                    Text(sentence)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.md)
            Button {
                ui.clearAttachmentProblems(for: conversationID)
            } label: {
                Text("OK")
                    .font(DS.Text.caption.weight(.medium))
                    .foregroundStyle(DS.Accent.live)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Surface.paper, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Surface.border, lineWidth: DS.Size.hairline)
        )
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
        // Paper with a hairline, and the hairline is the whole treatment.
        //
        // This used to be a tinted fill with a clay glow behind it and a clay stroke on top.
        // The glow is gone because nothing in this system glows, and the clay is gone because
        // the composer is focused nearly all the time — a permanently-lit brand colour is not
        // an accent, it is decoration that happens to be the logo. Focus now moves the border
        // to full ink, which is the reference's rule and reads as sharper the instant it lands.
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.pill)
                .fill(DS.Surface.paper)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.pill)
                // `borderStrong` rather than the full-ink `borderFocus` every other field
                // uses, and the composer is the one control that earns the exception: it holds
                // focus almost the entire time the app is open, so the focused state *is* its
                // resting state. Drawn at full ink it was a heavy black ring around the bottom
                // of the window at all times — the loudest thing on a quiet screen, signalling
                // something that is almost always true and therefore signalling nothing.
                .stroke(focused ? DS.Surface.borderStrong : DS.Surface.border,
                        lineWidth: DS.Size.hairline)
        )
        .dsAnimation(DS.Motion.instant, value: focused)
        // Dropping a file on the composer is how a Mac user attaches one. Before this the only
        // path was a button that pasted absolute paths as text, and dragging anything onto the
        // window did nothing at all — in an app whose whole subject is files.
        .onDrop(of: DroppedFiles.accepted, isTargeted: $dropping) { providers in
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
                // Dark ink on the clay, like every accent fill in the app — white here
                // measures 3.1:1 and fails AA.
                .foregroundStyle(canSend ? DS.Accent.onAccent : DS.Ink.quaternary)
                // One quick bounce per send. Keyed to the counter, not to hover, so it fires
                // exactly when a message leaves and never while the cursor is just passing.
                .symbolEffect(.bounce, value: sends)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .background(canSend ? DS.Accent.live : DS.Tint.t3, in: Circle())
                // The fill popping in as the first character lands is the button saying
                // "ready". Scale rides the same spring; the overshoot is a whisker, because
                // this fires on every draft.
                .scaleEffect(canSend ? 1 : DS.Motion.pressScale)
        }
        .buttonStyle(PressableStyle())
        .disabled(!canSend)
        .dsAnimation(DS.Motion.pop, value: canSend)
        .help("Send (Return)")
        .accessibilityLabel("Send message")
    }

    private var stopButton: some View {
        Button { runner.stop(conversationID) } label: {
            RoundedRectangle(cornerRadius: DS.Radius.xs)
                .fill(DS.Accent.onAccent)
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
        sends += 1
    }

    /// Add dropped files to the draft, one path per line.
    /// Pull paths out of a drop, whatever the source registered them as.
    ///
    /// The parsing lives in `DroppedFiles`, in the core, because the test bundle links that and
    /// not this target — so anything left here could only ever be checked by dragging a file onto
    /// a running app by hand, which is exactly the kind of test nobody repeats. See that file for
    /// what was actually wrong with dropping, and for the theory that turned out not to be.
    private func attach(_ providers: [NSItemProvider]) {
        DroppedFiles.load(from: providers) { paths in
            Task { @MainActor in append(paths: paths) }
        }
    }

    /// Attaching is granting. See `Attaching` for why all three routes go through one function,
    /// and `Attachment` for why the grant may come from this gesture and never from a message.
    ///
    /// Paths are quoted where they need it. Most screenshots are called "Screen Shot …", and an
    /// unquoted path with a space in it read as two paths — the bot then went looking for a
    /// file called "Screen" and reported, truthfully, that it did not exist.
    private func append(paths: [String]) {
        Attaching.accept(paths, into: conversationID, store: store, ui: ui, draft: $draft)
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

    @State private var open = false
    /// Bumped when the key file changes, so the warning triangle clears the moment a key is
    /// saved in Settings rather than at the next incidental re-render.
    @State private var keyEdition = 0

    /// A popover rather than a `Menu`, for the reason already recorded on the roster's create
    /// button: `Menu` insets and restyles its own label, and there is no supported way to take
    /// that off. The `Chip` primitive was written with a capsule background, a 9-point icon and
    /// a chevron, and inside a `Menu` label none of the three survived — the chip rendered as
    /// bare text with an oversized icon whose tint was dropped, so a warning showed a white
    /// triangle beside amber words. `Chip` is used in exactly two places, both of them were
    /// menus, and so the primitive had never once drawn the way it was designed.
    var body: some View {
        Button { open.toggle() } label: {
            Chip(label, systemImage: warns ? "exclamationmark.triangle.fill" : "brain",
                 tint: warns ? DS.Status.running.mark : DS.Ink.secondary,
                 showsChevron: true)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $open, arrowEdge: .top) { menu }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsDidChange)) { _ in
            keyEdition += 1
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SectionLabel("Gemini")
            option(.gemini(model: GeminiAdapter.defaultModel), "Gemini 3.7 Flash",
                   "Best for using the computer")
            option(.gemini(model: GeminiAdapter.cheapModel), "Gemini 3.5 Flash-Lite",
                   "Faster and cheaper")

            SectionLabel("Claude Code")
            option(.claudeCode, "Claude Code",
                   "Your subscription, no key — cannot drive the screen")

            SectionLabel("Not wired up yet")
            option(.anthropic(model: "claude-opus-5"), "Claude Opus 5", "Adapter not written")
            option(.openAI(model: "gpt-5"), "GPT-5", "Adapter not written")

            Hairline()
            Button {
                open = false
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Text("Set up keys…")
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: DS.Size.hit)
                    .padding(.horizontal, DS.Space.sm)
            }
            .buttonStyle(.plain)
            .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.xs))
        }
        .padding(DS.Space.md)
        .frame(minWidth: DS.Window.popoverMin)
    }

    /// Whether the brain this bot is actually set to can answer.
    ///
    /// Asks about the bot's own brain rather than about Gemini. It used to warn whenever no
    /// Gemini key existed, so a bot set to Claude Code with a working subscription showed a
    /// warning triangle for a key it does not need and would never use.
    private var unavailable: Bool {
        switch bot.brain {
        case .gemini:              return !CredentialStore.has("gemini")
        case .claudeCLI:           return ClaudeCLIAdapter.locateBinary() == nil
        case .anthropic, .openAI:  return true
        }
    }

    private var warns: Bool { unavailable }

    /// Says what will actually answer, not what is selected. A control that reports a state
    /// the system is not in is worse than one that admits the gap.
    private var label: String { bot.brain.shortName }

    private var helpText: String {
        switch bot.brain {
        case .gemini:
            return CredentialStore.has("gemini") ? "Model" : "This model has no key yet"
        case .claudeCLI:
            return ClaudeCLIAdapter.locateBinary() == nil
                ? "The claude command line tool is not installed"
                : "Your Claude Code subscription — cannot drive the screen"
        case .anthropic, .openAI:
            return "No adapter for this model yet — pick another brain"
        }
    }

    private func option(_ brain: BrainSpec, _ title: String, _ detail: String) -> some View {
        Button {
            var updated = bot
            updated.brain = brain
            store.update(updated)
            open = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                // A fixed gutter so every title starts on the same pixel whether or not it is
                // the one currently chosen. A checkmark that shifts the text is how a menu ends
                // up looking like it is moving under the cursor.
                Image(systemName: "checkmark")
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(bot.brain == brain ? DS.Ink.primary : .clear)
                    .frame(width: DS.Space.lg, alignment: .center)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(DS.Text.callout).foregroundStyle(DS.Ink.primary)
                    Text(detail).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.xs))
    }
}

/// How much the bot may decide for itself. Three names, not six rungs — the ladder underneath
/// keeps its full resolution, but nobody should have to think in those terms to send a message.
struct AutonomyChip: View {
    @Environment(Store.self) private var store
    let bot: Bot

    @State private var open = false

    /// A popover for the same reason as `BrainChip`: a `Menu` restyles its label and the chip
    /// loses its capsule, its icon size and its chevron.
    var body: some View {
        Button { open.toggle() } label: {
            Chip(label, systemImage: icon, showsChevron: true)
        }
        .buttonStyle(.plain)
        .help("How much this bot decides on its own")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                mode(.confirmBeforeChange, "Ask", "Reads anything. Asks before changing anything.")
                mode(.autonomousWorkspace, "Work", "Works in its folder. Asks before anything consequential.")
                mode(.autonomousOperational, "Autopilot", "Acts across what you authorised. Asks rarely.")
            }
            .padding(DS.Space.md)
            .frame(minWidth: DS.Window.popoverMin)
        }
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
        // `hand.raised` was a raised palm, which reads as "stop" — the opposite of a mode whose
        // whole promise is that the bot keeps going and checks with you first. A question mark
        // says "it will ask", which is what the mode is called.
        case .autonomousOperational, .delegatedOperator: return "bolt.fill"
        case .autonomousWorkspace:                        return "play.fill"
        default:                                          return "questionmark.circle.fill"
        }
    }

    private func mode(_ level: Autonomy, _ title: String, _ detail: String) -> some View {
        Button {
            var updated = bot
            updated.defaultAutonomy = level
            store.update(updated)
            open = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                // The gutter is always there so the titles do not shift when the choice moves.
                Image(systemName: "checkmark")
                    .font(DS.Text.glyphSmall)
                    .foregroundStyle(bot.defaultAutonomy == level ? DS.Ink.primary : .clear)
                    .frame(width: DS.Space.lg, alignment: .center)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(DS.Text.callout).foregroundStyle(DS.Ink.primary)
                    Text(detail).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.xs))
    }
}
