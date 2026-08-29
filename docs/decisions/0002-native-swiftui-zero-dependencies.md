---
id: 0002
title: Native SwiftUI in one Swift binary, with no third-party dependencies
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [architecture, ui, build]
---

# 0002. Native SwiftUI in one Swift binary, with no third-party dependencies

## Context

The app must be Mac-native, feel simple, hold invasive OS permissions, and be installable by a
user without them provisioning a language runtime first.

Notably, the product being answered took the opposite path: Grok Bot is Electron and 307 MB.

Two facts on this machine settle most of the argument. First, a SwiftUI app that links
ScreenCaptureKit, ApplicationServices and AVFoundation **compiles and links with Command Line
Tools alone** — verified, 38 s cold build, exit 0. Second, the user already has a working
zero-dependency SwiftUI macOS app of this exact shape at `~/Desktop/FableEnable`, 2,878 lines,
which has already solved the bundle assembly, the Keychain wrapper, and streaming SSE against
provider APIs in plain `URLSession`.

## Options considered

### Option A — Native SwiftUI, no packages
- **For:** Direct access to ScreenCaptureKit, the Accessibility APIs and CGEvent with no bridge.
  One binary, nothing for the user to install. Genuinely native. A working precedent on disk.
- **Against:** Slower to make visually lavish than HTML. No npm ecosystem: an MCP client, a CDP
  client and an SSE parser all have to be written rather than installed.
- **Verified against:** `docs/guides/ENVIRONMENT.md`, `~/Desktop/FableEnable/`

### Option B — Electron or Tauri
- **For:** Fastest UI iteration, the largest component ecosystem, and the approach the reference
  product actually chose.
- **Against:** OS control still has to go through a native helper, so the hard part is not
  avoided — it is relocated and given an IPC boundary. Tauri additionally needs Rust, which is
  not installed, on a disk with 1.4 GB free.

### Option C — Swift shell hosting a web UI in WKWebView
- **For:** Native permissions and native OS control, with HTML for the interface.
- **Against:** Two languages and a bridge from day one, for a UI that is a list, a thread and an
  inspector — none of which need HTML.

## Decision

We chose **Option A**.

Because: the permissions this app must hold are the whole product, and every non-native option
ends up writing the native part anyway, just with a bridge in front of it.

Sidecar processes (MCP servers, a browser driver) are still spawned as subprocesses. The rule
constrains what is *linked into the app*, not what it may talk to.

## Consequences

- **We now must:** write our own MCP client, Chrome DevTools Protocol client, and SSE parser.
  Each is a known, bounded amount of work against a documented wire format.
- **We now must:** justify any package in an ADR. A dependency in this app is something the
  user has to trust with Screen Recording and Accessibility.
- **We can no longer:** drop in a React component library when the UI needs something rich.
- **We gain:** an app with no runtime prerequisites, that starts instantly and is a few MB.

## Revisit when

A capability we need genuinely has no reasonable Swift path — the most likely candidate is a
browser automation layer far richer than CDP-over-WebSocket. That would justify a Node sidecar,
not a change to what the app links.
