# Build environment — verified facts

Everything here was executed on this machine on 2026-08-29. Nothing is assumed.
Re-run `scripts/doctor.sh` to re-verify after any OS or toolchain update.

## The machine

| | |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Architecture | arm64 (Apple Silicon) |
| Swift | 6.0.3 (`swiftlang-6.0.3.1.10`), target `arm64-apple-macosx16.0` |
| Xcode | **Not installed.** Only Command Line Tools at `/Library/Developer/CommandLineTools` |
| Node | v24.6.0, npm 11.5.1, pnpm 11.2.2 (no bun) |
| Python | 3.10.11 (`/Library/Frameworks/Python.framework/Versions/3.10`) |
| Rust | not installed |
| Docker | 29.3.1 |
| Homebrew | 6.0.16 |
| gh | 2.93.0, authenticated as `ckryptickunal`, scopes `gist, read:org, repo, workflow` |
| claude CLI | 2.1.238 at `~/.local/bin/claude` |
| Main display | 1800 × 1169 points (Retina, so 3600 × 2338 pixels) |

## The finding that unblocks the project

**A SwiftUI app that links ScreenCaptureKit, ApplicationServices and AVFoundation builds
cleanly with Command Line Tools alone. Xcode is not required.**

Verified by compiling a program that imports `SwiftUI`, `ScreenCaptureKit`,
`ApplicationServices` and `AVFoundation`, uses `@main struct App: App`, and calls
`SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`:

```
swift build -c release   →  Build complete! (38.39s), exit 0
```

This matters because the entire "native Mac app" requirement rested on it, and because the
alternative (installing Xcode) is a ~16 GB download the user has not chosen to make.

### Minimum `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BotHarness",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BotHarness",
            path: "Sources/BotHarness",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
```

`.swiftLanguageMode(.v5)` is deliberate: Swift 6 strict concurrency makes SwiftUI view code
noisy to write, and this project's concurrency risk lives in the agent runtime, not the views.
Revisit per target, not globally.

### Assembling the `.app`

Swift Package Manager produces a bare executable, not a bundle. The bundle is assembled by
hand — this is the pattern already proven in `~/Desktop/FableEnable/bundle.sh`:

```bash
swift build -c release

APP=build/BotHarness.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BotHarness "$APP/Contents/MacOS/BotHarness"
cat > "$APP/Contents/Info.plist" <<'PLIST'
… CFBundleExecutable / CFBundleIdentifier / usage-description keys …
PLIST
codesign --force -s - "$APP"
open "$APP"
```

## Code signing: what ad-hoc actually gets you

```
$ codesign --force -s - build/Smoke.app
$ codesign -dv build/Smoke.app
  CodeDirectory v=20400 … flags=0x2(adhoc)
  Signature=adhoc
$ spctl -a -vv build/Smoke.app
  build/Smoke.app: rejected
```

**Ad-hoc signing is rejected by Gatekeeper assessment.** It still runs locally, because an app
you built yourself never receives the `com.apple.quarantine` extended attribute and so is never
assessed. The practical consequences:

- Local development and personal use: fine. This is how Fable already ships on this machine.
- Sending the `.app` to anyone else, or downloading it from anywhere: it will be quarantined,
  assessed, and refused. Distribution needs a Developer ID certificate and notarisation.
- **Ad-hoc signatures are not stable across rebuilds.** macOS ties TCC permission grants
  (Accessibility, Screen Recording) to the code signature. Every rebuild can therefore look
  like a different app and re-prompt for permissions. This is the single most annoying thing
  about this build path and needs a real answer before the app asks users for permissions —
  see the open question in `docs/decisions/`.

## TCC / permission APIs — availability confirmed

Probed with non-prompting APIs only, so nothing was shown to the user:

| Check | Result |
|---|---|
| `AXIsProcessTrusted()` | `true` *(inherited from the parent terminal process, not a grant to our app)* |
| `CGPreflightScreenCaptureAccess()` | `true` *(same caveat)* |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | `0` (notDetermined) |
| `CGEventSource(stateID: .hidSystemState)` | constructible — **input synthesis is available** |
| `CGEvent(mouseEventSource:…)` | constructible |

> **Read the caveat carefully.** A command-line binary inherits the TCC identity of whatever
> launched it. `true` here means the terminal running this session already holds Accessibility
> and Screen Recording. It says nothing about what a freshly built `BotHarness.app` will get.
> Our app will have to request its own grants under its own bundle identifier.

## Credentials present on this machine

- **No LLM API keys in the shell environment.** Only `ANTHROPIC_BASE_URL` is set.
- Gemini keys exist in several project `.env` files (`transcriptor/`, `AraviAI/`, `KurtiAICLI/`,
  `catalogue-platform/`, `reel-vault/`, and others). Their values were not read.
- `gcloud` is configured for account `lanesurfdesign@gmail.com`, project `teaching-479115`.
- The `claude` CLI is signed in via subscription and supports headless operation:
  `--print`, `--output-format stream-json`, `--input-format stream-json`, `--permission-mode`,
  `--mcp-config`, `--agents`, `--settings`, `--append-system-prompt`, `--model`, `--resume`.

**Bot-Harness stores its own keys in the macOS Keychain and nowhere else.** It does not read
these `.env` files. The pattern to copy is `~/Desktop/FableEnable/Sources/Fable/LLM.swift`,
which wraps `SecItemAdd` / `SecItemCopyMatching` in about 30 lines with no dependencies.

## Prior art on this machine worth reading before writing code

| Path | Why it matters |
|---|---|
| `~/Desktop/FableEnable/` | A zero-dependency SwiftUI macOS app, 2,878 lines, that already solves: the no-Xcode build, Keychain-backed keys, streaming SSE against Anthropic and OpenAI in pure `URLSession`, a ⌘K command palette, and a considered motion system. This is the closest thing to a starting point that exists. |
| `~/Desktop/FableEnable/bundle.sh` | The exact, working `.app` assembly script. |
| `~/Desktop/FableEnable/Sources/Fable/LLM.swift` | Keychain wrapper plus provider failover chain. Directly reusable. |
| `~/Desktop/FableEnable/.agents/skills/` | Local design skills: `swiftui-ui-patterns`, `impeccable`, `emil-design-eng`, `make-interfaces-feel-better`. Read before doing UI work. |
| `/Applications/Grok Bot.app` | The product being answered. See `docs/research/grok-bot-teardown.md`. |
