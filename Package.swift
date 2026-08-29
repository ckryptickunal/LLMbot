// swift-tools-version: 6.0
import PackageDescription

// Bot-Harness is deliberately dependency-free. Every capability it needs — HTTPS and SSE,
// JSON, the Keychain, screen capture, input synthesis, accessibility, subprocesses, and
// WebSockets for Chrome DevTools Protocol — exists in the macOS SDK. Adding a package here
// means adding something a user has to trust, so it requires an ADR.
let package = Package(
    name: "BotHarness",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that is not the interface: models, the agent loop, brains, executors,
        // the trace. Free of SwiftUI on purpose — that is what lets the tests and the eval
        // harness link it, which an executable containing SwiftUI views cannot be.
        .target(
            name: "BotHarnessCore",
            path: "Sources/BotHarnessCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BotHarness",
            dependencies: ["BotHarnessCore"],
            path: "Sources/BotHarness",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Probe",
            path: "Sources/Probe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BotHarnessTests",
            dependencies: ["BotHarnessCore"],
            path: "Tests/BotHarnessTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
