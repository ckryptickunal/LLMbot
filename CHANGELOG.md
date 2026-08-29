# Changelog

All notable changes to Bot-Harness are recorded here.

Format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## Rules for agents

- **Every session that changes a file adds a line here.** No exceptions, including
  documentation-only sessions.
- Write what changed *for the user of the system*, not what you typed. "Agent can now read
  files outside the workspace after approval" beats "added path check to FileTool.swift".
- Link the ADR when a change implements a decision: `(see docs/decisions/0007-....md)`.
- Group under `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`.
- `Security` is not optional. Any change to the permission model, credential handling,
  sandboxing, or what the agent is allowed to touch goes under `Security` even if it is
  also an `Added`.

---

## [Unreleased]

### Added — capabilities, and a way to see what happened
- **A working MCP client**, written against the wire format with no dependencies. stdio and
  HTTP transports, both verified against real servers. This is the piece that turns a list of
  hoped-for integrations into real ones: **Perplexity (4 tools), Lightroom (14) and Framer
  (22) now connect live** — 40 tools that were unreachable before.
- **Capability registry and resolver.** The agent asks for a capability, not a vendor. Two
  meta-tools let it extend its own reach mid-task: `capability.search` describes what it needs
  in plain words and gets back names and one-liners; `capability.load` brings a provider's
  operations into reach. So "put these in HubSpot" now discovers that HubSpot is not connected
  and says so, instead of inventing a worse plan.
- **Provider health with six states** — healthy, degraded, needs sign-in, starting, offline,
  error. A connector that fails stays visible with the reason and a repair action. Figma
  Desktop reports "not reachable, is the app running?"; Magic reports its reset API key.
- **Activity window** (account menu → Activity). Every run, every step, in order: the model's
  stated intent, the literal arguments, what came back, what the permission system decided and
  which layer decided it, tokens and cost. It verifies the hash chain on open, because a
  tamper-evident log nobody checks is just a log.
- **Connections screen driven by real health**, not a hardcoded list.

### Fixed — the app now actually responds
- **Nothing could be sent.** A `TextField` with `axis: .vertical` swallows Return, so
  `.onSubmit` never fired; there was no send button to fall back on; and the field never took
  focus. Three dead ends in one control, and together they made the whole app inert. Return
  now sends, Shift-Return makes a newline, a send button appears when there is something to
  send, and the composer takes focus when a conversation opens.
- **Four API shape errors**, each found by calling the live endpoint rather than trusting the
  docs. Function tools are one entry each with the name at the top level. Replies arrive as
  `model_output` with a `content` array, not a `text` field — so every reply would have been
  silently dropped. Every input part needs a `type`. Usage keys are `total_input_tokens` and
  `total_output_tokens`, so cost and tokens read zero.
- **`files.glob` never expanded `~`**, so every lookup under `~/Desktop` matched nothing, and
  an empty result was returned as an empty string — which tells the model nothing and sends it
  round the same call again. Empty results now say so in words.
- Replies were posted twice, because the closing note repeated what the bot had already said.
- **Several tools were advertised and unimplemented** — `web.search`, `web.open`,
  `memory.search`, `memory.save` were all in the catalogue and threw "there is no tool called
  X" when chosen. That is the tool-layer version of a button that does nothing, and it is how
  a run asking to search the web ended up listing the root filesystem instead. All four are
  implemented, and eval H13 now calls every advertised tool so the class cannot come back.
- **A relative path meant the whole filesystem.** A GUI app's working directory is `/`, so
  `files.glob path=.` listed the root. Relative paths now resolve to the bot's workspace.

### Added
- **A brain switcher**, in the composer where the decision actually gets made. Also an
  autonomy switch: Ask, Work, Autopilot.
- **Connections, Computers and Skills**, reachable from the sidebar, listing what a bot can
  reach and saying plainly where something is not built yet.
- Every button now leads somewhere. The account row opens a menu, Share as template writes a
  file, Open computer reveals the screen panel, and Grant opens the right privacy pane.
- **The agent loop actually runs.** `observe → context → brain → permission → execute →
  observe → verify → continue`, with observation escalating from structured state to the
  accessibility tree to a screenshot only when the cheaper level was not enough.
- **Gemini brain adapter**, behind a provider-neutral `BrainAdapter` protocol so the harness
  owns the computer rather than the model vendor.
- **macOS executor** — screenshot, click, double/right click, drag, scroll, type, hotkey,
  launch app, and the accessibility tree. Typing goes through `keyboardSetUnicodeString`, so
  it is correct on any keyboard layout rather than silently wrong on non-US ones.
- **Persistent processes** — start, read new output only, status, kill. Without these a bot
  cannot run a dev server and then look at the page it serves.
- **Eval suite: 20 tasks**, twelve deterministic and eight needing a live model, across file
  editing, terminal, debugging, browser, app control, recovery, prompt injection and
  permission boundaries. `scripts/eval.sh`. Exits non-zero on failure so it can gate a commit.
- `scripts/build.sh` and `scripts/eval.sh`.
- **Settings window (⌘,)** with somewhere to actually put an API key. Three fields — Gemini,
  Anthropic, OpenAI — writing straight to the macOS Keychain, plus automatic detection of the
  Claude Code CLI, which needs no key at all. A stored key is never displayed back, not even
  masked: this screen can write a secret and ask whether one exists, and has no read path.
  Also shows the global permission rules and the built-in floor that no rule can switch off.
- `scripts/_toolchain.sh`, sourced by every script, pinning one Swift toolchain.
- **The harness.** `docs/HARNESS.md` describes 22 capability layers and the order to build
  them; `docs/TASK-CONTRACT.md` describes the six-field contract that governs every run.
- `TaskContract` — objective, urgency, autonomy, authority, constraints, success criteria.
  Urgency sets real budgets (planning time, retries, parallelism, step and spend caps), not
  tone. Autonomy is a six-rung ladder. Authority is enforced by the tool layer, never by the
  prompt, and includes a `selfRepair` class so a bot can fix its own environment without asking.
- `ToolRegistry` with mid-run discovery (`search`, `describe`), a `CapabilityRouter` that
  exposes only the domains a turn needs, and 30 built-in tools across files, shell,
  development, research, browser, computer and memory.
- `SurfaceSelector` — always take the cheapest execution surface that will work: API, then
  code, then structured browser, then GUI, then asking the user
  (see `docs/decisions/0007-cheapest-execution-surface-first.md`).
- `Verifier` — the run is over when the success criteria have evidence, not when the model says
  so. `StuckDetector` catches repeated actions, repeated errors, no state change and
  oscillation. `RecoveryPlaybook` holds ordered responses to the failures that actually recur.
- Trace records are now **hash-chained**, so an edited or deleted line is detectable and
  `TraceWriter.verifyChain` reports where. Idea taken from bloks.
- A test suite, and `scripts/test.sh` to run it (XCTest needs Xcode, which
  `xcode-select` does not point at on this machine).
- `docs/research/reference-implementations.md` — what to take from bloks, rakazo, clicky and
  openclicky, and what not to.
- Sixteen research documents under `docs/research/` — 321 individually sourced facts and 105
  catalogued tools, covering Gemini and Claude computer use, controlling a real Mac, the macOS
  build and signing path, browser control, MCP, sandboxing, agent runtimes, observability, and
  the interface itself. Start at `docs/research/README.md`.
- Six decision records under `docs/decisions/`, each with the observation that would prove it
  wrong.
- `CLAUDE.md` and `AGENTS.md` — how any coding agent should work in this repository.
- Repository scaffold: `app/` (SwiftUI cockpit), `core/` (agent runtime), `docs/`,
  `.claude/` (project-specific agent configuration), `evals/`, `var/` (traces + artifacts).
- Architecture decision record system under `docs/decisions/` with a mandatory
  falsifier field on every record.
- Append-only decision trace: every tool call made by any agent working in this repo is
  captured to `var/traces/agent-activity.jsonl` via a Claude Code hook.
- `scripts/doctor.sh`, `scripts/bundle.sh`, `scripts/set-key.sh`.

### Changed
- Package split into `BotHarnessCore` and the UI. The core carries no SwiftUI, which is what
  lets the tests and the eval harness link it — an executable containing SwiftUI views cannot
  be linked into an XCTest bundle.
- Urgency budgets are expressed in work rather than wall-clock thinking time. "Critical means
  ten seconds of planning" was artificial; a ceiling on reasoning maps onto nothing the model
  or the harness controls, and punishes a hard problem for being hard.
- Parallel subagents pinned to 1 at every urgency, with the reason recorded in the type. One
  agent has to be excellent before several are worth the state races.
- `scripts/bundle.sh` now signs with the Apple Development certificate found on the machine
  instead of ad-hoc. Verified that this keeps the designated requirement byte-identical across
  rebuilds, which is what keeps Screen Recording and Accessibility grants alive
  (see `docs/decisions/0003-sign-with-a-real-certificate.md`).

### Fixed
- Mixing the two Swift toolchains in one `.build` directory produced an opaque linker failure
  (`_swift_coroFrameAlloc` undefined, `SwiftUICore` not an allowed client) that reads like a
  code problem. All scripts now pin the same toolchain, and the symptom is documented.
- `docs/guides/ENVIRONMENT.md` claimed full Xcode was not installed. It is: Xcode 26.6 with the
  macOS 26.5 SDK and Swift 6.3.3. `xcode-select` merely points at Command Line Tools, so
  `xcodebuild` errors. The document now records the mistake rather than quietly correcting it.

### Security
- **The eval suite found a real hole and it is fixed.** A user rule reading "push code to a
  remote" did not match `git push origin main`, because only one of its three content words
  appears in the command — so a safety rule the user wrote silently did nothing. Rule matching
  now bridges what people write to what commands look like, and is deliberately asymmetric:
  a near-miss on a restricting rule counts as a match, a near-miss on a permitting rule does
  not. Uncertainty narrows what a bot may do and never widens it.
- Traces redact known credential shapes before writing, not on read, because trace files get
  copied and shared.
- **Fixed a real gap:** redaction was documented but not actually applied to trace records
  written through `record()` — only to hook output. Redaction now happens at the single choke
  point every trace write passes through, and a test asserts it. A guarantee that depends on
  every caller remembering is not a guarantee.
- `var/` is gitignored and must stay so: this repository is public and traces contain real
  commands, paths, and file contents.
- Project `.claude/settings.json` denies reads of `.env` files, `~/.ssh` and `~/.aws`, and of
  Keychain secret values.
