# Build environment — verified facts

Everything here was executed on this machine on 2026-08-29. Nothing is assumed.
Run `scripts/doctor.sh` to re-verify after any OS or toolchain update.

> **This document was wrong once already.** An earlier version stated that full Xcode was not
> installed, because `xcode-select -p` returns the Command Line Tools path and `xcodebuild`
> therefore errors. Both observations were correct and the conclusion drawn from them was
> false: Xcode 26.6 is on disk, it is simply not the selected developer directory. The
> correction is recorded here rather than quietly edited away, because "the tool errored, so
> the thing is absent" is a mistake worth not repeating.

## The machine

| | |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Architecture | arm64 (Apple Silicon) |
| **Selected** developer dir | `/Library/Developer/CommandLineTools` — Swift 6.0.3, SDK 15.2, target `macosx16.0` |
| **Available** developer dir | `/Applications/Xcode.app` — **Xcode 26.6 (17F113)**, Swift 6.3.3, target `macosx26.0` |
| SDKs under Xcode | `MacOSX.sdk`, `MacOSX26.sdk`, `MacOSX26.5.sdk` |
| Signing identity | `Apple Development: kunalbairwa232@gmail.com (PNJ8A4A6JP)` — `224FA75C1E159B4B50EE901312F3B38632663F97` |
| XcodeGen | 2.45.4 (`/opt/homebrew/bin/xcodegen`) |
| Node | v24.6.0, npm 11.5.1, pnpm 11.2.2 |
| Python | 3.10.11 default; **3.11 at `/opt/homebrew/bin/python3.11`**; `uv` 0.9.11 at `~/.local/bin/uv` |
| Docker | 29.3.1 |
| gh | 2.93.0, authenticated as `ckryptickunal` (`gist, read:org, repo, workflow`) |
| claude CLI | 2.1.238 at `~/.local/bin/claude` |
| Main display | 1800 × 1169 points → 3600 × 2338 pixels (2× Retina) |

### Two toolchains, and which one we use

The default toolchain is old because `xcode-select` points at Command Line Tools. To use the
current one, either set the environment variable per-invocation or switch globally:

```bash
# per-invocation, no admin rights needed — this is what scripts/ do
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

# or switch globally (needs your password)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**Bot-Harness currently builds against the CLT toolchain (Swift 6.0.3 / SDK 15.2) and works.**
The Xcode toolchain becomes necessary the moment we want macOS 26 SDK APIs — which includes
the current design language. That switch is a decision, not a default; see `docs/decisions/`.

## Building

A SwiftUI app that links ScreenCaptureKit, ApplicationServices and AVFoundation compiles with
**either** toolchain, and Swift Package Manager plus a hand-assembled bundle is enough. No
`.xcodeproj` is required.

```bash
./scripts/bundle.sh          # swift build → assemble .app → sign → print designated requirement
open build/BotHarness.app
```

Verified: `swift build -c release` completes in 38s cold, ~1.5s warm, exit 0.

## Code signing — the finding that saves weeks

macOS keys TCC permission grants (Screen Recording, Accessibility) to an app's **designated
requirement**. This is not a detail; it is the difference between a pleasant project and a
miserable one.

- **Ad-hoc signing (`codesign -s -`)** produces a designated requirement built from the
  per-build **cdhash**. Every rebuild is therefore a different app, and macOS silently revokes
  both permissions. For an app whose entire purpose requires those two permissions, that is
  fatal to the development loop.
- **The Apple Development certificate on this machine** produces an identity-based requirement
  with no hash in it:

  ```
  designated => identifier "app.botharness.mac"
                and anchor apple generic
                and certificate leaf[subject.CN] = "Apple Development: kunalbairwa232@gmail.com (PNJ8A4A6JP)"
                and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
  ```

**Verified empirically:** built twice with a source change between builds. The cdhash changed;
the designated requirement was byte-identical. Grants persist. `scripts/bundle.sh` therefore
discovers and uses this certificate automatically and only falls back to ad-hoc if no
certificate exists, printing a warning when it does.

`spctl -a -vv` still reports `rejected`, because an Apple Development certificate is not a
Developer ID. That only matters for giving the app to someone else; a locally built app is
never quarantined and so is never assessed. Distribution needs Developer ID + notarisation.

## TCC / permission APIs — availability confirmed

Probed with non-prompting APIs only, so nothing was shown to the user:

| Check | Result |
|---|---|
| `AXIsProcessTrusted()` | `true` |
| `CGPreflightScreenCaptureAccess()` | `true` |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | `0` (notDetermined) |
| `CGEventSource(stateID: .hidSystemState)` | constructible — **input synthesis available** |
| `CGEvent(mouseEventSource:…)` | constructible |

> **Read the caveat.** A command-line binary inherits the TCC identity of whatever launched it.
> Those `true` values describe the terminal running this session, not `BotHarness.app`. The app
> must obtain its own grants under `app.botharness.mac`. That is the first thing to test on the
> next run, and it is the one claim in this document that has been reasoned about but not yet
> observed.

## Open problem: disk space

```
/System/Volumes/Data   460Gi size   428Gi used   1.4Gi available   100% capacity
```

**1.4 GB free.** Enough to keep building this project, and not enough to install much of
anything: a second Python toolchain, a browser automation runtime, a local eval harness, or
any container image. Several things this project will eventually want are blocked until space
is cleared. This is a real constraint on sequencing, not a nag.

## Credentials

- **No LLM API keys in the shell environment.** Only `ANTHROPIC_BASE_URL` is set.
  `ANTHROPIC_API_KEY` and `GEMINI_API_KEY` are both unset.
- Gemini keys exist in several project `.env` files (`transcriptor/`, `AraviAI/`, `KurtiAICLI/`,
  `catalogue-platform/`, `reel-vault/`). Their values were not read.
- `gcloud` is configured for `lanesurfdesign@gmail.com`, project `teaching-479115`.
- The `claude` CLI is signed in via subscription and supports headless streaming:
  `--print`, `--output-format stream-json`, `--input-format stream-json`, `--permission-mode`,
  `--mcp-config`, `--agents`, `--settings`, `--append-system-prompt`, `--model`, `--resume`.

**Bot-Harness stores its own keys in the macOS Keychain under service `app.botharness.keys`
and nowhere else.** It does not read those `.env` files. Add one with `scripts/set-key.sh gemini`.

## Prior art on this machine worth reading before writing code

| Path | Why it matters |
|---|---|
| `~/Desktop/FableEnable/` | A zero-dependency SwiftUI macOS app, 2,878 lines, that already solves the SPM-only build, Keychain-backed keys, streaming SSE against Anthropic and OpenAI in pure `URLSession`, a ⌘K palette, and a considered motion system. |
| `~/Desktop/FableEnable/Sources/Fable/LLM.swift` | Keychain wrapper plus provider failover chain. Directly reusable. |
| `~/Desktop/FableEnable/.agents/skills/` | Local design skills: `swiftui-ui-patterns`, `impeccable`, `emil-design-eng`, `make-interfaces-feel-better`. Read before UI work. |
| `/Applications/Grok Bot.app` | The product being answered. See `docs/research/grok-bot-teardown.md`. |
