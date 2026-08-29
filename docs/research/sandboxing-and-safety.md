# Sandboxing and the safety kernel for Bot-Harness: a Mac-native agent that runs shell commands and controls macOS 26.5 on Apple Silicon

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The safety kernel you want already exists as a well-trodden pattern and you can build it today: `sandbox-exec` (Seatbelt) is present and fully functional on macOS 26.5 — I wrote a profile, ran it locally, and confirmed it blocks writes outside an allowed subpath and blocks DNS/network entirely — and it is exactly what both Claude Code and Codex CLI use for their macOS sandboxes, despite the man page saying "DEPRECATED". Apple's `container` CLI is real, at 1.3.1, Apache-2.0, macOS 26 and Apple-Silicon only, one lightweight Linux VM per container, but it is a Linux-workload tool, not a way to sandbox the Mac GUI your agent is driving — and its 1.3.1 release notes (published today, 2026-08-29) patch six Containerization security advisories including host-file reads and path traversal, so it is not yet a hardened security boundary. The real architectural split for Bot-Harness is that shell commands can be confined by Seatbelt, but GUI computer-use (clicking, typing, screenshots) cannot: those actions run as your logged-in user with Accessibility and Screen Recording TCC grants, so for that half the only kernel is a permission/approval layer plus prompt-injection classifiers, and Anthropic's own numbers show a non-zero residual attack rate even on the newest models. For credentials, never put secrets in prompts: use the macOS Keychain (Security framework from Swift, `keyring` 25.7.0 from Python, `@napi-rs/keyring` from Node — `keytar` is archived and dead) and inject at the subprocess boundary.

## Recommendation

Build the safety kernel as two separate enforcement domains, because macOS gives you a real kernel-enforced boundary for one and nothing at all for the other.

Domain one, shell commands: wrap every command in `/usr/bin/sandbox-exec` with a generated Seatbelt profile. Do it natively in Swift by generating the .sbpl text and spawning `Process` with `["-p", policy, "/bin/zsh", "-c", cmd]` — hardcode the `/usr/bin/sandbox-exec` path exactly as Codex does, never resolve it from PATH. Start from Codex's `seatbelt_base_policy.sbpl` (Apache-2.0, Chrome-derived, `(deny default)` first line) rather than writing your own from scratch, and copy its two best ideas: writable roots computed from the task's working directory, and read-only carve-outs for `.git` and your own config directory inside those writable roots so the agent cannot rewrite history or edit its own permission rules. Ship `(deny network*)` as the default and open the network only through a local proxy allowlist. Ignore the "DEPRECATED" man page — I verified the mechanism works on 26.5.2, and it is what both Claude Code and Codex ship today.

Domain two, GUI computer-use: accept that Seatbelt cannot help here. Clicking and typing happen as Kunal's logged-in user with Accessibility and Screen Recording TCC grants, and any process with those grants can drive anything on screen. The only kernel is your approval layer. Model it on Claude Code's three-bucket allow/ask/deny with pattern rules, plus Cursor's `autoRun.block_instructions` idea (natural-language classifier steering is genuinely useful for GUI actions where no pattern syntax fits). Hard-code an unbypassable deny list — Keychain UI, System Settings, Terminal-in-Terminal, anything touching payment or credential fields — that no mode, including a bypass mode, can override.

Skip remote sandboxes entirely for v1. E2B, Daytona, and Modal all solve "run untrusted code away from my machine," which is not your problem: your product's entire value is that it controls *this* Mac. Adding a $150/month Pro tier and a network round trip to a personal app is the wrong trade.

For apple/container, evaluate but do not ship in v1. It is a legitimately impressive piece of engineering and the Swift package is directly importable, but 1.3.1 landed today patching six advisories including host-file reads through symlinks — that is a boundary still finding its bugs, and you would be depending on it for security. If you want Linux isolation for a specific subtask later, revisit it in a month.

Two concrete build constraints. First, ship as a signed .app bundle, not a bare CLI binary: on Tahoe 26.1 a non-bundled executable that gets Screen Recording permission does not appear in System Settings, so the user cannot see or revoke it — unacceptable for a product that is supposed to feel trustworthy. Second, for the audit log the brief asks for, log the *resolved policy* alongside every action, not just the action: the generated .sbpl text, the matched permission rule, and the approval decision with who or what made it. A future auditing agent needs to know what the boundary was at the moment of the action, and that is exactly the thing that is invisible after the fact.

On credentials, adopt Claude Code's masking pattern rather than inventing one. Secrets live in the Keychain; a helper resolves them at the subprocess boundary; the agent's context sees a placeholder. Claude Code's `credentials.envVars[].mode: "mask"` with `injectHosts` is the shape to copy, and its `apiKeyHelper` (a script that prints a key, re-invoked on 401) is the shape for rotating tokens.

## Risks

- Seatbelt confines subprocesses, not the GUI. Screenshot, click, and keystroke actions run as the logged-in user with Accessibility and Screen Recording grants and cannot be sandboxed by sandbox-exec at all. Any framing of Bot-Harness as "sandboxed" that does not distinguish these two domains is a false claim to the user.
- sandbox-exec is officially DEPRECATED in its man page. It works today on 26.5.2 and two major vendors depend on it, which makes near-term removal unlikely, but Apple has given no compatibility commitment and a point release could change behavior. Isolate all Seatbelt use behind one Swift module so a future swap costs one file, and add a startup self-test that runs a known deny case and fails loudly if it starts succeeding.
- apple/container 1.3.1, released today, patched six Containerization advisories including deleting files outside the bundle via an unchecked id, path traversal in the local content store, and reading host files through a symlink. This is a boundary actively finding its own bugs; do not build a security guarantee on it in v1.
- Domain-allowlist network filtering does not inspect traffic. Anthropic's own sandbox-runtime README says a broad entry like github.com permits exfiltration. An allowlist containing any user-content host (gists, S3, pastebins, a wildcard CDN) is an open egress channel for anything the agent has read.
- Prompt injection is reduced, not solved. Anthropic's most recent published figure for Fable 5 in the browser with probes and classifier is 0.3%, and their own research post says plainly that no browser agent is immune. For an agent that both browses and holds shell access on the user's primary machine, treat every screenshot and every fetched page as attacker-controlled input, and never let content read in one step silently authorize an action in the next.
- On Tahoe 26.1 a non-bundled Unix executable granted Screen Recording no longer appears in System Settings, so the user cannot audit or revoke it there. Shipping a bare binary would give Bot-Harness an invisible, unrevokable screen-capture grant — the opposite of the trustworthy product you want.
- OpenClaw's license is NOASSERTION on the GitHub API. Its permission design is worth studying, but do not copy code until someone reads the actual LICENSE file in the repo.
- keytar is archived (last push 2022) yet still widely recommended in blog posts and by models trained on them. If any Node component of Bot-Harness picks it up, you inherit an unmaintained native module for the single most security-sensitive dependency in the app.
- Claude Code's own macOS sandbox had a publicly reported escape via literal-path and glob confusion in path rule matching. Path-pattern matching is the recurring weak point in every one of these designs — canonicalize and resolve symlinks before matching, and never match on the raw string the model supplied.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- Apple's `container` CLI is NOT installable via Homebrew, contrary to what many guides say. I confirmed directly: `brew info --cask container` returns "Cask 'container' is unavailable: No Cask with this name exists." Installation is a signed .pkg from the GitHub releases page only. (`orbstack` does exist as a cask, at 2.2.3.)
- The brief's premise that apple/container might "run a Linux desktop" is not supported. Neither the README nor the technical overview mentions GUI, X11, VNC, or desktop support anywhere. Running Linux GUI apps requires the same manual XQuartz X11-forwarding or Xvfb+x11vnc hacks as Docker, documented only in third-party gists — not a product feature. For Bot-Harness's "live computer view" pane, this is the wrong tool: you want ScreenCaptureKit on the host Mac, not a Linux VM.
- apple/container publishes NO quantified performance numbers. The technical overview makes only relative claims ("boot times comparable to containers running in a shared VM", "less memory than full VMs") and explicitly notes freed memory is not properly released back to macOS. Every specific benchmark figure circulating for it comes from third-party blogs I did not treat as authoritative.
- Claude Code's exact Seatbelt profile text is not published. The docs confirm it uses the Seatbelt framework and that @anthropic-ai/sandbox-runtime generates profiles dynamically, but the generated .sbpl is not in any doc I could fetch. Codex's .sbpl files are the only fully-readable production example.
- E2B's cold-start latency (commonly cited as 150-200ms, with 5-30ms from pre-booted snapshots) and its use of Firecracker microVMs could NOT be confirmed from E2B's own docs — docs.e2b.dev does not state either. All figures come from third-party comparison articles. Treat as unverified.
- The OrbStack vs colima vs Docker Desktop benchmark numbers (OrbStack idle 0.8 GB RAM, 130.2 Gbps container-to-container, Docker Desktop 0.329s container startup) come from third-party blogs and one community benchmark repo, not from vendor documentation. I did not independently verify any of them, and I did not verify Docker Desktop's current commercial-license thresholds at all.
- The VentureBeat-sourced claim that "Anthropic's browser agent got hijacked 31.5% of the time before safeguards" does not match either Anthropic primary source. Anthropic's own numbers are 17.6% baseline for Opus 4.5 and 3.8% for Opus 5 (Claude in Chrome GA post, 2026-08-26), and 1% for Opus 4.5 against an adaptive Best-of-N attacker (research post, 2025-11-24). Use Anthropic's figures, not the press ones.
- The claim in one search result that "Anthropic launched computer use for Claude on March 23, 2026" is wrong — computer use shipped in 2024 and the current tool version is computer_toolset_20260801. That date appears to be a hallucinated or garbled secondary source; I did not use it.
- I did not verify the Cursor CLI's separate permission format. Cursor has two distinct systems — permissions.json (verified, mcpAllowlist/terminalAllowlist/autoRun) and a CLI config using Shell(...)/Read(...)/Write(...)/WebFetch(...) tokens in allow/deny arrays at cursor.com/docs/cli/reference/permissions. I fetched only the former; the token syntax for the latter is from a search snippet and is unverified.
- The macOS Tahoe 26.1 Screen Recording regression is a developer forum report with no Apple engineer confirmation and no acknowledged workaround. The underlying advice (ship an .app bundle) is sound regardless, but the specific 26.0.1-worked / 26.1-broke boundary is one developer's account.
- I did not verify Google's computer-use prompt-injection mitigations or any Gemini API flags for them. The assignment asked for Anthropic AND Google vendor mitigations; I found and verified only Anthropic's.

## Verified facts

- sandbox-exec exists at /usr/bin/sandbox-exec on macOS 26.5.2 (build 25F84, arm64) and its man page states "sandbox-exec - execute within a sandbox (DEPRECATED)" and "The sandbox-exec command is DEPRECATED." Despite this, it works: I wrote a profile with (deny default) + (allow file-write* (subpath "/private/tmp/bh-allowed")) + (deny network*), and confirmed a write to the allowed subpath succeeded, a write to /private/tmp/bh-denied returned "touch: /private/tmp/bh-denied: Operation not permitted", and curl to https://example.com failed with "curl: (6) Could not resolve host" (exit 6) while the same curl outside the sandbox returned HTTP 200.  
  — **confirmed** · <local execution on this machine: /usr/bin/sandbox-exec -f profile.sb ... ; man sandbox-exec>
- Codex CLI's macOS sandbox is Seatbelt via sandbox-exec. The source hardcodes the binary path: `pub const MACOS_PATH_TO_SEATBELT_EXECUTABLE: &str = "/usr/bin/sandbox-exec";` with the comment that only /usr/bin is considered "to defend against an attacker trying to inject a malicious version on the PATH." The policy is passed with the `-p` flag (`vec!["-p".to_string(), full_policy]`), and is assembled from seatbelt_base_policy.sbpl, seatbelt_network_policy.sbpl, and seatbelt_preferences_policy.sbpl.  
  — **confirmed** · <https://raw.githubusercontent.com/openai/codex/main/codex-rs/sandboxing/src/seatbelt.rs>
- Codex's base Seatbelt profile starts closed: `(version 1)` then `(deny default)`, then `(allow process-exec)`, `(allow process-fork)`, `(allow signal (target same-sandbox))`, `(allow process-info* (target same-sandbox))`, plus a tightly enumerated sysctl-read allowlist. The header credits Chrome's macOS sandbox policy as the inspiration. The network policy file adds `(allow system-socket (require-all (socket-domain AF_SYSTEM) (socket-protocol 2)))` and a mach-lookup allowlist including com.apple.SecurityServer, com.apple.networkd, com.apple.ocspd, com.apple.trustd.agent, and com.apple.SystemConfiguration.DNSConfiguration.  
  — **confirmed** · <https://raw.githubusercontent.com/openai/codex/main/codex-rs/sandboxing/src/seatbelt_base_policy.sbpl>
- Claude Code's sandboxed Bash tool uses the built-in Seatbelt framework on macOS with nothing to install; on Linux/WSL2 it uses bubblewrap plus socat, with an optional seccomp filter installed via `npm install -g @anthropic-ai/sandbox-runtime` that adds Unix domain socket blocking. Native Windows is unsupported. Enabled per-session with `/sandbox`, or globally via `sandbox.enabled: true` in ~/.claude/settings.json.  
  — **confirmed** · <https://code.claude.com/docs/en/sandboxing>
- Claude Code's sandbox config has a credentials block that solves the secrets-in-agent-context problem directly: `sandbox.credentials.files[]` and `sandbox.credentials.envVars[]` each take a `mode` of "deny" or "mask". In "mask" mode with `network.tlsTerminate` enabled, the value is hidden from the agent and injected only into requests to hosts named in `injectHosts`. There is also `credentials.files[].extract` (a regex, e.g. "oauth_token:\\s*(\\S+)") to pull a token out of a config file, and `credentials.awsPairs[]` with accessKeyIdVar / secretAccessKeyVar / sessionTokenVar.  
  — **confirmed** · <https://code.claude.com/docs/en/sandboxing>
- Anthropic's sandbox runtime is open source and published as the npm package @anthropic-ai/sandbox-runtime, CLI name `srt`, latest version 0.0.74 (npm modified 2026-08-26), Apache-2.0, 5,090 stars, repo pushed 2026-08-28. Its only runtime dependencies are @pondwader/socks5-server, commander, node-forge, and zod — it is a Node CLI that shells out to sandbox-exec on macOS with dynamically generated Seatbelt profiles, and to bubblewrap on Linux. Its README explicitly warns that domain filtering does not inspect traffic (so a broad allowlist entry like github.com permits exfiltration), that allowUnixSockets can expose powerful services such as the Docker socket, and that `enableWeakerNestedSandbox` "considerably weakens security".  
  — **confirmed** · <https://raw.githubusercontent.com/anthropic-experimental/sandbox-runtime/main/README.md>
- Apple's `container` is real, active, and at version 1.3.1 published 2026-08-29. It is Apache-2.0, 49,492 stars, written in Swift, built on the apple/containerization Swift package (Apache-2.0, 8,904 stars). It requires a Mac with Apple silicon and is supported only on macOS 26 — the README states maintainers "typically will not address issues that cannot be reproduced on macOS 26." It reached 1.0.0 on 2026-06-09.  
  — **confirmed** · <https://github.com/apple/container>
- apple/container is installed from a signed .pkg downloaded from the GitHub releases page (double-click, admin password, installs under /usr/local) — NOT via Homebrew. I confirmed there is no Homebrew cask named `container` (`brew info --cask container` returns "Cask 'container' is unavailable"), while `orbstack` does exist as a cask at version 2.2.3. After install: `container system start`, then e.g. `container run --rm alpine echo hello`. Upgrades use /usr/local/bin/update-container.sh; uninstall uses /usr/local/bin/uninstall-container.sh -d.  
  — **confirmed** · <https://raw.githubusercontent.com/apple/container/main/README.md>
- apple/container runs one lightweight Linux VM per container (not a shared VM), and uses the vmnet framework so each container gets its own network identity. The technical overview claims boot times "comparable to containers running in a shared VM" and lower memory than full VMs, but publishes no quantified benchmark numbers, and notes a current limitation where freed memory is not properly released back to macOS.  
  — **confirmed** · <https://raw.githubusercontent.com/apple/container/main/docs/technical-overview.md>
- apple/container 1.3.1 is a security patch release fixing six Containerization advisories, including GHSA-x7pf-2jmj-pgcq (creating a container or executing a container process can delete files outside its bundle through an unchecked id), GHSA-f689-h8m7-3jp2 (unvalidated OCI descriptor digests enabling path traversal in the local content store), GHSA-r3h2-rgqf-9hv9 (loading an OCI image layout can read host files through a symlink), and CVE-2026-65388 / GHSA-mx96-5vvg-x2mg (RegistryClient follows the WWW-Authenticate realm without validating host or scheme).  
  — **confirmed** · <https://github.com/apple/container/releases/tag/1.3.1>
- Codex CLI's approval/sandbox model in ~/.codex/config.toml: `sandbox_mode` takes read-only | workspace-write | danger-full-access; `approval_policy` takes untrusted | on-request | never | { granular = {...} } where granular has boolean sub-flags sandbox_approval, rules, mcp_elicitations, request_permissions, skill_approval. There is also `approvals_reviewer` = user | auto_review. The [sandbox_workspace_write] table has writable_roots (array<string>), network_access (bool), exclude_tmpdir_env_var (bool), exclude_slash_tmp (bool). Per-tool MCP approval uses mcp_servers.<id>.tools.<tool>.approval_mode with values auto | prompt | writes | approve.  
  — **confirmed** · <https://learn.chatgpt.com/docs/config-file/config-reference>
- Claude Code's permission model is three buckets (allow / ask / deny) with tool-scoped pattern rules, e.g. "Bash(npm run *)", "Bash(git commit *)", deny "Bash(git push *)", "mcp__*" to deny all MCP tools, "Agent(Explore)", and "WebFetch". Permission modes are default, acceptEdits, plan, bypassPermissions (plus auto), selected at startup via the `defaultMode` setting. Admins can hard-disable escape hatches with permissions.disableBypassPermissionsMode and permissions.disableAutoMode set to "disable" in managed settings.  
  — **confirmed** · <https://code.claude.com/docs/en/permissions>
- Cursor's permission file is permissions.json, read from ~/.cursor/permissions.json (per-user) and <workspace>/.cursor/permissions.json (per-repo), with arrays concatenated rather than replaced. Top-level fields are mcpAllowlist (string[]), terminalAllowlist (string[]), and autoRun { allow_instructions[], block_instructions[] } which steers the Auto-review classifier in natural language. Terminal matching is prefix-based: "git" matches `git status` but not `gitk`. MCP patterns support server:tool, server:*, *:tool, *:*.  
  — **confirmed** · <https://cursor.com/docs/reference/permissions>
- OpenClaw is a real and enormous project — github.com/openclaw/openclaw, 387,966 stars, pushed 2026-08-29, license NOASSERTION. Its tool permission model uses tools.allow / tools.deny (case-insensitive, `*` wildcards, deny wins), a tools.profile baseline of minimal | coding | messaging | full, per-provider narrowing via tools.byProvider, sender-scoped policy via tools.toolsBySender (keys like "channel:discord:<id>", "id:<user>", "*"), and separate sandbox gating via tools.sandbox.tools.alsoAllow with agents.defaults.sandbox.mode. Config is JSON5.  
  — **confirmed** · <https://docs.openclaw.ai/gateway/config-tools>
- Anthropic's current computer-use tool is `computer_toolset_20260801`, which requires no beta header and is supported on claude-opus-5, claude-mythos-5, claude-fable-5, claude-sonnet-5, and claude-opus-4-8. The prior version is `computer_20251124`. Anthropic runs classifiers on prompts that flag potential prompt injections, and when one is detected in a screenshot the model is automatically steered to ask the user for confirmation before proceeding. This protection can be disabled only by contacting support. The docs still advise a dedicated VM/container with minimal privileges, no access to credentials, a domain allowlist for internet access, and human confirmation for consequential actions.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- Anthropic's published browser-agent prompt-injection numbers (Claude in Chrome GA post, 2026-08-26): attacks that reached the model succeeded against Opus 4.5 17.6% of the time baseline (16.7% with probes), and against Opus 5 3.8% baseline dropping to 0% with probes plus the safety classifier. Sonnet 5 and Mythos 5 are 0% with probes plus classifier; Fable 5 is 0.3%. The three defense layers are RL training against a growing attack library, trained probes that scan tool results for injections, and a safety classifier that checks the action Claude is about to take against what the user originally asked for.  
  — **confirmed** · <https://claude.com/blog/claude-in-chrome-generally-available>
- Anthropic's research post on browser prompt-injection defenses (published 2025-11-24) reports a 1% attack success rate for Claude Opus 4.5 against an internal adaptive Best-of-N attacker with 100 attempts per environment, and states plainly that this "still represents meaningful risk" and that "no browser agent is immune to prompt injection."  
  — **confirmed** · <https://www.anthropic.com/research/prompt-injection-defenses>
- Node's keytar is dead: atom/node-keytar is archived on GitHub with last push 2022-12-12, and npm `keytar` is stuck at 7.9.0 (registry last modified 2025-07-30). The maintained replacement is @napi-rs/keyring, latest 1.3.0 (npm modified 2026-04-30), a napi.rs binding over the Rust keyring-rs crate. For Python the maintained library is `keyring` 25.7.0 on PyPI, which uses the macOS Keychain backend by default.  
  — **confirmed** · <https://www.npmjs.com/package/@napi-rs/keyring>
- macOS ships a Keychain CLI at /usr/bin/security with the subcommands add-generic-password, find-generic-password, delete-generic-password, and set-generic-password-partition-list — verified by running `security help` on this machine. This gives a zero-dependency shell path to Keychain from any language.  
  — **confirmed** · <local execution: /usr/bin/security help>
- Claude Code itself stores its credentials in the encrypted macOS Keychain on macOS (on Linux it falls back to ~/.claude/.credentials.json at mode 0600). For rotating/dynamic secrets it supports an `apiKeyHelper` setting: a shell script that prints a key, re-invoked after 5 minutes or on HTTP 401, tunable with CLAUDE_CODE_API_KEY_HELPER_TTL_MS. This is a good precedent for Bot-Harness: a helper process fetches the secret, the agent never sees it.  
  — **confirmed** · <https://code.claude.com/docs/en/iam>
- E2B pricing: Hobby is free with a one-time $100 usage credit, up to 1-hour sandbox sessions, max 20 concurrent sandboxes, 10 GiB storage. Pro is $150/month with up to 24-hour sessions, 100 concurrent sandboxes (extendable to 1,100), 20 GiB storage. Compute is per-second: 1 vCPU $0.000014/s, 2 vCPU (default) $0.000028/s, 8 vCPU $0.000112/s; RAM $0.0000045/GiB/s.  
  — **confirmed** · <https://e2b.dev/pricing>
- Daytona pricing is per-second: vCPU $0.0504/hour, RAM $0.0162/GiB/hour, storage $0.000108/GiB/hour after 5 free GiB. Trial users get $200 in free compute credits with no card required. Daytona markets "sandboxes in milliseconds" with sub-90ms creation time.  
  — **confirmed** · <https://www.daytona.io/pricing>
- Modal pricing distinguishes Sandboxes from ordinary functions and charges roughly 3x for them: CPU $0.0000131/core/sec for functions vs $0.00003942/core/sec for Sandbox + Notebooks; memory $0.00000222/GiB/sec vs $0.00000667/GiB/sec for Sandbox. The Starter plan is $0/month with $30/month of free credits, 3 seats, 100 containers; Team is $250/month with $100/month credits.  
  — **confirmed** · <https://modal.com/pricing>
- On macOS Tahoe 26.1 a plain (non-app-bundle) Unix executable that calls CGRequestScreenCaptureAccess() triggers the system dialog and can capture the screen once granted, but no longer appears in System Settings > Privacy & Security > Screen & System Audio Recording, so the user cannot verify or revoke it in the UI. The reporting developer attributes this to a new undocumented "Background Security Improvements" section added in 26.1, and says Full Disk Access is affected the same way. No Apple engineer response in the thread. Practical consequence for Bot-Harness: ship as a proper signed .app bundle, not a bare CLI binary.  
  — likely · <https://developer.apple.com/forums/thread/807323>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [apple/container](https://github.com/apple/container) | evaluate — great for confining Linux-shell workloads Bot-Harness spawns, but do NOT treat it as a hardened boundary yet: 1.3.1 (today) patched six advisories including host-file reads and path traversal. Also useless for sandboxing the macOS GUI the agent drives. | Swift CLI that runs OCI Linux containers as one lightweight VM per container on Apple Silicon, using the Containerization framework and vmnet networking. macOS 26 only. | 49,492 | Apache-2.0 | 2026-08-28 (release 1.3.1 on 2026-08-29) |
| [apple/containerization](https://github.com/apple/containerization) | evaluate — the only native-Swift path to VM isolation, but carries the same fresh-advisory risk. Pin to containerization 0.42.0 or later. | The Swift package underneath apple/container. Directly importable from a Swift 6 app — this is the API surface Bot-Harness would use rather than shelling out to the CLI. | 8,904 | Apache-2.0 | 2026-08-28 |
| [anthropic-experimental/sandbox-runtime (npm: @anthropic-ai/sandbox-runtime, CLI: srt)](https://github.com/anthropic-experimental/sandbox-runtime) | adopt — the highest-leverage single dependency for Bot-Harness's shell-command kernel. Read its config schema and either use `srt` directly or reimplement its profile generator in Swift. | Wraps any process in OS-level filesystem and network restrictions without a container: sandbox-exec with generated Seatbelt profiles on macOS, bubblewrap + socat on Linux, with an HTTP + SOCKS5 proxy pair enforcing a domain allowlist. This is the engine behind Claude Code's /sandbox. | 5,090 | Apache-2.0 | 2026-08-28 (npm 0.0.74, 2026-08-26) |
| [openai/codex](https://github.com/openai/codex) | reference-only — do not depend on it, but copy the .sbpl base policy and the writable-root/protected-path carve-out logic. It is the best free reference implementation of a macOS agent sandbox in existence. | Rust coding agent whose codex-rs/sandboxing/src/ directory contains a production-grade, Chrome-derived Seatbelt policy generator (seatbelt.rs + three .sbpl files) and a granular approval-policy model. | 119,726 | Apache-2.0 | 2026-08-29 |
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | reference-only — mine its tools.profile / tools.byProvider / tools.toolsBySender design for Bot-Harness's permission schema. NOASSERTION license means do not copy code. | Personal AI assistant with the most elaborate published tool-permission model: profiles, allow/deny with wildcards, per-provider narrowing, per-sender policy, and a separate sandbox tool gate. | 387,966 | NOASSERTION (check before reuse) | 2026-08-29 |
| [abiosoft/colima](https://github.com/abiosoft/colima) | reject for this project — you already have Docker installed, and for a polished consumer-feeling app a headless VM manager the user must debug in a terminal is the wrong dependency. | CLI-only Lima-backed container runtime for macOS. No GUI, no .local domains. | 30,559 | MIT | 2026-08-24 |
| [e2b-dev/E2B](https://github.com/e2b-dev/E2B) | reference-only for a personal Mac app — remote sandboxes add a network round trip and a bill for something a local Seatbelt profile does for free. Revisit only if you later want untrusted-code execution isolated from Kunal's machine entirely. | Firecracker-microVM remote sandboxes with `e2b` SDKs for Python and JS. | 13,581 | Apache-2.0 | 2026-08-28 |

## API and code shape

## 1. Seatbelt profile — VERIFIED WORKING on this machine (macOS 26.5.2, arm64)

I wrote this to /tmp/bh_test.sb and ran it. Allowed write succeeded; denied write gave "Operation not permitted"; curl gave "curl: (6) Could not resolve host: example.com".

```scheme
(version 1)
(deny default)
(import "system.sb")
(allow file-read*)
(allow process-exec (literal "/bin/ls") (literal "/usr/bin/touch") (subpath "/bin") (subpath "/usr/bin"))
(allow file-write* (subpath "/private/tmp/bh-allowed"))
(deny network*)
```

Invocation (both forms work; Codex uses -p, I tested -f):

```bash
/usr/bin/sandbox-exec -f /tmp/bh_test.sb /usr/bin/touch /private/tmp/bh-allowed/ok
/usr/bin/sandbox-exec -p '<policy string>' bash -c 'whatever'
```

Full flag set from `man sandbox-exec`:
```
sandbox-exec [-f profile-file] [-n profile-name] [-p profile-string] [-D key=value ...] command [arguments ...]
```
The `-D key=value` form is how you parameterize a profile; Codex uses it with `(param "...")`, e.g.
`(allow network-outbound (remote unix-socket (subpath (param "KEY"))))`.

## 2. Codex's hardcoded path and base policy (copy this pattern)

```rust
// codex-rs/sandboxing/src/seatbelt.rs
/// When working with `sandbox-exec`, only consider `sandbox-exec` in `/usr/bin`
/// to defend against an attacker trying to inject a malicious version on the
/// PATH. If /usr/bin/sandbox-exec has been tampered with, then the attacker
/// already has root access.
pub const MACOS_PATH_TO_SEATBELT_EXECUTABLE: &str = "/usr/bin/sandbox-exec";

const MACOS_SEATBELT_BASE_POLICY: &str = include_str!("seatbelt_base_policy.sbpl");
const MACOS_SEATBELT_NETWORK_POLICY: &str = include_str!("seatbelt_network_policy.sbpl");
const MACOS_SEATBELT_PREFERENCES_POLICY: &str = include_str!("seatbelt_preferences_policy.sbpl");
```

seatbelt_base_policy.sbpl opening:
```scheme
(version 1)
; start with closed-by-default
(deny default)
; child processes inherit the policy of their parent
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))
(allow process-info* (target same-sandbox))
(allow file-write-data
  (require-all
    (path "/dev/null")
    (vnode-type CHARACTER-DEVICE)))
```

Loopback/DNS carve-outs it injects at runtime:
```scheme
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote ip "*:53"))
(allow network-outbound (remote unix-socket))
```

## 3. Claude Code sandbox settings (~/.claude/settings.json) — the credential-masking pattern you want

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "denyRead": ["~/"],
      "allowRead": ["."],
      "allowWrite": ["~/.kube", "/tmp/build"],
      "denyWrite": [".env"]
    },
    "network": {
      "tlsTerminate": {},
      "allowedDomains": ["*.github.com", "registry.npmjs.org"],
      "httpProxyPort": 8080,
      "socksProxyPort": 8081
    },
    "credentials": {
      "files": [
        { "path": "~/.aws/credentials", "mode": "deny" },
        { "path": "~/.ssh", "mode": "deny" },
        { "path": "~/.config/gh/hosts.yml", "mode": "mask",
          "extract": "oauth_token:\\s*(\\S+)", "injectHosts": ["api.github.com"] }
      ],
      "envVars": [
        { "name": "GH_TOKEN", "mode": "mask", "injectHosts": ["api.github.com"] },
        { "name": "NPM_TOKEN", "mode": "mask" }
      ]
    }
  }
}
```

## 4. Claude Code permission rules (three buckets, tool-scoped patterns)

```json
{
  "permissions": {
    "allow": ["Bash(npm run *)", "Bash(git commit *)"],
    "deny": ["Bash(git push *)", "mcp__*", "Agent(Explore)"],
    "defaultMode": "default"
  }
}
```
Modes: `default`, `acceptEdits`, `plan`, `bypassPermissions`, `auto`.
Hard locks: `permissions.disableBypassPermissionsMode: "disable"`, `permissions.disableAutoMode: "disable"`.

## 5. Codex config.toml

```toml
sandbox_mode = "workspace-write"      # read-only | workspace-write | danger-full-access
approval_policy = "on-request"        # untrusted | on-request | never | { granular = {...} }
approvals_reviewer = "user"           # user | auto_review

[sandbox_workspace_write]
writable_roots = ["/path/one", "/path/two"]
network_access = false
exclude_tmpdir_env_var = false
exclude_slash_tmp = false
```
Granular approvals: `{ granular = { sandbox_approval = true, rules = true, mcp_elicitations = true, request_permissions = true, skill_approval = true } }`
Per-MCP-tool: `mcp_servers.<id>.tools.<tool>.approval_mode` = `auto | prompt | writes | approve`.

## 6. Cursor ~/.cursor/permissions.json

```jsonc
{
  "mcpAllowlist": ["github:*", "linear:list_issues"],
  "terminalAllowlist": ["git", "npm install*", "cargo build"],
  "autoRun": {
    "allow_instructions": ["Read-only file inspections are acceptable"],
    "block_instructions": ["Flag any database modification attempts for review"]
  }
}
```
Terminal matching is prefix-based: `git` matches `git status`, not `gitk`. MCP wildcards: `server:tool`, `server:*`, `*:tool`, `*:*`.

## 7. OpenClaw tool policy (JSON5)

```json5
{
  tools: {
    profile: "coding",                       // minimal | coding | messaging | full
    deny: ["write", "edit", "apply_patch"],  // deny wins over allow
    byProvider: {
      anthropic: { profile: "minimal" },
      "openai/gpt-5.4": { allow: ["group:fs", "sessions_list"] },
    },
    toolsBySender: {
      "*": { deny: ["exec", "process", "write", "edit", "apply_patch"] },
    },
    sandbox: { tools: { alsoAllow: ["web_search", "web_fetch"] } },
  },
  agents: { defaults: { sandbox: { mode: "all" } } },
}
```

## 8. Anthropic sandbox-runtime (srt)

```bash
npm install -g @anthropic-ai/sandbox-runtime
srt echo "hello world"
srt --debug curl https://example.com
srt --settings /path/to/srt-settings.json npm install
```
`~/.srt-settings.json`:
```json
{
  "network":    { "allowedDomains": ["github.com", "*.github.com"], "deniedDomains": ["malicious.com"] },
  "filesystem": { "denyRead": ["~/.ssh"], "allowWrite": [".", "/tmp"], "denyWrite": [".env"] }
}
```

## 9. Apple container CLI

```bash
# install: download signed .pkg from https://github.com/apple/container/releases (NO homebrew cask)
container system start
container run --rm alpine echo hello
/usr/local/bin/update-container.sh          # upgrade
/usr/local/bin/update-container.sh -v 0.3.0 # downgrade to a version
/usr/local/bin/uninstall-container.sh -k    # keep user data
```

## 10. Keychain from Swift / Python / Node / shell

Swift (Security.framework, no dependency):
```swift
import Security

let query: [String: Any] = [
    kSecClass as String:       kSecClassGenericPassword,
    kSecAttrService as String: "com.kunal.bot-harness",
    kSecAttrAccount as String: "openai_api_key",
    kSecValueData as String:   secret.data(using: .utf8)!,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
]
let status = SecItemAdd(query as CFDictionary, nil)   // errSecDuplicateItem == -25299
```
Read back with `SecItemCopyMatching`, remove with `SecItemDelete`. All three block the calling thread — call them off the main actor.

Python: `pip install keyring` (25.7.0), macOS Keychain backend by default:
```python
import keyring
keyring.set_password("com.kunal.bot-harness", "openai_api_key", secret)
token = keyring.get_password("com.kunal.bot-harness", "openai_api_key")
```

Node: `npm i @napi-rs/keyring` (1.3.0). Do NOT use `keytar` — archived 2022.
```js
import { Entry } from '@napi-rs/keyring'
const entry = new Entry('com.kunal.bot-harness', 'openai_api_key')
entry.setPassword(secret)
const token = entry.getPassword()
```

Zero-dependency shell path (verified present on this machine):
```bash
security add-generic-password -s com.kunal.bot-harness -a openai_api_key -w "$SECRET" -U
security find-generic-password -s com.kunal.bot-harness -a openai_api_key -w
security delete-generic-password -s com.kunal.bot-harness -a openai_api_key
```

## 11. Computer-use tool (current version, no beta header)

```json
{
  "model": "claude-opus-5",
  "max_tokens": 1024,
  "tools": [{ "type": "computer_toolset_20260801" }],
  "messages": [{ "role": "user", "content": "Your task here" }]
}
```
Prior version: `computer_20251124`. Injection classifiers are ON by default and steer the model to ask for confirmation when an injection is detected in a screenshot; opting out requires contacting Anthropic support.
