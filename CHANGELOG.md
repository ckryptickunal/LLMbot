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

### Security — the permission system now covers the shell

- **A bot's workspace boundary applies to the terminal, not just to the file tools.** The shell
  executor was built with no permissions at all, so any bot that preferred `cat` to the file tool
  could read anything in your home directory regardless of what you had scoped it to. It now
  refuses reads and writes outside the paths you gave it, with an allowance for system and
  temporary directories so ordinary tooling still runs.
- **An empty permission list now means "nothing", not "everything".** A bot created without
  explicit paths previously had the run of the whole disk.
- **`~/.SSH/id_rsa` no longer bypasses the guard on your private key.** Every path comparison was
  case-sensitive while the disk is not, so changing one letter walked past the deny list. All path
  matching now happens in one place, folds case, and compares whole path components.
- **`curl --data-binary "@$HOME/…/credentials.json"` no longer uploads every key.** The old guard
  only recognised `$HOME` at the very start of a word, so a single leading `@` defeated it.
- **Copying the folder that holds your keys is caught even though it never names the file.**
  `cp -r`, `tar`, `rsync` and friends are now matched against containers of a protected path.
- **Uploading is recognised as leaving the machine.** There was a floor category for downloading
  and running code and none for sending data out, so `curl -d`, `scp` and `nc` were unguarded.
- **Commands no longer run in a login shell.** Your `.zshrc` exports real API keys and tokens, and
  every command a bot ran inherited all of them — so `env` printed your secrets. The child
  environment is now filtered.
- **Search results are treated as untrusted.** `files.search` returns lines lifted out of files;
  they arrived as plain tool output, so a document containing "SYSTEM: ignore your instructions"
  reached the model as an instruction if grep found it rather than the file being opened.
- **Web searches are redacted on the way out.** The query goes to a third party, so a bot holding
  a key could simply search for it. Results now arrive wrapped as untrusted content too.
- **Password managers and Keychain Access are never captured in a screenshot.** A screenshot is
  the one channel no redactor can touch, and the image is written to the trace and sent to the
  model provider.

### Fixed — things that did not work at all

- **Stop now stops.** The agent ran in a task the Stop button never reached, so after the
  transcript said "Stopped." the bot kept calling the model and using your Mac. It now unwinds
  between turns and between individual actions, and kills any process it started.
- **A command that never exits no longer hangs the whole run.** Output was read to end-of-file
  before the timeout was ever consulted, so the timeout was dead code and `npm run dev` or
  `tail -f` blocked forever. Output is now drained continuously, the timeout is real, and a
  process that ignores it is killed rather than left running.
- **Bots can drive Safari and Chrome for real.** The four browser tools were advertised to the
  model and had no implementation, so every call failed and the only way to use the web was
  screenshots (see docs/decisions/0018).
- **Git tools work.** `git.status`, `git.diff`, `git.commit` and `git.push` were advertised and
  gated behind approval, but had no implementation — so the approval gate protected nothing.
- **`test.run` works.** Advertised since the beginning and never implemented. Found only after
  the eval meant to catch this class of bug was itself fixed: it matched "there is no tool
  called" in lower case while the error says "There is no tool called", so it had never caught
  anything.
- **What a bot learns is actually saved.** `memory.save` collected notes into a per-run list that
  was discarded when the run ended, while telling the model "Noted." each time. Memory is now
  persisted, injected into later runs, searchable within the run that saved it, and can be
  forgotten (see docs/decisions/0015).
- **Channels can be created, and bots can be deleted.** Both existed in the data layer with no
  way to reach them from the interface. ⌘N makes a bot, ⇧⌘N makes a channel, and a right-click on
  a row offers Rename and Delete.
- **The menu bar's New Bot command was restored** after being lost during a parallel edit.
- **Two bots can no longer type over each other.** Concurrent runs each drove the same physical
  keyboard and mouse; machine use is now serialised.
- **A hung MCP server no longer hangs the run.** The timeout fired but left the waiting request
  parked forever, so the task it belonged to never finished.
- **MCP servers are shut down** instead of being left running. Nothing ever called `disconnect`,
  and reopening the connections screen spawned a fresh set while orphaning the old ones.

### Security — credentials and the record

- **The key file is never briefly world-readable, and a crash cannot leave a copy behind.** It was
  created with default permissions and tightened afterwards; a crash in that window left a
  complete plaintext copy of every key readable by anyone, and nothing checked for it.
- **Keys saved from the terminal are no longer destroyed by the next save in the app**, and a key
  added while the app is open is now visible without reopening Settings.
- **One odd value in the key file no longer hides every key** and then destroys them on the next
  save. A file that cannot be parsed at all is now refused rather than overwritten.
- **Keys stored under any name are redacted**, not only `gemini`, `anthropic` and `openai`.
- **Keys are excluded from Time Machine.** They are stored in cleartext, so every backup was
  carrying them off the machine.
- **Settings tells the truth about a failed save.** A key that could not be written showed the
  same green confirmation as one that was.
- **The trace is genuinely tamper-evident.** Its hash chain used a public algorithm with no key,
  so anything that could edit a record could re-chain the file to match — and the app displayed
  the result in green as "intact". Records are now signed, older traces are labelled as predating
  signing rather than passed off as verified, and `run.json` is redacted (see
  docs/decisions/0017).
- **A bot cannot rewrite its own trace**, and all of the app's directories are owner-only.

### Added

- **Claude Code actually works as a brain.** Settings listed it first with a green check and the
  words "no API key needed", while every bot answered with Gemini regardless of what you picked —
  so a user whose only credential was a Claude Code subscription was told they were ready and then
  got a silent failure. There is now a real adapter driving the local `claude` CLI, and the
  Settings row reports what it actually checked rather than promising sign-in it cannot verify.
  The CLI is invoked with its own tools, MCP servers, plugins and settings files all switched off:
  left to itself it is an agent with a shell and a file editor, and letting it act would route
  every action around this app's permission floor, path guard and trace.
- **Brains that have no adapter say so.** Anthropic and OpenAI previously became Gemini silently.
- **"Always allow" no longer grants the action to every bot you own.** Answering an approval card
  in one bot's conversation wrote a rule that applied roster-wide, including to bots created
  later, and nothing on screen said so. An allow is now scoped to the bot that asked; a "never"
  stays global, because refusing an action is a statement about the action rather than about who
  asked. Both buttons now say which they mean.
- **You can see and take back what a bot is allowed to do without asking.** Per-bot permissions
  had no list anywhere, so a rule created by clicking "Always" was invisible and permanent. Each
  bot's settings pane now shows them with a way to remove one, and answering the same prompt
  twice no longer leaves two identical rules to hunt down.
- **Channels can be renamed**, like bots.
- **Repeated side effects are prevented across runs** (see docs/decisions/0016). If a run is
  stopped or crashes after sending something, asking again does not send it twice — and an action
  whose result was never confirmed is reported as uncertain rather than guessed either way.
- **Bots cannot erase the record of what they already did.** The effect ledger now lives beside
  the traces, which are on the write-deny list, instead of somewhere any bot could delete it.
  This also stopped the test suite and the eval harness writing into your real ledger — 178
  entries of temporary paths had accumulated there. The old file at
  `~/Library/Application Support/Bot-Harness/effects.jsonl` is no longer read and can be deleted.
- **A continuation no longer drops tool results.** When a model turn asked for several tools at
  once, only the last result was sent back, so the model reasoned about calls it never saw
  answered — which looks like forgetfulness and was data loss.
- **A bot cannot save a "lesson" that widens what it is allowed to do**, and anything it learned
  from a page it read is marked unverified when recalled.


### Security
- **A permission you granted by mistake can now be taken back.** Settings → Permissions writes,
  edits and removes rules; "Always allow this" on a prompt is no longer a one-way door. The
  prompt also offers "Never", which was in the model and had no button.
- **A bot's folder is visible and changeable.** It silently defaulted to your whole Desktop and
  no screen said so, while the composer offered a mode called "works in its folder". Bot
  settings now shows the folder, explains that anything outside it needs approval, and lets you
  pick a different one.
- **Work whose process is gone no longer claims to be running.** A tool card that said
  "Running", a Computer card that said "Waiting for you", and an approval card with three live
  buttons wired to a run that ended — all three now settle to an honest state at launch and at
  Stop, and say what happened (see docs/decisions/0013-settle-work-whose-process-is-gone.md).

### Fixed
- **Typing into an empty app no longer destroys the message.** With no bot selected the column
  showed a working-looking composer that silently discarded whatever you sent. It now shows an
  empty state with a way to make a bot.
- **Editing one bot's settings can no longer edit a different one.** The pane kept a private
  copy that outlived the selection, so typing after switching bots wrote into the bot you left.
- **Sending while a bot is working no longer starts a second, unstoppable run.**
- **Quitting no longer loses the last fraction of a second.** Answering an approval and pressing
  ⌘Q inside the save delay used to lose the answer.
- **Bots can be deleted**, from the roster's context menu or from bot settings, after a
  confirmation, cancelling their work first.
- **You are told when a bot needs you**, even when the app is behind something else. The
  per-bot notification switch was previously connected to nothing at all.
- **Code from a bot stays runnable.** Fenced blocks kept their line breaks, get a Copy button,
  and scroll rather than wrapping mid-command.
- **The roster answers the glance questions**: which bot needs you, which is working, and what
  you have not read. It also has arrow-key navigation, type-to-select and VoiceOver rows, as
  does the run list in Activity.
- **The transcript has a time axis** — day separators, message times on hover, tool durations —
  and follows a streaming reply without yanking you away from history you are reading.
- **A failed run offers Try again.** Messages, cards, screenshots and rows have context menus.
- **Escape closes sheets. ⌘F finds. ⌥⌘1 and ⌥⌘2 show the roster and the panel. ⇧⌘0 opens Activity.**
- **Return no longer sends mid-word for anyone using an input method.**
- **Drafts stay with their conversation** instead of following you to the next bot.
- **Files can be dropped on the composer.**
- **Missing key is caught before you type, not after you wait** — the composer says so with a
  link to add one.
- **An unreadable state file says where your data went** instead of silently starting fresh.
- **The Screen panel shows the last thing the bot actually looked at.**
- Design-system self-violations: the roster uses the system's selection material; 25 pieces of
  real text moved off the 2.2:1 decorative ink; the approval colour no longer collides with
  "running"; the status pill uses the ramp built for it; the banned rounded font is gone; the
  transcript's permanent phantom scrollbar and the "in 0s" timestamp are both fixed; unfilled
  icon buttons respond to the cursor; Reduce Motion now reaches the spinner, skeleton and press
  feedback. Fifteen unused tokens and three dead mechanisms removed.

### Added — audit
- **A full end-to-end UX/UI audit** (`docs/UX-AUDIT-2026-08-31.md`): ~90 findings across
  critical data-loss paths (the composer can destroy a typed message; editing one bot's
  settings can edit another; two runs can share one conversation), safety UX (rules cannot be
  edited or revoked; approvals go silent when the app is in the background; the default
  workspace is the whole Desktop and no surface says so), interaction gaps (no keyboard
  access, no context menus, no timestamps, no retry), design-system self-violations, and dead
  code. Findings only — nothing fixed in that session.

### Security
- **API keys moved out of the macOS Keychain into an owner-only file.** They now live in
  `~/Library/Application Support/Bot-Harness/credentials.json` with mode `0600`, in a directory
  with mode `0700`. This is a **deliberate reduction in security**: the Keychain encrypted keys
  at rest and tied access to a code signature, and a file does neither, so anything running as
  you can read it. It was accepted because the Keychain asked for the login password repeatedly
  and could not be made to stop — an ad-hoc-signed binary's "Always Allow" grant dies with every
  rebuild, so `swift run Evals` prompted forever. See
  (docs/decisions/0012-credentials-live-in-an-owner-only-file.md) for the full trade-off,
  including the one hole this leaves open.
- **No bot can read the key file, through any door.** The path is on a permanent deny list that
  the file tool checks *independently of the bot's own contract*, so a `state.json` saved before
  this change cannot decode into permission to read it. The shell is guarded separately, because
  `cat` never went through the file tool at all — a new `readingSecrets` floor category refuses
  it outright rather than asking, since there is no sensible way to answer that prompt. Shell
  output is also redacted by key value, which catches reads the path guard cannot see.
  The guard matches full paths only, never file names, so your own project's
  `credentials.json` still opens normally.
- **Settings warns if the key file's permissions drift** and offers to repair them. A restore
  from backup or a sync tool can widen them, and nothing else would notice.

### Changed
- Settings no longer claims keys are "never written to a file", because they now are. It says
  they are stored in one file only you can read.
- `scripts/set-key.sh` writes the file instead of calling `security`, and gained `--list` and
  `--remove`. `scripts/doctor.sh` reports the file's mode and warns when it is not `600`.

### Removed
- `Keychain.swift`, and every use of the `security` command line tool for storing keys.

### Migration
- **Keys already in the Keychain are not carried over**, because reading them would raise the
  password dialog this change exists to remove. Add yours again in Settings (⌘,) or with
  `scripts/set-key.sh gemini`. To clear the old item:
  `security delete-generic-password -s app.botharness.keys -a gemini`.

### Security
- **The safety floor now reads a shell command instead of scanning it for words.** Four commands
  that used to get past it no longer do: `rm -fr /` (flags in the other order), `rm -rf "$HOME"`
  (home named without a `~`), appending a key to `~/.ssh/authorized_keys` (the floor could not
  see redirects), and `curl … | sh` (nor pipes). Commands hidden behind `sudo`, `env`, `xargs`,
  `sh -c "…"`, `$(…)` and subshells are now found too, and a delete pointed at something that
  cannot be resolved without running it — `rm -rf "$TARGET"` — is treated as the most alarming
  case rather than the least.
- **"I could not read this command" is now a real answer**, and it asks you. Previously an
  unparseable command was indistinguishable from a safe one. 27 new tests; no new dependency
  (see docs/decisions/0010-parse-shell-before-judging-it.md).

### Added — research
- **Grok Bot's `app.asar` read for the first time** (`docs/research/grok-bot-app-asar.md`).
  Their permission model turns out to be five layers, not the one natural-language rule table
  the screenshots showed: a real `tree-sitter-bash` parse of every command, a classifier over
  that parse, a model risk judgement, the natural-language rules, and an admin-set ceiling.
  Also documents a gap in our own safety floor — it matches substrings, so `rm -fr /`,
  `rm -rf "$HOME"`, a redirect into `~/.ssh/authorized_keys`, and `curl … | sh` all get past it.
  Written up, not fixed; the fix needs its own ADR.

### Fixed
- **The app no longer asks for your Mac login password over and over.** It was asking every
  time an eval run started, and in the running app it was asking as you typed — the check for
  "is there a key stored?" was accidentally reading the key itself, and reading a key is what
  raises that dialog. Checking now looks only at whether the item exists, which needs no
  authorisation at all. Where a key genuinely has to be read, it is read once per launch
  instead of once per message
  (see docs/decisions/0011-existence-checks-must-not-touch-the-acl.md).

### Security
- Keys are still in the login Keychain and the dialog was not suppressed or downgraded — the
  two shortcuts that would have silenced it, storing keys in a file or marking the item
  readable by any application without warning, were both rejected in ADR 0011.
- `scripts/set-key.sh` now adds the signed app to the key's trusted-application list, and its
  header points at Settings (⌘,) as the better path: a key stored by the app is owned by the
  app, so the app never has to ask for permission to read it. A key stored by the `security`
  command line tool belongs to that tool, which is why the app was being challenged for it.

### Added — the mascot
- **The mascot now shows what the bot is doing.** Six states, all built from the same eleven
  rectangles: it *walks* when nothing is happening, *trots on the spot* while a run is in
  progress, *hops twice and then waits* when a run is blocked on your approval, *jumps once*
  when one finishes, *slumps and sighs* when one fails, and *sleeps with its eyes shut* when
  there is nothing selected. That is the reason it earns permanent space above the message box:
  the field you are typing into is already where you are looking.
- **Claude's mascot walks on the strip above the message box**, standing on the composer
  rather than hanging in the middle of an empty conversation. Half the size it started at, on
  a strip about a third as tall.
- **Its size is one number.** `DS.Size.mascot` is the only mascot dimension: the strip's height
  and how far it walks are both derived from it, so changing it re-proportions the rest. How far
  it walks had to become a derived number for that to be true — pinned to the width of the
  composer, a smaller mascot would have taken the same ten strides across the same distance and
  skated instead of walked. It leans, looks around, walks
  the width of the composer, then crouches and jumps the rest of the way, on a loop. Ported
  from the public SVG-and-GSAP original rather than embedded — no browser and no animation
  library were added (see docs/decisions/0009-port-the-mascot-rather-than-run-it.md).
- It stands still when the Mac is set to Reduce Motion, and stops redrawing entirely when
  Bot-Harness is not the front app, so leaving the window open behind something else costs
  nothing.

### Changed — the design system is now actually implemented
- Every view is rebuilt on the token layer. An audit before this change found **157 raw font
  sizes, 215 raw spacings, 23 raw corner radii and 26 raw colours** still inline, with most
  components unused — `IconButton`, `Chip`, `EmptyState`, `Spinner`, `SectionLabel` and
  `Hairline` were all at zero. The earlier claim that no view contained a raw number was a
  token rename, not an implementation.
- After: **zero raw font sizes, zero raw radii, zero raw colours**, 586 token references, and
  every component in use. Icon sizes are named rather than derived, because arithmetic on a
  token at the call site is the same exception the system exists to prevent — it just looks
  more principled than a bare number.
- Empty and loading states are now real everywhere they were missing: an empty sidebar offers
  to make a bot, Connections shows row-shaped skeletons while it probes, the Activity window
  shows run-shaped skeletons while it scans the disk, and a screenshot shows an
  image-shaped one so nothing jumps when it lands.
- Trace and run scanning moved off the main actor. Reading a directory of runs, and decoding a
  Retina PNG, both dropped frames when done on the main thread while a run was streaming.

### Added — design system, live activity, screenshots in the conversation
- **A complete design system.** Space, radius, type scale, colour, size, motion and duration as
  one namespace, with a component layer covering every state including loading, empty and
  error. Documented in `docs/DESIGN-SYSTEM.md`. The old `Theme` is gone and all ten view files
  are migrated: no view contains a raw number or a raw colour any more.
- **Live activity behind a chevron.** What the bot is doing, streaming, collapsed by default and
  remembered. Shows the model's stated intent for each action, what it looked at, and what came
  back. Honest about its limit: Gemini returns no readable reasoning, only an opaque signature,
  so what is shown is intent plus everything the harness itself did.
- **Screenshots posted into the conversation**, like Grok Bot. Loaded from disk on demand and
  decoded off the main thread; the conversation document stores a path, never image bytes.
  Click to see full size.
- **From the rakazo teardown** (`docs/research/rakazo-teardown.md`, 37 patterns extracted from
  reading their source): screenshot deduplication by content fingerprint plus keep-last-N
  pruning, structural untrusted-content envelopes with the label placed *before* the content,
  and a repeated-identical-call guard that answers instead of re-running.

### Fixed
- **`files.glob` could not do recursive patterns.** `find -name` matches basenames only, so
  `**/*.swift` matched nothing — seen live, where the model responded by retrying with
  ever-broader patterns until it was listing the whole Desktop. Recursive patterns now work,
  build and dependency directories are pruned, and an empty result explains the pattern rule
  rather than just saying nothing was found.

### Changed — a real design system
- **Radix Colors for surfaces, macOS semantics for everything the OS owns**
  (`docs/decisions/0010-…`). The interface was thirty hand-picked hex greys, six half-point
  font sizes, and `Color.white.opacity(…)` scattered everywhere. Three measurements taken on
  this machine reframed it: macOS label colours are not greys but white at fixed alphas; the
  system palette shifted in macOS 26 (`systemRed` is now `#FF383C`); and macOS publishes no
  numeric surface ramp at all, while a three-pane cockpit needs five depths.
- **The functional layer is no longer painted.** The roster and inspector inherit the system
  material, the app uses a real `NavigationSplitView` with resizable columns, and the
  conversation pane is filled *darker* than the window — the native relationship. This is the
  single change that decides whether the app reads as Mac-native or as a web page in a window.
- **Five type steps, each bound to a system text style**, replacing six half-point sizes that
  matched nothing the OS draws and never optically lined up with the toolbar.
- **Motion is frequency-gated through one chokepoint.** Nothing triggered by a keyboard
  shortcut animates. 300ms ceiling. Reduced motion handled once rather than at ninety call
  sites.
- `docs/DESIGN-SYSTEM.md` — the full specification, and the record of where the research
  contradicted itself.

### Added — bots that describe themselves, and four patterns from rakazo
- **Bots write their own name and description.** After a successful run a bot updates its
  description from what it has actually been asked to do, the way Grok Bot does. A fresh bot
  asked to count Swift files named itself "File Scout" and wrote its own summary. Editing the
  text by hand locks it and the bot never overwrites your words; a button gives it back.
- **Live activity stream** behind a chevron between the conversation and the composer.
- **Streaming secret redactor.** Seeded with the actual key values for the run, not regexes, and
  it holds back the tail of the buffer so a secret split across two stream chunks is still
  caught. This matters here specifically: the trace is hash-chained, so a leaked key cannot be
  edited out afterwards without breaking the chain.
- **Loop guard.** Six identical tool calls ends the run — as a *completion* with a plain
  explanation naming the tool and the count, not as a failure. A red run with no explanation
  tells the user nothing they can act on.
- **Screenshot economy.** Frames are content-hashed, and an unchanged screen returns a sentence
  instead of an identical picture. Most looks in a GUI loop return the same frame, and paying
  roughly 1,500 tokens to say "still the same" is the most wasteful thing a screen agent does.
- `docs/research/rakazo-teardown.md` — 112 KB from reading elie222/rakazo's source, 36 patterns
  ranked by value and effort.

### Added — capabilities, and a way to see what happened
- **A working MCP client**, written against the wire format with no dependencies. stdio and
  HTTP transports, both verified against real servers. This is the piece that turns a list of
  hoped-for integrations into real ones: **Perplexity (4 tools), Lightroom (14) and Framer
  (22) now connect live** — 40 tools that were unreachable before.
- **Capability registry and resolver.** The agent asks for a capability, not a vendor. Two
  meta-tools let it extend its own reach mid-task: `capability.search` describes what it needs
  in plain words and gets back names and one-liners; `capability.load` brings a provider's
  operations into reach. So "put these in HubSpot" now discovers that HubSpot is not connected
  and says so, instead of inventing a worse plan.
- **Provider health with six states** — healthy, degraded, needs sign-in, starting, offline,
  error. A connector that fails stays visible with the reason and a repair action. Figma
  Desktop reports "not reachable, is the app running?"; Magic reports its reset API key.
- **Activity window** (account menu → Activity). Every run, every step, in order: the model's
  stated intent, the literal arguments, what came back, what the permission system decided and
  which layer decided it, tokens and cost. It verifies the hash chain on open, because a
  tamper-evident log nobody checks is just a log.
- **Connections screen driven by real health**, not a hardcoded list.

### Fixed
- **⌘N left the composer unfocused**, so creating a bot and typing did nothing. Focus now
  follows an explicit request rather than a flag, because setting a flag that is already true
  changes nothing and that was exactly the case.
- **`files.glob` could not handle `**/*.swift`.** `find -name` matches basenames and treats
  `**` literally, and the depth limit was 2 — too shallow for a real source tree. A bot asked
  to count Swift files got nothing back, tried three more globs, and reached for Terminal.
  Recursive patterns now work and results are counted.

### Fixed — the app now actually responds
- **Nothing could be sent.** A `TextField` with `axis: .vertical` swallows Return, so
  `.onSubmit` never fired; there was no send button to fall back on; and the field never took
  focus. Three dead ends in one control, and together they made the whole app inert. Return
  now sends, Shift-Return makes a newline, a send button appears when there is something to
  send, and the composer takes focus when a conversation opens.
- **Four API shape errors**, each found by calling the live endpoint rather than trusting the
  docs. Function tools are one entry each with the name at the top level. Replies arrive as
  `model_output` with a `content` array, not a `text` field — so every reply would have been
  silently dropped. Every input part needs a `type`. Usage keys are `total_input_tokens` and
  `total_output_tokens`, so cost and tokens read zero.
- **`files.glob` never expanded `~`**, so every lookup under `~/Desktop` matched nothing, and
  an empty result was returned as an empty string — which tells the model nothing and sends it
  round the same call again. Empty results now say so in words.
- Replies were posted twice, because the closing note repeated what the bot had already said.
- **Several tools were advertised and unimplemented** — `web.search`, `web.open`,
  `memory.search`, `memory.save` were all in the catalogue and threw "there is no tool called
  X" when chosen. That is the tool-layer version of a button that does nothing, and it is how
  a run asking to search the web ended up listing the root filesystem instead. All four are
  implemented, and eval H13 now calls every advertised tool so the class cannot come back.
- **A relative path meant the whole filesystem.** A GUI app's working directory is `/`, so
  `files.glob path=.` listed the root. Relative paths now resolve to the bot's workspace.

### Added
- **A brain switcher**, in the composer where the decision actually gets made. Also an
  autonomy switch: Ask, Work, Autopilot.
- **Connections, Computers and Skills**, reachable from the sidebar, listing what a bot can
  reach and saying plainly where something is not built yet.
- Every button now leads somewhere. The account row opens a menu, Share as template writes a
  file, Open computer reveals the screen panel, and Grant opens the right privacy pane.
- **The agent loop actually runs.** `observe → context → brain → permission → execute →
  observe → verify → continue`, with observation escalating from structured state to the
  accessibility tree to a screenshot only when the cheaper level was not enough.
- **Gemini brain adapter**, behind a provider-neutral `BrainAdapter` protocol so the harness
  owns the computer rather than the model vendor.
- **macOS executor** — screenshot, click, double/right click, drag, scroll, type, hotkey,
  launch app, and the accessibility tree. Typing goes through `keyboardSetUnicodeString`, so
  it is correct on any keyboard layout rather than silently wrong on non-US ones.
- **Persistent processes** — start, read new output only, status, kill. Without these a bot
  cannot run a dev server and then look at the page it serves.
- **Eval suite: 20 tasks**, twelve deterministic and eight needing a live model, across file
  editing, terminal, debugging, browser, app control, recovery, prompt injection and
  permission boundaries. `scripts/eval.sh`. Exits non-zero on failure so it can gate a commit.
- `scripts/build.sh` and `scripts/eval.sh`.
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
- Package split into `BotHarnessCore` and the UI. The core carries no SwiftUI, which is what
  lets the tests and the eval harness link it — an executable containing SwiftUI views cannot
  be linked into an XCTest bundle.
- Urgency budgets are expressed in work rather than wall-clock thinking time. "Critical means
  ten seconds of planning" was artificial; a ceiling on reasoning maps onto nothing the model
  or the harness controls, and punishes a hard problem for being hard.
- Parallel subagents pinned to 1 at every urgency, with the reason recorded in the type. One
  agent has to be excellent before several are worth the state races.
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
- **The eval suite found a real hole and it is fixed.** A user rule reading "push code to a
  remote" did not match `git push origin main`, because only one of its three content words
  appears in the command — so a safety rule the user wrote silently did nothing. Rule matching
  now bridges what people write to what commands look like, and is deliberately asymmetric:
  a near-miss on a restricting rule counts as a match, a near-miss on a permitting rule does
  not. Uncertainty narrows what a bot may do and never widens it.
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
