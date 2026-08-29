# 0012 — Credentials live in an owner-only file, not the Keychain

**Status:** accepted, 2026-08-30
**Supersedes the storage half of:** [0011 — Existence checks must not touch the ACL](0011-existence-checks-must-not-touch-the-acl.md)

## What changed

API keys were stored in the login keychain under the service `app.botharness.keys`. They are now
stored in a single JSON file:

```
~/Library/Application Support/Bot-Harness/credentials.json    mode 0600
~/Library/Application Support/Bot-Harness/                    mode 0700
```

`Keychain.swift` is deleted. `CredentialStore.swift` replaces it with the same shape — `get`,
`set`, `has`, `delete` — so the fourteen call sites changed by name only.

## Why

The keychain asked for the login password repeatedly, and ADR 0011 explains only half of why.
Fixing the `kSecReturnData` mistake removed the prompts from the app, but not from `swift run
Evals`: that binary is ad-hoc signed, its designated requirement contains a per-build hash, and
so every rebuild produces a binary the keychain has never seen. "Always Allow" cannot persist for
something whose identity changes on every compile. There is no fix inside the keychain for that;
it is what the keychain is *for*.

So the choice was between a store that is stronger but interrupts a development loop several
times an hour, and a store that is weaker but never does. This project is a local-first app that
runs on one person's Mac under their own account, using their own API keys. The keys buy inference
from Google and Anthropic. They are not the user's identity, their money at rest, or anything that
grants access to another person's data.

## What this costs, stated plainly

The keychain encrypted keys at rest, bound access to a code signature, and put the operating
system between a stranger's process and a secret. **A file with mode 0600 does none of that.**
Anything running as this user can read it: another app, a script the user pastes into a terminal,
a compromised dependency in any project on the machine. Full-disk encryption still protects the
file when the Mac is off, and nothing else does.

This is a real reduction in security, accepted deliberately, not an equivalent swap.

## What carries the weight instead

The keychain was also doing something less obvious: it kept *this app's own bots* away from the
keys. A bot with permission to read `~/**` could not read a keychain item, because the keychain is
not a path. Once the keys are a file inside Application Support, that protection stops being
structural and has to be built. Three things do it:

1. **The path is on the permanent floor.** `Authority.alwaysDenied` contains it, and
   `FileExecutor` checks that list *separately from the contract's own deny list, and always*.
   This matters more than it looks: `Authority` is `Codable`, so a `state.json` written before
   this change decodes into a contract whose deny list predates the credential file. Reading the
   floor from the contract would have meant last week's saved file quietly reopening the hole.

2. **The shell is guarded too, because it never went through `FileExecutor`.**
   `cat ~/Library/Application\ Support/Bot-Harness/credentials.json` bypasses the file tool
   entirely. `ShellFloor.readsTheKeyStore` now refuses it, as a new `SafetyFloor.readingSecrets`
   category whose behaviour is `neverAllow` rather than `askFirst` — a dialog the user can only
   sensibly answer one way is not a choice.

   The guard matches on **resolved full paths, never on the file name**. `credentials.json` is a
   common name; Google client secrets use it. A name-only check would refuse ordinary work in the
   user's own repositories, and a guard that fires on legitimate work is one people learn to
   route around.

3. **Shell output is redacted by value.** The path guard can be evaded — a path assembled from a
   variable, a `cd` first, a glob. Redaction cannot be evaded the same way, because it matches
   the key's actual characters in whatever comes back. This is the guard that actually holds.

## Residual risk, not papered over

An **obfuscated read still wins**: `base64 < credentials.json`, `xxd`, reading byte ranges, or
anything else whose output does not contain the literal key. The path guard does not see the
path and the redactor does not see the value.

This is not closable with string matching, and pretending otherwise would be worse than saying
so. Closing it properly needs the shell to run under a sandbox profile that cannot open the file
at all — `sandbox-exec` can express this, and it is the right next step if this app ever runs
bots it did not get from the user. It is not built today.

## Consequences

- `scripts/set-key.sh` writes the file instead of calling `security`, and gains `--list` and
  `--remove`. Both routes — the script and Settings — now write the same file, so the ownership
  mismatch that ADR 0011 describes cannot happen at all.
- `scripts/doctor.sh` checks the file and reports its mode, warning if it is not `600`.
- Settings shows a repair banner if the mode drifts. A backup restore or a sync tool can widen
  it, and nobody would otherwise notice.
- The Settings copy changed from "never written to a file" to "stored in one file only you can
  read". The old sentence is now false, and a settings screen that oversells its own security is
  worse than one that admits what it is.
- Existing keychain items are **not migrated automatically**, because reading them would raise
  the password dialog this change exists to remove. Users re-enter the key in Settings, or run
  `scripts/set-key.sh gemini`. Any leftover item can be deleted with
  `security delete-generic-password -s app.botharness.keys -a gemini`.

## Tested by

`Tests/BotHarnessTests/CredentialStoreTests.swift` — file mode after write, permission-drift
detection and repair, one account not clobbering another, the floor refusing the file under a
contract that allows `~/**` with an empty deny list, the shell refusing quoted *and* unquoted
spellings of the path, the shell still allowing a project's own `credentials.json`, and
redaction by value.

The unquoted-path case was found by the test, not by review: the store's path contains a space
in "Application Support", so an unquoted spelling splits into two operands and matched nothing.
The guard now checks the raw command text for the full path as well as the parsed operands.
