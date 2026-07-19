# AGENTS.md

## Cursor Cloud specific instructions

This repo is a **self-hosting compiler + toolchain for the "W" language** (a heavily
extended fork of the `cc500` C compiler). There are **no long-running services** and
**no package manager** — everything is driven by `./wbuild` and bootstrapped from the
pinned 32-bit x86 ELF seed binary `./w`, which `./wbuild` downloads from GitHub
Releases per the sha256 pins in `SEEDS` when it is missing.

### Build / test / run
Standard commands live in `build.json` (targets, not duplicated here):
- `./wbuild build` — bootstrap the compiler (`bin/wv2..wv5`).
- `./wbuild verify` — self-host fixpoint check (`wv3 == wv4 == wv5`); the key regression guard.
- `./wbuild tests` — full suite (includes `verify`, x64 tests, REPL, debugger, stdlib, structures).
- `./wbuild wdbg` — build the in-process debugger (`bin/wdbg`).
- `./bin/wv2 repl.w -o bin/repl && ./bin/repl` — build and launch the interactive REPL.

`./wbuild` is backed by `tools/wexec.w` + `build.json` (see
`docs/projects/wexec.md`): target list via `./wbuild --list`, independent
targets run in parallel (`-j N` overrides the CPU-count default), toolchain
targets are content-hash-cached (`--no-cache` forces reruns; stamps live in
`bin/.wexec_cache/`, `rm -rf bin` resets everything). `build.json` is
generated, not hand-edited: `./wbuild manifest` rebuilds it from the
hand-maintained `build.base.json` plus every conventional `*_test.w`
source (a `# wbuild: x64` directive in the source adds the 64-bit twin),
and `./wbuild manifest_check` (in `tests`) fails on drift. To add a plain
test: create the `_test.w` file and run `./wbuild manifest`; only tests
with irregular steps or expectations get hand-written targets in
`build.base.json`. Interactive
conveniences (debuggers, `stap` traces, hand-testing servers) are manual
one-liners, listed in README's "Build, verify, test" section — wexec
captures step stdio, so it cannot host a live prompt or a
serve-until-Ctrl-C process.

Compile/run an arbitrary program directly:
`./bin/wv2 file.w -o out && ./out` (prepend `x64` for 64-bit: `./bin/wv2 x64 file.w -o out`).

### Tooling for agents — the standard edit loop
Use the toolchain's structured tools instead of raw compile/test cycles:

1. **After editing a `.w` file**, check it without producing a binary:
   `./bin/wv2 check --json <file>` (add `x64` after `--json` for 64-bit). Empty
   stdout + exit 0 = clean. Fix **warnings too** — the self-host build stages
   compile with `--strict`, so warnings fail `./wbuild build`. Compiler-tree modules
   (`compiler/`, `grammar/`, `code_generator/`) don't compile standalone; check
   `w.w` instead. (An automatic post-edit check hook built on this surface
   is maintained with the external integration tools, out of this repo.)
2. **Pick tests from the diff**, don't guess:
   `git diff --name-only HEAD | ./bin/wtest changed` prints the focused build
   targets (`./wbuild wtest` builds it; `./wbuild test_changed` runs them directly).
   Selection is manifest-driven: wtest parses `build.json` and unions targets
   whose steps name a changed path with targets whose compile roots
   transitively import a changed `.w` file (`bin/wv2 deps` closures, cached
   in `bin/.wtest_deps_cache` — first run after a build ~35s, then
   sub-second), plus residue rules documented in `tools/test_map.w`.
   Compiler changes always get `verify` (+ `verify_x64` for codegen/word-size
   work); every existing `.w` change gets `parser_generator_w_test`; deleted
   `.w` files and `lib/`/`structures/`/`libs/` paths get `metadata_check`;
   docs map to nothing; paths nothing knows about fall back to `tests`.
   **Reviewing a commit range instead of the worktree?**
   `bin/wtest changed A..B` (or `A...B`, or `A..` for "`A` versus the
   worktree") takes a git revision range in place of the path list —
   any single argument containing `..` is treated as one, since no
   tracked path here ever contains `..`. The file list itself comes from
   `git diff --no-renames --name-only`, so a rename reads as an ordinary
   delete-then-add pair; add `--defhash` to compare `git show A:<path>`
   against `git show B:<path>` (or the worktree) instead of HEAD versus
   the worktree. A bare revision with no dots is never auto-detected
   (indistinguishable from a path) — spell it `A..`. No range argument
   is byte-identical to the plain path-list behavior above.
   **Editing a file compiled under more than one arch** (e.g.
   `tools/wexec.w`: default `x86`, `win64`, `arm64_darwin`)? A plain
   `w check` only proves the default target — `bin/wtest archs <file>`
   lists every `(arch, root)` pair the file's closure is compiled under
   (with the owning target(s)), and `bin/wtest archs <file> --check` runs
   `bin/wv2 [arch] check <root>` per pair, so an arch-only import gap
   (e.g. a `lib/__arch__/` module missing its `win64` counterpart) shows
   up immediately instead of at that target's next full build.
3. **Before declaring work done**, run the full suite: `./wbuild tests`.
4. **Find declarations** with `./bin/wv2 symbols --json <file>` (functions,
   globals, types with file/line/column) instead of grepping, **answer
   language-behavior questions** by piping entries + `:quit` into `./bin/repl`,
   and **debug runtime failures** by scripting `./bin/wdbg` over stdin rather
   than adding print statements.

Detailed how-tos live in `.cursor/skills/` (`w-check-diagnostics`,
`w-select-tests`, `w-debug-wdbg`, `w-repl-explore`); path-scoped guardrails in
`.cursor/rules/`. The editor/agent integration layer built on these surfaces
(the `w-toolchain`/`w-index`/`w-debug` MCP servers, the `wlsp` LSP server,
the `windex` semantic index, and the post-edit check hook) moved out of
this repo in July 2026 — use the shell commands above directly when
working in this repo.

### Non-obvious gotchas
- The `bin/` output directory is `.gitignore`d; `./wbuild` creates it itself.
  If you see a redirection/`chmod` failure like
  `bin/wv2: No such file or directory` from a hand-run compile, run
  `mkdir -p bin` (or `./wbuild build`) first.
- There is **no separate linter**. "Lint" is the compiler's own type/style warnings,
  asserted by the `warning_test` target. Compile-diagnostic fixtures carry their
  expected messages as `# expect_stderr:`-style directive lines in their own header
  comments, run by `bin/wfixture` (`tools/wfixture.w`); see the header of that tool
  for the directive syntax.
- The seed `./w` is a **32-bit x86** statically-linked ELF; it runs on this x86_64 host
  without extra libc because it's static. It is not committed: `./wbuild` downloads it
  (sha256-verified) from the GitHub release pinned in `SEEDS`. Do not hand-edit it;
  `./wbuild update` (and `update_darwin` for the macOS seed `./w_darwin`) promotes a
  locally built fixpoint for local iteration only. Publishing a promotion = cut a release,
  then bump **every** `SEEDS` line to that tag in one PR (`docs/release.md`) — the
  single-tag pin is what keeps the seeds compiling the same sources (the old
  "refresh both seeds in the same PR" rule, see #128/#129, is now enforced by the format).
- W source is whitespace-significant: **tabs** for indentation (spaces trigger a warning),
  no semicolons, `#` line comments, blocks open with `:`.
- Expression gotchas: `|`/`&` are bitwise and do **not** short-circuit — a
 guarded expression like `i < n & buf[i]` still evaluates `buf[i]`; use
 `&&`/`||`. A hex literal with bit 31 set sign-extends into the word-sized
 `int` on **every** target (`0xffffffff` is `-1` even on x64, so
 `x & 0xffffffff` is a no-op, never a truncation; build 32-bit masks at
 runtime — `lib/sha256.w`'s `sha256_mask32` pattern, header comment has the
 full discipline). `byte` is a built-in 1-byte type, so an identifier named
 `byte` breaks at statement position (`byte = 5` parses as a malformed
 declaration) — don't use it as a variable/field name. `T* + int` stays a
 raw byte offset but keeps the pointer's type: `*(p + n)` / `(p + n)[i]`
 read at the element's width, and assigning the result to an `int` needs
 an explicit `cast(int, ...)`.
- Built-in containers (`map[K, V]`, `set[K]`, `list[T]`) lower to runtime helpers in
 `structures/hash_table.w` and `structures/w_list.w`, which the compiler **auto-imports
 into every program** (`import_module` calls in `compiler/compiler.w`). Those runtime
 files — like everything under `compiler/`, `grammar/`, `code_generator/`, `debugger/`,
 and `libs/extras/{c_import,c_preprocessor,parser_generator}` (pulled in by the compiler's
 C-import feature), plus any `lib/` file those import — are compiled by the pinned
 seed, so they must not use new language syntax until `SEEDS` is bumped to a release
 whose binaries include that syntax (`docs/release.md`; a local `./wbuild update` does
 not change what other checkouts or CI bootstrap from). New syntax is fine in `tests/`
 and other leaf consumers once `bin/wv2` is built. Design notes:
 `docs/projects/typed_containers.md`.
- When adding language syntax, also extend the parser-generator grammar
 `tests/parser_generator/w.pg`: the `parser_generator_w_test` target parses **every
 tracked `.w` file** with a parser generated from that grammar and fails on syntax it
 does not know.
- The optional debug/trace one-liners need tools that are **not installed** and are not
 required for build/test: `gdb`/`ddd` (hand-debugging a built binary), `radare2`
 (`rasm2` encoding lookups), `systemtap`/`stap` with sudo (syscall-trace one-liners).
- `./wbuild tests` includes targets whose binaries are **32-bit dynamically linked**
 and need the i386 loader/libc (`/lib/ld-linux.so.2`, `libc6:i386`): `dynamic_test`,
 `c_import_test`, `c_import_errno_test`, `c_import_libc_test`, `float_abi_test`,
 `varargs_test`, and `extern_data_test`. In the
 Cursor Cloud environment this is **baked into the VM snapshot** (installed once during
 environment setup), so `./wbuild tests` runs out of the box; the minimal update script
 intentionally does not reinstall it (an apt step on every startup would be a network
 dependency and a reliability risk). If you ever hit `./bin/dynamic_test: not found`
 (loader missing, e.g. on a non-snapshot host), install it per the README
 (`sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install -y libc6:i386`).
 `./wbuild build` and `./wbuild verify` do not require it.
- ARM64 backend work needs `qemu-user-static` so ARM64 W-compiler test binaries can
 run under `qemu-aarch64`. For disassembly during development, use the in-house A64
 disassembler in `libs/asm/` (`asm_arm64_decode` + `asm_arm64_format`; see
 `docs/projects/assembler_disassembler.md`) rather than `binutils-aarch64-linux-gnu`
 — it decodes the full compiler output with zero unknown opcodes host-side, no cross
 toolchain required. Like the i386 dynamic-test support, qemu should be baked into
 the Cursor Cloud VM snapshot rather than installed ad hoc by agents. If it is
 missing, run an env setup agent from Cursor web at https://cursor.com/onboard with a
 prompt such as: "Install qemu-user-static via apt into the snapshot so ARM64
 W-compiler test binaries can run under qemu-aarch64, mirroring how libc6:i386 is
 baked in for dynamic_test."
- The win64 PE backend (`docs/projects/windows.md`) needs `wine` to run its test
 binaries (`./wbuild tests_win64`; the win64_header_test
 structural check works without it). Like qemu for ARM64, wine should be baked
 into the Cursor Cloud VM snapshot rather than installed ad hoc; if it is missing,
 run an env setup agent from Cursor web at https://cursor.com/onboard with a
 prompt such as: "Install wine (wine64) via apt into the snapshot so win64
 W-compiler test binaries (PE32+ .exe) can run under Wine, mirroring how
 qemu-user-static is baked in for the ARM64 tests."
