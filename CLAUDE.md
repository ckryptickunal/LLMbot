# Working in this repository

Bot-Harness is a native macOS app where a person keeps a roster of named bots that can use
their real Mac. Read [`docs/PRODUCT.md`](docs/PRODUCT.md) before your first change; it is short
and it is the only thing that explains why the code is shaped this way.

## The one thing to understand first

This app runs shell commands, edits files, drives a logged-in browser, and controls macOS apps
on a real machine that has no snapshot to roll back to. **The permission system is not a
feature of this product; it is its spine.** Every other design choice bends around it.

Practically, when you touch anything in `Sources/BotHarness/Model/Permission.swift`, the tool
layer, or the trace writer, you are working on the safety-critical part of the codebase. Slow
down there. Everywhere else, move.

## Before you write code

- `docs/PRODUCT.md` — the five objects (Bot, Chat, Channel, Plugin, Routine) and what we are
  deliberately not building.
- `docs/guides/ENVIRONMENT.md` — verified toolchain facts. **Check here before concluding that
  a tool is missing.** This document was wrong once because `xcodebuild` errored and the
  conclusion drawn was "Xcode is not installed". It is installed; it is just not selected.
- `docs/research/README.md` — 321 sourced facts across sixteen tracks. If you are about to
  research something, look here first; it has probably already been verified with a URL.
- `docs/decisions/` — why things are the way they are, and what would make each choice wrong.

## House rules

**Verify, do not assume.** This project's research phase found that roughly a third of the
confident claims in its own starting brief were false. When a command errors, read the error
before concluding what it means. When you state a fact in a document, you must have run the
command or fetched the URL that establishes it. Write "assumption" next to things you did not
check.

**Record decisions, not just changes.** Anything that closes a door — a dependency, a schema,
a permission behaviour, a choice between two defensible implementations — gets an ADR in
`docs/decisions/` with a falsifier: what observation would prove this wrong. Copy
`_TEMPLATE.md`. Reversible, obvious choices get a `CHANGELOG.md` line instead, not an ADR.

**Every session that changes a file adds a `CHANGELOG.md` line**, including documentation-only
sessions. Write what changed for the person using the app, not what you typed.

**No new dependencies without an ADR.** The app is deliberately dependency-free: URLSession,
Security, ScreenCaptureKit, CoreGraphics, ApplicationServices and Foundation cover everything
we need. A package is something the user has to trust.

## Build and check

```bash
./scripts/doctor.sh        # verify the machine still has what the docs claim
swift build                # fast type-check loop
./scripts/bundle.sh        # assemble and sign BotHarness.app
open build/BotHarness.app
```

`bundle.sh` signs with the real Apple Development certificate on this machine, not ad-hoc.
That is deliberate and load-bearing: macOS keys Screen Recording and Accessibility grants to
the app's designated requirement, and an ad-hoc signature's requirement contains a per-build
hash, so ad-hoc signing revokes both permissions on every rebuild. **Do not "simplify"
`bundle.sh` back to `codesign -s -`.**

The app is a GUI app; `swift run` gives you a window but launching the signed bundle is what
exercises the real permission identity. To inspect a running window without stealing focus,
capture it by window ID rather than taking a full-screen screenshot — the app is usually not
frontmost and a full-screen grab will silently photograph something else.

## Code conventions

- Swift 6 toolchain, `.swiftLanguageMode(.v5)` — strict concurrency is turned off for view
  code on purpose. The concurrency risk in this project lives in the agent runtime, not the UI.
- `Store` is the single owner of state and the only thing that writes to disk. Views observe;
  the runtime asks and reports. Do not add a second writer.
- On-disk formats are ones a human can read without this app: JSON for state, JSONL for
  traces, PNG for screenshots. If the app is deleted, the record of what it did must survive
  and stay legible. This constrains format choices more than performance does.
- Comments explain *why*, and especially why-not. A comment that restates the next line is
  noise; a comment recording the option that was rejected is the most valuable line in the file.

## Writing for the user

Bot messages in this product are terse, first-person, and carry decisions rather than
reasoning. The tone to match, taken from the product this one answers:

> 28 CaratLane addresses bounced. They were guessed names BCC'd on the marketing@ mail, every
> one "address not found." I won't retry any of them, and I won't BCC guessed names again.

What it did, what it concluded, what rule it is adopting. No narration of thinking, no asking
for permission it already has. Apply the same standard to your own summaries in this repo.

## Traces

Every tool call any agent makes in this repository is appended to
`var/traces/agent-activity.jsonl` by `.claude/hooks/trace.py`, with secrets redacted on the
way in. The app's own runs write richer traces to `~/Library/Application Support/Bot-Harness/traces/`.

`var/` is gitignored and must stay that way. **This repository is public**, and traces contain
real commands, real paths, and real file contents.

## Things that will trip you up

- `xcode-select -p` points at Command Line Tools, so `xcodebuild` errors. Xcode 26.6 is
  installed at `/Applications/Xcode.app`. Use `DEVELOPER_DIR=` to reach it.
- The machine has **1.4 GB free**. Do not casually `brew install`, `pip install`, or pull a
  container image. Check `df -h` first and say something if space is the blocker.
- `ANTHROPIC_API_KEY` and `GEMINI_API_KEY` are both unset in the environment. Keys live in the
  Keychain under service `app.botharness.keys`. Never read a project `.env` to get one.
- Python 3.10 is the default, but 3.11 and `uv` are both installed. The "3.10 ceiling" that
  appears in some early notes is not real.
