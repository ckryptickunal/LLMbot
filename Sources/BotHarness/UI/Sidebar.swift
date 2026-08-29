import BotHarnessCore
import SwiftUI

/// The roster.
///
/// Rows are bots and channels, ordered by most recent activity. Each carries identity (avatar,
/// name) and just enough of the last message to know whether it needs you — which is what
/// makes a list of agents feel like a list of colleagues rather than a list of jobs.
struct Sidebar: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
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
                        // Deliberately not staggered. This list re-renders on every search
                        // keystroke and every window resize, and an entrance animation on a
                        // list that re-renders is an animation that hides content.
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
        // No background: the roster is the functional layer and inherits the window's
        // material, which is what makes it read as a native sidebar.
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
                ui.focusComposer()
            }
        }
        .padding(.horizontal, DS.Space.lg)

        .frame(height: DS.Size.rosterRow)
    }

    private var search: some View {
        HStack(spacing: DS.Space.sm + 1) {
            Image(systemName: "magnifyingglass")
                .font(DS.Text.glyphSmall)
                .foregroundStyle(DS.Ink.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.primary)
        }
        .padding(.horizontal, DS.Space.md + 1)
        .padding(.vertical, DS.Space.sm + 1)
        .background(DS.Tint.t3, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
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
            // Without this the menu sizes to its label and centres, so the account row stops
            // sharing a left edge with the two rows above it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, DS.Space.sm)
        }
    }

    private func footerRow(_ icon: String, _ label: String) -> some View {
        HStack(spacing: DS.Space.md + 1) {
            Image(systemName: icon)
                .font(DS.Text.glyph)
                .foregroundStyle(DS.Ink.secondary)
                .frame(width: DS.Space.xl + 2)
            Text(label)
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.primary)
            Spacer()
        }
        .padding(.horizontal, DS.Space.lg + 2)
        .frame(height: DS.Size.connectionRow, alignment: .leading)
        .hoverRow(shape: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .contentShape(Rectangle())
    }
}

// MARK: - One row

private struct SidebarRow: View {
    @Environment(Store.self) private var store
    let conversation: Conversation

    var body: some View {
        HStack(spacing: DS.Space.lg - 2) {
            avatar
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                HStack(spacing: DS.Space.sm) {
                    Text(title)
                        .font(DS.Text.body.weight(.semibold))
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                    Text(relativeTime)
                        .font(DS.Text.micro)
                        .foregroundStyle(DS.Ink.tertiary)
                        .fixedSize()
                }
                Text(preview)
                    .font(DS.Text.callout)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .dsInset(DS.Inset.row)
        .hoverRow(resting: isSelected ? DS.Surface.active : .clear)
        .contentShape(Rectangle())
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
                    if let member = store.bot(id) {
                        BotAvatar(bot: member, size: DS.Size.avatarRoster - 6)
                            .overlay(Circle().stroke(DS.Surface.panel, lineWidth: 1.5))
                            .offset(x: CGFloat(index) * (DS.Space.md + 1))
                    }
                }
            }
            .frame(width: DS.Size.avatarRoster + DS.Space.md, height: DS.Size.avatarRoster,
                   alignment: .leading)
        } else {
            if let bot = store.bot(conversation.participants.first) {
                BotAvatar(bot: bot, size: DS.Size.avatarRoster)
            } else {
                Circle().fill(DS.Tint.t3)
                    .frame(width: DS.Size.avatarRoster, height: DS.Size.avatarRoster)
            }
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
