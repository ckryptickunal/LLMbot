---
id: 0003
title: Sign with the Apple Development certificate, never ad hoc
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [build, permissions, safety]
---

# 0003. Sign with the Apple Development certificate, never ad hoc

## Context

macOS keys TCC permission grants to an application's **designated requirement**. Bot-Harness
needs exactly two grants — Screen Recording and Accessibility — and without them it does
nothing at all.

An ad-hoc signature (`codesign -s -`) produces a designated requirement derived from the
per-build **cdhash**. Every rebuild therefore presents as a different application and macOS
silently revokes both grants. For an app rebuilt dozens of times a day, that is not a
annoyance; it makes the development loop unusable and, worse, trains the user to click through
permission dialogs without reading them.

An earlier version of `scripts/bundle.sh` used ad-hoc signing, because an earlier reading of
this machine concluded no certificate existed. That reading was wrong.

## Options considered

### Option A — Ad-hoc signing
- **For:** Zero setup, works on any machine, no certificate to expire.
- **Against:** Revokes both required permissions on every rebuild.
- **Verified against:** `codesign -d -r-` on an ad-hoc bundle shows a cdhash-derived requirement.

### Option B — The Apple Development certificate present on this machine
- **For:** The designated requirement is identity-based and contains no hash, so it is stable
  across rebuilds and grants persist.
- **Against:** Tied to one developer account; certificates expire; a second contributor needs
  their own. `spctl` still rejects the bundle, since an Apple Development certificate is not a
  Developer ID.
- **Verified against:** `security find-identity -v -p codesigning` →
  `224FA75C1E159B4B50EE901312F3B38632663F97 "Apple Development: kunalbairwa232@gmail.com (PNJ8A4A6JP)"`

## Decision

We chose **Option B**, with automatic discovery and an ad-hoc fallback that prints a warning.

**Verified empirically, not reasoned:** built twice with a source change between builds. The
cdhash changed between them; the designated requirement was byte-identical:

```
designated => identifier "app.botharness.mac"
              and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: kunalbairwa232@gmail.com (PNJ8A4A6JP)"
              and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

## Consequences

- **We now must:** keep `scripts/bundle.sh` printing the designated requirement on every build,
  so an identity change is visible rather than mysterious.
- **We now must:** handle certificate expiry as a real operational event; when it happens, the
  permissions vanish and the cause will not be obvious.
- **We can no longer:** hand someone the built `.app` and expect it to open. It is signed for
  development, not distribution.
- **`CLAUDE.md` explicitly forbids** "simplifying" the script back to `codesign -s -`.

## Revisit when

The app is ready to be given to anyone else. That needs a Developer ID certificate plus
notarisation, which changes the signing step but not this decision's substance.
