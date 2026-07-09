# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

W is a small, self-hosting compiled language (C-like semantics, Python-like
tab-indented syntax). The compiler is written in W (`w.w` + its imports),
compiles itself, and is bootstrapped from `./w` — a committed, statically
linked **32-bit x86 Linux ELF** seed binary. It emits executables directly,
with no assembler, linker, or libc dependency: x86/x86-64 Linux ELF
(primary), plus arm64 Linux ELF, `arm64_darwin` Mach-O, and win64 PE
backends. `README.md` is the detailed orientation doc and `AGENTS.md` the
agent workflow doc; both are current and authoritative — this file is the
summary.

**Platform**: `./w` is a Linux seed; `./w_darwin` is a committed arm64
Mach-O seed that bootstraps natively on this Mac (`./wbuild build_darwin`,
`verify_darwin`). On this macOS checkout, prefer in this order:
1. **Locally on the Mac** for anything the native darwin toolchain covers
   (`./wbuild build_darwin` self-hosts; run Mach-O binaries with
   `tools/mac/run_darwin_tests.sh` — the compiler self-signs its output).
2. **ssh host `w`** (x86_64 Linux, clone at `/home/w/w`) for
   builds/verify/tests that need Linux — everything runs directly there
   (`dynamic_test` additionally needs `libc6:i386`).
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
./wbuild update      # ONLY after verify: archives seed, promotes bin/wv2 to ./w
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
`./wbuild test_changed` runs them. Don't guess targets.

**Check without compiling to a binary**: `./bin/wv2 check --json file.w`
(NDJSON diagnostics; empty stdout + exit 0 = clean). Fix warnings, not just
errors — self-host stages build with `--strict`, so any warning fails
`./wbuild build`. There is no separate linter; the compiler's warnings are the
lint, asserted by `./wbuild warning_test`.

**Find declarations**: `./bin/wv2 symbols --json file.w` instead of grepping.

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
- **Seed constraint**: `w.w`, `grammar.w`, `codegen.w`, `compiler/`,
  `grammar/`, `code_generator/`, and the auto-imported container runtime
  (`structures/hash_table.w`, `structures/w_list.w`) are compiled by the
  committed seed, so they must not use language syntax newer than the seed
  until `./wbuild update` promotes one. New syntax is fine in `tests/`, `lib/`,
  and other consumers once `bin/wv2` exists.
- Built-in `map`/`set`/`list` lower to that runtime, which
  `compiler/compiler.w` auto-imports into every program.

## Rules when making changes

- W source is **tab-indented** (spaces are a compiler warning), blocks open
  with `:`, no semicolons, `#` comments, trailing newline required.
- New language syntax must also be added to the parser-generator grammar
  `tests/parser_generator/w.pg` — `parser_generator_w_test` parses every
  tracked `.w` file and fails on unknown syntax.
- Diagnostic message text is frozen by `warning_test` and the
  `type_system_*_test` targets; rewording requires updating those fixtures
  in the same commit. `tests/*fixture*.w` files are compile-only inputs
  whose exact diagnostics are asserted (`expect_stderr`/`reject_stderr`)
  in `build.json`.
- A new end-to-end test needs: `tests/foo_test.w` (use `lib/assert.w` /
  `lib/testing.w`), a target in `build.json`, membership in the `tests`
  umbrella target, and a `tools/test_map.w` entry if no directory rule
  covers it.
- The agent tooling here is dogfooded: if you hit friction or bugs in
  `w check`, `wtest`, the edit hook, `wmcp`, or `wlsp`, add an entry to
  `docs/projects/ai_tooling_next_steps.md` in the same PR.
- Design docs for major features live in `docs/projects/*.md`;
  `docs/todo.txt` tracks the working/missing inventory.
