---
id: 0013
title: Settle work whose process is gone, at launch and at stop
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [state, safety, ux]
supersedes: []
superseded_by: []
---

# 0013. Settle work whose process is gone

## Context

Nothing in this app resumes a run across a launch. A run is a `Task` holding an `AgentLoop`;
when the process ends, both end. But the *record* of that run persists, and the record was
written as though the work were still happening:

- A tool card kept its `running` status, so a transcript reopened a day later showed an amber
  "Running" pill for a process that had not existed since yesterday.
- A Computer card kept `awaitingHuman`, saying "Waiting for you — this needs a person" about a
  machine nobody was driving.
- An approval card kept its three enabled buttons. Pressing one called `BotRunner.answer`,
  which begins `guard let loop = loops[conversationID] else { return }` — so the click did
  nothing at all: no state change, no message, no explanation. The card could never be answered
  and never be dismissed.

All three were observed in the UX audit (`docs/UX-AUDIT-2026-08-31.md`, items 1.4 and 2.13).
The common shape is the worst one an interface can have: **it asserts something is true that
the code cannot back**, and it does so in the surface whose entire purpose is being an honest
record of what the agent did.

The same hole existed at `stop()`, which cancelled the task but corrected none of the record,
and left the `awaiting` map populated so the composer's mascot kept asking for an answer that
could no longer be given.

## Options considered

### Option A — resume runs across a launch
- **For:** the record would be true, because the work really would still be happening.
- **Against:** an agent that silently continues shell commands and computer control when the
  app reopens is the opposite of what [0004](0004-two-layer-permission-model.md) is for. An
  approval granted before a crash is consent for an action in a context that no longer exists.
- **Verified against:** `BotRunner.send`, which builds the loop, brain, trace and contract per
  message; none of it is persisted.

### Option B — hide open work when it cannot be live
- **For:** trivial; nothing on screen would be false.
- **Against:** deletes the record. A tool that started and never reported is the single most
  interesting thing in a failed run, and this is an app whose stated identity is that the
  record survives.

### Option C — record the interruption as a state of its own
- **For:** keeps the history, and the history becomes more informative rather than less: "this
  started and nobody knows how it ended" is a fact worth having.
- **Against:** adds cases to two persisted enums.

## Decision

We chose **Option C**, in two places, with one rule: **"unknown outcome" is a value, not a
gap.** `ToolActivity.Status.interrupted` and `ApprovalRequest.Answer.expired` both exist so the
absence of a result has somewhere to live other than a stale `running`.

- `Store.reconcileInterruptedWork()` runs once inside `load()`, before any view can render, so
  no frame is ever drawn containing a false claim.
- `BotRunner.settleOpenWork(in:)` does the same at `stop()`, and `answer()` calls it when the
  loop is gone — so an approval card resolves even when the thing that asked is not there.

Two schema notes, both deliberate:

- **Both additions are enum cases, not new keys.** A new non-optional key breaks decoding of
  every state file written before it, and this app's response to a decode failure is to set the
  document aside and re-seed — which presents to the user as total data loss. A new case is
  invisible to old documents and to old builds reading nothing.
- **`Conversation.lastReadAt` is `Optional`** for the same reason. It is also honest: a
  conversation nobody has opened is a real state, not a missing value.

`interrupted` is deliberately not `failed`. A failure is a result; this is the absence of one,
and the card says so in words rather than leaving the user to infer it from a grey pill.

## Consequences

- **We now must:** settle open work anywhere else a run can end. There are three paths today —
  launch, stop, and answering into a dead loop — and any fourth must call the same function.
- **We now must:** keep every future persisted field optional or defaulted, and keep new states
  as enum cases, for as long as a decode failure re-seeds. If that response ever becomes a
  proper migration, this constraint can relax.
- **We can no longer:** treat `status == .running` as "a process is doing this". It means "the
  last thing we knew". Anything wanting liveness must ask `BotRunner.isRunning`.
- **We will know this was wrong if:** users report losing the ability to answer an approval
  they meant to answer — that is, if expiry is firing on runs that were actually still alive.
  That would mean the reconciliation is running somewhere it should not.

## Revisit when

Runs become resumable across launches, at which point interrupted work has a fourth possible
ending — "picked up again" — and expiry becomes wrong rather than merely conservative.
