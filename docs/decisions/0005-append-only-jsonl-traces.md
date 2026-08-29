---
id: 0005
title: Decision traces are append-only JSONL on disk, not a database
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [observability, architecture]
---

# 0005. Decision traces are append-only JSONL on disk, not a database

## Context

The user's first and most emphatic requirement: *"Maintain every decision trace, maintain every
change log, maintain every step that the LLM takes… for any other agent to work and improve it
in the future."*

The synthesis of the research recommended SQLite in WAL mode, reasoning that two processes (a
Swift shell and a Python sidecar) would both need to write, and that WAL supports concurrent
readers where DuckDB does not.

That reasoning is sound but its premise does not currently hold: ADR 0002 put everything in one
Swift binary, so there is one writer.

## Options considered

### Option A — SQLite, WAL mode
- **For:** Queryable. Handles multiple writers. Links from the macOS SDK with no package.
  Correct if a sidecar is added later.
- **Against:** Reading a trace requires a tool. The failure mode of a corrupt database is losing
  the whole file, which is precisely the case where you most need the record.

### Option B — Append-only JSONL, one directory per run
- **For:** `cat`, `grep`, `jq`, `tail -f` all work. A crashed process leaves a valid file minus
  its last line. Any agent can read it with no schema knowledge. Diffable, and greppable across
  runs with no index.
- **Against:** No queries. "Which runs failed last week" means scanning, or maintaining a
  manifest per run.

## Decision

We chose **Option B**, with a `run.json` manifest per run carrying the summary figures so the
common aggregate question does not require a scan.

Because: the trace exists to be read by a future agent debugging a run that went wrong, and in
that moment "you need the right tool to open it" is exactly the wrong property.

Specific commitments, each of which costs something:

- **Written before the action, amended after.** A step is recorded as proposed *before* the tool
  runs, and completed afterwards as a separate appended line rather than by rewriting. A crash
  mid-action therefore leaves evidence of what was being attempted — the case where you most
  need it, and the case a write-after-completion design loses.
- **Secrets redacted on the way in, not on the way out.** A trace file is a file; it gets copied
  into issues and pasted into chats. Redacting at read time is redacting too late.
- **Screenshots stored beside the trace, referenced by name.** They are the largest and most
  sensitive artifacts, so deleting them must not corrupt the record.
- **Tracing never fails the work.** Every write is best-effort. A broken logger must not break
  a run.
- **`intent` is a first-class field.** Gemini's Computer Use returns the model's stated reason
  per action; that string is the "decision" in decision trace, and it is what makes the log
  answer *why* rather than only *what*.

## Consequences

- **We now must:** maintain the `run.json` manifest, or aggregate questions get slow.
- **We now must:** keep the schema flat and self-describing enough that `jq` on it is pleasant
  without reading this codebase.
- **We can no longer:** run cross-run analytical queries without writing something that indexes
  the JSONL. That is acceptable; it is a reporting feature, not a debugging one.
- **`var/` stays gitignored.** The repository is public and traces hold real commands and file
  contents.

## Revisit when

A second process needs to write traces — the most likely cause being a Python or Node sidecar
for MCP or browser control. At that point SQLite WAL becomes correct and this decision should
be superseded rather than patched with file locks.
