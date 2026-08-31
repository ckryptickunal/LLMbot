# Giving a bot its own computer

> Prompted by LangChain's "Give your AI agent its own computer" (langchain.com/blog, read
> 2026-08-31), which is a pitch for LangSmith Sandboxes: hosted, hardware-virtualised microVMs
> with a Python SDK, snapshots, pre-warmed "blueprints", and an auth proxy that injects
> credentials without letting the agent see them. The pitch is sound; the product is someone
> else's cloud. This note is what "its own computer" should mean for *this* app, checked
> against what is already verified in `sandboxing-and-safety.md` (2026-08-29) and against this
> machine on 2026-08-31.

## The phrase hides two different needs

**1. A place to execute without consequences.** Shell, files, packages, network — isolated so
a mistake (or a prompt-injected command) cannot touch the real Mac. This is what the LangChain
post is selling. It needs no screen.

**2. A screen of its own.** A desktop the bot can look at, click, and type into that is not
*your* desktop — so computer-use stops meaning "the bot moves my real mouse while I watch".
This is what Grok Bot ships (one cloud Linux VM per account, viewed over noVNC — see
`grokbot-mechanics.md`), and it is the half the sandbox vendors mostly skip. E2B is the
exception: `e2b-dev/desktop` is an Ubuntu 22.04 + XFCE sandbox with VNC streaming, built
exactly for this.

Bot-Harness already reserves the concept: `EnvironmentKind.container` exists in the model
("A disposable container. Cannot touch anything that matters"), the Computers tab shows it as
"Soon", and every tool call is stamped with the environment in the trace. Nothing routes on it
yet, and `ShellExecutor`'s own comment says plainly: "What this is not: a sandbox."

## Constraints that decide this (verified today)

- macOS 26.5.2, Apple silicon — both requirements for `apple/container` are met. It is **not
  installed** (`container`, `docker`, `limactl`, `orb` all absent).
- **6.5 GiB free disk** (`df -h /`, 2026-08-31 — CLAUDE.md's "1.4 GB" is stale). Enough for
  small Linux images; hostile territory for a 3–4 GB desktop VM image.
- ADR 0002: no package dependencies. A *CLI the user installs* is the accepted pattern — the
  app already shells out to the Claude Code CLI it finds on disk.
- The product's stated identity is the local-first answer to Grok Bot. A mandatory cloud VM
  would dissolve the reason the app exists; an *optional* one is just honest choice.

## The four ways, ranked for this app

### A. Seatbelt around every shell command — isolation, not yet a computer
`/usr/bin/sandbox-exec` with a generated profile, verified working on this exact OS build in
the existing research (deny-default, writable roots from the workspace, network denied unless
allowed; Claude Code and Codex both ship this despite the DEPRECATED man page). Zero disk,
zero install, pure Swift `Process` work. This is not "its own computer" — it is the floor that
makes *this Mac* survivable as the default environment, and the research already marked it the
v1 recommendation. It is still unbuilt.

### B. `apple/container` — its own computer, headless. **The recommended v1 of "Container".**
One lightweight Linux VM per container, Apple-signed `.pkg`, Apache-2.0, macOS 26 + Apple
silicon only. The bot gets a real filesystem, package manager, and network identity of its own;
`shell.exec` and `files.*` route into `container exec` / bind mounts while the browser and
computer tools stay host-side or disabled. Alpine/Debian images are 10–250 MB — fits the disk.
Install is a user action (signed pkg, admin password), discovered at a fixed path the way the
Claude CLI is — no package dependency, but it needs an ADR because it adds a trusted binary.
Caveat the research flagged and the release notes confirm: 1.3.1 (2026-08-29) patched six
advisories including host-file reads — treat it as isolation for *accidents* now, not yet as a
boundary against *malice*, and say exactly that in the UI copy.

### C. Virtualization.framework — its own computer *with a screen*, fully local
The only zero-dependency path to a desktop the bot owns: `VZVirtualMachine` is a system
framework, Linux guests get graphics, and the app could screenshot and inject input into the
guest instead of the real Mac — Grok Bot's architecture with the VM moved onto your hardware.
Honest costs: a desktop Linux image is 2–4 GB (**disk is the blocker on this machine today**),
RAM per VM, and the largest engineering lift of the four (guest tooling for input injection,
screenshot, file exchange). This is the destination, not the next step.

### D. A cloud desktop — E2B Desktop / Daytona / LangSmith Sandboxes
Real today: E2B's desktop sandbox streams VNC and exposes mouse/keyboard/screen APIs; Daytona
sells sub-90 ms sandbox creation; LangSmith adds snapshots, blueprints, and the auth-proxy
idea. Zero local disk, no TCC prompts, and destroying the machine is a feature. It is also
exactly the design this product defines itself against — so if it ever ships, it ships as an
explicit opt-in environment ("Cloud desktop — their computer, not yours"), keyed from the
credential file, never the default. Not v1.

## Recommendation

Stage it along ADR 0007 (cheapest surface first), reusing the seam that already exists
(`bot.environment` → executor routing):

1. **Build A now.** It is the standing gap between the permission model and reality, costs
   nothing, and the profile-generation pattern is already written up with a working example.
2. **Build B as what "Container" means.** Detect `/usr/local/bin/container`; when absent, the
   Computers tab explains the one-time signed-pkg install instead of saying "Soon". Route
   shell/files through it per-bot; keep computer-use honestly labelled as host-only. One ADR
   covering the trusted-binary decision and the 1.3.1-era security posture.
3. **Defer C until disk stops being the constraint** (it is the falsifier to watch: >10 GB
   free and a user asking for computer-use isolation makes C current). Defer D unless demand
   for zero-setup outweighs the identity cost; if built, opt-in only.

Worth stealing from LangSmith's design regardless of provider: **snapshot/fork before risky
steps** (container commit gives this nearly free), **blueprints** (pre-pulled images per bot
so first run isn't a 200 MB download), and the **auth proxy stance** — credentials injected at
the boundary, never visible to the agent, which is already this app's rule for keys.

## Sources

- langchain.com/blog/give-your-ai-agent-its-own-computer (read 2026-08-31)
- `docs/research/sandboxing-and-safety.md` — Seatbelt verified on this machine; apple/container
  1.3.1 facts and advisories (verified 2026-08-29)
- `docs/research/grokbot-mechanics.md` — Grok Bot's one-VM-per-account + noVNC architecture
- github.com/e2b-dev/desktop; e2b.dev/docs/use-cases/computer-use (search-verified 2026-08-31)
- Local checks 2026-08-31: `sw_vers` 26.5.2; `df -h /` 6.5 GiB free; `container`/`docker`
  absent; `grep` shows no sandbox code in `Sources/` and no routing on `EnvironmentKind`.
