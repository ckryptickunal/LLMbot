# Grok Bot teardown

**Method:** direct inspection of `/Applications/Grok Bot.app` (v0.30.0) on this machine plus
25 user-supplied screenshots at `~/Downloads/GrokBot Screenshots/`, captured 2026-08-29.
Everything below is observed evidence, not inference, unless a line says "Inference".

**Why this document exists:** Bot-Harness is the open-source, local-first answer to this app.
You cannot build the answer without knowing precisely what the question is.

---

## 1. What it actually is, structurally

| Property | Observed value | Source |
|---|---|---|
| Bundle identifier | `com.anysphere.sand` | `Contents/Info.plist` |
| Display name | Grok Bot | `CFBundleDisplayName` |
| Version | 0.30.0 | `CFBundleShortVersionString` |
| Copyright | © 2026 SpaceXAI | `NSHumanReadableCopyright` |
| Framework | Electron (`NSPrincipalClass = AtomApplication`, `Resources/app.asar`, `ElectronAsarIntegrity`) | `Info.plist` |
| Bundle size | 307 MB | `du -sh` |
| Built with | Xcode 16.4, macOS 15.5 SDK | `DTXcode = 1640`, `DTSDKName = macosx15.5` |
| Minimum macOS | 12.0 | `LSMinimumSystemVersion` |
| URL schemes | `grokbot://`, `sand://` | `CFBundleURLTypes` |
| Frameworks shipped | Electron Framework, Squirrel (auto-update), Mantle, ReactiveObjC | `Contents/Frameworks` |
| Helper processes | GPU, Plugin, Renderer, generic — the stock Electron set | `Contents/Frameworks` |
| Category | `public.app-category.developer-tools` | `Info.plist` |

### The two findings that matter most

**Finding 1 — Anysphere built it.** The bundle identifier is `com.anysphere.sand`. Anysphere is
the company behind Cursor. `sand` is the internal codename. This is corroborated inside the
product: the plugin catalogue contains entries whose descriptions read "Developer Environments
for **Cursor**: MCP …" (1Password) and "Airwallex integration skills for **Cursor**"
(Airwallex Developer). Grok Bot ships Cursor's plugin registry verbatim.

**Finding 2 — the computer is not local.** There is no native computer-use helper anywhere in
the bundle. `Contents/Helpers` and `Contents/Frameworks` contain only the stock Electron helper
apps plus Squirrel/Mantle/ReactiveObjC, none of which can drive a screen. Combined with the
"Starting desktop" progress bar in the right panel, the per-bot "*Bot name*'s screen" label, the
"Showing saved messages — this conversation may be out of date and will refresh when the
connection returns" banner, and a "Weekly usage 100% — resets in 5 days" meter, the conclusion
is firm: **each bot's computer is a cloud VM, and the Mac app is a thin client.**

Requested permissions in `Info.plist` are camera, microphone, audio capture and Bluetooth —
consistent with voice input. There is no screen-recording or accessibility usage string, which
is exactly what you would expect from an app that never touches the local screen.

> **This is the single most important strategic fact for Bot-Harness.** Grok Bot's bots live in
> a rented cloud desktop with none of your files, none of your logged-in sessions, and a weekly
> usage cap. Ours live on the Mac you are already signed into. That is not a smaller version of
> their product; it is the opposite trade, and it is the reason to build it.

---

## 2. The interface

Three columns, dark, chat-first. It reads as a messaging app whose contacts happen to be agents.

```
┌──────────────┬────────────────────────────────────────┬──────────────────┐
│ SIDEBAR ~310 │ CONVERSATION (flex)                    │ CONTEXT ~340     │
│              │                                        │                  │
│         [+]  │  ◆ Jewel Partnership          ⚙  »     │  ‹   Settings  » │
│ ┌──────────┐ │  ┌──────────────────────────────────┐  │                  │
│ │🔍 Search │ │  │ Showing saved messages           │  │   ┌──────────┐   │
│ └──────────┘ │  │ …will refresh when connection…   │  │   │ Starting │   │
│              │  └──────────────────────────────────┘  │   │ desktop  │   │
│ ▸ Jewel      │                                        │   │ ▓▓▓▓▓▓░░ │   │
│   Partnership│  ┌ bot message ─────────────────┐      │   └──────────┘   │
│   Yesterday  │  │ Pipeline as of now:          │      │  Jewel Partner-  │
│   Status?    │  │ Kalyan is live…              │      │  ship's screen   │
│              │  └──────────────────────────────┘      │                  │
│ ▸ Joby       │                                        │  ── or ──        │
│   Thursday   │       ┌ user message ─────────────┐    │                  │
│   2070 Healt…│       │ There is one more called  │    │      ◆ avatar    │
│              │       │ eternz                    │    │  Name  [______]  │
│              │       └───────────────────────────┘    │  Label [______]  │
│              │                                        │  Description     │
│              │      Updated routine ⏱ Jewel           │  [ persona     ] │
│              │      partnership reply watch           │  [ text area   ] │
│              │                                        │                  │
│              │  ┌ Computer ──────────── ● Done ┐      │  Notifications ⬤ │
│              │  │ Enter the 8-character code…  │      │                  │
│              │  │ [ 🖥 Open computer ]         │      │                  │
│              │  └──────────────────────────────┘      │  ⬆ Share as      │
│ 🔌 Plugins   │  ┌──────────────────────────────────┐  │    template      │
│ KB Kunal B.  │  │ ➕  Message Jewel Partnership  🎤│  │                  │
└──────────────┴──┴──────────────────────────────────┴──┴──────────────────┘
```

### Sidebar
`+` (new bot) top-right. Search field. Then a list of **bots**, not conversations — each row is
avatar, bot name, relative timestamp, and a one-line preview of the last message. Bottom rail:
`Plugins` and the signed-in account.

### Conversation
Header is the bot's avatar and name, with a gear (bot settings) and `»` (collapse right panel).

Message treatment:
- Bot messages: left-aligned, dark grey rounded rectangles, generous width, plain prose.
- User messages: right-aligned, lighter grey pills, hug their content.
- Inline code and email addresses render in a salmon/red monospace span.
- System events are centred, muted, no bubble: `Updated routine ⏱ Jewel partnership reply watch`.
- Date separators are centred and muted: `Yesterday 4:59 AM`.

**The tone of the bot's own writing is worth copying.** It is terse, factual, first-person and
decision-carrying: "28 CaratLane addresses bounced. They were guessed names BCC'd on the
marketing@ mail, every one 'address not found.' I won't retry any of them, and I won't BCC
guessed names again." It reports what it did, what it concluded, and what rule it is adopting
as a result. It never narrates its reasoning at length and never asks permission it already has.

### The Computer card
The one non-prose element in the message stream. A bordered card, inline:

```
┌─ Computer ─────────────────────── ● Done ─┐
│ Enter the 8-character Atomicwork code from │
│ kunalbairwaiitd@gmail.com, then submit     │
│ ┌──────────────────┐                       │
│ │ 🖥 Open computer │                       │
│ └──────────────────┘                       │
└────────────────────────────────────────────┘
```

Title `Computer`, a status pill (`● Done`, green dot), the natural-language task the computer
was given, and an `Open computer` button. This is both the progress indicator and the human
takeover door. Inference: the same card renders as running/blocked while in flight.

### Right panel
Two modes, toggled by `‹` / gear:
1. **Screen** — live view of that bot's desktop, captioned "*Bot name*'s screen". Shows
   "Starting desktop" with a determinate progress bar while the VM boots.
2. **Settings** — the bot's identity: avatar, **Name**, **Label** (optional; placeholder
   "Research, marketing, admin"), **Description** (the persona/system prompt), a
   **Notifications** toggle ("Get notified when this Bot finishes or needs input"), and
   **Share as template** pinned at the bottom.

Observed Description values are written as instructions in the third person about the user:
- "Runs corporate partnership outreach for JewelAI: finds the right big-company owners, drafts
  warm founder emails from kunal@araviai.com, and never leads with selling the company."
- "The user works with Workspace, LinkedIn, GitHub, Figma every day — start with those tools
  when suggesting connectors or taking on work."

---

## 3. The permission model — the best idea in the product

App Settings → General → Bot:

- **Auto-review** (toggle, on): "Grok Bot checks each action before it runs and asks you first
  when needed. Add rules to customize what it can do automatically."
- **Auto-review Rules**: "Write one short, natural-language rule for each action. **'Ask first'
  takes priority if rules conflict.**"
  - Composer: `When Grok Bot wants to:` [free text, e.g. *"reply to emails for me"*]
    → `It should:` [dropdown, e.g. *Allow automatically*] → `Add Rule`
  - Rules table: **Action** | **Behavior**, each row editable and deletable.
    Observed row: `Use the browserUse subagent tool to submit job applicat…` → `Allow automatically`
- Footer: "These rules apply only to you. **Built-in safety checks always apply.**"
- Below: a **Security Key** section.

Three properties are worth stealing outright:

1. **Rules are natural language, matched semantically** — not glob patterns over command
   strings. A user writes "reply to emails for me", not `Bash(gmail send:*)`. This is the right
   abstraction for non-engineers and it degrades gracefully for engineers.
2. **Deny wins.** "Ask first takes priority if rules conflict" is a stated, deterministic
   conflict rule, so an over-broad allow can never silently swallow a narrower ask.
3. **A non-overridable kernel.** "Built-in safety checks always apply" means the user-editable
   rule layer sits *above* a floor it cannot lower. Bot-Harness needs the same two-layer split.

The observed rule text names a `browserUse` subagent tool, which confirms these bots delegate to
named subagents rather than running one flat tool loop.

Other settings panes: **Computer**, **Usage & Billing**, **Updates**. General also carries
"Use hardware acceleration" and a Timezone selector (`Auto-detect (Asia/Calcutta)`).

Account menu: **Weekly usage 100%** — "Resets in 5 days" — with a **Change limit** action, plus
Get Grok Bot for iOS, Settings, About, Help Center, Send Feedback, Log out.

---

## 4. Plugins

A modal, not a page. Header shows stacked icons of installed plugins and "3 installed ›".
Search field, then filter chips:

`All` · `Featured` · `Agent Orchestration` · `Canvas` · `Customer Support` · `Data Analytics` ·
`Design` · `Documents And Files` · `Finance And Legal` · `Inbox And Collaboration` ·
`Infrastructure` · **`MCP`** · `Payments` · `Productivity` · `Research` · `Sales` · `Scheduling`

Below, sectioned rows (each section has "View all"), two per row: icon, name, one-line
description, and an `Add` button that becomes `✓ Added`.

Observed entries — Gmail ("Search, read, draft, and manage email", added), Google Drive
("Search, read, create, and share files", added), Google Calendar, Granola, Arize, Atlan, AWS
Agents, AWS SageMaker, Docs Canvas ("Render documentation as a navigable canvas"), PR Review
Canvas ("Render PR diffs as review canvases grouped by impo…"), 1Password, Agent Compatibility
("CLI-backed repo compatibility scans plus agents tha…"), Aikido, Aleph, 1inch, Airwallex
AgentOS, Airwallex Developer, Brex, Adobe Developer App Builder, AgentMail.

Note that `MCP` is one category among seventeen. Inference: "plugin" is the user-facing noun and
MCP is one of several transports beneath it. Bot-Harness should adopt the same framing — users
install *plugins*; that a plugin happens to be an MCP server is an implementation detail.

`Canvas` as a category is notable: plugins can contribute **rendered views**, not just tools.

---

## 5. What Bot-Harness takes, and what it refuses

### Take
- Bots as first-class named entities with avatar, label, description-as-persona, and per-bot
  notification settings.
- Messaging as the primary interface. No task-board, no node graph. A list of bots you talk to.
- The inline **Computer card** as the single pattern for "the agent is using a machine" and for
  human takeover.
- Natural-language permission rules, deny-wins conflict resolution, and an unlowerable safety floor.
- Plugins as the user-facing noun, with a searchable categorised catalogue.
- Routines as a first-class, visible object that emits system lines into the conversation.
- Bots as shareable templates.
- The bot's writing voice: terse, first-person, decision-carrying, no reasoning theatre.
- A visible usage/limit meter. Users of their own API keys need this more, not less.

### Refuse
- **The cloud desktop.** Ours runs on the user's Mac, against their real files and real
  logged-in sessions. This is the whole point.
- **Electron and 307 MB.** Native SwiftUI, built with Swift Package Manager, no Xcode required.
- **The closed model.** Bring your own provider, your own keys, your own agents.
- **A single vendor's brain.** Gemini, the local `claude` CLI, and anything else, side by side.
- **Weekly caps set by someone else.** The limit is the user's, and it is theirs to change.

### Add, because they do not have it
- **Channels** — several bots and the human in one conversation, so bots collaborate rather than
  each working alone in a private thread.
- **A complete local decision trace.** Every step, every tool call, every approval, on disk,
  greppable and replayable.

---

## 6. Provenance and caveats

- All structural claims come from reading the installed bundle's `Info.plist` and directory
  listing with `plutil`, `ls`, `find`, `du` and `strings`. No proprietary source was extracted,
  decompiled, or reused. `app.asar` was not unpacked.
- All interface claims come from the 25 supplied screenshots and are described, not copied.
- Lines marked "Inference" are reasoned from evidence, not directly observed.
- Version pinned at 0.30.0, observed 2026-08-29. Re-verify before relying on any specific
  wording; this is a fast-moving product.
