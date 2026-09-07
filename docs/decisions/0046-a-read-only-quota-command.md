# ADR 0046: A read-only `quota` command

- Status: Accepted
- Date: 2026-09-07
- Amends [ADR 0007](./0007-rust-native-local-service.md) for one executable

## Context

[ADR 0007](./0007-rust-native-local-service.md) put one private Rust service behind one entry
point, and `AGENTS.md` said the rest out loud: `apps/menubar/helper` is the only entry point over
`packages/service`, with no command parser and no public installation surface, and the bundled
service executable is "never a public command".

The reason for that was collection. A second process that can start a refresh is a second thing
holding provider credentials, a second scheduler, a second writer of the local stores, and a second
place a person can be asked for Keychain access. None of that is worth a terminal.

But the numbers are already on disk, and the people running coding agents live in a terminal. The
question a command answers — "what is left, and what did I burn today" — needs none of the machinery
the rule was protecting.

## Decision

`packages/service` gains a second binary, `quota`, and it reads. It does not collect.

- **It opens the disposable cache read-only and nothing else.** `SQLITE_OPEN_READ_ONLY`, no owner
  lock, no migration, no recovery of interrupted work. `identity.sqlite` — where the session and
  provider credentials live — is not opened at all, so the command cannot read a secret whatever it
  is asked to print. It runs beside a live QuotaBar without taking anything away from it.
- **It prints the last valid state, and says when there is none.** The same answer QuotaBar shows
  the moment it starts ([`README.md`](../../README.md)). A Mac QuotaBar has never run on has no
  state to print, and the command says one sentence and exits 1 rather than creating one.
- **The words are the shared ones.** `packages/service/src/copy.rs` answers
  `remaining-copy-conformance.json` and `reset-copy-conformance.json`, the same fixtures
  `packages/quota-model`, `packages/apple-shared`, and the website answer. A window in a terminal
  and the same window in the menu bar cannot say different things.
- **`--json` is the state itself.** Not a second shape: `quota status --json` is the overview array
  QuotaBar reads over IPC, and `quota usage --json` is the stored period as the service folded it
  ([ADR 0040](./0040-a-period-is-folded-where-its-days-already-are.md)). A script reads what the app
  reads.
- **It ships in the bundle and is installed with a symlink.** `Contents/Helpers/quota`, signed the
  same way its sibling is, so the command a person links onto their `PATH` is the build QuotaBar is
  running. There is no installer, no Homebrew formula, and no separate release.

`AGENTS.md` is corrected in the same change: the private service still has exactly one entry point,
and this is not one of them.

## Consequences

- There are now two executables over `packages/service`, and only one of them may write. That is
  the whole of the rule that replaces the old one: a second writer would be the thing ADR 0007
  refused, and a reader is not.
- A cache one QuotaBar version behind is still readable, because the command reads the stored
  period as the JSON it is rather than decoding it into this build's summary type. The cache is
  disposable and versionless by design; a command that refused to print a fold it could otherwise
  read would be inventing a version boundary the store does not have.
- Counts print grouped rather than abbreviated. Compact-count copy is pinned by no fixture, and a
  terminal has room for the digits, so this adds no fourth rounding rule for the others to drift
  from.

## What was given up

A command that can refresh would be the useful one for anybody scripting against stale state, and
it is exactly the one ADR 0007 refused: it would need credentials, a lock, and a schedule. A
Homebrew formula would install the command without the app that fills the state it reads, which is
a support question rather than a feature.
