# Observability, decision-trace logging, and evaluation for a Mac-native computer-use agent harness (Bot-Harness)

> Verified research, 2026-08-29. Every claim carries the source that was actually
> fetched. Re-verify before relying on version numbers or pricing.

## Bottom line

The OpenTelemetry GenAI semantic conventions are the right vocabulary to adopt, but as of today they are still entirely "Development" status and were moved out of the main semantic-conventions repo into a separate repo that has zero releases and zero tags — so you can copy the attribute names but you cannot pin a stable schema version. For a solo developer on a Mac, the practical stack is: own your trace store as an append-only SQLite database in WAL mode (source of truth, survives everything), shape the records using gen_ai.* attribute names, and run Arize Phoenix locally with a single `uvx arize-phoenix serve` command as the trace-viewing UI, because Phoenix defaults to SQLite and needs no other services. Langfuse is the more polished product and is genuinely MIT-licensed at the core, but self-hosting it means Postgres plus ClickHouse plus Redis plus MinIO and a documented 16 GiB memory recommendation, which is a poor fit for a personal Mac app. On evaluation, be realistic: none of the serious computer-use benchmarks run natively on Apple Silicon without a virtual machine or a cloud account, and a single full OSWorld run costs roughly two thousand dollars in output tokens alone at frontier-model prices, so wire a hand-built regression suite of your own tasks into continuous integration and treat OSWorld as an occasional paid checkpoint rather than a routine test. The single most important design decision is that screenshots are the leak vector, not the text logs, and no vendor solves this for you — you must redact before the image is written to disk.

## Recommendation

**Storage: SQLite in WAL mode, as a single file under the app's Application Support directory. Not Postgres, not DuckDB.**

The decisive argument is not performance, it is the concurrency model. DuckDB permits exactly one process to hold a read-write handle to a database file; every other process can only attach read-only. A Mac-native harness will realistically have the SwiftUI shell in one process and agent work (or a Python computer-use driver, or a later CLI) in another, and DuckDB makes that architecturally impossible without a rewrite. SQLite's WAL mode gives you exactly the opposite property — readers do not block writers and writers do not block readers, with a single-writer serialization that a trace log (an append-mostly workload) never strains. Postgres solves a problem you do not have and costs you a daemon, a version upgrade path, and a backup story on a machine that already runs Docker for other reasons. SQLite is also in the macOS SDK, so Swift 6 with Command Line Tools only can link it with no package manager, no Xcode project, and no build step — which matters given the no-full-Xcode constraint.

Add sqlite-vec later and only when you actually want semantic search over past runs, and attach it as a *separate* database file. It is v0.1.10-alpha.4, its README warns of breaking changes, and it has not been pushed since May 2026; an alpha extension must not sit in the same file as your audit record.

**Observability: own the schema, borrow the UI.**

Write your own `run`/`step`/`artifact`/`change_log` tables as the source of truth (schema in the code section), naming every column after its `gen_ai.*` equivalent. Then dual-write to OTLP so any OTel-aware backend can read the same data. For the viewer, run `uvx arize-phoenix serve` — it is one command, no Docker, no external services, defaults to SQLite at `~/.phoenix/`, and listens for OTLP on :4317 already. Langfuse has the better trace-and-replay UI and is the more polished product, but self-hosting it means four services and a documented 16 GiB memory floor, and its server-side data masking is behind a paid enterprise license, which is precisely the feature you would want for this project. Keep Langfuse as an optional export target, not the local store. Reject LangSmith and Braintrust outright: neither is self-hostable without an enterprise contract, and both cap free tiers at 14-day retention, which is fundamentally incompatible with "maintain every decision trace."

**Screenshots: redact before write, never after.**

This is the requirement no vendor satisfies for you. Every platform surveyed redacts *attributes* — strings in span fields — and none of them look inside a PNG. A computer-use screenshot of a password manager, a bank page, or a terminal with an exported API key is a plaintext credential on disk, and once it is written, a downstream redaction processor cannot help. Build the redaction pass into the capture path in Swift, using the on-device Vision text recognizer to locate text regions and mask any that match secret patterns or that fall inside windows on a deny-list, before the bytes reach the filesystem. Then content-address the artifact by the SHA-256 of the *redacted* bytes, and record `redaction_regions` so a future auditor can see what was hidden and why without seeing the secret. Adopt the Collector redaction processor's allow-list-first posture (`allow_all_keys: false`, then explicit `allowed_keys`) rather than a deny-list, because deny-lists fail open. Give every artifact a `purge_after` timestamp at write time and run a sweeper — retention you have to remember to configure is retention you will not have.

**Evaluation: build your own regression suite; treat public benchmarks as occasional paid checkpoints.**

Wire exactly one public benchmark into CI: Terminal-Bench 2.0 via Harbor (`uv tool install harbor`). It is containerized, it does not need a desktop virtual machine, it already knows how to drive Claude Code as an agent, and it is cheap enough to run on a schedule. Everything else should stay manual. OSWorld cannot use its Docker provider on macOS at all because that path requires KVM, so on Apple Silicon it means VMware Fusion virtual machines or an AWS account, and the token economics are brutal — roughly $6 per task attempt in output tokens alone at frontier prices, which is four figures for a single 369-task sweep. WindowsAgentArena is Windows-only and stale since April. WebVoyager has been untouched since March 2024 and should be dropped from any current plan.

What will actually improve Bot-Harness is a locally-defined suite of twenty to fifty of Kunal's own real tasks, each with a deterministic checker, replayed from stored traces. Your `artifact` table already gives you the screenshots to replay against, which means most regressions can be caught without spending a single API token.

**The part that satisfies the stated #1 requirement.**

The `rationale` column on `step` and on `change_log` is the whole point. Traces that record only what happened produce a log a future agent must reverse-engineer; traces that record why a step was chosen, what alternatives were rejected, and what the model believed it was clicking produce a log a future agent can reason from. Capture `intent`, `rationale`, `alternatives`, and `cu_target_desc` on every step even though no specification asks for them, and make `change_log.rationale` NOT NULL so no change to the harness can be recorded without an explanation.

## Risks

- The OTel GenAI conventions are a moving target. Every gen_ai.* attribute is 'Development' status, the whole surface was relocated to a new repo in mid-2026, and that repo has zero releases and zero tags — meaning there is no versioned schema URL to pin against. Attribute names WILL change under you. Mitigate by treating gen_ai.* as a naming convention you copy into your own stable columns, with a JSON `attributes` escape hatch, rather than as a contract you depend on.
- Screenshots are the real leak vector and no surveyed tool addresses them. Langfuse, Phoenix, OpenLIT and the OTel redaction processor all redact string attributes only; none inspects image bytes. A single screenshot of a password field, a bank page, or a terminal with an exported key is a plaintext credential at rest. Redaction must happen in the capture path before the file is written, and this is code you have to write yourself.
- Langfuse's server-side data masking, data retention policies, and audit logs are all Enterprise-Edition features behind a paid license key. If you plan around Langfuse for the redaction and retention requirements you will hit a paywall precisely at the feature that matters most for this project.
- Phoenix is Elastic License 2.0, not open source. It is free for Kunal's personal and internal use, but the license forbids providing it to third parties as a hosted or managed service and forbids circumventing license-key functionality. If Bot-Harness ever becomes a product that ships or hosts Phoenix, this becomes a legal problem rather than an engineering one.
- sqlite-vec is alpha software that has not been pushed since May 2026. The README explicitly warns of breaking changes pre-v1. Building trace search on it today risks a migration; keeping it in a separate attached database file contains the blast radius.
- Published OSWorld-Verified scores near 85% are SELF-REPORTED by the model vendor, and the aggregator itself warns that rows vary by evaluator, harness, attempt budget, tool access, task filtering, and verification level. Do not use them as a target for your own harness — you will be comparing against a different step budget and toolset and concluding your agent is worse than it is.
- There are two different benchmarks both called OSWorld and they differ by a factor of four in difficulty. OSWorld-Verified (369 tasks) has frontier agents near 85%; OSWorld 2.0 (108 long-horizon tasks, averaging 318 tool calls each) has the best agent at 20.6%. Citing one number while meaning the other will badly miscalibrate expectations for what a personal harness can achieve.
- Full benchmark runs are genuinely expensive. At roughly 244K output tokens per task attempt and $25 per million output tokens, one OSWorld-scale sweep runs into the low thousands of dollars in output tokens alone, before input tokens. For a solo developer this is not a CI job, it is a deliberate purchase.
- Several repos and identifiers in the assignment brief are stale (org renames, tool-version strings, an abandoned benchmark). Any config, README, or agent instruction that hardcodes the old names will silently point at redirects or dead projects. Audit for these before writing them into the codebase.
- Claude Code's OTel content-capture variables (OTEL_LOG_USER_PROMPTS, OTEL_LOG_TOOL_CONTENT, OTEL_LOG_RAW_API_BODIES) default to OFF for good reason. Turning them all on to satisfy 'log everything' will write full API request and response bodies — including any secrets that passed through a tool — into your trace store. Enable them deliberately and only behind the same redaction pass as everything else.
- Phoenix's default SQLite database lives in a temporary folder unless PHOENIX_WORKING_DIR is set. If you rely on Phoenix as anything more than a viewer without setting that variable, traces can vanish on reboot — which would directly violate the 'maintain every decision trace' requirement.

## Corrections, and what could not be verified

These contradict the original brief, or no live source confirmed them.

- STALE IN BRIEF — computer use tool version. The current Anthropic computer use tool type string is `computer_toolset_20260801` and requires NO beta header. Older identifiers such as `computer_20250124` and `computer_20241022` are superseded; the immediately prior version was `computer_20251124`. The current toolset also adds a `zoom` action that did not exist in older versions. Any code or documentation carrying the old strings needs updating.
- STALE IN BRIEF — terminal-bench location. The GitHub org `laude-institute` has been renamed to `harbor-framework`. `laude-institute/terminal-bench` now redirects to `harbor-framework/terminal-bench-1`. The active harness is `harbor-framework/harbor`, which is 'the official harness for Terminal-Bench-2.0'. There are now three related repos (terminal-bench, terminal-bench-1, terminal-bench-2) and the brief's single-repo assumption is wrong.
- STALE IN BRIEF — OpenTelemetry GenAI conventions location. They are no longer at opentelemetry.io/docs/specs/semconv/gen-ai/; that page now serves only a redirect notice, and the registry marks all gen_ai.* attributes Deprecated in the main repo. The live spec is open-telemetry/semantic-conventions-genai. Anything fetching the old URL will get a stub.
- STALE IN BRIEF — the brief's framing implies the GenAI conventions may be stable. They are not. Every span, attribute, metric and event is 'Development', and the new repo has no releases and no tags at all.
- STALE IN BRIEF — benchmark list. WebVoyager (last commit 2024-03-04) is abandoned and should be dropped. WebArena (last push 2025-11-26) is largely dormant. WindowsAgentArena (last push 2026-04-13) is Windows-only and cannot run on the target Mac. The brief treats these as live options.
- STALE IN BRIEF — SWE-bench repo. `princeton-nlp/SWE-bench` has moved to the `SWE-bench/SWE-bench` org; old URLs redirect.
- STALE IN BRIEF — the brief asks for 'OSWorld and OSWorld-Verified' SOTA as if one benchmark. OSWorld 2.0 was released mid-2026 as a separate, much harder benchmark (108 long-horizon tasks vs 369) with radically different scores (20.6% vs ~85%). The os-world.github.io URL now redirects to osworld-v1.xlang.ai, confirming the v1/v2 split.
- MATERIAL EVENT NOT IN BRIEF — Langfuse was acquired by ClickHouse, Inc. on 2026-01-16. The LICENSE copyright now reads ClickHouse, Inc. ClickHouse has publicly committed to keeping the MIT core and self-hosting, but this changes the governance risk profile of a long-term dependency and the brief does not account for it.
- UNVERIFIED — OSWorld-Verified per-run dollar cost. The ~$6.10-per-task-attempt figure derives from the OSWorld 2.0 paper's token counts (244K output tokens for Opus 4.8) multiplied by published output-token pricing, reported via a secondary summary rather than read directly from a pricing page in this session. The order of magnitude is sound; treat the precise number as an estimate, and note it covers output tokens only.
- UNVERIFIED — the specific OSWorld-Verified leaderboard percentages (85.4% / 85.0% / 83.4%). These come from leaderboard.steel.dev, a third-party aggregator last updated 2026-07-10, and every top row is explicitly marked SELF-REPORTED by the vendor. The official OSWorld v1 site returned 'Loading verified benchmark data...' and did not render its leaderboard to a static fetch, so I could not corroborate against the primary source.
- UNVERIFIED — the claim that OpenAI stopped reporting SWE-bench Verified scores in February 2026 over contamination concerns, and the reported SWE-bench Verified top scores (~95%) and SWE-bench Pro top score (GPT-5.4 xHigh at 59.1%). All of these came from search-result summaries and SEO aggregator sites; swebench.com's leaderboard did not render to a static fetch. Do not cite these numbers without independent confirmation.
- UNVERIFIED — the exact Langfuse Python SDK masking signature. The `mask_otel_spans` parameter and `Langfuse(mask_otel_spans=mask_otel_spans)` construction came from a summarizer reading the docs page rather than from SDK source. Confirm against the installed package before writing code against it. Note also that the Python and JS/TS SDKs use different masking APIs.
- UNVERIFIED — Apple Vision framework OCR API shape on macOS 26. I could not retrieve developer.apple.com documentation for `RecognizeTextRequest` (the page returned only its title, and Apple docs are JavaScript-rendered). The recommendation to use on-device Vision OCR for screenshot redaction is architecturally sound and the framework certainly provides text recognition with bounding boxes, but I could NOT verify the current Swift API surface, its macOS 26 availability annotations, or whether the older `VNRecognizeTextRequest` is deprecated in favor of the newer Swift-native request type. Verify this directly in the SDK headers before building on it. One search result also alleged a memory-growth issue with repeated VNRecognizeTextRequest calls (~3-15 MB per call) — unconfirmed, but worth testing given a harness would call OCR on every screenshot.
- UNVERIFIED — LangSmith and Braintrust free-tier limits (5,000 traces/month and 14-day retention; 1 GB / 10,000 scores / 14-day retention respectively). These came from pricing-aggregator sites rather than the vendors' own pricing pages. The directional conclusion — that neither is free-self-hostable and both cap retention short — is well supported, but the specific numbers are not primary-sourced.
- NOT FOUND — there is no authoritative standard, specification, or widely-adopted open-source library for redacting secrets from agent SCREENSHOTS specifically. Searches returned only vendor marketing content about text-based PII redaction. This is a genuine gap you will have to fill with your own implementation; do not expect to find a drop-in solution.

## Verified facts

- The OpenTelemetry GenAI semantic conventions were moved out of open-telemetry/semantic-conventions into a dedicated repo, open-telemetry/semantic-conventions-genai. The gen_ai.* attributes in the main registry now carry the 'Deprecated' badge with a pointer to the new repo.  
  — **confirmed** · <https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/>
- The GenAI spans specification carries a 'Development' status badge — it is NOT stable. No gen_ai.* span or attribute is marked Stable.  
  — **confirmed** · <https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-spans.md>
- open-telemetry/semantic-conventions-genai has 302 stars, Apache-2.0 license, was created 2026-05-05 and last pushed 2026-08-27 — but the GitHub API returns an EMPTY list for both /releases and /tags. There is no versioned release or schema URL to pin against.  
  — **confirmed** · <https://api.github.com/repos/open-telemetry/semantic-conventions-genai/tags>
- Inference span name convention is `{gen_ai.operation.name} {gen_ai.request.model}`. Only gen_ai.operation.name and gen_ai.provider.name are Required; gen_ai.input.messages, gen_ai.output.messages, gen_ai.system_instructions and gen_ai.tool.definitions are Opt-In (off by default because they carry content).  
  — **confirmed** · <https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-spans.md>
- gen_ai.operation.name allowed values are: chat, create_agent, create_memory, create_memory_store, delete_memory, delete_memory_store, embeddings, execute_tool, fetch_response, generate_content, invoke_agent, invoke_workflow, plan, retrieval, search_memory, text_completion, update_memory, upsert_memory.  
  — **confirmed** · <https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-spans.md>
- Agent span naming: `create_agent {gen_ai.agent.name}` and `invoke_agent {gen_ai.agent.name}` (falling back to bare `invoke_agent` when the agent name is unavailable). The convention distinguishes an invoke_agent CLIENT span from an invoke_agent INTERNAL span; the internal variant requires only gen_ai.operation.name, not gen_ai.provider.name.  
  — **confirmed** · <https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/docs/gen-ai/gen-ai-agent-spans.md>
- Langfuse was acquired by ClickHouse, Inc., announced 2026-01-16. The repository LICENSE file now reads 'Copyright (c) 2023-2026 ClickHouse, Inc.' ClickHouse committed that 'Langfuse remains 100% open-source under its existing MIT license for core features which allows for self-hosting at production scale'.  
  — **confirmed** · <https://clickhouse.com/blog/clickhouse-acquires-langfuse-open-source-llm-observability>
- Langfuse's license is split: everything under 'ee/', 'web/src/ee/' and 'worker/src/ee/' is under a separate enterprise license; everything else is MIT Expat. So the GitHub API reports the license as NOASSERTION, not MIT.  
  — **confirmed** · <https://github.com/langfuse/langfuse/blob/main/LICENSE>
- Self-hosting Langfuse via docker compose requires PostgreSQL, ClickHouse, Redis and MinIO together, and the docs recommend 'at least 4 cores and 16 GiB of memory' plus ~100GiB storage. App on port 3000, MinIO on 9090.  
  — **confirmed** · <https://langfuse.com/self-hosting/docker-compose>
- Server-Side Data Masking is a Langfuse Enterprise Edition feature requiring a paid license key — it is NOT available in the free self-hosted OSS build. Also EE-gated: Data Retention Policies and Audit Logs. This matters directly for the screenshot/PII requirement.  
  — **confirmed** · <https://langfuse.com/self-hosting/license-key>
- Langfuse accepts native OTLP over HTTP at /api/public/otel (and /api/public/otel/v1/traces), with Basic auth from base64-encoded API keys plus an 'x-langfuse-ingestion-version: 4' header. gRPC is NOT supported — HTTP/JSON and HTTP/protobuf only.  
  — **confirmed** · <https://langfuse.com/integrations/native/opentelemetry>
- Arize Phoenix is licensed under the Elastic License 2.0 (ELv2), not an OSI-approved open-source license. The LICENSE file states 'You may not provide the software to third parties as a hosted or managed service' and 'You may not move, change, disable, or circumvent the license key functionality'. Free for personal/internal use; not free to resell as a service.  
  — **confirmed** · <https://github.com/Arize-ai/phoenix/blob/main/LICENSE>
- Phoenix defaults to file-based SQLite (no Postgres required), with PHOENIX_WORKING_DIR defaulting to ~/.phoenix/, web UI on port 6006 and the gRPC OTLP trace collector on port 4317. This makes it the lowest-friction self-hosted trace UI for a single-user Mac app.  
  — **confirmed** · <https://arize.com/docs/phoenix/self-hosting/configuration>
- OpenLIT is Apache-2.0 (a genuinely permissive license, unlike Phoenix or Langfuse), is OpenTelemetry-native, and its maintainers co-maintain the gen_ai semantic conventions with the OpenTelemetry community. However it stores traces in ClickHouse, so self-hosting is heavier than Phoenix. 2,723 stars, actively pushed 2026-08-29.  
  — **confirmed** · <https://github.com/openlit/openlit>
- Claude Code has built-in OpenTelemetry export, enabled with CLAUDE_CODE_ENABLE_TELEMETRY=1, with span tracing behind CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1. Content capture is OFF by default and gated behind separate opt-in vars: OTEL_LOG_USER_PROMPTS, OTEL_LOG_ASSISTANT_RESPONSES, OTEL_LOG_TOOL_DETAILS, OTEL_LOG_TOOL_CONTENT, OTEL_LOG_RAW_API_BODIES.  
  — **confirmed** · <https://code.claude.com/docs/en/monitoring-usage>
- Claude Code emits log events named claude_code.user_prompt, claude_code.assistant_response, claude_code.api_request, claude_code.api_error, claude_code.api_refusal, claude_code.tool_result, claude_code.tool_decision, claude_code.permission_mode_changed, claude_code.mcp_server_connection. claude_code.tool_decision carries decision/tool_source attributes — this is an existing, copyable model for a permission-decision trace.  
  — **confirmed** · <https://code.claude.com/docs/en/monitoring-usage>
- The current Anthropic computer use tool type string is `computer_toolset_20260801` and it requires NO beta header. The prior version was `computer_20251124` (beta header required). Current toolset supports claude-opus-5, claude-sonnet-5, claude-mythos-5, claude-fable-5, claude-opus-4-8, and adds a `zoom` action taking region [x0,y0,x1,y1].  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- Anthropic automatically runs prompt-injection classifiers on computer-use prompts: 'When these classifiers identify potential prompt injections in screenshots, they will automatically steer the model to ask for user confirmation before proceeding with the next action.' Your trace schema should record when this happens.  
  — **confirmed** · <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- SQLite WAL mode: 'WAL provides more concurrency as readers do not block writers and a writer does not block readers.' Limitations: 'there can only be one writer at a time' and 'WAL does not work over a network filesystem' (irrelevant for a local Mac app).  
  — **confirmed** · <https://www.sqlite.org/wal.html>
- DuckDB in-process allows only ONE process to hold a read-write handle to a database file at a time; multiple processes can only attach read-only. This disqualifies it as the live write store for an app where a UI process and an agent process both need to write.  
  — **confirmed** · <https://duckdb.org/docs/stable/connect/concurrency.html>
- sqlite-vec is still pre-1.0: latest release is v0.1.10-alpha.4 published 2026-05-18, flagged prerelease=true, and the README states 'sqlite-vec is a pre-v1, so expect breaking changes!' It is pure C with no dependencies and runs on macOS ARM. 8,055 stars, Apache-2.0.  
  — **confirmed** · <https://github.com/asg017/sqlite-vec/releases>
- OSWorld 2.0 exists and is a different, far harder benchmark than OSWorld-Verified: 108 long-horizon tasks, median ~1.6 human hours each, averaging 318 tool calls versus ~30 in OSWorld 1.0. Best agent (Claude Opus 4.8, max thinking, batched tool calls) completes only 20.6% at a 500-step budget; GPT-5.5 plateaus near 13%. arXiv 2606.29537, submitted 2026-06-28, revised 2026-07-13.  
  — **confirmed** · <https://arxiv.org/abs/2606.29537>
- OSWorld (v1) is 369 tasks, of which 8 Google Drive tasks may need manual setup, leaving 361 usable. OSWorld-Verified was released 2025-07-28 with community-reported fixes and AWS support reducing a full evaluation to about 1 hour wall-clock via parallelization.  
  — **confirmed** · <http://osworld-v1.xlang.ai/>
- OSWorld on a Mac requires VMware Fusion — 'for systems with Apple Chips, you should install VMware Fusion'. The Docker provider is NOT viable on macOS because it needs KVM and 'macOS hosts generally do not support KVM'. So local OSWorld on Apple Silicon means Fusion VMs or a cloud provider (AWS/Modal/Daytona).  
  — **confirmed** · <https://github.com/xlang-ai/OSWorld/blob/main/README.md>
- The GitHub org laude-institute has been renamed to harbor-framework. laude-institute/terminal-bench now redirects to harbor-framework/terminal-bench-1 (2,557 stars, last push 2026-07-11). A separate active repo harbor-framework/terminal-bench (558 stars, pushed 2026-08-28) is described as 'Measuring and evolving with the frontier of agent work'.  
  — **confirmed** · <https://api.github.com/repos/laude-institute/terminal-bench>
- Harbor (harbor-framework/harbor, 4,758 stars, Apache-2.0, v0.22.0 released 2026-08-22) is 'the official harness for Terminal-Bench-2.0' and can evaluate arbitrary agents including Claude Code. Install with `uv tool install harbor` or `pip install harbor`.  
  — **confirmed** · <https://github.com/harbor-framework/harbor/blob/main/README.md>
- The OpenTelemetry Collector redaction processor is Beta for traces and Alpha for logs/metrics. Config keys are exactly: allow_all_keys, allowed_keys, ignored_keys, ignored_key_patterns, blocked_key_patterns, blocked_values, allowed_values, hash_function, redact_all_types, summary, url_sanitizer, db_sanitizer, hmac_key.  
  — **confirmed** · <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/redactionprocessor/README.md>
- OpenTelemetry's official guidance for sensitive data names four Collector processors — attributes (hash/delete actions), filter (drop whole spans), redaction (allow-list attributes), and transform (regex via replace_pattern()) — and leads with data minimization: 'Only collect data that serves an observability purpose'.  
  — **confirmed** · <https://opentelemetry.io/docs/security/handling-sensitive-data/>
- WebVoyager is effectively abandoned: MinorJerry/WebVoyager was last pushed 2024-03-04, over two years ago. WebArena (web-arena-x/webarena) was last pushed 2025-11-26. Neither is a live target for 2026 CI.  
  — **confirmed** · <https://api.github.com/repos/MinorJerry/WebVoyager>
- WindowsAgentArena (microsoft/WindowsAgentArena, MIT, 891 stars) was last pushed 2026-04-13. It benchmarks agents on Windows and is therefore not runnable natively on macOS — it needs a Windows VM or Azure.  
  — **confirmed** · <https://api.github.com/repos/microsoft/WindowsAgentArena>
- princeton-nlp/SWE-bench has moved to the SWE-bench/SWE-bench org (5,734 stars, MIT, pushed 2026-08-18). Old URLs redirect. SWE-bench Verified is a 500-instance human-validated subset.  
  — **confirmed** · <https://api.github.com/repos/princeton-nlp/SWE-bench>
- On OSWorld 2.0 at a 500-step budget, Claude Opus 4.8 consumes roughly 244K output tokens per task attempt at $25 per million output tokens, i.e. roughly $6.10 per task in output tokens alone. Extrapolated to a 369-task OSWorld-Verified sweep this is on the order of $2,000+ per full run before input tokens.  
  — likely · <https://arxiv.org/html/2606.29537v1>
- Top reported OSWorld-Verified scores cluster around 85% (Claude Mythos Preview 85.4%, Claude Mythos 5 / Claude Fable 5 85.0%, Claude Opus 4.8 83.4%), but the aggregator explicitly flags every top row as SELF-REPORTED by Anthropic, and notes rows 'can vary by evaluator, harness, attempt budget, tool access, task filtering, or verification level'.  
  — likely · <https://leaderboard.steel.dev/leaderboards/osworld/>
- The Langfuse Python SDK's client-side masking hook is `mask_otel_spans`, passed to the constructor as `Langfuse(mask_otel_spans=mask_otel_spans)`, operating on raw OpenTelemetry span attributes at export time. The JS/TS SDK instead uses a `mask` function over stringified JSON attributes. This client-side path is free (SDK is MIT), unlike server-side masking.  
  — likely · <https://langfuse.com/docs/observability/sdk/python/advanced-usage>
- LangSmith's free Developer plan is one seat with roughly 5,000 traces/month and 14-day retention; self-hosting LangSmith inside your own infrastructure requires an Enterprise contract. Braintrust's free Starter tier is ~1 GB processed data, 10,000 scores, 14-day retention, with Pro at $249/month. Neither is meaningfully self-hostable for free.  
  — likely · <https://www.braintrust.dev/docs/plans-and-limits>

## Repositories and tools

| Name | Fit | What it does | Stars | Licence | Last activity |
|---|---|---|---|---|---|
| [Arize Phoenix](https://github.com/Arize-ai/phoenix) | ADOPT as the local trace UI. It is the only mature option that runs from a single command with zero external services and a SQLite backend — exactly right for a single-user Mac app. Caveat: Elastic License 2.0, so fine for Kunal's personal use but you cannot ship it as a hosted service. | Self-hosted LLM/agent trace viewer, evals, datasets and experiments. Built on OpenTelemetry + OpenInference. Defaults to file-based SQLite at ~/.phoenix/, serves UI on :6006 and an OTLP gRPC collector on :4317. | 11,238 | Elastic License 2.0 (ELv2) — NOT OSI open source; GitHub reports NOASSERTION | pushed 2026-08-29 |
| [Langfuse](https://github.com/langfuse/langfuse) | EVALUATE, do not adopt as the primary local store. Best trace-and-replay UI of the group and genuinely MIT at the core, but self-hosting drags in Postgres + ClickHouse + Redis + MinIO with a documented 16 GiB memory floor. Also, server-side data masking is paid-EE, which is the wrong side of the fence for your screenshot-redaction requirement. Reasonable as an optional export target. | The most polished open LLM observability product: trace tree UI, sessions, prompt management, evals, native OTLP ingestion at /api/public/otel with gen_ai.* attribute mapping. Acquired by ClickHouse Inc. on 2026-01-16; core stays MIT. | 33,896 | MIT Expat for core; separate enterprise license for ee/ directories | v4.24.0 released 2026-08-28 |
| [OpenLIT](https://github.com/openlit/openlit) | REFERENCE-ONLY for the app itself, but the single best source of truth for what the gen_ai.* conventions actually look like in working code, since the maintainers write the spec. Apache-2.0 makes it the most legally unencumbered option if you ever need to vendor code. ClickHouse dependency rules it out as an embedded Mac store. | OpenTelemetry-native AI observability platform with evals, guardrails, prompt management and a vault. Its maintainers co-maintain the OTel gen_ai semantic conventions. Two-line Python integration: `import openlit; openlit.init()`. Stores traces in ClickHouse. | 2,723 | Apache-2.0 | pushed 2026-08-29 |
| [OpenTelemetry GenAI Semantic Conventions](https://github.com/open-telemetry/semantic-conventions-genai) | ADOPT the vocabulary, but pin nothing. Copy the attribute names verbatim into your schema so a future agent (or a future you) can pipe the same records into any OTel-aware backend. Because there are zero releases and zero tags, treat it as a naming guide, not a versioned contract, and expect churn. | The specification repo for gen_ai.* spans, attributes, metrics and events, including agent spans (invoke_agent, create_agent), tool-execution spans, and MCP conventions. Split out of the main semantic-conventions repo. | 302 | Apache-2.0 | pushed 2026-08-27; no releases, no tags |
| [Harbor (formerly Laude Institute)](https://github.com/harbor-framework/harbor) | ADOPT for CI evaluation. This is the one benchmark harness that is cheap, containerized, runs terminal tasks rather than needing a desktop VM, and already knows how to drive Claude Code. Install with `uv tool install harbor`. Note the org rename from laude-institute — old URLs and any docs referencing them are stale. | Agent evaluation and RL-rollout framework; the official harness for Terminal-Bench 2.0, and can also drive third-party benchmarks. Evaluates arbitrary agents including Claude Code, OpenHands and Codex CLI. | 4,758 | Apache-2.0 | v0.22.0 released 2026-08-22 |
| [OSWorld](https://github.com/xlang-ai/OSWorld) | REFERENCE-ONLY for CI; run it manually a handful of times at most. On Apple Silicon it needs VMware Fusion because the Docker provider requires KVM which macOS does not provide, and a full frontier-model sweep runs into four figures of API spend. Mine its task definitions and its evaluator functions for ideas instead. | The reference computer-use benchmark. OSWorld/OSWorld-Verified is 369 Ubuntu desktop tasks (361 without the Google Drive set). OSWorld 2.0 is a separate, much harder 108-task long-horizon benchmark. | 3,112 | Apache-2.0 | pushed 2026-08-21 |
| [sqlite-vec](https://github.com/asg017/sqlite-vec) | EVALUATE, and only add it once you actually need semantic search over past traces. It is still v0.1.10-alpha.4 and the README warns of breaking changes, and it has not been pushed since May 2026. Keep embeddings in a separate attached database file so an alpha extension breaking cannot corrupt your primary trace store. | Pure-C, dependency-free vector search extension for SQLite. Creates vec0 virtual tables holding float, int8 or binary vectors; runs anywhere SQLite runs including macOS ARM. | 8,055 | Apache-2.0 | v0.1.10-alpha.4 released 2026-05-18 |
| [OpenTelemetry Collector Contrib — redaction processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/redactionprocessor) | ADOPT the pattern, not necessarily the binary. Its allow-list-first design (allow_all_keys: false, then explicit allowed_keys) is the correct default for agent traces and is worth reimplementing directly in Swift so no unredacted data ever reaches disk. Note it is only Beta for traces, Alpha for logs. | Collector processor that deletes span attributes not on an allow-list, then masks values matching blocked regex patterns. Supports hashing via hmac_key, plus url_sanitizer and db_sanitizer. | n/a (monorepo) | Apache-2.0 | actively maintained |
| [WindowsAgentArena](https://github.com/microsoft/WindowsAgentArena) | REJECT. Windows-only, so it cannot run on Kunal's Mac without a Windows VM or an Azure subscription, and it has not been touched since April 2026. No value for a macOS-native harness. | Scalable Windows OS platform for benchmarking multi-modal agents. | 891 | MIT | pushed 2026-04-13 |
| [WebVoyager](https://github.com/MinorJerry/WebVoyager) | REJECT. Last commit was 2024-03-04 — abandoned for over two years. Any brief recommending it as a current benchmark is out of date. WebArena is only marginally healthier (last push 2025-11-26). | End-to-end web agent benchmark from the 2024 paper. | 1,123 | Apache-2.0 | pushed 2024-03-04 |

## API and code shape

## 1. Run the local trace UI (recommended — zero infra, SQLite-backed)

```shell
uvx arize-phoenix serve
```
Or installed: `pip install arize-phoenix` then `phoenix serve`.
Defaults: UI on :6006, OTLP gRPC collector on :4317, data in ~/.phoenix/ (file-based SQLite).
Override with: PHOENIX_WORKING_DIR, PHOENIX_PORT, PHOENIX_GRPC_PORT, PHOENIX_SQL_DATABASE_URL.

Docker equivalent:
```bash
docker run -p 6006:6006 -p 4317:4317 -i -t arizephoenix/phoenix:latest
```

## 2. Langfuse self-host (only if you want its trace UI; heavy)

```bash
git clone https://github.com/langfuse/langfuse.git
cd langfuse
docker compose up
```
Upgrade: `docker compose up --pull always`. UI at http://localhost:3000, MinIO at :9090.
Requires Postgres + ClickHouse + Redis + MinIO; docs recommend "at least 4 cores and 16 GiB of memory".

Native OTLP ingestion (HTTP only, no gRPC):
```bash
OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:3000/api/public/otel"
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic ${AUTH_STRING},x-langfuse-ingestion-version=4"
# AUTH_STRING: echo -n "pk-lf-xxx:sk-lf-xxx" | base64
```
Signal-specific path: /api/public/otel/v1/traces

## 3. Capture Claude Code's own traces into the same collector

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1      # span tracing (beta)
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_LOG_USER_PROMPTS=1
export OTEL_LOG_TOOL_DETAILS=1
claude
```
Content-capture vars, all default-OFF: OTEL_LOG_USER_PROMPTS, OTEL_LOG_ASSISTANT_RESPONSES,
OTEL_LOG_TOOL_DETAILS, OTEL_LOG_TOOL_CONTENT, OTEL_LOG_RAW_API_BODIES.

## 4. Anthropic computer use tool (CURRENT — verify against your brief)

```json
{"type": "computer_toolset_20260801", "name": "computer"}
```
No beta header required. Prior version was "computer_20251124" (beta header required).
Actions: screenshot, zoom (region [x0,y0,x1,y1]), left_click, right_click, middle_click,
double_click, triple_click, left_click_drag, mouse_move, left_mouse_down, left_mouse_up,
cursor_position, scroll, type, key, hold_key, wait.

Credentials, if unavoidable, are wrapped by Anthropic's documented convention:
```xml
<robot_credentials>
username: [username]
password: [password]
</robot_credentials>
```

## 5. OTel span/attribute names to mirror in your schema

Span names:
  inference:     "{gen_ai.operation.name} {gen_ai.request.model}"     e.g. "chat claude-opus-5"
  agent create:  "create_agent {gen_ai.agent.name}"
  agent invoke:  "invoke_agent {gen_ai.agent.name}"
  tool:          operation gen_ai.operation.name = "execute_tool"

Required:      gen_ai.operation.name, gen_ai.provider.name
Cond. req.:    error.type, gen_ai.conversation.id, gen_ai.output.type, gen_ai.request.model,
               gen_ai.request.seed, gen_ai.request.stream, gen_ai.request.choice.count,
               gen_ai.prompt.name, gen_ai.prompt.version, gen_ai.request.top_k
Recommended:   gen_ai.request.max_tokens, gen_ai.response.id, gen_ai.response.finish_reasons,
               gen_ai.usage.input_tokens, gen_ai.usage.output_tokens, gen_ai.conversation.compacted
Opt-In (content, off by default):
               gen_ai.input.messages, gen_ai.output.messages, gen_ai.system_instructions,
               gen_ai.tool.definitions
Agent:         gen_ai.agent.id, gen_ai.agent.name, gen_ai.agent.version, gen_ai.agent.description
Tool:          gen_ai.tool.name, gen_ai.tool.type, gen_ai.tool.description,
               gen_ai.tool.call.id, gen_ai.tool.call.arguments, gen_ai.tool.call.result
Usage extras:  gen_ai.usage.cache_read.input_tokens, gen_ai.usage.cache_creation.input_tokens,
               gen_ai.usage.reasoning.output_tokens

gen_ai.provider.name values include: anthropic, openai, gcp.gemini, gcp.vertex_ai,
aws.bedrock, azure.ai.openai, azure.ai.inference, cohere, deepseek, groq, mistral_ai,
perplexity, x_ai, ibm.watsonx.ai

## 6. Redaction allow-list pattern (OTel Collector redaction processor)

```yaml
processors:
  redaction:
    allow_all_keys: false
    allowed_keys: [description, group, id, name]
    ignored_key_patterns: ["^safe_.*", ".*_trusted$"]
    blocked_key_patterns: [".*token.*", ".*api_key.*"]
    blocked_values:
      - "4[0-9]{12}(?:[0-9]{3})?"
      - "(5[1-5][0-9]{14})"
    hash_function: md5
    summary: debug
```

## 7. Recommended SQLite schema for the decision/step trace

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;

-- One row per user-facing task (maps to gen_ai.conversation.id)
CREATE TABLE run (
  run_id            TEXT PRIMARY KEY,          -- UUIDv7, time-sortable
  conversation_id   TEXT NOT NULL,             -- gen_ai.conversation.id
  goal              TEXT NOT NULL,             -- the user's request, verbatim
  agent_name        TEXT,                      -- gen_ai.agent.name
  agent_version     TEXT,                      -- gen_ai.agent.version
  harness_version   TEXT NOT NULL,             -- your app build, for reproducibility
  provider_name     TEXT NOT NULL,             -- gen_ai.provider.name
  request_model     TEXT NOT NULL,             -- gen_ai.request.model
  started_at        INTEGER NOT NULL,          -- unix micros
  ended_at          INTEGER,
  status            TEXT NOT NULL,             -- running|ok|error|cancelled|blocked_on_user
  error_type        TEXT,                      -- error.type
  redaction_policy  TEXT NOT NULL              -- policy id in force, for audit
);

-- One row per span. Self-referencing = full decision tree, OTel-shaped.
CREATE TABLE step (
  step_id           TEXT PRIMARY KEY,          -- UUIDv7
  run_id            TEXT NOT NULL REFERENCES run(run_id),
  parent_step_id    TEXT REFERENCES step(step_id),
  trace_id          TEXT NOT NULL,             -- 16-byte hex, W3C
  span_id           TEXT NOT NULL,             -- 8-byte hex, W3C
  seq               INTEGER NOT NULL,          -- monotonic within run
  operation_name    TEXT NOT NULL,             -- gen_ai.operation.name enum value
  span_name         TEXT NOT NULL,             -- "chat claude-opus-5" etc
  started_at        INTEGER NOT NULL,
  ended_at          INTEGER,
  status            TEXT NOT NULL,
  error_type        TEXT,

  -- decision layer: WHY, not just what
  intent            TEXT,                      -- one-line plain statement of the goal of this step
  rationale         TEXT,                      -- model's stated reason for choosing this action
  alternatives      TEXT,                      -- JSON array of considered-and-rejected actions
  confidence        REAL,                      -- 0..1 if the model reports one

  -- tool layer
  tool_name         TEXT,                      -- gen_ai.tool.name
  tool_type         TEXT,                      -- gen_ai.tool.type
  tool_call_id      TEXT,                      -- gen_ai.tool.call.id
  tool_arguments    TEXT,                      -- gen_ai.tool.call.arguments (JSON, POST-REDACTION)
  tool_result       TEXT,                      -- gen_ai.tool.call.result (JSON, POST-REDACTION)

  -- computer-use layer
  cu_action         TEXT,                      -- screenshot|left_click|type|key|scroll|zoom|...
  cu_coordinate     TEXT,                      -- JSON [x,y]
  cu_target_desc    TEXT,                      -- what the model believed it was clicking
  screen_before_id  TEXT REFERENCES artifact(artifact_id),
  screen_after_id   TEXT REFERENCES artifact(artifact_id),

  -- permission / safety layer
  permission_decision TEXT,                    -- auto_allowed|user_approved|user_denied|blocked
  permission_reason   TEXT,
  injection_flagged   INTEGER NOT NULL DEFAULT 0,  -- Anthropic classifier steered to confirm

  -- cost layer
  input_tokens      INTEGER,                   -- gen_ai.usage.input_tokens
  output_tokens     INTEGER,                   -- gen_ai.usage.output_tokens
  cache_read_tokens INTEGER,                   -- gen_ai.usage.cache_read.input_tokens
  cache_creation_tokens INTEGER,
  reasoning_tokens  INTEGER,                   -- gen_ai.usage.reasoning.output_tokens
  cost_usd_micros   INTEGER,

  attributes        TEXT                       -- JSON escape hatch for any other gen_ai.* attr
);
CREATE INDEX step_run_seq   ON step(run_id, seq);
CREATE INDEX step_parent    ON step(parent_step_id);
CREATE INDEX step_trace     ON step(trace_id, span_id);

-- Content-addressed blobs. Screenshots NEVER inline in step rows.
CREATE TABLE artifact (
  artifact_id       TEXT PRIMARY KEY,          -- sha256 of the REDACTED bytes
  run_id            TEXT NOT NULL REFERENCES run(run_id),
  kind              TEXT NOT NULL,             -- screenshot|screenshot_region|dom|file|stdout
  mime_type         TEXT NOT NULL,
  byte_size         INTEGER NOT NULL,
  path              TEXT NOT NULL,             -- relative to the app's Application Support dir
  captured_at       INTEGER NOT NULL,
  redacted          INTEGER NOT NULL,          -- 1 = redaction pass ran
  redaction_count   INTEGER NOT NULL DEFAULT 0,-- how many regions were masked
  redaction_regions TEXT,                      -- JSON [[x,y,w,h,reason]] — audit WHAT was hidden
  purge_after       INTEGER NOT NULL           -- unix seconds; retention enforced by a sweeper
);
CREATE INDEX artifact_purge ON artifact(purge_after);

-- Append-only change log: how the harness ITSELF changed over time.
CREATE TABLE change_log (
  change_id         TEXT PRIMARY KEY,
  occurred_at       INTEGER NOT NULL,
  actor             TEXT NOT NULL,             -- human|claude-code|bot-harness
  category          TEXT NOT NULL,             -- code|prompt|tool|permission|config|schema
  target            TEXT NOT NULL,             -- file path, prompt id, tool name
  summary           TEXT NOT NULL,
  rationale         TEXT NOT NULL,             -- WHY. This is the field future agents read.
  diff_ref          TEXT,                      -- git sha or artifact_id
  related_run_id    TEXT REFERENCES run(run_id)
);
```

Optional embeddings, in a SEPARATE attached file so an alpha extension cannot corrupt the trace store:
```sql
create virtual table vec_examples using vec0(
  sample_embedding float[8]
);
```

## 8. Evaluation harness in CI

```bash
uv tool install harbor
harbor datasets list
harbor run --dataset terminal-bench@2.0 --agent claude-code --model anthropic/claude-opus-4-1 --n-concurrent 4
```

OSWorld, if you ever run it (needs VMware Fusion on Apple Silicon — Docker provider needs KVM which macOS lacks):
```bash
python scripts/python/run_multienv.py \
    --provider_name docker \
    --headless \
    --observation_type screenshot \
    --model gpt-4o \
    --sleep_after_execution 3 \
    --max_steps 15 \
    --num_envs 10 \
    --client_password password
```
