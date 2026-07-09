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

**Platform**: the seed is a Linux binary, so the toolchain itself needs
Linux. On this macOS checkout, run every build/test command inside the
`w-dev` Docker container via `tools/mac/wdev.sh` (e.g.
`tools/mac/wdev.sh make verify`; one-time container setup is documented in
that script's header). The repo is bind-mounted at `/w`, so `bin/`
artifacts appear on the host. `arm64_darwin` Mach-O binaries are
cross-compiled in the container, then signed and run natively on the Mac
with `tools/mac/run_darwin_tests.sh`. On Linux hosts everything runs
directly (`dynamic_test` additionally needs `libc6:i386`).

## Commands

```sh
make build       # bootstrap: ./w w.w -> bin/wv2 -> wv3 -> wv4 -> wv5
make verify      # self-host fixpoint (wv3==wv4==wv5) — REQUIRED gate for any compiler change
make verify_x64  # same for the 64-bit target; run for codegen/word-size work
make verify_arm64  # same for the ARM64 target
make tests       # full pre-merge suite
make update      # ONLY after verify: archives seed, promotes bin/wv2 to ./w
make repl        # interactive REPL (bin/repl)
make wdbg        # in-process debugger (bin/wdbg file.w)
```

`./wbuild` is the W-native alternative to make (`./wbuild tests`,
`./wbuild --list`; parallel + content-hash cached, `--no-cache` to force).

Compile and run one program: `./bin/wv2 file.w -o out && ./out`
(insert `x64` before the file for 64-bit).

**Run a single/focused test**: `git diff --name-only HEAD | ./bin/wtest changed`
prints the exact Makefile targets for your diff (build wtest with `make wtest`);
`make test_changed` runs them. Don't guess targets.

**Check without compiling to a binary**: `./bin/wv2 check --json file.w`
(NDJSON diagnostics; empty stdout + exit 0 = clean). Fix warnings, not just
errors — self-host stages build with `--strict`, so any warning fails
`make build`. There is no separate linter; the compiler's warnings are the
lint, asserted by `make warning_test`.

**Find declarations**: `./bin/wv2 symbols --json file.w` instead of grepping.

Gotcha: `bin/` is gitignored and many one-off make targets don't create it —
run `mkdir -p bin` (or `make build`) first if you see
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
  equality of wv3/wv4/wv5 (`make verify`) is the cheapest strong regression
  guard. A change can pass unit tests while corrupting self-hosting.
- **Seed constraint**: `w.w`, `grammar.w`, `codegen.w`, `compiler/`,
  `grammar/`, `code_generator/`, and the auto-imported container runtime
  (`structures/hash_table.w`, `structures/w_list.w`) are compiled by the
  committed seed, so they must not use language syntax newer than the seed
  until `make update` promotes one. New syntax is fine in `tests/`, `lib/`,
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
  whose exact diagnostics are grep-asserted in the Makefile.
- A new end-to-end test needs: `tests/foo_test.w` (use `lib/assert.w` /
  `lib/testing.w`), a Makefile target, the same target in `build.json`,
  membership in the `tests` umbrella in both, and a `tools/test_map.w`
  entry if no directory rule covers it.
- The agent tooling here is dogfooded: if you hit friction or bugs in
  `w check`, `wtest`, the edit hook, `wmcp`, or `wlsp`, add an entry to
  `docs/projects/ai_tooling_next_steps.md` in the same PR.
- Design docs for major features live in `docs/projects/*.md`;
  `docs/todo.txt` tracks the working/missing inventory.
