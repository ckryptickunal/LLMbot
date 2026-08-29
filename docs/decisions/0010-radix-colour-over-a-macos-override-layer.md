---
id: 0010
title: Radix Colors for surfaces, macOS semantics for everything the OS owns
status: accepted
date: 2026-08-30
deciders: [Kunal, Claude]
tags: [design, ui]
---

# 0010. Radix Colors for surfaces, macOS semantics for everything the OS owns

## Context

The interface was built from hand-picked hex greys — `Color(red: 0.055, green: 0.055,
blue: 0.059)` and thirty-odd siblings — plus six half-point font sizes and `Color.white
.opacity(…)` scattered through every view. It looked plausible in isolation and wrong beside
a real Mac app, and nobody could say which grey to use for a new surface because there was no
rule, only precedent.

Three measurements, taken on this machine rather than from documentation, reframed the problem:

- macOS semantic label colours **are not greys**. `labelColor` is white at 84.7% alpha,
  secondary 54.9%, tertiary 24.7%, separator 9.8%. That is why they sit correctly on
  translucent material and why a literal grey never does.
- The system palette **shifted in macOS 26**. `systemRed` is `#FF383C`, not the `#FF3B30`
  everyone has memorised, and `controlAccentColor` (`#007AFF`) is a *different colour* from
  `systemBlue` (`#0088FF`).
- macOS publishes **no numeric neutral surface ramp**. You get `windowBackground`,
  `controlBackground`, `underPageBackground` and nothing between. A three-pane cockpit needs
  five distinguishable depths.

## Options considered

### Option A — Copy Grok Bot's palette
- **For:** The comparison would be head-on, and the values are already measured
  (`#070707`, `#111111`, `#262626`, `#5a5a5a`).
- **Against:** They are flat achromatic Electron greys with no semantic contract and no alpha
  companion. Copying them would make this look like the Electron app it claims to beat.

### Option B — macOS semantic colours alone
- **For:** Perfectly native, tracks the user's settings, zero maintenance.
- **Against:** There is no surface ramp to use. Five depths cannot be built from three names.

### Option C — Radix Colors alone
- **For:** A complete, documented, MIT scale with a semantic contract per step.
- **Against:** Fixed values do not track Increase Contrast, desktop tinting or translucency,
  and text especially would be wrong over any material.

### Option D — Radix for surfaces, macOS for what the OS owns
- **For:** Each supplies what the other cannot.
- **Against:** Two sources means a rule about which applies where, and that rule has to hold.

## Decision

We chose **Option D**.

- **Radix slate dark, steps 1–8** for opaque surfaces, and the matched **alpha** scale for
  anything drawn over a material. Radix's 12 steps are a semantic contract — 3 is an element
  background, 6 a subtle border, 9 a solid fill, 11 low-contrast text — so the scale says which
  value to use rather than leaving it to taste. Its alpha ramp is authored as a slightly cool
  white, which is what stops stacked overlays drifting brown.
- **macOS semantics for text, accent, materials and the focus ring.** Every readable string is
  `.primary` / `.secondary` / `.tertiary`; the accent is `controlAccentColor`, never a literal.
- **Radix step 9 for status marks, step 11 for status words**, because white on a step-9 fill is
  3.2:1 and fails AA. No text ever sits on a step-9 fill.

And the rule that carries the most weight: **the functional layer is never painted and the
content layer always is.** The roster, the inspector, the toolbar and every sheet get no
background at all and inherit the system material; only the conversation pane is filled, and it
is filled darker than the window, which is the native relationship.

Because: each source supplies exactly what the other cannot, and the split is decidable — if it
is text, accent or chrome, it is macOS; if it is a surface, it is Radix.

## Consequences

- **We now must:** keep every value in `DS`. A raw number or colour in a view is a defect, and
  the sweep is provable — the compiler names any straggler because the old names are gone.
- **We now must:** re-verify the measured system colours after each macOS release. They moved
  once already.
- **We can no longer:** paint a sidebar or an inspector, which also means we inherit macOS 26's
  chrome for free without a single availability check.
- **We gain:** an answer to "which grey?" that is not taste.

## Revisit when

Either: Apple ships a documented numeric neutral surface ramp, which would make the Radix half
unnecessary; or drawing Radix alpha over a system material proves to break under Increase
Contrast or desktop tinting, which would push text *and* surfaces onto semantics and cost us
the five depths.
