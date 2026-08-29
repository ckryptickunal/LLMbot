---
id: 0004
title: Permissions are a natural-language rule layer over an unlowerable floor
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [safety, product]
---

# 0004. Permissions are a natural-language rule layer over an unlowerable floor

## Context

ADR 0001 put bots on the user's real machine, with no snapshot to roll back to. The approval
gate now carries all the safety weight that a disposable VM carries for the reference product.

Grok Bot's model, read directly from its settings pane, is the best design available:

- **Auto-review**: "Grok Bot checks each action before it runs and asks you first when needed."
- **Rules in plain language**: "Write one short, natural-language rule for each action.
  **'Ask first' takes priority if rules conflict.**" The user completes the sentence
  *"When Grok Bot wants to: ___"* and picks a behaviour.
- **A floor beneath them**: "These rules apply only to you. **Built-in safety checks always apply.**"

The alternative model, which Claude Code and Codex CLI use, is pattern matching over command
strings: `Bash(git push:*)`, `Read(//path/**)`. It is precise, and it is writable only by
someone who thinks in globs.

Gemini's Computer Use API independently arrives at a similar shape: it returns a
`safety_decision` of `allowed` / `require_confirmation` / `blocked`, ships seven built-in
policy categories, and warns that disabling a category is only a preference — the model may
still return `require_confirmation`, so the client must handle it regardless.

## Options considered

### Option A — Pattern rules over command strings
- **For:** Deterministic, auditable, no model call to evaluate, no ambiguity.
- **Against:** Unwritable by the audience most in need of constraining a bot. Also brittle in
  the wrong direction: `Bash(rm:*)` does not catch `find . -delete`.

### Option B — Natural-language rules, matched semantically
- **For:** A user writes "reply to emails for me". Covers intent rather than syntax, so it
  catches the `find -delete` case that a pattern misses.
- **Against:** Matching costs a model call and is not perfectly deterministic. A rule can be
  interpreted more broadly than intended.

### Option C — B over a hardcoded floor
- **For:** The ambiguity of B is bounded by A's determinism where it matters most. A
  mis-generous interpretation of a user rule cannot reach the actions that would be
  unrecoverable, because those are decided before user rules are consulted.
- **Against:** Two systems to maintain, and users will occasionally be asked about something
  they thought they had allowed.

## Decision

We chose **Option C**, with these properties:

1. **The floor is evaluated first and cannot be lowered.** `SafetyFloor` covers nine categories:
   financial transactions, entering credentials, destructive deletes, rewriting shared history,
   sending to a new recipient, granting access, changing system configuration, publishing, and
   *instructions originating from untrusted content*. Two of them — entering credentials, and
   anything a web page or document asked for rather than the user — are `neverAllow` rather
   than `askFirst`. They are not delegated at all.
2. **Strongest behaviour wins.** `neverAllow` < `askFirst` < `allowAutomatically` by strength.
   An over-broad allow can never swallow a narrower ask. This is Grok Bot's stated rule and it
   is the right one.
3. **Every decision is traced** — outcome, reason, deciding layer, and the rule that matched.
   A permission system that cannot be audited cannot be trusted.

The prompt-injection defence lives here rather than in a separate subsystem:
`ProposedAction.originatedFromUntrustedContent` marks any action whose justification came from
content the agent *read*, and the floor refuses those outright. Content is data; it does not
get to issue instructions.

## Consequences

- **We now must:** evaluate rules with a model call on the hot path, and design for that
  latency and cost. Deterministic pre-filters should short-circuit the common cases.
- **We now must:** show the user the literal command or message in every prompt. OpenClaw's
  disclosed vulnerability was a confirmation dialog that elided what it was confirming.
- **We now must:** track provenance through the whole tool pipeline, so
  `originatedFromUntrustedContent` is accurate rather than decorative. This is the hardest part
  and the easiest to get quietly wrong.
- **We can no longer:** claim the permission decision is fully deterministic.

## Revisit when

Either:
- Semantic matching produces a wrong *allow* even once in real use. Then the floor expands and
  the user layer narrows to a whitelist of explicitly safe categories.
- Users report being asked about things they clearly allowed, often enough to be trained into
  clicking through. Alert fatigue is a security failure, not a UX one.
