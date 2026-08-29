# UI/UX for a Mac-native agent cockpit (Bot-Harness): reference-product layouts, live screen streaming on macOS, macOS 26 Liquid Glass design language, and concrete interaction patterns

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The single most important finding is local and blocking: this Mac runs macOS 26.5.2 but the installed Command Line Tools ship only the macOS 15.2 SDK and Swift 6.0.3, so `glassEffect` does not exist and a Liquid Glass app literally cannot compile today — I verified this by compiling, and the error is `value of type 'Text' has no member 'glassEffect'`. Plain SwiftUI apps DO build and code-sign under CLT alone (I built and signed a working .app bundle), so the fix is a toolchain upgrade to the Xcode 26 SDK, not an architecture change. The second finding is that the "Grok Bot" reference app in /Applications is not an xAI product and is not native: it is bundle ID `com.anysphere.sand`, a validly-signed Anysphere (Cursor) Electron app, version 0.30.0, and its "computer" is a shared remote VM streamed over noVNC with snapshot/reset — not the local Mac. Its real layout is also not the one in the brief: left is a bot/conversation list, center is the conversation, right is a Settings inspector, the computer opens from a title-bar screen icon rather than living in a persistent right pane, and the current-action indicator is a floating pill at top-center, not a bottom bar. Meanwhile the browser-agent cockpits the brief names as references have been shutting down — OpenAI's help centre now states plainly that ChatGPT agent is no longer available, and Google discontinued Project Mariner on 4 May 2026 — so the durable patterns to copy come from Manus, Devin, Cursor and Jules rather than from Operator or Mariner. For a local-Mac agent the recursion problem has a clean official answer: `SCContentFilter(display:excludingApplications:exceptingWindows:)` excludes your own app from its own capture.

## Recommendation

Fix the toolchain before writing a line of UI. Install Command Line Tools for Xcode 26.x from the Apple developer portal and confirm `xcrun --show-sdk-version` reports 26.x. Until that happens, "Liquid Glass Mac-native app" is not a design decision, it is a compile error. Design the app so this is survivable either way: put every glass call behind one `ChromeSurface` view modifier with an `if #available(macOS 26.0, *)` branch that falls back to `.regular` material, so the app builds and looks respectable on the 15.2 SDK and lights up when the SDK lands.

Do not copy the brief's layout literally, because the app it is modelled on does not use it. Build three fixed panes plus one floating status element, using NavigationSplitView with two sidebars — the native container gives you Liquid Glass sidebar treatment, collapse behaviour and window-state restoration for free.

Left, "Runs" (~280pt, collapsible): a New run button, a search field, then rows of status glyph, run title, right-aligned relative time, and a one-line current-step preview. Pin a Permissions health row and the account row to the bottom. Copy the reference app's inline degraded-state affordance verbatim — a small "Reconnecting to your computer… Retry" line directly in the sidebar beats a modal.

Center, "Conversation" (flexible, min ~520pt): streaming markdown via Textual, user messages right-aligned in pills, assistant messages left-aligned unpilled. Tool calls render as the minimal card the reference app uses — title, coloured status pill (Running / Done / Failed / Needs you), one plain-language line of intent, and at most one action button. Hide raw arguments behind a disclosure triangle; Manus's own reviewers noted that showing raw terminal output creates cognitive overload. Put run events as centered dividers in the transcript ("Updated routine · Jewel partnership reply watch"), which is exactly how the reference app marks them.

Right, "Computer" (~420pt, collapsible, toggled from a title-bar monitor icon): the ScreenCaptureKit live view at the top with an "Auto-follow" toggle borrowed from Devin's "Following" switch, and a segmented control below it for Screen / Steps / Diffs / Files. Steps is a virtualized action timeline with a scrubber; clicking a step seeks the recorded frame, which is how Manus replay works and is what makes the audit log the brief demands actually navigable.

Floating, top-center of the conversation: a single glass status pill showing the current action and an elapsed timer, with a Pause control. This is where the reference app puts its status, and it is better than a bottom bar because it sits next to the content the user is reading and disappears when idle. Give it three states — running, waiting for you, failed.

For approvals, ship Auto-review as described above and default it ON. The natural-language rule composer is the single best idea in the reference app: it converts every approval interruption into a durable preference instead of a modal the user learns to click through. Reserve full modal sheets for genuinely irreversible actions (sending mail, spending money, deleting files) and render everything else as an inline card in the transcript with Allow once / Always allow / Deny. Steal Jules's auto-approve timer for plan gates so overnight runs do not stall, but never apply a timer to the irreversible class.

For Take Control, follow OpenAI's takeover-mode framing: when the user takes control, visibly suspend the agent, stop capturing model frames, and show a clear banner that the agent is paused and not watching. That last part matters because the user will type passwords during takeover. Resume should re-screenshot before the agent acts again, never resume from a stale frame.

Run one capture stream, not two. Feed the human pane at ~15fps via minimumFrameInterval and pull full-resolution stills for the model only at decision points. Continuous model-rate capture would cost roughly 1,000-1,800 tokens per frame and is the fastest way to make this app expensive and slow.

Finally, put cost in its own Usage window rather than in the chat, matching the reference app's separate Usage & Billing tab, and surface only a small per-run token and cost figure in the Computer pane footer. Cost noise in a transcript makes every run feel like a meter running.

## Risks

- The toolchain blocker is absolute, not a preference: the installed CLT ships SDK 15.2 and Swift 6.0.3 against a macOS 26.5.2 host, so glassEffect and every macOS 26 API is uncompilable today. Any plan that assumes Liquid Glass without first upgrading the SDK will fail at the first build. Verified by compiling, not inferred.
- The brief's core reference is misidentified. 'Grok Bot' is bundle ID com.anysphere.sand — an Anysphere/Cursor Electron app whose computer is a remote VM over noVNC with snapshot and reset. Building a native Mac app that drives the LOCAL Mac is a fundamentally different product with different failure modes: no snapshot to reset to, no isolation, and the user's real files and logged-in sessions at stake on every mis-click.
- A local-Mac agent has no undo. The reference app's 'Reset Grok Bot's Computer — it's rebuilt from your last saved snapshot' has no local equivalent. Without a sandbox, an errant click is permanent. Consider gating destructive filesystem and Mail/Messages actions behind hard modals regardless of Auto-review rules, and consider APFS snapshots as a crude rollback.
- Auto-review rules written in natural language are themselves an injection surface. A rule like 'reply to emails for me → Allow automatically' combined with a malicious email is precisely the prompt-injection scenario OpenAI documents (agent reads a poisoned page, is told to fetch a password reset code and send it to a malicious site). Rules must be scoped by tool AND by target, never by intent alone.
- Screen-recording and Accessibility permissions are all-or-nothing and re-prompt after app updates and re-signing. An ad-hoc-signed app (`codesign --sign -`) gets its TCC grants invalidated on every rebuild, which during development means re-granting Accessibility constantly. Use a stable signing identity early or development becomes miserable.
- Continuous pixel-level computer use is expensive and slow at roughly 1,000-1,800 input tokens per screenshot with a 20-image cap per request. A cockpit that streams frames to the model rather than sampling at decision points will feel sluggish and burn budget. Route web work through DOM automation where possible — the reference app itself carries sand_computer_use_playwright.
- Half the reference cockpits named in the brief are dead or dying: ChatGPT agent is 'no longer available', Operator shut down 31 Aug 2025, Project Mariner was discontinued 4 May 2026. Studying their screenshots risks copying patterns their own makers abandoned. Weight Manus, Devin, Cursor, Jules and Warp far more heavily.
- macOS 27 'Golden Gate' was announced at WWDC 2026 and reportedly refines Liquid Glass with a user-facing opacity slider, tighter window corner radii, a unified toolbar and edge-to-edge sidebars. A cockpit that hardcodes glass opacity or corner radii will look wrong within a year. Use system materials and semantic shapes, not hand-tuned numbers.
- The two-VM ceiling is enforced in the kernel, so the sandboxed-macOS-guest escape hatch does not scale past two concurrent agents on one machine. If Bot-Harness ever grows parallel agents, that path caps out fast.
- Several UI descriptions here (Manus, Devin, Jules) come from third-party reviews and blog posts rather than vendor documentation, and their UIs change without notice. Treat the specific pane names as directional, not as a spec to match pixel-for-pixel.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN THE BRIEF — 'Grok bot' is not an xAI agent UI. /Applications/Grok Bot.app is CFBundleIdentifier com.anysphere.sand, TeamIdentifier DCNK4UB866 (Anysphere, the Cursor company), an Electron app v0.30.0 whose signature validates. Its plugin catalogue says 'Connect Cursor to Asana' and its Cursor changelog match (Gmail/Drive/Calendar plugins, 3 Aug 2026) is exact. It does contain a 'TransferXaiCredits' symbol, so an xAI billing relationship exists, but there is no evidence of an xAI-built agent cockpit. I could not determine whether 'Grok Bot' is a public product name or a co-branded/internal build.
- WRONG IN THE BRIEF — the target layout does not match the reference app. There is no left task list (it is a bot/conversation list), no persistent right live-computer pane (the right pane is a Settings inspector; the computer opens from a title-bar monitor icon or an inline card), and no bottom current-action bar (status is a floating pill at top-center). The three-pane-with-live-view layout the brief describes is closer to Manus than to the app on disk.
- WRONG IN THE BRIEF — 'Swift 6 via Command Line Tools only' is true but insufficient. Swift is 6.0.3 and CLT is present, yet the bundled SDK is 15.2, so no macOS 26 API compiles. The brief treats the toolchain as adequate; it is not.
- STALE IN THE BRIEF — OpenAI Operator no longer exists (folded into ChatGPT agent 17 July 2025, shut down 31 Aug 2025) and ChatGPT agent itself is now marked 'no longer available' by OpenAI's help centre. Google's Project Mariner was discontinued 4 May 2026. Three of the named reference products cannot be studied live.
- COULD NOT VERIFY — Apple's HIG page at developer.apple.com/design/human-interface-guidelines/generative-ai resolved to an empty body in a real browser. I could not confirm whether Apple ships HIG guidance for AI/agent interfaces, so I have no Apple-sanctioned guidance on agent-specific patterns (approval, autonomy, live view). Worth re-checking manually.
- COULD NOT VERIFY — no primary benchmark for ScreenCaptureKit latency or CPU cost. A figure of '~1.9% of one core' for 60fps capture plus 48kHz audio on Apple Silicon appeared in a search summary attributed to the Rust screencapturekit crate, but crates.io returned no readable content on fetch. Treat that number as unconfirmed and measure on Kunal's own hardware before committing to a frame rate.
- COULD NOT VERIFY — the exact Command Line Tools version that first ships the macOS 26 SDK. Sources mention CLT 26.1.0.0.1.1761104275 and a CLT 26.3 existing, but no source I fetched states the bundled SDK version per CLT release, and `softwareupdate --list` on this machine offers no CLT package at all. Kunal should download from the developer portal and verify with `xcrun --show-sdk-version` rather than trusting a version number.
- COULD NOT VERIFY — Amp's cockpit specifics. ampcode.com/manual is a redirect stub and /docs exposed only that Amp has web, CLI and editor surfaces, threads, files/attachments and multi-model support (it lists 'GPT-5.6, Claude Fable 5'). I could not confirm how it renders tool calls, diffs, approvals or cost, so I excluded Amp from the pattern recommendations. Note also that github.com/sourcegraph/amp returns 404, so Amp is not open source at that path.
- COULD NOT VERIFY — whether cua ships any agent UI. Its README documents packages, the Sandbox API and Lume/Lumier VM management but mentions no Gradio, VNC or computer-view UI. Earlier cua versions reportedly had a Gradio agent UI; I found no current evidence, so do not plan on borrowing a ready-made cockpit from it.
- COULD NOT VERIFY — exact current Cursor version numbering and its Agents Window UI. The official changelog is dated but unversioned; a third-party source claims Cursor 3.0 shipped 2 April 2026 with an Agents Window showing every active local and cloud agent session. Unconfirmed against Cursor's own docs.
- PARTIALLY VERIFIED — Manus, Devin and Jules pane layouts rest on third-party reviews plus one Jules docs URL surfaced by search but not directly fetched. The patterns (three-pane plus replay scrubber; right-hand tabbed workspace with a Following switch; plan approval with auto-approve timer) are consistent across multiple independent sources, but no vendor screenshot was verified.
- NOT INVESTIGATED — Claude Desktop's UI, and the Claude Code terminal UI beyond locally confirming its permission-mode flags and settings.json shape. I verified `--permission-mode`, `--dangerously-skip-permissions` and the permissions.allow/additionalDirectories keys by running the binary on this machine, but did not research its rendering of tool cards, diffs or cost display.
- NOT INVESTIGATED — WebRTC as a live-view transport. Given the agent controls the local Mac, an in-process ScreenCaptureKit stream needs no transport at all, so WebRTC and VNC were assessed as unnecessary rather than benchmarked. If a remote/VM mode is ever added, that comparison still needs doing.

## Verified facts

- Apple's HIG states Apple platforms feature two material types, Liquid Glass and standard materials, and that Liquid Glass 'forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer'. It explicitly instructs: 'Don't use Liquid Glass in the content layer' and 'Use Liquid Glass effects sparingly.' Two variants exist, regular and clear; for clear over bright content Apple recommends a dark dimming layer of 35% opacity. This is the governing rule for a cockpit UI: glass belongs on the sidebar/toolbar/inspector chrome, never on the transcript or the live-view canvas.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/materials>
- SwiftUI's Liquid Glass API surface is macOS 26.0+ only. Exact signature: `nonisolated func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View`. Companion symbols all introduced at macOS 26.0: `GlassEffectContainer` (`@MainActor @preconcurrency struct GlassEffectContainer<Content> where Content : View`), `glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View`, `backgroundExtensionEffect() -> some View`, `ToolbarSpacer`, and `GlassButtonStyle` (also constructible as `.glass`).  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)>
- BLOCKER verified locally by compiling on this machine: the host runs macOS 26.5.2 (build 25F84) but `xcode-select -p` is /Library/Developer/CommandLineTools, `xcrun --show-sdk-version` returns 15.2, and the only SDKs present are MacOSX14.5.sdk, MacOSX14.sdk, MacOSX15.2.sdk and MacOSX15.sdk. Swift is 6.0.3 (swiftlang-6.0.3.1.10). Compiling `Text("hi").glassEffect(.regular, in: .rect(cornerRadius: 12))` fails with `error: value of type 'Text' has no member 'glassEffect'`, and grep finds zero occurrences of `glassEffect` in the SDK's SwiftUI .swiftinterface files. No Xcode.app is installed. Liquid Glass cannot be built until the macOS 26 SDK is installed.  
  — **confirmed** · <file:///Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/SDKSettings.plist>
- Verified locally that Command Line Tools alone ARE sufficient for a native SwiftUI Mac app short of Liquid Glass: `swiftc -parse-as-library -o BotHarness App.swift` compiled a SwiftUI `App`/`WindowGroup` binary (62,008 bytes, Mach-O thin arm64), and hand-assembling Contents/MacOS + Info.plist and running `codesign --force --sign -` produced a valid signed .app bundle. SwiftPM cannot emit .app bundles, so the bundle must be assembled by the build script.  
  — **confirmed** · <file:///private/tmp/claude-501/-Users-Kunal-Desktop-Bot-Harness/1cd5359a-3ff6-4e80-8270-1a0042486f93/scratchpad/apptest/BotHarness.app>
- The recursion problem for a live view of the LOCAL Mac has an official API answer: `init(display: SCDisplay, excludingApplications applications: [SCRunningApplication], exceptingWindows: [SCWindow])`. Apple describes it as 'a three-stage filter': specify a display, specify apps to exclude from output, then specify windows that are exceptions. Passing Bot-Harness itself as the excluded application removes the infinite-mirror effect while still capturing everything the agent acts on. Available macOS 12.3+, so it works on the current 15.2 SDK.  
  — **confirmed** · <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:)>
- ScreenCaptureKit throttling knobs for keeping a live pane cheap: `var minimumFrameInterval: CMTime { get set }` — 'Use this value to throttle the rate at which you receive updates. The default value is 0, which indicates that the system uses the maximum supported frame rate.' And `var queueDepth: Int { get set }` — 'By default, the system sets the queue depth to its minimum value of three frames... Don't exceed a queue depth of eight frames.' Both macOS 12.3+.  
  — **confirmed** · <https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval>
- Anthropic's current computer-use tool is `computer_toolset_20260801` (tool_use blocks carry `"toolset_name": "computer"`); the older `computer_20251124` requires a beta header. It exposes 17 member tools including `screenshot`, `zoom` (region `[x0,y0,x1,y1]`), `left_click`, `left_click_drag`, `scroll`, `type`, `key`, `hold_key`, and `wait`. Display dimensions are NOT toolset parameters — coordinates are always in the pixel space of the screenshots you return. Guidance: 1024x768 or 1280x720 for desktop tasks, avoid above 1920x1080; max long edge 2576px; screenshots cost roughly 1,000–1,800 input tokens each; keep 20 or fewer images per request; and explicitly 'macOS Retina: Account for 2x device pixel ratio'.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- The /Applications/Grok Bot.app reference product is an Anysphere (Cursor) Electron app, not an xAI or native app. CFBundleIdentifier is `com.anysphere.sand`, CFBundleShortVersionString 0.30.0, TeamIdentifier DCNK4UB866, built against DTSDKName macosx15.5, LSMinimumSystemVersion 12.0, with Electron Framework.framework and Squirrel.framework present. `codesign --verify --deep --strict` reports 'valid on disk' and 'satisfies its Designated Requirement', so it is a genuine signed build, not a renamed forgery. Corroborating evidence inside the app: plugin descriptions read 'Connect Cursor to Asana' and 'Airwallex integration skills for Cursor.'  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Info.plist>
- The reference app's 'computer' is a REMOTE VM streamed over noVNC, not the local Mac. Strings in app.asar include `noVNC`, `./core/rfb.js`, `noVNC_control_bar`, `noVNC_connected`, `vncUrl`, plus `computer_use_stream`, `computer_use_coordinate_mode` and `sand_computer_use_playwright`. Its Settings > Updates pane confirms the VM model: 'Update Grok Bot's Computer — Updates the computer your assistants share. Your files and logins stay, but installed apps and packages are removed. All assistants update together' and 'Reset Grok Bot's Computer — Start fresh if the computer gets stuck. It's rebuilt from your last saved snapshot.' The exact control-transfer label in the binary is 'Take over the computer'.  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Resources/app.asar>
- The reference app's approval model is a named feature called Auto-review, worth copying verbatim: 'Auto-review — Grok Bot checks each action before it runs and asks you first when needed. Add rules to customize what it can do automatically.' Below it sits 'Auto-review Rules — Write one short, natural-language rule for each action. "Ask first" takes priority if rules conflict', built as a two-field composer ('When Grok Bot wants to:' free text, e.g. 'reply to emails for me'; 'It should:' dropdown, e.g. 'Allow automatically') feeding an Action | Behavior table with edit and delete icons. Footer: 'These rules apply only to you. Built-in safety checks always apply.' Settings tabs are General, Computer, Usage & Billing, Updates — cost lives in its own tab, not in the chat.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/Screenshot%202026-08-29%20at%206.47.57%20PM.png>
- The reference app's actual pane layout contradicts the brief. Left (~300px) is a bot/conversation list, not a task list: '+' button, Search field, rows of avatar + title + right-aligned relative date + one-line preview, with 'Plugins' and an account row pinned at the bottom. Center is the conversation with a composer reading 'Message Joby'. Right is a Settings inspector (Name, Label, Description, Notifications toggle, 'Share as template'), NOT a live computer view. The computer is reached either via a screen icon at the far right of the conversation title bar or via an inline tool-call card. Current status appears as a floating pill at top-center of the conversation ('◯ Reconnecting'), not a bottom bar, with a degraded-state banner ('Showing saved messages — This conversation may be out of date and will refresh when the connection returns') and an inline sidebar retry ('Reconnecting to your computer… Retry').  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/Screenshot%202026-08-29%20at%206.47.11%20PM.png>
- The tool-call card pattern in the reference app is minimal and worth copying exactly: a card titled 'Computer', a right-aligned status pill '● Done' in green, one line of plain-language intent ('Enter the 8-character Atomicwork code from kunalbairwaiitd@gmail.com, then submit'), and a single secondary button with a monitor glyph labelled 'Open computer'. No raw JSON args, no stack of parameters.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/Screenshot%202026-08-29%20at%206.48.12%20PM.png>
- OpenAI's ChatGPT agent is dead as a reference product. Its help-centre article (updated ~14 days before 29 Aug 2026) opens with: 'ChatGPT agent is no longer available. Use ChatGPT Work for longer, multi-step tasks and finished deliverables. For supported browser workflows, see Using cloud browser in ChatGPT.' The same page still documents the interaction vocabulary worth stealing: it 'can be guided or interrupted mid-task', safeguards include 'user confirmations for high-impact actions' and 'a "watch mode" requiring user supervision on certain sites', and the best-practice line 'Avoid typing passwords or private info directly in messages; use takeover mode for sensitive inputs.' Operator was folded in on 17 July 2025 and operator.chatgpt.com deprecated.  
  — **confirmed** · <https://help.openai.com/en/articles/11752874-chatgpt-agent>
- Google's Project Mariner was discontinued on 4 May 2026; its capabilities moved toward the Gemini API/Gemini Agent and Chrome auto-browse. It is no longer a live reference cockpit.  
  — **confirmed** · <https://en.wikipedia.org/wiki/Project_Mariner>
- Running the agent inside a macOS VM (the non-recursive alternative to screen-excluding capture) is capped: Apple's Virtualization framework enforces a maximum of two simultaneous macOS guests per host, surfaced as 'The number of virtual machines exceeds the limit.' The licence permits 'up to two (2) additional copies or instances' for software development, testing, macOS Server, or personal non-commercial use. This is enforced in the kernel regardless of host specs.  
  — **confirmed** · <https://eclecticlight.co/2023/09/14/current-limitations-on-macos-virtual-machines-running-on-apple-silicon-macs/>
- Manus is the closest shipped analogue to the layout in the brief: a left rail of tasks, a center chat panel, and a third panel called 'Manus's Computer' that shows the agent traversing web pages in real time, which the user can interrupt and redirect, plus session replay where you 'roll back the timeline and observe each step in detail'. This is the three-pane-plus-scrubber pattern Bot-Harness should target.  
  — likely · <https://www.technologyreview.com/2025/03/11/1113133/manus-ai-review/>
- Devin's cockpit puts the agent's environment in a right-hand tabbed panel — Progress, Shell, Browser, Editor, Planner — with a 'Following' switch that, when ON, auto-switches the panel to whichever tool the agent is currently using. The Progress tab unifies shell commands, code edits and browser activity in one feed. The auto-follow toggle is the key idea: it lets one pane serve both live-watching and manual inspection.  
  — likely · <https://ppaolo.substack.com/p/in-depth-product-analysis-devin-cognition-labs>
- Jules uses an explicit plan-approval gate with a timeout escape hatch: it produces a step-by-step plan that you review, edit or reject and then click 'approve plan', but 'if you navigate away, Jules will eventually auto-approve the plan on a timer, so there is no need to babysit.' Diffs render as a mini diff inline in the feed with a full-screen expanded diff editor in the right pane. The auto-approve timer is the pattern that keeps a solo-developer harness from stalling overnight.  
  — likely · <https://jules.google/docs/review-plan/>
- Warp 2.0 is now open source under AGPL-3.0 (64,628 stars, pushed 2026-08-29) and describes itself as 'an agentic development environment, born out of the terminal.' It treats agents as sessions within terminal sessions, running several concurrently in split panes or vertical tabs, wrapping each agent with status badges, and providing a management UI showing the status of all running agents plus notifications when an agent completes or needs help. Being AGPL and readable, it is the best source to study for multi-agent status/notification UX.  
  — **confirmed** · <https://api.github.com/repos/warpdotdev/warp>
- Cursor's changelog corroborates that the 'Grok Bot' app is Anysphere's bot product line: the 3 August 2026 entry adds 'Google Workspace Plugins — Gmail, Google Drive, and Google Calendar integrations', which are exactly the three plugins shown as installed in the app's Plugins modal. The 19 August 2026 entry lists 'Improved steering without interrupting agent work' and '/goal command for long-lived objectives' — the mid-run interruption pattern the brief asks for.  
  — **confirmed** · <https://cursor.com/changelog>
- Claude Code's own approval vocabulary, verified locally via `claude --help`: `--permission-mode <mode>` accepts values including `bypassPermissions` and `manual`, alongside `--dangerously-skip-permissions` ('Bypass all permission checks') and `--allow-dangerously-skip-permissions`. The settings.json shape is `"permissions": { "allow": [...], "additionalDirectories": [...] }` with tool-pattern strings like `Bash(...)`. Since Kunal is a heavy Claude Code user, matching these mode names in Bot-Harness gives him zero-learning-curve mental mapping.  
  — **confirmed** · <file:///Users/Kunal/.claude/settings.json>
- For streaming markdown in the transcript pane, the long-standing SwiftUI choice MarkdownUI (gonzalezreal/swift-markdown-ui, 3,922 stars) is now explicitly in maintenance mode; its README redirects to gonzalezreal/textual (856 stars, MIT, pushed 2026-06-15), 'the spiritual successor to MarkdownUI', which 'preserves SwiftUI's Text rendering pipeline' and offers `InlineText` and `StructuredText` views, native text selection, syntax highlighting and inline attachments. Picking MarkdownUI today would be adopting an abandoned dependency.  
  — **confirmed** · <https://api.github.com/repos/gonzalezreal/textual>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [warpdotdev/warp](https://github.com/warpdotdev/warp) | reference-only — AGPL-3.0 makes linking it into a closed personal app legally awkward, but it is the best readable source for multi-agent status/notification UX. Read it, don't vendor it. | Rust, GPU-accelerated agentic development environment; agents as sessions in split panes/vertical tabs, per-agent status badges, a management UI for all running agents, and completion/needs-help notifications. | 64,628 | AGPL-3.0 | pushed 2026-08-29 |
| [trycua/cua](https://github.com/trycua/cua) | evaluate — MIT, actively developed, and `lume` is the ready-made answer if Bot-Harness ever needs a sandboxed macOS guest instead of driving the host Mac. Its README documents no bundled UI, so the cockpit is still yours to build. | Open-source computer-use platform: `cua` Python SDK, `cua-driver` (background computer-use for macOS/Windows/Linux), `cua-agent`, `cua-sandbox`, `cua-bench`, and `lume` for managing macOS/Linux VMs on Apple Silicon via Apple's Virtualization framework (Lumier gives a Docker-style interface). | 22,004 | MIT | pushed 2026-08-29 |
| [novnc/noVNC](https://github.com/novnc/noVNC) | reject for the primary path — it exists to stream a REMOTE machine into a web view. Bot-Harness drives the local Mac, where ScreenCaptureKit is lower-latency, native, and has no server to run. Keep in reserve only if a VM mode is added later. | VNC client web application; the exact library the Anysphere reference app embeds to render its remote agent computer (core/rfb.js and noVNC_control_bar are present in its bundle). | 13,966 | NOASSERTION (MPL-2.0 core, mixed) | pushed 2026-08-20 |
| [gonzalezreal/textual](https://github.com/gonzalezreal/textual) | adopt — the maintained successor to MarkdownUI and the right dependency for the streaming assistant transcript. Native text selection and the Text pipeline matter for a chat pane. | SwiftUI rich-text rendering engine that happens to support Markdown; preserves SwiftUI's Text pipeline, offers InlineText and StructuredText, native selection/copy-paste, syntax highlighting, inline attachments, font-relative layout. | 856 | MIT | pushed 2026-06-15 |
| [gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | reject — the repo description now literally reads 'Maintenance mode — new development in Textual'. Adopting it would be starting on a dead dependency. | The older MarkdownUI SwiftUI markdown renderer, widely recommended in tutorials and likely to be suggested by any model trained before 2026. | 3,922 | MIT | pushed 2025-12-28 |
| [browser-use/browser-use](https://github.com/browser-use/browser-use) | evaluate — only for the browser slice. Pixel-level computer-use is slow and token-expensive; routing web tasks through DOM automation and reserving screen control for native macOS apps is cheaper, and the reference app does exactly this (its bundle contains sand_computer_use_playwright). | Browser automation for AI agents (DOM-level rather than pixel-level control of web pages). | 111,625 | MIT | pushed 2026-08-29 |
| [nonstrict-hq/ScreenCaptureKit-Recording-example](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example) | reference-only — small and three years stale, but a useful shape-check for SCStream setup. Verify every API against current docs before copying. | Minimal worked example of driving SCStream to a file. | 64 | MIT | pushed 2023-09-28 |

## API and code shape

TOOLCHAIN GATE — run this first; everything else depends on it.

    sw_vers                      # confirmed: 26.5.2, build 25F84
    xcode-select -p              # confirmed: /Library/Developer/CommandLineTools
    xcrun --show-sdk-version     # confirmed: 15.2   <-- TOO OLD FOR LIQUID GLASS
    ls /Library/Developer/CommandLineTools/SDKs/
    # confirmed output: MacOSX14.5.sdk MacOSX14.sdk MacOSX15.2.sdk MacOSX15.sdk

Reproduction of the blocker (exact compiler output observed):

    $ swiftc -parse-as-library -c glass.swift
    glass.swift:2:51: error: value of type 'Text' has no member 'glassEffect'

Fix: install Command Line Tools for Xcode 26.x from https://developer.apple.com/download/all/
(requires an Apple ID), then re-check that `xcrun --show-sdk-version` reports 26.x.
Note `softwareupdate --list` on this machine offers only "macOS Tahoe 26.6.2-25G83" and no CLT
package, so the developer-portal .dmg is the path.

LIQUID GLASS (macOS 26.0+ — usable only after the SDK upgrade). Exact declarations:

    nonisolated func glassEffect(_ glass: Glass = .regular,
                                 in shape: some Shape = DefaultGlassEffectShape()) -> some View
    @MainActor @preconcurrency struct GlassEffectContainer<Content> where Content : View
    nonisolated func glassEffectID(_ id: (some Hashable & Sendable)?,
                                   in namespace: Namespace.ID) -> some View
    @MainActor @preconcurrency func backgroundExtensionEffect() -> some View
    nonisolated struct ToolbarSpacer
    nonisolated struct GlassButtonStyle          // also: .buttonStyle(.glass)

Apply these to the sidebar, toolbar and the floating status pill only. Per the HIG, the transcript
and the live-view canvas are content layer and must use standard materials instead.

LOCAL LIVE VIEW WITHOUT RECURSION — the load-bearing initializer:

    init(display: SCDisplay,
         excludingApplications applications: [SCRunningApplication],
         exceptingWindows: [SCWindow])

Pass Bot-Harness itself in `excludingApplications` so the live pane never renders itself.
Throttle the same stream two ways for two consumers:

    var minimumFrameInterval: CMTime { get set }   // default 0 == max supported frame rate
    var queueDepth: Int { get set }                // min 3; Apple: "Don't exceed a queue depth of eight frames"

Suggested split: minimumFrameInterval = CMTime(value: 1, timescale: 15) for the human-facing pane;
capture full-resolution stills on demand for the model, since model frames are needed only at
decision points, not continuously.

ANTHROPIC COMPUTER USE — current toolset (copy exactly):

    {"type": "computer_toolset_20260801"}
    // optional: {"type": "computer_toolset_20260801", "configs": {"zoom": {"enabled": false}}}

Older, requires a beta header: {"type": "computer_20251124"}

Every tool_result must carry the toolset name:

    {
      "type": "tool_result",
      "tool_use_id": "toolu_01...",
      "toolset_name": "computer",
      "content": [{"type": "text", "text": "OK"}]
    }

17 member tools: screenshot, zoom, left_click, right_click, middle_click, double_click,
triple_click, left_click_drag, mouse_move, left_mouse_down, left_mouse_up, cursor_position,
scroll, type, key, hold_key, wait.

Critical for a Retina Mac: display_width_px / display_height_px / display_number are NOT toolset
parameters. Coordinates live in the pixel space of the screenshot you return, so you must downscale
the capture, remember the factor, and scale the model's coordinates back up before dispatching the
click. Anthropic's own scaling helper:

    def get_scale_factor(width, height):
        long_edge_scale = 1568 / max(width, height)
        total_pixels_scale = math.sqrt(1_150_000 / (width * height))
        return min(1.0, long_edge_scale, total_pixels_scale)

Budget guidance from the same page: target 1024x768 or 1280x720, avoid above 1920x1080, keep 20 or
fewer images per request, and count roughly 1,000-1,800 input tokens per screenshot.

Batch-failure contract to mirror in the timeline UI — execute in order, stop at first failure, and
mark every skipped action with is_error plus this exact string:

    "Not executed: an earlier computer action in this turn failed."

REQUIRED Info.plist / TCC keys (the reference app's own set, minus its Electron-specific extras):

    NSScreenCaptureUsageDescription     # ScreenCaptureKit live view
    NSAppleEventsUsageDescription       # app scripting
    NSMicrophoneUsageDescription        # only if voice input ships

Accessibility (the API that actually moves the mouse and keyboard) has no Info.plist key; it is
granted in System Settings > Privacy & Security > Accessibility. Gate startup on:

    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    CGPreflightScreenCaptureAccess() / CGRequestScreenCaptureAccess()

BUILD WITHOUT XCODE — verified working on this machine:

    swiftc -parse-as-library -o BotHarness App.swift
    mkdir -p BotHarness.app/Contents/MacOS
    cp BotHarness BotHarness.app/Contents/MacOS/
    # write Contents/Info.plist by hand (SwiftPM cannot emit .app bundles)
    codesign --force --sign - --entitlements BotHarness.entitlements BotHarness.app

APPROVAL MODEL — exact copy to clone from the reference app:

    Auto-review
      "Grok Bot checks each action before it runs and asks you first when needed.
       Add rules to customize what it can do automatically."
    Auto-review Rules
      "Write one short, natural-language rule for each action.
       \"Ask first\" takes priority if rules conflict."
      When [BOT] wants to:  [ e.g. reply to emails for me        ]
      It should:            [ Allow automatically  v ]  [ Add Rule ]
      | Action                                   | Behavior            |
      | Use the browserUse subagent tool to ...  | Allow automatically |
      "These rules apply only to you. Built-in safety checks always apply."

Match Claude Code's mode names so Kunal carries one mental model across both tools:
`manual`, `acceptEdits`, `plan`, `bypassPermissions`, with settings shaped as
`"permissions": { "allow": [...], "ask": [...], "deny": [...], "additionalDirectories": [...] }`.

TEXT WIREFRAME — the layout I would build (NavigationSplitView with two sidebars):

┌────────────────────────────────────────────────────────────────────────────────────────────┐
│ ⬤⬤⬤   Bot-Harness            [run title]              ⟨Auto-review: on⟩  ▣ Computer  ⓘ     │ TitleBar (glass)
├──────────────┬─────────────────────────────────────────────────┬───────────────────────────┤
│ RUNS         │ CONVERSATION                                    │ COMPUTER                  │
│ (280pt)      │ (flex, min 520pt)                               │ (420pt, collapsible)      │
│              │                                                 │                           │
│ [+ New run]  │        ╭───────────────────────────╮            │ ┌───────────────────────┐ │
│ [Search    ] │        │ ◐ Filling form · 0:42  ⏸ │  ← floating │ │  LIVE VIEW            │ │
│              │        ╰───────────────────────────╯    status  │ │  SCStream @15fps      │ │
│ ● Jewel      │                                          pill   │ │  (self excluded)      │ │
│   partners   │  ┌────────────────────────────────┐             │ │                       │ │
│   2m · step  │  │ assistant text, streaming      │             │ │  ▣ Auto-follow  ⛶     │ │
│   4 of 9     │  └────────────────────────────────┘             │ └───────────────────────┘ │
│              │                    ┌──────────────────┐         │                           │
│ ◐ Job apply  │                    │ user message     │         │ [Screen│Steps│Diffs│Files]│
│   running    │                    └──────────────────┘         │                           │
│              │  ┌────────────────────────────────┐             │ ▸ 12  click Submit    ✓   │
│ ✓ Inbox      │  │ ▣ Computer          ● Running  │  tool card  │ ▸ 13  screenshot      ✓   │
│   done 1h    │  │ Enter the 8-char code, submit  │             │ ▸ 14  type "8QK…"     ⚠   │
│              │  │ [▣ Open computer]              │             │ ◀━━━━━━━●━━━━━▶  scrubber │
│ ─────────────│  └────────────────────────────────┘             │                           │
│ ⚠ Permissions│                                                 │ ┌───────────────────────┐ │
│   1 missing  │  ┌────────────────────────────────┐             │ │ TAKE CONTROL          │ │
│ ⚙ Settings   │  │ ⚠ Approve: send email to 3     │  approval   │ │ Agent paused &        │ │
│ KB  Kunal    │  │   recipients?                  │  card       │ │ not watching          │ │
│              │  │ [Allow once][Always][Deny]     │             │ │ [Resume agent]        │ │
│              │  └────────────────────────────────┘             │ └───────────────────────┘ │
│              │ ┌─────────────────────────────────────────────┐ │                           │
│              │ │ + Message…                             🎤 ⏎ │ │ run · 34.2k tok · $0.41   │
└──────────────┴─┴─────────────────────────────────────────────┴─┴───────────────────────────┘

Pane contract:
  RUNS         — run list, status glyph + title + relative time + current-step preview;
                 Permissions health row and account pinned bottom; inline "Retry" on degraded state.
  CONVERSATION — streaming markdown (Textual), tool-call cards, inline approval cards,
                 centered run-event dividers, composer at bottom.
  COMPUTER     — live view + Auto-follow toggle; segmented Screen/Steps/Diffs/Files;
                 Steps is the audit timeline with a seek scrubber; Take Control block;
                 per-run token/cost footer.
  STATUS PILL  — floating, top-center of CONVERSATION, three states: running / waiting for you /
                 failed. Glass. Disappears when idle.
