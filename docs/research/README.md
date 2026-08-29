# Research index

Fourteen parallel research tracks plus a synthesis pass, run 2026-08-29 against live sources:
15 agents, 1.84M tokens, 605 tool calls, 27 minutes, 321 individually sourced facts.

Read [`00-synthesis`](00-synthesis.md) first. It carries the cross-cutting stack recommendation
and, more usefully, every place the tracks contradicted each other or contradicted the brief
this project started from.

| Track | Covers |
|---|---|
| [`00-synthesis`](00-synthesis.md) | 00-synthesis |
| [`grok-bot-teardown`](grok-bot-teardown.md) | Grok Bot teardown |
| [`reference-products-grokbot-hermes`](reference-products-grokbot-hermes.md) | Reference products for Bot-Harness: "Grok Bot" (SpaceXAI + Cursor desktop agent app) and "Hermes Agent" (Nous Research) — UI/UX teardown and |
| [`openclaw`](openclaw.md) | OpenClaw (ex-Clawdbot, ex-Moltbot) — architecture, permission model, and what a Mac-native computer-use harness should borrow |
| [`gemini-computer-use`](gemini-computer-use.md) | Google Gemini Computer Use — current state as of 2026-08-29 (tool shape, model IDs, safety keys, SDK, desktop support) for the Bot-Harness M |
| [`claude-brains-and-agent-sdk`](claude-brains-and-agent-sdk.md) | Anthropic computer-use + agent-building stack as of 2026-08-29, evaluated as the brain for a Mac-native personal computer-use harness (Bot-H |
| [`agent-runtime`](agent-runtime.md) | Agent runtime for Bot-Harness: loop, planning, verification, recovery, memory, context management (verified 2026-08-29) |
| [`harness-engineering`](harness-engineering.md) | Harness engineering as a named discipline; awesome-harness-engineering taxonomy; Vercel AI SDK harness primitives; SDK choice for a Swift-UI |
| [`controlling-a-real-mac`](controlling-a-real-mac.md) | Cua (trycua) and the landscape of libraries that let an agent control a real Mac — verified against live sources on 2026-08-29 |
| [`macos-native-app-stack`](macos-native-app-stack.md) | Building and shipping a polished Mac-native app for Bot-Harness on macOS 26.5 / Apple Silicon — toolchain feasibility, code signing, TCC per |
| [`browser-layer`](browser-layer.md) | Browser layer for Bot-Harness: deterministic + visual control of a real, logged-in Chrome on a local Mac (Playwright, browser-use, Skyvern,  |
| [`mcp-ecosystem`](mcp-ecosystem.md) | Model Context Protocol (MCP) as the extension layer for a Mac-native computer-use agent host, verified as of 2026-08-29 |
| [`sandboxing-and-safety`](sandboxing-and-safety.md) | Sandboxing and the safety kernel for Bot-Harness: a Mac-native agent that runs shell commands and controls macOS 26.5 on Apple Silicon |
| [`observability-and-eval`](observability-and-eval.md) | Observability, decision-trace logging, and evaluation for a Mac-native computer-use agent harness (Bot-Harness) |
| [`agent-docs-conventions`](agent-docs-conventions.md) | Repo Markdown structure + .claude/ configuration + decision/change logging conventions that make Claude Code work maximally well on Bot-Harn |
| [`ui-ux-reference`](ui-ux-reference.md) | UI/UX for a Mac-native agent cockpit (Bot-Harness): reference-product layouts, live screen streaming on macOS, macOS 26 Liquid Glass design  |