import BotHarnessCore
import SwiftUI

/// The cockpit.
///
/// Built on `NavigationSplitView` plus `.inspector` rather than three fixed-width columns in an
/// `HStack`. That was the source of most of what felt cheap: at 900 points the panes squeezed
/// the conversation into a gutter, and at 2000 they stretched prose across the whole display.
/// The native containers bring the behaviour people already expect from a Mac app — a
/// draggable divider, a width the system remembers, a sidebar that collapses when the window
/// gets narrow, and an inspector that gets out of the way.
///
/// The widths come from `DS.Size`, which had defined `rosterMin`, `rosterIdeal`, `rosterMax`
/// and `inspectorMin` all along. They were simply never wired to anything.
struct RootView: View {
    @Environment(Store.self) private var store
    @State private var ui = UIState()
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(
                    min: DS.Size.rosterMin,
                    ideal: DS.Size.rosterIdeal,
                    max: DS.Size.rosterMax
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ConversationView()
                .inspector(isPresented: $ui.showPanel) {
                    ContextPanelView()
                        .inspectorColumnWidth(
                            min: DS.Size.inspectorMin,
                            ideal: DS.Size.inspectorIdeal,
                            max: DS.Size.inspectorMax
                        )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(ui)
        .background(DS.Surface.ground)
    }
}
