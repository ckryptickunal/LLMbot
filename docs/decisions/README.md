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
| [0007](0007-cheapest-execution-surface-first.md) | Always take the cheapest execution surface that will work | accepted | 2026-08-29 |
| [0008](0008-the-verifier-decides-when-a-run-is-over.md) | The verifier decides when a run is over, not the model | accepted | 2026-08-29 |
| [0009](0009-port-the-mascot-rather-than-run-it.md) | Port the mascot's animation rather than embed its runtime | accepted | 2026-08-30 |
| [0010](0010-parse-shell-before-judging-it.md) | Parse a shell command before judging it, and treat "unreadable" as its own answer | accepted | 2026-08-30 |
| [0010](0010-radix-colour-over-a-macos-override-layer.md) | Radix Colors for surfaces, macOS semantics for everything the OS owns | accepted | 2026-08-30 |
| [0011](0011-existence-checks-must-not-touch-the-acl.md) | Credential existence checks never touch the keychain ACL | superseded by 0012 | 2026-08-30 |
| [0012](0012-credentials-live-in-an-owner-only-file.md) | Credentials live in an owner-only file, not the Keychain | accepted | 2026-08-30 |
| [0013](0013-settle-work-whose-process-is-gone.md) | Settle work whose process is gone, at launch and at stop | accepted | 2026-08-31 |
| [0014](0014-the-shell-honours-the-contract.md) | The shell honours the contract, and one matcher decides every path question | accepted | 2026-08-31 |
| [0015](0015-memory-is-data-and-never-permission.md) | Memory is data, never permission, and it carries where it came from | accepted | 2026-08-31 |
| [0016](0016-effects-are-recorded-before-they-happen.md) | Effects are recorded before they happen, and "uncertain" is a real answer | accepted | 2026-08-31 |
| [0017](0017-the-trace-chain-is-keyed.md) | The trace chain is keyed, and the key lives beside the API keys | accepted | 2026-08-31 |
| [0018](0018-the-browser-is-driven-through-applescript.md) | The browser is driven through AppleScript, not a debugging port | accepted | 2026-08-31 |
| [0019](0019-the-claude-cli-is-a-model-not-an-agent.md) | The claude CLI is used as a model, not as an agent | accepted | 2026-08-31 |
