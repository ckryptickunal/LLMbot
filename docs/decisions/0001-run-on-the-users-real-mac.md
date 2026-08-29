---
id: 0001
title: Bots run on the user's real Mac, not in a cloud VM
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [product, architecture, safety]
supersedes: []
superseded_by: []
---

# 0001. Bots run on the user's real Mac, not in a cloud VM

## Context

Grok Bot — the product this one answers — gives every bot a **remote desktop**. Verified by
inspecting the installed bundle: `com.anysphere.sand` v0.30.0 ships stock Electron helpers
(GPU, Plugin, Renderer) plus Squirrel, Mantle and ReactiveObjC, and **no native computer-use
helper of any kind**. Combined with the "Starting desktop" progress bar, the per-bot
"*Bot*'s screen" caption, the offline banner and a weekly usage meter, its computers are
plainly cloud VMs. See `docs/research/grok-bot-teardown.md`.

That design is safe. It is also disconnected: those desktops hold none of the user's files, no
signed-in browser sessions, no repositories, and are capped by a weekly limit set by the vendor.

The user's four stated acceptance tasks — work on a real repo, research to an artifact, drive
Mac apps, and operate existing projects on a schedule — are **all impossible** in that model.
Every one requires the user's actual machine.

Anthropic's own computer-use reference explicitly discourages running outside a VM. We are
choosing to disregard that guidance knowingly, and to pay for it in engineering.

## Options considered

### Option A — Cloud or local VM per bot
- **For:** Blast radius is bounded. A ruined machine is discarded and re-imaged. Snapshot and
  rollback are available, which is the single largest safety mechanism in the reference product.
- **Against:** None of the user's real work is reachable. Virtualising macOS on Apple Silicon is
  additionally constrained to 2 guest VMs by Apple's licence terms. Disk on this machine is at
  **1.4 GB free**, so no image fits today anyway.
- **Verified against:** `docs/research/controlling-a-real-mac.md`, `df -h`

### Option B — The user's real Mac, gated by permissions
- **For:** Everything the user actually wants becomes possible. Real files, real logged-in
  Chrome, real repos, real apps.
- **Against:** There is no undo. No snapshot, no rollback, no re-image. The approval gate has to
  carry all the safety weight that a disposable VM carries for the reference product, which
  means it must be *stricter* than theirs, not equally strict.
- **Verified against:** `ScreenCaptureKit`, `CGEventSource` and `AXIsProcessTrusted` all confirmed
  available on this machine — `docs/guides/ENVIRONMENT.md`

### Option C — Both, behind one abstraction
- **For:** Per-bot choice; a research bot in a container, a coding bot on the Mac.
- **Against:** Two executors to build and keep correct, when only one of them is wanted today.

## Decision

We chose **Option B, structured as Option C**: the real Mac is the only environment implemented
now, but every tool is written against an `EnvironmentKind` abstraction so a container can be
added without rewriting the tool layer.

Because: a bot that cannot touch the user's actual work is not a smaller version of this
product — it is a different product, and it is the one that already exists.

## Consequences

- **We now must:** treat the permission system as the primary engineering artifact, not a
  feature. It gets the most care, the most tests, and the most scrutiny in review.
- **We now must:** hold Screen Recording and Accessibility, which are the two most invasive
  permissions macOS grants. That obliges us to a stable code signature (see ADR 0003) and to
  never asking for more than is needed.
- **We can no longer:** offer "just reset it" as a recovery path. Recovery has to be prevention.
- **We can no longer:** honestly describe this as safe-by-isolation. The README says so plainly.

## Revisit when

Either of these:
- A run causes real damage that a container would have prevented. That is the signal to make
  `container` the default for new bots rather than an option.
- Apple ships a per-app sandbox that can confine GUI automation. Seatbelt confines shell
  processes but has no reach into synthesized input or screen capture, which is exactly the
  surface we most want confined.
