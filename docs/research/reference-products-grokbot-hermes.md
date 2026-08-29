# Reference products for Bot-Harness: "Grok Bot" (SpaceXAI + Cursor desktop agent app) and "Hermes Agent" (Nous Research) — UI/UX teardown and adoptable computer-use stack

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

Both names in the brief are real, but they are very different things and only one of them is technically borrowable. "Grok Bot" is a shipping commercial desktop app (v0.30.0, Electron, bundle id com.anysphere.sand, copyright "SpaceXAI") built jointly by SpaceXAI and Cursor/Anysphere — it is already installed on this machine at /Applications/Grok Bot.app, and 26 screenshots of it sit in /Users/Kunal/Downloads/GrokBot Screenshots, which is the best UX reference available and beats anything on the web. Its critical architectural difference from Bot-Harness: each Bot drives a persistent CLOUD VM, not the user's Mac, so its "live computer view" is a remote desktop stream, not local screen capture — cloning its look is easy, cloning its substance on a local Mac is a different engineering problem. "Hermes agent" almost certainly means NousResearch/hermes-agent (MIT, Python, ~238k stars, pushed 2026-08-29), not the Hermes 3/4 language models, and it is the more useful reference because it does exactly what Bot-Harness needs: drive a real Mac. Its computer-use layer delegates over MCP-stdio to cua-driver from trycua/cua (MIT, ~22k stars), which posts input to a specific process via macOS SkyLight private SPIs so the user's cursor never moves and focus is never stolen. That driver is the single highest-value thing to adopt: it solves the "agent uses my Mac while I keep using my Mac" problem that a naive CGEvent-posting harness cannot.

## Recommendation

Build Bot-Harness as a SwiftUI three-pane app that copies Grok Bot's UX vocabulary but Hermes/cua's architecture. Concretely: (1) Adopt cua-driver now — install CuaDriver.app, grant it Accessibility + Screen Recording, and drive it from Swift by spawning `/Applications/CuaDriver.app/Contents/MacOS/cua-driver mcp` as an MCP stdio subprocess. This is the decision that matters most: it gives Kunal a Mac-native agent that can work while he keeps using the machine, because SLEventPostToPid never moves the physical cursor. A harness that posts CGEvents instead will fight the user for the mouse and will feel broken. It also sidesteps the no-full-Xcode constraint, since the driver ships as a prebuilt signed app. (2) Copy Grok Bot's approval model verbatim in shape: split actions into read-only (capture, list_apps, list_windows — never prompt) and destructive (click, type, key, drag, focus_app — prompt), with four resolutions Allow once / Always / Deny / Never, and an explicit take-control handoff for exactly the four cases xAI enumerated (password or passkey, 2FA, CAPTCHA, payment or identity check) plus a masked secure-input field whose value never enters the transcript. Both reference products independently converged on this split, which is strong evidence it is right. (3) Model the log as Grok Bot does: one ordered append-only transcript stream carrying rows, agent-state changes, computer actions and screen frames, replayed from a cursor. That single structure satisfies both the live-view requirement and the "log every decision for future agents to audit" requirement without building two systems. (4) Steal Hermes' skills loop as the v2 differentiator, not v1 — the agent writing reusable skills from completed tasks is the feature that makes it compound, but it is orthogonal to shipping a working harness. (5) Do not try to replicate Grok Bot's cloud VM. Its "each Bot gets its own screen" parallelism comes from a remote multi-seat VM; on one local Mac, per-bot isolation has to come from either separate macOS user sessions or Lume VMs (also in trycua/cua, Apple Virtualization Framework, Apple Silicon). Ship single-agent-on-the-real-Mac first. One caution: cua-driver depends on undocumented private SkyLight SPIs, so treat a macOS point release as a real breakage risk and keep a foreground CGEvent fallback path behind a flag.

## Risks

- cua-driver's entire advantage rests on undocumented private Apple SPIs (SLEventPostToPid, SLPSPostEventRecordTo, _AXObserverAddNotificationAndCheckRemote). Any macOS point release can break or restrict these with no deprecation warning. Bot-Harness should keep a degraded foreground-control fallback and pin/vendor a known-good driver build rather than relying on its weekly auto-update.
- Known cua-driver gaps that will surface immediately in real use: right-clicks on web content are dropped by Chromium's renderer-IPC filter on non-HID-tap paths, and canvas apps (Blender, Unity, games) reject per-pid routes entirely and need brief foreground activation — which defeats the whole no-focus-stealing premise for those apps.
- Accessibility + Screen Recording are the two most invasive TCC permissions on macOS and they are granted to CuaDriver.app, not to Bot-Harness. That means the trust boundary is a third-party binary Kunal did not build. Anything the agent can do, that binary can do. Worth reading its install script before running it.
- Grok Bot's cloud-VM design means its UX is copyable but its guarantees are not. Its 'Reset Grok Bot's Computer' rebuilds from a snapshot; on a real Mac there is no snapshot to roll back to, so a misfired destructive action is permanent. The approval gate is doing much more safety work locally than it does in Grok Bot, and should be correspondingly stricter by default.
- Hermes Agent has 37,286 open issues against 237,952 stars — a very high ratio. Treat it as a design reference and a source of specific patterns, not as a dependency to build on. Vendoring its Python runtime into a Swift Mac app would also drag in a heavy toolchain that conflicts with the Command-Line-Tools-only constraint.
- The name 'Hermes' is genuinely ambiguous — Nous ships both an agent framework and a Hermes 4 model family, and several unrelated products use the name. Any future prompt, doc or skill in Bot-Harness that says 'Hermes' without qualification will be misread by a later agent. Write 'Hermes Agent (NousResearch/hermes-agent)' every time.
- Grok Bot is subscription-gated behind SuperGrok/Cursor plans and its weekly usage meter was at 100% in the screenshots. If Kunal is using it as a live UX reference, that access may lapse — capture any remaining UI states (the expanded computer view, an approval card mid-prompt, the routines editor) while access lasts.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- The brief's guesses 'Grokboard' and 'Grok Build agent' are wrong or misapplied. There is no 'Grokboard'. 'Grok Build' is real but is a separate SpaceXAI CODING agent documented at docs.x.ai/build/overview — it is not the computer-use teammate app. The correct product name is 'Grok Bot' (two words), docs at docs.x.ai/grok-bot/.
- The brief frames GrokBot as possibly 'a community project'. It is not — it is a commercial, closed-source, subscription-gated Electron app. Also note it is not purely xAI: the bundle identifier is com.anysphere.sand (Anysphere = Cursor), so Cursor's client codebase is clearly underneath it (the strings dump contains 'Failed to reach the Cursor API', 'Blocked by cursor ignore', 'PauseBackgroundComposer').
- 'xAI' now brands itself 'SpaceXAI' across docs.x.ai and the app's copyright string. If any Bot-Harness doc says 'xAI', that is now stale naming.
- WHICH MODEL POWERS GROK BOT — NOT VERIFIED. Neither docs.x.ai/grok-bot/overview nor /get-started names the model. Grok 4.6 is documented as SpaceXAI's frontier agentic model, and Grok 4.1 Fast is documented as usable with agent tools, but I found no primary source stating either one is what Grok Bot runs. Do not assert this.
- IS THERE A GROK BOT API — NOT VERIFIED, PROBABLY NO. The Grok Bot docs section contains no API reference. There is a separate Grok API (docs.x.ai/developers) with agent tools, web search, X search, code execution, function calling and a WebSocket Responses API mode, but that is the model API, not a programmatic interface to Grok Bot itself. docs.x.ai/llms.txt returned 404 so I could not enumerate the full doc tree to confirm.
- Grok Bot's expanded/full-screen Agent Computer view was NOT observed. All 26 screenshots show either the collapsed right-pane thumbnail ('Starting desktop') or the settings pane. My description of the expanded view is inferred from the docs phrase 'clicks, typing, navigation, and current status' plus the 'Open computer' button, not from a screenshot. Same for the live approval card mid-prompt and the routines editor UI.
- Whether Grok Bot's live view is video frames or a screenshot sequence is inferred from the protocol name GrokBotTranscriptWatchFrame in the asar strings, not from documentation. Treat as a strong hint, not a fact.
- The Hermes Agent star count (237,952) far exceeds the 140,000 figure NVIDIA published, and both were read today. The NVIDIA blog is presumably older than its content implies. I trust the GitHub API number; treat NVIDIA's as stale.
- cua.ai/docs/driver returned 404 and docs.cua.ai/driver 301-redirects there, so I could NOT retrieve the driver's canonical full action list. The action set I report comes from Hermes' wrapper (via DeepWiki) and the blog's CLI examples. The driver almost certainly exposes more actions than the nine Hermes surfaces — verify against the repo before designing to it.
- The DeepWiki page for Hermes' computer-use internals is a generated third-party wiki, not primary source. Module paths (tools/computer_use/tool.py, cua_backend.py) and the _approval_callback name should be confirmed against the actual repo before being written into Bot-Harness docs.
- Hermes 4.3's release date is reported by a search snippet as 25 August 2025 on a page titled for Hermes 4.3 — that date looks inconsistent with the 4.x timeline and I did not fetch nousresearch.com/introducing-hermes-4-3 directly. Do not cite the date.
- The claimed '95% reduction in token usage' for Hermes macOS computer control comes only from a KuCoin news-flash aggregator, which is not a credible primary source. Unverified; I would not repeat it.
- Perplexity MCP tools were unusable this session — the API key returned 401 insufficient_quota. All findings here come from WebSearch, WebFetch and direct local inspection instead.

## Verified facts

- "Grok Bot" is a real shipping macOS app, version 0.30.0, built on Electron (NSPrincipalClass AtomApplication, Resources/app.asar present), with CFBundleIdentifier com.anysphere.sand (Anysphere is Cursor's company), NSHumanReadableCopyright "Copyright © 2026 SpaceXAI", URL schemes grokbot:// and sand://, LSMinimumSystemVersion 12.0, category public.app-category.developer-tools.  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Info.plist>
- Grok Bot is built by SpaceXAI and Cursor, described as "in the process of becoming a single company"; it launched on Mac and iOS with Windows and Linux desktop versions also available and Android "coming soon". SpaceXAI markets Bots as "AI teammates you can give real work to" and states "Each Bot gets its own computer, then signs into the apps and services you already use to take on work across inboxes and other tools."  
  — **confirmed** · <https://9to5mac.com/2026/08/21/grok-bot-is-an-all-new-iphone-and-mac-app-from-spacexai-and-cursor/>
- Each Grok Bot runs on a persistent CLOUD VM containing a "browser, filesystem, and terminal". All of a user's Bots share one computer (shared files, browser sessions, app logins), but "Each Bot gets its own screen" so multiple Bots can work in parallel. Named Bots keep memory, files, browser sessions and preferences across sessions; Bots can message each other and pass ownership.  
  — **confirmed** · <https://docs.x.ai/grok-bot/overview>
- The user opens the live desktop by selecting Agent Computer from a conversation, which shows "clicks, typing, navigation, and current status". There is a shared durable workspace at /workspace. The user can take control to complete only blocked steps — specifically "A password or passkey", "Two-factor authentication", "A CAPTCHA", "A payment or identity check". For supported connectors, a secure request field is used instead, where "The value is masked and is not added to the conversation." Recovery lives under Settings → Beta (Update, Recover, or Reset Agent Computer); connectors under Settings → Plugins; @ attaches connectors in chat and / references saved skills.  
  — **confirmed** · <https://docs.x.ai/grok-bot/computer-and-apps>
- Grok Bot requires an eligible paid subscription: "SuperGrok Plus, SuperGrok Heavy, Cursor Pro+, Cursor Ultra, or Cursor Teams Standard or Premium", and supports macOS on Apple silicon and Intel plus Windows x64/Arm64 and iOS; Linux desktop is not supported by that setup page.  
  — **confirmed** · <https://docs.x.ai/grok-bot/get-started>
- Grok Bot's actual on-screen layout (observed in the user's own screenshots, 3600x2338 @2x): a three-pane dark window. Left rail ~15% width holds a Search field, a vertical list of named Bots each with a colored avatar glyph, bot name, relative timestamp ("Yesterday", "Thursday") and a one-line last-message preview; pinned to the rail bottom are "Plugins" and the account row. Center ~70% is the conversation: bot messages as left-aligned dark grey rounded bubbles, user messages as right-aligned lighter grey bubbles, inline monospace red-tinted code spans for emails/URLs, centered grey system lines ("Updated routine ⏱ Jewel partnership reply watch", date separators), inline action cards with a green "● Done" pill and an "Open computer" button with a monitor glyph, and a bottom composer reading "Message <BotName>" with a leading + attach button and a trailing microphone button. Right ~16% is a collapsible inspector that either shows the live computer thumbnail (loading state renders the literal text "Starting desktop" with a progress bar, captioned "<BotName>'s screen") or the Bot Settings form (avatar, Name, Label (optional), Description, a Notifications toggle reading "Get notified when this Bot finishes or needs input", and a bottom "Share as template" button). Header shows the bot avatar + name left, a gear and a » collapse chevron right.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/Screenshot%202026-08-29%20at%206.47.07%20PM.png>
- Grok Bot's Settings modal has four tabs: General, Computer, Usage & Billing, Updates. The Updates tab exposes an "Update Track" dropdown (Stable), a version row with a "Check for Updates" button, and a "Grok Bot's Computer" section with "Update Grok Bot's Computer" ("Your files and logins stay, but installed apps and packages are removed. All assistants update together.") and a destructive red "Reset" for "Reset Grok Bot's Computer" ("It's rebuilt from your last saved snapshot"). The account menu contains Weekly usage with a percentage and "Resets in N days" plus "Change limit", Get Grok Bot for iOS, Settings, About, Help Center, Send Feedback, Log out.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/Screenshot%202026-08-29%20at%206.48.04%20PM.png>
- Grok Bot's Plugins browser is a modal with an installed-count row, a "Search plugins" field, and category chips: All, Featured, Agent Orchestration, Canvas, Customer Support, Data Analytics, Design, Documents And Files, Finance And Legal, Inbox And Collaboration, Infrastructure, MCP, Payments, Productivity, Research, Sales, Scheduling. Each plugin row is icon + name + one-line description + an "Add" button, flipping to a green "✓ Added".  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/Screenshot%202026-08-29%20at%206.47.35%20PM.png>
- Strings extracted from Grok Bot's app.asar reveal the client/server protocol names, which map almost 1:1 onto what Bot-Harness needs: GrokBotTranscriptWatchRows, GrokBotTranscriptWatchAgentState, GrokBotTranscriptWatchAgentStateChanged, GrokBotTranscriptWatchComputerActions, GrokBotTranscriptWatchFrame, GrokBotTranscriptWatchHeartbeat, GrokBotTranscriptWatchCursorTooOld, GrokBotComputerAction, GrokBotUserComputerCapabilities, GrokBotHarnessRefusal, GrokBotHandoffLineage, InterruptGrokBotAgentRun. Permission resolution enums are GROK_BOT_LOCAL_TOOL_PERMISSION_CARD_RESOLUTION_{ALLOW_ONCE,ALWAYS,DENY,NEVER,UNSPECIFIED}; hand-back triggers are GROK_BOT_BOX_HAND_BACK_TRIGGER_{BUTTON,DISMISSED,VIEWER_CLOSED}; agent harness kinds are GROK_BOT_AGENT_HARNESS_KIND_{BOX,TEMPORAL}. Visible English UI strings include "Computer preview", "Open computer", "Starting desktop", "Approval needed", "Sensitive action", "Routines are recurring tasks this Bot runs on a schedule.", "Routine schedules must be at least 5 minutes apart.", "Routines paused while you were away", "All screens on the shared computer are in use. Try again in a moment."  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Resources/app.asar>
- NousResearch/hermes-agent is a real, extremely active MIT-licensed Python repo: 237,952 stars, 48,369 forks, created 2025-07-22, last pushed 2026-08-29, homepage https://hermes-agent.nousresearch.com, description "The agent that grows with you", topics include ai-agent, anthropic, claude, claude-code, codex, hermes-agent, nous-research.  
  — **confirmed** · <https://api.github.com/repos/NousResearch/hermes-agent>
- Hermes Agent installs on macOS with `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`, is model-agnostic (Nous Portal, OpenRouter, OpenAI, custom endpoints, switched via `hermes model`), routes every surface (CLI, Telegram, Discord, Slack, WhatsApp, Signal, email and more) through a single gateway process, and its headline differentiator is a built-in learning loop: "it creates skills from experience, improves them during use, nudges itself to persist knowledge, searches its own past conversations, and builds a deepening model of who you are across sessions."  
  — **confirmed** · <https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md>
- Hermes Agent drives a real macOS desktop — click, type, scroll, drag — "without moving your actual cursor or changing focus", via the open-source cua-driver. Enable with `hermes tools` (select Computer Use) or `hermes computer-use install`; diagnose with `hermes computer-use doctor`. macOS prerequisite is System Settings → Privacy & Security → grant Accessibility + Screen Recording. Three permission modes: standard (default), bounded (declared capability manifest of allowed apps/origins/tools reviewed once at launch), and unrestricted (--yolo). Guardrails: destructive actions require approval, hard-blocked key combos (force delete, lock screen, logout), hard-blocked shell patterns (curl | bash, sudo rm -rf /), and a system prompt that forbids clicking permission dialogs or typing passwords.  
  — **confirmed** · <https://hermes-agent.nousresearch.com/docs/user-guide/features/computer-use>
- Hermes' computer-use internals: tools/computer_use/tool.py exposes a single `computer_use` tool with action routing and safety enforcement; tools/computer_use/cua_backend.py speaks MCP over stdio to the external cua-driver, running a dedicated asyncio event loop on a background thread to marshal sync calls. Read-only actions: capture, wait, list_apps, list_windows, cua_browser_state. Approval-gated actions: click, drag, type, key, focus_app. Destructive actions route through _approval_callback. macOS uses private SkyLight SPIs; Windows uses SendInput + UI Automation; Linux uses X11 or Wayland via XWayland.  
  — likely · <https://deepwiki.com/NousResearch/hermes-agent/10.5-lsp-and-computer-use>
- trycua/cua is MIT-licensed, 22,005 stars, 1,512 forks, created 2025-01-31, last pushed 2026-08-29, homepage https://cua.ai, described as "Scale computer-use 2.0 with open-source drivers, cross-OS fleets, and benchmarks for training, evaluation, and data generation." It ships Cua Drivers (background automation on macOS/Windows/Linux), Cua Sandbox, Cua-Bench, and Lume (macOS/Linux VMs on Apple Silicon via Apple's Virtualization Framework).  
  — **confirmed** · <https://api.github.com/repos/trycua/cua>
- cua-driver achieves background input on macOS using three private Apple SPIs: SLEventPostToPid (posts synthesized events to one specific process, bypassing the HID tap, so the physical cursor does not move), SLPSPostEventRecordTo (flips a window's AppKit-active state without raising it — called twice, deliberately avoiding SLPSSetFrontProcessWithOptions which would raise the window), and _AXObserverAddNotificationAndCheckRemote (keeps occluded Electron apps' accessibility trees alive). It requires Accessibility and Screen Recording permissions granted to CuaDriver.app. Known limitations: right-clicks on web content are dropped by the renderer-IPC filter on non-HID-tap paths, and canvas apps (Blender, Unity, games) filter per-pid routes entirely and need brief foreground activation. Chromium needs a decoy LeftMouseDown/LeftMouseUp at (-1,-1) to tick the user-activation gate.  
  — **confirmed** · <https://cua.ai/blog/inside-macos-window-internals>
- Nous Research also publishes Hermes LANGUAGE MODELS on Hugging Face — NousResearch/Hermes-4-70B, Hermes-4-14B, Hermes-4-405B and Hermes-4-405B-FP8 — which are hybrid-mode reasoning models built on Llama-3.1 and Qwen 3 bases. These are a different product line from the Hermes Agent framework and are a real source of name collision.  
  — likely · <https://huggingface.co/NousResearch/Hermes-4-70B>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) | evaluate — do NOT adopt wholesale (Python, 37k open issues, huge surface area), but read tools/computer_use/, the approval-callback design, and the skills/memory loop closely. It is the closest existing thing to Bot-Harness's brief and it is MIT. | Self-hosted, model-agnostic persistent agent framework in Python. Gateway process fans a single agent out to CLI/Telegram/Discord/Slack/WhatsApp/Signal/email. Built-in learning loop that writes and refines its own skills, agent-curated memory, isolated sub-agents, execute_code programmatic tool calling, and a computer_use toolset that drives the real macOS desktop. | 237,952 | MIT | pushed 2026-08-29 |
| [trycua/cua (cua-driver)](https://github.com/trycua/cua) | adopt — this is the highest-value finding for Bot-Harness. It solves background Mac control, which is the hard part, is MIT, actively pushed the same day as this research, and is already the driver Hermes Agent depends on. Shelling out to its MCP server from Swift is far cheaper than reimplementing SkyLight SPI work. | Open-source cross-OS computer-use driver. On macOS it posts input to a specific process via SkyLight private SPIs so the user's cursor never moves and focus is never stolen. Installs CuaDriver.app to /Applications, symlinks a CLI to /usr/local/bin, and exposes both a CLI and an MCP stdio server. Also ships Sandbox, Cua-Bench and Lume (Apple Virtualization Framework VMs on Apple Silicon). | 22,005 | MIT | pushed 2026-08-29 |
| [Grok Bot (SpaceXAI + Cursor/Anysphere)](https://docs.x.ai/grok-bot/overview) | reference-only — it is proprietary and its agent runs in the cloud, not on the Mac, which is the opposite of Bot-Harness's premise. Copy the UX vocabulary and the approval/handoff model, not the architecture. The local install and 26 screenshots are the real asset here. | Closed-source Electron desktop app, v0.30.0, bundle id com.anysphere.sand. Named persistent Bots, each driving its own screen on a shared persistent cloud VM with browser, filesystem and terminal at /workspace. Plugins/MCP connector marketplace, Routines (scheduled recurring tasks, min 5 minutes apart), skills via /, connectors via @, approval cards, take-control handoff for passwords/2FA/CAPTCHA/payment, masked secure-request fields. | n/a (closed source) | proprietary, subscription-gated | v0.30.0 installed 2026-08-28 |
| [0xNyk/awesome-hermes-agent](https://github.com/0xNyk/awesome-hermes-agent) | reference-only — useful map of what a mature agent plugin ecosystem contains, worth skimming before designing Bot-Harness's own plugin/skill schema. | Independent community directory of skills, plugins, memory providers, tools and surfaces for Hermes Agent. | 5,491 | Other | pushed 2026-08-28 |
| [ZeroPointRepo/awesome-hermes-skills](https://github.com/ZeroPointRepo/awesome-hermes-skills) | reference-only — a concrete corpus of skill definitions to mine for the skill file format if Bot-Harness adopts an agentskills.io-compatible skill standard. | 350+ Hermes Agent skills, plugins and memory providers, MIT-licensed. | 479 | MIT | pushed 2026-08-27 |

## API and code shape

### cua-driver — macOS install (verbatim, from cua.ai blog)
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.sh)"
```
Installs `CuaDriver.app` to `/Applications` and symlinks the CLI to `/usr/local/bin`, with weekly auto-updates.
(README also lists the shorter form: `/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"`; Python SDK is `pip install cua`, Python 3.11+.)

### cua-driver — MCP server config (verbatim)
```json
{
  "mcpServers": {
    "cua-driver": {
      "command": "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
      "args": ["mcp"]
    }
  }
}
```

### cua-driver — CLI shape (verbatim examples)
```bash
cua-driver list_apps
cua-driver launch_app '{"bundle_id":"com.apple.calculator"}'
cua-driver click '{"pid":1234,"window_id":5678,"element_index":14}'
```
Note the addressing model: actions target `pid` + `window_id` + `element_index` (accessibility-tree element), NOT screen coordinates. That is what makes background control possible and is the single most important design decision to copy.

### macOS private SPIs cua-driver uses (verbatim names)
```
SLEventPostToPid                          // post events to one pid, bypasses HID tap -> cursor does not move
SLPSPostEventRecordTo                     // flip AppKit-active state without raising the window (called twice)
_AXObserverAddNotificationAndCheckRemote  // keep occluded Electron AX trees alive
```
Deliberately NOT used: `SLPSSetFrontProcessWithOptions` (would raise the window).
Chromium quirk: a decoy `LeftMouseDown`/`LeftMouseUp` at `(-1, -1)` is required to tick the user-activation gate before a real click.

### Hermes Agent — install and computer-use commands (verbatim)
```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
hermes model
hermes tools                    # select Computer Use
hermes computer-use install
hermes computer-use doctor      # health matrix: binary, platform, permissions, accessibility
```

### Hermes Agent — computer_use config block (verbatim, YAML)
```yaml
computer_use:
  permission_mode: standard      # or bounded
  capability_manifest: ""         # required for bounded
  grant_existing_profile: false   # opt-in for browser profiles
  no_overlay: false              # agent cursor visibility
  cua_telemetry: false           # telemetry disabled by default
```

### Hermes Agent — computer_use action set
Read-only (no approval): `capture`, `wait`, `list_apps`, `list_windows`, `cua_browser_state`
Approval-gated: `click`, `drag`, `type`, `key`, `focus_app`
Implementation: `tools/computer_use/tool.py` (action routing + safety), `tools/computer_use/cua_backend.py` (MCP-over-stdio to cua-driver on a background asyncio loop). Destructive actions route through `_approval_callback`.

### Grok Bot — internal protocol names extracted from app.asar (useful as a schema template)
```
GrokBotTranscriptWatchRows              GrokBotTranscriptWatchAgentState
GrokBotTranscriptWatchAgentStateChanged GrokBotTranscriptWatchComputerActions
GrokBotTranscriptWatchFrame             GrokBotTranscriptWatchHeartbeat
GrokBotTranscriptWatchCursorTooOld      GrokBotTranscriptWatchConnected
GrokBotComputerAction                   GrokBotUserComputerCapabilities
GrokBotHarnessRefusal                   GrokBotHandoffLineage
InterruptGrokBotAgentRun

GROK_BOT_LOCAL_TOOL_PERMISSION_CARD_RESOLUTION_{ALLOW_ONCE|ALWAYS|DENY|NEVER|UNSPECIFIED}
GROK_BOT_BOX_HAND_BACK_TRIGGER_{BUTTON|DISMISSED|VIEWER_CLOSED}
GROK_BOT_AGENT_HARNESS_KIND_{BOX|TEMPORAL}
GROK_BOT_AGENT_VISIBILITY_{OWNER|TEAM}
```
The transcript is a single ordered append-only stream carrying rows, agent-state changes, computer actions and video frames, replayed from a cursor with an explicit `CursorTooOld` failure mode and heartbeats. That is exactly the audit-log-plus-live-view shape the brief asks for.

### Grok Bot — verbatim UI strings worth reusing
```
"Open computer"      "Computer preview"     "Starting desktop"
"Approval needed"    "Sensitive action"
"Routines are recurring tasks this Bot runs on a schedule."
"Routine schedules must be at least 5 minutes apart."
"Routines paused while you were away"
"All screens on the shared computer are in use. Try again in a moment."
"Get notified when this Bot finishes or needs input"
```

### Grok Bot — text sketch of the three-pane layout (measured from the user's screenshots)
```
+----------------------------------------------------------------------------------------+
| ...                          [bot glyph] Jewel Partnership              (gear)   >>     |
+------------------+------------------------------------------------+--------------------+
|  ~15%            |  ~70%                                          |  ~16%              |
| +--------------+ |                                                | +----------------+ |
| | (mag) Search | |  +- system banner (grey, full width) ---------+ | |                | |
| +--------------+ |  | Showing saved messages                     | | | Starting       | |
|                  |  +--------------------------------------------+ | |   desktop      | |
| > [A] Jewel      |                                                | | [====------]   | |
|     Partnership  |  +- agent bubble (dark grey, left) -----------+ | +----------------+ |
|     Yesterday    |  | Pipeline as of now: ...                    | |  Jewel           |
|     Status?      |  +--------------------------------------------+ |  Partnership's   |
|                  |                                                |     screen        |
| > [B] Joby       |      .  Updated routine (clock) reply watch  . |                    |
|     Thursday     |                                                |  -- OR, flipped -- |
|     2070 Health. |                   +- user bubble (right) ----+ |                    |
|                  |                   | There is one more...     | |  [avatar]          |
|                  |                   +--------------------------+ |  Name  [Joby     ] |
|                  |                                                |  Label [Research ] |
|                  |  +- action card ---------------- (o) Done ---+ |  Description [ ... ]|
|                  |  | Computer                                  | |  Notifications (o) |
|                  |  | Enter the 8-char code from...              | |                    |
|                  |  |  [ (monitor) Open computer ]               | |                    |
|                  |  +-------------------------------------------+ |                    |
| ---------------- |                                                |                    |
| (plug) Plugins   |  +-------------------------------------------+ |                    |
| KB Kunal Bairwa  |  | +   Message Joby                     (mic) | | [Share as template]|
+------------------+--+-------------------------------------------+-+--------------------+
```
Notes for the clone: the right pane is ONE collapsible inspector that toggles between live-screen and bot-settings — it is not two separate panes. The live view starts as a small thumbnail in the inspector and expands to full-window on "Open computer". Every completed step becomes a persistent card in the transcript with a green "Done" pill, so the conversation IS the audit log. Chat is dark-only in the shipped build.
