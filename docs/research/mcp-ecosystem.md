# Model Context Protocol (MCP) as the extension layer for a Mac-native computer-use agent host, verified as of 2026-08-29

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

MCP shipped a hard breaking change on 2026-07-28: the protocol is now stateless — no `initialize` handshake, no `Mcp-Session-Id`, no server-initiated requests. Sampling, Roots, and Logging are all formally deprecated, and server-to-client asks (elicitation, sampling, roots) now happen through a new retry-based pattern called Multi Round-Trip Requests (MRTR). The official Swift SDK exists and is real (`modelcontextprotocol/swift-sdk`, 1,478 stars) but is stranded on the previous `2025-11-25` spec: its last release was 0.12.1 on 2026-05-07 and it has ten open unimplemented "Implement SEP-xxxx" issues covering exactly the 2026-07-28 changes. That is the single most important fact for Bot-Harness: if you write the host in Swift against the official SDK today, you are building on a superseded protocol version with no committed migration date. The TypeScript SDK v2 (`@modelcontextprotocol/client` 2.0.0) and Python SDK 2.1.1 are current and spec-complete. The practical recommendation is a Swift/SwiftUI shell over a Node or Python MCP client sidecar, which also gets you MCP Apps rendering for the "live computer view" panel.

## Recommendation

Do not build the MCP wire protocol in Swift. Build the Bot-Harness shell in Swift 6 / SwiftUI for the window, the three-pane layout, the TCC permission prompts, and the audit log, and run the actual MCP client as a Node 24 sidecar using @modelcontextprotocol/client 2.0.0, talking to the Swift app over a local Unix domain socket with a small internal JSON protocol you control. Rationale: the official Swift SDK is a full spec revision behind with no committed migration date, and 2026-07-28 is not a patch — it deletes the handshake, deletes sessions, and replaces every server-initiated request with MRTR. Porting that yourself in Swift is weeks of work the TypeScript team has already done and is validating against the conformance suite.

Three consequences worth designing around now.

First, the host is dramatically simpler than the pre-July architecture. There is no session to keep alive, no ping, no initialize. Each MCP call is a self-contained HTTP POST or stdio message carrying its own _meta. Your sidecar can be close to stateless, and a crashed server connection costs you one in-flight request rather than a session.

Second, do not implement Sampling, Roots, or Logging. All three are deprecated. Sampling in particular is the one a host would instinctively build, since it is the "server asks the model a question" path — the spec now tells you to integrate directly with the LLM provider API instead. Pass working directories as ordinary tool parameters rather than Roots. Send server stderr straight to your audit log rather than implementing the logging protocol. Do implement Elicitation, because that is how servers ask the user for input, and under MRTR it is a clean pattern: you receive an InputRequiredResult, render a form in the center pane from the JSON Schema, and retry the original call with a new request id.

Third, layer the permission model on the spec's own MUSTs rather than inventing one. Before first-running any local server, show the exact unelided command with its arguments, flag sudo, rm -rf, and access to the home directory or SSH keys, and require explicit approval — that is a spec requirement, not a nicety. Then add the two mitigations the spec does not cover: pin a hash of every tool's name, description and input schema at approval time and re-prompt when it changes (this defeats rug pulls), and render tool descriptions as inert text that never reaches the model without being marked untrusted (this blunts tool poisoning). Run snyk/agent-scan over each server at install. For the OAuth path, only allow https:// and loopback http:// authorization URLs, never open a URL through a shell, and use CIMD rather than Dynamic Client Registration, which is now deprecated.

For the right-hand live view, use the ext-apps AppBridge inside a WKWebView rather than writing your own iframe sandbox, and seed the default server set with the seven official reference servers plus github/github-mcp-server and openclaw/Peekaboo. Skip the Apple-native servers entirely for v1: the well-known one is archived and every live alternative is under fifty stars.

## Risks

- The official Swift SDK may never catch up. All ten 2026-07-28 SEP implementation issues have been open since early June with no linked commits and no release since 2026-05-07. Swift is not a Tier 1 SDK, so it has no release-alongside-spec commitment. Planning any Swift-native protocol layer around a future 0.13.0 is planning around a date nobody has published.
- 2026-07-28 is barely a month old. The TypeScript SDK v2 is capping new contributors to one PR each 'while v2 settles', an explicit admission that v2 is still stabilising. Expect breaking patch-level churn in @modelcontextprotocol/client through autumn 2026.
- Most third-party MCP servers in the wild still speak 2025-11-25 or earlier. Your host must keep a compatibility path — server/discover is explicitly designed as a backward-compat probe on stdio — or most of the ecosystem will not connect. Budget for running both protocol generations side by side; this is the largest hidden cost in the project.
- Removing SSE resumability means any long-running tool call over Streamable HTTP is lost outright if the stream breaks, and the client must re-issue with a new request id. For a computer-use agent whose actions have side effects, blind retry is dangerous: a re-issued 'click Purchase' is a second purchase. You need idempotency keys or an explicit no-auto-retry class of tool.
- Tool poisoning and rug pulls are absent from the official security page, so an implementer following only the spec will not defend against them. The spec says tool annotations 'should be considered untrusted' but offers no concrete mechanism. This gap is yours to fill.
- MCPB has not been touched since 2026-05-26, predating the current spec. If you adopt its manifest format for your permission model, you are adopting a schema not revised for the stateless protocol.
- The Swift SDK, the servers repo, the registry and ext-apps all report NOASSERTION for license via the GitHub API, meaning no SPDX-detectable license file. Confirm actual license terms manually before bundling any of them into a distributed Mac app.
- The Apple-native server niche has effectively collapsed. supermemoryai/apple-mcp is archived and twelve months stale; live replacements top out around forty stars and none are audited. Anything touching Messages, Notes or Calendar on the user's machine is high-blast-radius code from an unvetted author.
- Peekaboo moved from steipete/peekaboo to openclaw/Peekaboo, and mcp-scan is now snyk/agent-scan. Any pinned URL, docs reference, or install script written from pre-2026 knowledge will 404 or silently follow a redirect to a repo under different ownership than expected.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- WRONG IN BRIEF — 'sampling, roots, resources, prompts, tools: which are stable'. The premise that these are all candidate-stable is outdated. As of 2026-07-28, Roots, Sampling AND Logging are formally DEPRECATED (SEP-2577) with a minimum twelve-month removal window. Only Tools, Resources, Prompts and Elicitation remain Active. A host built today should implement none of the three deprecated features.
- WRONG IN BRIEF — 'SSE deprecated?'. The answer is more severe than deprecation. The legacy HTTP+SSE transport is deprecated, AND separately SSE resumability with the Last-Event-ID header was fully REMOVED from Streamable HTTP. Additionally the HTTP GET endpoint is gone entirely, replaced by subscriptions/listen.
- WRONG IN BRIEF — the brief's implicit model of MCP as a stateful, bidirectional, session-based protocol with an initialize handshake is now false. Sessions, the Mcp-Session-Id header, the initialize/notifications/initialized handshake, ping, and logging/setLevel were all removed on 2026-07-28.
- WRONG IN BRIEF — 'MCP Apps / MCP-UI: does an official UI extension exist'. The framing implies these might be rivals. They are not: MCP Apps is the official extension (io.modelcontextprotocol/ui) and MCP-UI (@mcp-ui/client) is the community React renderer the official docs recommend for client builders.
- REPO RENAMED — steipete/peekaboo is now openclaw/Peekaboo. The old path 301-redirects on the GitHub API.
- REPO RENAMED AND ARCHIVED — Dhravya/apple-mcp is now supermemoryai/apple-mcp and has been ARCHIVED since 2025-08-11. Do not treat it as a live option.
- REPO RENAMED — invariantlabs-ai/mcp-scan is now snyk/agent-scan (Invariant Labs absorbed into Snyk). The mcp-injection-experiments repo under invariantlabs-ai still exists as the tool-poisoning PoC.
- PACKAGE RENAMED — DXT / Desktop Extensions is now MCPB / MCP Bundles. The dxt CLI is mcpb, .dxt files are .mcpb, and @anthropic-ai/dxt moved to @anthropic-ai/mcpb.
- COULD NOT VERIFY — I could not fetch a live reference HOST implementation to copy. modelcontextprotocol/example-remote-client exists but has only 27 stars, no license, no description, and has not been pushed since 2025-12-15, predating the current spec by seven months. The ext-apps basic-host example is referenced in the docs and is the best available candidate, but I did not fetch its source. Treat 'reference host to copy' as an open question.
- COULD NOT VERIFY — I did not fetch the full text of the 2026-07-28 authorization specification, so the OAuth 2.1 and resource-indicator (RFC 8707) details are reported only as they appear in the changelog and security-best-practices pages. Read /specification/2026-07-28/basic/authorization directly before implementing the auth flow.
- UNVERIFIED — the three community Swift alternatives surfaced by search (Compiler-Inc/SwiftMCP, Cocoanetics/SwiftMCP, and a SwiftMCP bridging Apple Foundation Models to MCP servers) came from search snippets only. I did not fetch their repos or confirm star counts, licenses, maintenance status, or which spec version they target. Do not select one on the strength of this report.
- UNVERIFIED — the Python SDK's release tags are non-monotonic in the GitHub API (v2.1.1 dated 2026-08-25, v2.0.1 dated 2026-08-26), while PyPI reports 2.1.1 as current. I did not resolve which is genuinely newest; confirm before pinning a version.
- UNVERIFIED — I did not confirm whether @modelcontextprotocol/client 2.0.0 has actually implemented the MRTR client requirements, or merely ships the types. The SDK claims 2026-07-28 conformance in its README but I did not read its source or run the conformance suite against it. This is the single assumption most worth testing on day one, because the whole recommendation rests on it.

## Verified facts

- The current MCP specification version is 2026-07-28, authoritative schema at schema/2026-07-28/schema.ts. It supersedes 2025-11-25.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/latest>
- MCP is now a STATELESS protocol. SEP-2575 removed the initialize/notifications/initialized handshake entirely. Every request must instead carry io.modelcontextprotocol/protocolVersion and io.modelcontextprotocol/clientCapabilities in _meta. Version mismatches return UnsupportedProtocolVersionError.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- SEP-2567 removed protocol-level sessions and the Mcp-Session-Id header from Streamable HTTP. tools/list, resources/list and prompts/list no longer vary per-connection. Servers needing cross-call state mint explicit handles passed as ordinary tool arguments.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- A new required RPC, server/discover, replaces initialize for capability/version discovery: 'servers MUST implement this RPC to advertise their supported protocol versions, capabilities, and identity.' Clients MAY call it before any other request.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- Roots, Sampling and Logging are DEPRECATED as of 2026-07-28 (SEP-2577). They remain functional for a minimum 12-month deprecation window but 'new implementations should not add support for them.' Suggested migrations: pass directories via tool parameters instead of Roots; integrate directly with LLM provider APIs instead of Sampling; log to stderr or OpenTelemetry instead of Logging.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- Server-initiated requests are GONE. SEP-2322 introduced Multi Round-Trip Requests (MRTR): 'Servers MUST send server-to-client requests (such as roots/list, sampling/createMessage, or elicitation/create) using the MRTR pattern. The previous pattern of server-initiated requests is no longer supported. This is a breaking change.' Servers return an InputRequiredResult with resultType 'input_required'; the client gathers input and RETRIES the original request with a NEW JSON-RPC id.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr>
- Only three client requests may receive an InputRequiredResult: prompts/get, resources/read, and tools/call. Servers MUST NOT send InputRequiredResult on any other request.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr>
- Transports as of 2026-07-28: stdio and Streamable HTTP are current. The legacy HTTP+SSE transport (deprecated since 2025-03-26) is now formally reclassified as Deprecated under the lifecycle policy (SEP-2596). Separately, SSE stream resumability and message redelivery (Last-Event-ID header and SSE event IDs) were REMOVED from Streamable HTTP — a broken stream loses the in-flight request and the client MUST re-issue it as a new request with a new request ID.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- The HTTP GET endpoint and resources/subscribe / resources/unsubscribe are replaced by subscriptions/listen: a single long-lived POST-response stream. Clients opt into specific types (toolsListChanged, promptsListChanged, resourcesListChanged, resourceSubscriptions) and the server tags notifications with io.modelcontextprotocol/subscriptionId.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- ping, logging/setLevel and notifications/roots/list_changed were REMOVED. Log level is now per-request via io.modelcontextprotocol/logLevel in _meta, and servers MUST NOT emit notifications/message for requests that did not include this field.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- Auth: OAuth 2.0 Dynamic Client Registration (RFC 7591) is now DEPRECATED in favor of Client ID Metadata Documents (CIMD). Authorization servers SHOULD include the iss parameter per RFC 9207 and MCP clients MUST validate a present iss against the recorded issuer before redeeming the authorization code. Clients MUST key persisted credentials by issuer identifier and MUST re-register when the authorization server changes.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- An official Swift SDK exists at github.com/modelcontextprotocol/swift-sdk — 1,478 stars, created 2025-02-05, module name 'MCP', package name 'mcp-swift-sdk'. Supports macOS 13+, iOS 16+, requires Swift 6.0+. It implements BOTH client and server.  
  — **confirmed** · <https://github.com/modelcontextprotocol/swift-sdk>
- The Swift SDK is STALE relative to the current spec. Its README states it implements 'the 2025-11-25 (latest) version of the MCP specification'. Last release 0.12.1 on 2026-05-07; last commit 2026-04-29. It has open, unstarted tracking issues for every 2026-07-28 change: #245 SEP-2575 Make MCP Stateless, #244 SEP-2567 Sessionless MCP, #238 SEP-2322 Multi Round-Trip Requests, #246 SEP-2577 Deprecate Roots/Sampling/Logging, #247 SEP-2663 Tasks Extension — all still open as of 2026-08-29.  
  — **confirmed** · <https://raw.githubusercontent.com/modelcontextprotocol/swift-sdk/main/README.md>
- Swift is NOT a Tier 1 SDK. The 2026-07-28 release announcement names the four Tier 1 SDKs as TypeScript, Python, Go and C#, with Rust in beta. Swift is not listed.  
  — **confirmed** · <https://blog.modelcontextprotocol.io/posts/2026-07-28/>
- TypeScript SDK v2 is the stable line and implements 2026-07-28. It SPLIT into two packages: @modelcontextprotocol/client 2.0.0 and @modelcontextprotocol/server 2.0.0, both published 2026-07-27. The old single package @modelcontextprotocol/sdk is now v1 legacy at 1.30.0 and receives only bug/security fixes for at least 6 months after v2's release.  
  — **confirmed** · <https://raw.githubusercontent.com/modelcontextprotocol/typescript-sdk/main/README.md>
- Python SDK is at version 2.1.1 (PyPI package name 'mcp', MIT, requires Python >=3.10), released 2026-08-25. Note the project's own release tags are non-monotonic: v2.1.1 was tagged 2026-08-25 and v2.0.1 on 2026-08-26.  
  — **confirmed** · <https://pypi.org/pypi/mcp/json>
- An official MCP registry exists and is LIVE at https://registry.modelcontextprotocol.io. /v0/health returns {"status":"ok"}. The list endpoint is GET /v0/servers with query params: cursor, limit, updated_since (RFC3339), search (substring match on name), version ('latest' or exact), include_deleted. There are also /v0/servers/{serverName}/versions and /v0/publish. A newer /v0.1/ path family is served in parallel.  
  — **confirmed** · <https://registry.modelcontextprotocol.io/openapi.yaml>
- MCP Apps is the OFFICIAL UI extension, identifier io.modelcontextprotocol/ui, repo modelcontextprotocol/ext-apps (2,771 stars). A tool declares _meta.ui.resourceUri pointing at a ui:// resource; the host fetches the HTML and renders it in a sandboxed iframe; app and host talk over postMessage JSON-RPC using ui/-prefixed methods (e.g. ui/initialize) plus shared methods like tools/call. _meta.ui also carries csp and permissions.  
  — **confirmed** · <https://modelcontextprotocol.io/extensions/apps/overview>
- MCP-UI is NOT a competitor to MCP Apps — it is the recommended community client-side renderer. The official docs tell client builders to either use @mcp-ui/client (React components) or build on the ext-apps AppBridge module, with a basic-host example provided. MCP-UI-Org/mcp-ui has 5,114 stars, Apache-2.0, last pushed 2026-07-08.  
  — **confirmed** · <https://modelcontextprotocol.io/extensions/apps/overview>
- MCP Apps host support as of Aug 2026 includes Claude web, Claude Desktop, VS Code GitHub Copilot, Microsoft 365 Copilot, Goose, Postman, MCPJam, ChatGPT, Cursor, Archestra.AI and PostHog Code. Only Archestra.AI additionally supports Enterprise-Managed Authorization. No client in the matrix supports the OAuth Client Credentials extension.  
  — **confirmed** · <https://modelcontextprotocol.io/extensions/client-matrix>
- Host responsibilities are specified explicitly: the host 'Creates and manages multiple client instances; Controls client connection permissions and lifecycle; Enforces security policies and consent requirements; Handles user authorization decisions; Coordinates AI/LLM integration and sampling; Manages context aggregation across clients.' Each client has a strict 1:1 relationship with one server, and servers must not be able to read the whole conversation or see into other servers.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/architecture>
- For one-click local server install the spec imposes hard requirements on the client: it MUST show the exact command that will be executed without truncation including arguments, MUST clearly identify it as potentially dangerous, MUST require explicit approval, and MUST allow cancellation. It SHOULD additionally highlight dangerous patterns (sudo, rm -rf), warn on access to home/SSH/system directories, and sandbox servers with minimal default privileges.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/basic/security_best_practices>
- The spec's named attack classes are: Confused Deputy, Token Passthrough, SSRF, State Handle Hijacking (new, replaces Session Hijacking now that sessions are gone), Local MCP Server Compromise, OAuth Authorization URL Validation (javascript:/data:/file: injection), stdio Transport Security in Proxy Scenarios, Mix-Up Attacks, Localhost Redirect URI Impersonation, CIMD Trust Policies, and Scope Minimization.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/basic/security_best_practices>
- Hard client-side security MUSTs relevant to a Mac host: clients MUST only allow http:// and https:// schemes for authorization URLs (http only for loopback in dev) and MUST reject javascript:, data:, file:, vbscript:; clients MUST NOT use shell commands (sh, cmd.exe, PowerShell) to open URLs; MCP servers MUST NOT accept tokens not explicitly issued for them; servers MUST NOT treat possession of a state handle as authentication.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/basic/security_best_practices>
- Tool poisoning and rug pulls are real, documented attack classes but are NOT in the official spec's security page. They come from Invariant Labs' April 2025 disclosure: adversarial instructions hidden in tool descriptions, parameter schemas and metadata that the agent reads but the user does not; rug pulls exploit the gap between one-time approval and ongoing verification by mutating a tool after approval. Reproduction code is at invariantlabs-ai/mcp-injection-experiments.  
  — **confirmed** · <https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks>
- MCPB (MCP Bundles) is the one-click local-server install format used by Claude for macOS: .mcpb zip archives containing a local MCP server plus manifest.json. It was RENAMED from DXT/Desktop Extensions; the dxt CLI is now mcpb and @anthropic-ai/dxt moved to @anthropic-ai/mcpb. Repo last pushed 2026-05-26.  
  — **confirmed** · <https://raw.githubusercontent.com/modelcontextprotocol/mcpb/main/README.md>
- The official reference server set has shrunk to seven: everything, fetch, filesystem, git, memory, sequentialthinking, time. All other former reference servers live in modelcontextprotocol/servers-archived (archived since 2025-05-28). The main servers repo has 89,948 stars and was pushed 2026-08-28.  
  — **confirmed** · <https://github.com/modelcontextprotocol/servers>
- Results now carry a required resultType field ('complete' or 'input_required'), and list/read results carry required ttlMs and cacheScope ('public'|'private') fields via a new CacheableResult interface. Servers SHOULD return tools from tools/list in deterministic order to improve LLM prompt cache hit rates.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- Streamable HTTP POST requests now require standard MCP request headers Mcp-Method and Mcp-Name so gateways can route and authorize without parsing the JSON body, plus x-mcp-header support for custom headers from tool parameters (SEP-2243).  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>
- Tasks moved out of the core protocol into an official extension io.modelcontextprotocol/tasks. The redesign replaced blocking tasks/result with polling via tasks/get, added tasks/update for client-to-server input, and removed tasks/list.  
  — **confirmed** · <https://modelcontextprotocol.io/specification/2026-07-28/changelog>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | evaluate (do not adopt as the protocol layer yet) — it is a full spec version behind, unreleased since 2026-05-07, with all ten 2026-07-28 SEP issues still open. Fine to read for Swift ergonomics, wrong to build the host's wire layer on. | Official Swift SDK, client and server. SPM package 'mcp-swift-sdk', library product 'MCP'. macOS 13+, Swift 6.0+. Implements the 2025-11-25 spec only. | 1478 | NOASSERTION (no SPDX-detected license file — verify before shipping) | Last release 0.12.1 on 2026-05-07; last commit 2026-04-29; 100 open issues |
| [modelcontextprotocol/typescript-sdk](https://github.com/modelcontextprotocol/typescript-sdk) | adopt — the only client library both current with the spec and trivially embeddable as a Node 24 sidecar next to a Swift UI. Bot-Harness should run its MCP client here. | Official TypeScript SDK. v2 split into @modelcontextprotocol/client and @modelcontextprotocol/server, both 2.0.0, implementing 2026-07-28. Runs on Node, Bun, Deno. Tool schemas use Standard Schema (Zod v4, Valibot, ArkType). | 13270 | MIT | Pushed 2026-08-29; v2.0.0 released 2026-07-27 |
| [modelcontextprotocol/python-sdk](https://github.com/modelcontextprotocol/python-sdk) | evaluate — viable sidecar alternative if the rest of the harness is Python. Note Kunal is on Python 3.10, exactly the minimum supported. | Official Python SDK, PyPI package 'mcp' at 2.1.1, requires Python >=3.10. | 24152 | MIT | Pushed 2026-08-28; v2.1.1 released 2026-08-25 |
| [modelcontextprotocol/ext-apps](https://github.com/modelcontextprotocol/ext-apps) | adopt — AppBridge plus the basic-host example is the reference for the right-hand 'live computer view' panel. Wrapping it in a WKWebView is the shortest path to server-rendered UI in a Mac app. | Official MCP Apps extension (io.modelcontextprotocol/ui): spec, SDK, and the AppBridge host module that handles sandboxed iframe rendering, postMessage passing, tool-call proxying and security policy enforcement. Includes a basic-host example. | 2771 | NOASSERTION | Pushed 2026-08-12; npm @modelcontextprotocol/ext-apps 1.7.5 published 2026-07-23 |
| [MCP-UI-Org/mcp-ui](https://github.com/MCP-UI-Org/mcp-ui) | reference-only — a worked implementation of the host side of the postMessage dialect, but adds a React dependency a Swift-shelled app does not need if you use AppBridge directly. | Community React renderer for MCP Apps views (@mcp-ui/client). Officially recommended by the MCP docs as one of the two supported ways to add MCP Apps support to a client. | 5114 | Apache-2.0 | Pushed 2026-07-08 (roughly 7 weeks stale vs ext-apps) |
| [modelcontextprotocol/registry](https://github.com/modelcontextprotocol/registry) | adopt — use GET /v0/servers?search=&version=latest as the 'add a server' browser inside Bot-Harness. No auth needed for reads. | The official community registry service. Live at https://registry.modelcontextprotocol.io with a documented OpenAPI at /openapi.yaml. | 7199 | NOASSERTION | Pushed 2026-08-26; API responding 200 on 2026-08-29 |
| [modelcontextprotocol/mcpb](https://github.com/modelcontextprotocol/mcpb) | evaluate — the manifest schema is the best existing model for declaring a local server's required config and permissions, which maps directly onto Bot-Harness's permission model. Caveat: unchanged since 2026-05-26. | MCP Bundles (.mcpb): zip archive + manifest.json for one-click local MCP server install. This is the exact code Claude for macOS uses to load and verify bundles. CLI: npm install -g @anthropic-ai/mcpb. | 2090 | NOASSERTION | Pushed 2026-05-26 (three months stale, predates current spec) |
| [modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers) | adopt — ship filesystem, git, fetch, memory and time as the built-in default set; use 'everything' as your integration-test target. | Official reference servers. Now only seven: everything, fetch, filesystem, git, memory, sequentialthinking, time. 'everything' is the conformance/test server. | 89948 | NOASSERTION (mixed per-server) | Pushed 2026-08-28 |
| [openclaw/Peekaboo](https://github.com/openclaw/Peekaboo) | adopt — the closest existing thing to the 'live computer view' right panel and very actively maintained. NOTE: moved from steipete/peekaboo to openclaw/Peekaboo. | macOS CLI and optional MCP server for screen capture: screenshots of individual applications or the whole system, with optional visual question answering via local or remote models. | 5073 | MIT | Pushed 2026-08-29 (same day) |
| [steipete/macos-automator-mcp](https://github.com/steipete/macos-automator-mcp) | evaluate — extremely powerful and therefore the highest-risk server you could bundle. If included, it needs its own consent tier, since arbitrary AppleScript is arbitrary code execution. | MCP server that runs AppleScript and JXA (JavaScript for Automation) on macOS — the general-purpose escape hatch for driving native Mac apps. | 874 | MIT | Pushed 2026-08-28 |
| [github/github-mcp-server](https://github.com/github/github-mcp-server) | adopt — first-party, MIT, actively maintained; the safe default for the git/GitHub half of the toolset rather than a community fork. | GitHub's own official MCP server for repos, issues, PRs and the GitHub API. | 32592 | MIT | Pushed 2026-08-28 |
| [supermemoryai/apple-mcp (was Dhravya/apple-mcp)](https://github.com/supermemoryai/apple-mcp) | reject — the repo is ARCHIVED and moved from Dhravya/apple-mcp. Do not bundle it. Live successors exist but are all small and unvetted (MrGo2/icloud-mcp at 40 stars, GodModeAI2025/AppleMCP at 14, JonathanRReed/Apple-MCPs at 12). For Apple app access, writing your own thin server is currently safer than adopting any of these. | Collection of Apple-native MCP tools (Notes, Messages, Calendar, Contacts). | 3130 | MIT | ARCHIVED. Last pushed 2025-08-11 — over twelve months dead |
| [snyk/agent-scan (was invariantlabs-ai/mcp-scan)](https://github.com/snyk/agent-scan) | evaluate — run it in CI over every server Bot-Harness bundles, and consider invoking it at install time before a server is first trusted. Invariant Labs was absorbed into Snyk, hence the rename. | Security scanner for AI agents, MCP servers and agent skills. Static analysis of tool descriptions for injection patterns and cross-server shadowing. | 2972 | Apache-2.0 | Pushed 2026-08-28 |
| [modelcontextprotocol/conformance](https://github.com/modelcontextprotocol/conformance) | adopt — if you end up writing any protocol code yourself (likely, if you touch Swift), this is how you prove it correct against 2026-07-28. | Official conformance test suite for MCP implementations. | 110 | NOASSERTION | Pushed 2026-08-27 |

## API and code shape

EXACT SPEC-VERSION STRING: 2026-07-28 (previous: 2025-11-25)

--- Required _meta keys on EVERY request (there is no longer an initialize handshake) ---
io.modelcontextprotocol/protocolVersion     (required)
io.modelcontextprotocol/clientCapabilities  (required)
io.modelcontextprotocol/clientInfo          (SHOULD)
io.modelcontextprotocol/logLevel            (per-request; servers MUST NOT emit notifications/message without it)
Server identifies itself in each result's _meta as: io.modelcontextprotocol/serverInfo

Required Streamable HTTP POST headers: Mcp-Method, Mcp-Name
Custom headers from tool params: x-mcp-header
REMOVED headers: Mcp-Session-Id, Last-Event-ID

--- server/discover (replaces initialize) ---
Servers MUST implement `server/discover` to advertise supported protocol versions, capabilities and identity.
Clients MAY call it before any other request, or use it as a backward-compat probe on STDIO.

--- MRTR: InputRequiredResult (this is what a HOST must implement for elicitation) ---
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resultType": "input_required",
    "inputRequests": {
      "github_login": {
        "method": "elicitation/create",
        "params": {
          "mode": "form",
          "message": "Please provide your GitHub username",
          "requestedSchema": {
            "type": "object",
            "properties": { "name": { "type": "string" } },
            "required": ["name"]
          }
        }
      }
    },
    "requestState": "AEAD-protected blob"
  }
}

Client replies by RETRYING the original request with a NEW JSON-RPC id, carrying:
{
  "inputResponses": {
    "github_login": { "action": "accept", "content": { "name": "octocat" } }
  },
  "requestState": "<echoed byte-for-byte, never inspected or modified>"
}

Client MUSTs: construct requested inputs before retrying; echo requestState exactly; use a DIFFERENT
JSON-RPC id on the retry; never reuse inputRequests/requestState on any parallel request.
Allowed only on: prompts/get, resources/read, tools/call.
resultType is required on all results: "complete" | "input_required".
Clients MUST treat a missing resultType from earlier-protocol servers as "complete".

--- Subscriptions (replaces HTTP GET + resources/subscribe) ---
subscriptions/listen   // single long-lived POST-response stream
opt-in types: toolsListChanged | promptsListChanged | resourcesListChanged | resourceSubscriptions
notifications tagged with: io.modelcontextprotocol/subscriptionId

--- Cacheable list results (now required) ---
ttlMs: number            // freshness hint in milliseconds
cacheScope: "public" | "private"
on: tools/list, prompts/list, resources/list, resources/read, resources/templates/list

--- Error codes (renumbered) ---
-32000..-32019  implementation-defined (grandfathered)
-32020..-32099  reserved for the MCP spec
HeaderMismatch                  -32001 -> -32020
MissingRequiredClientCapability -32003 -> -32021
UnsupportedProtocolVersion      -32004 -> -32022
Resource not found              -32002 -> -32602 (Invalid Params)

--- Extension identifiers ---
io.modelcontextprotocol/ui                                 // MCP Apps
io.modelcontextprotocol/tasks                              // Tasks
io.modelcontextprotocol/oauth-client-credentials
io.modelcontextprotocol/enterprise-managed-authorization

--- MCP Apps (UI) ---
Tool declares:  _meta.ui.resourceUri  -> "ui://..."
Resource _meta.ui also carries: csp, permissions
Host<->app transport: postMessage, JSON-RPC, methods prefixed `ui/` (e.g. ui/initialize) plus shared `tools/call`

--- TypeScript SDK v2 (CURRENT, 2026-07-28) ---
npm install @modelcontextprotocol/client   # 2.0.0
npm install @modelcontextprotocol/server   # 2.0.0
npm install @modelcontextprotocol/node     # Streamable HTTP for IncomingMessage/ServerResponse
# LEGACY v1, do NOT start here: @modelcontextprotocol/sdk@1.30.0

--- Swift SDK (STALE: 2025-11-25 spec only) ---
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
]
// latest tag is 0.12.1 (2026-05-07); library product name is "MCP"
// platforms: .macOS("13.0"), .iOS("16.0"); swift-tools-version:6.1

--- Registry (live, unauthenticated reads) ---
curl -s "https://registry.modelcontextprotocol.io/v0/health"
# -> {"status":"ok","github_client_id":"Iv23liUydBbI7Z2Q9bOZ"}

curl -s "https://registry.modelcontextprotocol.io/v0/servers?search=github&version=latest&limit=3"
# query params: cursor, limit, updated_since (RFC3339), search (substring on name),
#               version ('latest' | exact e.g. '1.2.3'), include_deleted (bool)
# other paths: /v0/servers/{serverName}/versions
#              /v0/servers/{serverName}/versions/{version}
#              /v0/publish  /v0/validate  /v0/ping
# a parallel /v0.1/* family is also served
# OpenAPI: https://registry.modelcontextprotocol.io/openapi.yaml

--- MCPB (one-click local install, renamed from DXT) ---
npm install -g @anthropic-ai/mcpb
mcpb init   # generates manifest.json
mcpb pack   # produces the .mcpb bundle
