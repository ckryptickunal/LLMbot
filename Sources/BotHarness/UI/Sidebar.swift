import BotHarnessCore
import SwiftUI

/// The roster.
///
/// Rows are bots and channels, ordered by most recent activity. Each carries identity (avatar,
/// name) and just enough of the last message to know whether it needs you — which is what
/// makes a list of agents feel like a list of colleagues rather than a list of jobs.
struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var library: LibrarySheet.Tab?

    var body: some View {
        VStack(spacing: 0) {
            header
            search

            if filtered.isEmpty {
                EmptyState(
                    systemImage: query.isEmpty ? "person.2" : "magnifyingglass",
                    title: query.isEmpty ? "No bots yet" : "Nothing matches",
                    message: query.isEmpty
                        ? "Make one and tell it what you want done."
                        : "Try a different word.",
                    actionTitle: query.isEmpty ? "New bot" : nil,
                    action: query.isEmpty ? { store.createBot(name: "New Bot") } : nil
                )
                .padding(.horizontal, DS.Space.lg)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.hair) {
                        ForEach(filtered) { conversation in
                            SidebarRow(conversation: conversation)
                                .onTapGesture { store.selection = conversation.id }
                        }
                    }
                    .padding(.horizontal, DS.Space.md)
                    .padding(.top, DS.Space.xs)
                }
            }

            footer
        }
        .background(DS.Colour.panel)
        .sheet(item: $library) { LibrarySheet(tab: $0) }
    }

    private var filtered: [Conversation] {
        let all = store.sortedConversations
        guard !query.isEmpty else { return all }
        return all.filter { conversation in
            if title(for: conversation).localizedCaseInsensitiveContains(query) { return true }
            return conversation.messages.contains { message in
                if case .text(let text) = message.body {
                    return text.localizedCaseInsensitiveContains(query)
                }
                return false
            }
        }
    }

    private func title(for c: Conversation) -> String {
        c.title ?? store.bot(c.participants.first)?.name ?? "Untitled"
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Spacer()
            IconButton("plus", filled: false, help: "New bot (⌘N)") {
                store.createBot(name: "New Bot")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        // Leaves room for the traffic lights, since the title bar is hidden.
        .padding(.top, DS.Space.md)
        .frame(height: DS.Size.rowHeight)
    }

    private var search: some View {
        HStack(spacing: DS.Space.sm + 1) {
            Image(systemName: "magnifyingglass")
                .font(DS.Text.glyphTiny)
                .foregroundStyle(DS.Colour.inkTertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Text.secondary)
                .foregroundStyle(DS.Colour.ink)
        }
        .padding(.horizontal, DS.Space.md + 1)
        .padding(.vertical, DS.Space.sm + 1)
        .background(DS.Colour.fill, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.sm)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline()

            Button { library = .connections } label: {
                footerRow("app.connected.to.app.below.fill", "Connections")
            }
            .buttonStyle(.plain)

            Button { library = .computers } label: {
                footerRow("desktopcomputer", "Computers")
            }
            .buttonStyle(.plain)

            Menu {
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button("Skills…") { library = .skills }
                Button("Activity…") { openWindow(id: "activity") }
                Divider()
                Button("Open trace folder") { NSWorkspace.shared.open(Paths.traces) }
                Button("Open data folder") { NSWorkspace.shared.open(Paths.root) }
                Divider()
                Button("Quit Bot-Harness") { NSApp.terminate(nil) }
            } label: {
                footerRow("person.crop.circle", NSFullUserName())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.bottom, DS.Space.sm)
        }
    }

    private func footerRow(_ icon: String, _ label: String) -> some View {
        HStack(spacing: DS.Space.md + 1) {
            Image(systemName: icon)
                .font(DS.Text.glyph)
                .foregroundStyle(DS.Colour.inkSecondary)
                .frame(width: DS.Space.xl + 2)
            Text(label)
                .font(DS.Text.secondary)
                .foregroundStyle(DS.Colour.ink)
            Spacer()
        }
        .padding(.horizontal, DS.Space.lg + 2)
        .padding(.vertical, DS.Space.md + 1)
        .contentShape(Rectangle())
    }
}

// MARK: - One row

private struct SidebarRow: View {
    @Environment(Store.self) private var store
    let conversation: Conversation
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.lg - 2) {
            avatar
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.sm) {
                    Text(title)
                        .font(DS.Text.body.weight(.semibold))
                        .foregroundStyle(DS.Colour.ink)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                    Text(relativeTime)
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Colour.inkTertiary)
                        .fixedSize()
                }
                Text(preview)
                    .font(DS.Text.secondary)
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.lg - 2)
        .padding(.vertical, DS.Space.md + 1)
        .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dsAnimation(DS.Motion.instant, value: hovering)
    }

    private var background: Color {
        if isSelected { return DS.Colour.fillSelected }
        return hovering ? DS.Colour.fill : .clear
    }

    private var isSelected: Bool { store.selection == conversation.id }

    private var title: String {
        conversation.title ?? store.bot(conversation.participants.first)?.name ?? "Untitled"
    }

    /// Channels show stacked marks; a chat shows the bot's own.
    @ViewBuilder private var avatar: some View {
        if conversation.isChannel {
            ZStack(alignment: .leading) {
                ForEach(Array(conversation.participants.prefix(3).enumerated()), id: \.offset) { index, id in
                    Circle()
                        .fill(store.bot(id)?.tint ?? DS.Colour.inkTertiary)
                        .frame(width: DS.Size.avatar - 10, height: DS.Size.avatar - 10)
                        .overlay(Circle().stroke(DS.Colour.panel, lineWidth: 1.5))
                        .offset(x: CGFloat(index) * (DS.Space.md + 1))
                }
            }
            .frame(width: DS.Size.avatar + 2, height: DS.Size.avatar, alignment: .leading)
        } else {
            Circle()
                .fill(store.bot(conversation.participants.first)?.tint ?? DS.Colour.inkTertiary)
                .frame(width: DS.Size.avatar, height: DS.Size.avatar)
        }
    }

    private var preview: String {
        guard let last = conversation.messages.last else { return "No messages yet" }
        switch last.body {
        case .text(let t):       return t.replacingOccurrences(of: "\n", with: " ")
        case .toolUse(let a):    return a.summary
        case .computer(let a):   return a.task
        case .approval(let a):   return "Needs your approval — \(a.summary)"
        case .notice(let n):     return n
        case .failure(let f):    return f
        case .screenshot(let s): return s.caption
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.lastActivity, relativeTo: Date())
    }
}
