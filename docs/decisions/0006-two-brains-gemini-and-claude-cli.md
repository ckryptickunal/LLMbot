---
id: 0006
title: Two brains — Gemini for computer use, the local claude CLI for coding
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [architecture, providers, cost]
---

# 0006. Two brains — Gemini for computer use, the local `claude` CLI for coding

## Context

Asked which model accounts actually have working billing, the user answered: **a Google AI /
Gemini key, and a Claude Code subscription**. `ANTHROPIC_API_KEY` is unset, verified.

That answer constrains the design more than any technical consideration.

The research synthesis argued for Anthropic's Messages API with the computer-use toolset,
partly on the premise that "Kunal has zero Gemini keys". **That premise is false** — the user
stated they have one, and Gemini keys are present in several project `.env` files. The
synthesis's conclusion does not survive its premise being corrected.

What the research did establish, and what holds:

- Gemini's Computer Use tool officially supports `environment: "desktop"`, with OS-level actions
  (`click`, `type`, `hotkey`, `drag_and_drop`, `press_key`, `scroll`, `take_screenshot`, …) and
  explicitly without the browser-only `navigate` / `go_back` / `go_forward`.
- `gemini-3.7-flash` is real and is the documented recommendation for computer use, at
  $0.75/$3.75 per 1M tokens through 2026-12-31.
- Coordinates are **normalised integers 0–999**, not pixels. The client scales them.
- Every action carries an `intent` string — the model's stated reason for that step.
- `enable_prompt_injection_detection` is a real opt-in key, and `disabled_safety_policies`
  covers seven named categories.
- Google's reference repo is **browser-only**: it ships Playwright and Browserbase backends and
  no desktop executor. We write the macOS executor ourselves regardless of which brain we pick.
- Computer use is **not reachable through `claude -p`** — Claude Code's bundled computer-use
  MCP server is unavailable in print mode. A Claude subscription therefore cannot drive the
  screen without a separate API key.

## Options considered

### Option A — Anthropic Messages API for everything
- **For:** A macOS-native reference implementation exists that already solves screenshot
  resizing and coordinate alignment.
- **Against:** Requires an API key the user does not have and did not choose to buy. Blocked today.

### Option B — Gemini for everything
- **For:** One provider, one key, one wire format. Desktop environment is officially supported.
- **Against:** Wastes the Claude Code subscription, which is genuinely excellent at exactly the
  coding tasks that are one of the four acceptance tests.

### Option C — Both, chosen per bot
- **For:** Uses what the user actually has. Gemini drives the screen; `claude -p` does the
  coding, billed to a subscription already paid for. Each is used where it is strongest.
- **Against:** Two adapters, two failure modes, two cost models to display honestly.

## Decision

We chose **Option C**. `BrainSpec` is per bot, not global:

- `.gemini(model:)` — HTTPS to the Gemini API with a Keychain key. The computer-use path.
- `.claudeCLI(model:)` — spawns `claude -p --output-format stream-json --input-format stream-json`.
  Billed to the subscription. No API key. The coding path.
- `.anthropic(model:)` and `.openAI(model:)` exist in the type for users who have those keys.

`.claudeCLI` is deliberately the **default** for a new bot, because it is the one that works
with no key at all.

Because: the user told us what they have, and an architecture that requires them to buy
something else before it runs is not the architecture they asked for.

## Consequences

- **We now must:** write the macOS action executor ourselves — ScreenCaptureKit for capture,
  CGEvent for input. No vendor ships one. This was true under every option.
- **We now must:** handle the 0–999 normalised coordinate transform to a 3600×2338 Retina
  display, and get it exactly right. This is a prime early test target.
- **We now must:** map Gemini's `safety_decision` onto our own permission floor rather than
  trusting it. Google's docs say a disabled policy is only a preference and the model may still
  return `require_confirmation` — so our floor is the authority and theirs is an input.
- **We now must:** display cost per bot honestly, since the two brains bill in entirely
  different ways — one metered per token, one against a weekly subscription allowance.
- **We can no longer:** assume one prompt format. The system prompt is rendered per brain.

## Revisit when

Either:
- The user buys an Anthropic API key. Then the Messages API computer-use path becomes available
  and should be benchmarked head-to-head against Gemini on the same tasks, measured rather than
  argued.
- Gemini's desktop environment proves unreliable in practice on macOS. There is currently **no
  published end-to-end example** of that path on macOS, which makes it the single largest
  unverified assumption in this project.
