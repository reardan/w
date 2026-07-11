# Releases

W ships as GitHub releases: SemVer tags (`vX.Y.Z`) built and published by
`.github/workflows/release.yml`. Every binary in a release comes from a
verified self-host fixpoint — the workflow runs the full test suite plus
`verify`, `verify_x64`, `verify_arm64`, `verify_win`, `verify_wasm` on a
Linux runner and `verify_darwin` on an arm64 macOS runner, so a release
cannot be cut from a compiler that does not reproduce itself.

## Assets

| Asset | Target | Built from |
|---|---|---|
| `w-x86-linux` | 32-bit x86 Linux ELF, static | `bin/wv3` |
| `w-x86_64-linux` | x86-64 Linux ELF | `bin/wv3_64` |
| `w-arm64-linux` | arm64 Linux ELF | `bin/wv3_arm64` |
| `w-x86_64-windows.exe` | win64 PE | `bin/wv3_win.exe` |
| `w-wasm32-wasi.wasm` | wasm32/WASI module | `bin/wv3_wasm` |
| `w-arm64-macos` | arm64 Mach-O, self-signed | `bin/wv3_darwin` |
| `SHA256SUMS` | checksums of the above | publish job |

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
