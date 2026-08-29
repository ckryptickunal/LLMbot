# Decision records

Every architectural choice in Bot-Harness lives here as a numbered ADR. This directory is
the answer to "why is it built this way?" for any human or agent who arrives later.

## Rules

1. **One decision per file**, numbered `NNNN-kebab-title.md`, never renumbered.
2. **Never edit a decision's substance after it is `accepted`.** To change your mind, write
   a new ADR and set `superseded_by` on the old one and `supersedes` on the new one. The
   record of having been wrong is the most valuable part of the file.
3. **Every claim of fact needs a source.** A URL you actually fetched, or a `path:line` in
   this repo. If it is an assumption, write the word "assumption" next to it.
4. **Write the falsifier.** Every ADR must state what observation would prove it wrong.
   An ADR without a revisit trigger is an opinion, not a decision.
5. Copy `_TEMPLATE.md` to start.

## When an agent must write an ADR

Write one before you do any of these, not after:

- Adding, replacing, or removing a dependency or external service
- Changing the tool-permission model or anything in the safety kernel
- Changing the trace schema or any on-disk format
- Choosing between two implementations where the loser is still defensible
- Reversing a decision recorded here

If the choice is obvious and reversible in an afternoon, do not write an ADR. Write a line
in `CHANGELOG.md` instead.

## Index

| # | Title | Status | Date |
|---|-------|--------|------|
| [0001](0001-run-on-the-users-real-mac.md) | Bots run on the user's real Mac, not in a cloud VM | accepted | 2026-08-29 |
| [0002](0002-native-swiftui-zero-dependencies.md) | Native SwiftUI in one Swift binary, with no third-party dependencies | accepted | 2026-08-29 |
| [0003](0003-sign-with-a-real-certificate.md) | Sign with the Apple Development certificate, never ad hoc | accepted | 2026-08-29 |
| [0004](0004-two-layer-permission-model.md) | Permissions are a natural-language rule layer over an unlowerable floor | accepted | 2026-08-29 |
| [0005](0005-append-only-jsonl-traces.md) | Decision traces are append-only JSONL on disk, not a database | accepted | 2026-08-29 |
| [0006](0006-two-brains-gemini-and-claude-cli.md) | Two brains — Gemini for computer use, the local claude CLI for coding | accepted | 2026-08-29 |