# AGENTS.md

## Cursor Cloud specific instructions

This repo is a **self-hosting compiler + toolchain for the "W" language** (a heavily
extended fork of the `cc500` C compiler). There are **no long-running services** and
**no package manager** — everything is driven by `make` and bootstrapped from the
committed 32-bit x86 ELF seed binary `./w`.

### Build / test / run
Standard commands live in the `Makefile` (targets, not duplicated here):
- `make build` — bootstrap the compiler (`bin/wv2..wv5`).
- `make verify` — self-host fixpoint check (`wv3 == wv4 == wv5`); the key regression guard.
- `make tests` — full suite (includes `verify`, x64 tests, REPL, debugger, stdlib, structures).
- `make repl` — build and launch the interactive REPL (`bin/repl`).
- `make wdbg` — build the in-process debugger (`bin/wdbg`).

A W-native build path (`./wbuild`, backed by `tools/wexec.w` + `build.json`;
see `docs/projects/wexec.md`) is replacing the Makefile. It covers the full
test suite (`./wbuild tests`, target list via `./wbuild --list`), runs
independent targets in parallel (`-j N` overrides the CPU-count default) and
content-hash-caches the toolchain targets (`--no-cache` forces reruns; stamps
live in `bin/.wexec_cache/`). Only non-test conveniences (`update`,
`test_changed`, debug/trace targets) still need `make`.

Compile/run an arbitrary program directly:
`./bin/wv2 file.w -o out && ./out` (prepend `x64` for 64-bit: `./bin/wv2 x64 file.w -o out`).

### Tooling for agents — the standard edit loop
Use the toolchain's structured tools instead of raw compile/test cycles:

1. **After editing a `.w` file**, check it without producing a binary:
   `./bin/wv2 check --json <file>` (add `x64` after `--json` for 64-bit). Empty
   stdout + exit 0 = clean. Fix **warnings too** — the self-host build stages
   compile with `--strict`, so warnings fail `make build`. Compiler-tree modules
   (`compiler/`, `grammar/`, `code_generator/`) don't compile standalone; check
   `w.w` instead. A committed `postToolUse` hook (`.cursor/hooks.json` →
   `tools/hooks/w_check_hook.w`) runs this check automatically after every `.w`
   edit and injects the diagnostics into the conversation — treat that feedback
   as authoritative.
2. **Pick tests from the diff**, don't guess:
   `git diff --name-only HEAD | ./bin/wtest changed` prints the focused Makefile
   targets (`make wtest` builds it; `make test_changed` runs them directly).
   Compiler changes always get `verify` (+ `verify_x64` for codegen/word-size
   work); docs map to nothing; unknown paths fall back to `tests`.
3. **Before declaring work done**, run the full suite: `make tests` or
   `./wbuild tests`.
4. **Find declarations** with `./bin/wv2 symbols --json <file>` (functions,
   globals, types with file/line/column) instead of grepping, **answer
   language-behavior questions** by piping entries + `:quit` into `./bin/repl`,
   and **debug runtime failures** by scripting `./bin/wdbg` over stdin rather
   than adding print statements.

Detailed how-tos live in `.cursor/skills/` (`w-check-diagnostics`,
`w-select-tests`, `w-debug-wdbg`, `w-repl-explore`); path-scoped guardrails in
`.cursor/rules/`. The `w-toolchain` MCP server (`make wmcp`, registered in
`.cursor/mcp.json`) exposes build/verify/run_tests/check/compile/run/repl_eval/
test_changed as tools for the Cursor IDE; Cloud Agents do not load repo
`mcp.json` files, so in cloud use the equivalent shell commands (or register
the server in the Cloud Agents dashboard).

### Non-obvious gotchas
- The `bin/` output directory is `.gitignore`d. `make build`, the tool targets
  (`wtest`, `wmcp`, `wlsp`, `whook`) and `./wbuild` create it, but most other
  one-off Make targets do **not**. If you see a redirection/`chmod` failure like
  `bin/wv2: No such file or directory`, run `mkdir -p bin` (or `make build`) first.
- There is **no separate linter**. "Lint" is the compiler's own type/style warnings,
  asserted by the `warning_test` target.
- The seed `./w` is a **32-bit x86** statically-linked ELF; it runs on this x86_64 host
  without extra libc because it's static. Do not delete/replace it except via `make update`.
- W source is whitespace-significant: **tabs** for indentation (spaces trigger a warning),
  no semicolons, `#` line comments, blocks open with `:`.
- Built-in containers (`map[K, V]`, `set[K]`, `list[T]`) lower to runtime helpers in
 `structures/hash_table.w` and `structures/w_list.w`, which the compiler **auto-imports
 into every program** (`import_module` calls in `compiler/compiler.w`). Those runtime
 files — like everything under `compiler/`, `grammar/`, and `code_generator/` — are
 compiled by the committed seed, so they must not use new language syntax until a seed
 update via `make update`. New syntax is fine in `tests/`, `lib/`, and other consumers
 once `bin/wv2` is built. Design notes: `docs/projects/typed_containers.md`.
- When adding language syntax, also extend the parser-generator grammar
 `tests/parser_generator/w.pg`: the `parser_generator_w_test` target parses **every
 tracked `.w` file** with a parser generated from that grammar and fails on syntax it
 does not know.
- Optional debug/trace targets need tools that are **not installed** and are not required
 for build/test: `gdb`/`ddd` (`*_debug` targets), `radare2` (`asm_codegen_get_context`),
 `systemtap`/`stap` with sudo (`net_log*`, `log_write`).
- `make tests` includes `dynamic_test`, which produces a **32-bit dynamically linked**
 binary and needs the i386 loader/libc (`/lib/ld-linux.so.2`, `libc6:i386`). In the
 Cursor Cloud environment this is **baked into the VM snapshot** (installed once during
 environment setup), so `make tests` runs out of the box; the minimal update script
 intentionally does not reinstall it (an apt step on every startup would be a network
 dependency and a reliability risk). If you ever hit `./bin/dynamic_test: not found`
 (loader missing, e.g. on a non-snapshot host), install it per the README
 (`sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install -y libc6:i386`).
 `make build` and `make verify` do not require it.
- ARM64 backend work needs `qemu-user-static` so ARM64 W-compiler test binaries can
  run under `qemu-aarch64`; `binutils-aarch64-linux-gnu` is also useful for
  disassembly during development. Like the i386 dynamic-test support, this should be
  baked into the Cursor Cloud VM snapshot rather than installed ad hoc by agents. If
  those tools are missing, run an env setup agent from Cursor web at
  https://cursor.com/onboard with a prompt such as: "Install qemu-user-static and
  binutils-aarch64-linux-gnu via apt into the snapshot so ARM64 W-compiler test
  binaries can run under qemu-aarch64, mirroring how libc6:i386 is baked in for
  dynamic_test."
