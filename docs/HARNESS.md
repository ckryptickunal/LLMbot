# The harness

What makes an agent feel capable is almost never the model, and almost never a single
"computer access" feature. It is the machinery around the model: how it discovers what it can
do, picks the cheapest surface that will work, keeps state, notices it has failed, recovers,
and proves to itself that it actually succeeded.

This document is the design for that machinery. It is organised as layers, and each layer says
what we build, when we build it, and what we deliberately do not.

**The governing principle:** the harness should make the model need to think less about
plumbing. Every problem the harness solves deterministically is intelligence the model gets to
spend on the part we actually want it for — understanding the goal, deciding what happens next,
and adapting when reality disagrees with the plan.

---

## Layer 0 — The task contract

Everything below hangs off this, so it comes first. See `docs/TASK-CONTRACT.md`.

A request from the user is normalised into a contract carrying six things: the **objective**
it owns, the **urgency** that sets its resource budget, the **autonomy** level it operates at,
the **authority** it actually holds, the **constraints** it must never violate, and the
**success criteria** that decide when it is finished.

Urgency, autonomy and authority are machine-readable and have operational consequences —
planning budget, retry counts, parallelism, confirmation thresholds. They are not tone.

---

## Layer 1 — Tool registry

Every capability the bot can invoke, in one registry, grouped by domain:

```
research    web.search · web.open · web.find · web.download
browser     navigate · click · type · extract        (built; one window, one tab)
computer    screenshot · click · type · key · scroll · launch_app · accessibility_tree
shell       exec · start_process · read_process · signal · kill
files       read · write · patch · search · glob · move · delete
dev         git.* · github.* · docker.* · test.* · build.*
memory      search · save · forget                   (built; notes carry provenance, ADR 0015)
external    every MCP server, namespaced by plugin
```

**The catch, and it matters:** never show the model every tool. A registry of three hundred
tools presented at once makes an agent slower, more expensive and measurably worse.

## Layer 2 — Capability router

The registry is large; the exposed set is small. Before each turn the router classifies intent
into domains and loads only those schemas.

```
user intent → classify domains → load 5–15 schemas → model
```

And the model can go looking for more, mid-run:

```
tool.search("github issues")   → candidate tools, names and one-liners only
tool.load("github")            → schemas enter the active set
tool.describe("github.create_issue")  → full schema for one tool
```

This is what lets us hold thousands of capabilities without paying for them every turn. MCP is
a good fit beneath it, because MCP servers are discoverable by design.

**Verified constraint:** the current MCP spec went stateless in July 2026, and the official
Swift SDK is a full revision behind with no release since May. Our MCP client is therefore
something we write against the wire format, not something we adopt. See
`docs/research/mcp-ecosystem.md`.

## Layer 3 — Skills

Tools answer *what can I do*. Skills answer *how do I do this well here*.

A skill is a compact operating manual, loaded only when relevant — a markdown file with
frontmatter, following the convention Claude Code and now several other agents already use, so
skills are portable rather than ours alone.

The example that shows why they matter, for a "working with Cursor" skill:

> Prefer shell and file APIs for source changes. Use the Cursor GUI only for graphical diff
> review, Cursor's own agent, or editor-specific UI. After Cursor changes code: inspect
> `git diff` yourself, run the tests yourself, verify the output yourself. Never take the
> editor's word for it.

Planned: `browser-navigation`, `web-research`, `github`, `cursor`, `coding`, `debugging`,
`deployment`, `spreadsheet`, `pdf`, `terminal`, `macos`, plus per-project skills for the
user's own systems (`jewel-ai`, `aravi-infra`, `transcriptor`).

Bloks makes skills installable with explicit user approval and treats them as "closer to a
script than to a note". We adopt both: a skill is executable knowledge, and installing one is
a permissioned act.

## Layer 4 — Three execution surfaces, and a selector

The single highest-leverage idea in this whole document.

```
                 TASK
                   │
      ┌────────────┼────────────┐
      ↓            ↓            ↓
    CODE         TOOL          GUI
  shell/python  API/MCP    mouse/keyboard
```

The selector, in strict preference order:

```
direct API available?          → use it
machine-readable without one?  → use shell or code
structured browser access?     → use browser.* (AppleScript; see ADR 0018)
none of the above?             → use GUI computer control
still stuck?                   → ask the user
```

"Find `authCallback` in my repository" should be `rg authCallback`, not opening an editor and
clicking a search box. "What is my PR status" should be the GitHub API, not a browser. But
"change this Photoshop setting" has no surface but the GUI.

Getting this one rule right makes an agent dramatically faster and cheaper than one that
pixel-drives everything, which is the failure mode of most computer-use demos.

## Layer 5 — The computer abstraction

Beneath the model, one interface regardless of what is behind it:

```
computer.screenshot() · list_windows() · launch(app) · click() · type()
         accessibility_tree() · active_app() · displays()
```

Implementations: **this Mac** (ScreenCaptureKit for capture, CGEvent for input, AXUIElement for
structure) and later **a container**. The model never learns which.

## Layer 6 — Layered observation

An agent whose only sense is screenshots is an agent that is mostly blind and expensively so.

```
1  structured state    active app, window list, cwd, running processes, git status
2  accessibility tree  what controls exist, their roles, whether they are enabled
3  DOM                 for web pages, the real structure and selectors
4  screenshot          what it actually looks like
5  cropped vision      one region, at high resolution, when 1–4 were not enough
```

**Escalate only when the cheaper level is insufficient.** If the accessibility tree already
says `{role: button, name: "Save changes", enabled: true}`, spending a vision call to look at
a picture of that button is waste.

This is the deepest open fork in the project: the pixel agent versus the semantic agent. Two
research tracks each called their answer the highest-value finding and neither acknowledged the
other existed. Our answer is *both, cheapest first*, with coordinates as the executor and the
accessibility tree as the disambiguator.

## Layer 7 — State diffing

Never re-send the world. Send what changed.

```
SCREEN CHANGE   new modal "Generation failed." buttons: Retry, Cancel
FILE DIFF       + auth middleware changed
NEW LOG LINES   Database timeout after 30s
```

A screenshot is roughly 1,500 tokens. A diff of what changed in it is roughly 30.

## Layer 8 — Fast indexes

So the model reads six relevant places instead of two thousand files:
filename and symbol indexes, dependency graph, git history, full-text, and embeddings over
files, memories and documents. `repo.search("where credits are deducted after generation")`
should return locations, not a directory listing.

## Layer 9 — Code execution as a first-class action

Many tasks are enormously faster as code, and an agent that does not realise this will click
for two hours at something a twelve-line script solves. Python, shell, Node, git, curl, jq,
sqlite, and the ordinary Unix tools are all actions.

## Layer 10 — Persistent processes

`shell(cmd) → wait → output` cannot run a dev server. So:

```
process.start() · stdout() · stderr() · status() · signal() · kill()
```

Start the server, keep working, read the logs later. Not freeze.

## Layer 11 — Watchers and an event bus

The model should not poll the world; the world should tell it something happened.

```
watchers    filesystem · process · log · git · http endpoint · queue · schedule
events      FILE_CHANGED · PROCESS_EXITED · BUILD_FAILED · TEST_FAILED
            DOWNLOAD_COMPLETE · APP_DOWN · SCHEDULE_TRIGGERED · USER_INTERRUPTED
```

Watchers run without the model. Only an event that matters wakes it. This is where most of the
cost of an "always on" agent is either spent or saved.

## Layer 12 — Scheduler

Routines, in the product sense: run at 9am, run hourly, run when this PR changes, run when the
site comes back up. A scheduler plus the event bus, not a model capability.

## Layer 13 — Planner and task graph

Long work becomes a graph of nodes, each with status, inputs, outputs, a verification predicate
and a retry count. Short work does not — planning a three-step task costs more than doing it.
The classifier decides which.

## Layer 14 — Subagents

Narrow context, compressed report. "Find why the OAuth callback fails. Do not modify files.
Return likely root causes with file references." The parent gets the conclusion, not the
subagent's entire action history. This buys parallelism and context isolation at once.

Bloks adds a good wrinkle we should take: **senior and junior agents**. Cheap models do the
volume work, an expensive one reviews and breaks ties.

## Layer 15 — Model routing

Intent classification and summarisation do not deserve the strongest model. Verification
deserves deterministic code wherever it can get it. The harness picks the intelligence the step
requires, which is where a large fraction of both latency and cost lives.

## Layer 16 — Caching

Tool schemas, skill summaries, repository maps, embeddings, web fetches, documentation,
dependency graphs. If the model asks what framework this repo uses for the fourth time, answer
from the project state rather than rediscovering it.

## Layer 17 — Context router

Possibly more important than the model. Before every substantial call, assemble the **minimum
sufficient context**, not the maximum available: two relevant memories, one project summary,
three relevant files, one skill, seven tool schemas, current environment state.

A large context window does not make this unnecessary. Irrelevant context still degrades the
decision.

## Layer 18 — Verification

Never let "I performed the action" mean "the objective succeeded."

```
action     click Save
predicate  did the API return 200 · did the UI show "Saved" · did the file mtime change
result     yes → proceed        no → recover
```

Deterministic predicates wherever they exist; a model judge only where they do not.

## Layer 19 — Recovery playbooks

Standard failure recipes, at harness level rather than model level.

```
click failed → did state change anyway → re-read accessibility tree → retry by element
             → retry visually → scroll into view → refresh → switch surface → ask
test failed  → read the failure → find the implementation → patch minimally
             → rerun that test → then the suite
```

Plus **stuck detection**: identical screen, identical action, identical error, or no state
change across N steps, each of which triggers a strategy change rather than another attempt.

## Layer 20 — Self-repair authority

A surprisingly large fraction of agent failures are environmental: a missing dev dependency, a
crashed browser, an occupied port, a stale process, a missing temp directory. An agent that
must ask permission for each of these feels helpless.

So there is a named authority class, `selfRepair`, that permits exactly these and nothing that
reaches outside the workspace.

## Layer 21 — Permissions, authority, and the credential broker

Covered in `docs/decisions/0004-two-layer-permission-model.md`. Two additions here:

**Authority is technical, not conversational.** You do not tell the model it may deploy. You
issue it a capability, and the tool layer refuses without one — even if the model has convinced
itself otherwise.

**The model never sees credentials.** It calls `github.push(repo:)`; the connector resolves the
token from the credential store and injects it into the request. The model sees `success`.
The store itself is on the permanent deny list, so the model cannot go and read the token
either — see [ADR 0012](decisions/0012-credentials-live-in-an-owner-only-file.md).

## Layer 22 — Snapshots and artifacts

Before risky work, snapshot the workspace so forty-six bad edits are one `rollback()`. Outputs
go to a managed artifact directory with metadata, not into chat history where they are lost.

---

## Build order

Layers are not equally urgent. This is the sequence, and the reason for each position.

| # | Layer | Why here |
|---|---|---|
| 1 | Task contract, authority engine | Everything else reads from it |
| 2 | Tool registry + shell, files, git | The surfaces that solve most tasks cheapest |
| 3 | Trace + verification | Built in from the start or never retrofitted honestly |
| 4 | Brains: Gemini and `claude` CLI | Nothing runs without one |
| 5 | Capability router | The moment there are more than ~20 tools |
| 6 | Computer abstraction + macOS executor | The riskiest unknown; prove it early |
| 7 | Layered observation + state diffing | Makes the computer layer affordable |
| 8 | Recovery + stuck detection | The difference between a demo and a tool |
| 9 | Skills | Once we know what the bot keeps getting wrong |
| 10 | Browser via AppleScript | Built. CDP was rejected — it needs Chrome relaunched with a debugging port, which kills the user's session and is the move a session-stealing attack makes. See ADR 0018. |
| 11 | Processes + watchers + event bus | Turns it from request-response into always-on |
| 12 | Scheduler / routines | Needs the event bus underneath |
| 13 | Subagents, planner, model routing | Only once single-agent runs are reliable |
| 14 | Indexes, caching, context router | Optimisation; premature before there is a corpus |
| 15 | Snapshots, artifacts | Before autonomy is widened, not before it exists |

## What we are not building

Our own browser engine, sandbox runtime, VM manager, coordinate-prediction model, vector
database, or general agent framework for other developers. Each is solved elsewhere and none is
where this project's value lies.

## Sources

The specification this document is built from came from the user directly. Where it is
corroborated or corrected by verified research, that is noted inline. Related reading:
`docs/research/harness-engineering.md`, `docs/research/agent-runtime.md`,
`docs/research/reference-implementations.md`.
