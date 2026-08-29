#!/usr/bin/env python3
"""Append-only decision trace for every tool call any agent makes in this repo.

Wired to Claude Code's PreToolUse / PostToolUse / UserPromptSubmit / Stop /
SessionStart / SessionEnd hooks. Reads the hook payload as JSON on stdin, writes one
compact JSON object per line to var/traces/agent-activity.jsonl, and always exits 0 so a
tracing failure can never block real work.

Design notes:
  - Never mutates or blocks. Exit code is always 0 and stdout is always empty.
  - Unknown payload shapes are stored verbatim under "raw" so the trace survives any
    future change to Claude Code's hook schema.
  - Large tool inputs/outputs are truncated with an explicit marker rather than dropped,
    so a reader can always tell that truncation happened.
  - Values that look like secrets are redacted before they reach disk.
"""

import json
import os
import re
import sys
import time
from pathlib import Path

MAX_FIELD = 4000
REPO = Path(__file__).resolve().parents[2]
TRACE = REPO / "var" / "traces" / "agent-activity.jsonl"

SECRET_PATTERNS = [
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}"),
    re.compile(r"sk-[A-Za-z0-9]{32,}"),
    re.compile(r"AIza[A-Za-z0-9_\-]{30,}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"(?i)(api[_-]?key|token|secret|password)\"?\s*[:=]\s*\"?([^\s\"',]{12,})"),
]


def redact(text):
    for pat in SECRET_PATTERNS:
        text = pat.sub(lambda m: m.group(0)[:6] + "<redacted>", text)
    return text


def clip(value):
    if value is None:
        return None
    s = value if isinstance(value, str) else json.dumps(value, default=str)
    s = redact(s)
    if len(s) > MAX_FIELD:
        return s[:MAX_FIELD] + f"…<truncated {len(s) - MAX_FIELD} chars>"
    return s


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        payload = {"_parse_error": True}

    if not isinstance(payload, dict):
        payload = {"raw": payload}

    known = {
        "session_id", "transcript_path", "cwd", "hook_event_name",
        "tool_name", "tool_input", "tool_response", "prompt", "message",
        "permission_mode", "reason", "source",
    }

    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "event": payload.get("hook_event_name") or "unknown",
        "session": payload.get("session_id"),
        "cwd": payload.get("cwd"),
        "tool": payload.get("tool_name"),
        "input": clip(payload.get("tool_input")),
        "output": clip(payload.get("tool_response")),
        "prompt": clip(payload.get("prompt")),
        "pid": os.getpid(),
    }

    extra = {k: v for k, v in payload.items() if k not in known}
    if extra:
        record["raw"] = clip(extra)

    record = {k: v for k, v in record.items() if v is not None}

    try:
        TRACE.parent.mkdir(parents=True, exist_ok=True)
        with TRACE.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
