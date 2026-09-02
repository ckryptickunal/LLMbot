---
id: 0024
title: Content that gives orders poisons the next turn, not the whole run
status: accepted
date: 2026-09-03
deciders: [Kunal, Claude]
tags: [permissions, prompt-injection]
supersedes: []
superseded_by: []
---

# 0024. Content that gives orders poisons the next turn, not the whole run

## Context

`UntrustedContent.looksLikeInjection` has been in the codebase since the envelope was written,
with a doc comment saying it "flags the action for the permission floor, which refuses anything
whose justification came from read content". Nothing ever called it. Verified by search: the
only reference outside its own declaration was in a test.

What actually set `ProposedAction.originatedFromUntrustedContent` was a single expression in
`AgentLoop.perform` — `action.safety?.isBlocked` — which is Gemini's own injection verdict. So:

- a bot on the Claude CLI brain had no injection check at all, because that adapter has no
  equivalent signal;
- anything Gemini's detector missed had none either;
- and the local heuristic that existed to cover both cases was dead code.

This got worse with `files.extract_text`. Reading a PDF or a Word document now returns whatever
that document says, wrapped as untrusted — and a document is a much easier thing to get in
front of someone than a web page.

The constraint: `PermissionEngine` **refuses** an action of untrusted origin outright, with
`decidedBy: .safetyFloor`, and a floor refusal cannot be overridden by the user. So whatever
scope we give this flag, the run cannot argue its way out of it.

## Options considered

### Option A — Leave it dead
- **For:** the envelope is the real defence, and it is intact; the model is told plainly that
  the content is data.
- **Against:** the envelope is an instruction to the model, and the entire premise of the
  permission model is that instructions to the model are not enforcement. A guard that is
  documented as existing and does not exist is worse than no guard, because it is counted.
- **Verified against:** `Sources/BotHarnessCore/Runtime/PermissionEngine.swift:21`.

### Option B — Sticky for the rest of the run
Once a run reads injection-shaped content, every outward effect for the remainder is refused.
- **For:** strictly safer; no window in which the payload can act.
- **Against:** one document containing "override" and "system message" permanently costs that
  run its ability to commit, push or send, with no override anywhere. `looksLikeInjection` needs
  only two markers, and two markers appear in real documents — including, as it happens, in this
  project's own security notes. A guard that expensive is one people route around.
- **Verified against:** `InjectionProvenanceTests.testScanningTheWholeEnvelopeIsWhatWouldHaveBeenWrong`,
  which shows how easily the marker count reaches two.

### Option C — One turn, outward effects only
The read sets a flag; the flag applies to the actions of the turn that follows; reading is never
gated.
- **For:** covers where the attack actually lands — a payload works by being read and then acted
  on, and the acting is the model's very next move. Costs an ordinary run nothing, because an
  ordinary run's next move after reading a document is to read or write something else.
- **Against:** a patient attack that waits three turns is not caught. Nor is one that persuades
  the model to act much later.
- **Verified against:** `Tests/BotHarnessTests/InjectionProvenanceTests.swift`.

## Decision

We chose **Option C**.

Because: the floor cannot be overridden, so the scope of this flag is the scope of a refusal the
user cannot lift — and a refusal nobody can lift has to be aimed at the moment of the attack
rather than draped over the rest of the session.

Two details that are not obvious and are load-bearing:

**The heuristic runs on the envelope's body, never on the envelope.** The wrapper's own preamble
contains the phrases "a system message" and "an instruction to you". Scanning the whole string
therefore scores a marker for our own warning text and silently halves a deliberately
conservative two-marker threshold to one. `UntrustedContent.body(of:)` exists for this and
nothing else.

**Reading is not an outward effect.** A bot that has just opened a suspicious page must still be
able to look at things, or it cannot investigate what it read and cannot tell the user what is
in it. Only `AgentLoop.isOutwardEffect` actions are gated.

## Consequences

- **We now must:** keep `isOutwardEffect` honest. It is now load-bearing for injection defence
  as well as for the effect ledger, so a tool added to the outward set in one context is added
  to both.
- **We can no longer:** change the envelope's preamble without checking `body(of:)` still finds
  the boundary. A test asserts the preamble scores a marker on its own, which will fail loudly if
  the wording changes in a way that makes `body(of:)` unnecessary.
- **We will know this was wrong if:** a real attack succeeds by waiting a turn — at which point
  the answer is a decaying window rather than a binary one; or if false positives show up in
  ordinary runs, which would mean the marker list needs to be about sentence shape rather than
  substrings, the same way `MemoryGuard` had to be rewritten.

## Revisit when

A second brain adapter starts reporting its own injection verdict, or when the failure log shows
outward actions being refused for this reason in runs that were not under attack.
