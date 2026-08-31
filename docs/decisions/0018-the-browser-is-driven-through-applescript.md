---
id: 0018
title: The browser is driven through AppleScript, not a debugging port
status: accepted
date: 2026-08-31
deciders: [Kunal, Claude]
tags: [browser, capability]
supersedes: []
superseded_by: []
---

# 0018. The browser is driven through AppleScript, not a debugging port

## Context

`BuiltInTools` advertised `browser.navigate`, `browser.extract`, `browser.click` and
`browser.type` to the model, granted the capability `browser.use`, and `AgentLoop` had **no
dispatch case for any of them** — verified by grep. Every call returned "There is no tool called
browser.navigate". The product's headline claim that a bot drives a logged-in browser was dead,
and worse, its failure pushed all web work onto `computer.screenshot`, which is the one channel
nothing can redact.

The requirement that shapes the whole decision: it must drive the browser the user is *already
logged into*. A fresh automation profile has none of their sessions, which is the entire point.

## Options considered

### Option A — Chrome DevTools Protocol
- **For:** The capable, precise option: real waits, network interception, addressing any tab.
- **Against:** Attaching requires relaunching Chrome with `--remote-debugging-port`, which kills
  the user's open windows — and is the same move a session-stealing attack makes. Asking a person
  to run their daily browser with an open debugging port to use a feature is asking them to lower
  their own security.
- **Verified against:** Chrome requires the flag at launch; it cannot be enabled on a running
  instance.

### Option B — AppleScript via `/usr/bin/osascript`
- **For:** Zero dependencies, drives the running browser with its existing sessions intact, no
  relaunch, and consent is the OS's own Automation prompt rather than something this app invents.
- **Against:** Needs "Allow JavaScript from Apple Events" enabled by hand. One window, one tab, no
  network interception, no waiting on a specific element.
- **Verified against:** `BrowserExecutor.swift`; Chrome's refusal string was read verbatim out of
  its own resource bundle on this machine.

## Decision

We chose **Option B**.

Because: the capability is only worth having if it uses the user's real sessions, and Option A buys
precision by asking them to restart their browser in a less safe configuration every time.

The security boundary is the URL scheme rather than the filesystem. `file://` is refused outright —
a bot could otherwise read `credentials.json` through the browser and walk straight around every
filesystem guard — as are `javascript:`, `data:` and `about:`. Everything interpolated into
AppleScript and into JavaScript is escaped, because an unescaped quote in a selector or a URL is a
script-injection hole; the escaper's output was round-tripped through the real `osascript` parser.
Page text is wrapped as untrusted content inside the executor rather than at the call site, so no
future rewiring can drop the envelope.

## Consequences

- **We now must:** tell the user exactly which menu item to enable when JavaScript-from-Apple-Events
  is off. Chrome's message is quoted from Chrome; Safari returns an opaque `-10000` for several
  unrelated failures, so its error hedges out loud rather than asserting a cause it cannot prove.
- **We can no longer:** wait on a specific element, intercept network traffic, or address a tab
  that is not frontmost.
- **We will know this was wrong if:** a real task needs any of those three. That is the falsifier,
  and it is a likely one for anything resembling a login flow with a slow redirect.

## Revisit when

A task needs to wait for an element or read a network response. At that point CDP becomes necessary
and the launch problem has to be solved honestly — most likely a separate, clearly-labelled browser
profile the user opts into, rather than reconfiguring their daily one.
