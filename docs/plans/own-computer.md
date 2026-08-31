# Implementation plan: a bot's own computer

> **Who this is for.** An LLM (or person) implementing this end to end in a later session,
> possibly with no other context. Everything you need is here or linked; every external fact
> below was verified on 2026-08-31 against this machine or the cited source. Where something
> could NOT be verified in advance it is marked **VERIFY-AT-IMPL** — check it before building
> on it, and record what you find.
>
> **The one-sentence goal.** A bot whose `environment` is `.container` gets a real, disposable
> Linux machine of its own — own filesystem, own packages, own network identity — that it can
> use entirely by itself (install, build, run, serve), while everything that touches the real
> Mac stays exactly as guarded as it is today. A bot on `.thisMac` additionally gets every
> shell command wrapped in a kernel-enforced sandbox.

---

## 0. Rules of this repository — read before writing any code

These are not suggestions; violating them is how a correct-looking PR gets rejected here.

1. **Verify, do not assume.** This project found a third of its own starting brief was false.
   Run the command, read the error, then conclude. Write "assumption" next to anything you did
   not check.
2. **No package dependencies** (ADR 0002). The accepted pattern for external capability is a
   CLI the *user* installs, discovered at a fixed absolute path — the app already does this
   with the Claude Code CLI (`SettingsView.findClaudeCLI()`). `apple/container` follows the
   same pattern. Do NOT import the `apple/containerization` Swift package.
3. **Decisions get ADRs** (`docs/decisions/_TEMPLATE.md`, copy it). This plan requires two:
   one for Seatbelt, one for trusting the `container` binary. Number them after the highest
   existing ADR at the time you write (0013 existed when this plan was written; a parallel
   session may have added more — check).
4. **Every session that changes a file adds a CHANGELOG.md line**, written for the user of the
   app, not a diff summary.
5. **A parallel Claude session is usually editing this tree.** Practical consequences, all
   experienced while writing this plan:
   - The shared `.build/` gets poisoned by mixed-SDK builds. Build and test with
     `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --scratch-path /tmp/bh-own`
     (and `swift test --scratch-path /tmp/bh-own`) when `./scripts/build.sh` fails on link.
   - Files change under you mid-edit. Re-read before every Edit; if an edit fails on "file
     modified", re-read and re-apply. Never revert someone else's change to make yours apply.
   - The hottest files right now: `ShellExecutor.swift`, `AgentLoop.swift`, `Store.swift`,
     `GeminiAdapter.swift`. Touch them in small, surgical edits.
6. **GUI verification workflow** (the app must be run as a signed bundle, and launched with
   `open`, not direct exec — a directly-execed SwiftUI app on this machine never creates its
   window):
   ```
   ./scripts/bundle.sh            # signs with the real cert — never codesign -s -
   open -n --env CFFIXED_USER_HOME=/tmp/scratch-home --env HOME=/tmp/scratch-home build/BotHarness.app
   ```
   Screenshot by window id (`screencapture -l <wid>`), never full-screen. Kill the app before
   editing state fixtures. `Store` debounces saves 400 ms — quitting the app can lose the tail;
   the app itself flushes on terminate, but your *fixtures* should be written while it is not
   running.
7. **Tests that need external things are env-gated, not deleted.** Existing pattern:
   `ClaudeCLIAdapterTests` skips unless `BOTHARNESS_LIVE_CLAUDE=1`. Container integration
   tests follow it with `BOTHARNESS_LIVE_CONTAINER=1`.
8. **Disk is scarce.** 6.5 GiB free when this was written (`df -h /`). Every phase below has a
   disk budget and a hard check. Never pull an image without checking first.

---

## 1. What exists today (the seams you will build into)

Verified by reading the code on 2026-08-31. Symbol names, not line numbers — the tree moves.

| Thing | Where | What matters for this plan |
|---|---|---|
| `Bot.environment: EnvironmentKind` | `Model/Bot.swift` | `.thisMac` / `.container` already modelled, persisted, and shown read-only in bot settings. Nothing routes on it. |
| `Bot.effectiveWorkspace` | `Model/Bot.swift` | The single definition of the bot's folder. The container's `/work` mount maps to exactly this. |
| Tool execution | `Runtime/AgentLoop.swift`, one big `switch action.name` in the execute path | `shell.exec` calls `shell.run(command, cwd:, timeout:)`; `files.*` call `FileExecutor`; both executors are built per-run in `AgentLoop.init` from `contract.authority`. This switch is where environment routing goes. |
| `ShellExecutor` | `Tools/ShellExecutor.swift` | Runs `/bin/zsh -c` via `Process`. Its own doc comment says "What this is not: a sandbox." Has background-process support (`start`/`read`/`kill`). A parallel session is actively extending it — coordinate via small edits. |
| `ShellCommandParser` / `ShellFloor` | `Runtime/ShellCommandParser.swift`, `Runtime/ShellFloor.swift` | Deterministic parse + safety-floor judgment, runs *before* execution via `PermissionEngine`. Sandboxing is enforcement; this stays the judgment layer. Tests: `ShellFloorTests`. |
| `PermissionEngine` | `Runtime/PermissionEngine.swift` | Floor → authority → user rules → autonomy. Every decision traced with its reason. |
| Effects ledger | `Runtime/EffectLedger.swift` (added by parallel session) | Write-ahead journal of outward effects keyed by canonical arguments. **VERIFY-AT-IMPL:** whether the key includes the bot/environment; if not, the same command run on `.thisMac` and `.container` would collide. Add environment to the key derivation if absent. |
| Untrusted-content envelope | `Runtime/UntrustedContent.swift`; `shell.exec` output is wrapped | Container output must stay wrapped exactly the same way. |
| Trace | `Trace/TraceWriter.swift` | Already records `environment` in the run manifest. Add the container id (see 3.4). |
| Screen pane | `UI/ContextPanelView.swift` `ScreenPane` | Shows the last screenshot for `.thisMac`. Needs an honest headless state for `.container`. |
| Computers tab | `UI/LibrarySheet.swift` `ComputersList` | Currently: "Container … Soon". This is where install/status/GC UI goes. |
| Bot settings | `UI/ContextPanelView.swift` `BotSettingsPane` | Environment is `readOnly(...)` today; becomes a picker. Workspace picker already exists. |
| Live steps / notifications | `UI/BotRunner.swift` (`note`, `Notifier`) | Image pulls and container boots surface as live steps; nothing new needed. |
| Prior research | `docs/research/sandboxing-and-safety.md` (2026-08-29), `docs/research/giving-a-bot-its-own-computer.md` (2026-08-31) | Seatbelt verified working on this exact OS with a written profile; `apple/container` facts + 1.3.1 advisories; the four-option analysis this plan implements. Read both fully before starting. |

**External facts** (verified): macOS 26.5.2 arm64. `sandbox-exec` exists at
`/usr/bin/sandbox-exec` and a deny-default profile was proven to block writes and DNS on this
build. `apple/container` v1.3.x: installed by signed .pkg to `/usr/local`, needs macOS 26 +
Apple silicon, one lightweight VM per container. CLI (from `docs/command-reference.md` in the
apple/container repo, fetched 2026-08-31):

```
container system start | stop | status
container run [-d] [--name <n>] [--rm] [-v|--volume ...] [--mount ...] [-m|--memory <s>] [-c|--cpus <n>] <image> [args...]
container create <same as run, but stopped> ; container start [--attach] <id>
container exec [--env <e>] [--workdir <dir>] [--user <u>] [-i] [-t] <id> <args...>
container stop [--all] [--signal <s>] [--time <t>] [ids...]
container delete (rm) [--all] [--force] [ids...]
container list (ls) [--all] [--format json] [--quiet]
container logs [--follow] [-n <n>] <id>
container image pull [--platform <p>] <ref> ; container image list ; container image delete [--all]
```
**VERIFY-AT-IMPL:** exact `--volume` syntax (`host:guest` order and options) and whether
`container inspect` exposes the container's IP — check `container --help` output of the
installed version and `docs/networking.md`; the CLI is young and its flags may drift.

---

## 2. Phase 1 — Seatbelt: every `.thisMac` shell command runs in a kernel sandbox

### 2.1 What is being built

A Seatbelt profile generator plus wiring so that every command `ShellExecutor` runs is executed
as `/usr/bin/sandbox-exec -p <generated-profile> /bin/zsh -c <command>` — deny-by-default file
writes outside the bot's writable roots, network denied unless the bot's authority grants web.
This is **enforcement** for a policy the app already states (`contract.authority.writable`);
today that policy is judged (`ShellFloor`) but not enforced against a command that lies about
its paths at runtime (`P=$HOME; rm -rf "$P"` resolves after the parse).

### 2.2 Files

- **New:** `Sources/BotHarnessCore/Tools/Seatbelt.swift` — profile builder + self-test.
- **Modified:** `Tools/ShellExecutor.swift` (accept an optional `SandboxPolicy`, wrap the
  process invocation), `Runtime/AgentLoop.swift` (build the policy from the contract and pass
  it), `Trace` record for shell steps gains `sandboxed: Bool`.
- **New ADR:** "Shell commands on this Mac run inside Seatbelt" — copy the falsifier thinking
  from the research doc: DEPRECATED-but-working, used by Claude Code and Codex, isolate behind
  one module, startup self-test.
- **Tests:** `Tests/BotHarnessTests/SeatbeltTests.swift`.

### 2.3 Design, precisely

```swift
public struct SandboxPolicy: Sendable {
    public var writableRoots: [String]      // realpath'd absolute paths
    public var readOnlyCarveOuts: [String]  // e.g. <root>/.git — readable, not writable
    public var allowNetwork: Bool
    public var scratchDir: String           // per-run TMPDIR, always writable
}
```

Profile generation rules (start from Codex's `seatbelt_base_policy.sbpl`, Apache-2.0 — do not
write a base policy from scratch; the research doc §2 has the citation and the pattern):

- First line `(version 1)`, then `(deny default)`, then the base allows for system reads,
  process-exec, and the dyld/dev nodes the base policy enumerates.
- `(allow file-write* (subpath "<root>"))` per writable root; roots are
  `contract.authority.writable` with globs stripped, tilde-expanded, **realpath'd** (symlink
  through `/tmp` → `/private/tmp` is the classic profile-mismatch bug).
- After the allows: `(deny file-write* (subpath "<root>/.git"))` and the same for the app's
  own config dir — the agent must not rewrite history or its own permission rules. Deny wins
  when listed after an allow in SBPL — **VERIFY-AT-IMPL with a test**, this ordering rule is
  exactly the kind of thing to prove, not trust.
- Network: `(deny network*)` always present; when `allowNetwork`, instead allow outbound
  (`(allow network-outbound)` + `(allow system-socket)` per the base policy's shape).
- Always allow the per-run `scratchDir`, and pass `TMPDIR=<scratchDir>` in the child env —
  most build tools die without a writable temp.
- Escape every interpolated path for SBPL string syntax (quotes, backslashes). Property-test
  this: a path containing `"` must not become a profile injection.

Invocation: `Process` with launch path `/usr/bin/sandbox-exec` **hardcoded** (Codex's
anti-PATH-injection rule), args `["-p", profile, "/bin/zsh", "-c", command]`. Everything else
about `ShellExecutor` (timeouts, output caps, background handles) stays identical — the
sandbox wraps the leaf invocation only.

**Self-test at startup** (in `Seatbelt.swift`, called once from `BotRunner.init`): generate a
deny-all-writes profile, attempt `touch` of a forbidden path through it. If the write
*succeeds*, Seatbelt is broken on this OS → set a flag that (a) surfaces a one-time warning
banner and (b) records `sandboxed: false` in traces. **Do not silently continue claiming
sandboxed.** Do not disable the shell — degrading honestly beats bricking the app on an OS
update.

### 2.4 What Seatbelt does NOT cover — say so everywhere it matters

- In-process work: `URLSession` (web tools, brains), `FileExecutor`. Those are governed by
  authority checks, not the sandbox. No UI copy may say "everything is sandboxed".
- GUI computer-use. Runs as the logged-in user with TCC grants; cannot be seatbelted. Already
  documented in the research; keep the Computers tab copy honest.

### 2.5 Interactions that will break, and what to do about each

| Breaks | Why | Response |
|---|---|---|
| `brew install`, `npm i -g`, anything writing `/opt/homebrew`, `~/Library` | outside writable roots | Correct behaviour. The error must be honest: catch the `Operation not permitted` pattern in stderr and append one line: "blocked by the sandbox — this bot can only change files in <workspace>". Never auto-retry unsandboxed. Do not offer an unsandboxed path in v1; that is rule-writing territory, and a rule cannot lower the floor. |
| `git commit` hooks, `git config --global` | global config write | Hooks inside the repo work (workspace-writable). Global config writes fail; acceptable, honest error covers it. |
| `shell.start_process` (dev servers) | long-lived child | Profile applies for the child's lifetime — fine. Verify with a test that starts a server writing only to the workspace. |
| Anything reading outside `authority.readable` | Seatbelt base allows broad reads | Reads stay governed by the *existing* FileExecutor/ripgrep boundary checks; Seatbelt v1 constrains writes+network only. Tightening reads is a later, separate step — note it in the ADR as a known gap. |
| macOS update removes sandbox-exec | deprecated | The startup self-test catches it; behaviour defined above. |

### 2.6 Verification (run these, in this order)

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/bh-own --filter SeatbeltTests
# Manual, inside the app (scratch home, signed bundle):
#  1. bot workspace = /tmp/scratch-ws ; ask (or simulate) shell.exec: touch /tmp/scratch-ws/ok  → succeeds
#  2. shell.exec: touch /tmp/other/no → tool result contains "blocked by the sandbox"
#  3. shell.exec: curl https://example.com with web NOT granted → resolve failure, honest error
#  4. trace for the run shows sandboxed: true on shell steps
```
Unit tests to write (minimum): profile contains deny-default first; writable root realpath'd;
carve-out ordering proven effective (integration-style, actually exec through sandbox-exec —
these run fine un-gated, sandbox-exec needs no privileges); SBPL escaping property test; the
self-test detects a deliberately broken profile.

---

## 3. Phase 2 — the Container environment (`apple/container`)

### 3.1 Shape of the feature

Per-bot, persistent, headless Linux machine. Created lazily on first use, reused across runs,
destroyed with the bot. The agent does everything inside it through the tools it already has —
`shell.exec` (and start/read/kill), with the workspace visible at `/work`. `apt-get install`,
`pip install`, `make`, long-running servers: all just work, and all stay off the real Mac.

Decisions taken by this plan (revisit only with an ADR):

- **One container per bot**, named `bh-<first 12 hex of bot.id, lowercased>`. Derivable, no
  schema change, GC-able by prefix.
- **Default image `docker.io/library/debian:stable-slim`.** glibc (musl breaks Python wheels),
  `apt` present, order-100 MB unpacked. The agent installs what it needs itself — that IS the
  "does everything on its own" requirement; a fat pre-baked image spends disk this machine
  does not have. Blueprint-style pre-warm is a later optimisation (falsifier: users complain
  about first-run apt time).
- **The workspace is a bind mount**, host `bot.effectiveWorkspace` ↔ guest `/work`. Files
  tools keep running on the HOST against the workspace (they already enforce authority);
  nothing needs exec-based file IO. One path-translation function maps `/work/...` ↔ host
  workspace path for display, floor checks, and file-tool arguments the model writes with
  container paths.
- **Container lifetime = `container run -d --name bh-… --volume <ws>:/work -m 1g -c 2
  debian:stable-slim sleep infinity`**, then per-command `container exec --workdir /work
  bh-… /bin/sh -c <cmd>`. `sleep infinity` keeps it warm; memory/cpu caps are the guardrail
  against a runaway build eating the Mac.
- **Web tools stay host-side.** In-guest network exists (pip/apt need it) — that asymmetry is
  documented, not hidden: guest egress is unfiltered in v1 and the ADR must say so.
- **`computer.*` and `browser.*` refuse in `.container`** with an honest, routable error:
  "This bot's computer is headless — it has no screen. Switch this bot to This Mac for
  anything visual." (Exact copy; the model reads tool errors.)

### 3.2 Files

- **New:** `Sources/BotHarnessCore/Tools/ContainerRuntime.swift` — an `actor`:
  ```swift
  actor ContainerRuntime {
      static let binary = "/usr/local/bin/container"   // hardcoded, like sandbox-exec & claude
      enum Availability { case ready, notInstalled, systemStopped, brokenVersion(String) }
      func availability() async -> Availability        // stat binary; `container system status`
      func ensureSystemStarted() async throws          // `container system start` — VERIFY-AT-IMPL: admin needed?
      func ensureImage(_ ref: String, progress: (String) -> Void) async throws  // df check FIRST (≥2 GiB free or throw .diskFull), then pull
      func ensureContainer(for bot: Bot) async throws -> String                 // create-if-missing, start-if-stopped, returns name
      func exec(_ command: String, in name: String, timeout: TimeInterval) async -> CommandOutput
      func destroy(botID: UUID) async                  // stop --time 5, delete --force
      func collectGarbage(keeping bots: [Bot]) async   // ls --format json → delete bh-* without an owner
  }
  ```
  Every subprocess goes through the same output-cap/timeout treatment `ShellExecutor` uses —
  extract that into a shared helper rather than duplicating (coordinate with the parallel
  session; `ShellExecutor` is hot).
- **Modified:** `AgentLoop` — in the execute switch, `shell.*` and `git.*` route via
  `ContainerRuntime` when `bot.environment == .container`; `computer.*`/`browser.*` return the
  refusal above. `BotRunner` — owns one `ContainerRuntime`, calls `collectGarbage` at init and
  `destroy` inside the existing `discard(_:)`/delete path (this is the seam the bot-deletion
  flow already calls). Pull/boot progress → `note(.tool, "Preparing this bot's computer", …)`.
- **UI:** `ComputersList` (LibrarySheet) container card becomes stateful:
  `notInstalled` → explanation + "Get container…" button opening
  `https://github.com/apple/container/releases` (signed .pkg; the app cannot install it — an
  admin password is involved, and that is the user's act of trust, matching ADR 0002's spirit);
  `systemStopped` → "Start" button calling `ensureSystemStarted`;
  `ready` → status line + image cache size (`container image list`) + "Remove unused images".
  `BotSettingsPane` — environment becomes a two-option picker with the honest copy from
  `EnvironmentKind.explanation`; switching to `.container` when availability ≠ ready shows why
  inline and keeps `.thisMac` selected. `ScreenPane` — for `.container`, replace the empty
  state with "Headless computer — nothing to show. Shell work happens inside its Linux
  machine." (Do NOT leave the thisMac copy, which promises screenshots that cannot come.)
- **New ADR:** "The Container environment trusts the apple/container CLI" — trusted-binary
  decision, the 1.3.x advisory history, the explicit statement that in v1 the container is
  **isolation for accidents, not a security boundary against malicious code** (host-file-read
  bugs were patched days before this plan), egress unfiltered, falsifiers: a container-escape
  advisory while we ship it; Apple dropping macOS-26-only support.
- **Tests:** `ContainerRuntimeTests` (pure: name derivation, path translation both ways,
  argv construction, GC set arithmetic — no binary needed) + `ContainerLiveTests` gated on
  `BOTHARNESS_LIVE_CONTAINER=1` (availability → ensureImage(alpine, small!) → ensureContainer →
  exec echo → file written in guest `/work` appears in host workspace → destroy → gone).

### 3.3 Permission model inside the container — decided, with reasoning

The floor and rules run **unchanged**, with one substitution: `insideWorkspace` for a
container bot means "under `/work`" (after path translation). Deliberately conservative:
`rm -rf /` inside the container only kills the container, but v1 still asks — because (a) the
container is not yet a hardened boundary (see advisories), (b) the bind-mounted `/work` is
real host data either way, and (c) one permission model that is occasionally over-careful
beats two models the user has to reason about. Loosening in-container autonomy is a later ADR
with the security review to back it. The approval card for container commands gets one added
context line: "Runs inside this bot's Linux computer, not on your Mac." — users approving
should know the blast radius, in both directions.

`EffectLedger`: include the environment (and container name) in the effect key so identical
commands in different environments never dedupe against each other (**VERIFY-AT-IMPL** current
key composition first — see §1 table).

### 3.4 Traces & observability

Per-run manifest already records `environment`. Add `containerName` when applicable. Shell
steps inside the container record the translated command exactly as executed (`container exec
…` argv) in the step detail, while the summary stays the model's command — the trace answers
"what actually ran" without making the transcript unreadable.

### 3.5 Failure modes → defined behaviour (implement each; test the starred ones)

| Failure | Behaviour |
|---|---|
| ★ Binary missing when a `.container` bot runs | Tool error: "This bot's computer needs the container tool, which is not installed. Computers → Container explains the one-time install." Run continues (model can relay); no crash. |
| ★ `container system start` fails | Same routing to Computers tab, with stderr's first line included. |
| Disk < 2 GiB before pull | Refuse pull: "Not enough free disk to create this bot's computer (need ~2 GB free)." Never pull blind. |
| Pull interrupted (network) | `ensureImage` retries once, then honest failure. Partial layers are the CLI's problem, but VERIFY-AT-IMPL that a re-pull recovers. |
| ★ Container dies mid-exec (exit 255 / "not running") | One `ensureContainer` retry (restart), then fail the tool call. The interrupted-work reconciliation from ADR 0013 already covers app-death; this covers container-death. |
| Bot deleted while its container runs a command | `discard` path calls `destroy`; exec returns error; loop's normal tool-failure path handles it. |
| App relaunch | Containers keep existing (cheap, stopped or sleeping); GC at `BotRunner.init` removes only ownerless `bh-*`. |
| Workspace moved/renamed while container exists | Mount is stale → recreate container when `effectiveWorkspace` differs from the mount recorded at creation (keep the created-with path in an in-memory map + verify via `container inspect`; **VERIFY-AT-IMPL** inspect output shape). |
| CLI flag drift on upgrade | `availability()` parses `container --version`; live tests catch drift; failures surface stderr rather than guessing. |

### 3.6 Disk budget (hard numbers, enforce in code)

Base image ~100–250 MB unpacked + per-container writable layer (grows with `apt-get`).
Guardrails: refuse pull under 2 GiB free; Computers tab shows image-cache size with a delete
button; `collectGarbage` on every launch; cap containers by capping bots (no extra limit in
v1). CLAUDE.md's "1.4 GB free" is stale — re-run `df -h /` yourself and act on what you see.

---

## 4. Phase 3 — deferred, with tripwires (do NOT build now)

- **A screen of its own, locally** — `Virtualization.framework` Linux VM with a desktop,
  captured and driven by the app (Grok Bot's architecture, on-device; farzaa/clicky is prior
  art for the host-side observe-and-point UX). Blocked by disk (2–4 GB image) and by being the
  largest engineering item in the product. Tripwire to revisit: >10 GiB free AND a user asking
  for computer-use isolation.
- **Cloud desktop opt-in** — E2B Desktop (`e2b-dev/desktop`: Ubuntu+XFCE, VNC stream, mouse/
  keyboard/screenshot SDK) or Daytona. Zero local disk, real screen, but it is the design this
  product exists to answer; if ever built: explicit opt-in environment, key from
  `CredentialStore`, UI copy "their computer, not yours". Tripwire: users choosing Grok Bot
  over this app specifically for disposable desktops.

## 5. Cross-breakage matrix — "what does fixing X break?"

| Change | Can break | Guard |
|---|---|---|
| Seatbelt wrapping in `ShellExecutor` | `files.search` (`rg` through shell), self-describe, background processes | `rg` reads only → unaffected by write-deny, but IS affected if you later deny reads — do not. Brain calls are in-process URLSession — unaffected (test: self-describe with sandbox on). `shell.start` inherits profile — covered by dev-server test. |
| Routing `git.*` into container | `git.status` diffing against host state assumptions elsewhere in the loop | Search `AgentLoop` for other host-path `git` uses before switching; keep `git.*` host-side in v1 if any exist (they operate on the mounted workspace either way — host-side is the safe default; **decide at impl and record in the ADR**). |
| Path translation | `ShellFloor` workspace checks, approval-card detail text, effect keys | One translation function, used by all three; property test: translate∘translate == identity. |
| `ensureSystemStarted` at launch | Launch latency, admin prompts at the wrong moment | Never auto-start at app launch; start lazily on first container use, from an explicit user path when possible. |
| GC deleting containers | A second Mac user's containers, or a parallel dev instance's | GC filters strictly by `bh-` prefix AND absence from the current store; scratch-home test instances use the same store they GC against — safe. |
| New env fields in trace | Trace hash chain (append-only schema) | Additive JSON keys only; `TraceReader` ignores unknowns — verify with an old trace fixture. |
| Editing `EnvironmentKind` | Codable of every stored bot | Do not rename cases; additions only (same rule ADR 0013 set). |

## 6. Security guardrails — the checklist the ADRs commit to

1. Nothing from `CredentialStore` ever enters a container: not as env, not as mount, not in
   the image. Test: exec `env` in a live container, assert no key material.
2. Only `effectiveWorkspace` is ever mounted. Never `~`, never `/`. Assert in
   `ensureContainer` (refuse `/`, `/Users`, `$HOME` as workspace for container bots — reuse
   `ShellFloor.isRootOrHome`-style list).
3. Container stdout/stderr is untrusted content — same envelope as host shell output (§1).
4. The floor is never weaker inside the container (§3.3), and approval cards disclose where a
   command runs.
5. Seatbelt self-test failure is loud and recorded; the app never claims a sandbox it does not
   have (mirrors `ShellSandboxUnsupported` honesty from the Grok Bot teardown).
6. `sandbox-exec` and `container` binaries by absolute path only.
7. Sandbox denials are never auto-escalated to unsandboxed retries — not by code, and there is
   no tool that does it, so a prompt-injected "retry outside the sandbox" has nothing to call.
8. GC never deletes by name pattern alone without the store cross-check (defence against a
   hostile container naming itself `bh-…`? it cannot — names are assigned by us — but the
   cross-check also protects reinstalls with a fresh store: **it deletes ownerless `bh-*`, so
   document that a wiped store orphans then reaps containers — acceptable, they are cattle**).

## 7. Acceptance criteria (the implementing session's definition of done)

Phase 1: all SeatbeltTests green; the four manual checks in §2.6 pass in the signed bundle
against a scratch home; traces show `sandboxed: true`; CHANGELOG + ADR written; no view claims
more than the sandbox does.

Phase 2: `swift test` fully green with the live suite skipped; live suite green on a machine
with `container` installed (record its version in the test log); a `.container` bot can — via
the transcript alone — `apt-get install python3`, write & run a script in `/work`, results
visible in the host workspace folder; deleting that bot removes its container (`container ls
--all` clean); Computers tab shows all three availability states correctly (fake by renaming
the binary); every failure mode row in §3.5 marked ★ demonstrated once; CHANGELOG + ADR
written; the audit-era rule holds: no dead buttons, no state that lies.

## 8. Known traps for the implementing LLM (all personally paid for)

- zsh does not word-split unquoted variables — `for s in $sizes` iterates once. Quote and
  split explicitly in test scripts.
- `Process` + pipes: read both fds concurrently or big outputs deadlock (existing
  `ShellExecutor` pattern is correct — copy it).
- SBPL wants POSIX real paths; run every root through `realpath` or `URL.resolvingSymlinksInPath`.
- The signed-bundle requirement is load-bearing (TCC identity). `swift run` will mislead you
  about permissions and windows.
- Screenshot-based verification: capture by window id; the user's real cursor hovers rows and
  ruins "is this the selected state" reads — prefer reading state from fixtures + AX dumps
  (`menus.swift` pattern in the scratchpad) over pixels where possible.
- When the shared `.build` breaks mid-build with "input file modified": it is the parallel
  session; wait 15 s and retry, or use the scratch path (§0.5).
