# Contributing to W

Thanks for helping. `README.md` is the orientation doc and `AGENTS.md` the
detailed workflow doc; this page is the short version.

## Licence

W is released under the MIT License (`LICENSE`). By contributing you
agree that your contributions are licensed under the same terms.

The compiler's original ancestor, cc500, is GPL-2.0-or-later; its
copyright and terms are recorded next to its credit in
`docs/references.txt`.

## Style

- W source is **tab-indented**. Spaces are a compiler warning, and the
  self-host stages build with `--strict`, so a warning fails the build.
  The repository's `.editorconfig` sets this up for most editors.
- Blocks open with `:`, there are no semicolons, comments start with `#`,
  and every file needs a trailing newline.
- Check a file without producing a binary: `./bin/wv2 check --json file.w`
  (empty output and exit 0 means clean). Fix warnings, not just errors.

## Gates

Run these before you open a pull request:

```sh
./wbuild build     # bootstrap from the pinned seed; any warning fails
./wbuild verify    # self-host fixpoint (wv3 == wv4 == wv5); required for any compiler change
./wbuild tests     # full pre-merge suite
```

For quicker iteration, `./wbuild wtest` and then
`git diff --name-only origin/main | ./bin/wtest changed` print the focused
targets for your diff; `./wbuild test_changed` runs them. Codegen or
word-size work should also pass `./wbuild verify_x64`.

A new end-to-end test is just a `tests/foo_test.w` file; see
"A new end-to-end test" in `CLAUDE.md` for the `# wbuild:` directives.

## Pull requests

1. Branch from `main`, keep each pull request to one change, and reference
   the issue it addresses (`Fixes #123`).
2. Describe what changed and which gates you ran.
3. CI (`.github/workflows/ci.yml`) must pass before merge, and a code
   owner (`.github/CODEOWNERS`) reviews.

## The seed constraint

Everything in `w.w`'s import closure (the compiler, its grammar and code
generator, the auto-imported container runtime, and the libraries they
import) is compiled by the pinned seed binary. It may not use language
syntax newer than that seed until `SEEDS` is bumped to a release that
contains it. New syntax is fine in tests and other leaf programs. See the
seed sections of `AGENTS.md` and `docs/release.md` for the promotion flow.

New language syntax must also be added to `tests/parser_generator/w.pg`.

## Security issues

Do not file security problems as public issues; see `SECURITY.md`.
