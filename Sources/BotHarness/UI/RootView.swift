import BotHarnessCore
import SwiftUI

/// The cockpit.
///
/// Built on `NavigationSplitView` plus `.inspector` rather than three fixed-width columns, so
/// the divider drags, the width is remembered, and the sidebar collapses the way people expect
/// from a Mac app.
///
/// The part that needed care: **a split view compresses its columns rather than dropping one.**
/// Below about 1,100 points the roster, the conversation and the inspector cannot all have
/// their minimum width, and AppKit's answer is to squeeze all three past their minimums until
/// the content clips off both edges of the window. So the inspector is closed automatically
/// when there is not room for it, and restored when there is — but only if the person had not
/// deliberately closed it themselves.
struct RootView: View {
    @Environment(Store.self) private var store
    @State private var ui = UIState()
    @State private var columns: NavigationSplitViewVisibility = .all

    /// Below this, the three columns cannot coexist without clipping.
    private var inspectorThreshold: CGFloat {
        DS.Size.rosterMin + DS.Size.conversationMin + DS.Size.inspectorMin
    }

    var body: some View {
        GeometryReader { geo in
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
                    .frame(minWidth: DS.Size.conversationMin)
                    .inspector(isPresented: inspectorBinding(width: geo.size.width)) {
                        ContextPanelView()
                            .inspectorColumnWidth(
                                min: DS.Size.inspectorMin,
                                ideal: DS.Size.inspectorIdeal,
                                max: DS.Size.inspectorMax
                            )
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: geo.size.width, initial: true) { _, width in
                adapt(to: width)
            }
        }
        .environment(ui)
        .background(DS.Surface.ground)
    }

    /// The inspector may only be open when it fits, whatever the stored preference says.
    private func inspectorBinding(width: CGFloat) -> Binding<Bool> {
        Binding(
            get: { ui.showPanel && width >= inspectorThreshold },
            set: { ui.showPanel = $0 }
        )
    }

    /// Remembers whether the panel was closed by the window or by the person.
    ///
    /// Without the distinction, narrowing the window and widening it again either loses a
    /// panel the user wanted or reopens one they had deliberately dismissed.
    private func adapt(to width: CGFloat) {
        let fits = width >= inspectorThreshold
        if !fits, ui.showPanel {
            ui.showPanel = false
            ui.panelClosedByWindow = true
        } else if fits, ui.panelClosedByWindow {
            ui.showPanel = true
            ui.panelClosedByWindow = false
        }

        // The roster goes too when even two columns will not fit.
        columns = width < DS.Size.rosterMin + DS.Size.conversationMin ? .detailOnly : .all
    }
}
