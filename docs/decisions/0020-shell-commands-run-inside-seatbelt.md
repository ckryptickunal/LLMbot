---
id: 0020
title: Shell commands run inside a kernel sandbox, not only past a matcher
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [permissions, security, shell, sandbox]
supersedes: []
superseded_by: []
---

# 0020. Shell commands run inside a kernel sandbox, not only past a matcher

## Context

[ADR 0014](0014-the-shell-honours-the-contract.md) closed the three doors where the permission
contract was not being applied, and made one matcher decide every path question. That work was
necessary and it holds. It also has a ceiling that no amount of further care removes: it reads
commands as **text**.

`ShellExecutor.refusal(for:cwd:)` says so in its own doc comment. A path the model never writes
down cannot be matched:

```sh
P=$HOME; cat "$P/.ssh/id_rsa"
```

The parser sees `cat "$P/.ssh/id_rsa"`. There is no rule that makes `$P` resolvable without
executing the shell, and executing the shell to find out is the thing the check exists to gate.
The same hole covers anything an interpreter opens after it starts — `python3 -c`, a `Makefile`, a
`node` script, a `git` hook — none of which appear in the command line at all.

Verified on this machine, macOS 26.5.2 on Apple Silicon:

- `sandbox-exec` exists at `/usr/bin/sandbox-exec` and enforces a deny-default profile. A write
  outside the allowed subpath fails with `Operation not permitted`; the file is not created.
- The denial applies to a path assembled at runtime, which is the case the matcher cannot see
  (`SeatbeltTests.testAPathAssembledAtRuntimeIsStillDenied`).
- In SBPL the **last matching rule wins**. A carve-out written before the allows is silently
  ineffective and reads identically in a diff
  (`SeatbeltTests.testACarveOutInsideAWritableRootStaysReadOnly` proves the order by executing it).
- `man sandbox-exec` marks it **DEPRECATED**, and has for years. It is nonetheless what Claude
  Code and Codex CLI both ship for their macOS sandboxes.

## Options considered

### Option A — Keep improving the matcher
- **For:** No new mechanism; no dependency on a deprecated tool; failures are legible.
- **Against:** Cannot close the class. Every improvement is another special case, and the
  `$P` example above stays open under all of them.
- **Verified against:** `Sources/BotHarnessCore/Tools/ShellExecutor.swift`, ADR 0014.

### Option B — Run every command under a Seatbelt profile
- **For:** The kernel enforces it, so spelling, assembly and interpreters are all irrelevant.
  Costs one `exec` of a system binary; no dependency to add.
- **Against:** Deprecated with no compatibility commitment. A profile that is wrong in the
  permissive direction fails silently — it looks like it is working.
- **Verified against:** the four behaviours listed above, each executed, each with a test.

### Option C — Refuse to run shell commands at all unless a container exists
- **For:** One boundary instead of two.
- **Against:** Makes the product useless on a stock Mac, which is the machine it is for. The
  whole point of this app is that a bot uses *your* computer.
- **Verified against:** `docs/PRODUCT.md`.

## Decision

We chose **B**, with the matcher from 0014 kept in front of it.

Because: the matcher decides *whether a command should be attempted* and can explain itself to
the user in a sentence; the kernel decides *what it can touch* and cannot be talked around. They
answer different questions, and dropping either one loses something the other never provided.

Details that are load-bearing rather than incidental:

- `/usr/bin/sandbox-exec` is **hardcoded**, never resolved from `PATH`. A sandbox you locate by
  asking the environment is one the environment can replace with `/bin/true`.
- Writes and the network are confined; **reads are not**. A read-deny profile that is even
  slightly wrong stops `python3` loading its own standard library, which presents as a broken app
  rather than as a boundary holding — and reads are already gated by the matcher before anything
  runs.
- Every path in a profile is resolved with `realpath(3)`, **not** `URL.resolvingSymlinksInPath()`.
  Foundation's version strips a leading `/private` as a documented convenience; the kernel
  canonicalises the other way. A profile built from Foundation's answer denies every write into a
  workspace under `/tmp` or `/var/folders` while looking correct.
- `Seatbelt.selfTest()` runs once per launch and proves a known-denied write is actually denied.
  A `false` result never disables the shell — refusing to work is worse than working with a stated
  limitation. What must not happen is the app claiming a boundary that is not there, so the run
  records `mac (unconfined)` and says so.

## Consequences

- **We now must:** keep the carve-out denies last in the profile; keep every use of
  `sandbox-exec` behind `Seatbelt`; treat a red `selfTest()` as a release blocker for the claim,
  not for the feature; never auto-retry a sandbox denial without the profile, since that would
  turn the boundary into a speed bump.
- **We can no longer:** promise that a bot's shell can write outside its workspace even when the
  user would want it to — a grant has to go through `Authority`, which is the point.
- **We will know this was wrong if:** `Seatbelt.selfTest()` starts returning false on a supported
  macOS version, or users hit denials for work that is genuinely inside their grant often enough
  that the profile has to be widened past the point where it means anything.

## Revisit when

Apple removes `sandbox-exec`, or ships a supported replacement for unprivileged per-process
sandboxing. Also revisit if a bot's own computer (ADR 0021) becomes the default rather than the
option, since two boundaries maintained for one job is one too many.
