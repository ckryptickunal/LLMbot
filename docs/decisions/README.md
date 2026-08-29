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
| _(populated as ADRs land)_ | | | |
