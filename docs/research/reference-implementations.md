# Reference implementations worth stealing from

Four open-source projects that solve pieces of this problem. Read before designing anything
new — two of them are close enough to Bot-Harness that arriving at a different answer should
require a reason.

Fetched and verified 2026-08-29.

---

## bloks — the closest thing to this product that already exists

<https://github.com/hamedgitty/bloks>

> "A local-first desktop workspace for personal AI agents. Your agents, your machine, your data."

It is a messaging interface where **agents are contacts and rooms are group chats**, running
entirely locally with no account and no backend. That is, almost exactly, the product described
in `docs/PRODUCT.md` — including the channels feature we thought was our own addition.

**Stack:** React front end, a Node HTTP harness, an Electron shell for macOS. Node 22+, pnpm,
roughly 850 tests on Node's built-in runner.

**The architectural rule they state and we should adopt verbatim:** *the client holds no
transports.* Provider processes run in the harness only, never from the browser layer. Our
equivalent: the SwiftUI views never talk to a model or a tool; everything goes through the
runtime.

### What to take

**Tool-running engines versus chat-only engines.** Bloks distinguishes providers that can
execute commands and read files (Claude Code, Codex, Gemini CLI) from providers that can only
talk (OpenRouter, raw Gemini, Grok, Kimi, DeepSeek, Ollama). This is exactly the distinction
our own research forced on us — computer use is unreachable through `claude -p` — and naming it
in the model rather than discovering it per-provider is better design than what we have.

**Hash-chained, signed event logs.** Their audit log of consequential actions is append-only
*and* hash-chained, so tampering is detectable rather than merely inconvenient. Our trace
(ADR 0005) is append-only but not chained. Adding a `prev_hash` field is nearly free and turns
"a log" into "evidence". **This is the single best idea to take from bloks.**

**Senior and junior agents.** Cheap models do volume work; an expensive one reviews the results
and breaks ties. A cost strategy expressed as an org chart, which users understand immediately.

**Rules evaluated before the action, not after.** Their example: *"Refuse when the command
contains `rm -rf`."* Same shape as our natural-language rules, and the emphasis on *before*
matches our floor-first evaluation order.

**Skills are scripts, not notes.** They describe a skill as "closer to a script than to a
note", installed to `~/.bloks/skills/` and requiring explicit approval to install. Treating
skill installation as a permissioned act is correct and we had not planned it.

**Workflow state on disk rather than in a promise**, so a run survives the app closing. We
should hold ourselves to this too.

**Their storage layout**, which is worth comparing to ours:

```
~/.bloks/
  bots.json           agent definitions
  bloks.json          rooms and membership
  messages-<id>.json  transcripts, one file per conversation
  config.json         engine credentials, mode 0600
  skills/             markdown skills
  events/             the canonical event stream
  native/             raw provider logs
```

One transcript file per conversation is better than our single `state.json` and is the
migration to make when a conversation gets long. Credentials in a 0600 file is *worse* than our
Keychain approach; we keep ours.

### What not to take

Electron and the 307 MB that comes with it (ADR 0002). Credentials in a config file. And the
licence: **FSL-1.1-MIT**, free for everything except reselling bloks itself, converting to MIT
two years after each release. That is not OSI-open, which matters when choosing ours.

---

## rakazo — the routines and delegation model

<https://github.com/elie222/rakazo>, Apache-2.0

> "An open-source platform for running persistent AI teammates."

Web, Electron desktop and Expo mobile, over TypeScript, React 19, Hono, oRPC, PostgreSQL,
Prisma and Graphile Worker.

### What to take

**Team Computers versus Private computers.** Shared compute that several agents use, alongside
isolated per-agent environments. A better framing than our binary `thisMac` / `container`, and
worth revisiting when channels land: bots collaborating in a channel probably want a shared
workspace, not one each.

**Delegation to peers and to temporary subagents**, as a first-class product concept rather
than an implementation detail. Ours is currently only an implementation detail.

**Events via PostgreSQL `LISTEN`/`NOTIFY`, jobs via Graphile Worker.** We will not adopt
Postgres, but the split is the right one: a durable job queue for scheduled work and a
pub/sub channel for reactive work are different mechanisms, and `docs/HARNESS.md` layers 11 and
12 should keep them separate rather than building one thing that does both badly.

**Breadth of integration surfaces:** Composio, Pipedream Connect, MCP servers, OpenAPI, and
sandboxes across Docker, E2B, Daytona. Confirms that MCP alone is not the whole plugin story —
an OpenAPI importer reaches far more services for far less work.

### What not to take

The whole runtime shape. Postgres, Prisma, Graphile Worker, Docker Compose and a monorepo of
web, API, worker, desktop and mobile apps is a team's architecture. For a single user on one
Mac with 1.4 GB of free disk, it is the wrong trade in every direction.

---

## clicky and openclicky — native macOS control, in Swift

<https://github.com/farzaa/clicky> (MIT) and <https://github.com/jasonkneen/openclicky>

Menu-bar companions that see your screen, listen, talk back, and point at things. Small, and
directly instructive for our hardest layer.

### What to take

**They prove the native Swift path.** ScreenCaptureKit for capture, Accessibility plus
Microphone plus Screen Recording as the permission set, macOS 14.2+ as the floor. This is the
same stack ADR 0002 commits to, already working in shipped apps.

**`[POINT:x,y:label]` as a visible pointer overlay.** The model emits a coordinate and a label,
and an overlay window animates a cursor there across multiple displays. Worth copying wholesale
for our foreground-control mode: if the agent is driving the user's real screen, showing
*where it is about to act, and why*, before it acts, is both better UX and a safety feature.

**A local control bridge on `127.0.0.1:32123`** exposing cursor control, screenshots and
speech, deliberately without creating agent sessions or mutating conversation state.
openclicky's note that the bridge "avoids mutating core conversation state" is the right
instinct: the thing that touches the OS should not also be the thing that owns the transcript.

**openclicky's routing ladder** — direct answer, web search, image gallery, shell and file
operations within configured project roots, GitHub via MCP, screen automation by coordinate,
and *native computer use only as the fallback for what nothing else can reach*. That is
independently the same surface selector as `docs/HARNESS.md` layer 4, arrived at by someone
building the same kind of thing. Good corroboration.

### What not to take

Both require Xcode and a `.xcodeproj`; we build with Swift Package Manager. Both put API keys
behind a Cloudflare Worker proxy, which is right for a distributed app and unnecessary for one
that uses the user's own keys from their own Keychain.

---

## What this changes

| Change | Source | Status |
|---|---|---|
| Hash-chain the trace so tampering is detectable | bloks | To do — small, high value |
| Name tool-running vs chat-only as a property of a brain | bloks | To do |
| One transcript file per conversation, not one big state file | bloks | When a conversation gets long |
| Installing a skill requires approval | bloks | To do |
| Senior/junior agent pairing for cost | bloks | Later, with subagents |
| Separate the job queue from the event bus | rakazo | Design note for layers 11–12 |
| Shared workspace for a channel, not one per bot | rakazo | Open question for channels |
| OpenAPI import as well as MCP | rakazo | Later |
| Pointer overlay showing where and why before acting | clicky | To do — safety and UX both |
| Keep OS control out of the process that owns the transcript | openclicky | Already our shape; now deliberate |
