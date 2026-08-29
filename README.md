# Bot-Harness

**An open-source, local-first Grok Bot. Your bots, your Mac, your API keys.**

A native macOS app where you keep a roster of named bots — each with its own persona, tools,
permissions, and the ability to actually use your computer — that you talk to like people, put
in rooms together, and run on your own models.

> **Status: early construction.** The architecture is decided and documented; the app is being
> built. Nothing here is ready to rely on yet. See [`CHANGELOG.md`](CHANGELOG.md) for what
> actually exists as of today, and [`docs/decisions/`](docs/decisions/) for why it is shaped
> this way.

---

## Why

[Grok Bot](docs/research/grok-bot-teardown.md) gets the interface exactly right — bots as
contacts, a chat you talk into, a computer they can use, permission rules written in plain
English — and then gives each bot a **rented cloud desktop** that contains none of your files,
none of your logged-in browser sessions, and none of your repositories, behind a weekly usage
cap you do not control.

Bot-Harness makes the opposite trade. Your bots run on **your Mac**, against your real files,
your real Chrome, your real terminal, your real projects. That is far more useful and far more
dangerous, which is why the permission system here is not a feature — it is the spine of the
product, and everything else hangs off it.

|  | Grok Bot | Bot-Harness |
|---|---|---|
| Where the computer is | Cloud VM | Your Mac (or a container, per bot) |
| Your files and sessions | No | Yes |
| Models | Theirs | Yours — Gemini, the local `claude` CLI, anything |
| Keys | Theirs | Yours, in the macOS Keychain |
| Usage limits | Weekly cap they set | Yours |
| App | Electron, 307 MB | Native SwiftUI, no Xcode required to build |
| Source | Closed | Open |
| Bots working together | One thread each | **Channels** — several bots in one room |

## What it is made of

Five objects, and everything is one of them:

- **Bots** — named agents with an avatar, a persona, a brain, a toolset, and their own permissions.
- **Chats** — one thread per bot. The primary interface. Not a task board, not a graph.
- **Channels** — several bots and you in one conversation, so work can cross bots.
- **Plugins** — what gives bots abilities. MCP servers, connectors, built-in tool groups.
- **Routines** — scheduled or triggered work that runs without you asking each time.

Read [`docs/PRODUCT.md`](docs/PRODUCT.md) for the full definition.

## Requirements

- macOS 14 or later on Apple Silicon (developed against macOS 26.5)
- Swift 6 via Command Line Tools — **full Xcode is not required**
  (`xcode-select --install`)
- At least one brain: a Gemini API key, or the `claude` CLI signed in, or both

Optional, for particular plugins: Node 20+, Python 3.10+, Docker.

## Build

```bash
git clone https://github.com/ckryptickunal/LLMbot.git bot-harness
cd bot-harness
./scripts/doctor.sh      # verifies the machine has what it needs
./scripts/bundle.sh      # builds and assembles BotHarness.app
open build/BotHarness.app
```

The app is ad-hoc signed, which is fine for running it on the machine that built it. Sending
the `.app` to another Mac requires a Developer ID and notarisation — see
[`docs/guides/ENVIRONMENT.md`](docs/guides/ENVIRONMENT.md).

## Safety, stated plainly

This app is designed to run shell commands, edit files, drive a browser you are logged into,
and control macOS applications on your behalf. That is the point of it, and it is genuinely
dangerous. The mitigations are real but they are not magic:

- A **non-overridable floor** of actions that always stop and ask: moving money, entering
  credentials, deleting outside the workspace, force-pushing, sending to new recipients,
  granting OAuth scopes.
- **Natural-language rules** you write per bot, where *ask* always beats *allow* on conflict.
- Content the agent reads from web pages, files and emails is treated as **data, never as
  instructions**. A page that tells a bot to do something does not get to.
- **Every decision is written to disk** — every model call, tool call, approval and refusal —
  so a run can be audited after the fact rather than taken on trust.
- API keys live in the **macOS Keychain**. They are never written to config files, never put in
  prompts, and are redacted from traces before they are stored.

Do not point this at anything you cannot afford to have broken until you have read the trace
from a few runs and believe it.

## Documentation

| | |
|---|---|
| [`docs/PRODUCT.md`](docs/PRODUCT.md) | What we are building and what we are deliberately not |
| [`docs/research/grok-bot-teardown.md`](docs/research/grok-bot-teardown.md) | Evidence-based teardown of the product this answers |
| [`docs/guides/ENVIRONMENT.md`](docs/guides/ENVIRONMENT.md) | Verified build environment facts and the no-Xcode recipe |
| [`docs/decisions/`](docs/decisions/) | Every architectural decision, with its falsifier |
| [`CHANGELOG.md`](CHANGELOG.md) | What changed, and when |
| [`CLAUDE.md`](CLAUDE.md) | How coding agents should work in this repository |

## Prior art this borrows from

- **[Grok Bot](docs/research/grok-bot-teardown.md)** (Anysphere / xAI) — the interface and the
  natural-language permission model.
- **[clicky](https://github.com/farzaa/clicky)** and
  **[openclicky](https://github.com/jasonkneen/openclicky)** — native Swift menu-bar companions
  that prove the ScreenCaptureKit + accessibility + local-control-bridge pattern on macOS.
- **Fable** — the author's own zero-dependency SwiftUI harness, source of the no-Xcode build
  recipe and the Keychain-backed provider layer.

## Licence

Not yet chosen. See the open question in `docs/decisions/`.
