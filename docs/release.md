# Releases

W ships as GitHub releases: SemVer tags (`vX.Y.Z`) built and published by
`.github/workflows/release.yml`. Every binary in a release comes from a
verified self-host fixpoint — the workflow runs the full test suite plus
`verify`, `verify_x64`, `verify_win`, `verify_wasm` in a matrix of Linux
runners (one leg per target, so wall time is the slowest verify, not the
sum) and `verify_darwin` on an arm64 macOS runner, so a release cannot be
cut from a compiler that does not reproduce itself.

## Assets

| Asset | Target | Built from |
|---|---|---|
| `w-x86-linux` | 32-bit x86 Linux ELF, static | `bin/wv3` |
| `w-x86_64-linux` | x86-64 Linux ELF | `bin/wv3_64` |
| `w-x86_64-windows.exe` | win64 PE | `bin/wv3_win.exe` |
| `w-wasm32-wasi.wasm` | wasm32/WASI module | `bin/wv3_wasm` |
| `w-arm64-macos` | arm64 Mach-O, self-signed | `bin/wv3_darwin` |
| `SHA256SUMS` | checksums of the above | publish job |

arm64-Linux (`w-arm64-linux` from `bin/wv3_arm64`) is not currently
published: its self-host verify needs qemu-user emulation, which made it
the slowest release leg, and the target has no consumers yet. The matrix
leg is commented out in `release.yml` with notes on the two re-enable
paths (uncomment as-is, or split across an `ubuntu-24.04-arm` runner to
verify natively). `./wbuild verify_arm64` still works locally.

## Cutting a release

1. Bump the version in **both** places, in one PR:
   - `package.wmeta` (`version X.Y.Z`)
   - `w.w` (the `--version` string, `w X.Y.Z`)
   The workflow fails a tag that disagrees with either.
2. Merge to `main`.
3. Optional but recommended before the first tag after workflow changes:
   trigger the `Release` workflow via *workflow_dispatch* on `main` — it
   builds and verifies everything but skips publishing (a dry run).
4. Tag and push:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

5. The workflow publishes the release with auto-generated notes and all
   assets. Confirm the 7 assets are present.

No local `gh` calls or local builds are involved; the release is created
in CI with the workflow token.

## Seed promotion

The bootstrap seeds (`w`, `w_darwin`, and `w.exe` on Windows) are not
committed. `SEEDS` at the repo root pins a release tag, asset name, and
sha256 for each; `wbuild` / `wbuild.cmd` download a missing seed from that
release and refuse to run it on a hash mismatch. To promote a new seed
(required before seed-compiled sources may use new language syntax):

1. Land the compiler-feature PR. It must build under the *current* pinned
   seed — the release workflow bootstraps from that seed, which is the
   same constraint `./wbuild update` has always had.
2. Cut a release at that commit (previous section).
3. In a follow-up PR, bump **every** `SEEDS` line to the new tag, copying
   the sha256 values from the release's `SHA256SUMS`. Pinning all seeds
   to a single tag keeps them compiling the same sources by construction
   (this replaces the old "refresh `./w` and `./w_darwin` in the same PR"
   rule, see #128/#129).
4. Only after the `SEEDS` bump lands may seed-compiled sources use the
   new syntax.

`./wbuild update` / `update_darwin` / `update_win` still promote a locally
built fixpoint onto the (untracked) seed files for local iteration, and
`archive.sh` still backs the old one up to `old/`. After a local
promotion — or in a stale checkout after a `SEEDS` bump — `wbuild` prints
a one-line notice that the seed differs from its pin; `rm w` (or
`w_darwin` / `w.exe`) re-downloads the pinned one.
