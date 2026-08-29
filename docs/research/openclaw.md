# OpenClaw (ex-Clawdbot, ex-Moltbot) — architecture, permission model, and what a Mac-native computer-use harness should borrow

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

OpenClaw is real, active, and enormous: github.com/openclaw/openclaw, TypeScript, MIT, 387,965 stars and 81,469 forks, last pushed 2026-08-29 (today). But two assumptions in the brief need correcting. First, it is no longer Peter Steinberger's project in any operational sense — the LICENSE is held by the "OpenClaw Foundation" and Steinberger has been at OpenAI since February 2026. Second, OpenClaw is messaging-first, not computer-use-first: computer control is an optional node capability (`computer.act`) that is off by default and, on macOS, is implemented by delegating to a separate Swift project called Peekaboo. For Bot-Harness the genuinely valuable find is Peekaboo (openclaw/Peekaboo, Swift 6.2, MIT, macOS 15+, 5,073 stars) — a native CLI plus MCP server whose observe-then-act loop (`peekaboo see --app Safari --json` returns a structured UI map with opaque element IDs, then `click`/`type`/`press` against those IDs) is exactly the primitive a Mac-native harness needs, and it builds with Swift Package Manager rather than requiring full Xcode. The second thing worth stealing is OpenClaw's policy architecture — four named session permission modes, a metadata-only SQLite audit ledger, and the rule that denial is structural rather than something the model is asked to honor. The security record is the cautionary half: 647 published GitHub advisories in five months, including a CVSS 8.8 one-click remote code execution (CVE-2026-25253) that leaked the gateway token from a URL query parameter.

## Recommendation

Do not build Bot-Harness on OpenClaw. It is a messaging-first gateway whose product surface (pair a WhatsApp number, chat with your assistant from your phone) is orthogonal to a local Mac app with a task list, a conversation pane, and a live computer view. Adopting it would import a 3 GB TypeScript monorepo, an in-process plugin system with full process trust, and a security record of 647 advisories in five months — for a solo developer that is unmanageable attack surface.

Instead, take three things.

Take Peekaboo outright. It is the Mac-native computer-use layer, already MIT-licensed Swift 6.2 that builds under SwiftPM without full Xcode, already handling the two hard parts: TCC permission onboarding for Screen Recording and Accessibility, and addressing UI elements by opaque IDs from an accessibility-tree snapshot rather than raw pixel coordinates. Its observe-then-act contract — `see --json` produces the element map, actions reference IDs from that map — is a better agent loop than screenshot-and-guess-coordinates, and its distinction between background input delivery (allowed with an exact window selector plus a fresh snapshot) and foreground chords (requires explicit consent) is a permission boundary you should copy verbatim rather than reinvent. Start by shelling out to the CLI; move to linking the Swift sources only if you need lower latency.

Take the policy architecture, not the code. Three ideas transfer directly: (1) denial is structural — a read-only session must physically not construct the write tools, never a system-prompt instruction the model is asked to respect; (2) four named permission modes rather than a per-tool boolean matrix, so the user picks one legible thing and you resolve the tool set from it; (3) a metadata-only audit ledger in SQLite recording started/finished events with identity and outcome but never arguments or output — this satisfies your "log every decision for future agents to audit" requirement while keeping the log itself from becoming a secrets store.

Take the exposure model. Bind loopback only, require auth by default, and treat every inbound token as attacker-reachable. Specifically: never accept a gateway or server URL from a URL query parameter, deep link, or any external input without an explicit user confirmation step — that exact mistake is CVE-2026-25253, and it was exploitable against loopback-only instances because the victim's own browser made the outbound connection.

Leave behind: the channel layer (you have no WhatsApp/Telegram requirement), the Docker sandbox (a Mac-native app should use Apple's own sandbox and TCC, and OpenClaw notably has no seatbelt path at all), the in-process plugin model, and the pairing/multi-device scope system, which is where most of their critical privilege-escalation advisories cluster.

## Risks

- Security track record is the dominant risk signal, and it is quantified: 647 published advisories between 2026-01-31 and 2026-06-30 — 14 critical, 219 high, 350 medium, 64 low. These are not exotic bugs; the recurring themes are privilege escalation from a low scope to operator.admin, approval bypasses, and sandbox escapes. Any code lifted from this repo should be treated as unaudited.
- CVE-2026-25253 (CVSS 8.8) is the single most instructive failure for Bot-Harness: the Control UI auto-connected to whatever `gatewayUrl` appeared in the query string and sent the stored token in the connect payload. Loopback binding did not help, because the victim's browser initiated the outbound connection. If Bot-Harness ever exposes a local web UI, this is the exact bug to design against.
- CVE-2026-26320: "OpenClaw macOS deep link confirmation truncation can conceal executed agent message." A confirmation dialog that truncates the action text is worse than no dialog, because it launders consent. Any approval UI in Bot-Harness must show the complete command or be scrollable, and must never elide.
- Sandboxing is off by default (`agents.defaults.sandbox.mode: "off"`) and is Docker/Podman-only. There is no Apple seatbelt or sandbox-exec path. On a Mac-native app you cannot inherit their isolation story — you would be relying on Docker Desktop for containment, which is heavy, and the Gateway process itself is never sandboxed regardless.
- Native plugins load in-process via `require` with full process-level trust; the only defenses are the `plugins.allow` allowlist and path pinning. Two published advisories cover plugin-install policy bypass (GHSA-wgq8-x5wm-g4rw, GHSA-7vrr-rp4x-4g76) plus a critical path traversal in plugin installation (GHSA-qrq5-wjgg-rvqw). Do not copy this extension model.
- The docs are explicit that the design assumes a single operator or a mutually-trusting team, and that exec approvals are "guardrails for operator intent, not hostile multi-tenant isolation." For a solo-developer app that assumption actually holds — but it means none of their controls were designed to withstand a genuinely adversarial model, only a confused one.
- Velocity and churn: the project renamed twice in under three months (Clawdbot → Moltbot → OpenClaw), was pushed to today, and ships beta tags weekly (2026.9.1-beta.1 five days ago). Any API you pin against will move. This argues for shelling out to Peekaboo's stable CLI surface rather than linking against OpenClaw internals.
- Governance changed hands. The original author is at OpenAI and the copyright sits with the OpenClaw Foundation. Design decisions and security response now come from a foundation and maintainer group, not the person whose reputation the brief is anchored on.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- CORRECTION to the brief: OpenClaw is no longer "the open-source personal AI assistant project by Peter Steinberger" in any current sense. The LICENSE is held by the OpenClaw Foundation, and Steinberger's own site states he has been at OpenAI since February 2026. He created it; he does not run it. Treating it as a Steinberger project will lead you to the wrong maintainers and the wrong support channels.
- CORRECTION to the brief's framing: OpenClaw is messaging-first, not a computer-use agent. Computer control is an opt-in node capability that is not in the default tool set, and on macOS it is delegated to Peekaboo. The brief's implicit premise — that OpenClaw is a computer-use system to learn from — is only true one layer down, in Peekaboo.
- Rename chain Clawdbot → Moltbot → OpenClaw: the Clawdbot leg is confirmed from a primary source (GHSA-g8p2-7wf7-98mq lists the vulnerable npm package as `clawdbot` at <= 2026.1.28). The Moltbot leg is corroborated by multiple third parties (awesome-openclaw's repo description, Kaspersky, SecurityScorecard) but I did not fetch a first-party OpenClaw page that states it. Confidence: high, but one step short of primary.
- GitHub's license API reports spdx_id NOASSERTION / "Other" for openclaw/openclaw while the LICENSE file is verbatim MIT and npm metadata says MIT. I am confident it is MIT, but if license provenance matters for anything you ship, read the file yourself rather than trusting the API field.
- Could not verify the macOS daemon mechanics. https://docs.openclaw.ai/gateway/daemon and https://docs.openclaw.ai/install/macos both returned 404, and /gateway/background-process turned out to document the agent's `exec`/`process` tools rather than service installation. I therefore have NO verified launchd plist label, plist path, or service log path — only that `openclaw onboard --install-daemon` and `openclaw gateway install` exist as commands. If the launchd pattern matters for Bot-Harness, inspect a real install.
- CVE-2026-25253 does not appear in openclaw/openclaw's own repository advisory list; I found it in the global GitHub Advisory Database as GHSA-g8p2-7wf7-98mq. The repo-level advisory list starts 2026-01-31 and the CVE was published 2026-02-02, so this is likely because it was filed under the pre-rename `clawdbot` package. Minor provenance oddity, not a contradiction.
- Peekaboo version drift: the README on main describes "What's new in 4.2.3" but the latest tagged GitHub release is v4.2.2 (2026-08-20) and npm latest is 4.2.2. The README is ahead of the shipped release. Do not assume 4.2.3 features are available in the DMG or the npm package.
- I did not verify the Peekaboo build actually works on this machine's configuration — macOS 26.5, Apple Silicon, Command Line Tools only, no full Xcode. The README states macOS 15+ and Swift 6.2+ and uses SwiftPM via pnpm scripts, which is compatible in principle with a CLT-only setup, but a signed-app build or anything requiring xcodebuild would not be. This needs a hands-on test before you commit to the dependency.
- The claim that OpenClaw is "the fastest-growing project in GitHub history" and figures like "200K stars" or "64,048 commits" come from search-result summaries and third-party blogs, not sources I fetched. The only star count I verified directly is 387,965 from the GitHub API today.
- Third-party security reporting I saw in search results but did not fetch or verify: Hunt.io's claim of 17,500+ instances vulnerable to CVE-2026-25253, SecurityScorecard's exposed-control-panel counts, and the "Moltbook breach" referenced by adversa.ai. Directionally consistent with the advisory record, but treat the specific numbers as unconfirmed.

## Verified facts

- The project's current identity is the GitHub organization `openclaw`, repo `openclaw/openclaw`, described as "Your own personal AI assistant. Any OS. Any Platform. The lobster way." Language TypeScript; 387,965 stars; 81,469 forks; 5,703 open issues; created 2025-11-24T10:16:47Z; pushed_at 2026-08-29T13:20:20Z; archived=false; homepage https://openclaw.ai  
  — **confirmed** · <https://api.github.com/repos/openclaw/openclaw>
- License is MIT, but the copyright line reads "Copyright (c) 2026 OpenClaw Foundation" — not Peter Steinberger. GitHub's license API reports spdx_id NOASSERTION / "Other" because the LICENSE file appends a line pointing at THIRD_PARTY_NOTICES.md; the npm package metadata correctly reports `"license": "MIT"`.  
  — **confirmed** · <https://raw.githubusercontent.com/openclaw/openclaw/main/LICENSE>
- Peter Steinberger no longer runs the project. His own about page: "I made OpenClaw — the open-source personal AI agent that became GitHub's most-starred software project", that it is now managed by "the independent OpenClaw Foundation" (openclaw.org), and "Since February 2026 I'm at OpenAI, working on bringing agents to everyone."  
  — **confirmed** · <https://steipete.me/about>
- Current npm dist-tags for the `openclaw` package: latest = 2026.7.1-2, extended-stable = 2026.6.34, beta = 2026.9.1-beta.1, alpha = 2026.5.19-alpha.1. Binary is `openclaw` → `openclaw.mjs`. Node engine constraint is exactly `>=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0`.  
  — **confirmed** · <https://registry.npmjs.org/openclaw>
- The Gateway is a single always-on process exposing one multiplexed port, default 18789. It serves WebSocket control/RPC plus HTTP endpoints `/v1/models`, `/v1/embeddings`, `/v1/chat/completions`, `/v1/responses`, and `/tools/invoke`. Port precedence is `--port` flag → `OPENCLAW_GATEWAY_PORT` → `gateway.port` config key → 18789. Default bind is loopback via `gateway.bind`. Auth is required by default (`gateway.auth.token` / `gateway.auth.password`, or `OPENCLAW_GATEWAY_TOKEN` / `OPENCLAW_GATEWAY_PASSWORD`).  
  — **confirmed** · <https://docs.openclaw.ai/gateway>
- The wire protocol is WebSocket on 127.0.0.1:18789. Clients send an initial `connect` frame and receive `hello-ok` with a state snapshot. Request/response/event frames are `{type:"req", id, method, params}`, `{type:"res", id, ok, payload|error}`, `{type:"event", event, payload}`. Nodes (macOS/iOS/Android/headless devices) connect to the same WebSocket server but declare `role: node` with explicit capabilities and commands. Side-effecting methods require idempotency keys.  
  — **confirmed** · <https://docs.openclaw.ai/concepts/architecture>
- Config is a single JSON5 file at `~/.openclaw/openclaw.json`, overridable with `OPENCLAW_CONFIG_PATH` (must point at the real file, not a symlink). CLI surface: `openclaw onboard`, `openclaw configure`, `openclaw config get <path>`, `openclaw config set <path> <value>`, `openclaw config validate`. Config reload defaults to `gateway.reload.mode="hybrid"` — atomic when safe, restart when not.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/configuration>
- Computer use exists but is an optional node capability, not the core product. The built-in `computer` tool executes one node command, `computer.act`, supporting screenshot, click, drag, mouse move, scroll, keyboard text/combos, delays, and advanced window/element/accessibility-tree families. On macOS the default backend is Peekaboo (CUA is the alternative). It requires macOS Accessibility and Screen Recording granted to OpenClaw plus "Allow Computer Control" in app settings, and must be enabled by adding `"computer"` to `tools.alsoAllow`. It can be hard-denied with `gateway.nodes.commands.deny: ["computer.act"]`.  
  — **confirmed** · <https://docs.openclaw.ai/nodes/computer-use>
- Peekaboo is a separate repo now living under the same org: openclaw/Peekaboo — Swift, MIT, 5,073 stars, pushed 2026-08-29, not archived. It is a macOS CLI and menu-bar app for screen capture, accessibility inspection, and native UI automation, and it can expose the same toolset over MCP. Requires macOS 15+; source builds need Swift 6.2+ and Node 22+. Latest tagged release is v4.2.2 (2026-08-20) shipping a signed DMG.  
  — **confirmed** · <https://api.github.com/repos/openclaw/Peekaboo>
- Peekaboo's core loop is observe-then-act against opaque element IDs: `peekaboo see --app Finder --json` returns "a structured UI map with opaque element IDs", then actions target those. Command map: observe (`see`, `screen list`, `window list`), interact (`click`, `type`, `press`, `scroll`, `drag`, `set-value`, `action`), control macOS (`app`, `window`, `menu`, `menubar`, `dock`, `dialog`, `space`), workflows (`agent`, `capture`), integrate (`mcp`, `browser`, `tools`). Config lives under `~/.peekaboo`. Notably, targeted input uses background delivery so the app need not be frontmost; app/PID-only and targetless chords require explicit foreground consent.  
  — **confirmed** · <https://raw.githubusercontent.com/openclaw/Peekaboo/main/README.md>
- Sandboxing is container-based only — Docker (default), Podman, SSH, or OpenShell. There is no Apple seatbelt / sandbox-exec / bubblewrap path. Defaults: `agents.defaults.sandbox.mode` = `off`, `.scope` = `agent`, `.backend` = `docker`, `.workspaceAccess` = `none`, `.docker.network` = `"none"`, image `openclaw-sandbox:bookworm-slim`, `readOnlyRoot: true`, `capDrop: ["ALL"]`. The Gateway process itself is never sandboxed.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/sandboxing>
- There are exactly four session permission modes: `read-only` (reads under sessionRoot, mutation tools omitted, exec denied), `guarded` (read/write under sessionRoot, human review after an allowlist fast path), `workspace` (read/write under sessionRoot, LLM review with human fallback), and `full` (unrestricted filesystem, no review). `full` requires the `operator.admin` scope; the other three require `operator.write`.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/permission-modes>
- The stated architectural thesis is trusted gateway / untrusted execution / deterministic policy, with the key line: "Denial is structural, not a request the model is asked to honor; approval paths fail closed." Tools are gated by configuration rather than by prompt — a `read-only` session physically omits `edit`, `write`, and `apply_patch` rather than instructing the model not to use them.  
  — **confirmed** · <https://docs.openclaw.ai/start/why-openclaw>
- The Gateway keeps a bounded, metadata-only audit ledger in `state/openclaw.sqlite` with 30-day retention and a 100,000-row cap. It records `tool.action.started` and `tool.action.finished` by default and never stores prompts, message bodies, tool arguments, tool results, attachments, filenames, URLs, command output, or raw error text. Controlled by `logging.audit.executionIdentity` and `logging.audit.messages` (`off` default, `direct`, `all`); queried with `openclaw audit --execution <id> --explain` and `openclaw audit --run <id> --explain`.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/audit>
- Operational logs are separate from the audit ledger: JSON-lines rolling files under `/tmp/openclaw/`, named `openclaw-<profile>-YYYY-MM-DD.log`. Config keys `logging.level`, `logging.file`, `logging.consoleLevel` (default `info`), `logging.consoleStyle` (`pretty`|`json`), `logging.redactPatterns`, `logging.maxFileBytes` (default 100 MB). Read with `openclaw logs --follow`.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/logging>
- OpenClaw is both an MCP server and an MCP client. `openclaw mcp serve` exposes channel conversations over MCP to external clients such as Claude Code. As a client it supports stdio (`command`, `args`, `env`, `cwd`), SSE/HTTP, and streamable HTTP, configured under `mcp.servers.<name>` with `url`, `headers`, `auth`, `sslVerify`, `clientCert`, `clientKey`, `requestTimeoutMs`, `connectionTimeoutMs`, `supportsParallelToolCalls`, `toolFilter`.  
  — **confirmed** · <https://docs.openclaw.ai/cli/mcp>
- Skills follow the AgentSkills spec — a directory containing `SKILL.md` with YAML frontmatter (`name`, `description`, plus optional `user-invocable`, `disable-model-invocation`, `command-dispatch: "tool"`, `command-tool`, `homepage`). Discovery goes 6 levels deep. Precedence highest-to-lowest: `<workspace>/skills`, `<workspace>/.agents/skills`, `~/.agents/skills`, `<state-dir>/skills`, bundled, then `skills.load.extraDirs`. Load-time gating uses a `metadata.openclaw` JSON5 block with `requires.bins`, `requires.anyBins`, `requires.env`, `requires.config`, `os`, `always`, `primaryEnv`.  
  — **confirmed** · <https://docs.openclaw.ai/tools/skills>
- Plugins use an `openclaw.plugin.json` manifest and register through typed methods on `OpenClawPluginApi`: `api.registerProvider`, `api.registerSpeechProvider`, `api.registerEmbeddingProvider`, `api.registerMediaUnderstandingProvider`, `api.registerImageGenerationProvider`, `api.registerWebSearchProvider`, `api.registerChannel`, `api.registerRealtimeTranscriptionProvider`, `api.registerCliBackend`. Critically, native plugins run in-process with full process-level trust — the only controls are the `plugins.allow` allowlist and `plugins.load.paths`.  
  — **confirmed** · <https://docs.openclaw.ai/plugins/architecture>
- CVE-2026-25253 / GHSA-g8p2-7wf7-98mq, CVSS 8.8 high, published 2026-02-02: the Control UI trusted the `gatewayUrl` query-string parameter without validation and auto-connected on page load, sending the stored gateway token in the WebSocket connect payload. Visiting a crafted link exfiltrated the token, letting an attacker connect to the victim's local gateway, modify config (sandbox, tool policies) and reach RCE — exploitable even on loopback-only instances because the victim's own browser makes the outbound connection. Affected npm package was named `clawdbot`, versions <= 2026.1.28, first patched 2026.1.29.  
  — **confirmed** · <https://api.github.com/advisories/GHSA-g8p2-7wf7-98mq>
- The repository has published 647 GitHub security advisories between 2026-01-31 and 2026-06-30: 14 critical, 219 high, 350 medium, 64 low. Titles show systemic classes of failure rather than one-offs — e.g. GHSA-4jpw-hj22-2xmc "Pairing-scoped device tokens could mint `operator.admin` and reach node RCE", GHSA-9hjh-fr4f-gxc4 "Gateway Backend Reconnect lets Non-Admin Operator Scopes Self-Claim operator.admin", GHSA-8rh7-6779-cjqq "CWD `.env` environment variable injection bypasses host-env policy", GHSA-9p3r-hh9g-5cmg "Sandbox escape via TOCTOU race in remote FS bridge readFile", and CVE-2026-25593 "Unauthenticated Local RCE via WebSocket config.apply".  
  — **confirmed** · <https://api.github.com/repos/openclaw/openclaw/security-advisories>
- Directly relevant to designing an approval dialog: CVE-2026-26320 / GHSA-7q2j-c4q5-rm27 (high, 2026-02-15) is titled "OpenClaw macOS deep link confirmation truncation can conceal executed agent message" — the confirmation UI truncated the text so the user approved something other than what ran.  
  — **confirmed** · <https://api.github.com/repos/openclaw/openclaw/security-advisories>
- The documented security model is explicit that it is not multi-tenant: "OpenClaw is not a hostile multi-tenant security boundary for mutually adversarial users sharing one agent or gateway", and exec approvals are "guardrails for operator intent, not hostile multi-tenant isolation". It also states `sessionKey` is "a routing selector, not an authorization token". Secrets live in `~/.openclaw/` (`openclaw.json`, `credentials/**`, `state/openclaw.sqlite`) with recommended 700/600 permissions. `openclaw security audit` (with `--deep` and `--fix`) is the built-in posture check.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/security>
- The macOS app is a menu-bar companion distributed as `OpenClaw-<version>.dmg` from GitHub releases; it installs the matching CLI runtime on first launch. It provides a Spotlight-style Quick Chat on ⌥Space, native chat with image attachments, the `system.run` Mac node tool, camera/screen capture, notifications, and location. It requests macOS permission prompts for Screen capture, Microphone, Speech, Automation, and Accessibility, managed under Settings → Permissions. It runs either Local (bundled Gateway on the same Mac) or Remote (another host's Gateway over SSH, LAN, or Tailnet).  
  — **confirmed** · <https://docs.openclaw.ai/platforms/macos>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | reference-only — the product shape is chat-in-your-existing-messenger, not a Mac-native computer-use app, and it is 3 GB of TypeScript with 647 advisories in five months. Read its Gateway protocol, permission modes, and audit ledger designs; do not take the code or the dependency surface. | Messaging-first personal AI assistant. A single always-on TypeScript Gateway process owns config, credentials, channel connections (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, Matrix, and ~40 more) and a typed WebSocket control-plane API on 127.0.0.1:18789. Clients (macOS menu-bar app, CLI, TUI, Control UI) and Nodes (devices offering local capabilities) connect to the same socket. Extended by plugins (openclaw.plugin.json) and skills (SKILL.md). | 387,965 | MIT (LICENSE file; GitHub API reports NOASSERTION because of an appended third-party-notices line) | pushed 2026-08-29 (same day as this research) |
| [openclaw/Peekaboo](https://github.com/openclaw/Peekaboo) | adopt or evaluate closely — this is the single most useful artifact for Bot-Harness. Swift 6.2, MIT, macOS 15+, builds with SwiftPM (no full Xcode needed), and it already solves the permission onboarding, element-ID addressing, and background-vs-foreground input consent problems you would otherwise spend weeks on. Shell out to the CLI, wire it over MCP, or vendor the Swift sources. | Native macOS screen capture, accessibility inspection, and UI automation. Ships a Swift CLI (`peekaboo`), a menu-bar app with permission onboarding and visual feedback, and an MCP server exposing the same tools. Core loop is `see` (returns a JSON UI map with opaque element IDs) then `click` / `type` / `press` / `scroll` / `drag` against those IDs, plus `app`, `window`, `menu`, `menubar`, `dock`, `dialog`, `space` for OS-level control. Targeted input can be delivered to a background window without bringing the app frontmost. | 5,073 | MIT | pushed 2026-08-29; latest tagged release v4.2.2 on 2026-08-20 |
| [SamurAIGPT/awesome-openclaw](https://github.com/SamurAIGPT/awesome-openclaw) | reference-only — useful as a naming/ecosystem cross-check, no engineering value. | Community index of OpenClaw resources, tools, skills, and tutorials. Its own description is the clearest single confirmation of the rename chain: "OpenClaw (formerly Moltbot / Clawdbot)". | not fetched | not fetched | not fetched |

## API and code shape

INSTALL (macOS), copied verbatim from the README:

  # macOS / Linux / WSL2
  curl -fsSL https://openclaw.ai/install.sh | bash

  # or, if you manage Node yourself (Node 22.22.3+, 24.15+, or 25.9+):
  npm install -g openclaw@latest --allow-scripts=openclaw
  # (--allow-scripts is npm 12 / npm 11.16+ only; omit on npm 11.15 and earlier)

  openclaw onboard --install-daemon
  openclaw gateway status
  openclaw dashboard

NOTE for this machine: the engines field is exactly
  "node": ">=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0"
so Node 24 must be >= 24.15.0.

GATEWAY OPERATIONS:
  openclaw gateway status --json --deep
  openclaw gateway install | restart | stop
  openclaw secrets reload
  openclaw channels status --probe
  openclaw security audit --deep --fix
  openclaw logs --follow
  openclaw audit --execution <id> --explain
  openclaw audit --run <id> --explain
  openclaw pairing approve <channel> <code>
  openclaw plugins enable cua-computer

CONFIG — JSON5 at ~/.openclaw/openclaw.json (override with OPENCLAW_CONFIG_PATH).
Documented secure baseline:

  {
    gateway: {
      mode: "local",
      bind: "loopback",
      auth: { mode: "token", token: "your-long-random-token" }
    },
    channels: {
      whatsapp: {
        dmPolicy: "pairing",
        groups: { "*": { requireMention: true } }
      }
    }
  }

SANDBOX DEFAULTS (all under agents.defaults.sandbox):
  mode: "off"          scope: "agent"        backend: "docker"
  workspaceAccess: "none"                    docker.network: "none"
  image: openclaw-sandbox:bookworm-slim      readOnlyRoot: true    capDrop: ["ALL"]

COMPUTER USE — enable/deny:
  tools.alsoAllow: ["computer"]                     // and tools.sandbox.tools.alsoAllow for sandboxed agents
  gateway.nodes.commands.deny: ["computer.act"]     // hard kill switch

GATEWAY WS FRAMES:
  client → {type:"req", id, method, params}
  server → {type:"res", id, ok, payload|error}
  server → {type:"event", event, payload}
  handshake: client sends `connect`, server replies `hello-ok` with snapshot + policy limits
  nodes connect to the same socket declaring role: node

PEEKABOO (the part worth stealing):
  brew install steipete/tap/peekaboo
  npx -y @steipete/peekaboo --version          # npm pkg is @steipete/peekaboo, latest 4.2.2, MIT

  peekaboo permissions status
  peekaboo see --no-elements --mode screen --path /tmp/peekaboo-screen.png
  peekaboo see --app Finder --json             # structured UI map with opaque element IDs

  peekaboo window list --app Safari --json
  peekaboo click "Address and search bar" --app Safari --window-id 12345
  peekaboo type "github.com/openclaw/Peekaboo" --app Safari --window-id 12345
  peekaboo press Return --app Safari --window-id 12345

  peekaboo agent "Open Safari, go to github.com, and search for Peekaboo" --allow-foreground

  Peekaboo source build: pnpm install --frozen-lockfile && pnpm run build:cli
  (macOS 15+, Swift 6.2+, Node 22+, repo submodules)

AUDIT LEDGER:
  openclaw config set logging.audit.executionIdentity true
  openclaw gateway restart
  logging.audit.messages: "off" | "direct" | "all"
  events: tool.action.started, tool.action.finished
  storage: state/openclaw.sqlite, 30-day retention, 100,000-row cap
