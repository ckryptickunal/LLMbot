---
id: 0008
title: The verifier decides when a run is over, not the model
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [runtime, agency, safety]
---

# 0008. The verifier decides when a run is over, not the model

## Context

The most common complaint about agents is not that they do the wrong thing. It is that they
stop:

> "I found the issue. Would you like me to fix it?"

That is not caution. It is a task handed back one step from done, and it happens because
nothing in the system disagreed when the model decided it was finished.

The instinctive fix is to prompt harder — tell the model to take ownership, be autonomous, be
urgent. This does not work. It produces a model that writes more confidently and behaves
identically, because none of those words change what the system will accept as complete.

## Options considered

### Option A — Prompt for agency
- **For:** Free, immediate, no machinery.
- **Against:** Changes tone, not behaviour. And it fails in the dangerous direction too: a model
  told to be autonomous is more likely to do something irreversible without asking.

### Option B — The model declares completion; the harness accepts it
- **For:** Simple; how most agent loops work.
- **Against:** Completion becomes a matter of the model's self-assessment, which is exactly the
  thing under question.

### Option C — Every run carries success criteria, and a verifier checks them
- **For:** "Finished" becomes an objective property. Stopping early is caught by the system
  rather than by the user noticing later.
- **Against:** Every task needs criteria written, including vague ones. Some criteria have no
  deterministic check.

## Decision

We chose **Option C**. Every run is governed by a `TaskContract` carrying `successCriteria`,
and `Verifier.completion` — not the model — decides whether the run may end.

When the model stops short, the harness sends back a flat statement of what remains:

```
Not finished. These success criteria are not yet verified:
- Signup completes in the browser

Keep going until each one has evidence, or escalate if you are genuinely blocked.
```

Two supporting commitments make it work:

**Vague requests are normalised into contracts before the model sees them.** "Check why Jewel
isn't generating" becomes an objective of *restore local generation*, a success criterion of
*a test generation completes*, scoped authority, and an escalation list. The user still types
one sentence.

**Criteria prefer deterministic kinds.** A command's exit code, an HTTP status, a file's
modification time. `SuccessCriterion.Kind.judged` — a model answering a question — is listed
last so that reaching for it feels like the fallback it is. An unverifiable criterion is
treated as unmet, not as satisfied.

Because: agency is not a personality trait you can request. It is the property of a system whose
terminal condition is the outcome rather than the explanation.

The same mechanism handles the opposite failure. `AgencyCheck` encodes the rule — *if an action
is reversible, within granted authority, and clearly advances the objective, do it without
asking* — and every condition that fails names itself, so the prompt the user sees says
something specific rather than "this needs approval".

## Consequences

- **We now must:** write success criteria for every run, including ones the user phrased
  vaguely. Doing that badly produces either premature stops or runs that never end.
- **We now must:** cap runs with a real budget (`Urgency.budget`), because a verifier that
  never passes plus a model that never stops is an expensive infinite loop. `maxSteps`,
  `maxModelCalls` and `maxSpendUSD` are the backstop, and exhausting one ends the run as
  `budgetExhausted` rather than as failure.
- **We can no longer:** treat "the model said it was done" as an event of any significance.
- **We gain:** a truthful completion signal, which is the thing every other reliability claim
  in this project depends on.

## Revisit when

Users start writing success criteria that are trivially satisfiable in order to make runs end.
That would mean the criteria have become a chore rather than a contract, and the answer would
be better inference of criteria from the objective, not removing the check.
