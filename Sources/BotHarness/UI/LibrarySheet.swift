import SwiftUI
import Observation
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
            Divider().overlay(DS.Colour.line)
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
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { t in
                Button {
                    withAnimation(DS.Motion.instant) { tab = t }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 11))
                        Text(t.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(tab == t ? DS.Colour.ink : DS.Colour.inkSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(tab == t ? Color.white.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PressableStyle())
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Connections

/// What your bots can reach, and the true state of each.
///
/// Driven by the capability registry connecting to real servers, not by a hardcoded list. A
/// connector that needs a key, or whose app is not running, stays visible and says so with an
/// action next to it — removing it would make the system look like it never supported the
/// thing, which is both untrue and unfixable from here.
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
            let summary = all.first { $0.provider == entry.provider }?.summary
                ?? entry.health.detail
            return Row(id: entry.provider, name: entry.name, health: entry.health, summary: summary)
        }
    }
}

private struct ConnectionsList: View {
    @State private var model = ConnectionsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What your bots can reach. Model keys are in Settings (⌘,).")
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colour.inkSecondary)
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Button("Refresh") { Task { await model.refresh() } }
                        .buttonStyle(PressableStyle())
                        .font(.system(size: 11))
                }
            }

            section("Always available")
            ForEach(model.builtIn) { capability in
                row(name: capability.id.replacingOccurrences(of: "computer.", with: "")
                        .replacingOccurrences(of: "development.", with: "")
                        .replacingOccurrences(of: "research.", with: "").capitalized,
                    detail: capability.summary,
                    status: .healthy, action: nil)
            }

            section("Connectors")
            if model.rows.isEmpty && !model.isRefreshing {
                Text("No connectors configured yet.")
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colour.inkTertiary)
            }
            ForEach(model.rows) { entry in
                row(name: entry.name,
                    detail: entry.health.status.isUsable
                        ? entry.summary
                        : entry.health.detail,
                    status: entry.health.status,
                    action: entry.health.status.action,
                    toolCount: entry.health.toolCount)
            }
        }
        .padding(18)
        .task { await model.refresh() }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.Colour.inkTertiary)
            .padding(.top, 4)
    }

    private func row(name: String, detail: String, status: ProviderHealth.Status,
                     action: String?, toolCount: Int = 0) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(colour(status))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DS.Colour.ink)
                    if toolCount > 0 {
                        Text("\(toolCount) tools")
                            .font(.system(size: 10)).foregroundStyle(DS.Colour.inkTertiary)
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(DS.Colour.inkTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json"))
                }
                .buttonStyle(PressableStyle())
                .font(.system(size: 11))
            } else {
                Text(status.displayName)
                    .font(.system(size: 10.5)).foregroundStyle(DS.Colour.inkTertiary)
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func colour(_ status: ProviderHealth.Status) -> Color {
        switch status {
        case .healthy:      return DS.Colour.done
        case .degraded:     return DS.Colour.running
        case .needsAuth:    return DS.Colour.waiting
        case .initializing: return DS.Colour.inkTertiary
        case .offline:      return DS.Colour.inkTertiary
        case .error:        return DS.Colour.failed
        }
    }
}

// MARK: - Skills

private struct SkillsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skills are short written procedures a bot loads only when they are relevant — how to work in a particular repository, how to deploy a particular app.")
                .font(.system(size: 11.5)).foregroundStyle(DS.Colour.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22)).foregroundStyle(DS.Colour.inkTertiary)
                Text("No skills yet").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colour.ink)
                Text("When a bot does something well more than once, you will be able to save it here and ask for it by name.")
                    .font(.system(size: 11.5)).foregroundStyle(DS.Colour.inkTertiary)
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
                .font(.system(size: 11.5)).foregroundStyle(DS.Colour.inkSecondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.system(size: 15))
                        .foregroundStyle(DS.Colour.ink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("This Mac").font(.system(size: 13, weight: .semibold))
                        Text("Your real files, browser sessions and apps")
                            .font(.system(size: 11)).foregroundStyle(DS.Colour.inkTertiary)
                    }
                    Spacer()
                    Circle().fill(DS.Colour.done).frame(width: 7, height: 7)
                }

                Divider().overlay(DS.Colour.line)

                permissionRow("Screen Recording", "so a bot can see the screen",
                              granted: permissions.screenRecording, pane: "Privacy_ScreenCapture")
                permissionRow("Accessibility", "so a bot can use the keyboard and mouse",
                              granted: permissions.accessibility, pane: "Privacy_Accessibility")
            }
            .padding(13)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 10) {
                Image(systemName: "cube").font(.system(size: 15)).foregroundStyle(DS.Colour.inkTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Container").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colour.inkSecondary)
                    Text("A throwaway machine that cannot touch your Mac")
                        .font(.system(size: 11)).foregroundStyle(DS.Colour.inkTertiary)
                }
                Spacer()
                Text("Soon").font(.system(size: 10.5)).foregroundStyle(DS.Colour.inkTertiary)
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
                .foregroundStyle(granted ? DS.Colour.done : DS.Colour.running)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(why).font(.system(size: 10.5)).foregroundStyle(DS.Colour.inkTertiary)
            }
            Spacer()
            if !granted {
                Button("Grant") {
                    ComputerExecutor.requestAccess()
                    ComputerExecutor.openPrivacySettings(pane)
                }
                .buttonStyle(PressableStyle())
                .font(.system(size: 11))
            }
        }
    }
}
