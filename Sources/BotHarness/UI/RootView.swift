import BotHarnessCore
import SwiftUI

/// The three-column cockpit.
///
/// Left: the roster of bots and channels. Centre: the conversation. Right: either the bot's
/// screen or its settings. This is Grok Bot's arrangement, and it is right for the same
/// reason theirs is: the product is a messaging app whose contacts happen to be agents, so
/// the conversation gets the middle and everything else gets out of its way.
struct RootView: View {
    @Environment(Store.self) private var store
    @State private var ui = UIState()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Theme.sidebarWidth)

            Divider().overlay(Theme.separator)

            ConversationView()
                .frame(maxWidth: .infinity)

            if ui.showPanel {
                Divider().overlay(Theme.separator)
                ContextPanelView()
                    .frame(width: Theme.contextWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.ground)
        .environment(ui)
        .animation(Motion.occasional, value: ui.showPanel)
    }
}
