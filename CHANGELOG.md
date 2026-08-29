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

### Added
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
