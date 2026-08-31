import BotHarnessCore
import SwiftUI
import AppKit

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
/// deliberately closed it themselves. The roster now works the same way in both directions:
/// before, every resize forced it back open over a deliberate collapse, and below the roster
/// threshold it vanished with the toggle removed and no way to bring it back.
struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    /// Below this, the three columns cannot coexist without clipping.
    private var inspectorThreshold: CGFloat {
        DS.Size.rosterMin + DS.Size.conversationMin + DS.Size.inspectorMin
    }
    private var rosterThreshold: CGFloat {
        DS.Size.rosterMin + DS.Size.conversationMin
    }

    var body: some View {
        @Bindable var ui = ui
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $ui.columns) {
                Sidebar()
                    .navigationSplitViewColumnWidth(
                        min: DS.Size.rosterMin,
                        ideal: DS.Size.rosterIdeal,
                        max: DS.Size.rosterMax
                    )
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
        .background(DS.Surface.ground)
        // The state file could not be read. Saying nothing here is the difference between
        // "my data is gone" and "my data is at this path".
        .sheet(isPresented: Binding(get: { store.loadFailure != nil },
                                    set: { if !$0 { store.acknowledgeLoadFailure() } })) {
            if let failure = store.loadFailure { RecoveredStateSheet(failure: failure) }
        }
    }

    /// The inspector may only be open when it fits, whatever the stored preference says.
    private func inspectorBinding(width: CGFloat) -> Binding<Bool> {
        Binding(
            get: { ui.showPanel && width >= inspectorThreshold },
            set: { ui.showPanel = $0; ui.panelClosedByWindow = false }
        )
    }

    /// Remembers whether each column was closed by the window or by the person.
    ///
    /// Without the distinction, narrowing the window and widening it again either loses a
    /// column the user wanted or reopens one they had deliberately dismissed.
    private func adapt(to width: CGFloat) {
        let inspectorFits = width >= inspectorThreshold
        if !inspectorFits, ui.showPanel {
            ui.showPanel = false
            ui.panelClosedByWindow = true
        } else if inspectorFits, ui.panelClosedByWindow {
            ui.showPanel = true
            ui.panelClosedByWindow = false
        }

        let rosterFits = width >= rosterThreshold
        if !rosterFits, ui.columns != .detailOnly {
            ui.columns = .detailOnly
            ui.rosterClosedByWindow = true
        } else if rosterFits, ui.rosterClosedByWindow {
            ui.columns = .all
            ui.rosterClosedByWindow = false
        }
    }
}

/// What the app says when it could not read its own state file.
///
/// Re-seeding in silence is the worst possible presentation: the user opens the app after an
/// update, finds a stranger bot and an empty roster, and has every reason to believe their work
/// is gone. It is not — and this is where it went.
private struct RecoveredStateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let failure: Store.LoadFailure

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Label("Your bots could not be opened", systemImage: "exclamationmark.triangle.fill")
                .font(DS.Text.title)
                .foregroundStyle(DS.Status.running.mark)

            Text("Nothing was deleted. The file this app keeps your bots in could not be read, "
               + "so it was set aside under a new name and the app started fresh. You can open "
               + "the folder to keep the old file or pass it on to be looked at.")
                .font(DS.Text.callout)
                .foregroundStyle(DS.Ink.secondary)
                .lineSpacing(DS.Text.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Saved as").font(DS.Text.caption).foregroundStyle(DS.Ink.secondary)
                Text(failure.movedTo.lastPathComponent)
                    .font(DS.Text.monoSmall)
                    .foregroundStyle(DS.Ink.primary)
                    .textSelection(.enabled)
            }

            HStack(spacing: DS.Space.md) {
                SecondaryButton("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([failure.movedTo])
                }
                Spacer()
                PrimaryButton("Continue") { dismiss() }
            }
        }
        .dsInset(DS.Inset.pane)
        .frame(width: DS.Window.sheetWidth)
        .background(DS.Surface.panel)
    }
}
