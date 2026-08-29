---
id: 0009
title: Port the mascot's animation rather than embed its runtime
status: accepted
date: 2026-08-30
deciders: [Kunal, Claude]
tags: [ui, design-system, dependencies]
supersedes: []
superseded_by: []
---

# 0009. Port the mascot's animation rather than embed its runtime

## Context

Claude's mascot — the four-legged clay character — exists publicly as an SVG driven by GSAP.
Ayotomiwa Wale-Durojaye reconstructed four of its animations and wrote up how, on Codrops
(`reverse-engineering-claude-ais-mascot-animations-with-svg-and-gsap`, 5 May 2026), with a live
build at <https://ayotomcs.me/claude-mascot>. We want the walking one in the app.

What is actually in that source, read from the shipped bundle rather than inferred from the
article:

- **Eleven rectangles.** `viewBox="0 0 107 86"`. Four legs `11 × 26` at `y=60`; a torso
  `85 × 65`; two hands `22 × 23`; two eyes `11 × 11`. Fills are `#DD775B` and `black`.
- **A clip path at the floor.** `rect(-20, -50, 160, 136)` wrapped around the legs only. It is
  what stops a rotated, stretched leg from sliding through the ground during the lean, and it
  is the single detail that makes the lean read as weight.
- **One GSAP timeline, 11.51 seconds, looping.** Lean left, lean right, look down, hop, walk
  ten strides, lean again, look down, crouch, jump, land with a bounce, stand, snap back.
- **Two leg pivots.** The lean rotates each leg about its foot (`y=86`); the walk squashes it
  from the hip (`y=60`) so the foot lifts. The original swaps `svgOrigin` mid-timeline with a
  `.call()`.

Three of the four animations in that write-up (flag waver, confetti, gym) are sprite sequences
— 12, 8 and 36 separately illustrated frames. Those cannot be ported, only copied. The walking
one is the only one driven entirely by tweens, so it is the only one that can be *rebuilt*
rather than traced.

The constraint that makes this a decision: the app is dependency-free by
[0002](0002-native-swiftui-zero-dependencies.md), and this is decoration.

## Options considered

### Option A — `WKWebView` running the original SVG and GSAP
- **For:** Byte-identical to the source. Could carry all four animations, sprites included.
- **Against:** A web view and a 70 KB animation library, both inside the app's process, for a
  picture. GSAP would be the first third-party code in the bundle, and the user has to trust it
  on a machine where this app can already run shell commands. It also means a second rendering
  stack to keep in step with the design system's colours and reduced-motion behaviour.
- **Verified against:** the demo's own bundle, `_next/static/chunks/5ce46cbd0cd22c82.js`.

### Option B — Transcribe the timeline into SwiftUI, drawn with `Canvas`
- **For:** No dependency. The geometry is eleven axis-aligned rectangles and six easing
  functions, all of which exist in Foundation. Colours come from the design system, and Reduce
  Motion is a branch rather than a plugin.
- **Against:** Only the tween-driven animation is reachable; the three sprite ones are not. The
  transcription can drift from the source silently, since nothing checks it.
- **Verified against:** the same bundle, transcribed tween for tween into `Design/Mascot.swift`.

### Option C — Record the original to a video or animated image
- **For:** Trivially faithful.
- **Against:** A fixed size, a fixed background, no reduced-motion story, and megabytes in a
  bundle whose entire point is that it is small and legible.
- **Verified against:** unverified assumption about file size.

## Decision

We chose **Option B**.

Because: the animation is 40 numbers and six easing curves, and shipping a browser to play
them back would be the largest dependency in the app, added for the least important thing in it.

Two details of the port are deliberate departures in *implementation* while staying faithful in
*result*:

- **Time is a pure function, not animation state.** Every value GSAP animates here turns out to
  be driven by exactly one tween at a time, so the pose is computed from the clock instead of
  accumulated. That is why the loop closes seamlessly and why there is nothing to fall out of
  sync.
- **Reduce Motion stands the mascot still**, rather than shortening the walk. For a walk cycle
  there is no version of the movement that is safe to keep — the movement is the whole thing.

## Consequences

- **We now must:** keep `Design/Mascot.swift` honest about being a transcription. Its numbers
  have one source, cited in the file; anyone changing them for taste is changing a different
  character, and should say so here.
- **We now must:** keep the mascot cheap when nobody is watching it. This is the consequence
  that changed after the decision was first written: the mascot was placed in an empty state
  precisely because it is driven by a `TimelineView(.animation)` and redraws at the display's
  refresh rate for as long as it is on screen. Kunal asked for it above the message box
  instead, the way Claude Code has it, which makes it permanent rather than rare. The cost is
  paid down by pausing the timeline whenever Bot-Harness is not the front app, which is
  possible only because the pose is computed from the clock rather than accumulated — the
  animation resumes on the correct frame with no seam. What remains is a small continuous
  redraw while the app is in front, which is the price of the placement.
- **We can no longer:** use the flag-waving, confetti or gym animations without illustrating
  their 56 sprite frames by hand. This decision closes that door for as long as it stands.
- **We will know this was wrong if:** the mascot shows up in a profile as a measurable share of
  idle CPU, or if a second animation is wanted and the sprite frames turn out to be the cheaper
  path after all — at which point the web view is worth re-costing.

## Revisit when

Someone wants a second mascot animation, or the walking one shows up in an energy or GPU
profile as a measurable share of the app's idle cost while it is in front.
