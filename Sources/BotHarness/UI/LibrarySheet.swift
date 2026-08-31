import AppKit
import BotHarnessCore
import Observation
import SwiftUI

/// Connections, Skills and Computers.
///
/// Everything a bot can reach, in one place, stated honestly. Where something is not built yet
/// the row says so — a control that looks live and does nothing is worse than one admitting it
/// is coming, because the first teaches people not to trust the interface.
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
            Hairline()
            ScrollView {
                switch tab {
                case .connections: ConnectionsList()
                case .skills:      SkillsList()
                case .computers:   ComputersList()
                }
            }
        }
        .frame(width: DS.Window.sheetWidth, height: DS.Window.sheetHeight)
        .background(DS.Surface.panel)
    }

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(DS.Motion.instant) { tab = item }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: item.icon).font(DS.Text.glyphSmall)
                        Text(item.title).font(DS.Text.callout.weight(.medium))
                    }
                    .foregroundStyle(tab == item ? DS.Ink.primary : DS.Ink.secondary)
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.vertical, DS.Space.sm)
                    .background(tab == item ? DS.Tint.t5 : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
            SecondaryButton("Done") { dismiss() }
                // Escape closes it. A sheet whose only exit is one button is a sheet people
                // feel trapped in, and it is a direct HIG violation.
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.lg)
    }
}

// MARK: - Connections

/// What your bots can reach, and the true state of each.
///
/// Driven by the capability registry connecting to real servers, not by a hardcoded list. A
/// connector that needs a key, or whose app is closed, stays visible and says so with an action
/// next to it — removing it would make the system look like it never supported the thing,
/// which is untrue and unfixable from here.
@MainActor
@Observable
final class ConnectionsModel {
    struct Row: Identifiable {
        var id: String
        var name: String
        var health: ProviderHealth
        var summary: String
    }

    private let registry = CapabilityRegistry()
    private(set) var rows: [Row] = []
    private(set) var isRefreshing = false
    private(set) var builtIn: [Capability] = []

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await registry.registerConfiguredMCPServers()
        builtIn = await registry.all().filter { $0.provider == "builtin" }

        let report = await registry.discoverAll()
        let all = await registry.all()
        rows = report.map { entry in
            Row(id: entry.provider, name: entry.name, health: entry.health,
                summary: all.first { $0.provider == entry.provider }?.summary ?? entry.health.detail)
        }
    }
}

private struct ConnectionsList: View {
    @State private var model = ConnectionsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack {
                Text("What your bots can reach. Model keys are in Settings (⌘,).")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                Spacer()
                if model.isRefreshing {
                    DelayedSpinner()
                } else {
                    SecondaryButton("Refresh") { Task { await model.refresh() } }
                }
            }

            SectionLabel("Always available")
            ForEach(model.builtIn) { capability in
                ConnectionRow(name: displayName(capability),
                              detail: capability.summary,
                              status: .healthy, toolCount: 0)
            }

            SectionLabel("Connectors")
            if model.isRefreshing && model.rows.isEmpty {
                // Shaped like the rows that are coming, so nothing jumps when they land.
                VStack(spacing: DS.Space.md) {
                    ForEach(0..<3, id: \.self) { _ in
                        Skeleton(height: DS.Size.connectionRow + DS.Space.xl, radius: DS.Radius.md)
                    }
                }
            } else if model.rows.isEmpty {
                EmptyState(systemImage: "app.connected.to.app.below.fill",
                           title: "No connectors yet",
                           message: "Connectors you configure for other tools on this Mac appear here automatically.")
            }
            ForEach(model.rows) { entry in
                ConnectionRow(name: entry.name,
                              detail: entry.health.status.isUsable ? entry.summary : entry.health.detail,
                              status: entry.health.status,
                              toolCount: entry.health.toolCount)
            }
        }
        .dsInset(DS.Inset.pane)
        .task { await model.refresh() }
    }

    private func displayName(_ capability: Capability) -> String {
        capability.id
            .replacingOccurrences(of: "computer.", with: "")
            .replacingOccurrences(of: "development.", with: "")
            .replacingOccurrences(of: "research.", with: "")
            .capitalized
    }
}

private struct ConnectionRow: View {
    let name: String
    let detail: String
    let status: ProviderHealth.Status
    let toolCount: Int

    var body: some View {
        HStack(spacing: DS.Space.lg) {
            Circle()
                .fill(colour)
                .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.sm) {
                    Text(name).font(DS.Text.callout.weight(.medium)).foregroundStyle(DS.Ink.primary)
                    if toolCount > 0 {
                        Text("\(toolCount) tools")
                            .font(DS.Text.micro)
                            .foregroundStyle(DS.Ink.secondary)
                    }
                }
                Text(detail)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Space.md)
            if let action = status.action {
                SecondaryButton(action) {
                    // Reveal rather than open: dropping someone into a raw JSON file in
                    // whatever app claims the extension, with no indication of what to change,
                    // is not help. Showing them where it lives at least orients them.
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")])
                }
                .help("Shows the configuration file for connectors in the Finder")
            } else {
                Text(status.displayName).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
            }
        }
        .padding(DS.Space.lg)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private var colour: Color {
        switch status {
        case .healthy:                  return DS.Status.done.mark
        case .degraded:                 return DS.Status.running.mark
        case .needsAuth:                return DS.Status.waiting.mark
        case .initializing, .offline:   return DS.Ink.secondary
        case .error:                    return DS.Status.failed.mark
        }
    }
}

// MARK: - Skills

private struct SkillsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Skills are short written procedures a bot loads only when they are relevant — how to work in a particular repository, how to deploy a particular app.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

            EmptyState(systemImage: "sparkles",
                       title: "No skills yet",
                       message: "When a bot does something well more than once, you will be able to save it here and ask for it by name.")
        }
        .dsInset(DS.Inset.pane)
    }
}

// MARK: - Computers

private struct ComputersList: View {
    @State private var permissions = ComputerExecutor.permissions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Text("Where your bots do their work.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Ink.secondary)

            Surface(fill: DS.Tint.t3, bordered: false) {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    HStack(spacing: DS.Space.lg) {
                        Image(systemName: "desktopcomputer")
                            .font(DS.Text.glyph)
                            .foregroundStyle(DS.Ink.primary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("This Mac").font(DS.Text.body.weight(.semibold))
                                .foregroundStyle(DS.Ink.primary)
                            Text("Your real files, browser sessions and apps")
                                .font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
                        }
                        Spacer()
                        Circle().fill(DS.Status.done.mark)
                            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    }

                    Hairline()

                    permissionRow("Screen Recording", "so a bot can see the screen",
                                  granted: permissions.screenRecording, pane: "Privacy_ScreenCapture")
                    permissionRow("Accessibility", "so a bot can use the keyboard and mouse",
                                  granted: permissions.accessibility, pane: "Privacy_Accessibility")
                }
            }

            Surface(fill: DS.Tint.t3.opacity(0.5), bordered: false) {
                HStack(spacing: DS.Space.lg) {
                    Image(systemName: "cube")
                        .font(DS.Text.glyph)
                        .foregroundStyle(DS.Ink.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Container").font(DS.Text.body.weight(.medium))
                            .foregroundStyle(DS.Ink.secondary)
                        Text("A throwaway machine that cannot touch your Mac")
                            .font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
                    }
                    Spacer()
                    Text("Soon").font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Tint.t3, in: Capsule())
                }
            }

            Spacer()
        }
        .dsInset(DS.Inset.pane)
        .onAppear { permissions = ComputerExecutor.permissions }
        // Granting a permission happens in System Settings, which means leaving this app and
        // coming back. Re-checking only on first appearance meant the row still said
        // "not granted" after the user had just granted it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions = ComputerExecutor.permissions
        }
    }

    private func permissionRow(_ title: String, _ why: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(DS.Text.glyph)
                .foregroundStyle(granted ? DS.Status.done.mark : DS.Status.running.mark)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Text.callout).foregroundStyle(DS.Ink.primary)
                Text(why).font(DS.Text.micro).foregroundStyle(DS.Ink.secondary)
            }
            Spacer()
            if !granted {
                SecondaryButton("Grant") {
                    ComputerExecutor.requestAccess()
                    ComputerExecutor.openPrivacySettings(pane)
                }
            }
        }
    }
}
