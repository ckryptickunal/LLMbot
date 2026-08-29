# The design system

> Decided 2026-08-30 from six research tracks against live sources, then reconciled.
> This document is the contract. `Sources/BotHarness/Design/Tokens.swift` implements it,
> and no view may contain a raw number or a raw colour.

## What we chose, and why

**Radix Colors (dark, MIT) as the opaque surface and status ramp, with macOS owning accent, materials, type metrics and the focus ring — and zero Liquid Glass adoption of our own.** Radix wins the colour base because macOS publishes no neutral surface ramp with numeric values (you get `windowBackground`, `controlBackground`, `underPageBackground` and nothing between), and a three-pane cockpit needs five distinguishable depths; Radix's 12 steps are a semantic contract (3 = element background, 6 = subtle border, 9 = solid fill, 11 = low-contrast text) rather than a lightness ramp, so an engineer is told which value to use instead of guessing, and it ships a matched alpha scale — the only way to tint a surface sitting on an `NSVisualEffectView` without killing the material. Grok Bot's sampled palette is rejected as the base: it is an Electron app's flat neutral greys (#070707/#111111/#262626 are pure achromatic), and copying it head-on would make Bot-Harness look like the product it claims to beat; we keep Grok's *information design* (bubble geometry, the natural-language rule form, the handoff card, the settings copy) and discard its pixels. The single rule that decides whether this reads as Mac-native or as a web app in a window: **the functional layer is never painted and the content layer always is** — the roster sidebar, the inspector, the toolbar and all sheets get no `.background()` at all and inherit the system material (which also means we get macOS 26 Liquid Glass and the scroll edge effect for free by building against the 26 SDK), while the conversation pane is painted opaque Radix `slate1`, which lands it *darker* than the window chrome, matching the measured native relationship (#1E1E1E content against #323232 window). Text is the one place Radix loses outright: every readable string uses macOS semantic hierarchical styles, because `labelColor` is white at 84.7% alpha rather than a grey, and only an alpha composite tracks Increase Contrast, desktop tinting and material correctly — Radix `slate11`/`slate12` are reserved for exported PNGs and trace rendering, where a fixed value must reproduce identically later. We target **macOS 15.0 with the macOS 26 SDK** and ship no `glassEffect()` call anywhere, which gets us the new chrome without a single `#available` branch.

## TOKEN SPECIFICATION — implement verbatim in `Sources/BotHarness/Design/Tokens.swift`

Add two private helpers first: `Color(hex: UInt32)` (sRGB) and `Color(p3: Double, Double, Double)`. Every colour below is given as sRGB hex; where a Display P3 triple is listed, use the P3 initialiser — every Mac display is P3 and the P3 value is the authored one.

### DS.Surface — opaque, content layer only. Never over a material.
| Token | Hex | Display P3 | Radix | Use |
|---|---|---|---|---|
| `ground` | #111113 | 0.067 0.067 0.074 | slate1 | conversation pane background, Settings content pane |
| `panel` | #18191b | 0.095 0.098 0.105 | slate2 | composer field, transcript inset wells |
| `raised` | #212225 | 0.130 0.135 0.145 | slate3 | cards, incoming bubble, tool card, settings card |
| `raisedHover` | #272a2d | 0.156 0.163 0.176 | slate4 | hovered card/row on an opaque surface |
| `active` | #2e3135 | 0.183 0.191 0.206 | slate5 | pressed/selected element on an opaque surface, outgoing bubble |
| `border` | #363a3f | 0.215 0.226 0.244 | slate6 | subtle borders, dividers inside cards |
| `borderStrong` | #43484e | 0.265 0.280 0.302 | slate7 | field borders, focused composer border |
| `borderHover` | #5a6169 | — | slate8 | hovered field border |

### DS.Tint — alpha, for anything drawn over an `NSVisualEffectView` material (sidebar, inspector, toolbar, sheets)
Radix dark alphas are a slightly **cool** white (≈rgb(217,237,255)), not pure white. That cool cast is what stops stacked overlays from going brown. Replace every `Color.white.opacity(…)` currently in the codebase with these.
| Token | Hex8 | Alpha | Tint RGB | Radix |
|---|---|---|---|---|
| `t2` | #d8f4f609 | 0.035 | 216,244,246 | slateA2 |
| `t3` | #ddeaf814 | 0.078 | 221,234,248 | slateA3 — hover fill on material |
| `t4` | #d3edf81d | 0.114 | 211,237,248 | slateA4 |
| `t5` | #d9edfe25 | 0.145 | 217,237,254 | slateA5 — selected-unfocused row |
| `t6` | #d6ebfd30 | 0.188 | 214,235,253 | slateA6 — separator on material |
| `t7` | #d9edff40 | 0.251 | 217,237,255 | slateA7 |

### DS.Ink — text. macOS semantic, NOT Radix.
| Token | SwiftUI spelling | Dark value | Measured on `ground` #111113 |
|---|---|---|---|
| `primary` | `.foregroundStyle(.primary)` | #FFFFFF @ 0.847 | composites #DADADB → **13.6:1** |
| `secondary` | `.foregroundStyle(.secondary)` | #FFFFFF @ 0.549 | composites #939395 → **6.2:1** |
| `tertiary` | `.foregroundStyle(.tertiary)` | #FFFFFF @ 0.247 | composites #4B4C4D → **2.2:1** — decorative and disabled only, never a string the user must read |
| `quaternary` | `.foregroundStyle(.quaternary)` | #FFFFFF @ 0.098 | non-text: glyph washes |
| `separator` | `Divider()` or `.separator` | #FFFFFF @ 0.098 | hairlines. Never a grey `Rectangle` |
| `placeholder` | `.foregroundStyle(.placeholder)` | #FFFFFF @ 0.247 | composer + field placeholders |
| Export-only | `DS.Ink.exportHigh` #edeef0 (slate12), `DS.Ink.exportLow` #b0b4ba (slate11) | fixed | trace HTML, exported PNGs — anything that must reproduce identically in five years |

### DS.Accent
- `DS.Accent.live = Color(nsColor: .controlAccentColor)` — selection, primary actions, focus. Tracks System Settings. Dark aqua measures #007AFF today; do **not** hardcode it.
- `DS.Accent.unfocusedSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)` — #464646 dark, selected-but-window-unfocused rows.
- `DS.Accent.static = #0090ff` (Radix blue9, P3 0.247 0.556 0.969) — traces, exports, chart series. Never for live UI.
- **Delete on sight:** any `#007AFF`, `#0088FF`, `#FF3B30`, `#AF52DE` literal. macOS 26 shifted the system palette (systemRed is now #FF383C, systemPurple #CB30E0) and `controlAccentColor` ≠ `systemBlue`.

### DS.Status — Radix step 9 for the dot/bar, step 11 for the word beside it. Never colour alone; always glyph + word.
| State | Dot / bar (step 9) | Label text (step 11) | Contrast of label on `ground` | Glyph | Word |
|---|---|---|---|---|---|
| `idle` | #696e77 slate9 | `.secondary` | 6.2:1 | `circle` | Idle |
| `running` | #ffc53d amber9 | #ffca16 amber11 | 12.3:1 | `circle.dotted` | Running |
| `awaitingApproval` | #f76b15 orange9 | #ffa057 orange11 | 9.3:1 | `hand.raised.fill` | Needs you |
| `done` | #30a46c green9 | #3dd68c green11 | 10.1:1 | `checkmark.circle.fill` | Done |
| `failed` | #e5484d red9 | #ff9592 red11 | 9.0:1 | `xmark.octagon.fill` | Failed |
| `waiting` | #0090ff blue9 | #70b8ff blue11 | 9.0:1 | `clock` | Waiting |
| `denied` | #e5484d red9 | #ff9592 red11 | 9.0:1 | `nosign` | Blocked |

`running` and `awaitingApproval` **must not** share a colour. "Working" and "blocked on you" are the one confusion in this app with a real-world cost.

Soft badge recipes (text on a tinted chip), all ≥7:1: blue11 on blue3 #0d2847 = 7.1:1 · red11 on red3 #3b1219 = 7.8:1 · amber11 on amber3 #302008 = 10.3:1 · green11 on green3 #132d21 = 7.9:1 · orange11 on orange3 #331e0b.

**The trap, stated as a hard rule:** white on blue9 is 3.26:1, white on green9 is 3.16:1, white on red9 is 3.91:1 — all fail AA. **No text ever sits on a step-9 fill.** The sole exception: amber9 #ffc53d with black text is 13.3:1.

### DS.Text — five anchored steps, all bound to system text styles so they track the OS
| Token | SwiftUI | Size / weight | Line height | Use |
|---|---|---|---|---|
| `body` | `.body` | 13 regular | 16 | message text, row labels, field text |
| `title` | `.body.weight(.semibold)` | 13 semibold ("Body Emphasized" in the HIG table) | 16 | section and pane titles, bot name in header |
| `callout` | `.callout` | 12 regular | 15 | supporting text beside a body line |
| `caption` | `.subheadline` | 11 regular | 14 | chips, metadata, settings help text |
| `micro` | `.caption` | 10 regular | 13 | timestamps, counters, hash prefixes |
| `mono` | `.body.monospaced()` (13) / `.subheadline.monospaced()` (11) | — | — | shell commands, tool arguments, paths, trace hashes. **The only place monospace is correct.** |
| `bodyLineSpacing` | 2.5 | — | — | multi-line prose only |

Deleted: 9, 10.5, 11.5, 12.5, 13.5, 15. The half-point sizes appear 31 times, match nothing the OS draws, and are why the app's text does not optically line up with the toolbar. **`design: .rounded` is banned** — it has no macOS system precedent and reads instantly as non-native. Section headers use title-style capitalisation, not uppercase + tracking; macOS 26 stopped auto-capitalising these.

### DS.Space — 2, 4, 6, 8, 12, 16, 24, 40 (`hair, xs, sm, md, lg, xl, xxl, xxxl`). Unchanged; it is already correct.

### DS.Radius — Radix medium scale, replacing 4/6/8/10/14
`xs 4` (inline code, tags) · `sm 6` (fields inside cards) · `md 8` (rows, small cards) · `lg 12` (cards, tool cards, handoff cards) · `xl 16` (message bubbles, sheets) · `pill 999`.
**Nesting rule, enforced:** inner radius = outer radius − inner padding. A 12pt card with 8pt padding contains a 4pt element. `ConcentricRectangle` is macOS 26-only; compute the value.

### DS.Size
`iconButton 24` · `iconButtonLarge 28` · `avatarRoster 24` · `avatarInspector 64` · `glyph 12` · `glyphSmall 10` · `statusDot 6` · `denseRow 24` (activity/trace rows — NSTableView's measured default) · `settingsRow 44` (minimum; auto-height when help text present) · `titlebar 52` · `windowCornerRadius 26` · `bubbleMax 620` · `cardMax 640` · `hairline 1`
Split view: roster `.navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)`; inspector `.inspectorColumnWidth(min: 260, ideal: 300, max: 380)`.

### DS.Motion — every value gated through one chokepoint
```
gated(_ a: Animation) -> Animation?   // returns nil when accessibilityReduceMotion is on,
                                      // EXCEPT opacity-only crossfades, which keep 0.12s
```
| Token | Duration | Curve | Where |
|---|---|---|---|
| `press` | 0.10 | timingCurve(0.23, 1, 0.32, 1) | button press; `pressScale = 0.97` |
| `hoverIn` | **0.00** | none — set the value directly | every hover |
| `hoverOut` | 0.12 | timingCurve(0.23, 1, 0.32, 1) | every hover |
| `instant` | 0.12 | timingCurve(0.23, 1, 0.32, 1) | status pill, token count, row highlight, Settings pane crossfade |
| `disclosure` | 0.18 | timingCurve(0.23, 1, 0.32, 1) | expand/collapse; chevron rotates 90° on the same curve; content opacity fades in over the last 0.12 |
| `rowInsert` | 0.20 | timingCurve(0.23, 1, 0.32, 1) | transcript and activity row insertion |
| `panel` | 0.24 | timingCurve(0.77, 0, 0.175, 1) | inspector slide |
| `sheet` | 0.28 | timingCurve(0.32, 0.72, 0, 1) | sheets and modals |
| `drag` | — | `.interactiveSpring(response: 0.15, dampingFraction: 0.86)` | interruptible drags |
| `rare` | 0.40 | `.snappy(duration: 0.4)` | first run only |
| `stagger` | 0.035 | — | **first 5 items only**, 0 thereafter |
| `caretPeriod` | 0.530 on / 0.530 off | — | stream caret; solid under reduced motion; removed the instant the stream ends |
| `spinnerDelay` | 0.400 | — | no `ProgressView` may appear before this |

Hard rules: **300ms ceiling on everything.** **Never `ease-in`.** **Never `Animation.default`** — since macOS 14 it is `spring(response: 0.55, dampingFraction: 1.0)`, roughly 3× too slow here. **Nothing triggered by a keyboard shortcut animates** (send, stop, new chat, palette, bot switching, focus). **Focus rings never animate and are never custom-drawn** — use the system ring, suppress with `.focusEffectDisabled()` only where genuinely decorative. **Rows never scale on hover** — background tint only, because a row cannot grow without overlapping its neighbours.

## Tokens

The complete token set is specified in the `chosen_system` field above under "TOKEN SPECIFICATION", covering DS.Surface (8 opaque Radix slate steps with sRGB + Display P3), DS.Tint (6 Radix slate-alpha steps with hex8 and decimal alpha), DS.Ink (macOS semantic styles with measured composite values and contrast ratios, plus two export-only fixed values), DS.Accent (live/unfocused/static), DS.Status (7 states × step-9 dot + step-11 label + glyph + word, with contrast ratios and the "no text on step 9" rule), DS.Text (5 anchored sizes bound to system text styles + mono), DS.Space (8 steps), DS.Radius (5 steps + pill, with the nesting rule), DS.Size (18 named values including split-view widths), and DS.Motion (13 tokens with exact durations and cubic-bezier curves, plus the reduced-motion chokepoint and five hard rules).

Two additions that belong to the token file and are specified here rather than above:

### DS.Avatar — shape × colour, offline, no image model
**Eight colours**, each Radix step 9 as the glyph fill on the matching step 3 as the tile: blue #0090ff/#0d2847 · teal #12a594/#0d2d2a · green #30a46c/#132d21 · amber #ffc53d/#302008 · orange #f76b15/#331e0b · red #e5484d/#3b1219 · iris #5b5bd6/#202248 · cyan #00a2c7/#082c36.

I deliberately did **not** adopt the 11 sampled Grok swatches. The research measured two swatch→glyph pairs and they disagree on direction: amber #D48F35 renders lighter as #F19D38, blue #3B79D8 renders *darker* as #3472D9. No single tint ratio reproduces both, the other nine pairs were never measured, and inventing a derivation would ship a guess. Eight citable Radix pairs beat eleven half-measured ones.

**Eight shapes**, drawn as SwiftUI `Shape` types, crisp at 24pt and 64pt: circle, squircle (continuous rounded square), hexagon, rounded triangle, droplet, blob-A, blob-B, diamond. 8 × 8 = 64 identities, deterministic from `Bot.id` so they survive renames.

Roster: 24pt tile, 14pt glyph. Inspector: 64pt tile, 38pt glyph. Radius: `DS.Radius.md` on the tile at 24pt, `DS.Radius.xl` at 64pt.

### DS.Elevation — there is no elevation ladder
macOS conveys depth through **material** and through **content surfaces being darker than window chrome**, not through progressively lighter greys. Delete any notion of base/elevated (an iOS mechanism with no macOS equivalent). The only two depth mechanisms in this app: (1) unpainted functional layer = system material; (2) painted content layer = `DS.Surface.ground`, which is darker than the material. Shadows: none, anywhere, except the system-supplied sheet and popover shadows we do not draw.

The app is unconditionally dark. This is permitted by the HIG for immersive apps, and it is **not a setting** — there is no theme picker. Light-mode token definitions are not written, and `NSApp.appearance` is pinned to `.darkAqua` at launch so system-supplied chrome matches.

## Components

Every component below lists the tokens it uses and all six states. "—" means the state does not change the component. Any state not listed is a bug.

### 1. Sidebar row (bot roster)
Container: `List(.sidebar)` with **no `.background()`** — the material shows through. Row: 28pt height, 8pt leading / 10pt trailing inset, `DS.Radius.sm` (6) on the fill shape, inset 4pt from the column edges. Content: 24pt avatar + `DS.Space.md` (8) + VStack(name `DS.Text.body`/`.primary`, label `DS.Text.micro`/`.secondary`) + Spacer + 6pt status dot.
- rest: no fill; name `.primary`; label `.secondary`
- hover: fill `DS.Tint.t3` (0.078). In: 0ms. Out: `DS.Motion.hoverOut`. Gate with a 70ms enter delay so a cursor traversing the list does not strobe. No scale.
- press: fill `DS.Tint.t5`, no scale
- focus: system ring only, never animated
- disabled: n/a (a bot is never disabled)
- selected (window focused): fill `DS.Accent.live` at 0.14 opacity; name `.primary`; hover is a **no-op** while selected
- selected (window unfocused): fill `DS.Accent.unfocusedSelection`
- running: status dot amber9 with an opacity pulse only (no scale), gated off under reduced motion

### 2. Message bubble
Incoming: `DS.Surface.raised` #212225, radius `DS.Radius.xl` (16), padding 10 vertical / 12 horizontal, `maxWidth DS.Size.bubbleMax` (620), leading inset 16pt from the pane edge. Outgoing: `DS.Surface.active` #2e3135, same geometry, trailing aligned. Text `DS.Text.body` `.primary`, `lineSpacing` 2.5. Gap between consecutive bubbles from the same speaker: **4pt**; between speakers: `DS.Space.lg` (12). Timestamp `DS.Text.micro` `.secondary`, revealed on row hover, also present in the context menu.

Radius is **16, not Grok's measured 20**. 20pt at 13pt text is the single most web-looking number in the sampled set; 16 is the Radix step and holds the shape at native density.
- rest / hover: bubble itself does not change; only the hover-revealed copy button appears (`DS.Motion.hoverIn` 0ms in, `hoverOut` out)
- press: — (a bubble is not a button)
- focus: — · disabled: — · selected: text selection uses `.selection`
- streaming: trailing caret, 2pt × 14pt, `.primary`, 530ms on/off, solid under reduced motion, removed the frame the stream ends

### 3. Tool card (a tool call in the transcript)
`DS.Surface.raised`, radius `DS.Radius.lg` (12), 1pt `DS.Surface.border` stroke, 12pt padding, `maxWidth DS.Size.cardMax` (640). Header row 24pt: 12pt SF Symbol for the tool + 8pt + tool name `DS.Text.title` + Spacer + status pill. Body: the arguments in `DS.Text.mono(11)` `.secondary`, inside a `DS.Surface.panel` well with `DS.Radius.sm` (6 = 12 − 6 padding). Collapsed by default; chevron rotates 90° over `DS.Motion.disclosure`.
- rest: as above · hover: stroke → `DS.Surface.borderStrong`, 0ms in / 120ms out
- press (on the header, which toggles): whole card `DS.Motion.press`, scale 0.97
- focus: system ring on the header · disabled: — · selected: —
- running: status pill Running amber; a 2pt amber9 bar pinned to the card's bottom edge, indeterminate
- failed: stroke red9 at 28% opacity; body shows stderr in mono `.primary`

### 4. Approval / human-handoff card
The safety spine surfacing in the UI, and the same shape serves both. `DS.Surface.raised`, radius `DS.Radius.lg` (12), **1pt orange9 #f76b15 stroke at 45% opacity** (this is the only stroke in the app that reads as "stop"), 16pt padding, full `cardMax` width — never a bubble, never an alert.
Layout: title row (`hand.raised.fill` orange11 + title `DS.Text.title` `.primary` + Spacer + status pill) / one-line instruction `DS.Text.body` `.primary` / detail `DS.Text.mono(11)` `.secondary` in a `DS.Surface.panel` well / footer row of buttons, trailing aligned, 8pt gap.
Copy pattern, in this order, all four required: **what** the bot wants to do (naming the capability and the scope), **which bot** wants it, **why now**, and **what happens next** — including "macOS will not ask again" where a TCC grant is involved.
- Needs you: pill orange, buttons `[Deny]` `.secondary` plain · `[Allow once]` soft · `[Always allow]` soft
- Running: pill amber, buttons replaced by `[Stop]` destructive plain
- Done: pill green, stroke drops to `DS.Surface.border`, buttons replaced by `[Open computer]` / `[Show in Activity]`
- Blocked by floor: pill Blocked red, no allow button at all, footer line "Built-in safety checks always apply."
- hover/press/focus/disabled: inherit from the button styles below; the card itself has no hover state

### 5. Chip (filter, capability tag, inheritance tag)
Height 20pt, horizontal padding 8, radius `DS.Radius.pill`, `DS.Text.caption` (11).
- rest: fill `DS.Tint.t3` on material / `DS.Surface.raised` on content; label `.secondary`
- hover: fill `DS.Tint.t4` / `DS.Surface.raisedHover`; 0ms in, 120ms out
- press: fill `DS.Tint.t5`, scale 0.97, `DS.Motion.press`
- focus: system ring · disabled: label `.tertiary`, fill unchanged, no hover
- selected: fill `DS.Accent.live` at 0.16, label `.primary`, hover is a no-op
- **"Default" inheritance capsule** variant: `DS.Text.micro`, fill `DS.Tint.t2`, label `.tertiary`, not interactive

### 6. Button — exactly three styles, no others
**`.primary`** (inverted, the only filled style): fill `DS.Ink.exportHigh` #edeef0, label `DS.Surface.ground` #111113 → **16.25:1**. Height 24 (28 in sheets), horizontal padding 12, radius `DS.Radius.sm` (6), `DS.Text.body`.
**`.soft`** (secondary affirmative): fill blue3 #0d2847, 1pt blue7 #205d9e border, label blue11 #70b8ff → **7.08:1**.
**`.plain`** (everything else, including destructive): no fill, no border, label `.primary` or — when destructive — red11 #ff9592.
A filled blue button is banned (white on blue9 = 3.26:1). A filled red button is banned everywhere: in a settings pane it reads as the pane's primary action, which it never is.
- rest / hover: `.primary` fill → #f5f6f8; `.soft` border → blue8 #2870bd; `.plain` fill → `DS.Tint.t3`. 0ms in, 120ms out.
- press: scale 0.97, `DS.Motion.press` (0.10). **Destructive buttons are asymmetric: 0.16s on press, 0.10s on release** — the press reads as a deliberate hold.
- focus: system ring · disabled: opacity 0.4, no hover, no press · selected: —

### 7. Text field / composer
Composer: `DS.Surface.panel` #18191b, radius `DS.Radius.xl` (16), 1pt `DS.Surface.border` stroke, 10/12 padding, `DS.Text.body`, placeholder `.placeholder`. Min height 36, grows to 8 lines then scrolls.
- rest: stroke `DS.Surface.border` · hover: stroke `DS.Surface.borderHover` #5a6169, 0ms/120ms
- **focus: stroke `DS.Surface.borderStrong` #43484e, set instantly — 0ms, no animation.** Remove the existing `.animation(DS.Motion.instant, value: focused)`; focus is keyboard-driven and fires hundreds of times a session.
- press: — · disabled: fill `DS.Surface.ground`, text `.tertiary` · selected: `.selection`
- error: stroke red9 at 45%, one-line message below in `DS.Text.caption` red11

### 8. Disclosure
Header 28pt, chevron 10pt leading, rotates 0°→90° over `DS.Motion.disclosure` (0.18) on the same curve — **rotate, never swap the glyph**. Content animates height via `withAnimation` on a state change (not a manual `frame(height:)`), and fades in `opacity` over the final 0.12s so text never appears stretched. Never animate more than a handful of rows at once. Under reduced motion: snap open, fade content over 0.15s, no height animation.
- rest/hover/press/focus/disabled/selected: header inherits sidebar-row behaviour; the expanded state persists per-item in `@AppStorage`

### 9. Settings row
Inside a `DS.Surface.raised` card with `DS.Radius.lg` (12), no border. 12pt horizontal / 10pt vertical padding, min height `DS.Size.settingsRow` (44), auto-height when help text is present. Label `DS.Text.body` `.primary`; help text `DS.Text.caption` `.secondary`, max width 560. Divider: 1pt `.separator`, inset 12pt from leading, flush trailing. Control right-aligned, leading edges aligned across every card in the pane via a **shared alignment guide, not `Spacer()`**. Control is pinned to the label's **first-line baseline**, not the row's vertical centre — a switch floating in the middle of a three-line paragraph looks unattached.
- rest · hover: no fill change (a settings row is not a target; only its control is) · press: — · focus: system ring on the control · disabled: label and help `.tertiary`, control disabled
- inherited (still on the app default): control label `.secondary` + trailing "Default" capsule
- overridden: control label `.primary`, capsule swaps to a `[Reset]` `.plain` button

### 10. Connection row
`DS.Size.denseRow` variant at 32pt (it carries two lines). Leading: 12pt status glyph in the state's step-11 colour + 8pt. Centre: provider name `DS.Text.body` `.primary`, and `state word — detail` in `DS.Text.caption` `.secondary`. Trailing: action button `.soft` using the verb already in `ProviderHealth.Status.action` (Check / Connect / Repair / Reconnect), then an 8pt gap, then a mini `Toggle`. Never colour alone — glyph, word and colour together, per HIG.
Sort worst-first under three headers: **NEEDS YOU** (needsAuth, offline, error) / **CONNECTED** (healthy, degraded) / **OFF**. Summary strip above: three filter chips plus `[Check all]` and `checkedAt` as relative time.
- rest/hover/press/focus/selected: as sidebar row, at 32pt
- disabled (toggle off): name and detail `.tertiary`, glyph `.quaternary`, action button hidden
- initializing: glyph is a `Spinner` gated behind 400ms

### 11. Empty state
All three parts, per NN/g: **why it is empty**, **what would appear here**, and **the button that starts it**. Centred in the pane, max width 420, `DS.Space.xxxl` (40) margins. Glyph 28pt `.quaternary` / `DS.Space.lg` / title `DS.Text.title` `.primary` / `DS.Space.md` / body `DS.Text.callout` `.secondary` / `DS.Space.xl` / one `.primary` button.
- Empty roster: "No bots yet." / "A bot is a named identity with its own files, its own logins, and its own permission rules. Nothing runs until you make one." / `[New Bot]`
- Empty chat: the bot's own description rendered as the introduction (it is the thing the user is about to edit anyway), or if blank: "This bot has no description." / "The description is its brief — it is injected on every run and it is how the roster routes a request to the right bot." / `[Write a description]`
- Empty activity: "No actions recorded." / "Every tool call any bot makes is appended here with its arguments, the permission decision, and a hash chained to the previous entry. The record survives this app being deleted." / `[Show trace folder]`
- hover/press/focus: on the button only · disabled/selected: n/a

## Settings

## The window shell
**`NavigationSplitView` inside a `Settings` scene** — not `TabView(.sidebarAdaptable)`. The rule to write into the ADR: **up to 5 panes, none holding a browsable list → toolbar tabs; 6+ panes, or any pane holding a live list → sidebar.** We have 7 panes and Connections is a live list.

- Default 940 × 660pt · minimum 860 × 560 · maximum 1180 wide, unbounded height · resizable (justified: Connections and Activity are scrollable lists)
- Sidebar fixed 210pt, `.navigationSplitViewColumnWidth(210)`, **unpainted** — material, no `DS.Colour.panel` fill, no drawn hairline. (This overrides the settings-ia research, which specified a painted #131314 sidebar; the same rule that governs the main window governs this one.)
- Content pane painted `DS.Surface.ground`, 24pt outer padding, content column max 640pt, **left aligned** — a centred column drifts when panes have different heights.
- Window title = the current pane's name ("Connections"). No subtitle. **No pane title repeated inside the pane** — it costs 40pt of vertical space on every pane and the window already says it.
- Minimise and zoom dimmed: `w.standardWindowButton(.miniaturizeButton)?.isEnabled = false`, same for `.zoomButton`.
- ⌘, opens · Escape and ⌘W close · ⌘F focuses the sidebar search field · last pane restored from `@AppStorage("settings.lastPane")`.
- Pane switch: crossfade at `DS.Motion.instant` (0.12). No slide, no window resize animation.
- **No Save / Cancel / Apply anywhere.** Every control commits on change.
- Sidebar rows: 28pt, 14pt SF Symbol in a fixed 18pt frame + 8pt + `DS.Text.body`; group headers `DS.Text.micro` `.secondary` in title case (not uppercase), 18pt top / 6pt bottom, 12pt leading. Attention badge trailing: count on a red9 capsule, height 15, 5pt horizontal padding.

## The seven panes

**1. General** — `gearshape`
Card "New bots start with": Model (pop-up, all installed brains) · Autonomy (pop-up: Ask / Work / Autopilot) · Sandbox profile (pop-up: off / workspace / devbox / read-only / strict) · Notifications ("Get notified when this Bot finishes or needs input").
Card "Startup": Open at login (switch) · Reopen the last conversation (switch).
Link button: **"Open bot settings"** — selects the current bot's inspector and closes this window.
Footer: *"Bot-Harness follows your system appearance, language and accessibility settings."* **No theme picker, no language picker.** Apple's guidance is explicit that redundant versions of systemwide settings confuse people; Grok Bot ships both set to "Follow System" and it is a mistake worth not copying. The app is unconditionally dark and that is not a preference.

**2. Brains** — `brain`
Intro: *"A brain is the model that thinks for a bot. Keys are stored in a file only you can read, and written only — Bot-Harness cannot read one back to you."*
One **expandable** row per provider (not an always-open form). Collapsed: name, one-line purpose, and either a "Key saved" pill (green3 fill, green11 label) or an `[Add key]` `.soft` button. Expanded reveals the `SecureField`, a `[Save]` `.primary`, a `[Remove]` `.plain` destructive, and micro text "Bot-Harness cannot read this back to you."
Removal confirmation: *"Remove your Gemini key?"* / *"Bots using Gemini will stop until you add another key. The key is deleted from your key file."* / `[Cancel]` `[Remove Key]` — non-destructive-styled per the HIG Empty Trash rule.
Footer: *"Model and autonomy are chosen per message, in the composer. They change too often to be settings."*

**3. Connections** — `powerplug`
Summary strip: three filter chips (Needs you N · Connected N · Off N) + `[Check all]` + "Checked 2 minutes ago". Then the Connection rows spec above, grouped worst-first under NEEDS YOU / CONNECTED / OFF, driven entirely by the existing `ProviderHealth` enum and its `action` verbs. **Do not invent a second status vocabulary.**
Footer row: `[+ Add MCP Server]`.

**4. Permissions** — `hand.raised`
Intro: *"Bot-Harness checks each action before it runs and asks you first when needed. Add rules to customise what it can do automatically."*
Card "Rules": the composer, which **does not exist today and is the largest dead end in the app** — `PermissionSettings` currently renders `store.globalRules` read-only with no way to add, edit or delete. Ship: "When a bot wants to:" `TextField` (placeholder "e.g. reply to emails for me") / "It should:" `Picker` bound to `PermissionRule.Behaviour.displayName`, default "Allow automatically" / `[Add Rule]` `.primary`, disabled while the field is empty. Below it an **Action | Behaviour** table whose Behaviour cell is itself an in-place pop-up, with hover-revealed pencil and trash `IconButton`s at `DS.Size.iconButton` (24) — both also present in the row's context menu, because hover must never be the only path to an action.
Rule text below the table: *"Write one short, natural-language rule for each action. \"Ask first\" takes priority if rules conflict."* Footer: *"These rules apply only to you. Built-in safety checks always apply."*
The UI is Grok's and it is good; the matching underneath is typed capability + scope, not string matching against tool-call intent.
Card "This Mac": four rows — Screen Recording, Accessibility, Automation, Files and Folders. Each: granted/not-granted glyph + word, one sentence saying what a bot cannot do without it ("Without this, no bot can see your screen or take a screenshot."), and `[Open System Settings]` firing the `x-apple.systempreferences:` deep link for that specific pane. **Re-poll grant state on `NSApplication.didBecomeActiveNotification`** — without that it shows stale state and is worse than nothing.
Card "Allow everything, without asking" — **the only red-stroked card in the app** (1pt red9 at 28%). Switch, default off. Confirmation is destructive-styled: *"Every bot will run every action without asking, for one hour."* / `[Cancel]` `[Turn On for 1 Hour]`. While active: a live countdown in the row **and a persistent banner in the main window** — a dangerous mode visible only inside Settings is not visible.

**5. Sandbox** — `shield.lefthalf.filled`
Card "Profile": five radio rows using the vocabulary verbatim — **off / workspace / devbox / read-only / strict** — each with its write scope as help text ("workspace — reads anywhere, writes only to the bot's root, ~/.botharness/, /tmp and /var/tmp"). Custom-profile disclosure exposes `extends`, `restrict_network`, `read_only`, `read_write`, `deny` with gitignore-style globs.
Card "Environment": *"Variables matching \*KEY\*, \*SECRET\* and \*TOKEN\* are removed before any bot starts a process."* with `inherit` pop-up (core / all / none) and disclosures for exclude / include_only / set.
Card "Hooks": three rows — PreToolUse, PostToolUse, SessionStart — each a path field plus `[Test]`, with help text naming the JSON stdin contract and the allow/deny result.

**6. Activity & Traces** — `list.bullet.rectangle`
Card "Where": the trace path and the screenshot path, each with `[Show in Finder]` and a size. Pull-down `[Manage ▾]`.
Card "Retention": "Keep traces for" pop-up (30 days / 90 days / 1 year / Forever).
Card "Integrity": `[Verify Chain]` — reports in place ("4,812 entries verified. Chain intact." green, or the first broken index in red).
Destructive card (`DS.Surface.raised`, 1pt red9 at 28%, **no "Danger zone" label — name the actual thing**): "Delete all traces" and "Delete all screenshots", each a `.plain` red11 right-aligned button whose confirmation **enumerates real counts and bytes** — *"Delete 4,812 trace entries and 219 MB of screenshots?"* — rather than saying "this cannot be undone".

**7. About** — `info.circle`
Version, build, the signing identity, a `[Check for Updates]`, and one line: *"Bot-Harness runs on this Mac. Nothing leaves it except the requests you configure."*

## The inheritance mechanic, across all three tiers
App default → per-bot → per-run. A per-bot control still on the app default renders `.secondary` with a trailing micro "Default" capsule; overriding it flips the label to `.primary` and swaps the capsule for a `[Reset]` `.plain` button. Identical pattern for a per-run override in the composer. Neither Grok Bot nor Raycast does this, and it is what makes three tiers legible instead of confusing.

## What stays out of Settings
Per-bot identity (avatar, Name, Label, Description, Notifications, model), Routines, and per-bot rules live in the **right-hand inspector**, never here. Apple: *"prefer letting people modify task-specific options without going to your settings area… Putting this type of option in a separate settings area disconnects it from its context."* Model and autonomy live in the **composer**, per message.

## Sidebar search
A search field bound to ⌘F, indexing pane names, section headers and every control label. At seven panes it is a convenience; retrofitting search into a pane structure that was never indexed is expensive, so it ships now.

## Where the research disagreed with itself

Recorded rather than smoothed over: each was a real fork, and the reasoning is the part
worth keeping.

- PALETTE: Grok's sampled greys vs Radix slate vs macOS semantics. RESOLVED for Radix as the opaque ramp; Grok's palette is rejected as the base. Grok's values (#070707, #111111, #262626, #5a5a5a) are pure achromatic Electron greys with no semantic contract and no alpha companion. Matching them 'so the comparison is head-on' would make us look like the Electron app we claim to beat, and #5a5a5a as a user bubble is far too loud at our density. We keep Grok's information design — bubble geometry, the natural-language rule form, the handoff card, the settings copy — and discard its pixels. Our nearest equivalents: canvas slate1 #111113 (vs #070707), incoming slate3 #212225 (vs #262626), outgoing slate5 #2e3135 (vs #5a5a5a), composer slate2 #18191b (vs #2f2f2f).
- PAINTING THE CHROME: settings-ia and grokbot-mechanics both specify painted sidebars (#131314 and #111111 with drawn hairlines); macos-visual-language says stop painting split views entirely. RESOLVED for macOS, in both windows. The functional layer — roster sidebar, inspector, toolbar, sheets, Settings sidebar — gets no .background() at all and no drawn hairline (Divider() or .separator only). Apple names split views, tab bars and toolbars as the specific places custom backgrounds interfere with Liquid Glass and the scroll edge effect. The content layer — conversation pane, Settings content pane — is painted opaque slate1. This is the single change that decides whether the app reads as Mac-native, and it is a net deletion of code.
- TEXT COLOUR: Radix slate11/slate12 vs macOS label alphas. RESOLVED for macOS semantics in-app. labelColor is #FFFFFF at 84.7% alpha, not a grey; only an alpha composite renders correctly over a material and only a semantic name tracks Increase Contrast and desktop tinting. Every readable string uses .primary/.secondary/.tertiary. Radix slate12 #edeef0 and slate11 #b0b4ba are kept as DS.Ink.exportHigh/exportLow, used only in exported PNGs and rendered traces where a fixed value must reproduce identically years later. Consequence to accept: .tertiary composites to 2.2:1 on our canvas, so it is decorative and disabled-only and may never carry a string the user must read.
- ACCENT: macos-visual-language measured controlAccentColor #007AFF and systemBlue #0088FF as different colours; design-system-candidates proposes Radix blue9 #0090FF. RESOLVED three ways, not one. DS.Accent.live = Color(nsColor: .controlAccentColor) for selection, primary actions and focus, because only it tracks the user's System Settings choice. DS.Accent.static = blue9 #0090ff for traces, exports and chart series, which must not change when the user changes their accent. systemBlue is used nowhere. Every hardcoded #007AFF is deleted — macOS 26 shifted the whole system palette (systemRed is now #FF383C, systemPurple #CB30E0), so remembered constants are stale.
- GEOMETRY: Grok's measured 278.5pt sidebar / 318pt inspector / 20pt bubble radius vs macOS split-view conventions. RESOLVED for native metrics. Roster is min 180 / ideal 240 / max 320 (AppKit's own 140pt minimum is too tight for a name plus a status glyph, and 278 is a fixed Electron number, not a resizable native column). Inspector is min 260 / ideal 300 / max 380 (AppKit's fixed inspector default is 270). Bubble radius is 16, the Radix step — 20pt at 13pt text is the most web-looking number in the whole sampled set. Grok's 4pt same-speaker gap and 16pt leading inset are adopted unchanged; both are correct.
- ROW HEIGHT: macos-visual-language specifies 24pt to match NSTableView's default; settings-ia specifies a 44pt minimum for settings rows. RESOLVED as two different components, not one number. Dense data rows (activity log, trace list) are 24pt. Roster rows are 28pt (they carry an avatar and two lines). Connection rows are 32pt. Settings rows are 44pt minimum and auto-height when help text is present. Nothing else hardcodes a row height — macOS 26 increased list and form padding and hardcoded metrics are exactly what Apple warns will look wrong.
- DEPLOYMENT TARGET: macos-visual-language argues for macOS 26.0 to unlock glassEffect and ConcentricRectangle; settings-ia argues for 15.0 to unlock .sidebarAdaptable; Package.swift currently says 14. RESOLVED as macOS 15.0 deployment target, built against the macOS 26 SDK, with zero glassEffect() calls of our own. Liquid Glass is applied to system-supplied chrome by the SDK you build against, not by the deployment target, so by not painting the chrome we get the new look on toolbars, sheets and split views for free and write no #available branch anywhere. Apple's own guidance is that glassEffect on custom controls 'can provide a subpar user experience by distracting from that content' — the honest count of custom elements that earn it in this app is zero, and ConcentricRectangle is replaced by the arithmetic nesting rule (inner = outer − padding).
- SETTINGS SHELL: HIG text describes toolbar tabs; SwiftUI ships .tabViewStyle(.sidebarAdaptable); settings-ia recommends NavigationSplitView. RESOLVED for NavigationSplitView inside the Settings scene. .sidebarAdaptable has open AppKit-bridging problems in a Settings scene (centred toolbar items, a sidebar toggle you must strip with .toolbar(removing:)) and gives no control over row rendering. The stated threshold: up to 5 panes with no browsable list → toolbar tabs; 6+ panes or any live list → sidebar. We have 7 and Connections is live. Raising Package.swift to .macOS(.v15) is required for other reasons but not for this.
- TYPE SCALE: the codebase's six half-point sizes (10.5, 11.5, 12.5, 13.5) vs macOS system metrics. RESOLVED for the OS. Five sizes, each bound to a system text style rather than Font.system(size:), so they track OS changes and optically line up with the toolbar: 13 body, 13 semibold title, 12 callout, 11 caption, 10 micro. The 11.5 and 12.5 sizes appear 31 times and match nothing the OS draws. One departure from macos-visual-language: it maps titles to .headline, which on macOS is Bold 13 (resolved font name .SFNS-Bold) — too heavy at this density — so titles use Body Emphasized (13 semibold), which is a documented HIG variant.
- AVATARS: the research supplies 11 sampled Grok picker swatches and instructs deriving the glyph fill as a lighter tint. REJECTED, and the research's own measurements are why. The two measured swatch-to-glyph pairs disagree in direction: amber #D48F35 renders lighter as #F19D38, but blue #3B79D8 renders slightly darker as #3472D9. No single ratio reproduces both, and the other nine pairs were never measured, so any derivation would be a guess dressed as a spec. We ship 8 avatar colours instead — Radix step 9 glyph on step 3 tile, all eight hues verified with sRGB and P3 values — times 8 shapes, for 64 deterministic identities derived from Bot.id.
- MOTION, and two stale claims in the research. The interaction track states 'grep found no reference to accessibilityReduceMotion anywhere in Sources/BotHarness/UI/' — that is literally true but misleading: the mechanism already exists as dsAnimation in Sources/BotHarness/Design/Tokens.swift:195 and is simply used at only 4 call sites (RootView.swift:35 and Primitives.swift:71, 144, 439). The fix is a sweep, not a build. The track also says press scale is 0.96 and Composer.swift:315 uses 0.12 — the file actually has two competing implementations: DS.Motion.pressScale = 0.96 in Tokens.swift, and PressableButtonStyle in Composer.swift:311-316 with a hardcoded 0.94 scale, 0.85 opacity and .easeOut(0.12). Both are replaced by one source of truth at 0.97 / DS.Motion.press (0.10), and the opacity dip is deleted — scale alone is what reads as physical.
- HOVER: hoverEffect(_:isEnabled:) is unavailable on macOS entirely (Apple's platform list is iOS/iPadOS/Mac Catalyst/tvOS/visionOS), so every hover state in this app is hand-built on .onHover. Instant in, 120ms ease-out out — the asymmetry is the point. Rows get a 70ms enter delay so a cursor traversing the sidebar does not strobe; buttons get none. Rows never scale, only tint. Hover on an already-selected row is a no-op. And nothing is reachable by hover alone: every hover-revealed control is also in the row's context menu and reachable by Full Keyboard Access.
- STREAMING SCROLL: ConversationView currently animates proxy.scrollTo(last.id, anchor: .bottom) on message change (the research cites line 104; the file has since been modified and the call has moved, so locate it by symbol rather than by line). Resolved as three separate fixes: .defaultScrollAnchor(.bottom) on the ScrollView so SwiftUI repositions on content-size change; the explicit scrollTo restricted to genuine message insertion and never to growth of the streaming last message; and a user-scroll disengage that stops auto-scrolling once the user is more than 40pt off the bottom and resumes when they return.

## Build order

1. 1. Rewrite Sources/BotHarness/Design/Tokens.swift against the spec: add private Color(hex:) and Color(p3:) helpers; split DS.Colour into DS.Surface (opaque slate 1-8), DS.Tint (slateA 2-7), DS.Ink (macOS semantic + two export constants), DS.Accent (live/unfocused/static) and DS.Status (7 states, step 9 dot + step 11 label + glyph + word). Put the Radix step number in a trailing comment on every value. Keep the old DS.Colour names as deprecated typealiases for exactly one commit so the app still builds, then delete them in step 3. Pure substitution — no view changes yet.
2. 2. In the same file: collapse DS.Text to the five system-text-style-bound steps; snap DS.Radius to 4/6/8/12/16/pill; update DS.Size with the split-view widths, the four row heights and the 52pt titlebar; replace DS.Motion with the 13 tokens; add DS.Motion.gated(_:) reading a single @Environment(\.accessibilityReduceMotion) published from RootView, and DS.Avatar (8 shapes x 8 colours).
3. 3. Sweep all ten view files plus Primitives.swift for raw numbers, raw colours and raw .opacity() literals, replacing each with a token; then delete the deprecated DS.Colour typealiases so the compiler proves the sweep is complete. Delete the duplicate PressableButtonStyle in Composer.swift and route everything through DS.Motion.press / pressScale 0.97. This is the step that makes the file's own doc comment ('a view may not contain a raw number') true rather than aspirational.
4. 4. Delete every .background() on the roster column, the inspector column, the toolbar and all sheets, and delete every hand-drawn grey hairline in favour of Divider() / .separator. Paint only the conversation pane and the Settings content pane, with DS.Surface.ground. Raise Package.swift to .macOS(.v15). Build against the macOS 26 SDK; add no glassEffect() call. This is a net deletion and it is the highest-value change in the list.
5. 5. Set NSApp.appearance = .darkAqua at launch, the window to .unified toolbar style, roster .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320), inspector .inspectorColumnWidth(min: 260, ideal: 300, max: 380), and .listStyle(.sidebar) on the roster.
6. 6. Build the shared component layer in Primitives.swift against the component spec: the three button styles (.primary inverted, .soft, .plain — delete any filled blue or filled red), Chip with its Default/Reset inheritance variants, StatusPill driven by DS.Status, the .rowHover() modifier (onHover, 0ms in / 120ms out, tint only, 70ms enter delay on rows, no-op when selected), Disclosure at 0.18 with the rotating chevron and trailing opacity fade, and the Spinner gated behind a 400ms delay.
7. 7. Rebuild the transcript components: message bubble (16pt radius, 4pt same-speaker gap, 16pt inset, 620 max), tool card, and the approval/human-handoff card as a first-class message type with its four-part copy contract and Needs you / Running / Done / Blocked states. The handoff card is the shape the permission floor needs for actions we will never take ourselves, so it ships before the streaming work.
8. 8. Fix streaming, in this order because each depends on the last: a 60Hz drain buffer in BotRunner flushing one word per ~10ms to the published string; incremental-markdown safety that parses only closed blocks and renders the trailing incomplete block as plain monospace; then .defaultScrollAnchor(.bottom) plus the insertion-only scrollTo and the 40pt user-scroll disengage; then the 530ms caret.
9. 9. Sweep every withAnimation and .animation call site in ConversationView, RootView, MessageRow, ActivityWindow, LibrarySheet, ContextPanelView, Composer and SettingsView through DS.Motion.gated. Remove .animation(DS.Motion.instant, value: focused) from the composer border. Cap the stagger at the first 5 items. Verify no keyboard-triggered action animates.
10. 10. Replace SettingsView's three-tab TabView with the NavigationSplitView shell: 940x660 default, 860x560 minimum, 210pt unpainted sidebar, title bound to the pane, minimise and zoom dimmed, last pane in @AppStorage, Escape and Cmd-W to close, Cmd-F to the search field, crossfade at 0.12. Keep the Settings scene so Cmd-comma still works.
11. 11. Build the Permissions pane, which is the largest functional gap: the two-field natural-language composer feeding an editable Action | Behaviour table with hover-revealed edit and delete that are also in the context menu; the This Mac grants card re-polling on NSApplication.didBecomeActiveNotification; and the single red-stroked 'Allow everything' card with its countdown and its main-window banner.
12. 12. Build the remaining panes in this order: Connections (against the existing ProviderHealth enum and its action verbs — do not invent a second vocabulary), Brains (expandable provider rows, write-only keys, the removal confirmation, the composer footer line), General (new-bot defaults plus the 'Open bot settings' link and the systemwide-settings footer), Sandbox, Activity & Traces, About.
13. 13. Write the three empty states with all three NN/g parts, and the permission-needed inline transcript row with its [Open System Settings] deep link. Replace vague status copy with the operation being performed — 'Reading 4 files', 'Waiting on Gemini' — never 'Working…'.
14. 14. Wire the keyboard shortcuts, none of which animate: Cmd-. to Stop (Apple's documented Cancel, and the most important shortcut in an app that runs shell commands on a real Mac), Cmd-Shift-A for Activity, Cmd-1 through Cmd-9 for bot switching, Cmd-0 for the inspector, Cmd-K for the palette.
15. 15. Add the screenshot check to the eval suite, capturing by window ID rather than full screen (per the repo's own note about not stealing focus), in four configurations: dark, dark with Increase Contrast, dark with Reduce Transparency, and Reduce Motion. Increase Contrast and Reduce Transparency are where alpha-over-material most often produces dark text on a dark background, and that matrix is the falsifier for the whole approach.
16. 16. Write four ADRs in docs/decisions/, each with its falsifier. Design system base (Radix plus a macOS override layer — wrong if Apple ships a documented numeric neutral surface ramp, or if alpha-over-material breaks under Increase Contrast or Reduce Transparency; test both before closing). Deployment target and glass adoption (macOS 15 target, macOS 26 SDK, zero glassEffect — wrong if anyone needs to run on macOS 14). Motion policy (the frequency table, the 300ms ceiling, never animate keyboard actions, the reduced-motion drop/keep list — wrong the moment a user reports a specific interaction feeling laggy, because that interaction was animated when it should not have been). Settings shell (the 5-pane rule — wrong if the pane count drops to five with no live list, at which point the window goes back to toolbar tabs). Then one CHANGELOG.md line per session, written for the person using the app.