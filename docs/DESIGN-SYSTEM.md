# The design system

> Rewritten 2026-09-03. This document is the contract; `Sources/BotHarness/Design/Tokens.swift`
> implements it, and no view may contain a raw number or a raw colour.
>
> It describes **what is built**. Where something is intended but not implemented it says so in
> that sentence. The previous version of this file did not make that distinction and had drifted
> badly from the code — it specified eight avatar shapes that were never drawn, seven settings
> panes when there are three, and an app that was "unconditionally dark" with "no theme picker",
> which is now false in both halves.

## The shift, in one paragraph

The app was dark-only and got all its structure from fill against fill: five opaque greys, each
a little lighter than the last, stacked to imply depth. The tell was in the token file itself —
`Surface.border` and `Surface.borderStrong` were defined, documented, and had **zero call
sites**. Nothing in the app drew a line, so every boundary was a change of shade and the whole
thing read as a stack of soft grey slabs. The system now follows
[Opensource UI](https://github.com/bidyut10/opensourceui): **paper and ink, structure from
hairlines, flat at rest, one restrained accent.** It follows the macOS appearance and ships both
ramps. See ADR 0025.

## The five rules

1. **Structure is a hairline, not a shade.** A card is the page colour with a one-point border,
   not a lighter rectangle. This is the change that does most of the work.
2. **Flat at rest.** No glows, no gradients, no ambient shadow, no glass. Depth is a border and
   a tonal fill; that is the entire vocabulary.
3. **Focus is a border colour.** Never a ring, never a glow.
4. **One accent, spent on almost nothing.** Neutrals carry the interface. Clay appears on the
   mascot, the send button, and accent-coloured text. Status colours are their own vocabulary
   and are not "the accent".
5. **No purple, no serif, no `design: .rounded`.** Purple, violet and indigo are the most
   reliable tell of generated interface work and are banned outright, including in the bot
   avatar family. Serif is out by instruction. `.rounded` has no macOS precedent.

## Colour

Every value is appearance-aware via `Color.dynamic(light:dark:)`, which wraps
`NSColor(name:dynamicProvider:)` — the provider is asked at draw time, so a colour built once at
launch still flips when the appearance changes. Both ramps were checked numerically; every value
that carries text clears WCAG AA on its own paper.

### `DS.Surface` — the stage

| Token | Light | Dark | Use |
|---|---|---|---|
| `paper` | `#FFFFFF` | `#0C0C0C` | The page. Panes, window fills, cards. |
| `paperTint` | `#FAFAFA` | `#141414` | One step *in*: recessed fields, wells, disabled fills. Never elevation. |
| `hover` | `#F5F5F5` | `#1A1A1A` | A row under the cursor. |
| `selected` | `#EDEDED` | `#232323` | A selected row — a full step past `hover`, so a selected row under the cursor still reads as selected. |
| `pressed` | `#E5E5E5` | `#2B2B2B` | A pressed control. |
| `borderSubtle` | `#F0F0F0` | `#1C1C1C` | Quiet dividers. |
| `border` | `#E5E5E5` | `#262626` | The default edge on a card, field or control. |
| `borderStrong` | `#D4D4D4` | `#333333` | Hovered field; any edge that must be seen rather than felt. |
| `borderFocus` | `#171717` | `#EDEDED` | A focused field. Full ink — the whole focus treatment. |

Dark paper is `#0C0C0C` rather than pure black: pure black against Mac window chrome reads as a
hole rather than a surface, and a hairline on it has nowhere to go.

### `DS.Tint` — over a material

Alpha washes for the roster, the inspector and sheets, where an opaque fill would flatten the
`NSVisualEffectView` into mud. `t2` 2.2% through `t7` 18%, of ink on light and white on dark.
**Every `Color.white.opacity(…)` in a view is a bug; use these.**

### `DS.Ink` — text

`primary` and `secondary` stay macOS-semantic, because `labelColor` is an alpha composite rather
than a grey and only the semantic name tracks Increase Contrast and desktop tinting. The quieter
tiers are explicit, because at that end the exact value is the design:

| Token | Light | Dark | On its own paper | Use |
|---|---|---|---|---|
| `muted` | `#737373` | `#8F8F8F` | 4.74:1 / 6.05:1 | Help text, footers — quiet but readable. |
| `tertiary` | `#A3A3A3` | `#6B6B6B` | 2.52:1 / 3.67:1 | Placeholders, meta. **Never a string that must be read.** |
| `quaternary` | `#D4D4D4` | `#3A3A3A` | — | Glyph washes, non-text marks. |
| `fill` | `#262626` | `#EDEDED` | — | A primary control's fill. |
| `onInk` | `#FFFFFF` | `#0C0C0C` | — | The label on that fill. |

### `DS.Accent` — clay, and nowhere near as much of it

`live` `#DD775B` is the mascot's clay and is identical in both appearances, because it is a brand
colour rather than a neutral. It measures **3.06:1 on white**, so it cannot be text there:
`Accent.text` is the same hue taken down to `#B4502F` (5.09:1) on light and left at `#DD775B`
(6.39:1) on dark. `onAccent` `#2B1811` is the ink drawn on a clay fill (5.3:1 — white on clay is
3.1:1 and fails).

Clay is no longer the selection colour, the focus ring, or a wash behind a hero avatar. It is the
character, the send button, accent text, and the app-wide SwiftUI `.tint` — the last being a
deliberate exception, because a macOS selection drawn in grey reads as disabled.

### `DS.Status` — never colour alone

Every status is **a glyph, a word and a colour**, so it survives colour-blindness and a greyscale
screenshot. One `mark` value per state serves the dot, the bar and the word; the chip behind it
is that mark at 10% with a hairline of the same mark at 24%, so a chip can never drift out of
step with the dot beside it.

| State | Light | Dark |
|---|---|---|
| idle | `#737373` | `#8F8F8F` |
| running | `#B45309` | `#FFC53D` |
| awaitingApproval | `#C2410C` | `#F97316` |
| done | `#15803D` | `#4ADE80` |
| failed / denied | `#B91C1C` | `#F87171` |
| waiting | `#1D4ED8` | `#60A5FA` |

All twelve clear AA as text on their own paper. The old values were Radix step 9, authored for
dark grounds and unreadable on white — amber9 on paper is 1.7:1.

**The one rule with a real cost if broken:** `running` and `awaitingApproval` must never share a
colour. "Working" and "blocked on you" is the confusion in this app that wastes an afternoon.

### `Bot.tint` — the avatar family

Eight curated anchors, snapped to from the bot's stored hue so a bot's colour survives renames
and relaunches. Each carries two brightnesses: a colour must come *down* to hold an edge against
white and *up* to hold one against black.

terracotta · ochre · gold · moss · sage · cyan · dusty blue · rose

The anchors skip the 0.62–0.88 hue arc entirely, which is why they are spaced as they are: the
old family had a lavender at 0.72 (259°, squarely violet).

## Type

**One voice, SF Pro.** Hierarchy comes from size, weight and tracking, not from a second face.

| Token | Spec | Use |
|---|---|---|
| `display` | 28pt semibold, tracking −0.7 | The one big moment per screen. |
| `headline` | 19pt semibold, tracking −0.4 | Section and pane titles. |
| `title` | body semibold | Card titles, form labels. |
| `body` | `.body` | Message text, rows, fields. |
| `callout` | `.callout` | Supporting text beside a body line. |
| `caption` | `.subheadline` | Chips, metadata, help text. |
| `label` | `.caption` medium, tracking +0.3 | The small label above a field or group. |
| `micro` | `.caption` | Timestamps, counters, hash prefixes. |
| `mono` / `monoSmall` | monospaced body / subheadline | Commands, paths, arguments, hashes. **The only correct use of monospace here** — prose in monospace is a web habit, not a Mac one. |

The negative tracking on `display` and `headline` is the whole trick. SF Pro spaces itself for
reading at body size, so at 28 points the default gaps make a heading look like body text that
was scaled up. This is the same move the reference makes on its own body copy
(`letterSpacing: -0.025em`).

## Space, radius, motion

**Space** is a 4-point base: `hair` 2 · `xs` 4 · `sm` 6 · `md` 8 · `lg` 12 · `xl` 16 · `xxl` 24 ·
`xxxl` 48.

**Radius**: `xs` 4 · `sm` 6 (buttons, chips) · `md` 8 (fields, rows) · `lg` 12 · `xl` 16 (cards,
bubbles, sheets) · `pill`. Nesting rule, not optional: **inner radius = outer radius − inner
padding.**

**Motion** is frequency-gated — how often a control is touched decides whether it animates at
all, and anything triggered by a keyboard shortcut animates never. The ease-out curve is
`cubic-bezier(0.22, 1, 0.36, 1)`, which is the reference's `--ease-smooth` to three decimals,
arrived at independently. Every value passes through `DS.Motion.gated` so reduced motion is
handled once rather than at ninety call sites.

## Components

### Message bubble
Two different objects, not two shades of one. **Outgoing**: `Ink.fill` lozenge, `Ink.onInk` text,
radius 16. **Incoming**: `Surface.paper` with a `Surface.border` hairline, radius 16. Previously
both were greys four per cent apart, which is why a transcript read as a wall rather than an
exchange.

### Buttons
**Primary**: `Ink.fill`, `Ink.onInk` label, radius 6, 28pt tall. Ink and not clay — when the
confirm button, the selection and the mascot are all the same colour, none of them is a signal.
**Secondary**: `Surface.paper` with a hairline; hover moves the fill to `Surface.hover` and the
border to `borderStrong`.
**Send** is the one clay control in the app.

### Cards (`Surface`)
`Surface.paper`, radius 16, 16pt padding, `Surface.border` hairline. Width between `cardMin` 180
and `cardMax` 640.

### Wells (`.dsWell(_:)`, `.dsWellCapsule()`)
A `Tint.t3` fill plus a `Surface.border` hairline. The fill stays a tint rather than becoming
opaque paper because most wells sit on a material. This replaced twenty-five hand-written
`.background(DS.Tint.t3, in: RoundedRectangle(...))` calls, every one of which was a box with a
fill and no edge.

### Composer
`Surface.paper`, pill radius, hairline. Focus moves the border to `borderStrong` rather than the
full-ink `borderFocus` every other field uses — it is the one control that holds focus almost the
whole time the app is open, so its focused state *is* its resting state, and at full ink it was a
permanent black ring around the bottom of the window.

### Chips and status pills
Chips: `Surface.paper` capsule with a hairline. Status pills: the mark at 10% with a hairline of
the mark at 24%.

### Avatar
A flat disc — not `.gradient` — with a dark monogram at 66% and an edge drawn as `black` at 10%.
The old edge was `.white.opacity(0.14)`, which the token file itself listed as a bug and which
disappears entirely on white paper.

### Empty state
Avatar, then the name at `display`, then the persona. No halo: a 200-point radial gradient was
the largest single thing on an empty screen and it was decoration.

## Appearance

`Appearance` is `system` (default), `light` or `dark`, stored in `state.json` and chosen in
Settings → General. It is applied to `NSApp.appearance` rather than only as a SwiftUI
`preferredColorScheme`, because that preference reaches SwiftUI views and stops there — the
toolbar, the window chrome and every material behind the roster ask the application object, and
an app whose sidebar material is dark inside a light window is worse than either mode alone.
`system` maps to `nil`, which is the absence of an override rather than a third appearance.

## Still true from before

- **The functional layer is never painted; the content layer always is.** The roster, the
  inspector, the toolbar and sheets get no background and inherit the system material; the
  conversation pane is filled.
- **No elevation ladder.** macOS conveys depth through material and through content surfaces
  differing from window chrome, not through progressively lighter greys.
- **No `glassEffect()` anywhere.** Verified by search: zero call sites. Built against the
  macOS 26 SDK with a deployment target of **macOS 14** (`Package.swift`, `.macOS(.v14)`; the
  test runner reports `arm64e-apple-macos14.0`), so the new chrome arrives without a single
  `#available` branch. The previous version of this document said 15.0, which was never true.

## Not built

These appear in the previous version of this document and are **not implemented**; they are
recorded here so nobody re-reads them as a description of the app.

- Eight avatar *shapes* (circle, hexagon, droplet, …). The avatar is a circle. Only the colour
  family varies.
- A seven-pane settings sidebar. Settings is a three-tab `TabView`: Providers, Permissions,
  General.
- Per-item disclosure state persisted in `@AppStorage`. There is no `@AppStorage` in this
  codebase; `Store` is the only thing that writes preferences.
