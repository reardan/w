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

Compile/run an arbitrary program directly:
`./bin/wv2 file.w -o out && ./out` (prepend `x64` for 64-bit: `./bin/wv2 x64 file.w -o out`).

### Non-obvious gotchas
- The `bin/` output directory is `.gitignore`d and Make targets do **not** create it.
  It must exist before building (the update script runs `mkdir -p bin`). If you ever see
  a redirection/`chmod` failure like `bin/wv2: No such file or directory`, run `mkdir -p bin`.
- There is **no separate linter**. "Lint" is the compiler's own type/style warnings,
  asserted by the `warning_test` target.
- The seed `./w` is a **32-bit x86** statically-linked ELF; it runs on this x86_64 host
  without extra libc because it's static. Do not delete/replace it except via `make update`.
- W source is whitespace-significant: **tabs** for indentation (spaces trigger a warning),
  no semicolons, `#` line comments, blocks open with `:`.
- Optional debug/trace targets need tools that are **not installed** and are not required
 for build/test: `gdb`/`ddd` (`*_debug` targets), `radare2` (`asm_codegen_get_context`),
 `systemtap`/`stap` with sudo (`net_log*`, `log_write`).
- `make tests` includes `dynamic_test`, which produces a **32-bit dynamically linked**
 binary and needs the i386 loader/libc (`/lib/ld-linux.so.2`, `libc6:i386`). This is
 preinstalled in the Cursor Cloud snapshot; if the loader is missing, `dynamic_test`
 fails with `./bin/dynamic_test: not found` — install it per the README
 (`sudo dpkg --add-architecture i386 && sudo apt-get install -y libc6:i386`). `make build`
 and `make verify` do not require it.
