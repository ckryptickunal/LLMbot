---
id: 0021
title: A bot can have its own Linux computer, and the Mac stays the default
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [sandbox, runtime, product]
supersedes: []
superseded_by: []
---

# 0021. A bot can have its own Linux computer, and the Mac stays the default

## Context

Everything a bot does today happens on the user's real Mac — that is
[ADR 0001](0001-run-on-the-users-real-mac.md), and it is why the product is worth using: the
browser is already logged in, the files are the real files. It is also why a mistake is expensive.
There is no snapshot to roll back to.

[ADR 0020](0020-shell-commands-run-inside-seatbelt.md) confines shell commands with the kernel, so
a bot cannot write outside its workspace. That bounds the damage; it does not give a bot a place
where it can install packages, break a toolchain, or run a long build without any of it touching
the user's machine. Those are ordinary things to want, and on the Mac they are exactly the things
a sandbox has to refuse.

`apple/container` runs one lightweight Linux VM per container on Apple silicon. Installing it is a
signed `.pkg` into `/usr/local`.

What was verified on this machine, 2026-08-31:

- **`container` is not installed** — `/usr/local/bin/container` does not exist. Everything below
  about the live path is therefore **specification, not observation**.
- **3.3 GB free** on the boot volume. A Debian slim image plus a VM is a real fraction of that,
  which is why the runtime checks free space *before* pulling rather than failing partway.
- The not-installed path is executed by tests: `availability()` returns `.notInstalled`, and
  `prepare` throws rather than hanging (`ContainerRuntimeTests`).

## Options considered

### Option A — Mac only, as today
- **For:** One execution surface; nothing new to install or explain.
- **Against:** No safe place for destructive or dependency-heavy work. The sandbox has to say no
  to things the user would happily allow if they were not on their own disk.
- **Verified against:** ADR 0001, `docs/PRODUCT.md`.

### Option B — Container only
- **For:** One surface again, and a much stronger boundary.
- **Against:** Throws away the reason the product exists. A Linux VM has no logged-in browser, no
  Mac apps, no Screen Recording, no user's files.
- **Verified against:** `docs/PRODUCT.md`.

### Option C — Per-bot choice, Mac by default
- **For:** Each bot gets the surface its work needs. A bot that drives Safari stays on the Mac; a
  bot that builds things gets a machine it can break.
- **Against:** Two execution paths to keep correct, two sets of failure modes, and a tool the user
  may not have installed.
- **Verified against:** implemented in `ContainerRuntime` + `AgentLoop.runShell`.

## Decision

We chose **C**, and the Mac is the default.

Because: the two surfaces are good at opposite things, and which one is right is a property of the
individual bot rather than of the app.

The constraint that shaped the implementation more than any other: **it has to work with and
without the VM.** A stock Mac has no `container`, and that is not a degraded state to apologise
for — it is the normal one. So:

- `availability()` distinguishes not-installed, service-stopped and failing, because the user's
  next action differs for each: install, press a button, or reinstall.
- A run configured for a container on a Mac without one **falls back to the Seatbelt-confined host
  shell** and says so once, naming the reason, rather than failing the run.
- The Computers tab shows the real state and never offers a control that cannot work.
- Nothing starts the VM service at launch. A VM spinning up behind an app the user just opened is
  a surprise, and it may want a password.

What a container is and is not:

- **Is:** isolation for accidents. `rm -rf /` inside it destroys a Debian image, not a Mac.
  Dependencies, toolchains and long builds stay off the user's disk.
- **Is not:** a boundary against a genuinely hostile program. It is a VM with the bot's workspace
  bind-mounted read-write, and **guest network egress is unfiltered** — anything running inside
  can reach the internet regardless of what the bot was granted. Treat it as a clean room, not a
  cell. The UI must not claim more.
- **Never receives host secrets.** The runtime builds the guest environment from scratch (`PATH`
  and `HOME` only) rather than inheriting the app's, so nothing from `CredentialStore` can reach
  it. Guest output stays wrapped as untrusted content on the way back.
- **Only the workspace is mounted.** `isShareable` refuses `/`, `$HOME` and the other paths that
  would turn a share into handing over the machine.

Screen, browser and macOS-app tools are refused inside a container rather than silently doing
nothing: there is no screen in there, and a bot that believes it took a screenshot is worse than
one that was told it cannot.

## Consequences

- **We now must:** keep both paths working, and keep the fallback honest — the trace records the
  computer a step actually ran on (`mac`, `mac (sandboxed)`, `container:<name>`), never the one
  the bot was configured for. Shell effects are keyed by computer in the ledger, because a build
  that happened in a container has not happened on the Mac.
- **We can no longer:** assume a bot's filesystem is the Mac's filesystem, or that a path in a
  trace refers to a path a user can open.
- **We will know this was wrong if:** the live tests fail once someone installs `container`; if
  users routinely turn it on and then hit the headless refusals, meaning the choice is offered at
  the wrong granularity; or if VM start-up latency makes a container-backed bot feel broken.

## Revisit when

Someone installs `apple/container` on a development machine — **run `ContainerLiveTests` first**;
the live path has never been executed. Also revisit if free disk space stops being a real
constraint, since the pull-before-check ordering exists mostly because of it.
