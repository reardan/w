---
name: w-seed-update
description: The bootstrap-seed discipline — what the pinned seed is, when ./wbuild update is allowed, and how a new seed is published via a release tag plus SEEDS bump. Use before any ./wbuild update, when seed-graph code needs newer language syntax, or when wbuild reports the seed differs from its pin.
---

# Seed updates and `./wbuild update` discipline

The seed `./w` is a statically linked 32-bit x86 Linux ELF that
compiles the compiler's own sources. It is **not committed**: `SEEDS`
at the repo root pins a release tag, asset name and sha256 for each
seed (`w`, `w_darwin`, `w.exe`), and `./wbuild` downloads a missing
seed from that GitHub release, refusing to run it on a hash mismatch.

Bootstrap chain: the seed compiles `w.w` into `bin/wv2`; `./wbuild
build` continues wv2 -> wv3 -> wv4 -> wv5 (those self-host stages
compile with `--strict`, so any warning fails the build), and
`./wbuild verify` asserts the fixpoint wv3 == wv4 == wv5.

## Local promotion: `./wbuild update`

`./wbuild update` archives the current seed (`archive.sh` -> `old/`)
and promotes the `bin/wv3` fixpoint onto `./w` (`update_darwin` /
`update_win` do the same for the other seeds). Rules:

- **Only after `./wbuild verify` passes.** The target depends on
  `verify`, so a broken fixpoint cannot be promoted — never work
  around that ordering.
- **Local only.** A promoted `./w` changes nothing for other checkouts
  or CI, which keep bootstrapping from the `SEEDS` pin. Afterwards
  `wbuild` prints a one-line notice that the seed differs from its
  pin; `rm w` re-downloads the pinned seed to get back to baseline.

## Publishing a seed: release tag + SEEDS bump

Making a new seed real for everyone is a release, not an `update`
(details in `docs/release.md`):

1. Land the feature PR. It must build under the *current* pinned seed.
2. Cut a release at that commit (version bumped in `package.wmeta` and
   `w.w`'s `--version` string; the workflow verifies every fixpoint).
3. In a follow-up PR, bump **every** `SEEDS` line to the new tag,
   copying sha256 values from the release's `SHA256SUMS`. The
   single-tag pin keeps all seeds compiling the same sources by
   construction.
4. Only after the `SEEDS` bump lands may seed-compiled sources use the
   new syntax.

## The no-post-seed-syntax rule

Everything in `w.w`'s transitive import graph is compiled by the
pinned seed: `compiler/`, `grammar/`, `code_generator/`, `debugger/`,
the auto-imported container runtime (`structures/hash_table.w`,
`structures/w_list.w`), `libs/extras/{c_import,c_preprocessor,
parser_generator}`, and any `lib/` file those import. None of it may
use language syntax newer than the seed until the `SEEDS` bump lands —
a feature can work in `bin/wv2` yet break the next cold bootstrap.
`./bin/wv2 deps w.w` prints the exact membership; new syntax is fine
in `tests/` and other leaf consumers once `bin/wv2` exists.
