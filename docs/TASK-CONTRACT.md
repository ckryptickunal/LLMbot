# The task contract

A bot that asks "I found the issue, would you like me to fix it?" is not being careful. It is
being useless in a way that looks like carefulness. But a bot that deploys to production
because it inferred you would want that is worse.

The difference between those two failures is not personality and cannot be prompted into
existence. Telling a model to "take ownership" or "be urgent" produces a model that writes
more confidently and behaves identically. What actually changes behaviour is machinery:
budgets, defaults, permissions, deadlines, escalation rules, and — most of all — what the
system will accept as *finished*.

Every run in Bot-Harness is therefore governed by a contract with six fields.

```
                       TASK
                         │
          ┌──────────────┼──────────────┐
          │              │              │
      OBJECTIVE       URGENCY       AUTONOMY
          │              │              │
          └───────┬──────┴──────┬───────┘
                  │             │
              AUTHORITY    CONSTRAINTS
                  │             │
                  └──────┬──────┘
                         ↓
                 SUCCESS CRITERIA
```

| Field | The question it answers |
|---|---|
| **Objective** | What outcome do I own? |
| **Urgency** | How aggressively should I pursue it? |
| **Autonomy** | How much may I decide myself? |
| **Authority** | What may I technically execute? |
| **Constraints** | What must never happen? |
| **Success criteria** | What evidence proves I am finished? |

---

## Objective — owning an outcome, not a task

The difference between these two is most of the difference between a chatbot and an operator:

> "Look into this signup bug."

> "Own resolution of this signup bug. You are done only when signup works and the fix is
> verified. You may inspect and modify this repository, run services, and test locally. Ask me
> only if a protected action is necessary."

The second produces far stronger behaviour, and not because it is more emphatic. It produces
stronger behaviour because it states a **different terminal condition**. The first is satisfied
by an explanation. The second is not satisfied by anything short of working software.

The harness normalises vague requests into contracts before the model sees them. "Check why
Jewel isn't generating" becomes an objective of *restore local generation*, success criteria of
*a test generation completes*, authority over the repo, terminal, local browser and local
database, a constraint of no production changes, and an escalation list.

## Urgency — a resource budget, not a tone

Urgency must have operational consequences or it is decoration.

| Level | Behaviour | Planning | Retries | Parallel | Confirmations |
|---|---|---|---|---|---|
| **low** | Thoroughness over speed. Explore alternatives. | generous | 4 | 1 | normal |
| **normal** | Steady progress, direct actions, escalate after repeated failure. | moderate | 3 | 2 | normal |
| **high** | Time-to-resolution first. Parallelise. Skip nonessential exploration. | 20s | 2 | 3 | protected actions only |
| **critical** | Restore function first, investigate after. Interrupt only at hard boundaries. | minimal | 2 | 4 | protected actions only |

Concretely, at `critical` with production down, the correct reasoning is: check health, check
the recent deploy, read the logs, identify the likely regression, roll back if authorised,
verify recovery — *then* investigate root cause. Not forty minutes of architectural analysis
while the site is down.

## Autonomy — a ladder, not a switch

```
A0  Advisory              Explain only.
A1  Assisted              Suggest actions; the user executes them.
A2  Confirm before change Read freely, confirm every write.
A3  Autonomous workspace  Act freely inside a scoped environment.
A4  Autonomous operational Act across authorised systems; confirm consequential actions.
A5  Delegated operator    Broad authority within explicit policy.
```

Defaults: **A2** for a new bot on this Mac, **A3** once the user has watched it work and
widened it, **A3 with tight scopes** for anything touching infrastructure.

### The agency rule

The single decision rule that produces high agency without recklessness:

> If an action is **reversible**, within **granted authority**, and clearly advances the
> **stated objective**, perform it without asking.

Expanded, the check before any action is:

```
Can I confidently infer the user's desired outcome?     no → ask
Is this within the task's scope?                        no → ask
Is it authorised?                                       no → ask
Is it reasonably reversible?                            no → ask
Does it create significant external consequence?        yes → ask
                                                        otherwise → do it
```

So: discovering a missing CSS import does not produce "should I add it?" It produces adding
the import, running the build, opening the page, verifying it renders, and carrying on.

### Bias toward progress

When torn between taking a safe reversible action that gathers information and reasoning
further about it, **take the action**. Maybe the server is not running — check the process.
Maybe the endpoint 500s — curl it. Maybe the test fails — run it. Action is how an agent
interrogates reality instead of speculating about it, and it is a large part of why capable
coding agents feel more intelligent than chat models.

### Initiative, and its boundary

High agency includes inferring work the goal implies. "Add dark mode" means the toggle, the
persisted preference, respecting the system setting, checking the main screens, contrast,
building, and verifying on mobile.

It does not mean redesigning the navbar.

> **Infer necessary subgoals. Do not infer optional product decisions.**

## Authority — technical, not conversational

You do not tell a model it may deploy. You issue a capability, and the tool layer refuses
without one even if the model is certain it has permission.

```
filesystem   ~/Desktop/jewel/**        read/write
             ~/Documents/**            read
             ~/.ssh/**                 denied
github       read, branch, commit      allowed
             push to feature branch    allowed
             merge to main             approval
aws          read logs, restart staging allowed
             modify production          approval
gmail        read, send                denied
```

`filesystem.delete("~/.ssh")` returns `DENIED: outside task authority`, from the tool, before
any model reasoning is consulted.

**Self-repair** is a named authority class covering the environmental failures that otherwise
make an agent feel helpless: installing a missing dev dependency, restarting a crashed browser,
killing a stale local process on a port it needs, creating a temp directory, retrying a network
request, clearing a cache, choosing a different port. All are inside the workspace, all are
reversible, none require asking.

**Budgets are authority too.** Model calls, wall-clock steps, browser actions, external spend,
retries — each capped, and each scaled by urgency. Agency without economics becomes
pathological.

## Constraints — what must never happen

The task's own prohibitions, layered on top of the unlowerable `SafetyFloor`
(`docs/decisions/0004-two-layer-permission-model.md`). "No production changes." "No paid API
calls." "Do not modify files, only report."

## Success criteria — the part that creates agency

This is where most agents are weakest, and it is the highest-leverage field in the contract.

**The verifier, not the model, decides when a run is over.**

```
Model:    "I fixed it."
Harness:  success condition — the user can complete signup
          tests pass?              yes
          signup tested in browser? no
          STATUS: not complete → continue
```

```
Model:    "I've identified the likely problem."
Harness:  the objective is resolution, not diagnosis → continue
```

An agent stops early because the harness lets it. Completion enforcement is how you get agency
without ever writing the word "ownership" in a prompt.

## Escalation — asking as the highest-leverage move

High agency does not mean never asking. It means knowing when asking is the *best available
action*. Escalate when, and essentially only when:

- a required permission is not held, or an irreversible consequential choice is genuinely open
- two materially different readings of the user's intent both fit
- a credential is missing, or a CAPTCHA or 2FA needs a human
- a legal or financial commitment is involved
- repeated failure has persisted across genuinely different strategies
- an external dependency is actually unavailable

And escalation is compact and decision-shaped:

> Blocked on production deployment. Everything before it is done: fix implemented, tests pass,
> staging verified. I need your approval to deploy commit `4af913` to production.

Not "what would you like me to do next?" The first is an operator reporting a decision point.
The second is a chatbot handing the problem back.

---

## What this buys

The same model, under a contract instead of a personality prompt, stops behaving like:

> "Here are some steps you could try."

and starts behaving like:

> "I understand the desired state. I have permission to act. I will choose the fastest safe
> path, change strategy when something fails, verify the outcome, and involve you only when
> your judgment or authority is genuinely required."

Implemented in `Sources/BotHarness/Model/TaskContract.swift`.
