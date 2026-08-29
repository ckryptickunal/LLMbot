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
        .frame(width: 560, height: 480)
        .background(DS.Colour.panel)
    }

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(DS.Motion.instant) { tab = item }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: item.icon).font(DS.Text.glyphSmall)
                        Text(item.title).font(DS.Text.secondary.weight(.medium))
                    }
                    .foregroundStyle(tab == item ? DS.Colour.ink : DS.Colour.inkSecondary)
                    .padding(.horizontal, DS.Space.lg - 1)
                    .padding(.vertical, DS.Space.sm)
                    .background(tab == item ? DS.Colour.fillSelected : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
            SecondaryButton("Done") { dismiss() }
        }
        .padding(.horizontal, DS.Space.lg + 2)
        .padding(.vertical, DS.Space.lg - 1)
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
                    .foregroundStyle(DS.Colour.inkSecondary)
                Spacer()
                if model.isRefreshing {
                    Spinner()
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
                        Skeleton(height: 46, radius: DS.Radius.md)
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
        .padding(DS.Space.xxl - 4)
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
        HStack(spacing: DS.Space.lg - 1) {
            Circle()
                .fill(colour)
                .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.sm) {
                    Text(name).font(DS.Text.secondary.weight(.medium)).foregroundStyle(DS.Colour.ink)
                    if toolCount > 0 {
                        Text("\(toolCount) tools")
                            .font(DS.Text.micro)
                            .foregroundStyle(DS.Colour.inkTertiary)
                    }
                }
                Text(detail)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Colour.inkTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: DS.Space.md)
            if let action = status.action {
                SecondaryButton(action) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json"))
                }
            } else {
                Text(status.displayName).font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
            }
        }
        .padding(DS.Space.lg - 1)
        .background(DS.Colour.fill, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private var colour: Color {
        switch status {
        case .healthy:                  return DS.Colour.done
        case .degraded:                 return DS.Colour.running
        case .needsAuth:                return DS.Colour.waiting
        case .initializing, .offline:   return DS.Colour.inkTertiary
        case .error:                    return DS.Colour.failed
        }
    }
}

// MARK: - Skills

private struct SkillsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Skills are short written procedures a bot loads only when they are relevant — how to work in a particular repository, how to deploy a particular app.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Colour.inkSecondary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

            EmptyState(systemImage: "sparkles",
                       title: "No skills yet",
                       message: "When a bot does something well more than once, you will be able to save it here and ask for it by name.")
        }
        .padding(DS.Space.xxl - 4)
    }
}

// MARK: - Computers

private struct ComputersList: View {
    @State private var permissions = ComputerExecutor.permissions

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            Text("Where your bots do their work.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Colour.inkSecondary)

            Surface(fill: DS.Colour.fill, bordered: false) {
                VStack(alignment: .leading, spacing: DS.Space.lg - 2) {
                    HStack(spacing: DS.Space.lg - 2) {
                        Image(systemName: "desktopcomputer")
                            .font(DS.Text.glyphLarge)
                            .foregroundStyle(DS.Colour.ink)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("This Mac").font(DS.Text.body.weight(.semibold))
                                .foregroundStyle(DS.Colour.ink)
                            Text("Your real files, browser sessions and apps")
                                .font(DS.Text.caption).foregroundStyle(DS.Colour.inkTertiary)
                        }
                        Spacer()
                        Circle().fill(DS.Colour.done)
                            .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
                    }

                    Hairline()

                    permissionRow("Screen Recording", "so a bot can see the screen",
                                  granted: permissions.screenRecording, pane: "Privacy_ScreenCapture")
                    permissionRow("Accessibility", "so a bot can use the keyboard and mouse",
                                  granted: permissions.accessibility, pane: "Privacy_Accessibility")
                }
            }

            Surface(fill: DS.Colour.fill.opacity(0.5), bordered: false) {
                HStack(spacing: DS.Space.lg - 2) {
                    Image(systemName: "cube")
                        .font(DS.Text.glyphLarge)
                        .foregroundStyle(DS.Colour.inkTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Container").font(DS.Text.body.weight(.medium))
                            .foregroundStyle(DS.Colour.inkSecondary)
                        Text("A throwaway machine that cannot touch your Mac")
                            .font(DS.Text.caption).foregroundStyle(DS.Colour.inkTertiary)
                    }
                    Spacer()
                    Text("Soon").font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
                        .padding(.horizontal, DS.Space.sm + 1)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Colour.fill, in: Capsule())
                }
            }

            Spacer()
        }
        .padding(DS.Space.xxl - 4)
        .onAppear { permissions = ComputerExecutor.permissions }
    }

    private func permissionRow(_ title: String, _ why: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: DS.Space.md + 1) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(DS.Text.glyph)
                .foregroundStyle(granted ? DS.Colour.done : DS.Colour.running)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Text.secondary).foregroundStyle(DS.Colour.ink)
                Text(why).font(DS.Text.micro).foregroundStyle(DS.Colour.inkTertiary)
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
