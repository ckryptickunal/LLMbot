---
id: 0011
title: Credential existence checks never touch the keychain ACL
status: accepted
date: 2026-08-30
deciders: [Kunal, Claude]
tags: [credentials, permissions, keychain]
supersedes: []
superseded_by: []
---

# 0011. Credential existence checks never touch the keychain ACL

## Context

The app asked for the login keychain password repeatedly — on eval runs, and in the app
itself. The user's report was "every time it runs."

Two things combined to cause it.

**The existence check was secretly a data read.** `Keychain.has()` queried with
`kSecReturnData: false` and no other return key. That reads as "do not give me the data",
but it is not an attribute query — it is a query with *no return type specified*, and the
Security framework falls back to fetching data. Fetching data evaluates the item's ACL, and
an ACL evaluation against an untrusted caller is a password dialog.

This mattered because of where `has()` is called. `Composer.swift:182` holds it in a SwiftUI
computed property, so it re-ran on every body evaluation — every keystroke in the message
box. `Evals/main.swift:167` ran it as a precondition before doing any work at all, which is
the dialog in the user's screenshot.

**The dialog could never be dismissed permanently.** Verified with `codesign -dvv`:

- `.build/debug/Evals` — `Signature=adhoc`, `TeamIdentifier=not set`,
  `Identifier=Evals-55554944518c46d0e8fb31c4874aed64d1bfbbaf`
- `build/BotHarness.app` — `Authority=Apple Development: … (PNJ8A4A6JP)`,
  `TeamIdentifier=233YWRXL6V`

An ad-hoc signature's designated requirement contains a per-build hash, so "Always Allow"
records a grant for a binary that ceases to exist at the next `swift build`. This is the same
mechanism ADR 0003 documents for Screen Recording and Accessibility, arriving from a
different direction: there, ad-hoc signing revoked TCC grants; here, it revokes a keychain
grant. The signed app does not have this problem — its requirement is stable across rebuilds.

The item itself was created by `scripts/set-key.sh` via `security add-generic-password` with
neither `-A` nor `-T` (`cdat` 20260829161141Z, `crtr` NULL). **Assumption, not verified:** its
ACL therefore trusts only `/usr/bin/security`. Reading the ACL to confirm requires the login
keychain password, which an agent must not handle.

## Options considered

### Option A — Store keys in a 0600 file instead of the Keychain
- **For:** No ACLs, no dialogs, ever. Trivially fixes the complaint.
- **Against:** Any process running as the user reads the key with no audit trail and no
  prompt, on a machine whose whole premise (ADR 0001) is that agents run real commands on it.
  Trades a bug for a permanent downgrade.
- **Verified against:** `Sources/BotHarnessCore/System/Keychain.swift` doc comment — "the
  model never sees a secret" is a stated invariant; a readable file weakens it.

### Option B — Create the item with `-A` (any application may read, no warning)
- **For:** One-line change to `set-key.sh`, silences everything.
- **Against:** Same objection as A with extra steps — silent read access for every process,
  including the ones this app is designed to supervise.
- **Verified against:** `man security`, `-A` — "insecure, not recommended!"

### Option C — Make the existence check an attribute query, and cache reads per process
- **For:** Removes the dialog because the ACL is never consulted, not because the ACL was
  weakened. Data reads still authorise, exactly once per process.
- **Against:** Does not help an unsigned CLI that genuinely needs the key's *value*; that
  path still authorises once per launch.
- **Verified against:** ad-hoc-signed probe, `kSecReturnAttributes: true` +
  `kSecReturnData: false` against `app.botharness.keys`/`gemini` → `errSecSuccess`, no data
  blob, no dialog, exit 0. Same probe shape against a throwaway item created the way
  `set-key.sh` creates them: identical result.

## Decision

We chose **Option C**.

Because: the prompts were a bug in how we asked, not a cost of storing keys securely — so
the fix should delete the question, not weaken the answer.

## Consequences

- **We now must:** keep `has()` an attribute-only query. Anyone "simplifying" it back to
  `kSecReturnData: false` alone reintroduces a password dialog on every keystroke, and the
  symptom appears far from the change. The doc comment on `has()` says so at the call site.
- **We now must:** treat the app's own Settings pane as the supported way to store a key. An
  item written by `SecItemAdd` from inside the signed app is owned by that app and never
  prompts it; an item written by `/usr/bin/security` makes the app a stranger to its own
  credential. `set-key.sh` now passes `-T` for the signed bundle and says this in its header.
- **We can no longer:** read a key value from an ad-hoc-signed helper without one
  authorisation per launch. `Evals` is the only such caller, and it no longer reads values —
  it only checks existence.
- **We will know this was wrong if:** a password dialog appears during ordinary use of the
  signed app after the key has been stored through Settings once. That would mean the
  designated requirement is not stable across rebuilds after all, and ADR 0003's reasoning
  needs re-examining too.

## Revisit when

The app gains a second credential consumer that is not the main bundle — a login item, an
XPC helper, or a shipped CLI. At that point the trusted-application list stops being "one
signed app" and a keychain access group with a shared entitlement becomes the cheaper shape.
