import SwiftUI

@main
struct BotHarnessApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
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
