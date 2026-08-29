# Agent runtime for Bot-Harness: loop, planning, verification, recovery, memory, context management (verified 2026-08-29)

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The published state of the art in 2026 is much simpler than the framework market suggests: a plain tool-use loop, ground truth pulled from the environment after every action, a hard iteration cap, a stuck detector, and the file system used as memory. Anthropic has since shipped the three hardest parts of this as server-side API features you can just turn on — context editing (clear_tool_uses_20250919), server-side compaction (compact_20260112), and the client-side memory tool (memory_20250818) — so a Swift app does not need a Python agent framework to get compaction, memory, or context management. Two of your brief's assumptions are wrong today: Google ADK's Sequential/Parallel/LoopAgent primitives are all marked @deprecated in favour of a new `Workflow` primitive in ADK 2.8.0, and OpenHands has been renamed (All-Hands-AI/OpenHands → OpenHands/OpenHands) and re-launched as "Agent Canvas", an Electron control centre that drives Claude Code and Codex over the Agent Client Protocol — which is very close to what you are building. For a single-user Mac app the right memory architecture is markdown files plus git, not mem0/Letta/Zep; every one of those adds a server, an embedding store and a retrieval-quality problem you do not have with one user and a few hundred notes.

## Recommendation

**Build the loop yourself in Swift. Adopt no agent framework.** ADK and the OpenAI Agents SDK are both Python, both would force a sidecar process into a Mac-native app, and ADK's orchestration primitives are actively deprecating underneath you. Everything they'd give you that you actually need — compaction, memory, tracing, tool loop — Anthropic now ships as API features or as a CLI you can spawn.

**Runtime, concretely.** Two viable spines, pick by how much control you want:
1. *Spawn `claude -p --output-format stream-json`* from Swift and parse NDJSON. You inherit Claude Code's loop, compaction, permission modes, subagents and skills for free, and the stream is already a structured audit log (`parent_tool_use_id` gives you the subagent tree). Ship this first. Use `--bare` so a stray `~/.claude` hook doesn't change behaviour between runs.
2. *Talk to the Messages API directly* when you need the computer-use toolset wired to your own ScreenCaptureKit/CGEvent layer. Turn on `clear_tool_uses_20250919` with `keep: 3` and `exclude_tools: ["memory"]` — with computer use, stale screenshots are 80%+ of your context, and this is the single highest-leverage config line in the whole system.

**Verification: deterministic first, judge last.** For computer-use, an LLM judge on screenshots is expensive and unreliable as a gate. Layer it: (a) deterministic post-conditions the agent declares *before* acting ("file exists at path", "window title contains X", "process running", accessibility-tree query returns element) — these are cheap, fast, and honest; (b) the screenshot-after-every-action self-check, which Anthropic prompts for verbatim and which is genuinely load-bearing; (c) an LLM judge only for end-state evaluation of the whole task, scored 0.0-1.0 against a fixed rubric, and only for offline eval runs — never in the hot loop. Anthropic's own harness post is blunt that Claude will mark features passing before end-to-end verification unless you force real execution, so make "verified" a state that only a deterministic check can set.

**Recovery: git is your undo stack.** Anthropic's long-running-agent harness uses git commits as the checkpoint mechanism and reverts to recover. For a computer-use agent, add: a per-task working directory committed after each verified step, and — for OS-level actions — a pre-action snapshot of whatever you can cheaply snapshot (clipboard, frontmost app, window geometry). Resume from checkpoint, never restart; Anthropic states plainly that restarts are expensive and frustrating for users.

**Stuck detection: port OpenHands' detector, don't invent one.** ~200 lines, five patterns, thresholds 4/3/3/6, 20-event window, reset on user message. On trip, escalate through a ladder rather than dying: (1) inject a nudge naming the observed loop, (2) force a `zoom` or a fresh screenshot to break perceptual staleness, (3) re-plan from the progress file, (4) surface to Kunal with the last three screenshots. Also keep an unconditional max-iteration cap per task — the computer-use docs recommend one explicitly.

**Memory: markdown files plus git. Reject mem0, Letta and Zep outright.** Copy Claude Code's exact two-layer shape because it's proven at scale and already familiar to a heavy Claude Code user: a hand-written policy file (`HARNESS.md`, under 200 lines, loaded every session) plus an auto-memory directory with a `MEMORY.md` index capped at 200 lines / 25KB and one topic file per lesson, read on demand. Type each memory `user | feedback | project | reference`, stamp `modified` as ISO-8601, and skip anything derivable from the filesystem. Back it with the `memory_20250818` tool so the model edits it through a real tool interface rather than you guessing what to persist. For one user this beats every vector-memory product on latency, debuggability and cost, and it has no retrieval-quality failure mode — you can read the whole thing.

**Per-task state file is non-negotiable.** One JSON file per task, the harness's spine and the thing that survives a context reset: `{goal, plan: [steps], current_step, attempts_on_current_step, verified_steps: [], blocked_reason, artifacts: [paths], last_screenshot}`. Anthropic's feature-list shape (`{"category","description","steps","passes": false}`) is the right model — `passes` flips only on deterministic verification. The memory tool's auto-injected system prompt ("ASSUME INTERRUPTION") is doing exactly this job, so lean on it.

**Trace: one JSONL per task, OTel key names.** Append-only, one line per step, using `gen_ai.*` attribute names verbatim so any tracing UI reads it later. Log: step index, wall clock, the model's stated intent, tool name and full arguments, the verification predicate and its boolean result, token usage split (including cache read/write), the compaction event when it fires, and a content-addressed path to the screenshot rather than the image itself. That last one matters — inline base64 will make the log unusable within a day. Add a `decision_reason` string per step so a future auditing agent can diff intent against outcome; that field is the whole point of the exercise and no framework will add it for you.

**One thing worth stealing from outside this list:** ACP. OpenHands' pivot to Agent Canvas shows the durable design — the GUI owns tasks, permissions and the live view, and agents are swappable behind a JSON-RPC protocol (`initialize`, `session/new`, `session/prompt`, `session/update`, `session/request_permission`). Structure Bot-Harness's Swift internals along those method boundaries even if you never implement ACP on the wire, and you keep the option of running Codex or Gemini later without rewriting the UI.

## Risks

- Screenshot context blowup is the dominant failure mode for computer-use, not reasoning quality. A 2576px screenshot costs up to 4,784 visual tokens; twenty steps without clearing is your whole window. If you don't enable clear_tool_uses_20250919 (or aggressive client-side pruning) on day one you will hit context rot and the agent will start re-clicking things it already clicked — which will then read as a planning bug and send you debugging the wrong layer.
- Compaction and the memory tool are both behind beta headers (compact-2026-01-12, context-management-2025-06-27). Beta types are dated and get superseded — clear_tool_uses_20250919 and clear_thinking_20251015 already show two generations. Isolate every beta type string in one Swift constants file so a rename is a one-line change, and be prepared for the harness to break on an API-side deprecation.
- ADK's Sequential/Parallel/LoopAgent are deprecated in favour of a Workflow primitive that, by Google's own deprecation text, 'cannot yet be used as an LlmAgent sub-agent'. Anyone on the team who adopts ADK now against a tutorial written this year is building on a primitive scheduled for removal, and the replacement is functionally incomplete.
- Prompt injection through the screen is a live, unsolved risk for computer use. Anything visible on Kunal's display — a webpage, an email, a Slack message, a filename — is untrusted input that can instruct the agent. Anthropic's own mitigation list is a dedicated VM, a domain allowlist, and human confirmation for consequential actions; a personal Mac agent with full OS permissions has none of those by construction. Human-in-the-loop on irreversible actions is the only real control you'll have.
- Deterministic verifiers are much harder to write for GUI actions than for code. 'Tests pass' is a clean predicate; 'the email was actually sent' often is not. Expect a long tail of tasks where the only available verifier is a screenshot judged by a model, and budget for that being both slow and wrong sometimes. Do not let a green LLM-judge verdict mark a step verified in the trace — record the verifier kind alongside the result.
- Anthropic's multi-agent numbers (15x token usage, 90.2% improvement) come from a research task with genuinely parallel subtasks. Computer use on a single physical Mac display is serial — one mouse, one keyboard, one screen — so subagents buy you context isolation, not parallelism. Spawning subagents for GUI work will multiply cost without the corresponding speedup.
- The auto-memory index has a hard 200-line / 25KB load ceiling in Claude Code's implementation. If you copy the pattern without copying the enforcement, MEMORY.md will silently grow past the limit and the tail will stop loading — a failure that presents as the agent 'forgetting' things it demonstrably wrote down. Enforce the cap in code and error on overflow, the way Claude Code does.
- OTel GenAI semantic conventions are still marked Status: Development and just moved repos. Attribute names can change. Using them is still right, but write the log through one serialisation function rather than scattering string literals, and version your log format explicitly.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN THE BRIEF: 'google/adk-python ... its primitives (Agent/Runner/Session/Memory/Artifacts/Workflow)'. Sequential/Parallel/LoopAgent are all @deprecated in ADK 2.8.0 in favour of a new Workflow primitive, and the deprecation message states Workflow 'cannot yet be used as an LlmAgent sub-agent'. Treating the classic workflow agents as current, stable primitives is out of date. Verified by reading loop_agent.py, sequential_agent.py and parallel_agent.py on main.
- RENAMED: the OpenHands repo moved from All-Hands-AI/OpenHands to OpenHands/OpenHands, and the product pivoted from a Python agent to 'Agent Canvas', an Electron/TypeScript control centre that drives third-party agents over ACP. The Python agent code moved to OpenHands/software-agent-sdk. Any path like openhands/controller/stuck.py from older write-ups now 404s; the current path is openhands-sdk/openhands/sdk/conversation/stuck_detector.py in the SDK repo.
- 'OpenClaw memory' — named in the brief — I could not confirm the existence of any such project against a live source and did not search exhaustively for it. Treat the name as unverified; it may be a garbled reference to OpenHands, Open WebUI, or Moltbot/Clawdbot-style forks. Do not design around it without confirming it exists.
- The Zep LoCoMo dispute (84% headline corrected to 58.44% under matched evaluation settings) appeared in search results pointing at getzep/zep-papers issue #5, but I did NOT fetch that issue directly. Confidence: likely, not confirmed. The broader point stands on its own — different groups use incompatible LoCoMo judging prompts (token-overlap F1 vs 'be generous with grading' vs a 5-point scale vs unpublished), so cross-paper memory-benchmark numbers are not comparable. Do not pick a memory system on published LoCoMo scores.
- Letta's most recent GitHub release is tagged 0.16.8 (2026-05-14) even though the repo was pushed 2026-08-23; mem0's most recent release tag is a plugin release (deepseek-plugin-v0.1.1) rather than a core version, while PyPI mem0ai is at 2.0.19. Release cadence for both is therefore hard to read from tags alone — I did not verify their actual core release history.
- I did not verify Anthropic's /compact slash command behaviour from its own documentation page; what is confirmed is the server-side compact_20260112 API and the memory doc's statement that project-root CLAUDE.md is re-read from disk and re-injected after /compact. The exact client-side /compact algorithm in Claude Code is inferred from the context-engineering blog post, not from a command reference.
- No source I fetched gives a published, measured stuck-detection threshold for GUI/computer-use agents specifically. The 4/3/3/6 thresholds are OpenHands' defaults for a software-engineering agent; they are real shipped values but they are not tuned for screen interaction, where legitimate repeated actions (scrolling, waiting on a spinner) are far more common. Expect to retune, and exclude wait/screenshot/scroll from identical-action comparison.
- The Anthropic engineering posts were read through WebFetch's markdown conversion, which summarises. Quoted sentences are reproduced as returned and I am confident in them, but I did not diff them against the raw HTML; if you intend to quote them in a public document, re-read the originals.

## Verified facts

- Anthropic distinguishes workflows ("LLMs and tools are orchestrated through predefined code paths") from agents ("LLMs dynamically direct their own processes and tool usage"), and names five workflow patterns: prompt chaining, routing, parallelization (sectioning/voting), orchestrator-workers, evaluator-optimizer. For the agent loop it states it is "crucial for the agents to gain 'ground truth' from the environment at each step (such as tool call results or code execution) to assess its progress", and recommends "stopping conditions (such as a maximum number of iterations) to maintain control".  
  — **confirmed** · <https://www.anthropic.com/engineering/building-effective-agents>
- Anthropic's context-engineering post names five techniques: compaction ("summarizing its contents, and reinitiating a new context window with the summary"), structured note-taking (agent writes notes persisted outside the context window, e.g. NOTES.md), sub-agent architectures (each subagent "returns only a condensed, distilled summary of its work (often 1,000-2,000 tokens)"), just-in-time retrieval (keep "lightweight identifiers (file paths, stored queries, web links)" and load on demand), and context rot (recall degrades as token count grows). Claude Code's compaction is described as preserving "architectural decisions, unresolved bugs, and implementation details".  
  — **confirmed** · <https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents>
- Anthropic's multi-agent research system post reports multi-agent systems consume roughly 15x more tokens than chat (single agents ~4x), that token usage alone explains 80% of performance variance on their browsing evals, and that Opus 4 lead + Sonnet 4 subagents beat single-agent Opus 4 by 90.2%. Its evaluation stack is an LLM-as-judge scoring 0.0-1.0 against a rubric of factual accuracy, citation accuracy, completeness, source quality and tool efficiency, plus end-state evaluation (checkpoints on state changes rather than on the path taken). Reliability comes from resumability from agent checkpoints, durable execution with retry logic, and production tracing of decision patterns without reading conversation content.  
  — **confirmed** · <https://www.anthropic.com/engineering/multi-agent-research-system>
- Anthropic's long-running-agent harness pattern: an initializer agent creates an init.sh that can run the dev server, a claude-progress.txt log, and an initial git commit. Features are tracked in a JSON list of objects shaped {"category", "description", "steps", "passes": false}; agents are told "It is unacceptable to remove or edit tests because this could lead to missing or buggy functionality." Each session onboards by running pwd, reading git logs and progress files, then picking the highest-priority unfinished feature; git is the recovery mechanism for reverting bad changes. Features are marked passing only after end-to-end verification, not when code is written.  
  — **confirmed** · <https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents>
- The Claude memory tool is client-side: you declare {"type": "memory_20250818", "name": "memory"} and implement six commands (view, create, str_replace, insert, delete, rename) against a /memories path prefix you map to real storage. No beta header is required. The API automatically injects a system-prompt block containing "IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE" and "ASSUME INTERRUPTION: Your context window might be reset at any moment, so you risk losing any progress that is not recorded in your memory directory." Path-traversal validation is the implementer's responsibility.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool>
- Server-side context editing exists under beta header anthropic-beta: context-management-2025-06-27, with strategy type clear_tool_uses_20250919 (defaults: trigger 100,000 input_tokens, keep 3 tool_uses, clear_at_least none, clear_tool_inputs false) and clear_thinking_20251015. Separately, server-side compaction exists under anthropic-beta: compact-2026-01-12 with type compact_20260112, default trigger 150,000 input_tokens (minimum 50,000), optional pause_after_compaction and custom instructions; the response carries a content block of type "compaction" and stop_reason "compaction" when paused.  
  — **confirmed** · <https://platform.claude.com/docs/en/build-with-claude/compaction>
- The current computer-use tool is the toolset type computer_toolset_20260801 (supported on claude-opus-5, claude-mythos-5, claude-fable-5, claude-sonnet-5, claude-opus-4-8); it does NOT take display_width_px/display_height_px, and every tool_result must carry "toolset_name": "computer". It adds a `zoom` action taking region [x0,y0,x1,y1] for inspecting small text, while coordinates always remain in full-screenshot pixel space. The docs' verification guidance is verbatim: "After each step, take a screenshot and carefully evaluate if you have achieved the right outcome... Only when you confirm a step was executed correctly should you move on to the next one." Batched actions run sequentially and stop at first failure; the docs explicitly recommend a maximum-iterations safeguard (e.g. 10) to prevent infinite loops.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- OpenHands ships a real, readable StuckDetector with five scenarios: repeating action-observation cycles, repeating action-error cycles, agent monologue (repeated agent messages with no user input), alternating action-observation patterns, and a context-window-error loop. It scans only the last MAX_EVENTS_TO_SCAN_FOR_STUCK_DETECTION = 20 events, and only those after the last user message. Default thresholds in StuckDetectionThresholds are action_observation=4, action_error=3, monologue=3, alternating_pattern=6.  
  — **confirmed** · <https://raw.githubusercontent.com/OpenHands/software-agent-sdk/main/openhands-sdk/openhands/sdk/conversation/stuck_detector.py>
- Claude Code's memory model is two-layer and file-based. Author-written CLAUDE.md loads from managed policy (/Library/Application Support/ClaudeCode/CLAUDE.md on macOS), ~/.claude/CLAUDE.md, ./CLAUDE.md or ./.claude/CLAUDE.md, and ./CLAUDE.local.md, concatenated root-down; @path imports resolve to a maximum depth of four hops; target under 200 lines per file. Auto memory lives at ~/.claude/projects/<project>/memory/ with a MEMORY.md index plus one topic file per memory; only the first 200 lines or 25KB of MEMORY.md is loaded per session and topic files are read on demand. Memory entries carry a type of user | feedback | project | reference and a `modified` ISO-8601 frontmatter timestamp.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- Claude Code headless mode gives a ready-made structured trace: claude -p with --output-format stream-json --verbose --include-partial-messages emits newline-delimited events. system/init reports model, tools, mcp_servers, mcp_server_errors, plugins, plugin_errors and a capabilities array; system/api_retry carries attempt, max_retries, retry_delay_ms, error_status and a categorical error field; subagent messages are identified by parent_tool_use_id (null for the main conversation, and --forward-subagent-text emits their text/thinking at every nesting depth). --output-format json supports --json-schema for typed results and returns total_cost_usd. --bare skips discovery of hooks, skills, MCP, auto memory and CLAUDE.md and is documented as the recommended mode for scripted/SDK calls.  
  — **confirmed** · <https://code.claude.com/docs/en/headless>
- Google ADK is at v2.8.0 (PyPI google-adk 2.8.0, requires_python >=3.10, Apache-2.0, repo google/adk-python 21,323 stars, pushed 2026-08-29). Its Session/State/Memory/Artifact/Runner/Callback/Event/Plugin primitives are real and MCP is supported, and the repo now also has skills/ and telemetry/ packages. However SequentialAgent, ParallelAgent and LoopAgent are ALL decorated @deprecated with the message '... is deprecated in favor of Workflow and will be removed in a future version. Workflow cannot yet be used as an LlmAgent sub-agent.'  
  — **confirmed** · <https://raw.githubusercontent.com/google/adk-python/main/src/google/adk/agents/loop_agent.py>
- OpenAI's Agents SDK is the live successor to Swarm: openai/openai-agents-python is at v0.22.0 (MIT, 29,054 stars, pushed 2026-08-28) with primitives Agent, Runner.run/run_sync, handoffs, guardrails, Sessions (persistent memory within an agent loop) and built-in tracing. openai/swarm is not archived but its README states verbatim: 'Swarm is now replaced by the OpenAI Agents SDK, which is a production-ready evolution of Swarm.'  
  — **confirmed** · <https://raw.githubusercontent.com/openai/swarm/main/README.md>
- OpenTelemetry's GenAI semantic conventions have moved out of the main semantic-conventions repo into open-telemetry/semantic-conventions-genai and are still marked Status: Development (not stable). Relevant attribute names for agent tracing include gen_ai.operation.name (values create_agent, invoke_agent, execute_tool), gen_ai.agent.name, gen_ai.conversation.id, gen_ai.conversation.compacted, gen_ai.tool.name, gen_ai.tool.type, gen_ai.tool.call.id, gen_ai.tool.call.arguments, gen_ai.tool.call.result, gen_ai.response.finish_reasons, gen_ai.usage.input_tokens / output_tokens / cache_read.input_tokens / cache_write.input_tokens / reasoning.output_tokens, plus a gen_ai.memory.* family (memory.query.text, memory.record.id, memory.store.id). Span name for a tool call SHOULD be 'execute_tool {gen_ai.tool.name}'.  
  — **confirmed** · <https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-spans.md>
- Anthropic Agent Skills are a filesystem convention, not a runtime: a skill is a directory containing SKILL.md whose YAML frontmatter requires only `name` and `description`. Three levels of progressive disclosure: (1) name+description pre-loaded into the system prompt at startup for every installed skill, (2) the SKILL.md body loaded only when judged relevant, (3) bundled files referenced by name and read on demand.  
  — **confirmed** · <https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills>
- The Agent Client Protocol (ACP) is a JSON-RPC 2.0 bidirectional protocol with agent-side methods initialize, authenticate, session/new, session/prompt; client-side method session/request_permission; and notifications session/update and session/cancel. It is the interoperability layer OpenHands Agent Canvas uses to drive third-party agents.  
  — **confirmed** · <https://agentclientprotocol.com/protocol/overview>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [OpenHands/software-agent-sdk](https://github.com/OpenHands/software-agent-sdk) | reference-only — port the ~200 lines of stuck-detection logic to Swift; do not take the Python dependency. | OpenHands V1 agent SDK. Contains the single most directly reusable artifact for this project: openhands-sdk/openhands/sdk/conversation/stuck_detector.py, a production stuck detector with five named failure patterns and tuned thresholds, plus a condenser (context compaction) layer. | 1,041 | MIT | 2026-08-29 |
| [OpenHands/OpenHands (formerly All-Hands-AI/OpenHands)](https://github.com/OpenHands/OpenHands) | reference-only — study its ACP backend abstraction and its task/conversation UI split; it is Electron, which is exactly the thing a Swift-native app is trying not to be. | Now 'Agent Canvas' — a self-hosted Electron/TypeScript developer control centre that runs OpenHands, Claude Code, Codex, Gemini or any ACP-compatible agent across local/remote/cloud backends. Closest shipped analogue to Bot-Harness. | 85,523 | MIT | 2026-08-28 |
| [anthropics/claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) | evaluate — the fastest path to a working runtime is to have Swift spawn `claude -p --output-format stream-json` directly and parse NDJSON; the Python SDK is only worth it if you need tool-approval callbacks in Python. | Programmatic wrapper over the Claude Code agent loop, context management and tool set (PyPI claude-agent-sdk 0.2.148, requires_python >=3.10). Same loop that ships in Claude Code. | 7,998 | MIT | 2026-08-28 |
| [google/adk-python](https://github.com/google/adk-python) | reject — Python-only sidecar for a Swift app, and its orchestration primitives are mid-migration: SequentialAgent, ParallelAgent and LoopAgent are all @deprecated in favour of a Workflow primitive that 'cannot yet be used as an LlmAgent sub-agent'. Adopting now means rewriting against an unfinished replacement. | Google Agent Development Kit 2.8.0. Agent/LlmAgent, Runner, SessionService, State, MemoryService, ArtifactService, Callbacks, Events, Plugins, MCP support, plus new workflow/, skills/ and telemetry/ packages. | 21,323 | Apache-2.0 | 2026-08-29 |
| [openai/openai-agents-python](https://github.com/openai/openai-agents-python) | reject for the runtime, reference-only for its guardrails-as-a-first-class-primitive idea. Wrong language, wrong process model for a Mac-native app, and its Sessions abstraction is weaker than plain files. | v0.22.0. Agents, Runner.run/run_sync, handoffs, guardrails, Sessions, built-in tracing. Production successor to Swarm. | 29,054 | MIT | 2026-08-28 |
| [mem0ai/mem0](https://github.com/mem0ai/mem0) | reject — it introduces an extraction LLM call, a vector DB and a retrieval-quality failure mode to solve a problem that, for one user, is a directory of markdown files and grep. | Hosted-or-self-hosted 'universal memory layer': LLM-based fact extraction, vector store, graph store, retrieval API (PyPI mem0ai 2.0.19). | 64,304 | Apache-2.0 | 2026-08-28 |
| [letta-ai/letta](https://github.com/letta-ai/letta) | reject — Letta wants to own the agent loop and run a server. You want to own the loop in Swift. Its one durable idea (agent edits its own memory blocks via tools) is already available to you as Anthropic's memory_20250818 tool. | MemGPT descendant: stateful agents with self-editing core memory, archival memory, a server and its own agent runtime. | 24,485 | Apache-2.0 | 2026-08-23 |
| [getzep/zep](https://github.com/getzep/zep) | reject — server + graph DB for a single-user desktop app, and its headline LoCoMo number is disputed (see unverified_or_stale). | Temporal knowledge-graph memory service for agents. | 4,875 | Apache-2.0 | 2026-08-28 |
| [open-telemetry/semantic-conventions-genai](https://github.com/open-telemetry/semantic-conventions-genai) | adopt (naming only) — use these exact attribute keys in your JSONL step log so a future agent, or any off-the-shelf tracing UI, can read it without a translation layer. Status is still Development, so pin the field names you use. | The relocated home of the OpenTelemetry GenAI semantic conventions (gen_ai.* span attributes, operation names, token-usage metrics, and a new gen_ai.memory.* family). | 302 | Apache-2.0 | 2026-08-27 |

## API and code shape

## 1. Turn on Anthropic's context management instead of writing your own compactor

Server-side compaction (beta header `anthropic-beta: compact-2026-01-12`):

```json
{
  "context_management": {
    "edits": [
      {
        "type": "compact_20260112",
        "trigger": { "type": "input_tokens", "value": 150000 },
        "pause_after_compaction": false,
        "instructions": null
      }
    ]
  }
}
```
Defaults: `trigger.value` 150000 (minimum 50000). Response gains a content block `{"type": "compaction", "content": "..."}`; with `pause_after_compaction: true` you also get `"stop_reason": "compaction"`. Streaming delivers it as one `content_block_delta` with `{"delta": {"type": "compaction_delta", "content": "..."}}`.

Tool-result clearing (beta header `anthropic-beta: context-management-2025-06-27`) — this is the one that matters for computer-use, because old screenshots are the bulk of your context:

```json
{
  "context_management": {
    "edits": [
      {
        "type": "clear_tool_uses_20250919",
        "trigger":        { "type": "input_tokens", "value": 100000 },
        "keep":           { "type": "tool_uses",    "value": 3 },
        "clear_at_least": { "type": "input_tokens", "value": 20000 },
        "exclude_tools":  ["memory"],
        "clear_tool_inputs": false
      }
    ]
  }
}
```
When combining, `clear_thinking_20251015` must be listed first in `edits`. Response reports what happened:
```json
{"context_management": {"applied_edits": [
  {"type": "clear_tool_uses_20250919", "cleared_tool_uses": 8, "cleared_input_tokens": 92000}
]}}
```

## 2. Memory tool — no beta header, six commands, you implement the storage

```json
{"tools": [{"type": "memory_20250818", "name": "memory"}]}
```
Commands your Swift handler must implement, with the exact return strings the docs specify:
- `view` → `"Here's the content of {path} with line numbers:\n"` + 6-char right-aligned line numbers, tab separator, 1-indexed. Directory form: `"Here're the files and directories up to 2 levels deep in {path}, excluding hidden items and node_modules:\n{size}\t{path}"`. Optional `view_range: [start, end]`, `-1` = to end.
- `create` (`path`, `file_text`) → `"File created successfully at: {path}"`
- `str_replace` (`path`, `old_str`, optional `new_str`) → `"The memory file has been edited."`; on miss: ``"No replacement was performed, old_str `{old_str}` did not appear verbatim in {path}."``
- `insert` (`path`, `insert_line`, `insert_text`) → `"The file {path} has been edited."`
- `delete` (`path`) → `"Successfully deleted {path}"` — must reject deleting `/memories` itself
- `rename` (`old_path`, `new_path`) → `"Successfully renamed {old_path} to {new_path}"`

Errors go back as `{"type": "tool_result", "tool_use_id": "...", "content": "Error: ...", "is_error": true}`. Every path must be canonicalised and verified to remain under `/memories` (block `../`, `..\\`, `%2e%2e%2f`).

## 3. Computer tool — current shape

```json
{
  "type": "computer_toolset_20260801",
  "configs": { "zoom": { "enabled": true } },
  "cache_control": { "type": "ephemeral" }
}
```
No `display_width_px` / `display_height_px`. Every result needs the toolset name:
```json
{"type": "tool_result", "tool_use_id": "toolu_...", "toolset_name": "computer", "content": "OK"}
```
Failed action inside a batch, and every action after it:
```json
{"type": "tool_result", "tool_use_id": "...", "toolset_name": "computer",
 "is_error": true, "content": "Not executed: an earlier computer action in this turn failed."}
```
Actions: `screenshot`, `zoom` (`region: [x0,y0,x1,y1]`), `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click`, `left_click_drag` (`start_coordinate`, `coordinate`), `mouse_move`, `left_mouse_down`, `left_mouse_up`, `cursor_position`, `scroll` (`scroll_direction`, `scroll_amount`), `type` (`text`), `key` (`text`, `repeat` 1-100), `hold_key` (`text`, `duration` ≤300s), `wait` (`duration` ≤300s). Screenshot must be pre-scaled to ≤2576px long edge — the API does not downscale for you.

## 4. Stuck detection — port these exact defaults (OpenHands, MIT)

```python
MAX_EVENTS_TO_SCAN_FOR_STUCK_DETECTION: int = 20

class StuckDetectionThresholds(BaseModel):
    action_observation:  int = 4   # identical action AND identical observation, N times
    action_error:        int = 3   # identical action producing errors, N times
    monologue:           int = 3   # N consecutive agent messages, no user input
    alternating_pattern: int = 6   # ABAB action/observation cycling
```
Scan window is the last 20 events, truncated to only those *after the last user message*. A fifth check fires on repeated context-window errors when ≥10 events are present.

## 5. Claude Code headless as your runtime (fastest path for a Swift app)

```bash
claude -p "<task>" \
  --bare \
  --output-format stream-json --verbose --include-partial-messages \
  --permission-mode acceptEdits \
  --allowedTools "Bash,Read,Edit" \
  --append-system-prompt-file ./harness-policy.md \
  --session-id "<uuid>"
```
Resume: `claude -p "<followup>" --resume "$session_id"` (works from any directory as of v2.1.223).
Events you must handle: `system/init` (model, tools, `mcp_servers`, `mcp_server_errors`, `plugins`, `plugin_errors`, `capabilities`), `system/api_retry` (`attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error`), `assistant`/`user` (subagent messages carry `parent_tool_use_id`; main conversation carries `null`), and a final `result` message with cost and session metadata. Add `--forward-subagent-text` to capture subagent text/thinking at all nesting depths. SIGTERM exits 143 and leaves the turn resumable; SIGINT ends the turn cleanly.

## 6. Step-log schema — use OTel GenAI key names verbatim

Per step, one JSONL line:
```
gen_ai.conversation.id, gen_ai.operation.name ("invoke_agent" | "execute_tool"),
gen_ai.agent.name, gen_ai.tool.name, gen_ai.tool.call.id,
gen_ai.tool.call.arguments, gen_ai.tool.call.result,
gen_ai.response.finish_reasons, gen_ai.conversation.compacted,
gen_ai.usage.input_tokens, gen_ai.usage.output_tokens,
gen_ai.usage.cache_read.input_tokens, gen_ai.usage.cache_write.input_tokens,
gen_ai.usage.reasoning.output_tokens
```
Span name for tool calls SHOULD be `execute_tool {gen_ai.tool.name}`.

## 7. The verification prompt Anthropic actually ships for computer use

> "After each step, take a screenshot and carefully evaluate if you have achieved the right outcome. Explicitly show your thinking: 'I have evaluated step X...' If not correct, try again. Only when you confirm a step was executed correctly should you move on to the next one."
