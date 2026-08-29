# Building and shipping a polished Mac-native app for Bot-Harness on macOS 26.5 / Apple Silicon — toolchain feasibility, code signing, TCC permissions, and framework choice

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The brief's hard constraint is false: full Xcode 26.6 IS installed at /Applications/Xcode.app (4.0 GB, license already accepted, actool and xcodebuild both functional, macOS 26.5 SDK present), and XcodeGen 2.45.4 is already installed via Homebrew. The project is not just feasible, it is unblocked today. I built, signed, and launched a real SwiftUI .app end-to-end on this machine through two separate pipelines. The single most important finding is a code-signing one that has nothing to do with Xcode: this Mac has a real "Apple Development" identity (Team 233YWRXL6V), and using it instead of ad-hoc signing is mandatory, because an ad-hoc signature's designated requirement is a raw cdhash that changes on every rebuild, which makes macOS treat each build as a brand-new app and silently revoke Screen Recording and Accessibility every single time. For a computer-use agent that lives on exactly those two permissions, ad-hoc signing would make the dev loop unusable. Go native SwiftUI signed with the Apple Development cert; Electron and Tauri both cost more and buy nothing here.

## Recommendation

Build it as a native SwiftUI app, signed with the existing Apple Development identity, using XcodeGen + xcodebuild as the build path.

First, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. This one command is the highest-leverage action available: it swaps the stale 15.2 SDK for 26.5 and unlocks actool. Everything else follows from it.

Sign every build with the Apple Development identity (<identity-hash>), never with `--sign -`. This is not a polish concern, it is the difference between a working and an unworkable dev loop. Bot-Harness lives entirely on Screen Recording and Accessibility; ad-hoc signing silently revokes both on every rebuild because the designated requirement is a cdhash that changes each compile. I measured both signatures on the same bundle to confirm. Add the `codesign -d -r- | grep 'anchor apple generic'` guard to build.sh so a future agent cannot regress this without the build failing loudly.

Choose XcodeGen over the hand-rolled SwiftPM script as the primary path. Both work, but XcodeGen gets the current SDK, real asset catalogs, hardened runtime and signing declaratively from a project.yml you can commit and diff, which matters for the "log every decision for future agents to audit" requirement. Keep the SwiftPM build.sh as a fallback since it is only 20 lines and it does run.

Skip Electron and Tauri. Tauri needs a Rust toolchain that is not installed and then routes every OS call through FFI; Electron ships 96-120 MB to do what a 116 KB native binary does, and still needs a native addon for ScreenCaptureKit and Accessibility. Both move you further from the OS while charging you more, and the GrokBot-style three-pane layout is straightforward in SwiftUI — I built a working one during this research.

For the live computer view, use ScreenCaptureKit directly in Swift. If you want web tech for the conversation pane specifically, WKWebView hosting is viable (it compiles against both SDKs), but treat it as an optional inner panel, not the app shell.

## Risks

- The Apple Development certificate expires (typically one year) and is tied to a personal Apple ID. When it lapses, the designated requirement changes and ALL TCC grants reset — the same failure mode as ad-hoc signing, just delayed. Note the expiry date now. If Bot-Harness is ever distributed beyond this Mac, a Developer ID cert plus notarization becomes necessary; Apple Development will not work on another machine.
- The signing identity is currently hardcoded to a specific SHA-1 hash in the build script. If the cert is renewed the hash changes and builds break with a confusing error. Prefer SIGN_ID as an overridable environment variable (the verified script already does this) and document the identity lookup command.
- xcode-select currently points at CommandLineTools. Any agent or script that runs a build WITHOUT setting DEVELOPER_DIR silently compiles against SDK 15.2 and produces a binary that cannot use macOS 26 APIs — and it will succeed, not fail. This is a silent-wrong-output risk, the worst kind. Set it globally with xcode-select rather than relying on per-shell exports.
- Existing TCC grants made to earlier ad-hoc builds do not migrate to the properly-signed build. If any prototype was already granted Screen Recording, those stale entries must be removed manually in System Settings > Privacy & Security before the new grants will take, otherwise the toggle can appear ON while access is actually denied.
- Disabling the App Sandbox is correct for a local computer-use agent but permanently forecloses Mac App Store distribution and widens blast radius: a bug or a prompt-injection through observed screen content can drive real input events via CGEvent. The logging requirement in the brief should be treated as a safety control, not just an audit feature.
- SMAppService plist placement at Contents/Library/LaunchAgents is drawn from Apple Developer Forums rather than a fetched Apple documentation page — the docs page returned no body. Verify empirically before relying on the background-agent design.
- actool exists only inside Xcode. If Xcode is ever removed to reclaim the 4.0 GB, asset catalogs break immediately and the SDK silently regresses to 15.2. The iconutil/sips fallback covers icons only, not Assets.car.
- A file named main.swift builds fine under SwiftPM but fails under xcodebuild with a misleading top-level-expression error. If the two build paths are kept in parallel, this asymmetry will bite whoever switches between them.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN THE BRIEF — the central premise: 'the machine has NO full Xcode.app - only Command Line Tools'. Xcode 26.6 build 17F113 is installed at /Applications/Xcode.app, 4.0 GB, installed 2026-06-26, license already accepted, with working actool and xcodebuild. The entire framing of the assignment as a constrained-environment problem is false. What is true is narrower: xcode-select POINTS at CommandLineTools, so the default toolchain is the stale one.
- WRONG IN THE BRIEF — 'XcodeGen / Tuist usable without Xcode?' presumes neither is installed. XcodeGen 2.45.4 is already installed via Homebrew at /opt/homebrew/bin/xcodegen. The question of minimum Xcode install size is moot: the full 4.0 GB is already on disk.
- WRONG, WIDELY REPEATED ON THE WEB — that NSScreenCaptureUsageDescription is a required Info.plist key. Several sources returned by search assert it confidently (one claims 'the app will be terminated without one'). I grepped every binary under /System/Library and /usr/lib: the string appears zero times, while the three genuine keys appear in two system binaries each. The key does not exist. NSAccessibilityUsageDescription is likewise not a real macOS key. Any agent that adds these will produce dead plist entries and, worse, may conclude permissions are configured when they are not.
- PARTIALLY WRONG IN THE BRIEF — 'damaged-app issues on macOS 26'. This affects downloaded, quarantined apps. A locally built bundle carries only com.apple.provenance and never com.apple.quarantine; my build launched normally. spctl -a does return 'rejected' for a non-notarized app, but that assessment does not block launch. No xattr workaround is needed for local development.
- COULD NOT VERIFY — Apple's official SMAppService documentation page returned an empty body via WebFetch (title only, no content). The Contents/Library/LaunchAgents path and the .plist-extension requirement come from Apple Developer Forums threads, not from the primary docs page. Marked 'likely', not confirmed.
- COULD NOT VERIFY — exact Tauri and Electron bundle sizes were not measured on this machine (neither is installed). The ~3-10 MB and ~96-120 MB figures come from a third-party 2026 tutorial, not from Tauri's or Electron's own documentation. The native SwiftUI figures (116 KB and 456 KB) ARE measured directly.
- COULD NOT VERIFY — GitHub's REST API returned HTTP 403 to unauthenticated curl and to WebFetch. All repo metadata was obtained through the authenticated gh CLI instead, which is equivalent but worth noting as a method substitution.
- COULD NOT VERIFY — the octavore.com command-line-app blog post returned HTTP 403, and the tqbf/swiftui-app README did not contain the actual codesign or Info.plist commands (they live in scripts/ which I did not fetch). No recipe in my output depends on either source; every command I give was executed on this machine.
- NOT TESTED — whether TCC grants actually persist across rebuilds with the Apple Development identity. I verified the mechanism (the designated requirement is stable) and Apple DTS confirms the causal link, but I did not run the full grant-rebuild-regrant cycle, which requires interactive System Settings approval. Confidence is high but this is inference from a verified mechanism, not a direct end-to-end observation.
- NOT INVESTIGATED — WKWebView hybrid gotchas beyond compilation. I confirmed WKWebView, WKWebViewConfiguration, WKUserContentController, loadFileURL and callAsyncJavaScript all compile against both SDKs, but did not test the Swift/JS bridge, local-file CORS behavior, or whether a non-sandboxed WKWebView inherits the host app's TCC grants. Worth a spike before committing to a hybrid UI.
- NOT INVESTIGATED — the Python 3.10 side of the stack. The brief mentions a possible Swift/Python core split, but I did not examine embedding Python, PyObjC access to AX APIs, or how a Python subprocess inherits (or fails to inherit) the parent app's TCC grants. That last point is a known sharp edge and should be researched before designing the core around Python.

## Verified facts

- Full Xcode 26.6 (build 17F113) is installed at /Applications/Xcode.app, 4.0 GB on disk, with actool and xcodebuild present and the first-launch/license check passing (xcodebuild -checkFirstLaunchStatus exits 0). The brief's claim of 'NO full Xcode' is wrong.  
  — **confirmed** · <local: du -sh /Applications/Xcode.app; xcodebuild -version; xcodebuild -checkFirstLaunchStatus>
- The Command Line Tools SDK is MacOSX 15.2, while the OS is macOS 26.5. Xcode ships MacOSX26.5.sdk and MacOSX26.sdk. A CLT-only build therefore compiles against an SDK 11 major versions behind the running OS and cannot use any macOS 26 API. Building via Xcode's DEVELOPER_DIR yields 'Runtime Version=26.5.0' vs '15.2.0' from CLT.  
  — **confirmed** · <local: xcrun --show-sdk-version (15.2) vs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-version (26.5); codesign -dv on both built apps>
- A SwiftUI macOS .app can be built, bundled, signed, verified and LAUNCHED using only Command Line Tools + SwiftPM. I compiled a three-pane SwiftUI app with /usr/bin/swift build -c release, hand-assembled the bundle, signed it, and it ran (PID 33770). No Xcode needed for this path.  
  — **confirmed** · <local: swift build -c release + manual bundle assembly + codesign + open; pgrep confirmed running process>
- Ad-hoc signing produces the designated requirement 'cdhash H"94e3aadf..."', which changes on every rebuild. Signing with the machine's Apple Development identity produces the stable DR 'identifier "com.kunal.botharness" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ..."'. Measured directly with codesign -d -r- on the same bundle signed both ways.  
  — **confirmed** · <local: codesign -d -r- on identical bundle signed ad-hoc vs with identity <identity-hash>>
- Apple DTS (Quinn 'The Eskimo!') confirms the consequence: 'macOS tracks code identity using the code's designated requirement. Ad hoc signed code does not include a stable DR, and thus macOS is unable to tell that version N+1 of your app is the same code as version N.' Apple's recommended fix is to sign with an Apple-issued identity — Apple Development during development.  
  — **confirmed** · <https://developer.apple.com/forums/thread/795739>
- NSScreenCaptureUsageDescription DOES NOT EXIST as a macOS Info.plist key. It appears in ZERO system binaries under /System/Library and /usr/lib, whereas NSCameraUsageDescription, NSMicrophoneUsageDescription and NSAppleEventsUsageDescription each appear in 2. NSAccessibilityUsageDescription is likewise absent. Screen Recording and Accessibility are gated purely by TCC via API calls, not by purpose strings.  
  — **confirmed** · <local: grep -rl over /System/Library and /usr/lib for each key; multiple blog/AI sources claiming otherwise are wrong>
- The real gating APIs exist in the macOS 26.5 SDK: 'CG_EXTERN bool CGPreflightScreenCaptureAccess(void) API_AVAILABLE(macos(10.15));' and 'CG_EXTERN bool CGRequestScreenCaptureAccess(void) API_AVAILABLE(macos(10.15));' in CoreGraphics; _AXIsProcessTrusted, _AXIsProcessTrustedWithOptions and _kAXTrustedCheckOptionPrompt in ApplicationServices.  
  — **confirmed** · <local: grep of MacOSX26.5.sdk CoreGraphics headers and ApplicationServices tbd symbol lists>
- actool (Xcode-only, absent from CommandLineTools) compiles an asset catalog correctly here, emitting AppIcon.icns (54 KB), Assets.car (282 KB) and a partial Info.plist containing CFBundleIconFile/CFBundleIconName. Without Xcode this step is impossible, but /usr/bin/iconutil and /usr/bin/sips are base-OS binaries (iconutil signed com.apple.iconutil, Platform identifier 26) and provide an icon-only fallback.  
  — **confirmed** · <local: xcrun actool ... --compile; find for actool in CommandLineTools (zero hits); codesign -dv /usr/bin/iconutil>
- XcodeGen 2.45.4 is already installed at /opt/homebrew/bin/xcodegen. The full project.yml -> xcodegen generate -> xcodebuild pipeline BUILD SUCCEEDED, producing a 116 KB signed BotHarness.app with TeamIdentifier=233YWRXL6V and Runtime Version 26.5.0.  
  — **confirmed** · <local: xcodegen --version; xcodegen generate; xcodebuild -project ... build; du -sh; codesign -dv>
- Gotcha that breaks the xcodebuild path but NOT the SwiftPM path: a source file named main.swift cannot host @main. xcodebuild fails with 'error: expressions are not allowed at the top level' / "pass '-parse-as-library'". Renaming main.swift to BotHarnessApp.swift fixed it and the build succeeded.  
  — **confirmed** · <local: xcodebuild failure then success after rename>
- Locally built apps are NOT quarantined: the bundle carries only com.apple.provenance, never com.apple.quarantine. The macOS 26 'app is damaged' Gatekeeper problem applies to downloaded apps and does not affect a locally built one. spctl -a does report 'rejected' for a non-notarized app, but this does not prevent launch — the app opened normally.  
  — **confirmed** · <local: xattr -lr on the built bundle; spctl -a -vvv -t exec; open + pgrep>
- ScreenCaptureKit, ApplicationServices/AXIsProcessTrusted, CGEvent posting, AVFoundation, WebKit/WKWebView and ServiceManagement/SMAppService all compile cleanly against BOTH the stale CLT SDK 15.2 and the Xcode SDK 26.5. ScreenCaptureKit.framework is physically present in the CLT SDK.  
  — **confirmed** · <local: swiftc -parse-as-library probes against both SDKs; ls of CLT SDK Frameworks dir>
- SMAppService requires the launchd plist to live in the app bundle at Contents/Library/LaunchAgents, and SMAppService.agent(plistName:) must be passed the filename INCLUDING the .plist extension. Registered agents appear in System Settings > General > Login Items.  
  — likely · <https://developer.apple.com/forums/thread/721737>
- Framework metadata as of 2026-08-29 via authenticated GitHub API: tauri-apps/tauri 110,639 stars, Apache-2.0, pushed 2026-08-28; electron/electron 122,781 stars, MIT, pushed 2026-08-29; yonaskolb/XcodeGen 8,744 stars, MIT, pushed 2026-07-16; tuist/tuist 5,779 stars, pushed 2026-08-29; stackotter/swift-bundler 510 stars, Apache-2.0, pushed 2026-08-21. None archived. Latest npm: electron 44.0.0, @tauri-apps/cli 2.11.4.  
  — **confirmed** · <https://api.github.com/repos/tauri-apps/tauri (via gh api) and https://registry.npmjs.org/electron/latest>
- Measured bundle sizes on this machine: xcodebuild-produced SwiftUI app 116 KB; SwiftPM-produced app 456 KB. Tauri documents ~3-10 MB bundles and Electron ~96-120 MB. Native SwiftUI is roughly three orders of magnitude smaller than Electron.  
  — likely · <https://rustify.rs/articles/rust-tauri-v2-desktop-app-tutorial-2026>
- Tauri v2 configures macOS permissions via a src-tauri/Info.plist that is merged with CLI-generated values, and an entitlements file registered as bundle.macOS.entitlements in tauri.conf.json. Rust is NOT installed on this machine (~/.cargo absent), so Tauri would require a full rustup toolchain install first.  
  — **confirmed** · <https://v2.tauri.app/distribute/macos-application-bundle/>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [Xcode 26.6 (already installed locally)](https://developer.apple.com/xcode/) | adopt — already present at /Applications/Xcode.app, 4.0 GB, license accepted. Use it as the build backend; it is the only source of actool and the current SDK. | Full IDE + toolchain. Provides xcodebuild, actool (asset catalogs), the macOS 26.5 SDK, and Interface Builder tooling. | n/a | Apple proprietary (free) | installed 2026-06-26 |
| [XcodeGen (already installed locally)](https://github.com/yonaskolb/XcodeGen) | adopt — v2.45.4 already at /opt/homebrew/bin/xcodegen; I ran the full generate+build and it succeeded. Keeps the project agent-auditable and diff-friendly. | Generates .xcodeproj from a declarative project.yml, so the repo stores YAML instead of an unmergeable project file. | 8,744 | MIT | pushed 2026-07-16 |
| [Tuist](https://github.com/tuist/tuist) | reject — heavier than XcodeGen, has a commercial/server dimension (license NOASSERTION), and solves scaling problems a solo dev does not have. | Swift-DSL project generation plus caching and a hosted server component. | 5,779 | NOASSERTION | pushed 2026-08-29 |
| [swift-bundler](https://github.com/stackotter/swift-bundler) | reference-only — useful as a design reference for the hand-rolled build.sh, but a 510-star dependency is not worth adopting when the 20-line script I verified already works. | Builds .app bundles from SwiftPM packages without an xcodeproj, handling Info.plist and signing. | 510 | Apache-2.0 | pushed 2026-08-21 |
| [Tauri v2](https://github.com/tauri-apps/tauri) | reject for this project — Rust is not installed (no ~/.cargo), and every macOS API you need (ScreenCaptureKit, AX, CGEvent) would go through FFI or third-party plugins. You would pay a new toolchain to get further from the OS. | Rust-backed desktop shell using the OS webview; ~3-10 MB bundles. | 110,639 | Apache-2.0 | pushed 2026-08-28 |
| [Electron](https://github.com/electron/electron) | reject for the shell — ~96-120 MB bundle vs 116 KB native, and it still needs a native addon for ScreenCaptureKit and Accessibility. Fastest UI iteration of the three, but least Mac-native. | Chromium + Node desktop shell. Node 24.6.0 and pnpm 11.2.2 are already installed. | 122,781 | MIT | pushed 2026-08-29 |
| [tauri-plugin-macos-permissions](https://github.com/ayangweb/tauri-plugin-macos-permissions) | reference-only — only relevant if Tauri were chosen; its existence illustrates that Tauri needs a third-party shim for what SwiftUI gets natively. | Checks/requests macOS accessibility, full disk access, camera and microphone permissions from Tauri. | not fetched | not fetched | not fetched |

## API and code shape

ENVIRONMENT AS MEASURED (2026-08-29)
  macOS 26.5.2 (25F84), arm64
  xcode-select -p          -> /Library/Developer/CommandLineTools
  swift --version          -> Apple Swift version 6.0.3 (swiftlang-6.0.3.1.10)
  CLT SDK                  -> 15.2   (STALE — 11 major versions behind the OS)
  Xcode                    -> 26.6 (17F113) at /Applications/Xcode.app, 4.0 GB, SDK 26.5
  xcodegen                 -> 2.45.4 at /opt/homebrew/bin/xcodegen
  node 24.6.0, pnpm 11.2.2, rust NOT installed
  signing identity         -> <identity-hash>
                              "Apple Development: <your-apple-id> (TEAMID)"
                              Team 233YWRXL6V

STEP 0 — POINT THE TOOLCHAIN AT XCODE (do this first; unlocks SDK 26.5 + actool)
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  # or, without sudo, per-shell:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

--------------------------------------------------------------------
RECIPE A — SwiftPM + hand-assembled bundle (VERIFIED: built, signed, launched)
--------------------------------------------------------------------
Package.swift:
    // swift-tools-version:6.0
    import PackageDescription
    let package = Package(
        name: "BotHarness",
        platforms: [.macOS(.v14)],
        targets: [.executableTarget(name: "BotHarness", path: "Sources/BotHarness")]
    )

IMPORTANT: name the entry file BotHarnessApp.swift, NOT main.swift.
A file called main.swift cannot host @main.

build.sh (this exact script ran clean end to end):
    #!/bin/bash
    set -euo pipefail
    APP_NAME="BotHarness"; BUNDLE_ID="com.kunal.botharness"
    SIGN_ID="${SIGN_ID:-<identity-hash>}"
    ROOT="$(cd "$(dirname "$0")" && pwd)"; APP="$ROOT/$APP_NAME.app"
    swift build -c release --arch arm64
    rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$ROOT/.build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
    cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
    codesign --force --options runtime --timestamp=none \
      --entitlements "$ROOT/$APP_NAME.entitlements" --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "BUILT: $APP"

Verified output:
    BotHarness.app: valid on disk
    BotHarness.app: satisfies its Designated Requirement

Asset catalog (requires Xcode's actool — VERIFIED working):
    xcrun actool Assets.xcassets \
      --compile "$APP/Contents/Resources" \
      --platform macosx --minimum-deployment-target 14.0 \
      --app-icon AppIcon \
      --output-partial-info-plist /tmp/partial.plist
    # emits AppIcon.icns + Assets.car; merge CFBundleIconFile/CFBundleIconName
    # from /tmp/partial.plist into your Info.plist

CLT-only icon fallback (no Xcode; iconutil and sips are base OS):
    mkdir icon.iconset
    sips -z 512 512 src.png --out icon.iconset/icon_512x512.png
    sips -z 1024 1024 src.png --out icon.iconset/icon_512x512@2x.png
    iconutil -c icns icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

--------------------------------------------------------------------
RECIPE B — XcodeGen + xcodebuild (VERIFIED: BUILD SUCCEEDED, 116 KB app)
--------------------------------------------------------------------
project.yml:
    name: BotHarness
    options:
      bundleIdPrefix: com.kunal
      deploymentTarget:
        macOS: "14.0"
    targets:
      BotHarness:
        type: application
        platform: macOS
        sources: [Sources]
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: com.kunal.botharness
            MARKETING_VERSION: "0.1.0"
            CODE_SIGN_IDENTITY: "Apple Development"
            CODE_SIGN_STYLE: Manual
            DEVELOPMENT_TEAM: 233YWRXL6V
            CODE_SIGN_ENTITLEMENTS: BotHarness.entitlements
            ENABLE_HARDENED_RUNTIME: YES
            SWIFT_VERSION: "6.0"

    xcodegen generate
    xcodebuild -project BotHarness.xcodeproj -scheme BotHarness \
      -configuration Release -derivedDataPath ./dd build

--------------------------------------------------------------------
Info.plist — ONLY these usage strings are real on macOS
--------------------------------------------------------------------
    <key>CFBundleIdentifier</key>       <string>com.kunal.botharness</string>
    <key>CFBundleExecutable</key>       <string>BotHarness</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSAppleEventsUsageDescription</key><string>Bot Harness controls apps to complete your tasks.</string>
    <key>NSCameraUsageDescription</key>     <string>...</string>
    <key>NSMicrophoneUsageDescription</key> <string>...</string>
    <!-- Menu-bar-only / no Dock icon: -->
    <!-- <key>LSUIElement</key><true/> -->

DO NOT ADD NSScreenCaptureUsageDescription OR NSAccessibilityUsageDescription.
I grepped all of /System/Library and /usr/lib: neither key exists anywhere in
macOS. Screen Recording and Accessibility have NO purpose string and NO
entitlement. They are granted only through System Settings, triggered by:

    CGPreflightScreenCaptureAccess()   // bool, macos(10.15) — check, no prompt
    CGRequestScreenCaptureAccess()     // bool, macos(10.15) — triggers prompt
    AXIsProcessTrusted()
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

--------------------------------------------------------------------
BotHarness.entitlements (sandbox OFF — required for a local agent)
--------------------------------------------------------------------
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.automation.apple-events</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.network.server</key><true/>

--------------------------------------------------------------------
Menu bar / background agent
--------------------------------------------------------------------
Plist must live at: BotHarness.app/Contents/Library/LaunchAgents/<name>.plist
Pass the filename WITH the .plist extension:

    let service = SMAppService.agent(plistName: "com.kunal.botharness.agent.plist")
    try service.register()
    _ = service.status
    try SMAppService.mainApp.register()   // launch-at-login for the app itself

Verify a build never regresses to ad-hoc (put this in CI / build.sh):
    codesign -d -r- BotHarness.app 2>&1 | grep -q 'anchor apple generic' \
      || { echo "FATAL: ad-hoc signature — TCC grants will be lost"; exit 1; }
