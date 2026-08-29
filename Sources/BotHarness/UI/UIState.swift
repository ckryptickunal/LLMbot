import SwiftUI
import Observation

/// Where the interface is pointing.
///
/// Kept in one observable object rather than threaded through as bindings, so that any view
/// can route somewhere without the views between it and the destination having to know. The
/// Computer card is the reason this exists: "Open computer" sits deep inside the message
/// list and has to reach the right-hand panel.
@MainActor
@Observable
final class UIState {
    enum Panel { case screen, settings }

    var panel: Panel = .screen
    var showPanel = true

    /// Reveal the bot's screen. Called from the Computer card.
    func openComputer() {
        panel = .screen
        showPanel = true
    }

    func openBotSettings() {
        panel = .settings
        showPanel = true
    }
}
