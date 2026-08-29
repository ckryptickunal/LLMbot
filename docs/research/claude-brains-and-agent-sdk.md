# Anthropic computer-use + agent-building stack as of 2026-08-29, evaluated as the brain for a Mac-native personal computer-use harness (Bot-Harness)

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

Almost every string in the assignment brief is stale. Computer use is no longer a single `computer_20250124` tool with an `action` discriminator and `display_width_px` params — it is now a *toolset*, `computer_toolset_20260801`, that declares 17 separate member tools, requires no beta header, and explicitly rejects `display_width_px` / `display_height_px` / `display_number` / `name`. The reference repo `anthropics/anthropic-quickstarts` was renamed to `anthropics/claude-quickstarts`, and it now contains a second, far more relevant quickstart — `computer-use-best-practices` — which is a macOS-native, no-Docker computer-use agent using pyautogui, `sandbox-exec`, correct screenshot resizing, prompt caching, and trajectory recording. That is the closest thing to a blueprint for Bot-Harness that exists. The single most important constraint for this project: Claude Code's own built-in computer use (a bundled MCP server named `computer-use`) is macOS-only, Pro/Max-only, and explicitly not available in `-p` non-interactive mode, which means it is not reachable from the Agent SDK — you cannot wrap Claude Code and inherit free screen control on the subscription. The Agent SDK itself ships zero GUI or screen tools, so the harness has to supply its own eyes and hands either way.

## Recommendation

Split the stack: use the Agent SDK as the harness and the raw Messages API toolset as the eyes and hands, and connect them with your own MCP server.

Concretely. Build the Swift app as the shell — task list, conversation, live screen view — and run a Python sidecar that calls `query()` from `claude-agent-sdk`. Register an in-process MCP server (Python `@tool` plus `create_sdk_mcp_server`) whose tools are the 17 member actions of `computer_toolset_20260801`, implemented natively in Swift over XPC or a local socket, using CGEvent for input and ScreenCaptureKit for capture. Name and schema them identically to the toolset members so you can swap between the two brains without rewriting prompts. That buys you the Claude Code agent loop, context compaction, subagents, sessions with resume and fork, skills, and MCP — all of which you would otherwise write yourself — plus two things that directly satisfy the brief. The `can_use_tool` callback gives you a native permission sheet with `title`, `display_name`, and `description` already written for you. The PreToolUse, PostToolUse, PostToolUseFailure, and PermissionRequest hooks give you the per-decision audit log without instrumenting anything.

Before writing any capture or input code, port `computer_use/image.py` and `computer_use/tools/` from `claude-quickstarts/computer-use-best-practices`. That directory exists specifically because getting screenshot resize and click-coordinate alignment right is the part everyone gets wrong, and it is already solved for macOS. Copy its `runs/` trajectory format for your audit log too.

On models: default to `claude-opus-5` at effort `high`, with `claude-sonnet-5` as the cost fallback. Sonnet 5 at $2/$10 is now permanently priced and costs 40% of Opus 5 for GUI grinding, which is mostly perception rather than reasoning. Turn prompt caching on from day one with a `cache_control` breakpoint on the toolset definition: the toolset alone is roughly 4,500 input tokens resent on every turn of a long GUI session, and cache reads cost 10% of base input.

Do not build on Managed Agents. It hosts the container, which is the opposite of what a Mac-native local harness needs, and it adds $0.08 per session-hour on top of tokens. Do not build on the Tool Runner either — the Agent SDK is a strict superset of it for this use case. And do not plan around wrapping the Claude Code CLI to inherit subscription-billed computer use, because the docs rule that out explicitly for `-p`.

One decision to settle early, because it changes the whole cost model: whether the sidecar authenticates with an API key or with Kunal's existing Max subscription. A non-bare `claude -p` reads the keychain and OAuth credentials, so the SDK plausibly runs on the subscription for personal use, but I could not confirm that end to end and Anthropic's Agent SDK docs point developers at API keys. Test it in ten minutes before committing to a budget.

## Risks

- The brief's assumption that wrapping Claude Code yields free computer use on the Max subscription is false. Claude Code's `computer-use` MCP server is explicitly unavailable in `-p` mode, so the Agent SDK cannot reach it. Screen control must be built, and if built against the Messages API it is billed per token against an API key, not the subscription.
- Anthropic already ships the product this brief describes. Claude Cowork and Claude Desktop computer use is a research preview on Pro and Max, on macOS and Windows, with per-app permissions, an app blocklist, and prompt-injection action review. The best-practices quickstart's own README tells readers who want safeguards to use Cowork instead. Bot-Harness needs a reason to exist that Cowork does not already cover.
- Anthropic's own reference implementation warns against running a computer-use agent outside a VM: it says running it outside a virtual machine is strongly discouraged and that there are no safeguards against it screenshotting sensitive information and uploading it to the API. The brief calls for the app to hold all needed OS permissions on Kunal's primary machine, which is precisely the configuration being warned against.
- Token cost on long GUI sessions is dominated by images, not reasoning. Every screenshot is billed as image input on top of a ~4,500-token toolset definition resent per turn. Without prompt caching and image pruning, a multi-hour session on Opus 5 gets expensive fast. The best-practices quickstart exists largely to address this.
- macOS permission fragility: Screen Recording and Accessibility attach to the hosting process, require a full quit and relaunch, and macOS 15+ re-prompts for the private-window-picker bypass roughly monthly. A signed, notarized Swift app has a better story here than a terminal, but this must be designed for rather than discovered.
- No official Anthropic Swift SDK exists. All agent-loop code lives in a Python or Node sidecar, so the Swift app owns process lifecycle, crash recovery, and IPC. That is real engineering surface the brief does not currently budget for.
- Tool versioning churn is fast: computer_20250124 to computer_20251124 to computer_toolset_20260801 in roughly 19 months, with a breaking wire-format change (action discriminator removed, toolset_name added). Isolate tool declaration and result encoding behind one adapter so the next version is a single-file change.
- The TypeScript Agent SDK's npm license field reads 'SEE LICENSE IN README.md' rather than an SPDX identifier, and use is governed by Anthropic's Commercial Terms. The Python SDK is plainly MIT. If licensing clarity matters, prefer the Python sidecar.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN BRIEF: `computer_20250124` is not the current tool type. Current is `computer_toolset_20260801` (no beta header, no `name` field, 17 member tools). `computer_20250124` and `computer_20251124` survive only for older models and still need their beta headers.
- WRONG IN BRIEF: the screen-size params are gone. `display_width_px`, `display_height_px`, and `display_number` are now REJECTED with `invalid_request_error` on the current toolset. The model infers dimensions from the screenshots you send, which is why porting the reference resize logic matters.
- WRONG IN BRIEF: `anthropics/anthropic-quickstarts` no longer exists under that name — it redirects (HTTP 301) to `anthropics/claude-quickstarts`. Any hardcoded URL or clone script using the old name needs updating. Note the Docker image tag still reads `ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest`.
- PARTLY WRONG IN BRIEF: the session's claimed model roster is mostly right but imprecise. Fable 5 (`claude-fable-5`), Opus 5 (`claude-opus-5`), Sonnet 5 (`claude-sonnet-5`), and Haiku 4.5 (`claude-haiku-4-5-20251001`) are the four on the public models overview. Mythos 5 (`claude-mythos-5`) is real but does NOT appear on the models overview — the pricing page lists it as 'limited availability' behind anthropic.com/glasswing (Project Glasswing), so treat it as unavailable for this project.
- STALE NAME: 'Claude Code SDK' is now 'Claude Agent SDK'. The old `claude-code-sdk` PyPI package is frozen at 0.0.25; the live package is `claude-agent-sdk` 0.2.148.
- VERIFICATION FAILURE WORTH NOTING: WebFetch's summarizer returned a fabricated `canUseTool` signature for the TypeScript docs page — it reported `PermissionResult = {permitted: true} | {permitted: false, reason?}`. The real shape, read from the Python SDK source (whose comment says it matches TypeScript), is `behavior: "allow" | "deny"`. Do not trust WebFetch summaries of API reference pages; read the SDK source.
- UNVERIFIED: whether the Agent SDK, running non-bare, actually authenticates against Kunal's claude.ai Max subscription rather than requiring ANTHROPIC_API_KEY. The headless docs state that `--bare` never reads OAuth credentials or the system keychain, which implies non-bare does, but no page states this affirmatively for the SDK and the Agent SDK quickstart directs developers to API keys. This is the highest-value thing to test empirically before budgeting. Note also Anthropic's standing restriction on third-party products offering claude.ai login — that governs distribution rather than personal use, but it means this path should not be designed into a shippable product.
- UNVERIFIED: the exact TypeScript-side field names for `canUseTool` and `PermissionResult`. I confirmed the Python source and relied on its in-source comment that it matches TypeScript's structure. If you build the TS sidecar, read sdk.d.ts in the installed package rather than trusting this.
- UNVERIFIED: I could not fetch the Anthropic Tool Runner or Agent Skills documentation pages live this session. What I report about them comes from the bundled claude-api skill (cached 2026-06-24) plus the confirmed existence of a `skills` field in ClaudeAgentOptions. My judgment that neither helps a local Mac harness follows from architecture rather than from a fetched page — Tool Runner is a thin loop helper the Agent SDK supersedes, and Agent Skills run in Anthropic's code-execution container.
- UNVERIFIED: I did not fetch the Managed Agents overview page directly. The $0.08 per session-hour figure and the hosted-container model are confirmed from the pricing page; the rest of my Managed Agents characterization comes from the bundled skill.
- NOT FULLY CHECKED: GitHub API rate limits blocked several repo probes mid-session. I re-ran the Swift check via GitHub code search (0 results) and the authenticated gh CLI (404), which I consider conclusive for 'no official Swift SDK', but I did not enumerate the full anthropics org.
- NOT CHECKED: whether `browser_toolset_20260801` has the same model support list as the computer toolset. Its existence and ~6,600-token overhead are confirmed from the pricing page; I did not fetch its own documentation page.

## Verified facts

- The current computer use tool is a toolset declared as `{"type": "computer_toolset_20260801"}` with no `name` field and no beta header. It declares 17 member tools: screenshot, zoom, left_click, right_click, middle_click, double_click, triple_click, left_click_drag, mouse_move, left_mouse_down, left_mouse_up, cursor_position, scroll, type, key, hold_key, wait.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- `computer_toolset_20260801` REJECTS the parameters `name`, `display_width_px`, `display_height_px`, `display_number`, and `enable_zoom` with an `invalid_request_error`. Its only optional parameters are `configs` (per-member `enabled` / `defer_loading`), `cache_control`, and `allowed_callers` (`["direct"]` only).  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- The toolset is supported on claude-fable-5, claude-mythos-5, claude-opus-5, claude-sonnet-5, and claude-opus-4-8. Older models (Opus 4.7, 4.6, 4.5, Sonnet 4.6) use the earlier single-tool shapes `computer_20241022` through `computer_20251124`, which keep the `action` discriminator and still require their beta headers.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- Wire shape change: with the toolset, `tool_use.name` is the member name (`left_click`, `screenshot`, ...), the block carries `toolset_name: "computer"`, and the input is that action's parameters with NO `action` discriminator. Every answering `tool_result` must carry the same `toolset_name`. Member calls in a turn run sequentially and stop on the first failure.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-quickstarts/main/computer-use-demo/README.md>
- Current model IDs on the public models overview are `claude-fable-5` ($10/$50 per MTok, 1M ctx, 128K out, thinking always on), `claude-opus-5` ($5/$25, 1M ctx, 128K out, adaptive thinking, default effort high), `claude-sonnet-5` ($2/$10, 1M ctx, 128K out), and `claude-haiku-4-5-20251001` (alias `claude-haiku-4-5`, $1/$5, 200K ctx, 64K out, effort NOT supported).  
  — **confirmed** · <https://platform.claude.com/docs/en/about-claude/models/overview>
- Claude Sonnet 5's $2 input / $10 output pricing, originally announced as introductory through August 31 2026, is now the permanent standard price; the scheduled increase to $3/$15 on September 1 2026 will not occur.  
  — **confirmed** · <https://platform.claude.com/docs/en/about-claude/pricing>
- Declaring `computer_toolset_20260801` with default members costs about 4,500 input tokens per request (~4,520 on Fable 5 / Mythos 5 / Opus 5 / Opus 4.8, ~4,590 on Sonnet 5). Disabling `zoom` via `configs` removes about 410 of those. There is also a `browser_toolset_20260801` costing about 6,600 input tokens.  
  — **confirmed** · <https://platform.claude.com/docs/en/about-claude/pricing>
- Prompt caching: 5-minute cache write = 1.25x base input, 1-hour cache write = 2x base input, cache read = 0.1x base input. On Opus 5 that is $6.25/$10 write and $0.50/MTok read. Batch API is a flat 50% discount on input and output. Effort is `low|medium|high|xhigh|max` inside `output_config`, default `high`.  
  — **confirmed** · <https://platform.claude.com/docs/en/about-claude/pricing>
- `anthropics/anthropic-quickstarts` was RENAMED to `anthropics/claude-quickstarts` (the old API path returns HTTP 301). The repo has 17,570 stars, MIT license, last pushed 2026-08-25, and contains: agents, autonomous-coding, browser-use-demo, computer-use-best-practices, computer-use-demo, customer-support-agent, financial-data-analyst, managed-agents.  
  — **confirmed** · <https://api.github.com/repos/anthropics/claude-quickstarts>
- `claude-quickstarts/computer-use-best-practices` is a macOS-ONLY, no-Docker reference computer-use agent: explicitly-defined tools in `computer_use/tools/`, a port of the API's reference screenshot resize in `computer_use/image.py`, `computer_batch`/`browser_batch` batching tools, sandboxed bash/python via `sandbox-exec`, trajectory recording to `runs/`, a Streamlit viewer, and a FastAPI debug panel. Requires Python 3.11+, pyautogui, and Playwright chromium.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-quickstarts/main/computer-use-best-practices/README.md>
- That same README documents the exact macOS permission set a native harness needs: Screen Recording (screenshots) and Accessibility (mouse/keyboard), granted to the hosting process, with a full quit/reopen required. On macOS 15+ there is an additional recurring 'bypass the system private window picker' dialog roughly once a month. Deep links: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"` and `...?Privacy_Accessibility`.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-quickstarts/main/computer-use-best-practices/README.md>
- Claude Code has built-in computer use on macOS as a bundled MCP server named `computer-use`, enabled per-project via `/mcp`. It requires a Pro or Max plan and claude.ai authentication (not Bedrock/Vertex/Foundry), takes a machine-wide lock (one session at a time), hides non-approved apps, excludes the terminal window from screenshots, downscales screenshots automatically (3456x2234 -> ~1372x887, no setting to change it), and aborts on global Esc.  
  — **confirmed** · <https://code.claude.com/docs/en/computer-use>
- CRITICAL LIMIT: Claude Code computer use 'requires an interactive session, so it is not available in non-interactive mode with the `-p` flag.' It is therefore unreachable from the Agent SDK, which drives the CLI non-interactively. It is also macOS-only in the CLI, and the denied-apps list is 'Not yet available' in the CLI (Desktop only).  
  — **confirmed** · <https://code.claude.com/docs/en/computer-use>
- The Agent SDK packages are `@anthropic-ai/claude-agent-sdk` (npm, v0.3.251) and `claude-agent-sdk` (PyPI, v0.2.148, MIT, requires Python >=3.10). The old `claude-code-sdk` PyPI package is stale at 0.0.25. Both SDKs bundle a native Claude Code binary. Prerequisites: Node.js 18+ or Python 3.10+.  
  — **confirmed** · <https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/latest>
- The Agent SDK ships NO computer-use, screen, mouse, keyboard, or GUI tools. A full-text grep of the Python SDK's types.py (2,466 lines) for 'computer', 'browser_toolset', and 'toolset' returns zero matches. Its built-in tool surface is the Claude Code set (Read/Write/Edit/Bash/Glob/Grep/WebSearch/WebFetch), selectable via `tools: list[str] | {"type":"preset","preset":"claude_code"}`.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/main/src/claude_agent_sdk/types.py>
- The Agent SDK's permission callback signature is `CanUseTool = Callable[[str, dict[str, Any], ToolPermissionContext], Awaitable[PermissionResult]]`, where PermissionResult is `PermissionResultAllow(behavior="allow", updated_input, updated_permissions)` or `PermissionResultDeny(behavior="deny", message, interrupt)`. ToolPermissionContext carries `tool_use_id`, `agent_id`, `blocked_path`, `decision_reason`, `title`, `display_name`, and `description` — ready-made strings for a native permission dialog.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/main/src/claude_agent_sdk/types.py>
- Agent SDK hook events are exactly: PreToolUse, PostToolUse, PostToolUseFailure, UserPromptSubmit, Stop, SubagentStop, PreCompact, Notification, SubagentStart, PermissionRequest. Permission modes are: default, acceptEdits, plan, bypassPermissions, dontAsk, auto.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/main/src/claude_agent_sdk/types.py>
- ClaudeAgentOptions includes the fields needed for an auditable harness: `resume`, `session_id`, `fork_session`, `resume_session_at`, `session_store`, `max_budget_usd`, `task_budget`, `effort`, `thinking`, `model`, `fallback_model`, `agents` (subagents), `skills`, `plugins`, `sandbox` (SandboxSettings, macOS/Linux bash sandboxing), `mcp_servers`, `hooks`, `can_use_tool`, `output_format`, `enable_file_checkpointing`, `include_partial_messages`, `include_hook_events`, `forward_subagent_text`.  
  — **confirmed** · <https://raw.githubusercontent.com/anthropics/claude-agent-sdk-python/main/src/claude_agent_sdk/types.py>
- Claude Code headless mode: `claude -p "<prompt>"` with `--output-format text|json|stream-json`, `--json-schema '<schema>'` (result lands in `structured_output`), `--include-partial-messages`, `--verbose`, `--allowedTools`, `--permission-mode auto|dontAsk|acceptEdits`, `--continue`, `--resume <session_id>`, `--append-system-prompt`, `--system-prompt`, `--mcp-config`, `--agents`, `--settings`, `--add-dir`, `--plugin-dir`, `--bare`. `--output-format json` includes `total_cost_usd` and a per-model cost breakdown. Exit code 0 on success, 143 on SIGTERM.  
  — **confirmed** · <https://code.claude.com/docs/en/headless>
- `--bare` skips auto-discovery of hooks, skills, commands, subagents, plugins, MCP servers, auto memory, and CLAUDE.md, and 'never reads OAuth credentials or the system keychain' — it requires ANTHROPIC_API_KEY. It is documented as the recommended mode for scripted/SDK calls and will become the default for `-p`. By implication, a non-bare `-p` run does read the keychain/OAuth credentials.  
  — **confirmed** · <https://code.claude.com/docs/en/headless>
- Claude Managed Agents is billed on two dimensions: tokens at standard model rates, plus session runtime at $0.08 per session-hour metered only while status is `running`. The Batch discount does not apply and it is unavailable on Bedrock/Vertex. Anthropic runs the loop AND hosts the per-session container.  
  — **confirmed** · <https://platform.claude.com/docs/en/about-claude/pricing>
- Anthropic's own end-user answer to this problem space already ships: Claude Cowork / Claude Desktop computer use, research preview, Pro and Max plans only (not Team/Enterprise), macOS and Windows, with per-app permission prompts, a configurable app blocklist, an action-review scan for prompt injection, and categories blocked by default (investment/trading platforms, cryptocurrency). The best-practices quickstart explicitly redirects users who want safeguards rather than a teaching scaffold to Cowork.  
  — **confirmed** · <https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork>
- Anthropic publishes no official Swift SDK. GitHub search `org:anthropics swift` returns 0 repositories and `anthropics/anthropic-sdk-swift` returns 404 via the authenticated gh CLI. Official SDKs are Python, TypeScript, Java, Go, Ruby, C#, PHP.  
  — **confirmed** · <https://api.github.com/search/repositories?q=org:anthropics+swift>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [anthropics/claude-quickstarts — computer-use-best-practices](https://github.com/anthropics/claude-quickstarts/tree/main/computer-use-best-practices) | adopt — the single closest existing artifact to Bot-Harness. Port its image.py resize math and tool schemas verbatim into Swift rather than re-deriving them, and copy its runs/ trajectory format to satisfy the 'log every decision for future agents to audit' requirement. | macOS-native (no Docker) reference computer-use agent: explicit tool schemas in computer_use/tools/, a port of the API's reference screenshot resize in computer_use/image.py, computer_batch/browser_batch batching tools, sandbox-exec-sandboxed bash/python, trajectory recording to runs/, Streamlit trajectory viewer, FastAPI tool debug panel. Ships a /first-run Claude Code slash command. | 17,570 (whole repo) | MIT | 2026-08-25 (repo push) |
| [anthropics/claude-quickstarts — computer-use-demo](https://github.com/anthropics/claude-quickstarts/tree/main/computer-use-demo) | reference-only — Linux container, wrong OS. Read its README for the wire protocol and its loop for tool-version dispatch, then discard the Docker layer. | The original Docker + X11 + VNC computer-use reference loop with a Streamlit UI. Supports every dated tool version including computer_toolset_20260801, selectable in a sidebar. Its README is currently the clearest written spec of the toolset wire format (toolset_name, sequential member execution). | 17,570 (whole repo) | MIT | 2026-08-25 (repo push) |
| [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) | adopt — this is the harness layer. Run it as a sidecar process behind the Swift UI. can_use_tool gives a native permission sheet with pre-written title/display_name/description strings; the PreToolUse and PostToolUse hooks give the audit log for free. | Claude Code packaged as a Python library. query() and ClaudeSDKClient, ClaudeAgentOptions, @tool + create_sdk_mcp_server for in-process MCP tools, can_use_tool permission callback, 10 hook events, subagents, sessions with resume/fork, skills, plugins, bash sandboxing, max_budget_usd and task_budget. | 7,998 | MIT | 2026-08-28 |
| [anthropics/claude-agent-sdk-typescript](https://github.com/anthropics/claude-agent-sdk-typescript) | evaluate — pick this over Python only if the session-listing helpers matter and Node 24 is already the sidecar runtime. Its npm license field is 'SEE LICENSE IN README.md' rather than a clean SPDX identifier, unlike the MIT Python SDK. | The same harness in TypeScript, published as @anthropic-ai/claude-agent-sdk v0.3.251. Adds startup()/WarmQuery for pre-warmed sessions and listSessions()/getSessionMessages()/renameSession()/tagSession() session-management helpers. | 1,720 | SEE LICENSE IN README.md (not OSI-identified; Anthropic Commercial ToS governs SDK use) | 2026-08-28 |
| [anthropics/claude-agent-sdk-demos](https://github.com/anthropics/claude-agent-sdk-demos) | reference-only — useful for the shape of a desktop app driving the SDK, not for computer use. | Anthropic's own demo apps built on the Agent SDK (email assistant, research agent, and others) for local development. | 2,729 | not set on the repo | 2026-08-27 |
| [anthropics/claude-quickstarts — browser-use-demo](https://github.com/anthropics/claude-quickstarts/tree/main/browser-use-demo) | evaluate — if a large share of Kunal's tasks are web tasks, routing them through browser_toolset_20260801 instead of screen control is cheaper, more reliable, and skips the Accessibility permission for those tasks entirely. | Docker + Playwright browser-only agent, pairing with the browser_toolset_20260801 server-side toolset. | 17,570 (whole repo) | MIT | 2026-08-25 (repo push) |

## API and code shape

CURRENT COMPUTER USE TOOL DECLARATION (Messages API, no beta header):

{
  "model": "claude-opus-5",
  "max_tokens": 1024,
  "tools": [
    { "type": "computer_toolset_20260801" },
    { "type": "text_editor_20250728", "name": "str_replace_based_edit_tool" },
    { "type": "bash_20250124", "name": "bash" }
  ],
  "messages": [{ "role": "user", "content": "Save a picture of a cat to my desktop." }]
}

With per-member config (drops ~410 input tokens by disabling zoom):

{
  "type": "computer_toolset_20260801",
  "configs": { "zoom": { "enabled": false } },
  "cache_control": { "type": "ephemeral" }
}

MEMBER ACTIONS AND THEIR INPUTS (verbatim from docs):
  screenshot                -> {}
  zoom                      -> region: [x0, y0, x1, y1]
  left_click / right_click / middle_click / double_click / triple_click
                            -> coordinate (optional): [x, y]; text (optional): "shift"|"ctrl"|"alt"|"super" or "+"-joined
  left_click_drag           -> start_coordinate: [x,y]; coordinate: [x,y]; text (optional)
  mouse_move                -> coordinate: [x, y]
  left_mouse_down / left_mouse_up / cursor_position -> {}
  scroll                    -> scroll_direction: "up"|"down"|"left"|"right"; scroll_amount: int; coordinate (optional); text (optional)
  type                      -> text: string
  key                       -> text: e.g. "Return", "ctrl+s", "alt+Tab"; repeat (optional): 1-100, default 1
  hold_key                  -> text: key/combo; duration: seconds, max 300
  wait                      -> duration: seconds, max 300

RESPONSE SHAPE: tool_use.name is the member name, the block carries toolset_name: "computer", and input has NO "action" key. Your tool_result must echo the same toolset_name.

REJECTED (invalid_request_error): name, display_width_px, display_height_px, display_number, enable_zoom.

--- AGENT SDK (Python), the harness layer ---

pip install claude-agent-sdk                 # PyPI: claude-agent-sdk 0.2.148, MIT, Python >=3.10
npm install @anthropic-ai/claude-agent-sdk   # npm 0.3.251

import asyncio
from claude_agent_sdk import query, ClaudeAgentOptions, AssistantMessage, ResultMessage

async def main():
    async for message in query(
        prompt="Review utils.py for bugs that would cause crashes. Fix any issues you find.",
        options=ClaudeAgentOptions(
            allowed_tools=["Read", "Edit", "Glob"],
            permission_mode="acceptEdits",
        ),
    ):
        ...

asyncio.run(main())

PERMISSION CALLBACK (exact, from src/claude_agent_sdk/types.py):

CanUseTool = Callable[
    [str, dict[str, Any], ToolPermissionContext], Awaitable[PermissionResult]
]

@dataclass
class PermissionResultAllow:
    behavior: Literal["allow"] = "allow"
    updated_input: dict[str, Any] | None = None
    updated_permissions: list[PermissionUpdate] | None = None

@dataclass
class PermissionResultDeny:
    behavior: Literal["deny"] = "deny"
    message: str = ""
    interrupt: bool = False

ToolPermissionContext fields usable directly as UI strings:
    tool_use_id, agent_id, blocked_path, decision_reason,
    title         # "Claude wants to read foo.txt"
    display_name  # "Read file"  -> button label
    description   # subtitle

PermissionMode = Literal["default","acceptEdits","plan","bypassPermissions","dontAsk","auto"]

HookEvent = PreToolUse | PostToolUse | PostToolUseFailure | UserPromptSubmit | Stop
          | SubagentStop | PreCompact | Notification | SubagentStart | PermissionRequest

CUSTOM TOOLS (in-process MCP server — how you expose Swift screen/mouse/keyboard to the SDK):
  Python:     @tool decorator + create_sdk_mcp_server(...)  -> options.mcp_servers
  TypeScript: tool(name, description, zodShape, handler, {annotations, searchHint, alwaysLoad})
              + createSdkMcpServer({name, version, instructions, tools, alwaysLoad, timeout})
  ToolAnnotations: readOnlyHint (default false), destructiveHint (default true),
                   idempotentHint (default false), openWorldHint (default true)

--- CLAUDE CODE CLI HEADLESS (exact flags) ---

claude -p "Find and fix the bug in auth.py" --allowedTools "Read,Edit,Bash"
claude -p "Summarize this project" --output-format json | jq -r '.result'
claude -p "Extract fn names" --output-format json \
  --json-schema '{"type":"object","properties":{"functions":{"type":"array","items":{"type":"string"}}},"required":["functions"]}' \
  | jq '.structured_output'
claude -p "Explain recursion" --output-format stream-json --verbose --include-partial-messages
session_id=$(claude -p "Start a review" --output-format json | jq -r '.session_id')
claude -p "Continue that review" --resume "$session_id"
claude --bare -p "Summarize README.md" --allowedTools "Read"      # needs ANTHROPIC_API_KEY

Other flags: --continue, --permission-mode auto|dontAsk|acceptEdits, --append-system-prompt,
--append-system-prompt-file, --system-prompt, --settings <file-or-json>, --mcp-config <file-or-json>,
--agents <json>, --plugin-dir <path>, --plugin-url <url>, --add-dir, --forward-subagent-text.
Env: MCP_TIMEOUT (30s default), CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS, CLAUDE_CODE_FORWARD_SUBAGENT_TEXT.

--- CLAUDE CODE BUILT-IN COMPUTER USE (interactive only) ---
/mcp  -> select `computer-use` -> Enable    (persists per project; macOS + Pro/Max + claude.ai auth only)
NOT available with -p, therefore NOT available via the Agent SDK.
