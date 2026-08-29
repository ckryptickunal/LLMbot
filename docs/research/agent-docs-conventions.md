# Repo Markdown structure + .claude/ configuration + decision/change logging conventions that make Claude Code work maximally well on Bot-Harness

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The single highest-leverage change is architectural, not stylistic: Claude Code now has four distinct instruction surfaces with different loading costs, and the brief treats them as one. CLAUDE.md loads every session and should stay under 200 lines; `.claude/rules/*.md` with `paths:` frontmatter load only when Claude touches matching files; skills load only when invoked; hooks are the only mechanism that is deterministic rather than advisory. Two assumptions in the brief are now wrong: Claude Code explicitly does not read AGENTS.md (the docs say so in those words), and custom slash commands have been merged into skills, so `.claude/commands/*.md` is legacy. The hook event list in the brief is also badly incomplete — there are 31 events, not 9. For the decision log you want, a `PostToolUse` hook with matcher `"*"` writing JSONL is correct and cheap, because PostToolUse stdout goes to the debug log rather than into Claude's context, so logging costs zero tokens. The repo already has CHANGELOG.md on Keep a Changelog 1.1.0 and a `docs/decisions/` directory, so the work is finishing that scaffold, not starting it.

## Recommendation

Build a four-tier instruction system in Bot-Harness, matched to how Claude Code actually loads each tier.

TIER 1 — /CLAUDE.md, hard cap 150 lines. This is the only file that pays a token cost on every single session, so it holds nothing derivable from the code. Contents: the exact build and run commands for a Swift 6 Command-Line-Tools-only Mac app (this is the top item — it is unguessable, since there is no Xcode and `xcodebuild` is unavailable, so the swift build invocation must be written down); the non-negotiable logging rule ("every session appends to CHANGELOG.md; every architectural choice gets an ADR in docs/decisions/"); the macOS permission model gotchas (Accessibility, Screen Recording, TCC re-prompting on rebuild) because those are the environment quirks Claude will otherwise rediscover every session; and a short map of the top-level dirs already present (app, core, runtime, evals, scripts, var). Use `<!-- -->` HTML comments for anything aimed at a human maintainer — those are stripped before injection and cost nothing. Do not write a file-by-file description; docs explicitly list that as an exclude.

TIER 2 — .claude/rules/, path-scoped, this is the piece the brief missed and it matters most for you. Swift UI conventions, Python runtime conventions, and shell-script conventions have almost no overlap, and paying for all three on every turn is exactly the bloat that makes Claude ignore instructions. Write swift.md with `paths: ["app/**/*.swift", "core/**/*.swift"]`, python.md with `paths: ["runtime/**/*.py", "scripts/**/*.py", ".claude/hooks/*.py"]`, and ui.md with the GrokBot three-pane layout rules scoped to the view files. Each loads only when Claude opens a matching file.

TIER 3 — .claude/skills/, for procedures. Anything that is a multi-step checklist rather than a standing fact belongs here, because a skill body costs nothing until invoked. Priority skills: `log-decision` (writes the next-numbered MADR file into docs/decisions/ and adds the CHANGELOG line, with `disable-model-invocation: true` so it only fires when you ask), `grant-permissions` (the TCC / tccutil reset sequence), and `ship` (build, sign check, run, screenshot). Note the repo has an empty `.claude/commands/` — leave it empty and use skills, since docs now treat commands as legacy and skills win on name collision.

TIER 4 — hooks, for what must be true regardless of what Claude decides. Ship the PostToolUse decision-log hook in api_or_code_shape as `.claude/hooks/decision_log.py` writing JSONL to `var/log/decisions.jsonl` (there is already a `var/` directory and a `.claude/hooks/trace.py` to reconcile with). Add SessionStart and SessionEnd for run boundaries and UserPromptSubmit to capture the human intent that explains the tool calls that follow — a tool-call log without the prompts is not auditable. Set `"async": true` on the PostToolUse entry so logging never adds latency, and always exit 0.

On the logging conventions specifically: keep the three artifacts separate and do not let them collapse into each other. `var/log/decisions.jsonl` is the machine-written, high-volume, append-only trace — no agent should ever hand-edit it. `CHANGELOG.md` is human-scale, one section per version under Keep a Changelog's six headings, already correctly set up. `docs/decisions/nnnn-*.md` is MADR 4.0.0 — one file per irreversible or expensive-to-reverse choice (the agent loop design, the screen-capture approach, the permission strategy), never for routine implementation. Adopt Conventional Commits so the git history is parseable later, but hold off on git-cliff: your CHANGELOG.md already tells agents to write entries by hand, and running both produces conflicting files. Add git-cliff only when hand-written entries start being skipped.

Finally, add `/llms.txt` at the repo root — an H1, a blockquote describing what Bot-Harness is, and H2 file lists pointing at docs/PRODUCT.md, docs/guides/ENVIRONMENT.md, docs/decisions/, and CHANGELOG.md. Anthropic ships one for their own docs, and it gives any future agent a single cheap entry point into the repo's documentation without reading everything.

Skip AGENTS.md unless a non-Claude agent will genuinely work in this repo. If one will, make AGENTS.md the real file and reduce CLAUDE.md to `@AGENTS.md` plus a short Claude-specific section, so you never maintain two drifting copies.

## Risks

- Version drift is the main hazard. The docs are dense with 'requires Claude Code v2.1.xxx or later' qualifiers and you are on 2.1.238 — below the 2.1.246 needed for /cd to pick up a new directory's project skills. Anything you write against a newer-gated feature will silently not fire rather than error.
- CLAUDE.md is advisory, not enforced. Docs state it is delivered as a user message after the system prompt with 'no guarantee of strict compliance', and permission rules are 'enforced by Claude Code, not by the model.' Any rule in Bot-Harness that must hold — never delete var/log, never write outside the project — needs a PreToolUse hook or a deny rule, not a CLAUDE.md sentence.
- A PostToolUse hook on matcher "*" fires on every single tool call. If the script is slow, synchronous, or crashes, it degrades or breaks every turn. Mitigate with "async": true, a short timeout, a bare try/except around the stdin parse, and an unconditional exit 0. Test it on a throwaway session before trusting it.
- The tool_input field logged by the decision hook can contain file contents, command strings, and anything Claude was about to write. On a computer-use agent that reads the screen, var/log/decisions.jsonl will accumulate sensitive material. Gitignore it, and consider redacting tool_input for Write/Edit rather than logging it whole.
- The repo already has .claude/hooks/trace.py. Adding decision_log.py without reconciling them risks two overlapping logs with different schemas and double latency on every tool call. Read trace.py first and decide whether to extend it instead.
- Hook entries MERGE across settings levels rather than replacing each other, and the user has a substantial global ~/.claude/ setup. A project-level PostToolUse hook will run alongside any global one, not instead of it.
- Deny rules cannot carry allowlist exceptions — specificity does not override the deny→ask→allow order. A broad Bash deny intended as a safety net will silently block the narrower allows you wrote for swift build.
- The gitignore-vs-glob distinction in permission paths is a real footgun: a single leading slash anchors at the settings source, not the filesystem root, so /Users/Kunal/... is NOT an absolute path — it needs //Users/Kunal/...
- MADR 4.0.0 dates from 2024-09-17. It is stable rather than abandoned (repo pushed 2026-08-28), but do not expect new template features. Its license is unclassified by GitHub (NOASSERTION), so read the LICENSE file before copying template text into the repo.
- Over-scaffolding is itself a risk for a solo developer. Four tiers of instruction files, a hook, ADRs, a changelog and an llms.txt is a lot of surface to keep accurate, and stale agent docs are worse than none. Build tier 1 and the hook first; add rules and skills only when a specific mistake recurs.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN BRIEF — the hook event list. The brief names 9 events (PreToolUse/PostToolUse/UserPromptSubmit/Stop/SubagentStop/SessionStart/SessionEnd/Notification/PreCompact). There are 31. Missing ones directly relevant to an audit log include SubagentStart, PostToolUseFailure, PostToolBatch, PermissionRequest, PermissionDenied, TaskCreated, TaskCompleted, FileChanged, ConfigChange, InstructionsLoaded, PostCompact and StopFailure.
- WRONG IN BRIEF — 'custom slash commands (frontmatter fields)' as a separate mechanism. Custom commands have been merged into skills. .claude/commands/*.md still works for backward compatibility but ignores the `name` and `paths` frontmatter fields, and a same-named skill wins. Do not write new command files.
- WRONG IN BRIEF — the implied premise that AGENTS.md might be adopted by Claude Code. It is not: 'Claude Code reads CLAUDE.md, not AGENTS.md.'
- STALE IN BRIEF — the doc URLs. docs.claude.com/en/docs/claude-code/* 301-redirects to code.claude.com/docs/en/*, and the anthropic.com/engineering/claude-code-best-practices blog post 308-redirects into the docs. Any bookmarked or hardcoded doc link in the project needs updating.
- RENAMED — github.com/openai/agents.md is now agentsmd/agents.md, and stewardship moved to the Agentic AI Foundation under the Linux Foundation.
- NOT VERIFIED — llms-full.txt. The llmstxt.org spec page I fetched does not mention an llms-full.txt variant. It is widely used in practice (Anthropic's own docs expose per-page .md files instead), but I could not confirm it is part of the specification.
- PARTIALLY VERIFIED — settings.json key value types. The settings-reference page returned a summarized table rather than verbatim JSON schema, so key NAMES are confirmed but the exact value shapes for `sandbox`, `statusLine` and `outputStyle` are secondhand. Confirm against https://code.claude.com/docs/en/settings-reference.md before writing those keys.
- NOT VERIFIED — statusline, output styles, and plugins. The assignment asked for exact schemas for all three and I did not fetch code.claude.com/docs/en/statusline, /output-styles, or /plugins-reference. Treat those three as open items.
- NOT VERIFIED — MADR template body text. I confirmed the version, filenames and directory from the README but did not fetch adr-template-minimal.md itself, so I cannot quote its section headings verbatim.
- STALE TOOL — npryce/adr-tools has had no commit since 2024-04-25 and generates the older Nygard template, not MADR. It is still widely linked in blog posts, which is how it likely reached the brief.
- LOCAL, NOT CROSS-CHECKED — I read the existing .claude/hooks/trace.py only as a filename; I did not open it. Its schema and whether it already covers decision logging is unresolved and should be checked before adding a second hook.

## Verified facts

- Claude Code docs have MOVED. https://docs.claude.com/en/docs/claude-code/memory returns 301 to https://code.claude.com/docs/en/memory, and https://www.anthropic.com/engineering/claude-code-best-practices returns 308 to https://code.claude.com/docs/en/best-practices. The 'Anthropic engineering blog post' on Claude Code best practices no longer exists as a separate artifact; it is now a docs page.  
  — **confirmed** · <https://code.claude.com/docs/en/best-practices>
- CLAUDE.md load order is broadest-to-most-specific: Managed policy (macOS: /Library/Application Support/ClaudeCode/CLAUDE.md), then user (~/.claude/CLAUDE.md), then project (./CLAUDE.md or ./.claude/CLAUDE.md), then local (./CLAUDE.local.md). All discovered files are CONCATENATED into context rather than overriding each other; content is ordered filesystem-root-down, so instructions closest to launch dir are read last.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- Official CLAUDE.md size guidance: 'target under 200 lines per CLAUDE.md file. Longer files consume more context and reduce adherence.' Claude Code loads a CLAUDE.md of up to 4 MiB in full and SKIPS a larger file. Splitting into @path imports helps organization but does NOT reduce context, since imported files load at launch.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- @import syntax: relative and absolute paths allowed; relative paths resolve relative to the FILE CONTAINING THE IMPORT, not the working directory; recursive imports allowed to a maximum depth of FOUR hops; import parsing skips Markdown code spans and fenced code blocks, so `@README` in backticks stays literal.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- Claude Code does NOT read AGENTS.md. Docs state verbatim: 'Claude Code reads CLAUDE.md, not AGENTS.md.' The recommended bridge is a CLAUDE.md whose first line is `@AGENTS.md`, or a symlink `ln -s AGENTS.md CLAUDE.md`. A `/import` command (v2.1.213+) appends a one-time copy of AGENTS.md into CLAUDE.md.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- AGENTS.md is a real cross-tool convention: root-of-repo markdown, agents read the NEAREST file in the directory tree so the closest takes precedence, 'used by over 60k open-source projects', and it is now stewarded by the Agentic AI Foundation under the Linux Foundation. 26+ tools listed as supporting it (Codex, Cursor, Copilot, Gemini CLI, Zed, Windsurf, Jules, Aider...).  
  — **confirmed** · <https://agents.md/>
- The agents.md GitHub repo has been RENAMED: github.com/openai/agents.md now resolves to agentsmd/agents.md (23,975 stars, MIT, last push 2026-08-25).  
  — **confirmed** · <https://api.github.com/repos/openai/agents.md>
- `.claude/rules/*.md` is the mechanism for scoping instructions. Rules WITHOUT `paths:` frontmatter load at launch with the same priority as .claude/CLAUDE.md. Rules WITH `paths:` glob frontmatter load ONLY when Claude reads a matching file. All .md files are discovered recursively. User-level rules in ~/.claude/rules/ load before project rules, giving project rules higher priority.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- There are 31 hook events, not the 9 named in the brief: SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, DirectoryAdded, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, Elicitation, ElicitationResult, SessionEnd.  
  — **confirmed** · <https://code.claude.com/docs/en/hooks>
- Hook exit-code semantics: exit 0 = success (stdout goes to the DEBUG LOG, except UserPromptSubmit/UserPromptExpansion/SessionStart where plain-text stdout is added as context Claude can see). Exit 2 = blocking error (blocks the tool call on PreToolUse, prevents stopping on Stop/SubagentStop; stderr is the blocking message). Exit 1 is explicitly NOT blocking despite Unix convention — use exit 2.  
  — **confirmed** · <https://code.claude.com/docs/en/hooks>
- Hook matcher syntax has three evaluation paths: `"*"`, `""`, or omitted = match all; a value containing only letters/digits/_/-/spaces/,/| = exact string or |- or ,-separated list of exact strings; ANY other character = unanchored JavaScript regular expression tested with RegExp.prototype.test. So `Edit.*` matches both `Edit` and `NotebookEdit`; use `^Edit$` for whole-string match.  
  — **confirmed** · <https://code.claude.com/docs/en/hooks.md>
- Hook commands receive path placeholders as environment variables: ${CLAUDE_PROJECT_DIR} (project root where the session started), ${CLAUDE_PLUGIN_ROOT}, ${CLAUDE_PLUGIN_DATA}, $CLAUDE_CODE_REMOTE, $CLAUDE_EFFORT. Hook entries MERGE across settings levels rather than replacing each other, and hooks from settings files also run inside subagents.  
  — **confirmed** · <https://code.claude.com/docs/en/hooks.md>
- Hooks support an `if` field using PERMISSION RULE syntax (e.g. "Bash(git *)", "Edit(*.ts)") to filter when the hook runs. It is only evaluated on tool events (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, PermissionDenied); on other events a hook with `if` set NEVER runs. The filter is best-effort — when Claude Code can't determine which commands a Bash input runs, it runs the hook regardless.  
  — **confirmed** · <https://code.claude.com/docs/en/hooks.md>
- Custom slash commands have been MERGED into skills. Docs state: 'A file at .claude/commands/deploy.md and a skill at .claude/skills/deploy/SKILL.md both create /deploy and work the same way.' Existing .claude/commands/ files keep working but `name` and `paths` frontmatter are ignored there. If both exist, the SKILL wins.  
  — **confirmed** · <https://code.claude.com/docs/en/skills>
- SKILL.md frontmatter fields (all optional except as noted): name, description (recommended), when_to_use, argument-hint, arguments, disable-model-invocation, user-invocable, allowed-tools, disallowed-tools, model, effort, context, agent, background, hooks, paths, shell, metadata, license, compatibility. Combined description + when_to_use text is TRUNCATED AT 1,536 CHARACTERS in the skill listing. Frontmatter is only read when the opening `---` is the file's first line.  
  — **confirmed** · <https://code.claude.com/docs/en/skills>
- Skill progressive disclosure is real and measurable: only description/when_to_use sit in context until invocation. On invocation the rendered SKILL.md enters the conversation as a single message and STAYS across later turns; Claude Code does NOT re-read the skill file on later turns. After auto-compaction, the most recent invocation of each skill is re-attached keeping the first 5,000 tokens each, sharing a combined 25,000-token budget. Docs advise keeping SKILL.md under 500 lines and moving reference material to sibling files.  
  — **confirmed** · <https://code.claude.com/docs/en/skills>
- Subagent (.claude/agents/*.md) frontmatter fields: name (required), description (required), tools, disallowedTools, model, permissionMode, maxTurns, skills, mcpServers, hooks, memory, background, effort, isolation, color, initialPrompt, experimental. Precedence: managed > --agents flag > .claude/agents/ > ~/.claude/agents/ > plugin agents/. Subagents DO load the full CLAUDE.md hierarchy at startup but do NOT load conversation history or the main conversation's auto memory.  
  — **confirmed** · <https://code.claude.com/docs/en/sub-agents>
- Permission rules are evaluated in the order deny, then ask, then allow; the first match wins and rule SPECIFICITY DOES NOT CHANGE THE ORDER. A broad deny like Bash(aws *) blocks calls that also match a narrower allow like Bash(aws s3 ls), so deny rules cannot carry allowlist exceptions. A bare tool name deny (e.g. `Bash`) removes the tool from Claude's context entirely; a scoped rule `Bash(rm *)` leaves the tool available.  
  — **confirmed** · <https://code.claude.com/docs/en/permissions>
- Read/Edit permission paths use GITIGNORE pattern syntax, not plain globs, with four pattern types: `//path` = absolute from filesystem root; `~/path` = home; `/path` = relative to the SETTINGS SOURCE (not filesystem root); `path` or `./path` = relative to cwd. Claude Code only consults Edit(path) and Read(path) rules — a path rule written for Write, NotebookEdit, Glob, or MultiEdit is accepted but NEVER CONSULTED and warns at startup.  
  — **confirmed** · <https://code.claude.com/docs/en/permissions>
- Anthropic's own docs site ships the llms.txt convention: https://code.claude.com/docs/llms.txt returns HTTP 200, 45,498 bytes, structured as H1 + blockquote summary + H2 sections of [name](url): description links. Every doc page is also fetchable as raw markdown by appending .md (e.g. https://code.claude.com/docs/en/hooks.md).  
  — **confirmed** · <https://code.claude.com/docs/llms.txt>
- llms.txt spec: file at /llms.txt at site root or any subpath, with more specific files taking precedence. Required structure in order: optional BOM; an H1 with the project name (the ONLY required section); a blockquote short summary; zero or more non-heading markdown sections; zero or more H2-delimited 'file lists' of [name](url) links optionally followed by a colon and notes. An 'Optional' H2 section by convention marks content agents can skip when context is limited.  
  — **confirmed** · <https://llmstxt.org/>
- MADR's current release is 4.0.0, published 2024-09-17. The repo (adr/madr) is active — 2,430 stars, last push 2026-08-28. Templates provided: adr-template.md (all sections with explanations), adr-template-minimal.md, adr-template-bare.md, adr-template-bare-minimal.md. Filename convention is `nnnn-title.md` and the recommended directory is `docs/decisions`.  
  — **confirmed** · <https://raw.githubusercontent.com/adr/madr/main/README.md>
- Keep a Changelog current version is 1.1.0 and defines exactly six change-type headings: Added, Changed, Deprecated, Removed, Fixed, Security.  
  — **confirmed** · <https://keepachangelog.com/en/1.1.0/>
- Conventional Commits 1.0.0 structure is `<type>[optional scope]: <description>` / blank line / `[optional body]` / blank line / `[optional footer(s)]`. fix: = PATCH, feat: = MINOR. Breaking changes are indicated either by a `BREAKING CHANGE:` footer or by appending `!` after the type/scope, correlating with MAJOR. A BREAKING CHANGE can be part of a commit of any type.  
  — **confirmed** · <https://www.conventionalcommits.org/en/v1.0.0/>
- Changelog automation options, live metadata: orhun/git-cliff 12,168 stars, Apache-2.0, last push 2026-08-22, latest release v2.13.1 (2026-04-26) — Rust binary, language-agnostic, no Node dependency. googleapis/release-please 7,416 stars, Apache-2.0, last push 2026-08-24. conventional-changelog/commitlint 18,711 stars, MIT, last push 2026-08-28.  
  — **confirmed** · <https://api.github.com/repos/orhun/git-cliff>
- npryce/adr-tools is effectively unmaintained: 5,632 stars but last push 2024-04-25 (over 2 years stale), not archived. It is a bash script generating Nygard-format ADRs, which is a different template from MADR.  
  — **confirmed** · <https://api.github.com/repos/npryce/adr-tools>
- Official guidance on what HURTS a CLAUDE.md, verbatim: 'Bloated CLAUDE.md files cause Claude to ignore your actual instructions!' and the test 'For each line, ask: Would removing this cause Claude to make mistakes? If not, cut it.' Exclude list includes: anything Claude can figure out by reading code, standard language conventions, detailed API docs, information that changes frequently, file-by-file descriptions of the codebase. Also: 'If you emphasize many lines, none of them stands out.'  
  — **confirmed** · <https://code.claude.com/docs/en/best-practices>
- CLAUDE.md content is delivered as a USER MESSAGE AFTER the system prompt, not as part of the system prompt, so there is no guarantee of strict compliance. Block-level HTML comments (<!-- ... -->) in CLAUDE.md are STRIPPED before injection, so they cost zero context — usable for human-maintainer notes. Project-root CLAUDE.md survives /compact (re-read from disk and re-injected); nested and path-scoped rules only reload when a matching file is touched.  
  — **confirmed** · <https://code.claude.com/docs/en/memory>
- The installed Claude Code on this machine is version 2.1.238, and the Bot-Harness repo already has .claude/{agents,hooks,commands,skills}/ (with .claude/hooks/trace.py), docs/decisions/ with _TEMPLATE.md and README.md, docs/PRODUCT.md, docs/guides/ENVIRONMENT.md, and a CHANGELOG.md already declaring Keep a Changelog 1.1.0 + SemVer 2.0.0. Note 2.1.238 is below the 2.1.246 needed for /cd to pick up a new directory's project skills.  
  — **confirmed** · <local: claude --version and find .claude docs in /Users/Kunal/Desktop/Bot-Harness>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [adr/madr](https://github.com/adr/madr) | adopt — use adr-template-minimal.md as the basis for docs/decisions/_TEMPLATE.md, which the repo already has stubbed. Current release 4.0.0; repo actively maintained. | Markdown Any Decision Records — the ADR template standard. Four template variants; ADRs named nnnn-title.md in docs/decisions. | 2430 | NOASSERTION (GitHub could not classify; verify LICENSE file before vendoring text) | pushed 2026-08-28; latest release 4.0.0 on 2024-09-17 |
| [agentsmd/agents.md](https://github.com/agentsmd/agents.md) | reference-only — Claude Code does not read AGENTS.md. Only worth adding if another agent (Codex, Cursor, Copilot) will touch Bot-Harness; then make CLAUDE.md a one-line `@AGENTS.md` import so there is a single source of truth. | The AGENTS.md cross-tool convention site and spec. Root-of-repo markdown, nearest-file-wins, no required schema. Now under the Agentic AI Foundation (Linux Foundation). | 23975 | MIT | pushed 2026-08-25 |
| [orhun/git-cliff](https://github.com/orhun/git-cliff) | evaluate — the right pick if you want the changelog automated, because it is a single Rust binary (brew install git-cliff) with no Node or Python runtime dependency, which suits a Swift/CLT-only Mac app repo. But the repo's CHANGELOG.md already instructs agents to hand-write entries; do not run both. | Language-agnostic changelog generator that turns Conventional Commits into a Keep a Changelog-shaped CHANGELOG.md via a cliff.toml config. | 12168 | Apache-2.0 | pushed 2026-08-22; latest release v2.13.1 on 2026-04-26 |
| [googleapis/release-please](https://github.com/googleapis/release-please) | reject — it is built around GitHub release PRs and CI. Overkill for a solo-developer local Mac app with no release pipeline. | Automates releases and CHANGELOG generation from Conventional Commits, primarily as a GitHub Action. | 7416 | Apache-2.0 | pushed 2026-08-24 |
| [conventional-changelog/commitlint](https://github.com/conventional-changelog/commitlint) | evaluate — useful only as a git hook to keep agent-written commits parseable. Requires Node (you have Node 24). Lower priority than the decision-log hook. | Lints commit messages against the Conventional Commits spec. | 18711 | MIT | pushed 2026-08-28 |
| [npryce/adr-tools](https://github.com/npryce/adr-tools) | reject — 2+ years without a commit, and it generates the older Nygard template rather than MADR. A five-line shell function that copies docs/decisions/_TEMPLATE.md and increments the number gives you the same thing with no dependency. | Bash CLI (adr new, adr link, adr supersede) that scaffolds Nygard-format ADRs. | 5632 | NOASSERTION | pushed 2024-04-25 (stale, not archived) |

## API and code shape

All schemas below are copied from the live docs pages cited in verified_facts. The two composite files at the end (settings.json and the log hook) are ASSEMBLED from those verified schema pieces — they are not verbatim doc examples.

═══ 1. CLAUDE.md import + AGENTS.md bridge (verbatim from code.claude.com/docs/en/memory) ═══

    See @README for project overview and @package.json for available npm commands for this project.

    # Additional Instructions
    - git workflow @docs/git-instructions.md

AGENTS.md bridge, verbatim:

    @AGENTS.md

    ## Claude Code

    Use plan mode for changes under `src/billing/`.

═══ 2. Path-scoped rule, .claude/rules/*.md (verbatim) ═══

    ---
    paths:
      - "src/api/**/*.ts"
    ---

    # API Development Rules

    - All API endpoints must include input validation

Multi-pattern form (verbatim):

    ---
    paths:
      - "src/**/*.{ts,tsx}"
      - "lib/**/*.ts"
      - "tests/**/*.test.ts"
    ---

Budget: one rule's whole `paths` list shares a budget of 1,000 expanded patterns and 4 MiB. Escape a literal bracket as `photos \[2024/**`.

═══ 3. SKILL.md frontmatter (verbatim field examples) ═══

    ---
    name: commit
    description: Stage and commit the current changes
    disable-model-invocation: true
    allowed-tools: Bash(git add *) Bash(git commit *) Bash(git status *)
    ---

Full accepted key list: name, description, when_to_use, argument-hint, arguments, disable-model-invocation, user-invocable, allowed-tools, disallowed-tools, model, effort, context, agent, background, hooks, paths, shell, metadata, license, compatibility.
Substitutions in the body: $ARGUMENTS, $ARGUMENTS[N], $N, named arguments.
Supporting-file layout (verbatim):

    my-skill/
    ├── SKILL.md (required - overview and navigation)
    ├── reference.md (detailed API docs - loaded when needed)
    ├── examples.md (usage examples - loaded when needed)
    └── scripts/
        └── helper.py (utility script - executed, not loaded)

═══ 4. Subagent .claude/agents/<name>.md (verbatim) ═══

    ---
    name: code-reviewer
    description: Reviews code for quality and best practices
    tools: Read, Glob, Grep
    model: sonnet
    ---

    You are a code reviewer. When invoked, analyze the code and provide
    specific, actionable feedback on quality, security, and best practices.

With persistent memory (verbatim):

    ---
    name: code-reviewer
    description: Review code and track patterns over time
    tools: Read, Glob, Grep
    memory: project
    ---

═══ 5. Hook entry schema (verbatim shape from code.claude.com/docs/en/hooks) ═══

    {
      "hooks": {
        "EventName": [
          {
            "matcher": "ToolName|OtherTool|*",
            "hooks": [
              {
                "type": "command",
                "command": "/path/to/script.sh",
                "args": [],
                "if": "Bash(rm *)",
                "timeout": 600,
                "statusMessage": "Custom message",
                "async": false,
                "shell": "bash"
              }
            ]
          }
        ]
      },
      "disableAllHooks": false
    }

Hook types available: "command", "http", "mcp_tool", "prompt", "agent".

Common input JSON delivered on stdin to every hook (verbatim):

    {
      "session_id": "abc123",
      "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
      "transcript_path": "/home/user/.claude/projects/.../transcript.jsonl",
      "cwd": "/home/user/my-project",
      "permission_mode": "default",
      "hook_event_name": "PreToolUse",
      "effort": { "level": "medium" }
    }

Tool-event additions (verbatim): "tool_name", "tool_input", "tool_use_id".

Blocking output (verbatim doc example):

    {
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "Destructive command blocked by hook"
      }
    }

═══ 6. THE DECISION LOG HOOK — assembled, for .claude/settings.json ═══

Use PostToolUse with matcher "*". PostToolUse stdout goes to the debug log, NOT into Claude's context, so this costs zero tokens per tool call.

    {
      "hooks": {
        "PostToolUse": [
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/decision_log.py",
                "timeout": 10,
                "async": true
              }
            ]
          }
        ],
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/decision_log.py",
                "timeout": 10
              }
            ]
          }
        ],
        "SessionStart": [
          {
            "matcher": "startup|resume|clear|compact|fork",
            "hooks": [
              {
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/decision_log.py",
                "timeout": 10
              }
            ]
          }
        ],
        "SessionEnd": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/decision_log.py",
                "timeout": 10
              }
            ]
          }
        ]
      }
    }

Note: UserPromptSubmit, PostToolBatch, Stop, CwdChanged and MessageDisplay have NO matcher support — omit the "matcher" key entirely for those. Do NOT set "async": true on UserPromptSubmit if you ever want it to inject context.

Matching script, .claude/hooks/decision_log.py (chmod +x, Python 3.10 is present):

    #!/usr/bin/env python3
    import json, os, sys, datetime, pathlib
    try:
        e = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    root = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
    out = pathlib.Path(root) / "var" / "log" / "decisions.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    rec = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "session_id": e.get("session_id"),
        "event": e.get("hook_event_name"),
        "tool": e.get("tool_name"),
        "tool_use_id": e.get("tool_use_id"),
        "cwd": e.get("cwd"),
        "agent_type": e.get("agent_type"),
        "input": e.get("tool_input"),
    }
    with out.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, default=str) + "\n")
    sys.exit(0)

Always sys.exit(0). Exit 2 on PostToolUse shows stderr to Claude and pollutes context; exit 1 is not blocking but is still reported as a non-blocking error.

═══ 7. Permission rules for .claude/settings.json (syntax verbatim from docs) ═══

Format is `Tool` or `Tool(specifier)`. Evaluation order is deny → ask → allow, first match wins. Read/Edit paths use gitignore syntax: `//abs`, `~/home`, `/relative-to-settings-source`, `path` or `./path` relative to cwd. Use `Edit(...)` not `Write(...)`; use `Read(...)` not `Glob(...)`.

    {
      "permissions": {
        "defaultMode": "default",
        "deny": [
          "Read(.env)",
          "Read(**/*.pem)",
          "Edit(/var/log/**)",
          "Bash(rm -rf *)"
        ],
        "ask": [
          "Bash(git push *)"
        ],
        "allow": [
          "Bash(swift build *)",
          "Bash(swift test *)",
          "Bash(git status *)",
          "Bash(git diff *)",
          "Read(//Users/Kunal/Desktop/Bot-Harness/**)"
        ]
      }
    }

Other verified settings.json top-level keys: hooks, env, model, statusLine, outputStyle, autoMemoryEnabled, autoMemoryDirectory, claudeMdExcludes, cleanupPeriodDays, sandbox, enableAllProjectMcpServers, disableAllHooks, claudeMd (managed/policy only).

═══ 8. MADR ADR filename + directory (verbatim) ═══

Directory: docs/decisions
Filename:  nnnn-title.md
Templates: adr-template.md, adr-template-minimal.md, adr-template-bare.md, adr-template-bare-minimal.md

═══ 9. Keep a Changelog 1.1.0 headings (verbatim) ═══

Added, Changed, Deprecated, Removed, Fixed, Security

═══ 10. Conventional Commits 1.0.0 (verbatim) ═══

    <type>[optional scope]: <description>

    [optional body]

    [optional footer(s)]

═══ 11. llms.txt structure (verbatim from llmstxt.org) ═══

H1 project name (only required section) → blockquote summary → non-heading markdown sections → H2-delimited file lists of `[name](url): notes`. An `## Optional` H2 marks content agents may skip when context is limited.
