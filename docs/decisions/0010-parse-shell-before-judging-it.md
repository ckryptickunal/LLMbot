---
id: 0010
title: Parse a shell command before judging it, and treat "unreadable" as its own answer
status: accepted
date: 2026-08-30
deciders: [Kunal, Claude]
tags: [safety, permissions, shell]
supersedes: []
superseded_by: []
---

# 0010. Parse a shell command before judging it

## Context

The safety floor decided which category an action fell into by looking for substrings in the
action's text. For shell commands that does not work, and the way it fails is silent.

Verified against the code as it stood (`PermissionEngine.classify`, needles `rm -rf /` and
`rm -rf ~`), these all reached the floor and passed it:

| Command | Why it passed |
|---|---|
| `rm -fr /` | the flags are in the other order |
| `rm -rf "$HOME"` | the home directory is named without the character `~` |
| `echo k >> ~/.ssh/authorized_keys` | the floor has no idea what a redirect is |
| `curl … \| sh` | nor a pipe |

Each is a command a shell treats as identical to one the floor claimed to stop. The failure is
the worst shape a safety check can have: it returns "nothing found" when the honest answer is
"I could not tell."

Reading Grok Bot's `app.asar` ([`grok-bot-app-asar.md`](../research/grok-bot-app-asar.md))
showed the same problem solved with a real grammar: they ship `tree-sitter-bash` as a native
dependency and parse every command into executables, typed arguments, and redirects before any
policy runs. Two of their message types exist only to say "I do not know" —
`parsing_failed` and a sandbox mode of `UNDETERMINED`.

## Options considered

### Option A — more substrings
- **For:** no new code, no new failure modes.
- **Against:** the list is unbounded and every entry is a guess about spelling. `rm -fr` teaches
  you that you also need `-f -r`, `--force --recursive`, `/bin/rm`, `env rm`, and so on forever.
  Worse, it cannot be made to notice a redirect or a pipe at all, because those are structure,
  not vocabulary.
- **Verified against:** `Sources/BotHarnessCore/Runtime/PermissionEngine.swift` before this change.

### Option B — ship `tree-sitter-bash`, as Grok Bot does
- **For:** a real grammar, maintained by other people, correct on cases we have not thought of.
- **Against:** a C dependency and a Swift binding, in the one part of the codebase where a
  crash is a safety event. [0002](0002-native-swiftui-zero-dependencies.md) requires an ADR for
  any dependency, and the bar for one that sits inside the permission path is higher than the
  bar for one that draws a chart.
- **Verified against:** `app.asar.unpacked/dist/deps/tree-sitter-bash` in Grok Bot 0.30.0.

### Option C — a small reader of our own, for the questions the floor actually asks
- **For:** no dependency; ~400 lines; testable against a real shell; and the scope is genuinely
  small because the floor needs three answers, not a syntax tree — which programs would run,
  what were they handed, and where does output go.
- **Against:** it is a shell parser we now own, and shell syntax is larger than it looks.
  It will be wrong about something.
- **Verified against:** `ShellCommandParserTests`, 13 cases.

## Decision

We chose **Option C**, with one condition that matters more than the parser: **it reports when
it cannot read something, and that is not the same value as finding nothing.**

`ShellParse.readable` is false for an unclosed quote, an unbalanced parenthesis, or nesting past
a depth limit, and `PermissionEngine` turns that into an approval prompt naming the reason. A
parser that fails open would be worse than the substring matcher it replaced, because it would
look thorough.

Three further choices, each because the alternative is a hole:

- **Flags are a set, not a string.** `-rf`, `-fr`, `-r -f` and `--recursive --force` all produce
  the same set, which is what makes flag order stop being a bypass. Single-dash words are
  recorded both exploded and whole, because `find -delete` is one option and `rm -rf` is two.
- **Wrappers are unwrapped.** `sudo rm -rf /` is recorded as `sudo` *and* `rm`, and the same for
  `env`, `xargs`, `nohup`, `timeout` and the rest. `sh -c "…"` and `$(…)` are parsed as the
  programs they are.
- **An unknowable target is the most alarming case, not the least.** `rm -rf "$TARGET"` cannot
  be resolved without running something, so the floor stops rather than shrugs. This is the
  opposite of what a substring matcher does with the same input.

The parser has no policy in it and the policy (`ShellFloor`) has no string-scanning in it. The
old text scan is **kept**, running after the structural one, because it still covers the tools
that are not shell commands and because two nets that miss different things beat one net.

`ProposedAction` now carries the tool's real arguments, and the floor judges those. It used to
judge a rendering that included model-written prose. That could only ever make the floor
stricter, so it was not a hole — but a floor whose input is written by the thing it constrains
is the wrong shape regardless.

One floor category is added: `runningUnreviewedCode`, for `curl … | sh` and its relatives. It is
the one common shell shape none of the existing categories describes — not a delete, not a
config change, not a grant, but able to become all three a second later.

## Consequences

- **We now must:** treat `ShellCommandParser` as safety-critical code. It gets a test for every
  bypass anyone finds, and the tests in `ShellFloorTests` are the record of what was already
  tried. It must never be "simplified" into a regex.
- **We now must:** keep `readable == false` routed to a person. Any future caller that treats it
  as clear reopens the hole this ADR closed.
- **We can no longer:** claim the floor is purely deterministic *text* matching. It is now a
  parse plus a policy, which is more code in the most sensitive place in the app.
- **We will know this was wrong if:** the parser produces a false "clear" on a command a shell
  would run differently — the one failure mode that matters — or if ordinary work starts
  triggering approvals often enough that people stop reading them. `ShellFloorTests` has a
  block of nine everyday commands asserting they stay clear, which is the tripwire for the
  second one.

## Revisit when

A bypass is found that needs real grammar rather than another case — nested here-documents,
process substitution `<(…)`, or arithmetic expansion changing what runs. At that point Option B
becomes the cheaper answer and this ADR should be superseded rather than patched.
