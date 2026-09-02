---
id: 0023
title: A dropped file is a permission grant, and only a gesture may make one
status: accepted
date: 2026-09-03
deciders: [Kunal, Claude]
tags: [permissions, files, ui]
supersedes: []
superseded_by: []
---

# 0023. A dropped file is a permission grant, and only a gesture may make one

## Context

Drag-and-drop shipped and did not work, in a way none of its tests could see.

Everything up to the boundary was right: the drop was accepted on both the composer and the
conversation pane, the path was extracted from whichever representation the source registered,
it was quoted if it contained a space, duplicates were dropped, and it landed in the draft.
Then the bot called `files.inspect` and got back *"this bot may only read inside the paths you
gave it"*.

The reason is in `BotRunner.contract(for:bot:conversation:)`: a run may read its workspace and
`~/Desktop`, and nothing else. Almost nothing anyone drags into a window lives in either —
attachments come out of `~/Downloads`, `~/Documents`, a mounted volume, another app's container.
Verified at `Sources/BotHarnessCore/Tools/FileExecutor.swift:40`, where an empty or
non-matching `readable` list throws before anything touches the disk, and again by
`AttachmentTests.testAFileOutsideTheWorkspaceIsUnreadableUntilItIsAttached`, which fails
against the old authority and passes against the new one.

So the user performs the most explicit act of consent the Mac has — picking a file up and
putting it in the window — and the app answers that it has not been given permission.

The constraint that makes this a decision rather than an obvious fix: this widens what a bot
may read, and the permission system is the spine of the product. Anything that widens it has to
be narrow, visible, revocable, and impossible for the model to trigger.

## Options considered

### Option A — Widen the default readable list
Add `~/Downloads` and `~/Documents` to every run's authority.
- **For:** one line; fixes the symptom immediately.
- **Against:** grants every bot standing read access to the user's documents whether or not
  anything was ever attached. The grant is invisible, permanent, and unrelated to any act the
  user took. It fails all four requirements above.
- **Verified against:** `Sources/BotHarness/UI/BotRunner.swift:481` (the list this would edit).

### Option B — Derive grants from the message text
Scan the draft for things that look like paths and grant those.
- **For:** no new state; works for a path someone typed as well as one they dropped.
- **Against:** the model writes into the conversation too. A reply containing
  `~/.ssh/id_rsa` would be indistinguishable from a path the user dragged in, so the model
  could widen its own authority by writing a sentence. This is the failure mode the whole
  design exists to prevent.
- **Verified against:** `Sources/BotHarnessCore/Runtime/UntrustedContent.swift` — content read
  during a run is already treated as data precisely because it can be authored by an attacker.

### Option C — Grant exactly what the user pointed at, from the gesture only
A drop or the open panel records an `Attachment`; the contract's `readable` list gains that one
path.
- **For:** narrow (one file, not its folder), visible (listed in the bot's settings pane with
  an X beside each), revocable, and reachable only from a physical pointer movement.
- **Against:** more moving parts — a new model type, a persisted field, a shared code path for
  the three ways to attach. Needs the floor re-checked at the drop so the refusal is the app's
  and not the bot's.
- **Verified against:** `Tests/BotHarnessTests/AttachmentTests.swift` — nine cases covering the
  grant, what it refuses, and what it does not widen.

## Decision

We chose **Option C**.

Because: a path the user pointed at and a path the model typed must never travel by the same
road, and that is a property of *where the grant comes from*, not of what it says.

Mechanically that means `Attachment.grant` is called from exactly two places — the drop handler
and the open panel — and nothing anywhere parses a message to produce one. The grant is for the
file itself, never its folder; a folder that is dropped grants its own subtree and nothing
above it. It never touches `writable`: dragging a file in is consent to read it, and a bot that
could overwrite whatever you dropped on it would make the gesture something you have to think
before using.

`Authority.alwaysDenied` is re-checked at the drop, after symlinks are resolved. That check is
redundant for safety — `FileExecutor` would refuse anyway — and it is not redundant for
honesty: without it, dropping a private key looks like it worked and the refusal arrives three
messages later in the bot's voice, phrased as the bot's limitation.

## Consequences

- **We now must:** show attached files somewhere the user will see them without hunting, and
  let them be taken back. They are listed under "Files you attached" in the bot's settings pane,
  directly beneath the workspace, because both answer the same question. Any new stored property
  on `Conversation` must also be added to its hand-written decoder — the omission is silent and
  cost this change one round of the fix (the field encoded correctly and was dropped on every
  load, so grants survived a save and vanished on the next launch).
- **We can no longer:** treat the run's readable list as a constant derived from the bot. It now
  varies per conversation, so anything reasoning about a bot's reach must ask the conversation.
- **We will know this was wrong if:** a user is surprised by what a bot could read, and the
  reason traces back to something they dropped rather than to something they chose; or if the
  cap of 32 attachments per conversation turns out to be reached in ordinary use, which would
  mean people are attaching in bulk and per-file grants are the wrong grain.

## Revisit when

Someone asks to attach a whole folder tree routinely, or when a second surface (a Share
extension, a Finder service, an inbound file from a channel) needs to attach something — at
that point "only a gesture may grant" needs restating for a gesture that happens outside this
app's window.
