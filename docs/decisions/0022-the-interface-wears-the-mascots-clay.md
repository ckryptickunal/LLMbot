---
id: 0022
title: The interface wears the mascot's clay
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [design, ui]
supersedes: [0010 (accent and surface-temperature clauses only)]
superseded_by: []
---

# 0022. The interface wears the mascot's clay

## Context

Kunal asked for the interface to stop looking generic: "use well thought colour pairing, do
not use generic colour palette." The palette at the time was ADR 0010's — Radix **slate**
(cool blue-grey) surfaces with `controlAccentColor` as the accent, which on this machine is
system blue. Meanwhile the app's most distinctive asset, the ported Claude mascot (ADR 0009),
is warm clay `#DD775B` and stands permanently on the composer. Verified by looking at the
running app: a warm clay character on a cool blue-grey ground with blue action buttons reads
as three products sharing a window.

The constraint that makes this a decision rather than styling: ADR 0010 ruled that the accent
is macOS's to own ("the accent is `controlAccentColor`, never a literal"), and tracking the
user's System Settings choice is real native behaviour with real value. Overriding it closes
that door.

## Options considered

### Option A — Keep slate + system accent, add warm touches around the mascot
- **For:** Keeps ADR 0010 intact; the user's accent preference keeps working.
- **Against:** Does not answer the brief. The ground stays cool, the accent stays whatever
  System Settings says, and the "three products in one window" read stays.
- **Verified against:** the running app before this change (screenshots in session).

### Option B — Radix sand surfaces + the mascot's clay as the accent, everywhere
- **For:** One identity. The character, the send button, the focus ring, the selection and
  the halo are the same colour family; the warm neutral ground makes the clay look native
  rather than stickered on. Same Radix semantic contract (steps 1–8, alpha companions), so
  every "which grey?" answer from 0010 survives — only the temperature changed.
- **Against:** The app stops following the user's accent choice, and dark ink must replace
  white on accent fills (white on `#DD775B` is 3.1:1, fails AA; `#2B1811` on it is 5.3:1).
- **Verified against:** contrast arithmetic in `Tokens.swift` comments; the running app after
  the change.

### Option C — Third-party icon/colour packs for a "premium" look
- **For:** Fast visual novelty.
- **Against:** ADR 0002 — the app is deliberately dependency-free, and a bundled icon font is
  a dependency the user has to trust. SF Symbols with hierarchical rendering already ship on
  every Mac.
- **Verified against:** ADR 0002; no package was added.

## Decision

We chose **Option B**.

Because: the app has a character, and a character wears one colour — every surface the user
recognises this app by (the mascot, the send button, the focus ring, the selection) now agrees
about what that colour is.

Alongside it, and part of the same identity move: bot avatar hues snap to a curated
eight-anchor family tuned against the clay (`BotTint.swift`) instead of a raw hue wheel, and
iconography stays SF Symbols with `.symbolRenderingMode(.hierarchical)` rather than any
imported pack.

## Consequences

- **We now must:** keep every accent fill's ink dark (`DS.Accent.onAccent`) — no white text
  on the clay, ever. And keep `running`/`awaitingApproval` status colours visually distinct
  from the accent, since all three are now warm.
- **We can no longer:** claim the accent tracks System Settings. A user who sets a green
  accent gets clay in this app.
- **We will know this was wrong if:** the clay accent gets confused with the
  `awaitingApproval` orange in real use (they differ in saturation and value, and status
  always carries glyph + word — but that is the risk to watch), or Increase Contrast makes
  any accent-on-sand pairing illegible.

## Revisit when

macOS gives apps a supported per-app accent the user can override (then honouring an explicit
user choice beats the brand), or a status-confusion incident between clay and orange actually
happens.
