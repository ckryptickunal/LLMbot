import BotHarnessCore
import SwiftUI

@main
struct BotHarnessApp: App {
    @State private var store = Store()
    @State private var runner: BotRunner

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
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        Window("Activity", id: "activity") {
            ActivityWindow()
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView().environment(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot") { store.createBot(name: "New Bot") }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
