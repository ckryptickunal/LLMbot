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
/// 3. **The brain that actually answers is listed first.** This used to be Claude Code, on the
///    reasoning that the fastest path to a working app is the one requiring nothing at all —
///    which would be right if it worked. `BotRunner.brain(for:)` returns a Gemini adapter for
///    every case, so following this screen and adding no key produced a bot that failed on its
///    first message with no clue why. Ordering by what is true beats ordering by what is easy.
struct ProviderSettings: View {
    @State private var present: [String: Bool] = [:]
    @State private var claudeCLIPath: String?
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

                // The whole app is inert without this one key, so the screen says so before it
                // says anything else. Previously the first thing here was a green tick beside a
                // brain that cannot answer, which told a new user they were finished.
                if !(present["gemini"] ?? false) {
                    StandingNotice(
                        systemImage: "key.horizontal",
                        title: "No brain is set up yet",
                        detail: "Add a Google Gemini key below. It is the only one that answers "
                              + "today — the others are stored for when their adapters exist.",
                        actionTitle: "Where do I get one?",
                        tint: DS.Status.waiting.mark,
                        action: openGeminiKeyPage
                    )
                }

                KeyField(provider: "gemini", title: "Google Gemini",
                         detail: "The brain every bot answers with today, and what drives the computer — screen, keyboard and mouse. Keys are free at aistudio.google.com.",
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
        .task { refresh() }
    }

    /// Claude Code, described as what it is today rather than what it is meant to be.
    ///
    /// It carried a green tick and "Signed in and ready — no API key needed", and `Bot.swift`
    /// still documents the CLI as the first-class brain that lets someone with no key use this
    /// app. Both are the intent. Neither is the code: `BotRunner.brain(for:)` returns a Gemini
    /// adapter for every `BrainSpec`, so a bot set to Claude Code answers with Gemini, and a
    /// user who added no key because this row said they were ready got silence.
    ///
    /// A tick is a claim. Until the adapter exists this row shows the same "Soon" chip the
    /// Container environment uses, and says the same thing the composer's brain chip already
    /// says — "adapter not written" — so the two places never disagree.
    private var claudeCodeRow: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: "clock")
                .foregroundStyle(DS.Ink.secondary)
                .font(DS.Text.glyph)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.md) {
                    Text("Claude Code")
                        .font(DS.Text.body.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                    Text("Soon")
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.secondary)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Tint.t3, in: Capsule())
                }
                Text("Meant to make a Claude Code subscription a brain with no API key. The "
                   + "adapter that speaks to the CLI is not written yet, so a bot set to Claude "
                   + "Code answers with Gemini instead.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = claudeCLIPath {
                    // Still worth showing: it is the one fact on this row that is checked
                    // against the disk rather than asserted.
                    Text("Found on this Mac at \(path)")
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
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
        claudeCLIPath = Self.findClaudeCLI()
        permissionProblems = CredentialStore.permissionProblems()
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

    /// The CLI is usually outside a GUI app's inherited PATH, so look where it installs rather
    /// than relying on `which`.
    static func findClaudeCLI() -> String? {
        [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
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
