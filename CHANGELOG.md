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

### Fixed
- **The app no longer asks for your Mac login password over and over.** It was asking every
  time an eval run started, and in the running app it was asking as you typed — the check for
  "is there a key stored?" was accidentally reading the key itself, and reading a key is what
  raises that dialog. Checking now looks only at whether the item exists, which needs no
  authorisation at all. Where a key genuinely has to be read, it is read once per launch
  instead of once per message
  (see docs/decisions/0011-existence-checks-must-not-touch-the-acl.md).

### Security
- Keys are still in the login Keychain and the dialog was not suppressed or downgraded — the
  two shortcuts that would have silenced it, storing keys in a file or marking the item
  readable by any application without warning, were both rejected in ADR 0011.
- `scripts/set-key.sh` now adds the signed app to the key's trusted-application list, and its
  header points at Settings (⌘,) as the better path: a key stored by the app is owned by the
  app, so the app never has to ask for permission to read it. A key stored by the `security`
  command line tool belongs to that tool, which is why the app was being challenged for it.

### Added — the mascot
- **Claude's mascot walks on the strip above the message box.** It leans, looks around, walks
  the width of the composer, then crouches and jumps the rest of the way, on a loop. Ported
  from the public SVG-and-GSAP original rather than embedded — no browser and no animation
  library were added (see docs/decisions/0009-port-the-mascot-rather-than-run-it.md).
- It stands still when the Mac is set to Reduce Motion, and stops redrawing entirely when
  Bot-Harness is not the front app, so leaving the window open behind something else costs
  nothing.

### Changed — the design system is now actually implemented
- Every view is rebuilt on the token layer. An audit before this change found **157 raw font
  sizes, 215 raw spacings, 23 raw corner radii and 26 raw colours** still inline, with most
  components unused — `IconButton`, `Chip`, `EmptyState`, `Spinner`, `SectionLabel` and
  `Hairline` were all at zero. The earlier claim that no view contained a raw number was a
  token rename, not an implementation.
- After: **zero raw font sizes, zero raw radii, zero raw colours**, 586 token references, and
  every component in use. Icon sizes are named rather than derived, because arithmetic on a
  token at the call site is the same exception the system exists to prevent — it just looks
  more principled than a bare number.
- Empty and loading states are now real everywhere they were missing: an empty sidebar offers
  to make a bot, Connections shows row-shaped skeletons while it probes, the Activity window
  shows run-shaped skeletons while it scans the disk, and a screenshot shows an
  image-shaped one so nothing jumps when it lands.
- Trace and run scanning moved off the main actor. Reading a directory of runs, and decoding a
  Retina PNG, both dropped frames when done on the main thread while a run was streaming.

### Added — design system, live activity, screenshots in the conversation
- **A complete design system.** Space, radius, type scale, colour, size, motion and duration as
  one namespace, with a component layer covering every state including loading, empty and
  error. Documented in `docs/DESIGN-SYSTEM.md`. The old `Theme` is gone and all ten view files
  are migrated: no view contains a raw number or a raw colour any more.
- **Live activity behind a chevron.** What the bot is doing, streaming, collapsed by default and
  remembered. Shows the model's stated intent for each action, what it looked at, and what came
  back. Honest about its limit: Gemini returns no readable reasoning, only an opaque signature,
  so what is shown is intent plus everything the harness itself did.
- **Screenshots posted into the conversation**, like Grok Bot. Loaded from disk on demand and
  decoded off the main thread; the conversation document stores a path, never image bytes.
  Click to see full size.
- **From the rakazo teardown** (`docs/research/rakazo-teardown.md`, 37 patterns extracted from
  reading their source): screenshot deduplication by content fingerprint plus keep-last-N
  pruning, structural untrusted-content envelopes with the label placed *before* the content,
  and a repeated-identical-call guard that answers instead of re-running.

### Fixed
- **`files.glob` could not do recursive patterns.** `find -name` matches basenames only, so
  `**/*.swift` matched nothing — seen live, where the model responded by retrying with
  ever-broader patterns until it was listing the whole Desktop. Recursive patterns now work,
  build and dependency directories are pruned, and an empty result explains the pattern rule
  rather than just saying nothing was found.

### Changed — a real design system
- **Radix Colors for surfaces, macOS semantics for everything the OS owns**
  (`docs/decisions/0010-…`). The interface was thirty hand-picked hex greys, six half-point
  font sizes, and `Color.white.opacity(…)` scattered everywhere. Three measurements taken on
  this machine reframed it: macOS label colours are not greys but white at fixed alphas; the
  system palette shifted in macOS 26 (`systemRed` is now `#FF383C`); and macOS publishes no
  numeric surface ramp at all, while a three-pane cockpit needs five depths.
- **The functional layer is no longer painted.** The roster and inspector inherit the system
  material, the app uses a real `NavigationSplitView` with resizable columns, and the
  conversation pane is filled *darker* than the window — the native relationship. This is the
  single change that decides whether the app reads as Mac-native or as a web page in a window.
- **Five type steps, each bound to a system text style**, replacing six half-point sizes that
  matched nothing the OS draws and never optically lined up with the toolbar.
- **Motion is frequency-gated through one chokepoint.** Nothing triggered by a keyboard
  shortcut animates. 300ms ceiling. Reduced motion handled once rather than at ninety call
  sites.
- `docs/DESIGN-SYSTEM.md` — the full specification, and the record of where the research
  contradicted itself.

### Added — bots that describe themselves, and four patterns from rakazo
- **Bots write their own name and description.** After a successful run a bot updates its
  description from what it has actually been asked to do, the way Grok Bot does. A fresh bot
  asked to count Swift files named itself "File Scout" and wrote its own summary. Editing the
  text by hand locks it and the bot never overwrites your words; a button gives it back.
- **Live activity stream** behind a chevron between the conversation and the composer.
- **Streaming secret redactor.** Seeded with the actual key values for the run, not regexes, and
  it holds back the tail of the buffer so a secret split across two stream chunks is still
  caught. This matters here specifically: the trace is hash-chained, so a leaked key cannot be
  edited out afterwards without breaking the chain.
- **Loop guard.** Six identical tool calls ends the run — as a *completion* with a plain
  explanation naming the tool and the count, not as a failure. A red run with no explanation
  tells the user nothing they can act on.
- **Screenshot economy.** Frames are content-hashed, and an unchanged screen returns a sentence
  instead of an identical picture. Most looks in a GUI loop return the same frame, and paying
  roughly 1,500 tokens to say "still the same" is the most wasteful thing a screen agent does.
- `docs/research/rakazo-teardown.md` — 112 KB from reading elie222/rakazo's source, 36 patterns
  ranked by value and effort.

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

### Fixed
- **⌘N left the composer unfocused**, so creating a bot and typing did nothing. Focus now
  follows an explicit request rather than a flag, because setting a flag that is already true
  changes nothing and that was exactly the case.
- **`files.glob` could not handle `**/*.swift`.** `find -name` matches basenames and treats
  `**` literally, and the depth limit was 2 — too shallow for a real source tree. A bot asked
  to count Swift files got nothing back, tried three more globs, and reached for Terminal.
  Recursive patterns now work and results are counted.

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
