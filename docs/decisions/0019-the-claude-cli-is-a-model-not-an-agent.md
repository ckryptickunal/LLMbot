---
id: 0019
title: The claude CLI is used as a model, not as an agent
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [brains, security, permissions]
supersedes: []
superseded_by: []
---

# 0019. The claude CLI is used as a model, not as an agent

## Context

Settings listed Claude Code first, with a green check and the words "Signed in and ready — no API
key needed." `BotRunner.brain(for:)` returned `GeminiAdapter()` for every case. A user whose only
credential was a Claude Code subscription was told they were finished and then got a silent
failure, or a confusing complaint about a Gemini key they had never been asked for.

Fixing it means running the local `claude` binary. That binary is not a model endpoint — it is a
complete agent with a shell, a file editor, a browser, MCP servers, plugins and hooks. Pointing
Bot-Harness at it naively would mean a second agent acting on the user's Mac *underneath* this one,
with none of this app's permission floor, path guard, approval cards or trace applied to anything
it did. The spine of this product is that every action a bot takes passes one boundary. A brain
that can act by itself is not a brain; it is a hole.

## Options considered

### Option A — Let the CLI use its own tools and report what it did
- **For:** Least work; the CLI is good at agentic coding on its own.
- **Against:** Every guarantee this app makes stops being true. Actions would not hit the floor,
  would not raise approval cards, and would not appear in the trace. `docs/PRODUCT.md` describes
  the permission system as the spine; this would cut it.
- **Verified against:** the CLI's startup line lists its own tools, MCP servers and plugins.

### Option B — Use the CLI purely as a text-in/JSON-out model, with every capability disabled
- **For:** The harness keeps ownership of every action. The subscription becomes a brain rather
  than a rival agent.
- **Against:** Relies on the CLI's own flags, which are a moving target across versions. Costs more
  per turn than resuming a session would, and cannot drive the screen.
- **Verified against:** `ClaudeCLIAdapter.swift`; each flag's effect read off the live CLI's own
  startup line on `claude 2.1.238`.

### Option C — Use the Anthropic API instead
- **For:** A plain model endpoint with no agentic surface at all.
- **Against:** Requires an API key, which is exactly what the user does not have and exactly what
  the Settings row promised they would not need.
- **Verified against:** `docs/PRODUCT.md` — running on the user's own accounts is the premise.

## Decision

We chose **Option B**.

Because: a subscription the user already pays for is worth using, and the only version of that
worth shipping is one where the harness still owns every action.

Four flags do the containment, and each was verified against the running binary rather than
assumed:

- `--tools ""` — the CLI reports `tools:["StructuredOutput"]` and nothing else.
- `--strict-mcp-config` — `mcp_servers:[]`.
- `--setting-sources ""` — `plugins:[]`, and no settings files are loaded. This one matters more
  than it looks: a `SessionStart` hook is a shell command, and it would have run on the user's Mac
  entirely outside the harness before the first token was generated.
- `--permission-mode manual` — asks a human, and `--print` has no human, so anything that did
  appear is denied rather than run.

The subprocess also gets a short explicit environment rather than the app's own, so an inherited
`ANTHROPIC_API_KEY` cannot quietly bill a metered API for a brain the user chose *because* Settings
said no key was needed.

## Consequences

- **We now must:** treat a CLI upgrade as a security-relevant event. The containment is the CLI's
  own behaviour, not ours. A test asserts the flags are sent and the live test (behind
  `BOTHARNESS_LIVE_CLAUDE=1`) asserts the running binary still honours them.
- **We can no longer:** let Claude Code drive the screen. Its only channel is a text prompt on
  stdin, and it has no tool with which to open a screenshot. `canDriveComputer` is false and that
  is structural, not a gap waiting to be filled.
- **We accept:** each turn resends the transcript rather than resuming a CLI session. Resuming
  would be cheaper and would make the CLI the owner of conversation state, which is precisely the
  thing being avoided.
- **We will know this was wrong if:** a future CLI version changes what `--tools ""` means, or adds
  a capability that is on by default and not covered by these four flags. The live test is the
  tripwire; if it starts failing, this ADR is the thing to reread.

## Revisit when

The CLI gains a documented "model only" or "no agent" mode. That would replace four flags whose
meanings we inferred with one contract the vendor maintains, and it should be adopted immediately.
