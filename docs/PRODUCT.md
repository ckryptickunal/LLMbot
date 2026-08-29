# Bot-Harness — product definition

> **Naming note.** The working directory is `Bot-Harness`; the public repository is
> [`ckryptickunal/LLMbot`](https://github.com/ckryptickunal/LLMbot), described as
> "Open-Source version of Grok Bot for your personal LLM". One name should win before
> the first release. This document uses **Bot-Harness** throughout as the codename.

---

## One sentence

Bot-Harness is a native Mac app where you keep a roster of named bots — each with its own
persona, its own tools, its own permissions, and the ability to actually use your computer —
that you talk to like people, put in rooms together, and run on your own API keys.

## The trade we are making

Grok Bot gives each bot a **rented cloud desktop**. That desktop has none of your files, none
of your logged-in browser sessions, none of your repositories, and a weekly usage cap set by
someone else. It is safe, and it is disconnected from your actual life.

Bot-Harness gives each bot **your Mac**. Your files, your Chrome with you already signed in,
your terminal, your repos, your Notes and Messages. This is enormously more useful and
enormously more dangerous, which is why the permission system is not a feature of this product
— it is the product's spine. Everything else is downstream of getting that right.

We accept the danger and engineer against it. We do not dodge it by moving the work somewhere
it cannot help.

## Who it is for

Initially one person: Kunal, on a Mac, with a Gemini API key and a Claude Code subscription,
who already runs a dozen half-automated projects and wants them to run themselves. The design
target is that everything is legible and controllable by someone who is technical, without
requiring them to be in a terminal.

Because it is open source and bring-your-own-key, the second audience is anyone who wants the
Grok Bot experience without renting the bots.

---

## The five objects

Everything in the product is one of five things. If a proposed feature is not one of these,
it is probably a setting on one of these.

### 1. Bot

A named agent with a persistent identity.

| Field | Meaning |
|---|---|
| Name | What you call it. "Joby", "Jewel Partnership". |
| Avatar | A generated or chosen mark. Identity at a glance in the sidebar. |
| Label | Optional short tag: "Research, marketing, admin". |
| Description | The persona and standing instructions. This is the system prompt, written in plain language *about the user and the job*, not as prompt-engineering. |
| Brain | Which provider and model runs it, and at what effort. Per bot, not global. |
| Plugins | Which tools this bot may reach for. A subset of what is installed. |
| Permissions | Its own auto-review rules, layered over the global floor. |
| Workspace | The directory it treats as home. |
| Notifications | Whether it may interrupt you when it finishes or gets stuck. |
| Memory | What it has learned that should survive across conversations. |

A bot is exportable as a **template**: everything above except your credentials and your
history. Templates are how a bot becomes shareable.

### 2. Chat

One continuous thread per bot. This is the primary interface — not a task board, not a graph.
You talk to a bot the way you would text a colleague, and its work appears in the thread as it
happens: prose for what it concluded, cards for what it did.

### 3. Channel

*Not in Grok Bot. This is ours.*

Several bots and you, in one conversation. A channel has a topic and a roster. Bots in a
channel can see each other's messages and address each other by name. One bot may be the
channel's lead, able to delegate.

The point is not novelty. It is that real work crosses bots: the research bot finds the
companies, the outreach bot writes to them, the bookkeeping bot logs it. Today that means you
manually carrying context between three threads. In a channel they carry it themselves, and you
watch one conversation instead of three.

Channels need rules that individual chats do not — who may speak unprompted, how loops between
two bots are stopped, whose permissions apply when bot A asks bot B to do something. Those are
open design problems, recorded as such, not hand-waved.

### 4. Plugin

The user-facing noun for "a thing that gives bots new abilities". An MCP server is a plugin. A
built-in tool group is a plugin. A connector to Gmail is a plugin.

Users install plugins from a searchable, categorised catalogue and enable them per bot. That a
given plugin is an MCP server over stdio is an implementation detail they never need to learn.

### 5. Routine

Work that happens without you asking each time. A schedule ("every weekday at 9"), a watch
("when a reply lands in this thread"), or a trigger. Routines are visible objects you can list,
pause, and edit, and when one fires it says so in the chat as a muted system line rather than
pretending a human asked.

---

## The Computer

Any bot may be granted the ability to use a computer. When it does, the work appears in the
chat as a **Computer card**: what it was asked to do, a live status, and a button to open the
screen and take over.

Two environments, chosen per bot:

- **This Mac** — the real machine. Real files, real browser sessions, real apps. Screen capture
  through ScreenCaptureKit, input through the accessibility and event APIs, browser control
  through a real Chrome profile. Gated by the permission system.
- **A container** — a disposable Linux environment for work that should not touch anything.
  Slower to be useful, impossible to regret.

The switch between them is a bot setting, and the same agent code runs against both. That
abstraction is worth building on day one even though only one side ships first, because
retrofitting it later means rewriting every tool.

---

## Permissions

Two layers, and the lower one cannot be lowered.

**The floor (built in, not user-editable).** Actions that always stop and ask, or always
refuse, no matter what rules exist: moving money, entering credentials, deleting outside the
workspace, force-pushing, sending on your behalf to someone new, granting OAuth scopes,
anything a webpage or document asked the bot to do rather than you.

**Your rules (natural language, per bot and global).** You write "reply to emails for me" and
choose "Allow automatically". You write "spend money" and choose "Always ask". Rules are matched
semantically against what the bot is about to do, and **ask always beats allow** when two rules
both apply. This is Grok Bot's design and it is the right one: it is writable by a person who
would never write `Bash(git push:*)`.

Every decision the permission system makes — allowed, asked, refused, and why — is written to
the trace. A permission system you cannot audit is a permission system you cannot trust.

---

## Bring your own everything

- **Your keys.** Gemini, Anthropic, OpenAI, whatever else. Stored in the macOS Keychain, never
  in a config file, never in a prompt, never in a log.
- **Your models.** Per bot. A cheap fast model for a watcher routine, a strong one for the bot
  that writes code.
- **Your agents.** The local `claude` CLI in headless mode is a first-class brain, so a
  Claude Code subscription counts as a provider. So does any other CLI agent that speaks
  streaming JSON on a pipe.
- **Your tools.** Any MCP server. Your own scripts.
- **Your data.** Everything on disk, in your home directory, in formats you can read without
  this app.

---

## What "simple" means here

The user asked for this to be as simple as it could get. Concretely, that means:

1. **Launch to first working bot in under five minutes**, including pasting one API key.
2. **No terminal required** for anything a normal user does. Installing a plugin, granting a
   permission, changing a model, reading a trace — all in the app.
3. **No configuration files to hand-edit.** They exist, they are readable, but the app is the
   interface to them.
4. **Permissions asked in plain language**, at the moment they matter, with the actual command
   or message shown.
5. **One obvious place to look when something goes wrong** — the trace, opened from the failing
   message.

## What we are explicitly not building

- A cloud service, a login, or a subscription.
- A multi-user or team product.
- A node-graph canvas. (Fable already explores that space; this is deliberately a chat app.)
- Our own browser engine, sandbox runtime, VM manager, coordinate-prediction model, or vector
  database. Those are solved elsewhere and are not where this project's value is.
- A general agent framework for other developers to build on. This is an application.

---

## How we will know it works

The acceptance tests, all four chosen by the user, each run end to end without intervention:

1. **Code on a real repo.** Open one of Kunal's projects, understand it, make a change, run it,
   verify the change works, report back.
2. **Research to artifact.** Investigate something across many sites and produce a spreadsheet
   or document.
3. **Drive Mac apps.** Operate Finder, Notes, Messages, Mail, and Chrome with real sessions.
4. **Run the existing bots.** Operate JewelAI, Twitteroo, and the transcriptor pipeline on a
   schedule, unattended.

Plus one that is not a task: **after any run, the complete decision trace can be read back and
explained** — every model call, every tool call, every permission decision, every screenshot.
