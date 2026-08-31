import BotHarnessCore
import SwiftUI

/// Application settings, at ⌘, like every other Mac app.
///
/// The product promise is that nothing a normal person does needs a terminal, and adding an
/// API key is the very first thing every person does. `scripts/set-key.sh` still exists for
/// scripting and headless setup; this is the path people take.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case providers, permissions, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers:   return "Providers"
            case .permissions: return "Permissions"
            case .about:       return "About"
            }
        }
        var icon: String {
            switch self {
            case .providers:   return "brain"
            case .permissions: return "hand.raised"
            case .about:       return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .providers

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { item in
                Group {
                    switch item {
                    case .providers:   ProviderSettings()
                    case .permissions: PermissionSettings()
                    case .about:       AboutSettings()
                    }
                }
                .tabItem { Label(item.title, systemImage: item.icon) }
                .tag(item)
            }
        }
        .frame(width: DS.Window.sheetWidth, height: DS.Window.sheetHeight)
    }
}

// MARK: - Providers

/// Where API keys go.
///
/// Three rules, all load-bearing:
///
/// 1. **A stored key is never displayed**, not even masked. There is no read path from this
///    screen to a secret; it can write one and ask whether one exists. A settings pane that
///    shows you your own key shows it to anyone who opens your laptop, and to any screenshot.
/// 2. **Keys go to one owner-only file** — never to `state.json`, a `.env`, a prompt or a trace,
///    and never to a path any bot is allowed to read. The copy below says plainly that they are
///    on disk, because they are; a settings screen that oversells its own security is worse than
///    one that admits what it is.
/// 3. **Every row says what is true of the code, not what is intended.** Claude Code used to
///    lead this screen with a green tick and "Signed in and ready — no API key needed", while
///    `BotRunner.brain(for:)` returned a Gemini adapter for every case; someone who believed
///    the tick and added no key got a bot that failed on its first message with an error about
///    a provider they had never chosen. That adapter now exists, so the row makes a claim
///    again — but the claim is checked against the disk each time this screen opens rather
///    than asserted, which is the only kind of tick worth showing.
struct ProviderSettings: View {
    @State private var present: [String: Bool] = [:]
    @State private var claudeCLI: ClaudeCLIState = .checking
    @State private var justSaved: String?
    @State private var permissionProblems: [String] = []
    /// Why the last save or delete did not happen. Previously a failed write showed the same
    /// green "Saved" as a successful one, so a key the user believed was stored was not.
    @State private var writeFailure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Bot-Harness runs on your own accounts. Keys are stored in one file only you can read, and are never put in a prompt, recorded in a trace, or reachable by a bot.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)

                // The reasons come from the store rather than being one hardcoded sentence.
                // There are three different problems it can report — a wide file mode, a wide
                // folder mode, and a leftover temporary file holding a complete copy of every
                // key — and a banner that always says "readable by other accounts" is simply
                // wrong for two of them. A security warning that names the wrong cause teaches
                // people to dismiss security warnings.
                if !permissionProblems.isEmpty {
                    ErrorState(permissionProblems.joined(separator: " ")) {
                        CredentialStore.repairPermissions()
                        permissionProblems = CredentialStore.permissionProblems()
                    }
                }

                if let failure = writeFailure {
                    ErrorState(failure)
                }

                // The app is inert with no brain at all, so the screen says so before it says
                // anything else. It checks for both of them: a signed-in `claude` CLI is a
                // working brain that costs nothing to set up, and telling someone who already
                // has one that they have no brain would send them off to fetch a key they do
                // not need.
                if !(present["gemini"] ?? false), !claudeCLI.canAnswer {
                    StandingNotice(
                        systemImage: "key.horizontal",
                        title: "No brain is set up yet",
                        detail: "Either add a Google Gemini key below, or install the Claude "
                              + "Code command and sign in — a Claude subscription needs no key. "
                              + "Only Gemini can drive the screen, keyboard and mouse.",
                        actionTitle: "Where do I get a Gemini key?",
                        tint: DS.Status.waiting.mark,
                        action: openGeminiKeyPage
                    )
                }

                KeyField(provider: "gemini", title: "Google Gemini",
                         detail: "The only brain that can drive the computer — screen, keyboard and mouse. Keys are free at aistudio.google.com.",
                         placeholder: "AIza…", isPresent: present["gemini"] ?? false,
                         onSave: { save("gemini", $0) }, onRemove: { remove("gemini") })

                KeyField(provider: "anthropic", title: "Anthropic",
                         detail: "Stored for later. No bot answers with it yet, so a key here changes nothing until the adapter is written.",
                         placeholder: "sk-ant-…", isPresent: present["anthropic"] ?? false,
                         onSave: { save("anthropic", $0) }, onRemove: { remove("anthropic") })

                KeyField(provider: "openai", title: "OpenAI",
                         detail: "Stored for later, on the same terms as Anthropic above.",
                         placeholder: "sk-…", isPresent: present["openai"] ?? false,
                         onSave: { save("openai", $0) }, onRemove: { remove("openai") })

                Hairline()
                claudeCodeRow

                if let justSaved {
                    Label("Saved your \(justSaved) key.", systemImage: "checkmark.circle.fill")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Status.done.mark)
                        .transition(.opacity)
                }
            }
            .dsInset(DS.Inset.pane)
        }
        .task {
            refresh()
            await refreshClaudeCLI()
        }
    }

    /// What this screen can honestly say about the `claude` command.
    ///
    /// Three states, not two, and the third is the point. Whether the CLI is *signed in* cannot
    /// be answered here: the subscription token lives in the login Keychain rather than a file,
    /// so asking costs either a Keychain prompt or a real model call. So the row says what it
    /// checked — the command is there and it runs — and stops short of the claim it cannot
    /// support. The old row's "Signed in and ready" was exactly that unsupported claim, and it
    /// is what sent a user into their first message believing they were set up.
    enum ClaudeCLIState {
        case checking
        case missing
        case installed(path: String, version: String)

        /// Enough to be worth offering as a brain. Sign-in is proven by the first message, and
        /// `ClaudeCLIAdapter` turns a signed-out CLI into an instruction rather than a silence.
        var canAnswer: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    /// Claude Code: a brain that needs no key, described by what was checked.
    private var claudeCodeRow: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: claudeCLIIcon)
                .foregroundStyle(claudeCLITint)
                .font(DS.Text.glyph)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.md) {
                    Text("Claude Code")
                        .font(DS.Text.body.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                    switch claudeCLI {
                    case .checking:     StatusPill(.running, "checking")
                    case .missing:      StatusPill(.waiting, "not installed")
                    case .installed:    StatusPill(.done, "installed")
                    }
                }

                Text(claudeCLIDetail)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)

                if case .installed(let path, let version) = claudeCLI {
                    // The one fact on this row that is read off the disk rather than asserted,
                    // so it is shown verbatim: if the row is ever wrong, this is the line that
                    // says how.
                    Text("\(path) — \(version)")
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var claudeCLIIcon: String {
        switch claudeCLI {
        case .checking:  return "hourglass"
        case .missing:   return "arrow.down.circle"
        case .installed: return "checkmark.circle.fill"
        }
    }

    private var claudeCLITint: Color {
        switch claudeCLI {
        case .checking:  return DS.Ink.secondary
        case .missing:   return DS.Ink.secondary
        case .installed: return DS.Status.done.mark
        }
    }

    private var claudeCLIDetail: String {
        switch claudeCLI {
        case .checking:
            return "Looking for the claude command on this Mac."
        case .missing:
            return "A Claude subscription can run your bots with no API key, through the "
                 + "claude command. It is not on this Mac. Install it from claude.com/code, "
                 + "sign in once, then reopen this window."
        case .installed:
            return "Found and running. Pick Claude Code in the brain menu next to the message "
                 + "box and this bot answers on your subscription, with no API key. If you have "
                 + "not signed the command in yet, the first message will say so. It cannot "
                 + "drive the screen, keyboard or mouse — only Gemini does that."
        }
    }

    /// Where a Gemini key comes from. The only external link on this screen, and it exists
    /// because "add a key" is not actionable advice if you do not know where keys live.
    private func openGeminiKeyPage() {
        guard let url = URL(string: "https://aistudio.google.com/apikey") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        CredentialStore.reload()
        for provider in ["gemini", "anthropic", "openai"] { present[provider] = CredentialStore.has(provider) }
        permissionProblems = CredentialStore.permissionProblems()
    }

    /// Separate from `refresh()` because it spawns a process, and a settings window that stalls
    /// while it waits is a settings window that looks broken. The row starts on `.checking` and
    /// this replaces it; `--version` neither reaches the network nor starts a login.
    private func refreshClaudeCLI() async {
        guard let path = Self.findClaudeCLI() else {
            claudeCLI = .missing
            return
        }
        let probe = await ClaudeCLIAdapter.execute(binary: path, arguments: ["--version"],
                                                   stdin: nil, cwd: nil, timeout: 15)
        // Present but not runnable is reported as missing rather than as a fourth state: to the
        // person reading this, a command that will not run is a command they have to install,
        // and the version line underneath is what would have said otherwise.
        guard probe.exitCode == 0 else {
            claudeCLI = .missing
            return
        }
        let version = probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeCLI = .installed(path: path, version: version.isEmpty ? "version unknown" : version)
    }

    private func save(_ provider: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The result is checked. A write can genuinely fail — a full disk, a file someone
        // hand-edited into something that is not a JSON object, a lock another process holds —
        // and confirming a save that did not happen is worse than reporting the failure, because
        // the user walks away believing their key is stored.
        guard CredentialStore.set(trimmed, account: provider) else {
            writeFailure = CredentialStore.lastWriteFailure
                ?? "That key could not be saved. \(CredentialStore.location) is not writable."
            return
        }
        writeFailure = nil
        present[provider] = CredentialStore.has(provider)
        withAnimation(DS.Motion.instant) { justSaved = Self.displayName(provider) }
        Task {
            try? await Task.sleep(for: .seconds(DS.Motion.confirmationDwell))
            withAnimation(DS.Motion.instant) { justSaved = nil }
        }
    }

    private func remove(_ provider: String) {
        CredentialStore.delete(provider)
        // Re-read rather than assuming. A delete that failed leaves the key on disk, and showing
        // it as gone means the user thinks they revoked something they did not.
        present[provider] = CredentialStore.has(provider)
        writeFailure = present[provider] == true
            ? (CredentialStore.lastWriteFailure ?? "That key could not be removed.")
            : nil
    }

    static func displayName(_ provider: String) -> String {
        switch provider {
        case "gemini":    return "Google Gemini"
        case "anthropic": return "Anthropic"
        case "openai":    return "OpenAI"
        default:          return provider
        }
    }

    /// Deliberately delegates rather than keeping its own copy of the search paths. The adapter
    /// is the thing that has to find the binary at run time; a second list here would be the
    /// list that silently goes stale, and this screen would then promise a brain the runtime
    /// cannot reach.
    static func findClaudeCLI() -> String? { ClaudeCLIAdapter.locateBinary() }
}

/// One provider's key row. Deliberately has no "show key" affordance: the stored value is
/// write-only from here.
private struct KeyField: View {
    let provider: String
    let title: String
    let detail: String
    let placeholder: String
    let isPresent: Bool
    let onSave: (String) -> Void
    let onRemove: () -> Void

    @State private var entry = ""
    @State private var replacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.md) {
                Text(title).font(DS.Text.body.weight(.semibold)).foregroundStyle(DS.Ink.primary)
                if isPresent && !replacing {
                    StatusPill(.done, "saved")
                }
                Spacer()
            }

            Text(detail)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

            if isPresent && !replacing {
                HStack(spacing: DS.Space.md) {
                    Text("••••••••••••••••••••••••")
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.secondary)
                    Spacer()
                    SecondaryButton("Replace") { replacing = true; entry = "" }
                    SecondaryButton("Remove", role: .destructive, action: onRemove)
                }
            } else {
                HStack(spacing: DS.Space.md) {
                    // SecureField, so the key is never rendered as readable text and never
                    // captured in a screenshot of this window.
                    SecureField(placeholder, text: $entry)
                        .textFieldStyle(.plain)
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, DS.Space.md)
                        .frame(minHeight: DS.Size.controlHeight)
                        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                        .onSubmit(commit)
                    PrimaryButton("Save", isEnabled: !entry.trimmingCharacters(in: .whitespaces).isEmpty,
                                  action: commit)
                    if replacing {
                        SecondaryButton("Cancel") { replacing = false; entry = "" }
                    }
                }
            }
        }
    }

    private func commit() {
        onSave(entry)
        entry = ""
        replacing = false
    }
}

// MARK: - Permissions

struct PermissionSettings: View {
    @Environment(Store.self) private var store
    @State private var newRule = ""
    @State private var newBehaviour: PermissionRule.Behaviour = .askFirst

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Rules that apply to every bot. Write one short rule per action, in plain language. Ask first always wins when two rules could both apply.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)

                // Writing a rule, which the copy above has always instructed people to do and
                // which nothing in the interface allowed. Without it the only way a rule could
                // ever be created was clicking "Always allow" on a prompt — and the only way to
                // remove one was editing the state file by hand.
                composer

                if store.globalRules.isEmpty {
                    Text("No rules yet. Every action falls back to the built-in list below and "
                       + "to how much each bot is allowed to decide.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                } else {
                    ForEach(store.globalRules) { rule in
                        RuleRow(rule: rule)
                    }
                }

                Hairline()

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    SectionLabel("Always asked, and not editable")
                    Text("These are built in. No rule you write can switch them off.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                }

                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(SafetyFloor.allCases, id: \.self) { floor in
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: floor.floorBehaviour == .neverAllow ? "nosign" : "hand.raised.fill")
                                .font(DS.Text.glyphSmall)
                                .foregroundStyle(floor.floorBehaviour == .neverAllow
                                                 ? DS.Status.failed.mark : DS.Status.running.mark)
                                .frame(width: DS.Space.lg)
                            Text("Anything that \(floor.explanation)")
                                .font(DS.Text.caption)
                                .foregroundStyle(DS.Ink.primary)
                            Spacer()
                            Text(floor.floorBehaviour == .neverAllow ? "never" : "asks")
                                .font(DS.Text.micro)
                                .foregroundStyle(DS.Ink.secondary)
                        }
                    }
                }
            }
            .dsInset(DS.Inset.pane)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionLabel("Add a rule")
            HStack(spacing: DS.Space.md) {
                Text("When a bot wants to")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .fixedSize()
                TextField("send a message on my behalf", text: $newRule)
                    .textFieldStyle(.plain)
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.primary)
                    .padding(.horizontal, DS.Space.md)
                    .frame(minWidth: DS.Size.fieldMin, minHeight: DS.Size.controlHeight)
                    .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .onSubmit(add)
                    .accessibilityLabel("What the bot might want to do")
            }
            HStack(spacing: DS.Space.md) {
                Picker("", selection: $newBehaviour) {
                    ForEach(PermissionRule.Behaviour.allCases, id: \.self) { behaviour in
                        Text(behaviour.displayName).tag(behaviour)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("What should happen")
                Spacer()
                PrimaryButton("Add rule",
                              isEnabled: !newRule.trimmingCharacters(in: .whitespaces).isEmpty,
                              action: add)
            }
        }
        .padding(DS.Space.lg)
        .background(DS.Surface.raised, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private func add() {
        let text = newRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addGlobalRule(PermissionRule(whenBotWantsTo: text, behaviour: newBehaviour))
        newRule = ""
        newBehaviour = .askFirst
    }
}

private struct RuleRow: View {
    @Environment(Store.self) private var store
    let rule: PermissionRule
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: icon)
                .foregroundStyle(colour)
                .font(DS.Text.glyph)
                .frame(width: DS.Space.xl)
                .accessibilityHidden(true)

            if editing {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    TextField("What the bot might want to do", text: $text)
                        .textFieldStyle(.plain)
                        .font(DS.Text.callout)
                        .foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, DS.Space.md)
                        .frame(minHeight: DS.Size.controlHeight)
                        .background(DS.Surface.ground, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                        .onSubmit(commit)
                    HStack(spacing: DS.Space.md) {
                        Picker("", selection: behaviourBinding) {
                            ForEach(PermissionRule.Behaviour.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("What should happen")
                        Spacer()
                        SecondaryButton("Cancel") { editing = false }
                            .keyboardShortcut(.cancelAction)
                        PrimaryButton("Save", action: commit)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text("When a bot wants to " + rule.whenBotWantsTo)
                        .font(DS.Text.callout)
                        .foregroundStyle(DS.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.sm) {
                        Text(rule.behaviour.displayName)
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Ink.secondary)
                        if rule.createdFromPrompt {
                            Text("added from a prompt")
                                .font(DS.Text.micro)
                                .foregroundStyle(DS.Ink.secondary)
                                .padding(.horizontal, DS.Space.sm)
                                .padding(.vertical, DS.Space.hair)
                                .background(DS.Tint.t3, in: Capsule())
                        }
                    }
                }
                Spacer()
                SecondaryButton("Edit") { text = rule.whenBotWantsTo; editing = true }
                SecondaryButton("Remove", role: .destructive) {
                    store.deleteGlobalRule(rule.id)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(minHeight: DS.Size.settingsRow, alignment: .leading)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rule: when a bot wants to \(rule.whenBotWantsTo), \(rule.behaviour.displayName)")
    }

    private var behaviourBinding: Binding<PermissionRule.Behaviour> {
        Binding(
            get: { rule.behaviour },
            set: { var updated = rule; updated.behaviour = $0; store.updateGlobalRule(updated) }
        )
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { editing = false; return }
        var updated = rule
        updated.whenBotWantsTo = trimmed
        store.updateGlobalRule(updated)
        editing = false
    }

    private var icon: String {
        switch rule.behaviour {
        case .allowAutomatically: return "checkmark.circle.fill"
        case .askFirst:           return "hand.raised.fill"
        case .neverAllow:         return "nosign"
        }
    }

    private var colour: Color {
        switch rule.behaviour {
        case .allowAutomatically: return DS.Status.done.mark
        case .askFirst:           return DS.Status.awaitingApproval.mark
        case .neverAllow:         return DS.Status.failed.mark
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Bot-Harness").font(DS.Text.title).foregroundStyle(DS.Ink.primary)
            Text("An open-source, local-first agent cockpit. Your bots, your Mac, your API keys.")
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.secondary)

            Hairline()

            path("State", Paths.root.path)
            path("Traces", Paths.traces.path)
            path("Keys", CredentialStore.location)

            Spacer()

            Text("Everything this app records is written where you can read it without this app: JSON for state, JSONL for traces, PNG for screenshots.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsInset(DS.Inset.pane)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func path(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            Text(title).font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
            Text(value)
                .font(DS.Text.monoSmall)
                .foregroundStyle(DS.Ink.primary)
                .textSelection(.enabled)
        }
    }
}
