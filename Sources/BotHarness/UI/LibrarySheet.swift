import SwiftUI
import BotHarnessCore

/// Connections, Skills and Computers.
///
/// Everything a bot can reach, in one place, stated honestly. Where something is not built
/// yet the row says so rather than pretending — a control that looks live and does nothing is
/// worse than one that admits it is coming, because the first teaches people not to trust the
/// interface.
struct LibrarySheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case connections, skills, computers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .connections: return "Connections"
            case .skills:      return "Skills"
            case .computers:   return "Computers"
            }
        }
        var icon: String {
            switch self {
            case .connections: return "app.connected.to.app.below.fill"
            case .skills:      return "sparkles"
            case .computers:   return "desktopcomputer"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State var tab: Tab = .connections

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            ScrollView {
                switch tab {
                case .connections: ConnectionsList()
                case .skills:      SkillsList()
                case .computers:   ComputersList()
                }
            }
        }
        .frame(width: 560, height: 480)
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button {
                    withAnimation(Motion.routine) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 11))
                        Text(t.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(tab == t ? Theme.primary : Theme.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(tab == t ? Color.white.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(PressableButtonStyle())
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Connections

private struct ConnectionsList: View {
    @State private var claudeCLI = ProviderSettings.findClaudeCLI()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            note("What your bots can reach. Model keys live in Settings (⌘,); everything else is listed here.")

            section("Working now")
            row("Your Mac", "Files, terminal, screen, keyboard and apps",
                status: .connected, icon: "desktopcomputer")
            row("Gemini", Keychain.has("gemini") ? "Key saved" : "No key yet",
                status: Keychain.has("gemini") ? .connected : .needsSetup, icon: "brain")
            row("Claude Code", claudeCLI == nil ? "CLI not found" : "Signed in, no key needed",
                status: claudeCLI == nil ? .needsSetup : .connected, icon: "terminal")

            section("Not built yet")
            row("Browser", "Drive Chrome with your logged-in sessions", status: .planned, icon: "globe")
            row("GitHub", "Issues, pull requests, releases", status: .planned, icon: "chevron.left.forwardslash.chevron.right")
            row("Gmail and Calendar", "Read, draft, schedule", status: .planned, icon: "envelope")
            row("Plugins over MCP", "Anything that speaks Model Context Protocol", status: .planned, icon: "puzzlepiece.extension")
        }
        .padding(18)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    enum Status { case connected, needsSetup, planned }

    private func row(_ title: String, _ detail: String, status: Status, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(status == .planned ? Theme.tertiary : Theme.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(status == .planned ? Theme.secondary : Theme.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            switch status {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Theme.done)
            case .needsSetup:
                Button("Set up") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 11))
            case .planned:
                Text("Soon").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Skills

private struct SkillsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skills are short written procedures a bot loads only when they are relevant — how to work in a particular repository, how to deploy a particular app.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22)).foregroundStyle(Theme.tertiary)
                Text("No skills yet").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                Text("When a bot does something well more than once, you will be able to save it here and ask for it by name.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        }
        .padding(18)
    }
}

// MARK: - Computers

private struct ComputersList: View {
    @State private var permissions = ComputerExecutor.permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where your bots do their work.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 15))
                        .foregroundStyle(Theme.primary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("This Mac").font(.system(size: 13, weight: .semibold))
                        Text("Your real files, browser sessions and apps")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    Circle().fill(Theme.done).frame(width: 7, height: 7)
                }

                Divider().overlay(Theme.separator)

                permissionRow("Screen Recording", "so a bot can see the screen",
                              granted: permissions.screenRecording, pane: "Privacy_ScreenCapture")
                permissionRow("Accessibility", "so a bot can use the keyboard and mouse",
                              granted: permissions.accessibility, pane: "Privacy_Accessibility")
            }
            .padding(13)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 10) {
                Image(systemName: "cube").font(.system(size: 15)).foregroundStyle(Theme.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Container").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Text("A throwaway machine that cannot touch your Mac")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Text("Soon").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }
            .padding(13)
            .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 9))

            Spacer()
        }
        .padding(18)
        .onAppear { permissions = ComputerExecutor.permissions }
    }

    private func permissionRow(_ title: String, _ why: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(granted ? Theme.done : Theme.running)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(why).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if !granted {
                Button("Grant") {
                    ComputerExecutor.requestAccess()
                    ComputerExecutor.openPrivacySettings(pane)
                }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 11))
            }
        }
    }
}
