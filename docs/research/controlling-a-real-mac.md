# Cua (trycua) and the landscape of libraries that let an agent control a real Mac — verified against live sources on 2026-08-29

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

trycua/cua is very much alive — 22,005 stars, MIT, pushed today (2026-08-29), with a release yesterday — but its architecture has changed from the Computer/Agent/Lume split in the brief. The headline component for Bot-Harness is cua-driver, a Rust core with a C ABI and UniFFI bindings that drives native macOS apps in the background without stealing cursor or focus, using private SkyLight SPIs (SLEventPostToPid, SLPSPostEventRecordTo). The single most important build constraint we verified: on macOS 26, Bot-Harness MUST ship as a signed .app bundle, not a plain CLI binary — TCC ties Accessibility and Screen Recording grants to a bundle identity, CGWindowListCreateImage is hard-obsoleted since macOS 15.0 (compile error, not a warning), and ScreenCaptureKit requires NSScreenCaptureUsageDescription in Info.plist or the system kills the app. This validates the plan to build a native SwiftUI app rather than wrapping a Python script. Two practical blockers to plan around: Kunal's Python 3.10 is below the floor for most of the cua stack (only cua-driver accepts 3.10), and macOS's own 2-VM limit is enforced in the kernel, not just the EULA.

## Recommendation

Build Bot-Harness as a signed, hardened-runtime SwiftUI .app bundle and use cua-driver as the control layer, reached over MCP rather than linked in. Three reasons, all verified rather than assumed.

First, the .app bundle is not a stylistic choice, it is a hard requirement. macOS ties Accessibility and Screen Recording grants to a bundle identity, ScreenCaptureKit terminates any app that triggers its permission prompt without NSScreenCaptureUsageDescription in Info.plist, and the cua project's own open issue #870 traces its macOS 26 screenshot failure to running as a plain executable rather than a bundle. The Command-Line-Tools-only constraint is fine here: an .app bundle is a directory layout plus a codesign call, and needs no full Xcode install.

Second, cua-driver is the only maintained option that satisfies the "don't steal the physical mouse" requirement. Every alternative worth naming — Hammerspoon, cliclick, PyAutoGUI, Self-Operating-Computer, macos-harness — drives the real cursor. Kunal needs to keep using his Mac while the agent works, and only cua-driver's background path delivers that today.

Third, talk to it over MCP (`cua-driver mcp`) instead of embedding `cua_driver` in-process. This matters for a specific reason: cua-driver's background control depends on private SkyLight SPIs (SLEventPostToPid, SLPSPostEventRecordTo), which Apple can break in any point release. An MCP boundary means a broken driver degrades to a swappable component rather than taking the whole app down, and it fits Kunal's Claude Code workflow directly. Run the driver in `bounded` permission mode with a reviewed capability manifest, never `unrestricted`.

For the audit-log requirement in the brief, do not rely on cua's own Computer History preview. It is nightly-channel only and its allowlist deliberately excludes exactly what an auditor needs — it stores no screenshots, typed text, arguments, results, accessibility trees, paths, window titles, or URLs. Bot-Harness should keep its own decision log at the harness layer, above the driver.

Two setup items to handle on day one. Kunal's Python 3.10 is below the floor for most of the stack, so either pin to cua-driver alone (which accepts 3.10) or install Python 3.12 — the `pip install cua` meta-package will simply refuse to resolve on 3.10. And plan the host-control path, not the VM path: the 2-VM limit is enforced in the kernel, so Lume and Tart are not a route to parallel agent fleets on one machine.

## Risks

- cua-driver's background control depends on PRIVATE, undocumented SkyLight SPIs (SLEventPostToPid, SLPSPostEventRecordTo). Apple can break these in any macOS point release with no deprecation notice, and no public API delivers equivalent no-focus-steal behavior. This is the central technical risk of the whole approach — architect so the driver is swappable.
- Documented cua-driver functional gaps that will surface as agent failures: right-clicks on Chromium web content silently degrade to left-clicks (renderer-IPC filter drops the right-click subtype), and canvas apps like Blender and games filter per-pid routes entirely, forcing brief foreground activation that breaks the no-cursor-movement promise. Bot-Harness needs explicit fallbacks and honest surfacing of these cases.
- trycua/cua issue #870 (macOS 26 screen capture returning only the desktop) is STILL OPEN as of today, created 2026-01-21 and last updated 2026-03-17. Screenshot capture on macOS 26 is the least settled part of the stack, so validate it on Kunal's actual 26.5 machine before building the live-computer-view pane around it.
- Python version mismatch will block installation immediately: Kunal runs Python 3.10, but cua requires >=3.12, cua-cli >=3.12, and cua-sandbox/cua-agent >=3.11. Only cua-driver accepts 3.10. `pip install cua` will fail to resolve as-is.
- cua-driver ships anonymous telemetry on by default and its install path is a curl-pipe-to-bash script from cua.ai. For a personal agent that will hold Accessibility and Screen Recording over Kunal's real machine, run `cua-driver telemetry disable` and review the install script before executing it.
- macOS 26.1 had a confirmed Apple-side TCC bug (acknowledged by Apple DTS) where executables selected in System Settings never appeared in the Privacy list, affecting both Accessibility and Screen Recording. Reported fixed in 26.3 Beta and Kunal is on 26.5, so he should be clear — but any user on 26.1/26.2 cannot grant permissions at all, which matters if Bot-Harness is ever shared.
- browser-use/macos-harness is the closest existing analogue to Bot-Harness but is 12 days old with a single push and is self-described as experimental. Treat it as a design reference, not a dependency — there is no evidence yet of sustained maintenance.
- Granting Accessibility plus Screen Recording to Bot-Harness gives it the ability to read every window and synthesize input anywhere on the machine — effectively full control including password fields and private messages. This is unavoidable for the product to work, but the audit log and a hard stop on credential fields should be designed in from the start, not retrofitted.
- openai/tart carries a NOASSERTION license (non-standard terms, not a recognized SPDX identifier). If Tart is ever chosen over Lume, read the actual license before any commercial or distributed use. Lume, within the cua monorepo, is MIT.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- BRIEF IS WRONG — the 'Computer / Agent / Driver / Lume split' no longer describes the codebase. The current package set is cua-driver, cua-agent, cua-sandbox, cua-computer-server, cua-bench, lume, lumier, and the top-level Python API is now `from cua import Sandbox, Image` with `Sandbox.ephemeral(Image.macos())`. There is no `from computer import Computer` entry point in the current README. Any code written against the old shape will not run.
- BRIEF IS WRONG — 'macos-use' does not exist at BandarLabs/macos-use (GitHub API returns 404). The real repo is browser-use/macOS-use, and it is effectively abandoned: last push 2025-03-05, about 18 months stale. The same org's active successor is browser-use/macos-harness.
- BRIEF IS STALE — 'open-interpreter OS mode' is no longer a meaningful option. OpenInterpreter/open-interpreter now redirects to openinterpreter/openinterpreter and the project describes itself as 'A coding agent for open models like Kimi K3'. The computer-control framing is gone from its stated purpose.
- BRIEF IS STALE — cirruslabs/tart has moved to the openai GitHub organization. The old path redirects to openai/tart.
- CONTESTED, COULD NOT RESOLVE — whether NSAccessibilityUsageDescription is actually honored by macOS TCC. Sources conflict directly: some community guides say to add it to Info.plist, others report it is a no-op on macOS (unlike its iOS counterparts) and that only AXIsProcessTrustedWithOptions plus a manual System Settings toggle works. Apple's own documentation pages for this key and for AXIsProcessTrustedWithOptions returned 404 or JavaScript-only shells and could not be fetched. Treat the key as harmless-but-probably-inert and rely on the API call; verify empirically on Kunal's machine.
- COULD NOT FETCH — developer.apple.com documentation pages are JS-rendered and returned 404 or empty content for nsscreencaptureusagedescription and both AXIsProcessTrustedWithOptions URLs. The exact Swift function signature and availability annotations for AXIsProcessTrustedWithOptions are therefore unverified against Apple primary source; the key name and options constant are corroborated only by secondary sources.
- COULD NOT FETCH — trac.macports.org is behind Anubis bot protection, so the exact cliclick compile-error text was read from search-result excerpts rather than the ticket itself. The CGWindowListCreateImage obsoletion is corroborated independently by the JUCE issue tracker.
- UNVERIFIED — Lume's exact minimum macOS version, Apple Silicon requirement, and install command are not stated in its README, and the README carries no statement about Apple's 2-VM limit. The 2-VM constraint is verified from Apple's EULA and the eclecticlight technical writeup, not from cua's own docs.
- UNVERIFIED — the specific list of MCP tool names exposed by `cua-driver mcp` (beyond history_status and history_query, which are named in the README). The hosted docs pages at cua.ai/docs/driver and docs.trycua.com/docs/driver returned 404 or redirect loops. Run `cua-driver doctor` and inspect the live MCP tool listing to enumerate them.
- UNVERIFIED — whether macOS 26 introduces genuinely NEW agent/automation APIs. Search surfaced only that Tahoe brought personal automations to Shortcuts and that App Intents is Apple's recommended direction over AppleScript, plus reports of AppleScript regressions on 26.x (error -600, Music app current track). None of this was confirmed against an Apple primary source, and no macOS 26 agent-specific API was found. Treat the App Intents direction as a lead to investigate, not a finding.
- UNVERIFIED — the daemon-proxy/Bundle-ID explanation for cua-driver's architecture comes from DeepWiki, an AI-generated documentation site, not from cua's own docs. The underlying claim is strongly corroborated by issue #870 and the install instructions, but the specific wording should not be quoted as primary.

## Verified facts

- trycua/cua is active and not archived: 22,005 stars, MIT License, created 2025-01-31, pushed_at 2026-08-29T12:59:32Z (today), 738 open issues. Topics include computer-use, lume, swift, virtualization-framework.  
  — **confirmed** · <https://api.github.com/repos/trycua/cua>
- Most recent cua release is tag computer-server-v0.3.45, published 2026-08-28T01:51:15Z, notes: 'Maintenance release — dependency updates only.' Confirms daily-active maintenance.  
  — **confirmed** · <https://api.github.com/repos/trycua/cua/releases/latest>
- The current top-level Python API is NOT the old Computer/Agent split. README example is: `from cua import Sandbox, Image` then `async with Sandbox.ephemeral(Image.linux()) as sb:` with `.macos()`, `.windows()`, `.android()` variants, and methods `sb.shell.run()`, `sb.screenshot()`, `sb.mouse.click(x,y)`, `sb.keyboard.type()`, `sb.mobile.gesture()`.  
  — **confirmed** · <https://raw.githubusercontent.com/trycua/cua/main/README.md>
- cua-driver drives native macOS apps in the background: 'Drive native desktop apps in the background. Agents click, type, and verify without stealing the cursor or focus.' It speaks MCP over stdio.  
  — **confirmed** · <https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/README.md>
- Background control is implemented with PRIVATE Apple SPIs, not public API: SkyLight's `SLEventPostToPid` (posts synthesized events to one process without the HID tap), `SLPSPostEventRecordTo` (flips a window's AppKit-active state without raising it), and `_AXObserverAddNotificationAndCheckRemote`. Public `CGEvent.postToPid` is documented as failing on Chrome/Chromium due to renderer filtering.  
  — **confirmed** · <https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md>
- cua-driver's documented macOS limitations: Chromium's renderer-IPC filter drops the right-click subtype on non-HID-tap paths (right-clicks on web content degrade to left-clicks); canvas apps like Blender and games 'filter per-pid routes entirely' and need brief foreground activation, which breaks the no-cursor-movement guarantee.  
  — **confirmed** · <https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md>
- cua-driver requires macOS 14 (Sonoma) or later on Apple Silicon or Intel, and needs exactly two TCC grants: Accessibility, and Screen & System Audio Recording. Setup is: `open -n -g -a CuaDriver --args serve`, then `cua-driver permissions grant`, then toggle CuaDriver on; verify with `cua-driver permissions status`.  
  — **confirmed** · <https://cua.ai/docs/how-to-guides/driver/install>
- cua-driver uses a daemon-proxy model specifically because macOS TCC permissions are tied to the Bundle ID of the requesting application. `cua-driver mcp` proxies to the installed CuaDriver.app daemon so Accessibility and Screen Recording grants retain the signed app-bundle identity.  
  — likely · <https://deepwiki.com/trycua/cua/6-cua-driver:-background-computer-use>
- Exact TCC service names: kTCCServiceAccessibility ('Allows client to control computer'), kTCCServiceScreenCapture, kTCCServiceAppleEvents ('Grants access to send Apple Events'), kTCCServicePostEvent ('ability to post events to the system'), kTCCServiceListenEvent.  
  — likely · <https://github.com/AtlasGondal/macos-pentesting-resources/blob/main/tccd/kTCCService.md>
- OPEN BUG in cua on macOS 26: issue #870 'macOS Tahoe (26.x): Screen capture only shows desktop, not application windows' — still open, created 2026-01-21. Root cause given as macOS 26.1 requiring app bundles for an item to appear in the Screen Recording privacy UI. Recommended fix is an .app bundle wrapper with NSScreenCaptureUsageDescription in Info.plist plus code signing with hardened runtime.  
  — **confirmed** · <https://github.com/trycua/cua/issues/870>
- Apple DTS (Quinn 'The Eskimo!') confirmed a serious macOS 26.1 bug where executables selected in System Settings never appear in the Privacy list, affecting 'a wide range of privileges' including Screen & System Audio Recording and Accessibility. The original reporter confirmed it was fixed in macOS 26.3 Beta. Kunal is on 26.5, so he is past this bug.  
  — **confirmed** · <https://developer.apple.com/forums/thread/808897>
- CGWindowListCreateImage is not merely deprecated but OBSOLETED in macOS 15.0 — it produces a hard compile error ('unavailable: obsoleted in macOS 15.0 - Please use ScreenCaptureKit instead'), which broke cliclick 5.0.1 builds. Replacement is ScreenCaptureKit's SCScreenshotManager, which is async.  
  — **confirmed** · <https://trac.macports.org/ticket/71136>
- NSScreenCaptureUsageDescription is required in Info.plist: the system terminates apps that trigger the Screen Recording TCC prompt without it. ScreenCaptureKit is purely TCC-gated — there is no code-signing entitlement that grants screen capture access.  
  — likely · <https://github.com/siddharthvaddem/openscreen/issues/548>
- NSAppleEventsUsageDescription is the documented Info.plist key (type String) for sending Apple Events, required since macOS 10.14 Mojave.  
  — **confirmed** · <https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription>
- Apple's macOS EULA permits running up to two (2) additional copies of macOS in virtual environments per Apple-branded computer. This is enforced technically, not just legally: the Virtualization framework returns VZErrorDomain code 6, 'The maximum supported number of active virtual machines has been reached', implemented in the closed-source part of the XNU kernel.  
  — **confirmed** · <https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/>
- Current verified package versions and Python floors: cua 0.1.6 (requires >=3.12,<3.14), cua-driver 0.22.2 (requires >=3.10), cua-sandbox 0.4.3 (>=3.11,<3.14), cua-cli 0.1.15 (>=3.12), cua-agent 0.8.4 (>=3.11,<3.14). npm @trycua/cua-driver is at 0.22.2, modified 2026-08-27.  
  — **confirmed** · <https://pypi.org/pypi/cua-driver/json>
- cua-driver architecture: a Rust Cargo workspace exposing a versioned C ABI (rust/include/cua_driver_abi.h) with UniFFI-generated bindings. Python apps `import cua_driver`; TypeScript apps import `@trycua/cua-driver`. `CuaDriver.create()` loads the native runtime in-process (no daemon needed for direct app use); `connect()` is the daemon-compatible path. Permission modes are `standard` (promptless default), `bounded` (manifest-limited), `unrestricted` (needs --dangerously-bypass-approvals).  
  — **confirmed** · <https://github.com/trycua/cua/blob/main/libs/cua-driver/README.md>
- Lume is described as 'CLI and framework for macOS and Linux VMs using Apple Virtualization Framework' with commands `lume create`, `lume run`, `lume sip`, `lume config telemetry`. Install: /bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)". Lumier is the Docker-compatible Lume interface. Both exist and are part of the cua monorepo.  
  — **confirmed** · <https://raw.githubusercontent.com/trycua/cua/main/libs/lume/README.md>
- browser-use/macos-harness exists and is directly analogous to Bot-Harness: MIT, 806 stars, but created AND last pushed 2026-08-17 (12 days old, single push). It exposes six primitives — see, key, type, click, ax, script — over one persistent Python process, using CGWindow for screenshots, CGEvent for input, AX + Apple Events for control, and Chrome DevTools Protocol for the browser. Self-described as experimental.  
  — **confirmed** · <https://github.com/browser-use/macos-harness>
- cirruslabs/tart has moved to the openai GitHub organization — repos/cirruslabs/tart now resolves to openai/tart, 6,609 stars, pushed 2026-08-28, homepage tart.run. It is the main alternative to Lume for macOS VMs on Apple Silicon.  
  — **confirmed** · <https://api.github.com/repos/cirruslabs/tart>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [trycua/cua](https://github.com/trycua/cua) | adopt (cua-driver only) — it is the only maintained thing that solves background control without hijacking Kunal's physical mouse, which is the single hardest requirement in the Bot-Harness brief. Adopt the driver; ignore the Sandbox/cloud layers, which solve a different problem. | Computer-use platform. For our purposes the relevant piece is cua-driver: a Rust core (C ABI + UniFFI bindings, Python/TypeScript SDKs, MCP over stdio) that drives native macOS apps in the background without stealing cursor or focus, via private SkyLight SPIs. Also ships Lume/Lumier for Apple Silicon macOS VMs and cua-sandbox for cloud/QEMU environments. | 22,005 | MIT | 2026-08-29 (pushed today; release 2026-08-28) |
| [browser-use/macos-harness](https://github.com/browser-use/macos-harness) | reference-only — this is almost exactly Bot-Harness's design, so read it for the primitive set and the doctor-style permission preflight. Do not depend on it: it is 12 days old with a single push, self-described as experimental, and it moves the real cursor. | A deliberately thin Mac-control harness for an LLM: six primitives (see, key, type, click, ax, script) over one persistent Python process, using CGWindow, CGEvent, the Accessibility API, Apple Events, and Chrome DevTools Protocol. | 806 | MIT | 2026-08-17 (created same day; one push) |
| [openai/tart](https://github.com/openai/tart) | evaluate (as Lume alternative) — more mature and better-known than Lume, and now backed by OpenAI. Only relevant if we decide the agent should act inside a disposable macOS VM rather than on the host. Subject to the same hard 2-VM kernel limit. | macOS and Linux VMs on Apple Silicon via Apple's Virtualization.framework, for CI and automation. Formerly cirruslabs/tart — the old URL now redirects to the openai org. | 6,609 | NOASSERTION (non-standard; check terms before commercial use) | 2026-08-28 |
| [Hammerspoon/hammerspoon](https://github.com/Hammerspoon/hammerspoon) | reference-only — excellent proof of how a signed .app should request and hold Accessibility. Adopting it would force a Lua bridge and it drives the real cursor, so it does not meet the background-control requirement. | Mature Lua-scriptable macOS desktop automation — window management, hotkeys, Accessibility API access, event taps. Ships as a signed .app bundle, so it already holds TCC grants correctly. | 16,014 | MIT | 2026-07-08 |
| [BlueM/cliclick](https://github.com/BlueM/cliclick) | reject — it is a plain CLI binary, which is the exact shape macOS 26 TCC handles worst (no bundle identity for grants), it moves the physical cursor, and its last tagged release is 5.1 from 2022. It also hit the CGWindowListCreateImage obsoletion wall on macOS 15. | Small macOS CLI that emulates mouse and keyboard events via CGEvent. | 2,007 | NOASSERTION | 2025-08-23 (commits); last release 5.1, 2022-08-14 |
| [asweigart/pyautogui](https://github.com/asweigart/pyautogui) | reject — unmaintained for our purposes (last push 2024-08-20, two years stale, no GitHub releases published). It predates the macOS 15 screenshot API obsoletion and the macOS 26 bundle requirements, and it always steals the physical cursor. | Cross-platform Python mouse/keyboard automation and screenshots. | 12,670 | BSD-3-Clause | 2024-08-20 |
| [OthersideAI/self-operating-computer](https://github.com/OthersideAI/self-operating-computer) | reject — last push 2025-09-19, roughly a year stale, and architecturally it is screenshot-plus-real-cursor, which is the approach Bot-Harness is specifically trying to avoid. | Multimodal-model framework that operates a computer by screenshotting and moving the real mouse. | 10,291 | MIT | 2025-09-19 |
| [browser-use/macOS-use](https://github.com/browser-use/macOS-use) | reject — effectively abandoned: last push 2025-03-05, roughly 18 months stale, and predates every macOS 26 TCC change. Superseded by the same org's macos-harness. | Accessibility-API-driven Mac agent — 'Make Mac apps accessible for AI agents'. | 1,974 | MIT | 2025-03-05 |
| [openinterpreter/openinterpreter](https://github.com/openinterpreter/openinterpreter) | reject — the project has pivoted to being a coding agent; the OS-mode/computer-control framing that made it relevant is no longer its stated purpose. | Now described as 'A coding agent for open models like Kimi K3'. The repo was renamed from OpenInterpreter/open-interpreter. | 68,178 | Apache-2.0 | 2026-08-20 |

## API and code shape

VERIFIED PACKAGE NAMES AND VERSIONS (PyPI / npm, 2026-08-29)
  cua          0.1.6   requires_python <3.14,>=3.12   (meta-package)
  cua-driver   0.22.2  requires_python >=3.10          <- the one we want
  cua-sandbox  0.4.3   requires_python <3.14,>=3.11
  cua-agent    0.8.4   requires_python <3.14,>=3.11
  cua-cli      0.1.15  requires_python <3.14,>=3.12
  npm: @trycua/cua-driver  latest 0.22.2  (modified 2026-08-27)

INSTALL (verbatim from README / docs)
  pip install cua
  # Cua Drivers (macOS/Linux):
  /bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
  # Lume (macOS VM management):
  /bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"

CURRENT TOP-LEVEL PYTHON API (verbatim from repo README — note this REPLACES the old Computer/Agent shape)
  # Requires Python 3.11 or later
  from cua import Sandbox, Image

  # Same API regardless of OS or runtime
  async with Sandbox.ephemeral(Image.linux()) as sb:   # or .macos() .windows() .android()
      result = await sb.shell.run("echo hello")
      screenshot = await sb.screenshot()
      await sb.mouse.click(100, 200)
      await sb.keyboard.type("Hello from Cua!")
      await sb.mobile.gesture((100, 500), (100, 200))  # multi-touch gestures

CUA-DRIVER INTEGRATION SURFACES (verbatim from libs/cua-driver/README.md)
  - Agents over MCP:      cua-driver mcp
  - Shell/automation:     cua-driver call
  - Python applications:  import cua_driver
  - TypeScript apps:      import @trycua/cua-driver
  - CuaDriver.create()  -> loads native runtime in-process (no daemon required)
  - connect()           -> daemon-compatible path for external clients
  - Stable native boundary: rust/include/cua_driver_abi.h  (C ABI, UniFFI bindings)

CUA-DRIVER CLI (verbatim from cua.ai/docs/how-to-guides/driver/install)
  open -n -g -a CuaDriver --args serve
  cua-driver permissions grant
  cua-driver permissions status
  cua-driver --version
  cua-driver doctor
  cua-driver serve
  cua-driver telemetry disable
  cua-driver channel set stable
  cua-driver mcp --grant existing-profile

CUA-DRIVER PERMISSION MODES + ENV VARS (verbatim)
  standard | bounded | unrestricted   (unrestricted needs --dangerously-bypass-approvals)
  CUA_DRIVER_PERMISSION_MODE
  CUA_DRIVER_CAPABILITY_MANIFEST_FILE
  CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED

MACOS PRIVATE SPIs USED FOR BACKGROUND CONTROL (exact symbol names)
  SLEventPostToPid                          // SkyLight: post events to one pid, bypassing the HID tap
  SLPSPostEventRecordTo                     // SkyLight: flip AppKit-active state without raising the window
  _AXObserverAddNotificationAndCheckRemote  // keeps Electron AX trees alive when windows are occluded
  CGEvent.postToPid                         // PUBLIC alternative; fails on Chrome/Chromium (renderer filtering)

CAPTURE MODES
  ax | vision | som     (accessibility tree | screenshots | combined)

TCC SERVICE NAMES (for auditing/verifying grants)
  kTCCServiceAccessibility   "Allows client to control computer."
  kTCCServiceScreenCapture   screen capture
  kTCCServiceAppleEvents     "Grants access to send Apple Events."
  kTCCServicePostEvent       ability to post events to the system
  kTCCServiceListenEvent     listen to system-level events

INFO.PLIST KEYS FOR BOT-HARNESS.APP
  <key>NSScreenCaptureUsageDescription</key>   <!-- REQUIRED: app is killed if the SC TCC prompt fires without it -->
  <key>NSAppleEventsUsageDescription</key>     <!-- REQUIRED for AppleScript/Apple Events; since macOS 10.14 -->
  <!-- Accessibility has NO reliably-honored usage-description key. Use the API instead: -->
  AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)

SCREENSHOT API — the old call is a COMPILE ERROR on macOS 15+
  CGWindowListCreateImage   // 'unavailable: obsoleted in macOS 15.0 - Please use ScreenCaptureKit instead'
  SCScreenshotManager       // replacement; async (watch latency on high-frequency capture)
  CGWindowListCopyWindowInfo  // still available for window enumeration/metadata

APPLE SILICON macOS VM LIMIT (kernel-enforced, not just EULA)
  VZErrorDomain code 6 = "The maximum supported number of active virtual machines has been reached."
