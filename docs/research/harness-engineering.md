# Harness engineering as a named discipline; awesome-harness-engineering taxonomy; Vercel AI SDK harness primitives; SDK choice for a Swift-UI / TS-or-Python-core Mac computer-use agent

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

Both resources in the brief are real and current. "Harness engineering" is now a genuinely named discipline with vendor essays (Anthropic, OpenAI, LangChain, Red Hat) and a Martin Fowler / Birgitta Böckeler synthesis, and ai-boost/awesome-harness-engineering (3,886 stars, CC0, pushed 2026-08-27) is its best index — organized into 12 Design Primitives that map almost one-to-one onto what Bot-Harness must build. The important falsification: "AI SDK harnesses" does NOT mean loop primitives. It is a brand-new experimental package family (@ai-sdk/harness, v1.0.93) that wraps existing agent runtimes (Claude Code, Codex, Cursor, Cline, OpenCode, Pi, Grok Build, Deep Agents, fx) and, critically, @ai-sdk/harness-claude-code explicitly requires a sandbox provider that exposes a network port, with @ai-sdk/sandbox-vercel as "the supported choice today." That makes the Vercel harness layer cloud-sandbox-shaped and a poor fit for an app whose whole point is driving the local Mac. The real loop primitives (isStepCount, prepareStep, pruneMessages, toolApproval) live in the plain `ai` package (v7.0.84) and are usable standalone. For Bot-Harness the strongest ergonomics come from the Claude Agent SDK directly: it ships the six-step permission pipeline, PreToolUse hooks, subagents, sessions, compaction and skills as built-ins, and Anthropic documents the exact escape hatch for a Swift UI — run the CLI as a subprocess with `-p` and `--output-format json`.

## Recommendation

Use the Claude Agent SDK as the harness core, in Python 3.10, and do not adopt @ai-sdk/harness.

Why, concretely:

1. The Vercel harness layer is architecturally wrong for this app. @ai-sdk/harness-claude-code is a wrapper around @anthropic-ai/claude-agent-sdk that ships a bridge process into a sandbox and requires a sandbox provider exposing a network port, with @ai-sdk/sandbox-vercel named as the only supported provider today. Bot-Harness's entire value is a local agent holding real macOS permissions on the user's own machine. Taking the Vercel layer means taking a cloud sandbox and losing the local machine, or waiting on an unofficial provider. The whole package family is also still marked experimental at 1.0.x.

2. The Claude Agent SDK gives you as built-ins the exact things the awesome list's Design Primitives say you must build: the six-step permission pipeline (the audit and gating story), PreToolUse hooks (the one place that sees every tool call, and therefore where the decision log writes), subagents, sessions with resume and fork, context compaction, and skills and memory auto-loaded from .claude/. Building those bespoke is weeks of work you would then maintain against a moving model.

3. Language choice. Kunal is a heavy Claude Code user and has Python 3.10, which exactly meets claude-agent-sdk's requires_python >=3.10. Python also keeps the door open to macOS automation via PyObjC and to the computer-use screenshot loop in anthropics/claude-quickstarts. TypeScript on Node 24 is a defensible alternative with better streaming-to-UI ergonomics, but it buys nothing the Python SDK lacks and adds a runtime. Pick one; do not run both.

4. Swift/Python boundary. Do not look for a Swift SDK — the community ones (terryso/open-agent-sdk-swift at 27 stars, then 6, 5, 4 and 2 stars) are too thin to depend on. Anthropic documents the supported alternative: run the CLI as a subprocess with `-p` and `--output-format json`. For a polished app, go one better than raw CLI: run the Python agent core as a long-lived local child process of the Swift app and speak newline-delimited JSON over stdio (the same pattern OpenAI uses for the Codex app server: Item/Turn/Thread over JSONL). Swift owns the window, the three panes, the TCC permission prompts and screen capture; Python owns the loop, tools, permissions and logs. That boundary also matches the "agent harness belongs outside the sandbox" argument: the Swift host holds credentials and OS grants, and the tool execution surface is the constrained side.

5. Steal these primitives from the AI SDK even without using it: pruneMessages as the context-budgeting seam, prepareStep as the per-iteration hook where you swap models and trim history, ToolCallRepairFunction as the retry-on-malformed-tool-call pattern, and the typed streaming part states (input-streaming, input-available, output-available) as the exact state machine the center conversation pane should render.

First concrete steps: copy templates/HARNESS_CHECKLIST.md into the repo as the ship gate; write PLAN.md and IMPLEMENT.md at the root and have the agent append to IMPLEMENT.md on every decision (that is the audit log, the file-as-scratchpad and the future-agent handoff in one artifact); wire a PreToolUse hook that appends every tool call, its arguments and its resolution to a JSONL decision log before anything else runs.

## Risks

- The @ai-sdk/harness family is experimental at 1.0.x and its API is visibly in flux (isStepCount vs the stepCountIs alias is evidence of recent renaming in `ai` v7 itself). Anything built on it will need rework.
- The Claude Agent SDK is MIT-licensed code but its use is governed by Anthropic's Commercial Terms of Service, and Anthropic explicitly does not allow third-party developers to offer claude.ai login or rate limits in products built on it without prior approval — Bot-Harness must use API key auth. If it ever ships beyond personal use, Anthropic's branding rules also forbid calling it 'Claude Code' or mimicking Claude Code visual elements.
- Permission gating has a sharp edge that defeats naive implementations: auto-approved tools never reach canUseTool. If the confirmation UI lives in canUseTool while bypassPermissions or bare allowedTools entries are set, the gate is silently bypassed. The correct place is a PreToolUse hook. The TypeScript SDK emits process warning CLAUDE_SDK_CAN_USE_TOOL_SHADOWED for this; the Python SDK may not.
- Subagents inherit the parent permission mode, and bypassPermissions, acceptEdits and auto cannot be overridden per subagent. A permissive parent silently grants full system access to every spawned subagent — a real hazard for a computer-use agent on a personal Mac.
- No official local-macOS sandbox exists in either ecosystem. Cursor's Seatbelt-based approach is the public prior art but you would implement it yourself. Until then the isolation story rests on Claude Agent SDK deny rules plus a PreToolUse hook, which is policy-level, not kernel-level.
- The awesome list is broad but not curated for link freshness: at least one entry (anthropics/ai-harness-scorecard) 404s and two repos are linked under stale names. Treat entries as leads and verify before adopting.
- The `ai` package's canonical stop-condition name changed to isStepCount with stepCountIs kept only as an alias, so any tutorial written against AI SDK v5 reads as correct while sitting on a deprecation path.
- Running the agent core as a subprocess of a Swift app means you own process supervision, crash recovery and resume. The SDK's session detach/stop/resume semantics help, but the plumbing is yours.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- CORRECTION TO THE BRIEF: 'Vercel AI SDK harness primitives' conflates two different things. The ai-sdk-harnesses docs section is NOT about stopWhen/prepareStep/loop control — it is a wrapper for running third-party agent runtimes (Claude Code, Codex, Cursor and others) inside a sandbox. stopWhen, prepareStep, activeTools and the Agent class live in the plain `ai` package under /docs/agents/loop-control, a separate docs section.
- CORRECTION: the exact symbol is `isStepCount`, not `stepCountIs`, in ai@7.0.84. `stepCountIs` exists only as `isStepCount as stepCountIs` in the export list. Verified by reading package/dist/index.d.ts from the published npm tarball.
- DEAD LINK in the awesome list: https://github.com/anthropics/ai-harness-scorecard returns HTTP 404 via both the GitHub API and the web. It is listed under Security, Sandbox & Permissions as 'Scores repositories on AI harness safeguards.' Either renamed, made private, or never public.
- STALE LINKS in the awesome list: it links anthropics/anthropic-quickstarts (now anthropics/claude-quickstarts) and affaan-m/everything-claude-code (now affaan-m/ECC). Both redirect, but the names in the list are outdated.
- COULD NOT FETCH: https://openai.com/index/harness-engineering/ returns HTTP 403 to both curl and WebFetch (bot blocking). It is the awesome list's first Foundations entry, described as OpenAI's framing of harness engineering as a discipline, but I could not read it and cannot confirm its content or date. The same likely applies to the other openai.com/index/* entries (Unrolling the Codex Agent Loop, Unlocking the Codex Harness).
- UNVERIFIED: @lgrammel/apple-container-sandbox 1.1.0 (MIT) exists on npm with the description 'AI SDK sandbox provider backed by Apple Container Sandboxes', but the package publishes no README to the registry and I did not read its source. I cannot confirm whether it exposes ports, which the Claude Code harness adapter requires.
- UNVERIFIED: the awesome list's descriptive claims about individual third-party projects (star counts, and benchmark numbers such as '77% token reduction', 'rank 30 to top 5 on Terminal Bench 2.0', 'harness setup alone can swing benchmarks by 5+ percentage points') are the list author's own summaries. I verified none of them against the underlying sources. Treat all such figures as unconfirmed until checked.
- UNVERIFIED: the AI SDK Skills and Terminal UI pages return HTTP 200 but I did not read their contents, so the skills API shape beyond createClaudeCode({ skills: [{ name, description, content }] }) is not characterized.
- PARTIALLY VERIFIED: Cursor's macOS Seatbelt sandboxing post is cited by the awesome list and the URL is plausible, but I did not fetch https://cursor.com/blog/agent-sandboxing directly and am relying on the list's description.
- NOT INVESTIGATED (out of scope but load-bearing for the recommendation): whether the OpenAI Agents SDK (@openai/agents 0.17.0, confirmed to exist at that version) offers comparable permission and hook primitives. I did not read its docs, so the three-way comparison rests on the Claude Agent SDK and the AI SDK only. The Codex SDK route (@openai/codex-sdk driving the codex CLI) is structurally the same subprocess pattern as Claude Code and would need its own evaluation.
- PERPLEXITY MCP UNAVAILABLE: the perplexity tools returned 401 insufficient_quota, so no Perplexity-sourced facts are in this report. All findings come from direct fetches of GitHub, npm, PyPI and vendor docs.

## Verified facts

- ai-boost/awesome-harness-engineering exists and is active: 3,886 stars, 469 forks, created 2026-03-29, last pushed 2026-08-27, default branch `main`, not archived. GitHub's license field reports NOASSERTION but the repo's LICENSE file is CC0 1.0 Universal, matching the README badge.  
  — **confirmed** · <https://api.github.com/repos/ai-boost/awesome-harness-engineering>
- The list's stated thesis: "This list focuses on the *harness*, not the model. Every component here exists because the model can't do it alone — and the best harnesses are designed knowing those components will become unnecessary as models improve."  
  — **confirmed** · <https://raw.githubusercontent.com/ai-boost/awesome-harness-engineering/main/README.md>
- The README taxonomy is: Foundations; Design Primitives (12 subcategories: Agent Loop, Planning & Task Decomposition, Context Delivery & Compaction, Tool Design, Skills & MCP, Permissions & Authorization, Memory & State, Task Runners & Orchestration, Verification & CI Integration, Observability & Tracing, Debugging & Developer Experience, Human-in-the-Loop); Reference Implementations (Tutorials & Educational, Generators & Meta-Harnesses, Demo Harnesses, Adjacent Collections); Security, Sandbox & Permissions; Evals & Verification; Templates; Production Infrastructure & Operations; Related Awesome Lists.  
  — **confirmed** · <https://raw.githubusercontent.com/ai-boost/awesome-harness-engineering/main/README.md>
- The repo ships four copy-and-adapt harness artifact templates: templates/AGENTS.md, templates/PLAN.md, templates/IMPLEMENT.md, templates/HARNESS_CHECKLIST.md. HARNESS_CHECKLIST.md is a real usable review checklist with sections for Agent instructions, Tool design, Context delivery, Planning artifacts, Permissions & sandbox, Verification loop, and a final table headed "When this harness component should be removed" with columns Component / Exists because / Can be removed when.  
  — **confirmed** · <https://raw.githubusercontent.com/ai-boost/awesome-harness-engineering/main/templates/HARNESS_CHECKLIST.md>
- Birgitta Böckeler's Martin Fowler article (April 2, 2026) defines the harness as "everything in an AI agent except the model itself" and splits harness controls two ways: feedforward (guides that steer the agent before it acts — docs, linters) vs feedback (sensors that let it self-correct), and computational (deterministic: tests, linters, type checkers) vs inferential (LLM-as-judge).  
  — **confirmed** · <https://martinfowler.com/articles/harness-engineering.html>
- Vercel AI SDK defines a harness as: "A harness is a complete agent runtime, such as Claude Code, Codex, or Pi. It owns capabilities that are larger than a model call: workspace access, built-in coding tools, native session state, compaction, permission flows, and runtime-specific configuration." The docs section has 8 pages: Overview, HarnessAgent, Tools, Skills, Harness Adapters, Workflow Utilities, UI, Terminal UI.  
  — **confirmed** · <https://ai-sdk.dev/docs/ai-sdk-harnesses/overview>
- The AI SDK harness packages are all marked experimental and are new: @ai-sdk/harness 1.0.93, @ai-sdk/harness-claude-code 1.0.97, @ai-sdk/harness-codex 1.0.95, @ai-sdk/sandbox-vercel 1.0.93. @ai-sdk/harness-claude-code is described on npm as a "HarnessV1 adapter backed by @anthropic-ai/claude-agent-sdk" — it wraps the Claude Agent SDK rather than replacing it.  
  — **confirmed** · <https://registry.npmjs.org/@ai-sdk%2Fharness-claude-code/latest>
- Blocking constraint for a local Mac app: the Claude Code harness adapter README states "The adapter requires a `HarnessV1SandboxProvider` whose handles expose at least one port — `@ai-sdk/sandbox-vercel` is the supported choice today." The adapter ships a bridge process that runs inside the sandbox and talks to the host over a WebSocket on a sandbox-proxied loopback port, and installs @anthropic-ai/claude-agent-sdk and @anthropic-ai/claude-code inside the sandbox on first session start.  
  — **confirmed** · <https://raw.githubusercontent.com/vercel/ai/main/packages/harness-claude-code/README.md>
- There is no official local-machine sandbox provider. @ai-sdk/sandbox-just-bash is in-process only: "an in-process JavaScript bash environment with a virtual filesystem" that "does not expose ports, so it cannot be used with features that require actual network sandboxes" — therefore it cannot back the Claude Code or Codex harness adapters. Third-party providers exist (@lgrammel/apple-container-sandbox 1.1.0 MIT, @e2b/ai-sdk-sandbox, @coder/ai-sdk-sandbox, @openagentsinc/ai-sdk-sandbox-local).  
  — **confirmed** · <https://raw.githubusercontent.com/vercel/ai/main/packages/sandbox-just-bash/README.md>
- Loop-control naming changed in ai v7. The published type declarations of ai@7.0.84 show canonical exports `isStepCount(stepCount: number): StopCondition<any, any>`, `hasToolCall<TOOLS>(...toolName): StopCondition`, and `isLoopFinished(): StopCondition<any, any>`. `stepCountIs` survives only as a re-export alias (`isStepCount as stepCountIs`).  
  — **confirmed** · <https://registry.npmjs.org/ai/7.0.84>
- The plain `ai` v7.0.84 package exports harness-grade primitives usable without the harness packages: `Agent`, `ToolLoopAgent`, `PrepareStepFunction`, `activeTools`, `pruneMessages` (context budgeting), `detectToolDrift`, `ToolApprovalConfiguration` / `SingleToolApprovalFunction` / `ToolApprovalStatus` (human-in-the-loop), `ToolCallRepairFunction` (retry on malformed tool calls), `smoothStream`, `uploadSkill`, and `createUIMessageStream` / `toUIMessageStream` for streaming partial results to a UI.  
  — **confirmed** · <https://registry.npmjs.org/ai/7.0.84>
- HarnessAgent's constructor accepts: harness, sandbox, id, model, instructions, output, stopWhen, tools, activeTools, inactiveTools, skills, permissionMode, toolApproval, sandboxConfig, harnessOptions. Sessions expose destroy(), detach(), stop(), hasUnfinishedTurn(), and resume via createSession({ sessionId, resumeFrom }). permissionMode values for built-in harness tools are allow-all (default), allow-edits, allow-reads; toolApproval values are not-applicable, approved, user-approval, denied.  
  — **confirmed** · <https://ai-sdk.dev/docs/ai-sdk-harnesses/harness-agent>
- Nine harness adapters ship today: @ai-sdk/harness-claude-code, -cline, -codex, -cursor, -deepagents, -fx, -grok-build, -opencode, -pi. Listed as coming soon: @ai-sdk/harness-amp, -goose, -mastra.  
  — **confirmed** · <https://ai-sdk.dev/docs/ai-sdk-harnesses/harness-adapters>
- Claude Agent SDK evaluates permissions in a documented six-step order: Hooks → Deny rules → Ask rules → Permission mode → Allow rules → canUseTool callback. Permission modes are default, dontAsk, acceptEdits, bypassPermissions, plan, auto. A PreToolUse hook runs before every other step and its deny applies even in bypassPermissions. Auto-approved tools never reach canUseTool, so per-call gating must use a PreToolUse hook. Mode can be changed mid-session with setPermissionMode() (TS) / set_permission_mode() (Python).  
  — **confirmed** · <https://code.claude.com/docs/en/agent-sdk/permissions>
- The Claude Agent SDK is "available as a library for Python and TypeScript only. To drive the same agent loop from another language, run the CLI as a subprocess with the `-p` flag and `--output-format json`." Built-in capabilities listed: built-in tools, hooks, subagents, MCP, permissions, sessions (resume/fork), skills/commands/memory loaded from .claude/ and ~/.claude/, and plugins.  
  — **confirmed** · <https://code.claude.com/docs/en/agent-sdk/overview>
- claude-agent-sdk (Python) is at 0.2.148, MIT, requires Python >=3.10 — compatible with the Python 3.10 already on the target Mac. The TypeScript @anthropic-ai/claude-agent-sdk is at 0.3.251. anthropics/claude-agent-sdk-python has 7,998 stars, MIT, last pushed 2026-08-28.  
  — **confirmed** · <https://pypi.org/pypi/claude-agent-sdk/json>
- Anthropic's reference harness for the screenshot-action computer-use loop lives at anthropics/claude-quickstarts (17,570 stars, MIT, pushed 2026-08-25) — the repo was renamed from anthropics/anthropic-quickstarts. It contains computer-use-demo, computer-use-best-practices, browser-use-demo, autonomous-coding and agents directories.  
  — **confirmed** · <https://api.github.com/repos/anthropics/claude-quickstarts>
- Cursor has published a cross-platform local agent sandbox implementation using macOS Seatbelt (plus Linux Landlock+seccomp and Windows WSL2) — the closest public prior art for sandboxing a local Mac agent without containers, cited by the awesome list.  
  — likely · <https://cursor.com/blog/agent-sandboxing>
- The awesome list cites 'The Agent Harness Belongs Outside the Sandbox' (Andrea Luzzardi, April 2026), arguing the agent loop should run outside the sandbox so credentials stay out of it — directly relevant to splitting a Swift host that holds OS permissions from a constrained execution surface.  
  — likely · <https://www.mendral.com/blog/agent-harness-belongs-outside-sandbox>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [ai-boost/awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering) | adopt — copy HARNESS_CHECKLIST.md into the repo now as the ship gate, and use the 12 Design Primitives as the literal module list for the Bot-Harness agent core. | The index for the discipline. ~640 lines, 12 Design Primitive categories, each entry annotated with why it matters. Ships 4 reusable templates (AGENTS.md, PLAN.md, IMPLEMENT.md, HARNESS_CHECKLIST.md). | 3,886 (469 forks) | CC0 1.0 (LICENSE file); GitHub API reports NOASSERTION | pushed 2026-08-27 |
| [vercel/ai (the `ai` package, v7.0.84)](https://github.com/vercel/ai) | evaluate — good if the agent core is TypeScript and you want to own the loop. Use the `ai` package directly; do not take the @ai-sdk/harness packages. | Core AI SDK. Provides the harness primitives that matter standalone: Agent/ToolLoopAgent, stopWhen with isStepCount/hasToolCall/isLoopFinished, prepareStep, activeTools, pruneMessages, ToolApprovalConfiguration, ToolCallRepairFunction, smoothStream, UI message streaming. | 26,483 | NOASSERTION (Apache-2.0 in repo) | pushed 2026-08-29 |
| [@ai-sdk/harness + @ai-sdk/harness-claude-code](https://ai-sdk.dev/docs/ai-sdk-harnesses/overview) | reject for Bot-Harness — the Claude Code adapter requires a sandbox provider exposing a network port and names @ai-sdk/sandbox-vercel as the only supported one today, which is the opposite of driving the user's own Mac. Worth watching for its tool/approval API shape. | Experimental wrapper that runs an existing agent runtime (Claude Code, Codex, Cursor, Cline, OpenCode, Pi, Grok Build, Deep Agents, fx) inside a network sandbox and exposes generate()/stream() with AI SDK-compatible results. | n/a (part of vercel/ai) | Apache-2.0 (monorepo) | @ai-sdk/harness 1.0.93 / harness-claude-code 1.0.97 |
| [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) | adopt — the highest harness ergonomics per line of code, and the Mac's existing Python 3.10 already satisfies requires_python >=3.10. | Runs the Claude Code agent loop in your own process. Ships the six-step permission pipeline, PreToolUse/PostToolUse hooks, subagents, sessions with resume/fork, MCP, skills and memory loaded from .claude/, and plugins. | 7,998 | MIT (SDK code; use governed by Anthropic Commercial ToS) | pushed 2026-08-28 |
| [anthropics/claude-quickstarts (computer-use-demo)](https://github.com/anthropics/claude-quickstarts) | reference-only — the loop shape and tool definitions are the canonical starting point for the live-computer-view pane; the demo itself is Linux/Docker-oriented, not macOS-native. Note the repo was renamed from anthropics/anthropic-quickstarts. | Anthropic's reference harness for the screenshot-action computer-use loop, plus computer-use-best-practices, browser-use-demo, and autonomous-coding. | 17,570 | MIT | pushed 2026-08-25 |
| [@lgrammel/apple-container-sandbox](https://www.npmjs.com/package/@lgrammel/apple-container-sandbox) | evaluate — if the AI SDK harness layer is ever wanted on a Mac, this is the only plausible provider. Unverified whether it exposes ports, which the Claude Code adapter requires. | AI SDK sandbox provider backed by Apple Container Sandboxes — the only Mac-native sandbox provider visible in the AI SDK ecosystem, authored by an AI SDK maintainer. | n/a (npm-only) | MIT | v1.1.0 |
| [RUCAIBox/awesome-agent-harness](https://github.com/RUCAIBox/awesome-agent-harness) | reference-only — useful when you want research backing for a design choice, not for implementation. | Academic survey and reading list on 'Agent Systems with Harness Engineering', 500+ references across agent workflows, memory, skill libraries, multi-agent orchestration. | 183 | MIT | pushed 2026-05-25 |
| [affaan-m/ECC (formerly everything-claude-code)](https://github.com/affaan-m/ECC) | reference-only — the most-starred entry in the list, but it is a Claude Code configuration bundle, not a harness you embed in a Mac app. Mine it for skill and memory patterns. | Skills / instincts / memory harness optimization system for Claude Code. The awesome list still links it under its old name. | 244,076 | MIT | pushed 2026-08-29 |

## API and code shape

// ============================================================
// 1) Vercel AI SDK — loop control in the PLAIN `ai` package (v7.0.84)
// ============================================================
import { Agent, generateText, tool, isStepCount, hasToolCall, isLoopFinished, pruneMessages } from 'ai';

// stop conditions (canonical v7 names; `stepCountIs` is only an alias of `isStepCount`)
declare function isStepCount(stepCount: number): StopCondition<any, any>;
declare function hasToolCall<TOOLS extends ToolSet>(...toolName: Array<keyof TOOLS | (string & {})>): StopCondition<TOOLS>;
declare function isLoopFinished(): StopCondition<any, any>;

// custom stop condition (verbatim from the docs)
const hasAnswer = ({ steps }) => {
  return steps.some(step => step.text?.includes('ANSWER:')) ?? false;
};

// prepareStep runs before each loop iteration; receives { stepNumber, messages, steps, model }
// and can switch models, prune/summarize messages, and set activeTools / toolChoice.
// forced-completion pattern: toolChoice: 'required' + a `done` tool with no `execute`.

// ============================================================
// 2) HarnessAgent (@ai-sdk/harness) — verbatim from the package README
// ============================================================
// npm i ai zod @ai-sdk/harness @ai-sdk/harness-claude-code @ai-sdk/sandbox-vercel
import { HarnessAgent } from '@ai-sdk/harness/agent';
import { claudeCode, createClaudeCode } from '@ai-sdk/harness-claude-code';
import { createVercelSandbox } from '@ai-sdk/sandbox-vercel';
import { tool } from 'ai';
import { z } from 'zod/v4';

const agent = new HarnessAgent({
  harness: claudeCode,
  id: 'auth-agent',
  model: 'claude-sonnet-4-5',
  instructions: 'You are a careful refactoring assistant. Prefer minimal diffs.',
  sandbox: createVercelSandbox({ runtime: 'node24', ports: [4000] }),
  sandboxConfig: {
    bootstrapHash: 'ripgrep-v1',
    onBootstrap: async ({ session, abortSignal }) => { /* install deps once */ },
    onSession:   async ({ session, sessionWorkDir, abortSignal }) => { /* per-session files */ },
  },
  tools: {
    deploy: tool({
      description: 'Deploy to a target environment',
      inputSchema: z.object({ env: z.enum(['staging', 'production']) }),
      execute: async ({ env }) => ({ url: `https://${env}.example.com` }),
    }),
  },
  activeTools: ['weather'],                    // allowlist
  inactiveTools: ['bash', 'write'],            // denylist
  permissionMode: 'allow-all',                 // | 'allow-edits' | 'allow-reads'
  toolApproval: { weather: 'user-approval' },  // 'not-applicable'|'approved'|'user-approval'|'denied'
  harnessOptions: { 'claude-code': { thinking: { type: 'adaptive', display: 'summarized' } } },
});

const session = await agent.createSession();
const result  = await agent.generate({ session, prompt: 'Fix the failing test in src/auth.ts' });
const s       = await agent.stream({ session, prompt: 'Now write a regression test' });
for await (const part of s.stream) { if (part.type === 'text-delta') process.stdout.write(part.text); }
// session lifecycle: session.destroy() | session.detach() | session.stop() | session.hasUnfinishedTurn()
// resume:  await agent.createSession({ sessionId: chatId, resumeFrom: resumeState })
// client-side tools omit `execute`; the turn suspends via suspendTurn() / continueStream()

// UI exports (from `ai`): useChat, DefaultChatTransport, convertToModelMessages,
// createUIMessageStream, createUIMessageStreamResponse, toUIMessageStream,
// getHarnessErrorMessage, InferUITools, UIMessage.
// Streamed parts are typed: tool-bash, tool-read, tool-<yourTool>, plus dynamic parts for
// file changes and compaction; each carries state: 'input-streaming'|'input-available'|'output-available'.

// Vercel Workflow helpers (workflow-utilities page):
// runHarnessAgentStep(), runHarnessAgentTimeSlice()   // 750-second default wall-clock slice
// createHarnessWorkflowState(), finalizeHarnessWorkflow(), loadResumeStep(), persistResumeStep()

# ============================================================
# 3) Claude Agent SDK — the shape Bot-Harness should actually use
# ============================================================
# pip install claude-agent-sdk        (requires_python >=3.10; MIT; v0.2.148)
import asyncio
from claude_agent_sdk import query, ClaudeSDKClient, ClaudeAgentOptions

async def main():
    async with ClaudeSDKClient(
        options=ClaudeAgentOptions(permission_mode="default")
    ) as client:
        await client.query("Help me refactor this code")
        await client.set_permission_mode("acceptEdits")   # TS: q.setPermissionMode("acceptEdits")
        async for message in client.receive_response():
            if hasattr(message, "result"):
                print(message.result)

asyncio.run(main())

# Locked-down headless agent (TypeScript form, verbatim from the docs):
#   const options = { allowedTools: ["Read", "Glob", "Grep"], permissionMode: "dontAsk" };
#
# Permission evaluation order (six steps, in this order):
#   Hooks -> Deny rules -> Ask rules -> Permission mode -> Allow rules -> canUseTool
# Modes: default | dontAsk | acceptEdits | bypassPermissions | plan | auto
# Rule syntax:
#   allowed_tools=["Read","Grep"]           # auto-approve
#   disallowed_tools=["Bash"]               # removes the tool definition entirely
#   disallowed_tools=["Bash(rm *)"]         # denied in EVERY mode incl. bypassPermissions
#   disallowed_tools=["*"] / ["mcp__*"]     # tool-name globs allowed in DENY rules only
#   Edit(//secrets/**)                      # `//` = absolute filesystem path; `/` = anchored at rule source
# Gotcha: auto-approved tools never reach canUseTool. For a check on EVERY call use a PreToolUse hook.
# TS warning code emitted when canUseTool is shadowed: CLAUDE_SDK_CAN_USE_TOOL_SHADOWED

# ============================================================
# 4) Driving the same loop from Swift (documented escape hatch)
# ============================================================
claude -p "<prompt>" --output-format json
