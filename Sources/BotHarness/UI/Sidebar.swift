import BotHarnessCore
import SwiftUI

/// The roster.
///
/// Rows are bots and channels, ordered by most recent activity. Each row carries the identity
/// (avatar, name) and just enough of the last message to know whether it needs you — which is
/// what makes a list of agents feel like a list of colleagues rather than a list of jobs.
struct Sidebar: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var library: LibrarySheet.Tab?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            search

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { conversation in
                        SidebarRow(conversation: conversation)
                            .onTapGesture { store.selection = conversation.id }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
            footer
        }
        .background(DS.Colour.panel)
        .sheet(item: $library) { tab in LibrarySheet(tab: tab) }
    }

    private var filtered: [Conversation] {
        let all = store.sortedConversations
        guard !query.isEmpty else { return all }
        return all.filter { conversation in
            let name = title(for: conversation)
            if name.localizedCaseInsensitiveContains(query) { return true }
            return conversation.messages.contains { message in
                if case .text(let t) = message.body {
                    return t.localizedCaseInsensitiveContains(query)
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
            Button {
                store.createBot(name: "New Bot")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("New bot (⌘N)")
        }
        .padding(.horizontal, 12)
        // Leaves room for the traffic lights, since the title bar is hidden.
        .padding(.top, 8)
        .frame(height: 44)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colour.inkTertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colour.ink)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().overlay(DS.Colour.line)
            Button { library = .connections } label: {
                footerRow(icon: "app.connected.to.app.below.fill", label: "Connections")
            }
            .buttonStyle(.plain)

            Button { library = .computers } label: {
                footerRow(icon: "desktopcomputer", label: "Computers")
            }
            .buttonStyle(.plain)

            Menu {
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button("Skills…") { library = .skills }
                Button("Activity…") { openWindow(id: "activity") }
                Divider()
                Button("Open trace folder") {
                    NSWorkspace.shared.open(Paths.traces)
                }
                Button("Open data folder") {
                    NSWorkspace.shared.open(Paths.root)
                }
                Divider()
                Button("Quit Bot-Harness") { NSApp.terminate(nil) }
            } label: {
                footerRow(icon: "person.crop.circle", label: NSFullUserName())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.bottom, 6)
        }
    }

    private func footerRow(icon: String, label: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colour.inkSecondary)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colour.ink)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct SidebarRow: View {
    @Environment(Store.self) private var store
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colour.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(relativeTime)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colour.inkTertiary)
                        .fixedSize()
                }
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colour.inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.07) : .clear)
        )
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
                ForEach(Array(conversation.participants.prefix(3).enumerated()), id: \.offset) { i, id in
                    Circle()
                        .fill(store.bot(id)?.tint ?? DS.Colour.inkTertiary)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(DS.Colour.panel, lineWidth: 1.5))
                        .offset(x: CGFloat(i) * 9)
                }
            }
            .frame(width: 32, height: 32, alignment: .leading)
        } else {
            Circle()
                .fill(store.bot(conversation.participants.first)?.tint ?? DS.Colour.inkTertiary)
                .frame(width: 30, height: 30)
        }
    }

    private var preview: String {
        guard let last = conversation.messages.last else { return "No messages yet" }
        switch last.body {
        case .text(let t):      return t.replacingOccurrences(of: "\n", with: " ")
        case .toolUse(let a):   return a.summary
        case .computer(let a):  return a.task
        case .approval(let a):  return "Needs your approval — \(a.summary)"
        case .notice(let n):    return n
        case .failure(let f):   return f
        case .screenshot(let s): return s.caption
        }
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: conversation.lastActivity, relativeTo: Date())
    }
}
