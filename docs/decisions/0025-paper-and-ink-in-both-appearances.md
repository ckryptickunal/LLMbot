---
id: 0025
title: Paper and ink, structure from hairlines, in both appearances
status: accepted
date: 2026-09-03
deciders: [Kunal, Claude]
tags: [design, ui]
supersedes: [0010 (dark-only and Radix-sand clauses), 0022 (warm-ground clause only)]
superseded_by: []
---

# 0025. Paper and ink, structure from hairlines, in both appearances

## Context

Kunal's brief was that the app "looks very stale", with
[Opensource UI](https://github.com/bidyut10/opensourceui) as the reference — a React/Next
copy-paste component library whose own design document describes it as "a quiet neutral stage":
white paper, near-black ink, hairline neutral borders, flat surfaces, focus by border colour,
one restrained accent, and an explicit ban on purple, gradients, glows and glassmorphism.

None of that library's code is usable here. It is React 19, Next 16 and Tailwind v4; this app is
native SwiftUI with no dependencies (ADR 0002). What transfers is the design language, which is
written down in `skills/opensource-ui/references/design.md` in that repository and is specific
enough to implement against.

The diagnosis, made by reading the code rather than the screenshots: the app got **all** of its
structure from fill against fill. Five opaque greys, each a little lighter than the last, stacked
to imply depth. The proof was in the token file itself — `Surface.border` and
`Surface.borderStrong` were defined, documented, and had **zero call sites**. Nothing in the app
drew a line. That is why it read as a stack of soft grey slabs: not because the greys were wrong,
but because there were only greys.

Two existing decisions were in the way. ADR 0010 chose Radix dark and ADR 0022 chose a warm sand
ground, and the token file stated the position plainly: *"The system is designed for one mode.
Following the OS here would mean designing a second palette that nobody has designed."*

## Options considered

### Option A — Light only, matching the reference exactly
- **For:** the most faithful reading of the brief; one palette to design and check.
- **Against:** a developer tool that ignores the system appearance and renders white next to a
  dark terminal is not "modern", it is broken. It also throws away the app's existing identity
  for no reason the brief actually asked for.
- **Verified against:** the reference's own colour block, which is light-only.

### Option B — Keep the dark stage, adopt only the theme-independent craft
Spacing, radii, flatness, border-only focus, restrained accent; no light mode.
- **For:** smallest change; both existing ADRs stay intact.
- **Against:** leaves the app dark-only, which is the thing an appearance-aware system exists to
  fix, and leaves the reference's central device — paper — unused.

### Option C — Both ramps, following the system
Build the reference's paper/ink system as the light appearance and a mirrored dark counterpart,
follow `NSApp.appearance`, and offer an override.
- **For:** correct native behaviour; nobody gets a wrong-looking app; the reference's language is
  fully expressed in light and survives intact in dark.
- **Against:** two ramps to design, check and keep in step. Supersedes two ADRs.
- **Verified against:** every value in both ramps was contrast-checked before it was written —
  see the tables in `docs/DESIGN-SYSTEM.md`.

## Decision

We chose **Option C**, and Kunal chose it too when asked directly.

Because: the reference's actual lesson is not "be light", it is **structure comes from hairlines
rather than from shade** — and that lesson is appearance-independent, which is exactly why it can
be delivered in both.

What follows from it, and what each supersedes:

**Hairlines carry structure.** A card is the page colour with a one-point border. This single
change does most of the visible work.

**Both ramps, numerically checked.** Light is the reference's neutral scale; dark mirrors it
around `#0C0C0C`. Every value carrying text clears WCAG AA on its own paper, and matching steps
have matching contrast, so a component does not become quieter by being in dark mode. This
supersedes ADR 0010's dark-only clause.

**True neutral, not sand.** ADR 0022 chose a warm ground because clay on a *cool blue-grey* read
as a sticker on someone else's window. That argument was about blue. True neutral is not blue,
clay sits on it without arguing, and the stage stops having an opinion — which is what a stage is
for. This supersedes 0022's warm-ground clause only; the clay accent itself stands.

**The accent is demoted, not removed.** Clay was the selection colour, the focus ring, the
primary button fill and a wash behind hero avatars. When the confirm button, the selection and
the mascot are all the same colour, none of them is a signal. Clay now appears on the mascot, the
send button, accent text, and the app-wide SwiftUI `.tint`. That last one is a deliberate
exception to the reference's neutral-chrome rule: a macOS selection drawn in grey reads as
disabled.

**No serif.** The reference pairs a display serif with a sans, and the obvious native analogue
was New York. Kunal ruled it out mid-implementation. The display step is sans with negative
tracking instead, which is the same move the reference already makes on its own body copy
(`letterSpacing: -0.025em`) — large sans at default tracking is what looks undesigned; large sans
pulled tight does not.

**No purple, anywhere, including the avatar family.** The old family had a lavender anchor at hue
0.72 — 259°, squarely violet. The eight anchors now skip the 0.62–0.88 arc entirely.

## Consequences

- **We now must:** keep both ramps in step. A colour added to one appearance and not the other is
  a bug that only shows up for half the users, and there is no test that catches it — this is
  checked by launching the app under each appearance and looking.
- **We can no longer:** write `Color.white.opacity(…)`, a gradient, a glow or a shadow in a view.
  White alphas over a light material make it lighter, which is backwards, and the other three are
  banned outright.
- **We can no longer:** assume a bot's tint is legible on a dark ground. Each anchor carries two
  brightnesses because a colour must come down to hold an edge on white and up to hold one on
  black.
- **We will know this was wrong if:** the light appearance turns out to be unusable beside a
  terminal in real daily use and everyone pins the app to dark — at which point the override
  earned its keep and the light ramp did not; or if the hairline structure reads as too quiet on
  a low-contrast external display, which would mean `border` needs to move a step toward
  `borderStrong` rather than that the approach is wrong.

## Revisit when

macOS ships a materials change that makes an unpainted functional layer read differently, or when
someone reports that the app is illegible under Increase Contrast — the two explicit greys in
`DS.Ink` (`muted`, `tertiary`) do not track that setting, and that is the known cost of using
exact values at the quiet end.
