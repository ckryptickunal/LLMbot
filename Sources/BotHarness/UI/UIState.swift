import SwiftUI
import Observation

/// Where the interface is pointing, and everything it remembers that is not worth saving.
///
/// Kept in one observable object rather than threaded through as bindings, so that any view can
/// route somewhere without the views between it and the destination having to know. The
/// Computer card is the reason this exists: "Open computer" sits deep inside the message list
/// and has to reach the right-hand panel.
///
/// **There is exactly one of these, created by `BotHarnessApp` and injected once.** A second
/// instance created further down the tree shadows the first for everything below it, so half
/// the app mutates one object and half reads the other — which is what happened here, and why
/// the Cmd-N focus request went to an object nobody was observing.
@MainActor
@Observable
final class UIState {
    enum Panel { case screen, settings }

    var panel: Panel = .screen
    var showPanel = true

    /// True when the window closed the inspector because it did not fit, as opposed to the
    /// person closing it. Only the first case is reopened automatically.
    var panelClosedByWindow = false

    /// Same distinction for the roster: a sidebar the window collapsed comes back, a sidebar
    /// the person collapsed stays collapsed.
    var columns: NavigationSplitViewVisibility = .all
    var rosterClosedByWindow = false

    // MARK: Focus

    /// Bumped whenever something should put the cursor back in the composer.
    ///
    /// A counter rather than a Bool: setting a flag that is already true changes nothing, so
    /// two consecutive "focus the composer" requests would only work once. Creating a bot with
    /// ⌘N and then typing was exactly that case — the field never took focus and the app
    /// looked broken.
    var focusComposerRequests = 0
    /// The same, for the roster's search field, so ⌘F has somewhere to land.
    var focusSearchRequests = 0

    /// The same again, for the menu bar's New Channel command. A channel is created through a
    /// sheet that needs to name it and pick members, and that sheet lives in the roster — so the
    /// menu raises a signal rather than trying to reach into the roster's own state.
    var newChannelRequests = 0

    func focusComposer() { focusComposerRequests += 1 }
    func focusSearch() { focusSearchRequests += 1 }
    func newChannel() { newChannelRequests += 1 }

    // MARK: Drafts

    /// Unsent text, per conversation.
    ///
    /// One shared draft used to follow the user between conversations: type half a message to
    /// one bot, click another, and the text was sitting in the second bot's composer one Return
    /// away from going to the wrong place. Deliberately not persisted — an unsent message is a
    /// thought in progress, not a document.
    private var drafts: [UUID: String] = [:]

    func draft(for id: UUID?) -> String {
        guard let id else { return "" }
        return drafts[id] ?? ""
    }

    func setDraft(_ text: String, for id: UUID?) {
        guard let id else { return }
        if text.isEmpty { drafts.removeValue(forKey: id) } else { drafts[id] = text }
    }

    /// A binding the composer can use directly, which reads and writes the right conversation's
    /// draft even as the selection changes underneath it.
    func draftBinding(for id: UUID?) -> Binding<String> {
        Binding(get: { self.draft(for: id) }, set: { self.setDraft($0, for: id) })
    }

    func discardDrafts(for ids: [UUID]) {
        for id in ids { drafts.removeValue(forKey: id) }
    }

    // MARK: Routing

    /// Reveal the bot's screen. Called from the Computer card.
    func openComputer() {
        panel = .screen
        showPanel = true
        panelClosedByWindow = false
    }

    func openBotSettings() {
        panel = .settings
        showPanel = true
        panelClosedByWindow = false
    }
}
