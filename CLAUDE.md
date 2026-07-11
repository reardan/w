# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

W is a small, self-hosting compiled language (C-like semantics, Python-like
tab-indented syntax). The compiler is written in W (`w.w` + its imports),
compiles itself, and is bootstrapped from `./w` — a statically linked
**32-bit x86 Linux ELF** seed binary that `./wbuild` downloads from the
GitHub release pinned in `SEEDS` (sha256-verified; the seeds are not
committed). It emits executables directly,
with no assembler, linker, or libc dependency: x86/x86-64 Linux ELF
(primary), plus arm64 Linux ELF, `arm64_darwin` Mach-O, win64 PE, and
wasm32/WASI backends (`./wbuild verify_wasm` / `wasm_smoke_test` run the
wasm gates via `tools/run_wasm.sh`, needing wasmtime or node). `README.md` is the detailed orientation doc and `AGENTS.md` the
agent workflow doc; both are current and authoritative — this file is the
summary.

**Platform**: `./w` is a Linux seed; `./w_darwin` is a pinned arm64
Mach-O seed that bootstraps natively on this Mac (`./wbuild build_darwin`,
`verify_darwin`). On this macOS checkout, prefer in this order:
1. **Locally on the Mac** for anything the native darwin toolchain covers
   (`./wbuild build_darwin` self-hosts; run Mach-O binaries with
   `tools/mac/run_darwin_tests.sh` — the compiler self-signs its output).
2. **ssh host `w`** (x86_64 Linux, clone at `/home/w/w`) for
   builds/verify/tests that need Linux — everything runs directly there.
   The 32-bit dynamically linked tests additionally need `libc6:i386`
   (`/lib/ld-linux.so.2`): `dynamic_test`, `c_import_test`,
   `c_import_errno_test`, `c_import_libc_test`, `float_abi_test`,
   `varargs_test`, `extern_data_test`. `verify_arm64` and the arm64 run
   targets need `qemu-user-static`.
3. **The `w-dev` Docker container** (`tools/mac/wdev.sh`, repo
   bind-mounted at `/w`) ONLY when absolutely necessary — i.e. a job
   neither of the above can do, such as natively executing aarch64-Linux
   binaries (the container is arm64 Ubuntu; `w` is x86_64). Do not
   default to it: the emulated seed makes builds very slow.

`arm64_darwin` Mach-O binaries are self-signed by the compiler and run
natively on the Mac with `tools/mac/run_darwin_tests.sh`.

## Commands

```sh
./wbuild build       # bootstrap: ./w w.w -> bin/wv2 -> wv3 -> wv4 -> wv5
./wbuild verify      # self-host fixpoint (wv3==wv4==wv5) — REQUIRED gate for any compiler change
./wbuild verify_x64  # same for the 64-bit target; run for codegen/word-size work
./wbuild verify_arm64  # same for the ARM64 target
./wbuild tests       # full pre-merge suite
./wbuild update      # ONLY after verify: archives seed, promotes the bin/wv3 fixpoint to ./w (local only; publishing = release + SEEDS bump, docs/release.md)
./wbuild wdbg        # in-process debugger (bin/wdbg file.w)
./bin/wv2 repl.w -o bin/repl && ./bin/repl   # interactive REPL
```

`./wbuild` runs targets from `build.json` (`./wbuild --list`; parallel +
content-hash cached, `--no-cache` to force, `rm -rf bin` resets). On this
Mac it bootstraps a native Mach-O executor from `./w_darwin`; only the
darwin targets run here — everything else needs Linux.

Compile and run one program: `./bin/wv2 file.w -o out && ./out`
(insert `x64` before the file for 64-bit).

**Run a single/focused test**: `git diff --name-only HEAD | ./bin/wtest changed`
prints the exact build targets for your diff (build wtest with `./wbuild wtest`);
`./wbuild test_changed` runs them. Don't guess targets. Selection is
manifest-driven: wtest parses `build.json` and combines literal step
references with import closures from `bin/wv2 deps` (cached in
`bin/.wtest_deps_cache`; the first run after a build takes ~35s, later
runs are sub-second), plus documented residue rules in `tools/test_map.w`
(compiler tree → `verify`, any `.w` → `parser_generator_w_test`,
deleted `.w`/library trees → `metadata_check`).

**Check without compiling to a binary**: `./bin/wv2 check --json file.w`
(NDJSON diagnostics; empty stdout + exit 0 = clean). Fix warnings, not just
errors — self-host stages build with `--strict`, so any warning fails
`./wbuild build`. There is no separate linter; the compiler's warnings are the
lint, asserted by `./wbuild warning_test`.

**Find declarations**: `./bin/wv2 symbols --json file.w` instead of grepping.

**List a program's imports**: `./bin/wv2 deps file.w` prints the transitive
import closure (root, imports, auto-imported runtime), one repo-relative
path per line; `--json` emits `{"file": "..."}` NDJSON. Like `check`, it
composes with the arch selectors (`./bin/wv2 x64 deps file.w` or
`deps x64 file.w`) and resolves `lib/__arch__/` imports per target.

Gotcha: `bin/` is gitignored; `./wbuild` creates it, but hand-run compiles
(`./bin/wv2 ...`) need `mkdir -p bin` (or `./wbuild build`) first if you see
`bin/...: No such file or directory`.

## Architecture

- **Single-pass, no AST, no IR** (cc500 heritage): grammar rules in
  `grammar/*.w` fuse parsing and code emission, writing machine-code bytes
  through `code_generator/x86.w` (x64 reuses it via REX-prefix helpers).
  Language-behavior changes live in `grammar/`; instruction encoding, ELF
  layout (elf_32/elf_64/elf_dynamic), DWARF, and FFI shims live in
  `code_generator/`. `compiler/` holds the driver, tokenizer, symbol and
  type tables. `lib/` is the stdlib, `structures/` the containers.
- **Bootstrap chain**: seed compiles sources → wv2 → wv3 → wv4 → wv5; byte
  equality of wv3/wv4/wv5 (`./wbuild verify`) is the cheapest strong regression
  guard. A change can pass unit tests while corrupting self-hosting.
- **Seed constraint**: everything in `w.w`'s transitive import graph is
  compiled by the pinned seed: `w.w`, `grammar.w`, `codegen.w`,
  `compiler/`, `grammar/`, `code_generator/`, `debugger/`, the
  auto-imported container runtime (`structures/hash_table.w`,
  `structures/w_list.w`), `libs/extras/{c_import,c_preprocessor,parser_generator}`
  (pulled in by the compiler's C-import feature), and any `lib/` file those
  import. None of it may use language syntax newer than the seed until
  `SEEDS` is bumped to a release containing it (`docs/release.md`; a local
  `./wbuild update` doesn't change what other checkouts bootstrap from).
  New syntax is fine in `tests/` and other leaf consumers once `bin/wv2`
  exists.
- **Seed promotion**: land the feature PR (builds under the old pinned
  seed) → tag a release at that commit → follow-up PR bumps every `SEEDS`
  line to that tag. The single-tag pin replaces the old "refresh `./w` and
  `./w_darwin` in the same PR" rule (#128/#129) — all seeds stay
  source-consistent by construction.
- Built-in `map`/`set`/`list` lower to that runtime, which
  `compiler/compiler.w` auto-imports into every program.

## Rules when making changes

- W source is **tab-indented** (spaces are a compiler warning), blocks open
  with `:`, no semicolons, `#` comments, trailing newline required.
- Expression gotchas that repeatedly bite generated code: `|`/`&` are
  bitwise and never short-circuit — use `&&`/`||` for guards; a hex
  literal with bit 31 set sign-extends into the word-sized `int` on every
  target (`0xffffffff` is `-1` even on x64, so `x & 0xffffffff` never
  truncates — build 32-bit masks at runtime, see `lib/sha256.w`); `byte`
  is a built-in 1-byte type name, so `byte = ...` at statement position
  parses as a declaration — don't name identifiers `byte`.
- New language syntax must also be added to the parser-generator grammar
  `tests/parser_generator/w.pg` — `parser_generator_w_test` parses every
  tracked `.w` file and fails on unknown syntax.
- Diagnostic message text is frozen by `warning_test`, the
  `type_system_*_test` targets and the other fixture targets; rewording a
  message requires updating the fixtures in the same commit. Compile-only
  diagnostic fixtures carry their expected messages as
  `# expect_stderr:` / `# reject_stderr:` / `# expect_fail` directive
  lines in their own header comments, asserted by `bin/wfixture`
  (`tools/wfixture.w`; a `<fixture>.w.expect` sidecar is the fallback
  for a fixture whose exact bytes are the test). Targets that also run
  the produced binary keep `expect_stderr`/`expect_fail` fields on their
  `build.json` steps.
- A new end-to-end test is just the source file: create `tests/foo_test.w`
  (use `lib/assert.w` / `lib/testing.w`), add a `# wbuild: x64` directive
  line if it should also run as a 64-bit `foo_64_test` twin, and run
  `./wbuild manifest`. `build.json` is GENERATED (but committed):
  `tools/wbuildgen.w` derives every conventional compile+run test target
  from the tree and merges it with the hand-maintained `build.base.json`
  (toolchain, fixture, and irregular targets), including `tests` /
  `tests_x64` umbrella membership; `./wbuild manifest_check` (part of
  `tests`) fails CI on drift, so never edit `build.json` by hand. A test
  needing extra steps or `expect_*` assertions gets a hand-written target
  in `build.base.json` instead. `bin/wtest` picks targets up automatically
  from the manifest (literal step references + import closures); a
  `tools/test_map.w` residue rule is only needed for coupling the import
  graph cannot see (run-time data files, non-default-arch modules).
- The agent tooling here is dogfooded: if you hit friction or bugs in
  `w check`, `wtest`, or the other agent-facing surfaces, add an entry to
  `docs/projects/ai_tooling_next_steps.md` in the same PR. (The LSP/MCP/
  index/hook integrations built on those surfaces moved out of this repo
  in July 2026.)
- Design docs for major features live in `docs/projects/*.md`;
  `docs/todo.txt` tracks the working/missing inventory.
