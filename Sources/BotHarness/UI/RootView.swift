import BotHarnessCore
import SwiftUI

/// The three-column cockpit.
///
/// Left: the roster. Centre: the conversation. Right: the bot's screen or its settings. This
/// is Grok Bot's arrangement, and it is right for the same reason theirs is — the product is
/// a messaging app whose contacts happen to be agents, so the conversation gets the middle and
/// everything else gets out of its way.
struct RootView: View {
    @Environment(Store.self) private var store
    @State private var ui = UIState()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: DS.Size.sidebar)

            verticalHairline

            ConversationView()
                .frame(maxWidth: .infinity)

            if ui.showPanel {
                verticalHairline
                ContextPanelView()
                    .frame(width: DS.Size.inspector)
                    // Slides from its own edge, so the panel appears to come from where it
                    // lives rather than fading in from nowhere.
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(DS.Colour.ground)
        .environment(ui)
        .dsAnimation(DS.Motion.surface, value: ui.showPanel)
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(DS.Colour.line)
            .frame(width: DS.Size.hairline)
    }
}
