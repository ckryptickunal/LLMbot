# How Grok Bot works end to end — company, agent architecture, Bots/Routines/Plugins, and the exact UI we are answering

> Verified 2026-08-30 against live sources.

## Bottom line

Grok Bot is an Electron desktop app (bundle id com.anysphere.sand, v0.30.0, © 2026 SpaceXAI) that is Cursor's agent stack wearing an xAI badge: every account gets ONE persistent cloud Linux VM shared by all of that account's Bots, each Bot is a named persistent identity (Name / Label / Description / avatar) with its own conversation, memory and Routines, and safety is a single natural-language "Auto-review" rule table plus a per-machine local-execution setting. Its two structural weaknesses are exactly where a local-first app wins: all Bots share one computer and one set of logins ("Do not use separate Bots as a security boundary"), and there is still no per-action audit log ("An audit view of Bot actions is coming"). Bot-Harness already has the hash-chained trace that Grok Bot does not.

## Concrete specifications

EXACT PALETTE (sampled from /Users/Kunal/Downloads/GrokBot Screenshots at 2x, dark theme)
- App / chat / right-pane background: #070707
- Sidebar background: #111111
- Sidebar hairline divider: #292929 (1px @2x = 0.5pt)
- Sidebar selected row: #313131
- Modal surface + settings card: #1b1b1b; nested control inside card: #2b2b2b
- Bot (incoming) bubble: #262626
- User (outgoing) bubble: #5a5a5a
- Composer field: #2f2f2f; placeholder grey: #6d6d6d
- Primary text: #fcfcfc; secondary text: #9a9a9a
- Primary (filled) button: #fafafa with #141414 label
- Filter chip, selected: #282828 with #fcfcfc label
- Inline code: #ec636b text on #343434 chip
- Progress bar fill (weekly usage): #3c82f6
- "Added" check green: #6cd297
- Bot avatar accent (Jewel Partnership): #f19d38; (Joby): #1a396c

EXACT GEOMETRY (measured @2x, halved to points)
- Sidebar width 278.5pt; divider 0.5pt; right pane width ~318pt; chat column takes the remainder
- Message bubble corner radius ≈ 20pt; left inset from chat pane edge ≈ 16pt
- Gap between consecutive bubbles from the same speaker: 4pt
- Settings modal is an overlay sheet with its own left rail: General / Computer / Usage & Billing / Updates

EXACT UI COPY (verbatim from screenshots)
- Bot settings pane fields: "Name", "Label (optional)" placeholder "Research, marketing, admin", "Description", and a "Notifications" row: "Get notified when this Bot finishes or needs input". Footer button: "Share as template".
- Routine editor: "Active" toggle, "Delete", "Test run"; "Name" placeholder "Name this routine"; "Instruction" placeholder "What should this routine do each time it runs?"; "When to run" → "+ Add trigger"; "Run history" → "No runs yet".
- Routines list in right pane, entries like: "Jewel partnership reply watch / Weekdays at 9:00 AM" with a clock glyph, plus a "+" to add.
- Auto-review setting: "Grok Bot checks each action before it runs and asks you first when needed. Add rules to customize what it can do automatically."
- Auto-review Rules: "Write one short, natural-language rule for each action. \"Ask first\" takes priority if rules conflict." Form is "When Grok Bot wants to:" [placeholder "e.g. reply to emails for me"] / "It should:" [dropdown, default "Allow automatically"] / [Add Rule]. Table columns "Action" | "Behavior". Footer: "These rules apply only to you. Built-in safety checks always apply."
- Computer settings: "Current computer / This is the computer you are using now" (editable name, e.g. "Unknown_c6:7d:a4:e1:b8:a7"); "Execution on this computer — Let Grok Bot open files and run tasks on your computer. Auto-review still checks everything first." with dropdown "Always allow".
- Security Key: "Use hardware security keys — Allow Grok Bot to use a security key (such as a YubiKey) connected to your computer. You'll be asked to approve each use."
- Usage & Billing: "Weekly usage 100% / Resets in 5 days"; "On-demand usage / Set a monthly limit" [None] "$10.68 / Resets in 18 days"; "On-Demand — Enable on-demand spend in the Cursor dashboard. A credit card may be required." [Open Cursor Dashboard]; "Upgrade to Pro+ — Get $500 of Grok Bot usage each week with Pro+".
- Connection state pill: "Checking connection / Reconnecting"; stale banner: "Showing saved messages / This conversation may be out of date and will refresh when the connection returns".
- Human-handoff card in transcript: title "Computer", status pill "● Done", body text, button "Open computer".
- Right-pane screen thumbnail caption: "<Bot name>'s screen"; empty state "Starting desktop" with an indeterminate bar.
- User menu: Get Grok Bot for iOS / Settings / About / Help Center / Send Feedback / Log out.
- Plugin categories (exact, in order): All, Featured, Agent Orchestration, Canvas, Customer Support, Data Analytics, Design, Documents And Files, Finance And Legal, Inbox And Collaboration, Infrastructure, MCP, Payments, Productivity, Research, Sales, Scheduling. Row action buttons are "Add" / "✓ Added"; header shows stacked icons + "3 installed >".

LOCAL BUNDLE FACTS (/Applications/Grok Bot.app/Contents/Info.plist)
- CFBundleIdentifier com.anysphere.sand; CFBundleShortVersionString 0.30.0; NSHumanReadableCopyright "Copyright © 2026 SpaceXAI"; NSPrincipalClass AtomApplication (Electron); LSMinimumSystemVersion 12.0; LSApplicationCategoryType public.app-category.developer-tools
- URL schemes: grokbot://, sand://
- ATS: NSAllowsArbitraryLoads true, plus explicit localhost / 127.0.0.1 insecure-HTTP exceptions

AGENT SURFACE (strings extracted from Contents/Resources/app.asar)
- Model ids present: grok-4.5, grok-4.6, grok-voice-latest, grok-voice-think-fast-2.0, grok-transcribe
- Subagent types: SubagentTypeBash, BrowserUse, ComputerUse, CursorGuide, Custom, Debug, Explore, MediaReview, Shell, Unspecified, VmSetupHelper, WatchVideo; proto enums SUBAGENT_TYPE_DEEP_SEARCH / FIX_LINTS / SPEC / TASK
- Tool parameter names (the tool surface): read_file, edit_file, edit_file_v2, new_file, delete_file, undo_edit, reapply, list_dir, glob_file_search, file_search, ripgrep_search, semantic_search, get_symbols, gotodef, read_lints, fix_lints, run_terminal_command_v2, write_shell_stdin, computer_use, record_screen, web_search, web_fetch, deep_search, task, task_v2, await_task, todo_read, todo_write, create_plan, create_diagram, ask_question, switch_mode, call_mcp_tool, get_mcp_tools, list_mcp_resources, read_mcp_resource, mcp_auth, create_pr, create_branch_and_commit, commit_and_push, babysit_pr_in_cloud
- Message names CallMcpTool, ExecuteSandMcpTool, MessageSubagent, StopSubagent, CheckSubagent, TeamSubagent, ToolCallResolution — confirming a subagent-orchestration protocol, not a flat loop

GROK BUILD SANDBOX PROFILES (directly implementable, from the repo's user guide)
| profile | FS read | FS write | child network |
| off | unrestricted | unrestricted | allowed |
| workspace | everywhere | CWD + ~/.grok/ + /tmp + /var/tmp | allowed |
| devbox | everywhere | all top-level dirs except /data | allowed |
| read-only | everywhere | ~/.grok/ + /tmp + /var/tmp | blocked (Linux only) |
| strict | CWD + system paths | CWD + ~/.grok/ + /tmp + /var/tmp | blocked (Linux only) |
Custom profiles in ~/.grok/sandbox.toml or .grok/sandbox.toml:
  [profiles.custom_name]
  extends = "workspace"
  restrict_network = true
  read_only = ["/path"]
  read_write = ["/path"]
  deny = ["**/*.env", "*.pem"]
Enforcement: Landlock + seccomp on Linux (kernel 5.13+), Seatbelt on macOS. Applied to the whole process at startup, "not per-command wrapping". Selected via [sandbox] profile in config.toml, --sandbox, or GROK_SANDBOX. The profile is pinned to the session and restored on --resume.
Env scrubbing: [shell_environment_policy] inherit = "core" | "all" | "none", with default excludes of *KEY*, *SECRET*, *TOKEN*, plus exclude / include_only / set.

SKILL FORMAT (Grok Build, Claude-Code-compatible)
- Discovery: ./.grok/skills/ walked to repo root, ~/.grok/skills/, enabled plugin dirs, custom paths in ~/.grok/config.toml
- SKILL.md YAML frontmatter fields: name, description, when-to-use, paths, allowed-tools, argument-hint, user-invocable, disable-model-invocation ("Only the literal true counts; yes is false")
- Hooks: PreToolUse, PostToolUse, SessionStart; from ~/.grok/hooks/ and project .grok/hooks/ (trust-gated); plugin hooks get GROK_PLUGIN_ROOT and GROK_PLUGIN_DATA
- Plugin = "skills, slash commands, agents, hooks, MCP servers, and LSPs into one installable package", pinned to a commit SHA and verified at install

HARD LIMITS FROM THE DOCS
- 50 Bots + group chats per account; 50 routines per Bot; 20 recent run records per routine
- Composer: 6 attachments; 25 MB documents/images/audio; 200 MB video
- Teach-a-task browser recording: up to 10 minutes, no audio
- Shared workspace path on the VM: /workspace

## Findings

- The installed app's bundle identifier is com.anysphere.sand (Anysphere = Cursor's company), version 0.30.0, copyright "Copyright © 2026 SpaceXAI", built on Electron (NSPrincipalClass AtomApplication), min macOS 12.0, registering the grokbot:// and sand:// URL schemes. It ships with NSAllowsArbitraryLoads plus explicit localhost/127.0.0.1 cleartext exceptions.  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Info.plist>
- The xAI/Anysphere link is real and corporate, not a partnership: SpaceX merged with xAI (finalised 6 May 2026), then SpaceX acquired Anysphere/Cursor for $60B all-stock, closing 15 August 2026 and folding it into the SpaceXAI unit. Grok Bot is the first joint product.  
  — likely · <https://www.cnbc.com/2026/06/16/spacex-spcx-cursor-acquisition-ipo.html>
- Grok Bot launched 11 August 2026 for SuperGrok Heavy, Cursor Ultra and Cursor Teams Premium, and within about ten days widened to SuperGrok Plus, Cursor Pro+ and Cursor Teams.  
  — likely · <https://9to5mac.com/2026/08/21/grok-bot-is-an-all-new-iphone-and-mac-app-from-spacexai-and-cursor/>
- Official supported plans per the docs: SuperGrok Plus, SuperGrok Heavy, Cursor Pro+, Cursor Ultra, Cursor Teams Standard or Premium. Downloads are offered for macOS (Apple silicon and Intel) and Windows (x64 and Arm64); the FAQ lists iPhone iOS 18+ and says Linux, Android and iPad are not supported initially.  
  — **confirmed** · <https://docs.x.ai/grok-bot/get-started>
- Every account gets ONE persistent cloud computer, not one per Bot: "Grok Bot works from a persistent cloud computer", "Every Bot on your account uses the same computer", sharing cookies, sessions, files and credentials, with "Each Bot gets its own screen on the shared computer" and a shared workspace at /workspace. Files, browser state and sign-ins are designed to survive updates and recovery.  
  — **confirmed** · <https://docs.x.ai/grok-bot/computer-and-apps>
- xAI explicitly tells users the shared computer is not an isolation boundary: "Do not use separate Bots as a security boundary." Signing in for one Bot makes the session available to every other Bot, and installed connectors are account-wide.  
  — **confirmed** · <https://docs.x.ai/grok-bot/approvals-security-and-privacy>
- Approvals are forward-only and explicitly do not roll anything back: "An approval controls the proposed action. It does not reverse work already completed." Desktop offers Allow once / Deny / Always allow; iPhone offers Approve once / Deny. Conflicting auto-review rules resolve in favour of Require Approval.  
  — **confirmed** · <https://docs.x.ai/grok-bot/approvals-security-and-privacy>
- Local execution on the user's own Mac is a single global setting, not per-bot or per-command: Settings → General → Agent → Execution on Local Computer, with always require approval / always allow / never allow, defaulting to asking each time.  
  — **confirmed** · <https://docs.x.ai/grok-bot/approvals-security-and-privacy>
- A Bot is a durable identity with persistent conversation history and evolving context. Creation is New (Cmd/Ctrl+N) → Create new agent → a bot named "New Agent" → Bot actions → Edit Profile to set name, title, description and avatar. Bot actions are Pin, Hide, Duplicate, Share, Delete. Duplicate copies profile, settings, skills and routines but not conversation history or learned memory. Share generates a public link others can preview and add. Limit: 50 Bots and group chats combined per account.  
  — **confirmed** · <https://docs.x.ai/grok-bot/bots>
- The Bot profile fields in the shipping macOS UI are exactly: avatar, "Name", "Label (optional)" (placeholder "Research, marketing, admin"), "Description", and a "Notifications" toggle described as "Get notified when this Bot finishes or needs input". The pane's footer action is "Share as template".  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/05%20-%20Jewel%20Partnership%20Bot%20Settings.png>
- A skill is "a reusable set of instructions for how to do a task"; a routine "assigns a workflow to one Bot and tells it when to run" — on a schedule or, where supported, after an event. Skills can be created by saying "Save the process we just used as a skill" or by the "Teach a task" browser recorder (up to 10 minutes, no audio) which produces a draft skill. Limits: 50 routines per Bot, 20 recent run records retained per routine, deletion is immediate with no undo.  
  — **confirmed** · <https://docs.x.ai/grok-bot/skills-routines-and-automations>
- The shipping Routine editor has exactly five controls: an "Active" toggle, "Delete", "Test run", a "Name" field, an "Instruction" field prompting "What should this routine do each time it runs?", a "When to run" section whose only affordance is "+ Add trigger", and a "Run history" list. Routines are surfaced in the right-hand pane beneath the bot's live screen thumbnail.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/06%20-%20Jewel%20Partnership%20Routine%20Editor.png>
- Auto-review is Grok Bot's entire permission model and it is natural-language, not a typed capability grammar: a free-text "When Grok Bot wants to:" clause paired with a behavior dropdown, stored in an Action/Behavior table, with the disclaimer "These rules apply only to you. Built-in safety checks always apply." A real stored rule reads "Use the browserUse subagent tool to submit job applicat… / Allow automatically", showing rules are matched against tool-call intent text.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/19%20-%20App%20Settings%20-%20Auto-review%20Rules.png>
- Grok Bot supports hardware security keys by forwarding WebAuthn from the cloud VM to a key physically attached to the user's Mac, with per-use approval: "Allow Grok Bot to use a security key (such as a YubiKey) connected to your computer. You'll be asked to approve each use."  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/20%20-%20App%20Settings%20-%20Security%20Key.png>
- Billing runs entirely through Cursor. The Usage & Billing pane shows a weekly usage meter with a reset countdown, an on-demand spend figure with an optional monthly limit, an "Open Cursor Dashboard" button for enabling on-demand spend, and an upsell reading "Upgrade to Pro+ — Get $500 of Grok Bot usage each week with Pro+". Team invoices combine Cursor and Grok Bot charges.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/22%20-%20App%20Settings%20-%20Usage%20and%20Billing.png>
- There is no model picker and there never will be: "Grok Bot has no model picker, for members or admins. We do not plan to allow admin or user choice." Requests route to a fixed model set with failover, and billing reflects the model that actually served the request.  
  — **confirmed** · <https://docs.x.ai/grok-bot/teams-and-enterprises>
- Per-action auditing does not exist yet — the docs say only "Spend and usage appear on the dashboard usage page. An audit view of Bot actions is coming." Today the only record of what a Bot did is the chat transcript.  
  — **confirmed** · <https://docs.x.ai/grok-bot/teams-and-enterprises>
- Team administration is done from the Cursor dashboard, members sign in with their Cursor account so existing Cursor SSO applies, and only organization admins (not team admins) can inspect and remove member VMs. Legacy Privacy Mode is not supported because work is stored in the cloud.  
  — **confirmed** · <https://docs.x.ai/grok-bot/teams-and-enterprises>
- The desktop bundle contains the model ids grok-4.5 and grok-4.6 plus grok-voice-latest, grok-voice-think-fast-2.0 and grok-transcribe, and a full subagent taxonomy — SubagentTypeBash, BrowserUse, ComputerUse, CursorGuide, Custom, Debug, Explore, MediaReview, Shell, VmSetupHelper, WatchVideo — alongside proto enums SUBAGENT_TYPE_DEEP_SEARCH / FIX_LINTS / SPEC / TASK.  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Resources/app.asar>
- The tool surface inside the bundle is Cursor's agent toolset verbatim — read_file, edit_file_v2, glob_file_search, ripgrep_search, semantic_search, gotodef, read_lints, fix_lints, run_terminal_command_v2, write_shell_stdin, todo_read/todo_write, create_plan, create_pr, babysit_pr_in_cloud — plus the agent-specific computer_use, record_screen, deep_search, web_search, web_fetch, task/task_v2/await_task and the MCP quartet call_mcp_tool, get_mcp_tools, list_mcp_resources, read_mcp_resource. This is the strongest single piece of evidence that Grok Bot is Cursor's runtime rebadged.  
  — **confirmed** · <file:///Applications/Grok%20Bot.app/Contents/Resources/app.asar>
- Grok 4.6 shipped 12 August 2026 — one day after Grok Bot — with a 500K-token context window, $2/M input and $6/M output ($0.50 cached; $4/$12 above 200K prompts), an added "xhigh" reasoning level, and explicit positioning for long-running agents (APEX-Agents 47.1 → 57.5 over 4.5).  
  — likely · <https://kingy.ai/blog/grok-4-6-price-benchmarks-api-cursor-context-window/>
- Plugins in Grok Bot are surfaced as a searchable modal with a fixed category taxonomy — All, Featured, Agent Orchestration, Canvas, Customer Support, Data Analytics, Design, Documents And Files, Finance And Legal, Inbox And Collaboration, Infrastructure, MCP, Payments, Productivity, Research, Sales, Scheduling — with one-click "Add" / "✓ Added" per row and an installed count in the header. MCP is one category among sixteen, not a separate system.  
  — **confirmed** · <file:///Users/Kunal/Downloads/GrokBot%20Screenshots/11%20-%20Plugins%20-%20Featured%20and%20Agent%20Orchestration.png>
- On the developer side, "A plugin bundles skills, slash commands, agents, hooks, MCP servers, and LSPs into one installable package." The marketplace is an open catalog at github.com/xai-org/plugin-marketplace, every remote plugin is pinned to a commit SHA and the pin is verified at install time, and installation is /marketplace + i in the TUI or `grok plugin install <name> --trust`.  
  — **confirmed** · <https://x.ai/news/grok-plugin-marketplace>
- Grok Build — the same company's coding agent, sharing the runtime — is open source under Apache 2.0 at github.com/xai-org/grok-build, ships as a Rust TUI whose binary is xai-grok-pager (released as `grok`), and its user guide documents the sandbox, hooks and skill formats in full. This is a readable reference implementation of the architecture Grok Bot hides.  
  — **confirmed** · <https://github.com/xai-org/grok-build>
- Grok Build's sandbox has five profiles — off, workspace, devbox, read-only, strict — enforced with Landlock+seccomp on Linux and Seatbelt on macOS, applied to the entire process at startup rather than per command, with custom profiles in sandbox.toml supporting extends / restrict_network / read_only / read_write / deny (gitignore-style globs). The profile is pinned to a session and restored on resume.  
  — **confirmed** · <https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/18-sandbox.md>
- Skills are Claude-Code-compatible folders discovered from ./.grok/skills/ (walked to repo root), ~/.grok/skills/, plugin dirs and config paths, each with a SKILL.md whose frontmatter carries name, description, when-to-use, paths, allowed-tools, argument-hint, user-invocable and disable-model-invocation. Hooks fire on PreToolUse, PostToolUse and SessionStart.  
  — **confirmed** · <https://docs.x.ai/build/features/skills-plugins-marketplaces>
- Real-user complaints cluster on four things: token burn from always-on agents with no Grok-Bot-specific spend cap; a launch-week metering bug where the dashboard showed zero while the app showed 48% consumed; plan gatekeeping behind Cursor Ultra/Teams being the loudest Hacker News thread; and "Test run" not being a dry run — it does real work against real sites with no sandboxed replay.  
  — likely · <https://www.eesel.ai/blog/grok-bot-review>
- The published use-case gallery is eight role-shaped Bots: Sales Outbound, Talent Scout, Paid Media, Expense Manager, Product Performance, Bug Reproduction, Account Health, Chief of Staff — each framed as "drafts, does not send" with approval kept at the boundary.  
  — **confirmed** · <https://docs.x.ai/grok-bot/use-cases>
- Bots run in parallel but each gets one screen and completes one computer task at a time; memory holds "stable preferences, role context, and summaries of prior work" and the docs warn "Memory is not a substitute for an authoritative source." Deleting a Bot removes its profile, conversation and routines but leaves shared files and logins on the account computer.  
  — **confirmed** · <https://docs.x.ai/grok-bot/faq>
- Credentials are handled by handing control back to the human rather than by a vault: for passwords, 2FA codes and payment confirmations the user takes manual control via the Agent Computer, and only supported connections offer masked input fields that are "masked, excluded from the transcript, and not shown to the model". The docs say this "is not a general-purpose password manager."  
  — likely · <https://nerdleveltech.com/grok-bot-shared-computer-security-docs>

## What to build

- Ship the audit view Grok Bot admits it does not have. Their own enterprise docs say "An audit view of Bot actions is coming" and reviewers call it the deployment blocker. Bot-Harness already writes a hash-chained JSONL trace — surface it as a first-class Activity window with a per-action row (timestamp, bot, tool, arguments, decision, result hash) and an export. This is the single sharpest differentiator and it is already 80% built.
- Make the per-bot boundary real, because theirs is explicitly fake. Their docs say "Do not use separate Bots as a security boundary." Give each Bot in Bot-Harness its own filesystem root, its own keychain scope, and its own browser profile, and say so in the Bot settings pane in one line. This is the product claim their architecture cannot make.
- Adopt the five-profile sandbox vocabulary verbatim — off / workspace / devbox / read-only / strict — with the same write scopes, and enforce it on macOS with Seatbelt (sandbox_init / sandbox-exec profiles) applied once at process start rather than per command. It is a published, battle-tested taxonomy from the same company's open-source agent, it costs no dependency, and matching the names makes Bot-Harness legible to anyone who has used Grok Build. Add the custom-profile fields extends / restrict_network / read_only / read_write / deny with gitignore-style globs.
- Copy the environment-scrubbing policy exactly: default-exclude any env var matching *KEY*, *SECRET*, *TOKEN* before spawning any child process, with inherit = core|all|none plus exclude / include_only / set overrides. Cheap, and it closes a real leak path in a shell-running app.
- Build the Bot object with their exact four fields — avatar, Name, Label (optional, placeholder "Research, marketing, admin"), Description — plus a Notifications toggle. Do not invent more. Their pane is deliberately tiny and it is the right call: the durable rules live in Description, not in a form.
- Build Routine as their five-field editor: Active toggle, Name, Instruction ("What should this routine do each time it runs?"), When to run (trigger list), Run history. Then beat them on the one thing users complained about: make "Test run" an actual dry run that resolves the plan and renders the tool calls it WOULD make without executing side-effectful ones. Their Test run does real work; ours should not.
- Implement the permission model as a typed capability rule table, but present it with their natural-language form — "When the bot wants to: [____] It should: [Ask first ▾]" — and keep their conflict rule ("Ask first" wins) and their honest footer ("Built-in safety checks always apply"). The UI is good; the underlying matching should be typed capability + scope, not string matching against tool-call intent, which is what their stored rule row reveals theirs to be.
- Adopt the human-handoff card as a first-class message type: a bordered card with a title, a status pill (Running / Needs you / Done), a one-line instruction, and a button that opens the screen. This is how Grok Bot handles CAPTCHAs, 2FA and payment confirmation, and it is exactly the shape Bot-Harness's permission floor needs for the actions it will never take itself.
- Match the dark palette exactly so the comparison is head-on: #070707 canvas, #111111 sidebar, #292929 hairline, #1b1b1b modal surface, #262626 incoming bubble, #5a5a5a outgoing bubble, #2f2f2f composer, #fcfcfc primary text, #9a9a9a secondary, #3c82f6 progress. Sidebar 278pt, right pane 318pt, bubble radius 20pt, 4pt gap between same-speaker bubbles.
- Put the model picker back. Their docs say "We do not plan to allow admin or user choice" for models — an unforced giveaway for a local-first app that already talks to Gemini and can talk to anything. Expose per-Bot model selection in the Bot settings pane.
- Support the Claude-Code-compatible SKILL.md format directly — frontmatter name, description, when-to-use, paths, allowed-tools, argument-hint, user-invocable, disable-model-invocation, discovered from ./.bothharness/skills/ walked to repo root and ~/.bothharness/skills/. Grok Build reads Claude Code's skills with zero config; matching the format means the entire existing skill ecosystem drops in without us shipping a marketplace.
- Add PreToolUse / PostToolUse / SessionStart hooks with a JSON stdin contract and deny/allow results. This is how a user makes the permission floor theirs without us anticipating their policy, and it is three enum cases plus a subprocess call.
- Keep the connection-state affordances — a "Checking connection / Reconnecting" pill and a "Showing saved messages / This conversation may be out of date" banner. A local-first app should almost never show them, which is itself the point worth making visible.

## Could not verify

- Which model actually serves Grok Bot requests. The bundle contains both grok-4.5 and grok-4.6 ids, and the docs say routing is fixed and managed with failover, but no source states the production model for a given task, and billing is described as reflecting whichever model served the request.
- Linux desktop availability. docs.x.ai/grok-bot/get-started lists only macOS and Windows downloads and the FAQ says Linux is unsupported initially, while 9to5Mac and one launch write-up say a Linux build was posted. Conflicting; do not rely on either.
- The weekly usage allowance in dollars or tokens for each plan. eesel notes xAI does not publish it; the only hard number I have is the in-app upsell "Get $500 of Grok Bot usage each week with Pro+", read off one account's screen, and the on-demand figure $10.68 which is that account's spend, not a rate.
- Exact monthly prices. SuperGrok Plus $100, SuperGrok Heavy $300, Cursor Pro+ $60, Cursor Ultra $200, Cursor Teams Premium $120/seat, Teams Standard $40/seat all come from secondary blogs and one X post, not from a fetched x.ai or cursor.com pricing page — x.ai/bot returned HTTP 403 to my fetch.
- Free trial terms. Multiple sources mention a one-time trial for individuals; none publishes its duration or usage cap.
- The event-trigger vocabulary for Routines. The docs say routines run on a schedule "or, where supported, after an event" and warn against "broad listeners such as 'every new message'", but no source enumerates the supported event types, and the shipping UI shows only an empty "+ Add trigger".
- Whether Grok Bot's Plugins panel and grok.com's Connectors are the same catalog. The 31-connector list I found (Box, Canva, GitHub, Gmail, Google Calendar, Google Drive, Notion, Stripe, Vercel, Wix, X Ads, BigQuery, Excalidraw, Mixpanel, eToro, IBKR, S&P Global, Webull, Calendly, Figma, Gamma, HyperFrames, Linear, Microsoft Teams, Outlook, Outlook Calendar, HubSpot, Meltwater, OneDrive, Salesforce, SharePoint) plus five built-in skills is documented for grok.com Connectors, whereas the Grok Bot desktop panel shows a different sixteen-category taxonomy with entries like Arize, Atlan, AWS Agents, AWS SageMaker, Granola, Docs Canvas and PR Review Canvas. Treat them as overlapping but distinct.
- The hosted MCP endpoint URLs (mcp.box.com, mcp.canva.com/mcp, api.githubcopilot.com/mcp/x/all, mcp.notion.com/mcp, mcp.stripe.com, mcp.vercel.com, mcp.wix.com/mcp) come from a community-maintained GitHub directory, not from a vendor page I fetched.
- Data retention periods. The teams docs cover privacy mode and training posture but state no retention timeline, and I found no primary source that does.
- The reported metering bug (dashboard showing 0% while the app showed 48%) and the token-burn quotes are relayed by one review site summarising Hacker News; I did not reach the original HN thread to read the comments directly.
