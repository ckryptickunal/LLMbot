# Settings and configuration information architecture for Bot-Harness (macOS SwiftUI, zero-dependency)

> Verified 2026-08-30 against live sources.

## Bottom line

Apple's own guidance settles most of the open questions, and it happens to endorse the decision already made: "Put general, infrequently changed settings in your custom settings area" and "prefer letting people modify task-specific options without going to your settings area… Putting this type of option in a separate settings area disconnects it from its context." That is the licence for model and autonomy living in the composer, and it is also the argument for keeping per-bot settings in the right-hand inspector and out of the Settings window entirely. The window pattern should be a sidebar, not toolbar tabs: the HIG text still describes a toolbar, but Apple's own System Settings is a sidebar, and SwiftUI ships `.tabViewStyle(.sidebarAdaptable)` which on macOS "always show[s] a sidebar" — the practical rule is toolbar tabs up to about five panes, sidebar beyond that or when any pane holds a browsable list. Bot-Harness needs seven panes and one of them is a live connection list, so it is a sidebar. Two implementation facts matter: `.sidebarAdaptable` is macOS 15.0+ while Package.swift currently declares `.macOS(.v14)`, and the codebase already contains a six-state `ProviderHealth` enum with a per-state action verb (Check / Connect / Repair / Reconnect), which is the exact spine the Connections pane needs. The current three-tab SettingsView (Providers, Permissions, About) is roughly a third of the surface the app actually has, and its Permissions pane is read-only — the global rules render but there is no way to add, edit or delete one, which is the single largest dead end in the app today.

## Concrete specifications

═══════════════════════════════════════════════════════
PART 1 — THE WINDOW SHELL
═══════════════════════════════════════════════════════

DECISION: sidebar, not toolbar tabs.
Rule of thumb to write into the ADR: up to 5 panes, none of which contains a
browsable list → toolbar tabs (HIG's literal text, and what SwiftUI's `Settings`
scene gives you for free). 6+ panes, or any pane holding a live list → sidebar,
because a toolbar tab row cannot hold 7 items without truncating and because a
list pane needs a resizable window, which a "resize to fit the pane" toolbar
window cannot have.

Implementation: `NavigationSplitView`, NOT `TabView(.sidebarAdaptable)`.
  · `.sidebarAdaptable` is macOS 15.0+; Package.swift says `.macOS(.v14)`.
  · More importantly, NavigationSplitView is the only one of the two where you
    control the sidebar row rendering, and the user asked for a real visual
    language. `sidebarAdaptable` inside a `Settings` scene also has open
    AppKit-bridging bugs (centred toolbar items, sidebar toggle you must strip
    with `.toolbar(removing: .sidebarToggle)`).

Window:
  default    940 × 660 pt
  minimum    860 × 560 pt
  maximum    1180 pt wide, unbounded height
  sidebar    fixed 210 pt (`.navigationSplitViewColumnWidth(210)`)
  resizable  yes (justified: Connections and Activity are scrollable lists)
  minimise + zoom buttons dimmed:
      if let w = NSApp.keyWindow { w.standardWindowButton(.miniaturizeButton)?.isEnabled = false
                                   w.standardWindowButton(.zoomButton)?.isEnabled = false }
  title      = the current pane's name ("Connections"), per HIG. No subtitle.
  ⌘,         opens. Escape and ⌘W close. ⌘F focuses the sidebar search field.
  last pane  restored from @AppStorage("settings.lastPane"), per HIG.
  no Save / Cancel / Apply anywhere. Every control commits on change.

Pane switch motion: crossfade only, DS.Motion.instant (0.12 s). No slide, no
window resize animation — the window is a fixed size so the HIG resize dance
does not apply, and a settings window that jumps size is the single most
disliked thing about the old NSPreferences pattern.

═══════════════════════════════════════════════════════
PART 2 — VISUAL LANGUAGE (exact values, all from DS tokens)
═══════════════════════════════════════════════════════

Hex equivalents of the DS.Colour tokens you already have (sRGB):
  ground   #0D0D0E    panel   #131314    raised  #1A1A1C    overlay #232325
  done     #59D97A    running #FABF4D    failed  #F27070    waiting #73ADFA
  ink 93% white · inkSecondary 58% · inkTertiary 34% · inkDisabled 20%
  line 7% white · lineStrong 14%

SIDEBAR
  background            DS.Colour.panel (#131314)
  trailing hairline     1 pt DS.Colour.line
  search field          top, 8 pt inset all round, height 24, DS.Radius.sm,
                        DS.Colour.fill background, placeholder "Search settings"
  group header          DS.Text.micro (10.5) uppercased, tracking 0.6,
                        DS.Colour.inkTertiary, 18 pt top / 6 pt bottom padding,
                        12 pt leading inset
  row height            28 pt
  row inset             8 pt leading, 10 pt trailing
  row content           SF Symbol 14 pt (fixed 18 pt frame) + 8 pt gap +
                        DS.Text.body label
  row icon colour       DS.Colour.inkSecondary; selected → DS.Colour.ink
  selected background   DS.Colour.fillSelected, DS.Radius.sm (6)
  hover background      DS.Colour.fillHover
  attention badge       trailing, DS.Text.micro on DS.Colour.failed capsule,
                        height 15, horizontal padding 5 — shows a count, e.g. "2"

CONTENT
  background            DS.Colour.ground (#0D0D0E)
  outer padding         DS.Space.xxl (24) all round
  content column        max 640 pt, LEFT aligned (never centred — a centred
                        column drifts when panes have different heights)
  pane title            none. The window title already says it. Repeating it
                        inside costs 40 pt of vertical space on every pane.
  pane intro paragraph  DS.Text.caption (11.5), DS.Colour.inkSecondary,
                        max width 560, 16 pt below, only where the pane needs a
                        stated rule (Brains, Permissions, Bot Defaults)
  section header        DS.Text.caption (11.5) DS.Colour.inkSecondary,
                        sentence case, 12 pt above its card, 8 pt leading inset
  card                  DS.Colour.raised (#1A1A1C), DS.Radius.lg (10), no border
  gap between cards     DS.Space.xl (16)
  gap between sections  DS.Space.xxl (24)
  row inside card       12 pt horizontal, 10 pt vertical padding,
                        min height 44 (DS.Size.rowHeight) for a bare row,
                        auto height when help text is present
  row divider           1 pt DS.Colour.line, inset 12 pt from the leading edge,
                        flush to the trailing edge
  control column        right-aligned; the control's leading edges are aligned
                        across every card in a pane (use a shared alignment guide,
                        not `Spacer()`, or the columns will not line up)
  control vertical align pinned to the LABEL's first-line baseline, not the row's
                        vertical centre. A switch that floats to the middle of a
                        three-line help paragraph looks unattached.

DESTRUCTIVE CARD (used exactly twice: Permissions, Activity & Traces)
  background            DS.Colour.raised
  stroke                1 pt DS.Colour.failed at 28% opacity
  header                no "Danger zone" label. Name the actual thing.
  action button         `.buttonStyle(.plain)` with DS.Colour.failed label text,
                        right-aligned, DS.Text.body. Never a filled red button —
                        a filled red button in a settings pane reads as the
                        primary action of the pane, which it never is.

═══════════════════════════════════════════════════════
PART 3 — FORM CONTROL RULEBOOK
═══════════════════════════════════════════════════════

LABEL PLACEMENT — two rules, no exceptions:
 · Settings row (switch, pop-up, stepper, short value): LABEL LEFT, CONTROL RIGHT.
   This is the macOS grouped-form convention; System Settings, Raycast and Grok
   Bot all do it, and it is what makes a column of unrelated rows scan.
 · Free-text configuration (a name, a command, a URL, a rule you are writing):
   LABEL ABOVE THE FIELD. A left-hand label next to a 500 pt text field wastes
   the width and destroys the control-column alignment.
 Decision test: if the control is wider than ~200 pt, the label goes above.

HELP TEXT:
 · Always directly BELOW THE LABEL, inside the label's column. Never below the
   control, never to the right, never in a tooltip only.
 · DS.Text.caption (11.5), DS.Colour.inkSecondary, max width 420 pt.
 · One sentence. If a second is needed, it says what happens when the setting
   is off — that is the only second sentence that ever earns its place.
 · Never restate the label. "Open at login — Opens Bot-Harness when you log in"
   is noise; delete the help text, not the setting.

CONTROL CHOICE — the table to implement against:
 ┌ situation ──────────────────────────────┬ control ──────────────┬ why ──────┐
 │ binary, emphasised, one row in a        │ mini switch           │ HIG: "Within a grouped form,
 │ grouped form                            │ .controlSize(.mini)   │ consider using a mini switch"
 │ binary, one setting governs sub-settings│ checkbox + indented   │ HIG: checkbox for hierarchy
 │                                         │ child checkboxes      │
 │ multi-select from a list (which tools,  │ checkboxes, leading   │ HIG: checkboxes for multiple
 │ which connections)                      │ edges aligned         │
 │ 2–5 exclusive options, all worth showing│ segmented control     │ HIG: max ~5–7 segments; noun
 │ at once, changed often, short labels    │                       │ labels; no intro label needed
 │ >5 exclusive options, or the list grows │ pop-up button         │ HIG: ">about five options,
 │ at runtime (models, brains, timezones)  │                       │ consider a pop-up button"
 │ a list of ACTIONS, or a submenu         │ pull-down button      │ HIG pop-up: "Use a pull-down
 │                                         │ (never a pop-up)      │ button instead if you need to
 │                                         │                       │ offer a list of actions"
 │ exclusive options each needing its own  │ radio buttons with    │ HIG: "multiple radio buttons
 │ explanation                             │ per-option help text  │ can help you clarify each"
 └─────────────────────────────────────────┴───────────────────────┴───────────┘

THE ONE DELIBERATE INCONSISTENCY: Autonomy is a POP-UP in Settings and a
SEGMENTED CONTROL in the composer. Same value, two controls, on purpose — in
Settings it is one quiet row among twenty; in the composer it is changed every
few messages and all three states must be visible without a click. Three
segments is comfortably inside HIG's five-to-seven limit. Write this down in a
comment or someone will "fix" it.

STATE INDICATION: never colour alone. HIG is explicit: "Avoid relying solely on
different colors to communicate state." Every health/permission state gets a
glyph AND a word; the colour is the third channel, not the first.

═══════════════════════════════════════════════════════
PART 4 — THE COMPLETE IA
═══════════════════════════════════════════════════════

Sidebar, exactly seven panes:

    ⚙︎  General
    ── CAPABILITY ──────────
    ✳︎  Brains
    ⚡︎  Connections              [2]     ← attention badge
    ── SAFETY ──────────────
    ✋  Permissions
    ⊞  Bot Defaults
    ── RECORD ──────────────
    ☰  Activity & Traces
    ────────────────────────
    ⓘ  About

SF Symbols: gearshape / sparkles / powerplug.fill / hand.raised.fill /
plus.square.on.square / list.bullet.rectangle / info.circle

───────────────────────────────────────────
PANE 1 — GENERAL
───────────────────────────────────────────
Card "Startup"
  · "Open at login"                              mini switch, default off
  · "Show in the menu bar"                       mini switch, default off
      help: "A menu bar item shows what your bots are doing while the window
             is closed."
  · "Reopen the last conversation at launch"     mini switch, default on

Card "Notifications"
  · "When a bot finishes"                        mini switch, default on
  · "When a bot needs you"                       mini switch, default on
      help: "A bot waiting for permission stops until you answer."
  · row, no control: "Sounds, banners and grouping are set by macOS."
      trailing button: "Open Notification Settings"
      → x-apple.systempreferences:com.apple.Notifications-Settings.extension

Pane footer, DS.Text.caption inkTertiary:
  "Bot-Harness follows your system appearance, language and accessibility
   settings. There is nothing to set here."

DELIBERATE OMISSION: no Theme picker, no Language picker. Grok Bot ships both
set to "Follow System", and HIG says plainly not to: "Respect people's
systemwide settings and avoid including redundant versions of them."

───────────────────────────────────────────
PANE 2 — BRAINS
───────────────────────────────────────────
Intro (keep the existing sentence, it is good):
  "Bot-Harness runs on your own accounts. Keys are stored in the macOS Keychain
   and are never written to a file, put in a prompt, or recorded in a trace."

Card "Default"
  · "New bots use"                pop-up, lists only brains that are ready;
                                  unavailable ones appear greyed with a
                                  " — no key" suffix rather than being hidden
      help: "Any bot can be switched to a different brain from its composer."

Card "Providers" — one expandable row each, in this order:
  Row anatomy (56 pt collapsed):
    [glyph 14] Name (13 semibold)                    [state pill] [chevron]
               subtitle (11.5 inkSecondary)

  · Claude Code
      ready:    "Signed in. Billed to your Claude subscription."
                third line, DS.Text.mono(10.5) inkTertiary: the resolved path
                pill "Ready" (done)
      missing:  "Not found. Install the Claude Code CLI to use your
                 subscription as a brain."
                trailing button "How to install" (opens the docs page)
  · Google Gemini
      "Drives the computer — screen, keyboard and mouse. Key from
       aistudio.google.com."
  · Anthropic API
      "Only needed if you have an API key. A Claude Code subscription is
       handled above."
  · OpenAI
      "Optional. Available as an additional brain."

  Collapsed with a key saved:   "••••••••" (mono, inkTertiary) + pill "Key saved"
  Collapsed with no key:        button "Add key"
  Expanded:                     SecureField (mono 12, DS.Radius.sm) +
                                "Save" (default) + "Cancel"
  Saved, expanded:              "Replace"  ·  "Remove" (red label)

  Keep the existing write-only rule and say it out loud in the expanded state,
  DS.Text.micro inkTertiary: "Bot-Harness cannot read this back to you."

  "Remove" confirmation (uncommon + not undoable → alert is warranted):
    title:  "Remove your Gemini key?"
    body:   "Bots set to Gemini stop until you add a key again. Bot-Harness
             cannot show you this key, so make sure you have it elsewhere."
    buttons: "Remove Key"  ·  "Cancel"
    NOT destructive-styled — the user deliberately chose it (HIG's Empty Trash
    rule).

Pane footer — the sentence that closes the composer/Settings loop:
  "Model and autonomy are chosen per message, in the composer. They change too
   often to be settings."

───────────────────────────────────────────
PANE 3 — CONNECTIONS   ← the health list
───────────────────────────────────────────
This pane renders `ProviderHealth` from Capability.swift. Do not invent a
second status vocabulary.

Summary strip (not a card; 32 pt tall, sits above the search field). Three
filter chips, each toggling the list filter, plus a right-aligned control:
    [✓ 6 connected]  [▲ 2 need you]  [○ 1 off]        Check all · 2 min ago
  · chips use DS.Colour.fill, DS.Radius.pill, height 22, DS.Text.caption;
    selected chip → DS.Colour.fillActive with an ink label
  · "Check all" is a plain button; the relative time under it is
    DS.Text.micro inkTertiary and updates from `ProviderHealth.checkedAt`

Search field: "Search connections", ⌘F.

THE ONE IA DECISION THAT MATTERS HERE: sort by state, worst first, not
alphabetically. Group headers in this order:
    NEEDS YOU   →   CONNECTED   →   OFF
A connections list that buries a broken connector between two working ones is
the reason people think agents are flaky.

Row anatomy (56 pt collapsed, 12 pt padding):
  [icon 22]  Linear                    ✓ Connected · 14 tools    [switch] [⌄]
             Issues, projects and cycles
  · icon: provider icon, or a DS.BotTint-derived rounded square (DS.Radius.sm)
    with the initial when there is none
  · name: DS.Text.body semibold
  · second line: the CapabilityDomain summary already in the model
    ("issues, tasks and tickets")
  · state: glyph + word + detail, DS.Text.caption. Glyph and colour per state:
      healthy       checkmark.circle.fill       done     "Connected · 14 tools"
      degraded      exclamationmark.triangle.fill running "Degraded · 2 of 9 tools failing"
      needsAuth     key.fill                    waiting  "Needs sign-in"
      initializing  circle.dotted               inkTertiary, opacity pulsing
                                                0.4→1.0 over 1.2 s   "Starting…"
      offline       powerplug.slash             inkTertiary "Offline · exited 3s ago"
      error         xmark.octagon.fill          failed   "Error · command not found: npx"
  · action button: the verb already in the model —
      degraded "Check" · needsAuth "Connect" · offline "Repair" · error "Reconnect"
    healthy and initializing render nothing in that slot.
  · trailing mini switch: enabled / disabled for all bots.

Expanded row (inline, inside the same card, 12 pt top divider):
  · "14 of 14 tools available to bots"   +  pull-down "Select…"
        { All · None · Read-only }
    then a wrapping set of operation chips, DS.Text.mono(10.5), DS.Radius.xs,
    each with a checkbox. Excluded chips drop to inkDisabled with a strikethrough.
  · "Command"  DS.Text.mono(11) truncating middle, with a copy icon button
  · "Last check"  "Connected in 340 ms · 29 Aug at 19:07"
  · button "Show last 50 lines" → opens the Activity window filtered to this
    provider. This is what makes an error row not a dead end.
  · footer, right-aligned: "Remove Connection" (red label, plain style)
        confirmation title: "Remove Linear?"
        body: "Bots lose 14 tools. Your Linear account is not affected and
               nothing is deleted there."
        buttons: "Remove"  ·  "Cancel"

Pane footer, two buttons left-aligned:
    [+ Add MCP Server…]   [Browse Library…]
  "Browse Library…" opens the existing LibrarySheet. Both must exist; a
  connections pane with no way to add a connection is the classic dead end.

"Add MCP Server" sheet (480 pt wide) — labels ABOVE, because these are
free-text config fields:
  · "Name"           placeholder "Linear"
  · "How it runs"    segmented control: [Command] [URL]   ← 2 exclusive options,
                     both worth showing → segmented is correct
  · Command branch:
      "Command"      mono field, placeholder
                     "npx -y @modelcontextprotocol/server-linear"
      "Environment"  key/value table with a [+] row
  · URL branch:
      "URL"          placeholder "https://mcp.example.com/sse"
      "Headers"      key/value table with a [+] row
  · sheet footer, DS.Text.caption inkSecondary:
      "Bot-Harness starts this on your Mac and lists whatever tools it offers.
       It runs with your account's access to your files."
  · buttons: "Cancel"  ·  "Add and Test" (default)
  · the result appears IN the sheet before it dismisses:
      "Connected. 14 tools."   or   "Could not start — command not found: npx"
    Never dismiss into an unknown state.

───────────────────────────────────────────
PANE 4 — PERMISSIONS
───────────────────────────────────────────
Intro:
  "Rules that apply to every bot. Write one short rule per action, in plain
   language. Ask first wins when two rules could both apply."

Card A "Your rules"  — this is the composer the current app is missing entirely
  · label above: "When a bot wants to"
      text field, placeholder "reply to emails for me"
  · label above: "it should"
      pop-up: "Allow automatically" · "Ask first" · "Never allow"
      (exactly PermissionRule.Behaviour.displayName — do not re-word)
  · trailing: "Add Rule", disabled while the text field is empty
  · rules table below:
      columns  Action (flex) | Behaviour (150) | edit + trash icon buttons
      the Behaviour cell IS a pop-up, editable in place — no edit mode, no
      modal. Icon buttons appear on row hover at DS.Size.iconButton (24).
      row height 34, alternating background none, 1 pt DS.Colour.line dividers
      empty state (centred, 60 pt tall):
        "No rules yet."
        "Until you write one, bots ask before anything that changes something."
  · card footer, DS.Text.micro inkTertiary:
      "These rules apply to every bot. Built-in safety checks always apply."

Card B "Always asked, never editable"
  header help: "Built in. No rule you write can switch these off."
  one row per SafetyFloor case, using the `explanation` strings already in the
  model: "Anything that spends or moves money", "…would enter a password or
  key", "…deletes something outside the workspace", and so on.
  Row: [glyph 10] text (DS.Text.caption) ......... [pill] [lock.fill 10 inkTertiary]
    pill "Never"      DS.Colour.failed  at 14% background, failed text
    pill "Asks first" DS.Colour.running at 14% background, running text
  RESPONSIBLE-PRESENTATION RULE: these rows are FULL CONTRAST, not greyed out.
  A disabled-looking row reads as "broken"; a full-contrast row with a lock
  glyph reads as "deliberate". "You cannot change this" and "this is not
  working" must never look the same.

Card C "This Mac"  — the part every competitor buries
  One row per macOS grant. Each: label, help text, state word, and a button.
  · "Screen Recording"    "Granted" (done) / "Not granted" (failed)
      help: "Needed to see the screen before clicking. Without it a bot is blind."
  · "Accessibility"
      help: "Needed to move the mouse and type. Without it a bot can look but
             not act."
  · "Automation"
      help: "Needed to tell apps like Mail and Calendar what to do."
  · "Files and Folders"
      help: "Needed to read and write outside a bot's workspace."
  Trailing button on every row: "Open System Settings"
  Card footer, DS.Text.micro inkTertiary:
      "macOS grants these, not Bot-Harness. We can only ask, and show you what
       we have."
  Re-poll the grant state on `NSApplication.didBecomeActiveNotification` so the
  row updates when the user comes back from System Settings. Without that this
  card is a liar.

Card D — DESTRUCTIVE (red-stroke treatment), pinned to the bottom
  · "Allow everything, without asking"          mini switch, default OFF
      help: "For a run you are watching, on a machine you can afford to lose.
             Every rule you wrote is skipped. Built-in safety checks still
             apply. Turns itself off after an hour."
  · turning it ON raises an alert — and THIS one gets the destructive style,
    because the user flipped a switch rather than choosing a destructive verb:
      title:   "Let bots act without asking?"
      body:    "For the next hour, every rule you wrote is skipped. Built-in
                safety checks still apply. Everything is still recorded."
      buttons: "Turn On for 1 Hour" (destructive)  ·  "Cancel"
  · while on, the row shows a live countdown "Off in 47:12" in DS.Colour.running
    and a "Turn Off Now" button — and the MAIN WINDOW shows a persistent banner.
    A dangerous mode that is only visible inside Settings is not visible.

───────────────────────────────────────────
PANE 5 — BOT DEFAULTS
───────────────────────────────────────────
Intro, with a trailing link button on the same line:
  "What a new bot starts with. Changing these never touches a bot that already
   exists."                                        [Open bot settings →]
  The link selects the current bot and closes the Settings window. Without it
  this pane is a dead end for anyone who came here looking for one bot.

Card "New bots start with"
  · "Brain"              pop-up (same list as the Brains pane)
  · "Autonomy"           pop-up, from Bot.Autonomy.displayName
      help: "Changeable per message in the composer."
  · "Environment"        pop-up, from EnvironmentKind ("This Mac", …)
  · "Workspace folder"   mono truncated path + "Choose…" + "Reset" (only when
                         non-default)
      help: "Where a new bot may read and write without asking. Anything
             outside it counts as a change, and changes follow your rules."
  · "Notify me when it finishes"    mini switch, default on

Card "Connections a new bot can use"
  Checkbox list of every connected provider (checkbox, not switch — HIG:
  checkboxes for multi-select with aligned leading edges), each row
  [checkbox] icon 16 · name · "14 tools" (inkTertiary, right)
  Header right: pull-down "Select…" { All · None · Read-only }
  help: "A bot can only use a connection you turn on for it."
  empty state: "No connections yet."  +  button "Add one →" (goes to Connections)

Pane footer: "These are defaults, not limits."

───────────────────────────────────────────
PANE 6 — ACTIVITY & TRACES
───────────────────────────────────────────
Card "Where things are written"
  Label left, mono path right (textSelection enabled), trailing icon button
  `arrow.up.forward.app` = Show in Finder. Every path is actionable.
    "State"            Paths.root.path
    "Traces"           Paths.traces.path
    "Screenshots"      traces/screenshots
    "Keychain service" Keychain.service   → button "Open Keychain Access"
  footer: "JSON for state, JSONL for traces, PNG for screenshots. If you delete
           this app, the record of what it did stays readable."

Card "Storage"
  · "Traces"       "412 MB · 1,204 runs"      pull-down "Manage"
                     { Reveal in Finder · Export… · Delete older than… }
  · "Screenshots"  "1.9 GB · 8,331 files"     same pull-down
  · "Keep traces for"   pop-up: Forever · 1 year · 90 days · 30 days
                        (default Forever)
      help: "Older traces are removed at launch."

Card "Verify"
  · "Trace integrity"    button "Verify Chain"
    While running, the button is replaced in place by "Checking 812 of 1,204…"
    Result replaces it, in place, permanently until the next run:
      ✓ "Verified 1,204 entries. No gaps."          (done)
      ✗ "Broken at entry 812, 14 Aug."  + button "Show entry"   (failed)
    Nothing here silently succeeds.

DESTRUCTIVE card, bottom
  · "Delete all traces"   (red label, plain style, right-aligned)
      title:   "Delete every trace?"
      body:    "1,204 runs and 8,331 screenshots, 2.3 GB, from 12 May to today.
                This is the only record of what your bots did."
      buttons: "Delete Traces" (NOT destructive-styled — deliberately chosen)
               · "Cancel"
      no suppression checkbox on this one, ever.
  · "Reset Bot-Harness"   (red label)
      title:   "Reset Bot-Harness?"
      body:    "Deletes 7 bots, 214 conversations and every setting. Your API
                keys stay in the Keychain and your traces stay on disk."
      buttons: "Reset"  ·  "Cancel"
      The body must enumerate real counts, computed at present time. A generic
      "this cannot be undone" teaches people to click through.

───────────────────────────────────────────
PANE 7 — ABOUT
───────────────────────────────────────────
  App icon 64 pt · "Bot-Harness" (DS.Text.display) · version + build
  (DS.Text.mono(11), selectable) ·
  "An open-source, local-first agent cockpit. Your bots, your Mac, your API keys."

  Link rows, each with a trailing `arrow.up.right` 10 pt:
    "Source on GitHub" · "Report an issue" · "Licence — MIT" · "Acknowledgements"

  Card "Environment"   ← the thing that makes bug reports possible
    read-only label/value rows: macOS version · Swift version · SDK ·
    signing identity · Screen Recording granted · Accessibility granted ·
    brains configured · connections healthy / total
    trailing header button: "Copy Diagnostics" → puts it on the clipboard as
    markdown, and flips to "Copied" for 1.2 s.

  footer: "No dependencies. URLSession, Security, ScreenCaptureKit,
           CoreGraphics, ApplicationServices and Foundation."

═══════════════════════════════════════════════════════
PART 5 — SETTINGS vs INLINE, AND PER-OBJECT vs APP-WIDE
═══════════════════════════════════════════════════════

THE TEST: if the answer can be different for the next message, it is not a
setting. Model and autonomy pass that test — hence the composer.

THREE TIERS, and each states its relationship to the one above:
  1. App-wide      → the Settings window (⌘,)
  2. Per-bot       → the right-hand inspector, always visible next to the bot.
                     NEVER a "Bots" pane in Settings: HIG's "disconnects it from
                     its context" is exactly the failure — you would pick a bot
                     twice, once in the roster and again in Settings. Grok Bot
                     gets this right and it is the best thing about its IA.
  3. Per-run       → the composer. Transient; reverts to the bot's default when
                     the message is sent.

  where it lives         │ composer (run) │ inspector (bot) │ Settings (app)
  ───────────────────────┼────────────────┼─────────────────┼────────────────
  model / brain          │ this message   │ this bot's      │ default for new
  autonomy               │ this message   │ this bot's      │ default for new
  which connections      │ this run       │ this bot's set  │ which exist + health
  workspace folder       │ override       │ this bot's      │ default for new
  permission rules       │ —              │ this bot's      │ global + the floor
  notifications          │ —              │ this bot's      │ app-wide default
  name / persona / avatar│ —              │ this bot's      │ —
  API keys               │ —              │ —               │ Brains
  paths, traces, storage │ —              │ —               │ Activity & Traces

INHERITANCE MUST BE VISIBLE — this is the mechanic that makes three tiers
legible, and neither Grok Bot nor Raycast does it:
  · A per-bot control still sitting on the app default renders its value in
    DS.Colour.inkSecondary with a trailing micro tag "Default"
    (DS.Text.micro, inkTertiary, DS.Colour.fill capsule, height 14).
  · Overriding it flips the value to DS.Colour.ink and swaps the tag for a
    "Reset" plain text button.
  · The same applies to a per-run override in the composer against the bot's
    value.

═══════════════════════════════════════════════════════
PART 6 — THE NO-DEAD-ENDS AUDIT (run this before shipping)
═══════════════════════════════════════════════════════
  1. Every empty list has a primary BUTTON in its empty state, not just prose.
  2. Every error string is followed by the control that addresses it
     (Connect / Repair / Reconnect / Show Log / Open System Settings).
  3. Every path is followed by "Show in Finder".
  4. Every "macOS grants this" row is followed by "Open System Settings", and
     the state re-polls on didBecomeActive.
  5. Every long-running check reports its result IN PLACE. Nothing silently
     succeeds.
  6. Every disabled control has a `.help()` tooltip saying why it is disabled.
     A disabled control with no explanation is the most common dead end in
     settings UIs.
  7. Locked rules use a lock glyph at full contrast, never a greyed-out control.
  8. Every list row that shows a state also shows the words for that state.
  9. Every destructive confirmation names real counts and real bytes.
 10. Every pane that mentions something living elsewhere links to it
     (Brains → composer; Bot Defaults → the inspector; Connections → Activity).

## Findings

- Apple HIG states the macOS settings window pattern verbatim: "Typically, a custom settings window contains a toolbar that includes buttons for switching between views — called panes — that each contain a group of related settings."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/settings>
- Apple HIG on what belongs where: "Put general, infrequently changed settings in your custom settings area" and "When possible, prefer letting people modify task-specific options without going to your settings area… Putting this type of option in a separate settings area disconnects it from its context, requiring people to suspend their task to make adjustments, and often hiding the results until people resume the task." This directly endorses model/autonomy pickers living in the composer.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/settings>
- Apple HIG macOS settings window rules: "Dim a settings window's minimize and maximize buttons"; "use a noncustomizable toolbar that remains visible and always indicates the active toolbar button"; "Update the window's title to reflect the currently visible pane. If your settings window doesn't have multiple panes, use the title App Name Settings"; "Restore the most recently viewed pane"; "Include a settings item in the App menu. Avoid adding settings buttons to a window's toolbar."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/settings>
- Apple HIG: "Minimize the number of settings you offer" and "Respect people's systemwide settings and avoid including redundant versions of them in your custom settings area… Including custom versions of global options in your settings area is likely to confuse people." This rules out a custom Theme or Language picker (which Grok Bot ships, wrongly).  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/settings>
- Apple HIG toggles, macOS: "Prefer a switch for settings that you want to emphasize"; "Within a grouped form, consider using a mini switch to control the setting in a single row. The height of a mini switch is similar to the height of buttons and other controls, resulting in rows that have a consistent height"; "Use a checkbox instead of a switch if you need to present a hierarchy of settings"; "In general, don't replace a checkbox with a switch."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/toggles>
- Apple HIG toggles: "Avoid relying solely on different colors to communicate state, because not everyone can perceive the differences." A green/red dot alone is therefore not a legitimate health indicator; it needs a glyph and a word.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/toggles>
- Apple HIG toggles, radio buttons: "If you need to present more than about five options, consider using a component like a pop-up button instead"; "To present a single setting that can be on or off, prefer a checkbox."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/toggles>
- Apple HIG segmented controls: "Aim for no more than about five to seven segments in a wide interface"; "Prefer using either text or images — not a mix of both"; "Use nouns or noun phrases for segment labels. Write text that describes each segment and uses title-style capitalization. A segmented control that displays text labels doesn't need introductory text"; on macOS, "Consider using a segmented control to help people switch views in a toolbar or inspector pane."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/segmented-controls>
- Apple HIG pop-up buttons: "Use a pop-up button to present a flat list of mutually exclusive options or states. Use a pull-down button instead if you need to: Offer a list of actions / Let people select multiple items / Include a submenu"; "You can also display explanatory text below the list to help people understand how the options work."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons>
- Apple HIG alerts, on destructive confirmation: "Avoid displaying alerts for common, undoable actions, even when they're destructive… In comparison, when people take an uncommon destructive action that they can't undo, it's important to display an alert in case they initiated the action accidentally."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/alerts>
- Apple HIG alerts, on button styling — a nuance almost everyone gets wrong: "Use the destructive style to identify a button that performs a destructive action people didn't deliberately choose. For example, when people deliberately choose a destructive action — such as Empty Trash — the resulting alert doesn't apply the destructive style to the Empty Trash button." So a confirmation reached by clicking "Delete Traces" should NOT use red on its confirm button; a confirmation triggered by flipping an unsafe switch should.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/alerts>
- Apple HIG alerts, copy rules: "Avoid using OK as the default button title unless the alert is purely informational… A specific button title like 'Erase,' 'Convert,' 'Clear,' or 'Delete' helps people understand the action they're taking"; "Aim for a one- or two-word title that describes the result of selecting the button"; "macOS alerts can add a suppression checkbox and a Help button"; place the default button on the trailing side, Cancel on the leading side.  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/alerts>
- Apple HIG privacy: "Request permission only when your app clearly needs access to the data or resource… Ideally, wait to request permission until people actually use an app feature that requires access" and "Avoid requesting permission at launch unless the data or resource is required for your app to function." Purpose strings must be active, specific, sentence case, with a period — Apple's own good/bad pair is "The app records during the night to detect snoring sounds" versus "Microphone access is needed for a better experience."  
  — **confirmed** · <https://developer.apple.com/design/human-interface-guidelines/privacy>
- SwiftUI's `Settings` scene is macOS 11.0+, and Apple's own canonical example groups panes with `TabView` + `Tab(...)` and sizes the content with `.scenePadding()` and `.frame(maxWidth: 350, minHeight: 100)`. Apple shows no Save/Cancel buttons — bindings write straight to `@AppStorage`.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/settings>
- `TabViewStyle.sidebarAdaptable` is macOS 15.0+ and Apple documents that "macOS and tvOS always show a sidebar." Bot-Harness's Package.swift currently declares `platforms: [.macOS(.v14)]`, so adopting it requires raising the deployment target to v15. The dev machine runs macOS 26.5.2, so nothing is lost by raising it.  
  — **confirmed** · <https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable>
- macOS System Settings itself is sidebar-navigated, not tabbed: Apple's user guide instructs "Click an option in the sidebar. (You may need to scroll down.)" It also documents a needs-attention badge convention: "If a red badge is shown on the System Settings icon in the Dock, you need to take one or more actions." That badge is the precedent for putting an attention count on a Settings sidebar row.  
  — **confirmed** · <https://support.apple.com/guide/mac-help/change-system-settings-mh15217/mac>
- A widely-cited macOS settings-window spec (usagimaru) gives concrete numbers: `NSWindow.ToolbarStyle.preference`; 20pt margins from window corners; 8pt horizontally between a heading and its controls; 6pt vertically between controls; at least 20pt on each side of a separator; heading in the 13pt system font; description text at 11pt in secondary label colour placed directly below its item; help button in the bottom-right; window resized to fit the pane with animation, disabled under Reduce Motion; Escape and Command-Period close; modeless with no Save/Cancel.  
  — likely · <https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en>
- Grok Bot (the reference product, bundle id com.anysphere.sand) puts app settings in a modal sheet with a left nav rail — General, Computer, Usage & Billing, Updates — and puts per-bot settings in a persistent right inspector instead (Name, Label (optional), Description, Notifications toggle with help text "Get notified when this Bot finishes or needs input", and "Share as template" pinned at the bottom). Plugins is a third, separate modal. Measured from local 2x screenshots (144 dpi, logical 1800x1169): sheet approx. 992 x 697 pt, nav rail approx. 193 pt with approx. 31 pt row pitch, content column approx. 799 pt, grouped card approx. 734 pt wide at approx. 10 pt corner radius, approx. 52 pt row pitch inside cards, section header approx. 18 pt above its card.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/18%20-%20App%20Settings%20-%20General%20Account%20and%20Bot.png>
- Grok Bot's permission copy, verbatim and worth answering directly: "Auto-review — Grok Bot checks each action before it runs and asks you first when needed. Add rules to customize what it can do automatically." / "Auto-review Rules — Write one short, natural-language rule for each action. \"Ask first\" takes priority if rules conflict." with a two-field composer ("When Grok Bot wants to:" free text, "It should:" pop-up, "Add Rule" button) feeding an Action | Behavior table with edit and delete icons, footed by "These rules apply only to you. Built-in safety checks always apply." Its computer pane reads "Execution on this computer — Let Grok Bot open files and run tasks on your computer. Auto-review still checks everything first" with an "Always allow" pop-up.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/19%20-%20App%20Settings%20-%20Auto-review%20Rules.png>
- Grok Bot's plugin browser is a separate modal, not a settings pane: header "Plugins", an avatar stack reading "3 installed >", a "Search plugins" field, a wrapping row of category filter chips (All, Featured, Agent Orchestration, Canvas, Customer Support, Data Analytics, Design, Documents And Files, Finance And Legal, Inbox And Collaboration, Infrastructure, MCP, Payments, Productivity, Research, Sales, Scheduling), then a two-column grid of icon + name + one-line description + "Add" button, with a "View all" link per category. Notably it shows no health state at all for installed plugins.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/15%20-%20Plugins%20-%20MCP%20and%20Payments.png>
- Bot-Harness already models connection health correctly and the Connections pane should render this enum rather than invent a new one: `ProviderHealth` carries `status`, `detail`, `toolCount`, `checkedAt`, with states healthy/degraded/needsAuth/initializing/offline/error, display names "Connected"/"Degraded"/"Needs sign-in"/"Starting"/"Offline"/"Error", and a per-state action verb: degraded="Check", needsAuth="Connect", offline="Repair", error="Reconnect", nil for healthy and initializing. The file's own comment states the design rule: "A connector that needs a key or whose app is closed must stay visible and say so."  
  — **confirmed** · <file:///Users/Kunal/Desktop/Bot-Harness/Sources/BotHarnessCore/Capabilities/Capability.swift>
- Raycast splits settings into 11 sidebar sections — Account, General, Launcher, Shortcuts, Keyboard, Advanced, Organizations, About, AI, Applications, Extensions — and gives Settings its own search bound to Command-F covering every extension, command and setting. Extensions are listed by category (Built-in, Store, Script Commands, Quicklinks) with per-command toggles.  
  — likely · <https://manual.raycast.com/settings>
- Warp organises settings into roughly 19 sections (General, Appearance, Terminal, Session, Agents, Code, Keys, Notifications, Privacy, System, Text editing, Experimental, Warp Drive, Warpify, Workflows, Accessibility, Account, Cloud platform, Global hotkey) and uses essentially three control types: toggles for booleans, dropdowns for enumerated strings, and custom editors for complex objects. It is a useful counter-example — at 19 sections the sidebar needs search to be usable.  
  — likely · <https://docs.warp.dev/terminal/settings/all-settings>
- Linear's redesigned settings group panes into three named buckets — Account (personal settings, notifications, preferences), Features (workspace-level feature configuration), and Administration (admin-only workspace settings) — which is the clearest published example of separating per-person, per-capability and per-org concerns in one sidebar.  
  — likely · <https://linear.app/changelog/2024-12-18-personalized-sidebar>
- Claude Desktop separates the browsing surface from the diagnostic surface: connected MCP servers and their tools are reached from the "+" button in the composer under "Connectors", while connection status and logs live in a separate Developer settings area. The split is worth copying in principle (browse where you use it, diagnose in Settings) but Anthropic's docs do not describe the visual status treatment.  
  — likely · <https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop>

## What to build

- Replace the three-tab TabView SettingsView with a NavigationSplitView shell: 940x660 default, 860x560 minimum, 210pt fixed sidebar, resizable width to 1180, window title bound to the selected pane, minimise and zoom buttons dimmed via NSWindow.standardWindowButton, last pane restored from @AppStorage("settings.lastPane"), Escape and Cmd-W to close. Keep the Settings scene so Cmd-comma still works. Crossfade panes at DS.Motion.instant with no window resize animation.
- Build the Permissions rule composer, which does not exist today. The current PermissionSettings renders store.globalRules read-only with no way to add, edit or delete one — that is the largest dead end in the app. Ship the two-field composer ("When a bot wants to" text field, "it should" pop-up bound to PermissionRule.Behaviour.displayName, "Add Rule" button disabled while empty) feeding an Action | Behaviour table whose Behaviour cell is itself an in-place pop-up, with hover-revealed edit and trash icon buttons at DS.Size.iconButton.
- Build the Connections pane against the existing ProviderHealth enum — do not invent a second status vocabulary. Sort rows worst-first under NEEDS YOU / CONNECTED / OFF headers, render each state as glyph plus word plus detail (never colour alone, per HIG), use the action verbs already in Status.action (Check / Connect / Repair / Reconnect), and put a mini switch in the trailing slot. Add the summary strip with three filter chips and a "Check all" button showing checkedAt as relative time.
- Add the "This Mac" card to the Permissions pane: Screen Recording, Accessibility, Automation, Files and Folders, each with granted/not-granted state, one sentence of help saying what a bot cannot do without it, and an "Open System Settings" button. Re-poll grant state on NSApplication.didBecomeActiveNotification so the card updates when the user returns — without that it displays stale state and is worse than nothing.
- Make the provider rows in Brains expandable rather than always-open KeyField forms. Collapsed rows show name, one-line purpose, and either a "Key saved" pill or an "Add key" button; expanding reveals the SecureField. Keep the existing write-only rule and surface it as micro text in the expanded state: "Bot-Harness cannot read this back to you." Add the "Remove your Gemini key?" confirmation, non-destructive-styled per the HIG Empty Trash rule.
- Add the two footer sentences that close the composer/Settings loop and prevent the most likely user confusion: in Brains, "Model and autonomy are chosen per message, in the composer. They change too often to be settings." In Bot Defaults, an "Open bot settings" link button that selects the current bot's inspector and closes the window.
- Implement the inheritance tag mechanic across all three tiers: a per-bot control still on the app default renders inkSecondary with a trailing micro "Default" capsule; overriding it flips to full-contrast ink and swaps the capsule for a "Reset" plain button. Same pattern for a per-run override in the composer. Neither Grok Bot nor Raycast does this, and it is what makes three tiers legible instead of confusing.
- Raise Package.swift from .macOS(.v14) to .macOS(.v15) if you want .tabViewStyle(.sidebarAdaptable) available as a fallback path. The dev machine runs 26.5.2 so nothing is lost. The recommended NavigationSplitView route does not require it, so treat this as optional and note the reason in the ADR.
- Add the Activity & Traces pane: paths with Show in Finder buttons, storage sizes with a Manage pull-down, a "Keep traces for" retention pop-up, a "Verify Chain" button that reports its result in place, and the two destructive actions with confirmations that enumerate real counts and bytes rather than saying "this cannot be undone".
- Add the "Allow everything, without asking" switch as the only red-stroked card in Permissions, defaulting off, with a destructive-styled "Turn On for 1 Hour" confirmation, a live countdown in the row while active, and a persistent banner in the main window. A dangerous mode visible only inside Settings is not visible.
- Delete the Theme and Language pickers from any General pane design. Apple's guidance is explicit that redundant versions of systemwide settings confuse people; Grok Bot ships both set to "Follow System" and it is a mistake worth not copying. Replace with one footer line: "Bot-Harness follows your system appearance, language and accessibility settings."
- Write an ADR recording the pane-count rule (up to 5 panes, no lists, toolbar tabs; 6+ panes or any browsable list, sidebar) with its falsifier: if the pane count ever drops to five and no pane holds a live list, the sidebar becomes the wrong choice and the window should go back to toolbar tabs.
- Add the sidebar search field bound to Cmd-F. At seven panes it is a convenience; Warp at nineteen sections proves it becomes mandatory as the app grows, and retrofitting search into a pane structure that was never indexed is expensive.

## Could not verify

- Craft, Arc/Dia, Notion Calendar (formerly Cron), and Cursor's settings interfaces — I could not reach a primary source describing their settings layouts. Cursor's MCP docs describe configuration via mcp.json and mention that servers can be toggled on and off in Customize, but say nothing about status indicators, tool counts or error presentation. Do not cite these apps as precedent without a screenshot.
- Things 3's full Settings tab list. Cultured Code's support site confirms a Quick Entry tab exists (Things → Settings → Quick Entry) but I could not retrieve the complete set of tabs, so the specific claim that Things uses General / Quick Entry / Calendar Events / Reminders / Cloud is unconfirmed.
- Claude Desktop's visual treatment of MCP server health. The Anthropic help centre confirms the navigation (Settings > Extensions; connectors reached from the composer's + button; connection status and logs under Developer settings) but describes no dots, colours, tool counts or error states.
- The System Settings deep-link URL scheme (x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture and its Privacy_Accessibility, Privacy_Automation, Privacy_AllFiles siblings). These are widely used but Apple does not document them, and the pane bundle identifiers changed at Ventura. Test each one on macOS 26.5 before shipping, and fall back to opening System Settings' root rather than failing silently.
- The exact point measurements taken from the Grok Bot screenshots (992x697 pt sheet, 193 pt rail, 734 pt card, 52 pt row pitch). The 2x scale factor is confirmed from the file's 144 dpi and the machine's Retina display, but the measurements themselves were read off a downscaled render of the image, so treat them as accurate to roughly plus or minus 5 pt.
- The usagimaru macOS Settings Window Guidelines numbers (20 pt window margins, 8 pt heading-to-control, 6 pt between controls, 13 pt headings, 11 pt descriptions). This is one expert developer's synthesis, not an Apple document. The values are consistent with what System Settings appears to do, but Apple publishes no spacing spec, so they are convention rather than requirement.
- Whether trace deletion can preserve hash-chain validity by recording deletions as entries. I specified the retention pop-up assuming this is possible, but I did not read the trace writer to confirm the chain design supports it. Check Sources/BotHarnessCore/Trace/Trace.swift before shipping the "Keep traces for" control, and if the chain cannot survive deletion, either drop the control or state plainly in its help text that pruning breaks verification.
- Raycast's exact settings tab list and Warp's exact section list came through fetched-page summaries rather than my own reading of the rendered UI. The section names are almost certainly right; the ordering in the sidebar is not something I verified.
