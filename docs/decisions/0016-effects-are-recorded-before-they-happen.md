---
id: 0016
title: Effects are recorded before they happen, and "uncertain" is a real answer
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [runtime, idempotency, safety]
supersedes: []
superseded_by: []
---

# 0016. Effects are recorded before they happen, and "uncertain" is a real answer

## Context

The only duplicate suppression in the runtime was `callSignatures`, an in-memory count that dies
with the `AgentLoop`. It covers a model repeating itself inside one run. It does not cover any of
the cases that actually duplicate a side effect:

- A run is stopped, or crashes, after an email is sent but before the model sees the result.
- A tool times out. The effect landed; the answer did not. The model retries, reasonably.
- The app quits mid-run and the user asks for the same thing tomorrow.

This was flagged in the project's own `docs/research/rakazo-teardown.md` and never built.

## Options considered

### Option A — Record success and failure
- **For:** Simple; two states, obvious semantics.
- **Against:** A timeout is neither. Recording it as failure duplicates the effect on retry;
  recording it as success means a genuinely failed action is never retried. Both lies are
  expensive and there is no third option to fall back on.
- **Verified against:** `ShellExecutor` timeout path returning exit 124 with no result.

### Option B — Record success, failure and uncertain, written before the attempt
- **For:** A crash between "beginning" and "finished" leaves `uncertain` rather than nothing,
  which is the honest state and the one that changes what the model should do next.
- **Against:** An extra file, and an advisory the model has to handle rather than a hard refusal.
- **Verified against:** `EffectLedger.swift`; `EffectLedgerTests.swift`.

## Decision

We chose **Option B**.

Because: "we do not know whether that happened" is the actual state of the world after a timeout,
and every scheme that collapses it into yes or no is wrong in one direction or the other.

Keys are **content-addressed** — a SHA-256 over the tool name and canonicalised arguments — so two
attempts to send the same body to the same recipient are one effect even though they are different
calls in different runs. Argument key order cannot make one action look like two.

The advisory is phrased as a fact plus an instruction to verify, never as a refusal. A hard
refusal would strand a run whose first attempt genuinely failed.

**Only outward, irreversible tools are ledgered.** The first version recorded every `shell.exec`,
which meant running `ls` in two consecutive runs got the second refused as "already completed" —
wrong, and exactly the kind of nonsense that makes someone disable a safety feature. Shell
commands are now judged from the parse: a command that writes a path, trips the floor, or invokes
a known-mutating executable is an effect; `ls` and `cat` are not. An unparseable command is treated
as an effect, because a wrong "no" costs a duplicated side effect and a wrong "yes" costs one
advisory message.

## Consequences

- **We now must:** keep `effects.jsonl` legible and bounded. It is append-only with last-write-wins
  semantics on load, and nothing prunes it yet.
- **We now must:** keep the mutating-executable list current. A missing entry means a duplicated
  effect, which is the failure this exists to prevent.
- **We can no longer:** assume a retry is free. A tool that is genuinely idempotent and wants to be
  re-runnable has to be absent from the outward set.
- **We will know this was wrong if:** users see "already completed" on something they deliberately
  wanted to do twice, often enough to be a nuisance — the escape hatch today is that changing any
  argument makes it a different effect, which is discoverable but not obvious.

## Revisit when

A tool exists whose effect is genuinely reversible and frequently repeated on purpose. At that
point the ledger needs a per-tool policy rather than one list.
