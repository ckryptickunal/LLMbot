import BotHarnessCore
import SwiftUI
import AppKit

@main
struct BotHarnessApp: App {
    @State private var store: Store
    @State private var runner: BotRunner
    @State private var ui = UIState()

    init() {
        let store = Store()
        _store = State(initialValue: store)
        _runner = State(initialValue: BotRunner(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(runner)
                .environment(ui)
                // Not an arbitrary number: the roster plus a readable transcript. Anything
                // narrower cannot be laid out without clipping, so the window refuses it
                // rather than showing a broken layout.
                .frame(minWidth: DS.Size.rosterMin + DS.Size.conversationMin,
                       minHeight: DS.Window.mainMinHeight)
                // The system is designed for one mode. Following the OS here would mean
                // designing a second palette that nobody has designed.
                .preferredColorScheme(.dark)
                // Everything else is debounced by 400 ms. Answering an approval and pressing
                // Cmd-Q inside that window used to lose the answer: the loop had it, the disk
                // did not. Quitting and losing focus are the two moments a write cannot wait.
                //
                // The two moments do not want the same call. `saveNow` encodes and writes on a
                // background queue — which is right, because the document is every message the
                // user has ever sent and encoding it on the main actor stalled typing — but it
                // means `flush` returns before the bytes exist. At termination the process is
                // about to stop, so returning early is losing the write; `saveAndWait` blocks
                // until it is on disk. Losing focus is not an ending, so it stays asynchronous
                // and the app does not freeze on every ⌘-Tab.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in store.saveAndWait() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willResignActiveNotification)) { _ in store.flush() }
        }
        // A unified toolbar rather than a hidden title bar: the split view now supplies
        // real chrome, and hiding it was what forced the hand-rolled traffic-light padding.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: DS.Window.mainWidth, height: DS.Window.mainHeight)

        /// Every run, every step. See `ActivityWindow`.
        Window("Activity", id: "activity") {
            ActivityWindow()
        }
        .defaultSize(width: DS.Window.activityWidth, height: DS.Window.activityHeight)

        Settings {
            SettingsView().environment(store)
        }

        // Restored deliberately. This block was lost during a parallel edit, and losing it takes
        // ⌘N with it — the only keyboard route to a new bot, and the one an empty roster tells
        // people to use.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot") {
                    store.createBot(name: "New Bot")
                    // Without this the new conversation opens with nothing focused, so the
                    // very next thing the user does — type — goes nowhere.
                    ui.focusComposer()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Channel…") { ui.newChannel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
