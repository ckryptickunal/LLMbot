import SwiftUI

/// Application settings. Opened with ⌘, like every other Mac app.
///
/// The product promise is that nothing a normal user does requires a terminal, and adding an
/// API key is the very first thing every user does. `scripts/set-key.sh` still exists for
/// scripting and for headless setup, but this is the path people actually take.
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
            ForEach(Tab.allCases) { t in
                Group {
                    switch t {
                    case .providers:   ProviderSettings()
                    case .permissions: PermissionSettings()
                    case .about:       AboutSettings()
                    }
                }
                .tabItem { Label(t.title, systemImage: t.icon) }
                .tag(t)
            }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - Providers

/// Where API keys go.
///
/// Three rules this screen follows, all of them load-bearing:
///
/// 1. **A stored key is never displayed**, not even masked back to the user. There is no read
///    path from this screen to a secret; it can write one and it can ask whether one exists.
///    A settings pane that shows you your own key is a settings pane that shows it to anyone
///    who opens your laptop, and to any screenshot you take of it.
/// 2. **Keys go straight to the Keychain**, never to `state.json`, never to a `.env`, never
///    into a prompt or a trace.
/// 3. **The bot that needs no key is listed first**, because the fastest path to a working
///    app is the one that requires nothing from the user at all.
struct ProviderSettings: View {
    @State private var present: [String: Bool] = [:]
    @State private var claudeCLIPath: String?
    @State private var justSaved: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Bot-Harness runs on your own accounts. Keys are stored in the macOS Keychain and are never written to a file, put in a prompt, or recorded in a trace.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                claudeCodeRow

                Divider()

                KeyField(
                    provider: "gemini",
                    title: "Google Gemini",
                    detail: "Drives the computer — screen, keyboard and mouse. Get a key at aistudio.google.com.",
                    placeholder: "AIza…",
                    isPresent: present["gemini"] ?? false,
                    onSave: { save("gemini", $0) },
                    onRemove: { remove("gemini") }
                )

                KeyField(
                    provider: "anthropic",
                    title: "Anthropic",
                    detail: "Only needed if you have an API key. A Claude Code subscription is handled above instead.",
                    placeholder: "sk-ant-…",
                    isPresent: present["anthropic"] ?? false,
                    onSave: { save("anthropic", $0) },
                    onRemove: { remove("anthropic") }
                )

                KeyField(
                    provider: "openai",
                    title: "OpenAI",
                    detail: "Optional. Available as an additional brain for bots that want it.",
                    placeholder: "sk-…",
                    isPresent: present["openai"] ?? false,
                    onSave: { save("openai", $0) },
                    onRemove: { remove("openai") }
                )

                if let justSaved {
                    Label("Saved \(justSaved) to your Keychain.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(20)
        }
        .task { refresh() }
    }

    private var claudeCodeRow: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: claudeCLIPath == nil ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(claudeCLIPath == nil ? Color.secondary : Color.green)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude Code")
                    .font(.system(size: 13, weight: .semibold))
                if let path = claudeCLIPath {
                    Text("Signed in and ready — no API key needed. Billed to your subscription.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not found. Install the Claude Code CLI to use your subscription as a brain.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func refresh() {
        for p in ["gemini", "anthropic", "openai"] { present[p] = Keychain.has(p) }
        claudeCLIPath = Self.findClaudeCLI()
    }

    private func save(_ provider: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, account: provider)
        present[provider] = Keychain.has(provider)
        withAnimation(Motion.routine) { justSaved = provider }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Motion.routine) { justSaved = nil }
        }
    }

    private func remove(_ provider: String) {
        Keychain.delete(provider)
        present[provider] = false
    }

    /// The CLI is usually outside a GUI app's inherited PATH, so look where it actually
    /// installs rather than relying on `which`.
    static func findClaudeCLI() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// One provider's key row.
///
/// Deliberately has no "show key" affordance. The stored value is write-only from this screen.
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if isPresent && !replacing {
                    Text("saved")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.14), in: Capsule())
                }
                Spacer()
            }

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isPresent && !replacing {
                HStack(spacing: 8) {
                    Text("••••••••••••••••••••••••")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Replace") { replacing = true; entry = "" }
                    Button("Remove", role: .destructive) { onRemove() }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    // SecureField, so the key is never rendered as readable text and never
                    // captured in a screenshot of this window.
                    SecureField(placeholder, text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { commit() }
                    Button("Save") { commit() }
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                    if replacing {
                        Button("Cancel") { replacing = false; entry = "" }
                    }
                }
                .controlSize(.small)
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
            VStack(alignment: .leading, spacing: 16) {
                Text("Rules that apply to every bot. Write one short rule per action, in plain language. **Ask first always wins** when two rules could both apply.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(store.globalRules) { rule in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: rule.behaviour))
                            .foregroundStyle(colour(for: rule.behaviour))
                            .font(.system(size: 12))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("When a bot wants to \(rule.whenBotWantsTo)")
                                .font(.system(size: 12))
                            Text(rule.behaviour.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(9)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                }

                Divider()

                Text("Always asked, and not editable")
                    .font(.system(size: 12, weight: .semibold))
                Text("These are built in. No rule you write can switch them off.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach(SafetyFloor.allCases, id: \.self) { floor in
                    HStack(spacing: 8) {
                        Image(systemName: floor.floorBehaviour == .neverAllow ? "nosign" : "hand.raised.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(floor.floorBehaviour == .neverAllow ? Color.red : Color.orange)
                            .frame(width: 14)
                        Text("Anything that \(floor.explanation)")
                            .font(.system(size: 11.5))
                        Spacer()
                        Text(floor.floorBehaviour == .neverAllow ? "never" : "asks")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
    }

    private func icon(for b: PermissionRule.Behaviour) -> String {
        switch b {
        case .allowAutomatically: return "checkmark.circle.fill"
        case .askFirst:           return "hand.raised.fill"
        case .neverAllow:         return "nosign"
        }
    }

    private func colour(for b: PermissionRule.Behaviour) -> Color {
        switch b {
        case .allowAutomatically: return .green
        case .askFirst:           return .orange
        case .neverAllow:         return .red
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bot-Harness").font(.system(size: 15, weight: .semibold))
            Text("An open-source, local-first agent cockpit. Your bots, your Mac, your API keys.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            Group {
                labelled("State", Paths.root.path)
                labelled("Traces", Paths.traces.path)
                labelled("Keychain service", Keychain.service)
            }

            Spacer()

            Text("Everything this app records is written where you can read it without this app: JSON for state, JSONL for traces, PNG for screenshots.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
