---
id: 0017
title: The trace chain is keyed, and the key lives beside the API keys
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [trace, security, tamper-evidence]
supersedes: []
superseded_by: []
---

# 0017. The trace chain is keyed, and the key lives beside the API keys

## Context

The trace was described as tamper-evident. It was not.

`append()` chained records with a bare SHA-256 over canonical JSON, and `verifyChain` re-derived
every hash with the identical public algorithm and no secret. That detects a truncated file and a
careless edit. It does not detect a deliberate one: anything able to rewrite `steps.jsonl` could
recompute every hash after the edit and hand back a file that verifies perfectly.

The adversary that matters here is the bot itself. Traces live under Application Support, and a
bot with `shell.exec` could reach them — so the record of what a bot did was editable by that bot,
and the app presented the result in green as "N records intact".

Two other gaps sat alongside it: `run.json` was written with no redaction at all, though it
carries the user's own message as `goal`, and the trace write path applied only the regex redactor,
never the value-seeded one — so a secret with no recognisable shape (a database URL with a
password, a bearer token) reached disk in cleartext.

## Options considered

### Option A — Sign the chain with a key in the macOS Keychain
- **For:** The strongest store on the machine; designed for exactly this.
- **Against:** ADR 0012 moved the API keys *off* the keychain because a grant binds to a code
  signature and dies on rebuild, so every launch asked for the login password. The eval binary and
  the test bundle are signed differently again, so a keychain-backed chain key would make
  `swift test` prompt or fail. A tamper-evidence scheme that cannot run in the test suite is one
  nobody can prove still works in six months.
- **Verified against:** `docs/decisions/0012`, `docs/decisions/0011`.

### Option B — Keep the key in its own file next to the traces
- **For:** Simple, no coupling to the credential store.
- **Against:** A sibling file is on no deny list, so the bot can read it — and a chain key the bot
  can read is one it can re-sign with, which is exactly the position being left.
- **Verified against:** `Authority.alwaysDenied` covers `credentials.json` and nothing else under
  Application Support.

### Option C — Keep the key inside `credentials.json` under a reserved account
- **For:** That file is the only path under Application Support on the permanent read-deny list.
  A bot cannot `cat` it, cannot open it with the file tool, and cannot carry it out inside a
  `cp -r` of the containing directory (ADR 0014 added container matching for bulk commands).
- **Against:** Puts a non-credential in the credential file, and creates that file for a user who
  has set no API key at all.
- **Verified against:** `TraceChainKey.swift`; `PathGuardTests`.

## Decision

We chose **Option C**. Records are chained with `HMAC<SHA256>` and `run.json` carries a seal over
its own contents.

Because: the key has to be somewhere the bot cannot read, and there is exactly one such place on
this machine that does not reintroduce the password prompts ADR 0012 was written to remove.

**What this does not do, stated plainly:** an attacker who can read the credential file can edit
any record, re-sign the whole chain, and leave a file that verifies clean. The HMAC raises the bar
from "any process that can write the traces directory" to "any process that can also read the
credential file" — the same bar that protects the API keys. If that bar falls, the keys are
already gone and a forged trace is not the worst outcome. The bar it genuinely raises is against
the bot, which is the adversary the trace exists to keep honest.

Verification distinguishes three states rather than two, and the UI now says which: `signed`,
`writtenBeforeSigning` (an older trace, unaltered but only weakly so), and `keyUnavailable`. An old
trace is never reported as tampered, and — equally important — is never reported as plain "intact"
in green, because that would tell the user the record is evidence when it is not.

## Consequences

- **We now must:** treat the credential file as the root of trust for two separate things. Losing
  it loses the ability to verify past traces as well as the API keys.
- **We now must:** accept that `credentials.json` exists on a fresh install even with no API key
  set, holding one entry named `trace.chain-hmac`.
- **We can no longer:** verify a trace on a different machine. That is the intended trade — a
  portable proof needs a signature anyone can check, which means asymmetric keys and a distribution
  story neither of which this product has.
- **We will know this was wrong if:** a user needs to hand a trace to someone else as evidence, or
  if restoring a backup loses the key and makes every prior trace unverifiable — the file is now
  excluded from Time Machine, which makes the second case *more* likely, not less.

## Revisit when

Traces need to leave the machine — shared with a colleague, attached to a bug report, or checked by
anything other than this app on this Mac. That requires a signing key with a public half, and it is
a different design rather than a parameter change.
