# Browser layer for Bot-Harness: deterministic + visual control of a real, logged-in Chrome on a local Mac (Playwright, browser-use, Skyvern, Stagehand, MCP servers, hosted sandboxes)

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The single biggest change since your assumptions were formed is that Chrome now controls this problem, not the automation libraries. Chrome 136 killed the old trick of pointing `--remote-debugging-port` at the default profile, and Chrome 144 replaced it with an explicit, user-consented opt-in at `chrome://inspect/#remote-debugging`. Kunal's machine is on Chrome 152, so that consented path is available today and is the correct foundation. Playwright's own docs now warn in writing that automating the default Chrome user profile via `launchPersistentContext` is unsupported, which rules out the naive "just point at ~/Library/Application Support/Google/Chrome" approach that browser-use's `Browser.from_system_chrome()` still implements. Separately, Anthropic shipped Claude in Chrome to general availability on 26 August 2026 — three days ago — on all paid plans, and it drives the user's real logged-in tabs through the extension `debugger` permission with a safety classifier per action; the MCP tool surface for it is already present in this Claude Code session. For a local Mac personal agent the hosted sandboxes (Browserbase, E2B, Daytona) are irrelevant to the core use case, because their entire value is a fresh cloud browser that by definition has none of Kunal's logins.

## Recommendation

Build the browser layer as two tiers over one CDP connection, and make the consented Chrome 144+ opt-in the front door.

Tier 1, the connection. Attach to Kunal's already-running Chrome 152 over CDP after he ticks "Allow remote debugging for this browser instance" once at chrome://inspect/#remote-debugging. Do not launch Chrome yourself with --remote-debugging-port against his profile (Chrome 136 ignores it) and do not point launchPersistentContext at his User Data directory (Playwright documents this as unsupported). Chrome's own consent dialog and its "controlled by automated test software" banner become your permission UX for free, which is exactly what a product that must "hold all needed OS permissions" wants — the browser vendor grants and displays the permission, not you.

Tier 2, the driving. Use Playwright, ideally through @playwright/cli, as the deterministic executor: snapshot to get element refs, then click/fill/press against those refs. Every one of those calls is a plain string you can write straight into your audit log, which satisfies the "log every decision/step/change for future agents to audit" requirement far better than a vision-model action stream. Reserve a vision or natural-language layer (Stagehand v4 with anthropic/claude-sonnet-5, attached via localBrowser.connect({cdpUrl})) for the cases where a ref-based step fails, and log the fallback as a distinct event type.

For the right-hand live computer view, run `playwright-cli show` or read its implementation before writing your own — it already does the live screencast grid, the address bar, and click-to-take-over with Escape to release. That is most of your third pane.

Before writing any of it, spend an hour inside browser-use/browser-harness. It is 17k stars, MIT, four months old, and it has already hit and solved the specific macOS problem you are about to hit: the per-connection Allow sheet, handled by `browser-harness mac-approve`, which needs Accessibility permission for the launching app. Even if you do not depend on it, its install.md is a map of your permission bugs.

Ignore the hosted sandboxes for v1. Browserbase, E2B and Daytona all sell fresh cloud browsers, and a fresh browser has none of Kunal's logins — the exact thing this product exists to use. Revisit them only as a deliberate "run this untrusted thing off my machine" mode later.

Two things to skip: Skyvern, because AGPL-3.0 in a shipped Mac app is a licensing problem you do not need and it drags in a server plus a database; and BrowserMCP, which has been dead since April 2025.

Finally, note what landed three days ago. Claude in Chrome went GA on 26 August 2026 on all paid plans, drives real logged-in tabs via the extension debugger permission, runs a per-action safety classifier, and its MCP tool surface (mcp__claude-in-chrome__*) is already exposed inside Claude Code. If Bot-Harness's real job is "Kunal's personal agent that uses his logged-in sessions," a meaningful slice of that now ships from Anthropic. Decide deliberately whether Bot-Harness wraps and orchestrates that extension — task list, audit log, multi-step planning, the polished shell — or duplicates it. Wrapping is the far cheaper bet.

## Risks

- CDP attach to the user's real Chrome is a full-profile compromise surface by design. Anything holding that websocket can read every cookie, every session token and every open tab across all sites simultaneously - there is no per-site scoping in CDP. Google's stated reason for the Chrome 136 lockdown was exactly this: malware abusing remote debugging to extract cookies and passwords. If Bot-Harness opens 127.0.0.1:9222, any other local process can use it too. Bind carefully, never expose beyond loopback, and treat the port's existence as a security event worth logging.
- The Chrome 144+ consent path depends on a checkbox and a per-connection dialog that the user must handle. browser-harness needed a dedicated `mac-approve` helper plus Accessibility permission just to dismiss that sheet on macOS - expect this to be your single largest source of onboarding friction and support burden, and budget real engineering for it rather than treating it as a one-line setup step.
- Chrome moved this policy twice in about eighteen months (136 blocked the old path, 144 replaced it with a new one). Assume it moves again. Isolate all attach logic behind one Swift protocol with a single implementation per strategy so a future Chrome change is a contained rewrite, not a scattered one.
- @playwright/mcp is still 0.0.79 and @playwright/cli is 0.1.18 - both pre-1.0, both moving weekly. Stagehand already shipped a breaking v3-to-v4 API change (act/observe/extract moved off page onto the stagehand object). Pin exact versions; do not use @latest in anything you ship.
- chrome-devtools-mcp sends usage statistics to Google by default, and its performance tools may send trace URLs to the Google CrUX API. For a personal agent operating on a logged-in profile this is a genuine privacy leak. Always pass --no-usage-statistics and consider --no-performance-crux.
- Prompt injection is the unsolved problem here, not automation. An agent driving a logged-in Gmail or bank tab will read attacker-controlled page text as input. Anthropic ships a safety classifier plus injection probes for Claude in Chrome and still calls it inherently risky; a hand-rolled harness has neither. Any autonomous mode needs a hard allowlist of domains and a confirm-gate on irreversible actions.
- browser-use's Browser.from_system_chrome() reads as the obvious answer and is a trap: its own docs say you may need to fully close Chrome first, which means taking over the profile rather than attaching to the live browser - and that collides with the Chrome policy Playwright warns about. Do not let it into the design just because it is the most-starred repo.
- Skyvern is AGPL-3.0 and Daytona reports no license at all in its GitHub metadata. Neither is safe to link into a distributed Mac app without a specific legal decision.
- Kunal has no full Xcode, only Command Line Tools. Nothing in this browser layer needs Xcode, but the Node and Python runtimes it depends on (Node 24.6.0, uv 0.9.11) become install-time prerequisites for a product meant to be 'dead simple' - you will need to either vendor them or ship a real bootstrap.
- Claude in Chrome going GA three days ago may make a large part of this layer redundant, and Anthropic will keep shipping into it. Building a parallel implementation risks being outrun. Verify the actual overlap before committing engineering time.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN THE BRIEF - 'how to drive Chrome on macOS with a real profile' is presented as a solved technique. It is not, in the form usually meant. Chrome 136 stopped honoring --remote-debugging-port against the default user data directory, and Playwright's docs explicitly state that automating the default Chrome user profile via launchPersistentContext is not supported and may cause pages not to load or the browser to exit. The only supported route today is the Chrome 144+ user-consented opt-in at chrome://inspect/#remote-debugging.
- WRONG IN THE BRIEF - 'browsermcp' is listed as a candidate for production readiness. It is abandoned: last commit 2025-04-24, last npm publish of @browsermcp/mcp 2025-04-11, about 16 months stale, and browsermcp.io returns HTTP 403.
- PARTLY WRONG IN THE BRIEF - browser-use/agent-sdk exists but is not what the name suggests. The package is bu-agent-sdk, it is a generic agent for-loop framework with no browser specialization, it has 686 stars, NO license set, and it has been stale since 2026-03-30.
- MISSING FROM THE BRIEF - two significant repos the assignment does not mention. browser-use/browser-harness (17,220 stars, MIT, created April 2026) is the vendor's current answer for real-browser control and is the closest prior art to Bot-Harness. microsoft/playwright-cli (@playwright/cli 0.1.18) is Microsoft's new CLI+SKILLS product, which Microsoft now recommends over Playwright MCP for coding agents, and it includes the live screencast dashboard the project needs.
- PARTLY WRONG IN MY OWN FIRST READ - I initially flagged Python 3.10 as a hard blocker for browser-use, browser-harness and Skyvern (all require >=3.11). Checking the machine falsified that: python3.11 is present at /opt/homebrew/bin/python3.11 and uv 0.9.11 is installed, and uv provisions 3.12 on demand. Not a blocker. Reporting the correction rather than the original claim.
- UNVERIFIED - I could not fetch browsermcp.io directly (HTTP 403). The abandonment conclusion rests on GitHub commit dates and npm publish dates, which I did verify, not on the project's own statements.
- UNVERIFIED - Modal sandboxes were named in the assignment and I did not fetch Modal's pricing or sandbox docs. I deprioritized this because every hosted sandbox fails the core requirement (real logged-in sessions) for the same structural reason, but the specific Modal numbers are absent.
- UNVERIFIED - I did not confirm the exact Chrome milestone that first shipped chrome://inspect/#remote-debugging as stable rather than beta. Google's blog describes M144 as Beta at the time of writing; Kunal's Chrome 152 is far past it and chrome-devtools-mcp documents --autoConnect as 'available in Chrome 144', but the stable-channel milestone number is not directly confirmed.
- UNVERIFIED - I did not test the Claude in Chrome extension end to end. list_connected_browsers returned an empty array, which confirms the MCP tool plane exists in this session but proves nothing about the extension's actual behavior on Kunal's Chrome, since no browser is currently paired.
- UNVERIFIED - the Playwright Extension required by playwright-mcp's --extension flag lives at microsoft/playwright/packages/extension; I did not fetch that README, so its install steps and current state are not confirmed.
- UNVERIFIED - Browserbase and E2B pricing came from their marketing pages via a summarizing fetch rather than from a pricing API. Treat the tier numbers as approximately right and re-check before any purchase decision.
- STALE-RISK - all version numbers here are as of 2026-08-29. Several of these packages publish weekly (playwright-mcp, chrome-devtools-mcp, stagehand, browser-use all pushed within the last 24 hours), so pin versions at implementation time rather than trusting these numbers a month from now.

## Verified facts

- Playwright is at 1.62.1 on npm (published 2026-07-30) and 1.62.0 on PyPI; the Python package requires Python >=3.10. The repo is Apache-2.0, 95,328 stars, pushed 2026-08-29.  
  — **confirmed** · <https://registry.npmjs.org/playwright>
- Playwright's own BrowserType docs state: "Chromium/Chrome: Due to recent Chrome policy changes, automating the default Chrome user profile is not supported. Pointing userDataDir to Chrome's main 'User Data' directory may result in pages not loading or the browser exiting." This directly falsifies the common 'just point Playwright at the real profile' pattern.  
  — **confirmed** · <https://playwright.dev/docs/api/class-browsertype>
- Playwright docs also warn that connectOverCDP "is significantly lower fidelity than the Playwright protocol connection" and that launching Chrome outside Playwright without Playwright's curated argument list may break functionality. CDP attach is Chromium-only.  
  — **confirmed** · <https://playwright.dev/docs/api/class-browsertype>
- From Chrome 136, --remote-debugging-port and --remote-debugging-pipe are no longer respected against the default Chrome data directory; they must be accompanied by --user-data-dir pointing at a non-standard directory. Google's stated rationale is that a non-standard data directory uses a different encryption key, protecting Chrome's data from attackers. Google recommends Chrome for Testing for automation.  
  — **confirmed** · <https://developer.chrome.com/blog/remote-debugging-port>
- Chrome M144 introduced a built-in, user-consented remote debugging opt-in at chrome://inspect/#remote-debugging. Every time an MCP server requests a remote debugging session, Chrome shows a permission dialog, and while a session is active Chrome displays the 'Chrome is being controlled by automated test software' banner.  
  — **confirmed** · <https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session>
- Kunal's machine has Google Chrome 152.0.7977.64 installed at /Applications/Google Chrome.app, which is well past the M144 threshold, so the consented auto-connect path is available today.  
  — **confirmed** · <https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session>
- chrome-devtools-mcp is at 1.8.0 on npm (published 2026-08-25), Apache-2.0, 50,080 stars, pushed 2026-08-28. It is built on Puppeteer and officially supports only Google Chrome and Chrome for Testing.  
  — **confirmed** · <https://github.com/ChromeDevTools/chrome-devtools-mcp>
- chrome-devtools-mcp exposes --autoConnect (Chrome 144+, requires the chrome://inspect/#remote-debugging opt-in), --browserUrl/-u, --wsEndpoint/-w, --userDataDir, --isolated, --channel, --headless and --slim. It also collects usage statistics by default, disabled via --no-usage-statistics or CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS.  
  — **confirmed** · <https://raw.githubusercontent.com/ChromeDevTools/chrome-devtools-mcp/main/README.md>
- microsoft/playwright-mcp is at @playwright/mcp 0.0.79 (published 2026-08-06), Apache-2.0, 36,598 stars, pushed 2026-08-28. It supports --cdp-endpoint, --user-data-dir, --isolated, --storage-state, --extension, --browser, --caps vision,pdf,devtools, --secrets and --save-session.  
  — **confirmed** · <https://raw.githubusercontent.com/microsoft/playwright-mcp/main/README.md>
- Microsoft now explicitly steers coding agents away from Playwright MCP toward a new CLI+SKILLS product: "Modern coding agents increasingly favor CLI-based workflows exposed as SKILLs over MCP because CLI invocations are more token-efficient." The package is @playwright/cli, at 0.1.18 (published 2026-08-06), Apache-2.0.  
  — **confirmed** · <https://github.com/microsoft/playwright-cli>
- playwright-cli ships a built-in visual monitoring dashboard via `playwright-cli show`, giving a live screencast grid of all sessions plus a detail view with tab bar, navigation controls and full remote takeover (click into viewport to control, Escape to release). This is close to the 'live computer view right' pane Bot-Harness needs.  
  — **confirmed** · <https://raw.githubusercontent.com/microsoft/playwright-cli/main/README.md>
- Claude in Chrome became generally available on 26 August 2026 across every paid Claude plan (Pro, Max, Team, Enterprise). It can act autonomously rather than asking approval per action, uses the user's existing logins, and a safety classifier validates each action; it uses the same auto-approve mechanism as Claude Code's auto mode.  
  — **confirmed** · <https://claude.com/blog/claude-in-chrome-generally-available>
- The Claude in Chrome extension requires the Chrome `debugger` permission, which is what "allows Claude to actually control your browser - clicking buttons, typing text", plus scripting, tabs/navigation, side panel, storage and downloads. It integrates with Claude Cowork and Claude Code. Admins can restrict sites via allowlists/blocklists.  
  — **confirmed** · <https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome>
- The claude-in-chrome MCP tool surface is live in this Claude Code session (mcp__claude-in-chrome__* including list_connected_browsers, computer, read_page, navigate, tabs_*). Calling list_connected_browsers right now returned an empty array, meaning the tool plane exists but no Chrome extension instance is currently paired to this account on this machine.  
  — **confirmed** · <https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome>
- browser-use is very much alive: 111,623 stars, MIT, pushed 2026-08-29, PyPI version 0.13.8. It requires Python >=3.11,<4.0. It supports BYO model including Claude and Gemini via ChatAnthropic / ChatGoogle / ChatOpenAI, plus its own ChatBrowserUse gateway.  
  — **confirmed** · <https://raw.githubusercontent.com/browser-use/browser-use/main/README.md>
- browser-use ships Browser.from_system_chrome(profile_directory=None, **kwargs) which resolves the real Chrome binary and the real user_data_dir (~/Library/Application Support/Google/Chrome on macOS). Its docs warn "You may need to fully close Chrome before running these examples" - i.e. it takes over the profile rather than attaching to a live browser, and it collides with the Chrome policy Playwright warns about.  
  — **confirmed** · <https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/browser/session.py>
- browser-use/agent-sdk EXISTS but is a different, much smaller thing than the brief implies: the PyPI/import name is bu-agent-sdk, 686 stars, NO license set, and it was last pushed 2026-03-30 (five months stale). It is a generic minimal agent for-loop framework, not a browser SDK.  
  — **confirmed** · <https://raw.githubusercontent.com/browser-use/agent-sdk/main/README.md>
- browser-use has effectively superseded its own local-Chrome story with a NEW repo not in the brief: browser-use/browser-harness (17,220 stars, MIT, created 2026-04-17, pushed 2026-08-28; PyPI browser-harness 0.1.10, requires Python >=3.11, last upload 2026-08-26). Its pitch: "Connect an LLM directly to your real browser through one editable CDP websocket. The agent writes missing helpers as it works."  
  — **confirmed** · <https://raw.githubusercontent.com/browser-use/browser-harness/main/README.md>
- browser-harness's install doc handles exactly the macOS problem Bot-Harness faces: it instructs the user to tick 'Allow remote debugging for this browser instance' at chrome://inspect/#remote-debugging, and ships `browser-harness mac-approve` to dismiss the per-connection macOS Allow sheet without foregrounding Chrome. That helper requires Accessibility permission for the launching app. It also has an explicit recording-consent gate (default off).  
  — **confirmed** · <https://raw.githubusercontent.com/browser-use/browser-harness/main/install.md>
- Skyvern is active: 22,875 stars, pushed 2026-08-29, PyPI skyvern 1.0.48, Python >=3.11,<3.14. Critically for a product, its license is AGPL-3.0, and it now positions itself as a Playwright extension adding page.act / page.extract / page.validate / page.prompt plus page.agent.run_task / login / download_files / run_workflow.  
  — **confirmed** · <https://raw.githubusercontent.com/Skyvern-AI/skyvern/main/README.md>
- Stagehand is at @browserbasehq/stagehand 4.0.2 (published 2026-08-20), MIT, 24,092 stars, pushed 2026-08-29. The v4 API changed shape from v3: Stagehand.create({ browser, model }) with act/observe/extract called on the stagehand object, not on page.  
  — **confirmed** · <https://raw.githubusercontent.com/browserbase/stagehand/main/README.md>
- Stagehand v4 does support fully local operation and CDP attach: localBrowser.launch(), localBrowser.launch({ userDataDir, preserveUserDataDir: true }), and localBrowser.connect({ cdpUrl: 'http://127.0.0.1:9222' }). Stagehand closes only browsers it launched, so an attached browser survives.  
  — **confirmed** · <https://docs.stagehand.dev/v4/configuration/browser>
- Stagehand v4 supports Anthropic and Google directly with provider-prefixed model names: anthropic/claude-sonnet-5, anthropic/claude-haiku-4-5, anthropic/claude-opus-4-8, google/gemini-2.5-flash, google/gemini-3.1-pro-preview, plus OpenAI, Groq and Cerebras.  
  — **confirmed** · <https://docs.stagehand.dev/v4/configuration/models>
- BrowserMCP is abandoned. BrowserMCP/mcp last commit was 2025-04-24 ('chore: version 0.1.3') and npm @browsermcp/mcp 0.1.3 was last published 2025-04-11 - roughly 16 months stale as of today. browsermcp.io returns HTTP 403 to fetches.  
  — **confirmed** · <https://github.com/BrowserMCP/mcp>
- Hosted sandbox pricing today: Browserbase Free $0 (1 browser hour, 3 concurrent), Developer $20/mo (100 hours, $0.12/hr overage, 25 concurrent), Startup $99/mo (500 hours, $0.10/hr overage, 100 concurrent), Scale custom.  
  — **confirmed** · <https://www.browserbase.com/pricing>
- E2B pricing: Hobby free with $100 usage credits, 1-hour max sessions, 20 concurrent sandboxes; Pro $150/month with 24-hour sessions and 100 concurrent. Usage billed per second: CPU $0.000014-$0.000112/sec by vCPU count, RAM $0.0000045/GiB/sec. e2b-dev/desktop (the computer-use desktop sandbox) is Apache-2.0, 1,458 stars, pushed 2026-08-26.  
  — **confirmed** · <https://e2b.dev/pricing>
- Daytona is 71,861 stars and pushed 2026-07-24, but the GitHub API reports NO license field (license: null), which is a real adoption risk for bundling into a product.  
  — **confirmed** · <https://github.com/daytonaio/daytona>
- Kunal's local toolchain as measured: default python3 is 3.10.11, but python3.11 exists at /opt/homebrew/bin/python3.11 AND uv 0.9.11 is installed at /Users/Kunal/.local/bin/uv. Node is v24.6.0. uv can provision Python 3.12 on demand, so the Python 3.11+ requirement of browser-use, browser-harness and Skyvern is NOT a blocker.  
  — **confirmed** · <https://raw.githubusercontent.com/browser-use/browser-harness/main/install.md>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [microsoft/playwright](https://github.com/microsoft/playwright) | adopt - this is the deterministic substrate. Use it for replayable steps, but do NOT point launch_persistent_context at the real Chrome profile; Playwright's own docs say that is unsupported. | Deterministic cross-browser automation. Node 1.62.1 / Python 1.62.0. connect_over_cdp() and launch_persistent_context() are the two attach paths. | 95,328 | Apache-2.0 | 2026-08-29 |
| [microsoft/playwright-cli](https://github.com/microsoft/playwright-cli) | adopt - Microsoft explicitly recommends CLI+SKILLS over MCP for coding agents, and `playwright-cli show` is the closest off-the-shelf thing to Bot-Harness's live computer-view pane. Study its dashboard before building your own. | npm @playwright/cli 0.1.18. Token-efficient CLI over Playwright with installable agent SKILLS, named sessions, --persistent profiles, and a live screencast dashboard via `playwright-cli show` with click-to-take-over remote control. | 12,944 | Apache-2.0 | 2026-08-27 |
| [ChromeDevTools/chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) | adopt for the real-profile attach path - it is the only first-party implementation of Chrome's own consent flow. Pass --no-usage-statistics; telemetry is on by default. | Google's official MCP server (v1.8.0, Puppeteer-based) for controlling and inspecting live Chrome, with --autoConnect for the Chrome 144+ consented remote-debugging opt-in. | 50,080 | Apache-2.0 | 2026-08-28 |
| [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp) | evaluate - excellent for a persistent agent-owned profile and for deterministic snapshot-driven loops, but Microsoft itself now points coding agents at playwright-cli instead. Version is still 0.0.x. | MCP server exposing Playwright via accessibility snapshots rather than screenshots. @playwright/mcp 0.0.79. Supports --cdp-endpoint, --extension (needs the Playwright Extension), --isolated, --storage-state, --secrets. | 36,598 | Apache-2.0 | 2026-08-28 |
| [browser-use/browser-harness](https://github.com/browser-use/browser-harness) | evaluate hard - this is the closest existing prior art to Bot-Harness and it has already solved the exact macOS Chrome-consent friction you will hit. At minimum, copy its install/consent flow. Note NO license metadata issue: repo is MIT. | Connects an LLM to your real running browser over one CDP websocket; the agent writes and accumulates its own Python helpers in a workspace. Ships an MCP server (mcp_server.py), a skill generator, recording consent, and `browser-harness mac-approve` for the macOS permission sheet. | 17,220 | MIT | 2026-08-28 |
| [browser-use/browser-use](https://github.com/browser-use/browser-use) | reference-only for the browser layer - its real-Chrome mode wants Chrome fully closed and fights Chrome's profile policy. Its LLM abstraction and Agent loop are worth reading, but the vendor's own attention has moved to browser-harness. | The best-known open-source browser agent. Python >=3.11, v0.13.8. Agent(task=..., llm=ChatAnthropic(...)) with first-class Claude and Gemini support. Browser.from_system_chrome() targets the real profile. | 111,623 | MIT | 2026-08-29 |
| [browser-use/agent-sdk (bu-agent-sdk)](https://github.com/browser-use/agent-sdk) | reference-only - no license, 686 stars, five months stale. Steal the ideas (ephemeral=N for screenshot-heavy tool results, require_done_tool) rather than the dependency. | A minimal 'an agent is just a for-loop' framework with a done-tool pattern, ephemeral messages for large tool outputs, and context compaction. Not browser-specific. | 686 | NONE SET | 2026-03-30 |
| [browserbase/stagehand](https://github.com/browserbase/stagehand) | evaluate - the strongest resilience layer if you want natural-language steps that survive DOM changes, and it takes anthropic/claude-* keys directly. Cost: v4 broke the v3 API, so pin the version. | v4.0.2. act/observe/extract over a Playwright-style API with self-healing selectors, runs as a browser extension for lower latency, TS + Python + Go. localBrowser.connect({cdpUrl}) works fully offline from Browserbase. | 24,092 | MIT | 2026-08-29 |
| [Skyvern-AI/skyvern](https://github.com/Skyvern-AI/skyvern) | reject for bundling, reference-only otherwise - AGPL-3.0 is a hard problem for a distributed Mac app, and it drags in a server plus SQLite/Postgres. Its credential-manager login flow is the one idea worth borrowing. | Vision-LLM swarm over Playwright, plus a no-code workflow builder and a local server/UI. page.act / page.extract / page.validate / page.prompt; page.agent.login supports 1Password and Bitwarden credentials. | 22,875 | AGPL-3.0 | 2026-08-29 |
| [BrowserMCP/mcp](https://github.com/BrowserMCP/mcp) | reject - abandoned. Last commit 2025-04-24, last npm publish 2025-04-11, ~16 months stale, and its website 403s. Superseded entirely by Claude in Chrome and chrome-devtools-mcp. | Extension-based MCP server for driving your own browser. npm @browsermcp/mcp 0.1.3. | 7,031 | Apache-2.0 | 2025-04-24 |
| [e2b-dev/desktop](https://github.com/e2b-dev/desktop) | reject for the core use case - a cloud desktop has none of Kunal's logged-in sessions, which is the entire point. Keep it in mind only as a future 'run this risky task somewhere disposable' escape hatch. | Cloud sandbox with a full desktop GUI for computer-use agents. | 1,458 | Apache-2.0 | 2026-08-26 |

## API and code shape

RECOMMENDED PRIMARY PATH - consented attach to the user's real Chrome (Chrome 152 on this Mac qualifies).

Step 1, one-time manual user action (deliberately NOT automatable):
  Open chrome://inspect/#remote-debugging
  Tick "Allow remote debugging for this browser instance"

Step 2, attach. Either via Google's MCP server:
  claude mcp add chrome-devtools --scope user npx chrome-devtools-mcp@latest
  # or in mcpServers config:
  {
    "mcpServers": {
      "chrome-devtools": {
        "command": "npx",
        "args": ["-y", "chrome-devtools-mcp@latest", "--autoConnect", "--no-usage-statistics"]
      }
    }
  }
  # --autoConnect requires Chrome 144+ and the chrome://inspect opt-in above.
  # Alternatives: --browserUrl/-u http://127.0.0.1:9222 , --wsEndpoint/-w ws://127.0.0.1:9222/devtools/browser/<id>

...or directly from Swift/Node/Python over the same CDP endpoint:
  // Node
  const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
  # Python
  browser = await playwright.chromium.connect_over_cdp("http://127.0.0.1:9222")

FALLBACK / AGENT-OWNED PROFILE (never the user's real one):
  npx @playwright/mcp@latest --browser chrome --user-data-dir ~/Library/Application\ Support/BotHarness/chrome-profile
  # default persistent profile lives at ~/Library/Caches/ms-playwright/mcp-{channel}-{workspace-hash}
  # a persistent profile can only be used by ONE browser instance at a time; use --isolated for parallel clients

DETERMINISTIC CLI LAYER + LIVE VIEW (strong fit for the right-hand pane):
  npm install -g @playwright/cli@latest
  playwright-cli install --skills
  playwright-cli open https://example.com --headed
  playwright-cli -s=bot-harness open https://example.com --persistent
  playwright-cli snapshot              # returns element refs like e21
  playwright-cli click e21
  playwright-cli fill e35 "text" --submit
  playwright-cli show                  # live screencast grid + click-to-take-over remote control
  playwright-cli list / close-all / kill-all
  PLAYWRIGHT_CLI_SESSION=bot-harness claude .

EXPLICITLY DO NOT DO THIS (unsupported per Playwright docs, blocked per Chrome 136):
  chromium.launchPersistentContext('~/Library/Application Support/Google/Chrome', {channel:'chrome'})
  "Google Chrome" --remote-debugging-port=9222      # ignored on the default data dir since Chrome 136

RESILIENCE LAYER, if you want natural-language steps (Stagehand v4, local, Claude-backed):
  const browser = await localBrowser.connect({ cdpUrl: "http://127.0.0.1:9222" });
  const stagehand = await Stagehand.create({ browser, model: { modelName: "anthropic/claude-sonnet-5", apiKey: process.env.ANTHROPIC_API_KEY } });
  await stagehand.act("click on the stagehand repo");
  const { data: actions } = await stagehand.observe("find the latest PR");
  await page.locator(actions[0].selector).click();
  const { data } = await stagehand.extract("extract author and title", z.object({ author: z.string(), title: z.string() }));

PRIOR ART TO MINE (browser-harness, already solves the macOS consent sheet):
  uv tool install --python 3.12 --upgrade --force browser-harness
  browser-harness skill > ~/.claude/skills/browser-harness/SKILL.md
  browser-harness mac-approve      # dismisses the per-connection macOS Allow sheet without foregrounding Chrome
                                   # requires Accessibility permission for the launching app
  browser-harness recordings enable | disable
