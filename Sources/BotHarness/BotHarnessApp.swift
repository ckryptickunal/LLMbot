import BotHarnessCore
import SwiftUI

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

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot") {
                    store.createBot(name: "New Bot")
                    // Without this the new conversation opens with nothing focused, so the
                    // very next thing the user does — type — goes nowhere.
                    ui.focusComposer()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
