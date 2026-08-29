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
        .frame(width: 560, height: 460)
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
/// 2. **Keys go straight to the Keychain** — never to `state.json`, a `.env`, a prompt or a trace.
/// 3. **The brain that needs no key is listed first**, because the fastest path to a working
///    app is the one requiring nothing at all.
struct ProviderSettings: View {
    @State private var present: [String: Bool] = [:]
    @State private var claudeCLIPath: String?
    @State private var justSaved: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl + 2) {
                Text("Bot-Harness runs on your own accounts. Keys are stored in the macOS Keychain and are never written to a file, put in a prompt, or recorded in a trace.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)

                claudeCodeRow
                Hairline()

                KeyField(provider: "gemini", title: "Google Gemini",
                         detail: "Drives the computer — screen, keyboard and mouse. Get a key at aistudio.google.com.",
                         placeholder: "AIza…", isPresent: present["gemini"] ?? false,
                         onSave: { save("gemini", $0) }, onRemove: { remove("gemini") })

                KeyField(provider: "anthropic", title: "Anthropic",
                         detail: "Only needed if you have an API key. A Claude Code subscription is handled above instead.",
                         placeholder: "sk-ant-…", isPresent: present["anthropic"] ?? false,
                         onSave: { save("anthropic", $0) }, onRemove: { remove("anthropic") })

                KeyField(provider: "openai", title: "OpenAI",
                         detail: "Optional. Available as an additional brain for bots that want it.",
                         placeholder: "sk-…", isPresent: present["openai"] ?? false,
                         onSave: { save("openai", $0) }, onRemove: { remove("openai") })

                if let justSaved {
                    Label("Saved \(justSaved) to your Keychain.", systemImage: "checkmark.circle.fill")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Status.done.mark)
                        .transition(.opacity)
                }
            }
            .padding(DS.Space.xxl - 4)
        }
        .task { refresh() }
    }

    private var claudeCodeRow: some View {
        HStack(alignment: .top, spacing: DS.Space.lg - 1) {
            Image(systemName: claudeCLIPath == nil ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(claudeCLIPath == nil ? DS.Ink.secondary : DS.Status.done.mark)
                .font(DS.Text.glyph)
            VStack(alignment: .leading, spacing: DS.Space.xs - 1) {
                Text("Claude Code")
                    .font(DS.Text.body.weight(.semibold))
                    .foregroundStyle(DS.Ink.primary)
                if let path = claudeCLIPath {
                    Text("Signed in and ready — no API key needed. Billed to your subscription.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                    Text(path)
                        .font(DS.Text.monoSmall)
                        .foregroundStyle(DS.Ink.tertiary)
                } else {
                    Text("Not found. Install the Claude Code CLI to use your subscription as a brain.")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Ink.secondary)
                }
            }
            Spacer()
        }
    }

    private func refresh() {
        for provider in ["gemini", "anthropic", "openai"] { present[provider] = Keychain.has(provider) }
        claudeCLIPath = Self.findClaudeCLI()
    }

    private func save(_ provider: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, account: provider)
        present[provider] = Keychain.has(provider)
        withAnimation(DS.Motion.instant) { justSaved = provider }
        Task {
            try? await Task.sleep(for: .seconds(DS.Motion.confirmationDwell))
            withAnimation(DS.Motion.instant) { justSaved = nil }
        }
    }

    private func remove(_ provider: String) {
        Keychain.delete(provider)
        present[provider] = false
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
        VStack(alignment: .leading, spacing: DS.Space.sm + 1) {
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
                        .foregroundStyle(DS.Ink.tertiary)
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
                        .padding(.horizontal, DS.Space.md + 1)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Rules that apply to every bot. Write one short rule per action, in plain language. Ask first always wins when two rules could both apply.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineSpacing(DS.Text.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(store.globalRules) { RuleRow(rule: $0) }

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
                                .frame(width: DS.Space.lg + 2)
                            Text("Anything that \(floor.explanation)")
                                .font(DS.Text.caption)
                                .foregroundStyle(DS.Ink.primary)
                            Spacer()
                            Text(floor.floorBehaviour == .neverAllow ? "never" : "asks")
                                .font(DS.Text.micro)
                                .foregroundStyle(DS.Ink.tertiary)
                        }
                    }
                }
            }
            .padding(DS.Space.xxl - 4)
        }
    }
}

private struct RuleRow: View {
    let rule: PermissionRule

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg - 2) {
            Image(systemName: icon)
                .foregroundStyle(colour)
                .font(DS.Text.glyph)
                .frame(width: DS.Space.xl)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text("When a bot wants to " + rule.whenBotWantsTo)
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.primary)
                Text(rule.behaviour.displayName)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
            }
            Spacer()
        }
        .padding(DS.Space.lg - 1)
        .frame(minHeight: DS.Size.settingsRow, alignment: .leading)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
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
        case .askFirst:           return DS.Status.running.mark
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
            path("Keychain service", Keychain.service)

            Spacer()

            Text("Everything this app records is written where you can read it without this app: JSON for state, JSONL for traces, PNG for screenshots.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.tertiary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.xxl - 4)
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
