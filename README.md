# W — a self-hosting systems language and toolchain

W is a small, self-hosting compiled language that started as a fork of Edmund
Grimley Evans' `cc500` C compiler and has since diverged into its own language.
The compiler is written in W (`w.w` plus the modules it imports), compiles
itself, and is bootstrapped from a committed binary seed. It targets 32-bit
x86 and 64-bit x86-64 Linux, emitting ELF executables directly — there is no
assembler, linker, libc, or other external toolchain dependency.

This README is the orientation document for the repository. It is written
primarily for AI agents (and new contributors) who need to understand the
project quickly and make correct changes.

## Quick facts

- **Language style**: C-like semantics with Python-like surface syntax.
  Whitespace-significant, **tabs** for indentation (spaces produce a compiler
  warning), blocks open with `:`, no semicolons, `#` line comments.
- **Compiler architecture**: single-pass, syntax-directed code generation
  (cc500 heritage). There is **no AST and no IR** — grammar rules in
  `grammar/*.w` emit machine-code bytes immediately through
  `code_generator/x86.w` (x64 reuses the same module via REX-prefix helpers).
- **Bootstrap seed**: `./w` at the repo root is a committed, statically linked
  **32-bit x86** ELF binary of the compiler. It runs on x86-64 Linux hosts
  without a 32-bit libc because it is static. Never delete or hand-edit it;
  it is only replaced via `./wbuild update`. `./w_darwin` is its Apple
  Silicon sibling — an ad-hoc-signed **arm64 Mach-O** seed that bootstraps
  the toolchain natively on macOS (`./wbuild build_darwin` /
  `verify_darwin` / `update_darwin`).
- **Output**: static ELF executables by default (x86 via
  `code_generator/elf_32.w`, x86-64 via `elf_64.w`), with DWARF line-number
  info for gdb. Programs declaring `c_lib`/`extern` get PT_INTERP/PT_DYNAMIC
  headers and eager GOT relocations for real dynamic linking against shared
  libraries such as libc (`code_generator/elf_dynamic.w`, `ffi.w`).
- **No package manager, no services**: everything is driven by `./wbuild`,
  a W-native manifest-driven build executor.

## Build, verify, test

The `bin/` output directory is `.gitignore`d; `./wbuild` creates it and
bootstraps everything else it needs from the committed seed (`rm -rf bin`
resets the world).

```sh
./wbuild build    # bootstrap: ./w w.w -> bin/wv2 -> wv3 -> wv4 -> wv5
./wbuild verify   # self-host fixpoint: wv3 == wv4 == wv5 (key regression guard)
./wbuild tests    # full suite: verify, x64 fixpoint, lib/structure/grammar
                  # tests, warnings, REPL, debugger, dynamic linking, hello
./wbuild update   # after verify: archive current seed, promote bin/wv2 to ./w
```

Compile and run an arbitrary program:

```sh
./bin/wv2 file.w -o out && ./out          # 32-bit x86
./bin/wv2 x64 file.w -o out && ./out      # 64-bit x86-64
./bin/wv2 file.w > out && chmod +x out    # without -o, the ELF goes to stdout
```

CLI shape: `w [x64] <file.w>... [-o output]` (see `compiler/compiler.w`).

Other useful targets:

```sh
./wbuild wdbg        # build the in-process debugger (bin/wdbg)
./wbuild verify_x64  # x64 self-host fixpoint (wv2_64 == wv3_64 == wv4_64);
                     # the first cmp also proves output is host-word-size independent
./wbuild warning_test  # asserts the compiler's type/style warnings ("the linter")
./wbuild cuda_smoke  # GPU-only: PTX vector add through libcuda (not part of 'tests')
```

There is no separate linter or formatter. "Lint" is the compiler's own
warnings (type mismatches, spaces-instead-of-tabs, missing trailing newline),
asserted by `./wbuild warning_test`.

`./wbuild` bootstraps `tools/wexec.w` (a manifest-driven executor written
in W) and runs targets from `build.json` — `./wbuild --list` shows them
all. Targets run in parallel (`-j N` to override the CPU-count default)
and toolchain targets are skipped via content-hash caching when their
sources are unchanged (`--no-cache` forces reruns). Design notes in
`docs/projects/wexec.md`.

wexec captures each step's stdout/stderr to check expectations, so it
cannot host a live prompt, a full-screen debugger, or a
serve-until-Ctrl-C process. Those conveniences are one-liners instead of
targets:

```sh
./bin/wv2 repl.w -o bin/repl && ./bin/repl    # interactive REPL prompt
./bin/wv2 x64 graphics/demo.w -o bin/graphics_demo && ./bin/graphics_demo
                                    # demo window (X11); close it to exit,
                                    # or pass --frames N to auto-exit
./bin/wv2 tests/tcp.w -o bin/tcp && ./bin/tcp       # echo server for hand
./bin/wv2 tests/whttp.w -o bin/whttp && ./bin/whttp # testing; Ctrl-C ends
ddd ./bin/<binary>                  # or gdb: debug any freshly built test
sudo stap -e 'probe syscall.write { printf("%s[%d] -> %s(%s)\n", execname(), pid(), name, argstr) }'
                                    # trace write syscalls (swap in
                                    # syscall.socket / syscall.sendto)
rasm2 -a x86 -b 32 -C "mov eax,[esp+4]; jmp eax"    # encoding lookups
```

Host requirement: `dynamic_test` (part of `./wbuild tests`) produces a 32-bit
dynamically linked binary, so the host needs the i386 loader and libc
(`/lib/ld-linux.so.2`; on Debian/Ubuntu:
`sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install -y libc6:i386`).
Everything else, including the seed and the 64-bit dynamic test, works on a
stock x86-64 system.

## Repository layout

| Path | Contents |
|---|---|
| `w` | Committed 32-bit static ELF seed binary of the compiler |
| `w_darwin` | Committed arm64 Mach-O seed (ad-hoc signed) for native macOS bootstrap |
| `w.w` | Compiler entry point (imports `compiler.compiler`, calls `link()`) |
| `compiler/` | Driver, tokenizer, symbol table, type table |
| `grammar/` | One module per grammar rule; parsing and code emission are fused |
| `grammar.w`, `codegen.w` | Umbrella modules that import the grammar/ and code_generator/ trees |
| `code_generator/` | Byte emitter, x86/x64 encoders, ELF32/ELF64 writers, dynamic linking, DWARF |
| `lib/` | Standard library: syscalls, memory, strings, math, format, args, env, process (spawn/pipes/wait/timeouts), the generic `wresult[T]` result type, assert/testing |
| `lib/__arch__/{x86,x64}/` | Per-architecture modules (syscalls, register context, ELF introspection) selected by the reserved `__arch__` import segment |
| `structures/` | hash map, array list, linked list, string builder (+ their tests) |
| `repl.w` | Interactive REPL: compiles each entry into an mmap buffer and calls it; definitions persist |
| `debugger/` | `wdbg`, an in-process SIGTRAP debugger driven by `debugger` statements |
| `tests/` | End-to-end test programs and compile-only warning fixtures |
| `docs/` | Design notes; `docs/projects/` holds larger design docs |
| `wbuild`, `build.json`, `tools/wexec.w` | The build system: W-native manifest-driven executor |
| `archive.sh` | Backs up a seed before `./wbuild update` / `update_darwin` promotes a new one |

## Language snapshot

Implemented and covered by tests:

- Types: `int`, `char`, explicit-width integers through `int32`/`uint32`
  (including the 1-byte built-in `byte` — a type name, so an identifier
  called `byte` breaks at statement position, where `byte = 5` parses as
  a malformed declaration), x64-only `int64`/`uint64`, `bool`, pointers
  (`int*`, `char**`, ...),
  structs with mixed-width fields, by-value struct parameters and returns,
  `type` aliases, `const`, `enum`, `union`, typed function pointers
  (`fn(T, ...) -> U`), fixed local/global/struct arrays (`T[N]`), slices
  (`T[]`), UTF-8 `string`, built-in `map[K, V]`, `set[K]` and growable
  `list[T]` (struct values stored by value; see
  `docs/projects/typed_containers.md`), `new type(args)` constructor-style
  allocation, and `new T[n]` heap arrays.
- Generics: monomorphized generic functions and structs
  (`T max[T](T a, T b)`, `struct pair[T]`) with explicit instantiation
  (`max[int](3, 5)`, `pair[int]`) and call-site type-argument inference
  for functions defined before the call (`max(3, 5)`); see
  `docs/projects/generics.md`.
- Floating point: `float`/`float32` on the default target, `float64` on x64
  (plus x64 float32 narrowing coverage), decimal literals with exponent forms,
  arithmetic/comparisons, int<->float coercions, function parameters/returns,
  fields/pointers, `ftoa`, and x64 `f64toa`.
- Expressions: full C-style operator set — arithmetic, shifts, relational
  (with chaining), equality, bitwise, `&&`/`||`/`!`, unary `+`/`-`, `&`/`*`
  address/deref, compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`, `&=`,
  `|=`, `^=`, `<<=`, `>>=`; integer, float and pointer scalar targets,
  including map index targets `m[k] += v` with the key evaluated once —
  struct targets are rejected), `[]` indexing, typed buffer slicing (`start:end`), struct
  field access, method-call sugar (`p.move()` -> `point_move(&p, ...)`),
  map/set indexing and membership with `in`, counter-style
  `m.add(key)`/`m.add(key, delta)` accumulating integer map values from
  zero for missing keys, `m.keys()`/`m.values()`/`s.keys()`
  insertion-order list snapshots (compose with `list` methods:
  `m.keys().sort()`), `list[T]` indexing,
  `l.push(v)`/`l.pop()` and container `.length`, explicit `cast(T, expr)`,
  postfix `?` error propagation on the generic `wresult[T]` result type
  (unwrap the payload, or return the error to the caller; see
  `docs/error_results.txt`), hex literals (one with bit 31 set
  sign-extends into the word-sized `int` on every target — `0xffffffff`
  is `-1` even on x64, so `x & 0xffffffff` never truncates; build 32-bit
  masks at runtime like `lib/sha256.w`'s `sha256_mask32`), UTF-8 `"..."`
  literals with `\u`/`\U` escapes, and explicit legacy C strings via
  `c"..."`.
- Statements: `if`/`else`, `while`, `for int i in range(start, end, step)`
  (1–3 args), `for x in <container>` over built-in lists/maps/sets and any
  struct-pointer type providing the four cursor functions
  `T_iter_begin/done/next/value` (implemented by `array_list`,
  `linked_list` and `hash_map`, which yields keys; see
  `docs/projects/iteration.md`), `for int cp in string` codepoint iteration,
  `switch`/`case`/`default` (multi-value `case a, b:` clauses, implicit
  break with no fallthrough, `default` last; `break` exits the switch while
  `continue` targets the enclosing loop), `break`, `continue`, `return`,
  `debugger` (emits `int3`), and Go-style `defer <call>` (function-scoped,
  LIFO at every exit; the deferred expression is re-emitted at each exit
  point, so it is evaluated at exit time — see `docs/projects/defer.md`).
- Modules: `import dotted.path` maps to `dotted/path.w`; the reserved
  `__arch__` path segment resolves to `x86` or `x64` per target;
  `__word_size__` is a compile-time constant (4 or 8).
- FFI: `c_lib "libc.so.6"` plus `extern int puts(char* s)` declarations link
  against shared libraries, with per-arch calling-convention shims (cdecl
  re-push on x86, System V registers on x64) that also follow the
  floating-point ABI (xmm args/returns on x64, x87 returns on x86). Variadic
  functions (`extern int printf(char* fmt, ...)`) emit the ABI conversion
  inline per call site with C default argument promotions, and data objects
  (`extern void* stdout`) import via COPY relocations. `c_import "libc.so.6"
  c"/usr/include/stdio.h"` preprocesses, parses, and imports broad libc/system
  headers (tested against `stdio.h`, `stdlib.h`, `unistd.h`, `sys/stat.h`, and
  more on both x86 and x64). See `tests/dynamic_test.w`, `tests/varargs_test.w`,
  `tests/float_abi_test.w`, `tests/extern_data_test.w`,
  `tests/c_import_libc_test.w`, and `tests/cuda_smoke.w`.
- Raw syscalls via `syscall(...)`. The ELF entry stub calls `_main`:
  `lib/lib.w` provides a `_main` that forwards to your `main(argc, argv)`,
  or a program can define `_main` itself and skip the library entirely
  (e.g. `tests/hello.w`).
- Diagnostics: type-mismatch warnings for assignments, initialization,
  arguments, and returns; style warnings for space-indentation and missing
  final newline. `int` is a word-sized scalar, not an untyped word:
  `int` <-> pointer conversions and function-value stores warn unless
  written with the explicit `cast(T, expr)` escape hatch (integer
  literals and `&x` addresses remain untyped for now). The compiler's own
  sources compile warning-free (`./wbuild self_host_warning_test`).

Toolchain beyond the compiler:

- **REPL** (`./bin/wv2 repl.w -o bin/repl && ./bin/repl`): each entry
  compiles into an executable mmap buffer
  and runs immediately. Entries span multiple lines Python-style (a line
  ending in `:` opens a block, a blank line ends it), so functions, structs,
  imports and control flow work at the prompt. Interactive sessions
  auto-indent block bodies (`return`/`break`/`continue`/`pass` dedent, a
  blank line dedents one level); piped input keeps its explicit tabs. Top-level declarations become
  persistent globals; redefining a name shadows the old binding; a bare
  expression echoes its value. `./bin/repl file.w [args...]` compiles and
  runs a program first, then attaches the prompt to its live definitions
  (`--no_main` skips running `main`). Compile errors roll back via
  checkpoint instead of killing the process. `:quit` exits, `:help` helps
  (see `docs/projects/repl.md`).
- **Debugger** (`./wbuild wdbg`, or `w --debug file.w`): `./bin/wdbg file.w`
  compiles and runs the program in-process, trapping on `debugger` statements,
  patched breakpoints and fatal signals into a gdb-flavored command loop:
  `step`/`next`/`stepi`/`finish`, `break function|line|file:line` (+ `tbreak`,
  `delete`), `print` of locals/args/globals by name or of any compiled-on-the-
  fly W expression, `set`, `x`, `backtrace`, `list`, `info locals|args|...`,
  `registers`, `stack`. SIGSEGV and friends stop for post-mortem inspection.
  See `docs/debugging.txt` and the `debug_test` target.

## How the bootstrap works

```
./w w.w        > bin/wv2    # seed compiles current sources
bin/wv2 w.w -o bin/wv3      # wv2 recompiles the sources
bin/wv3 w.w -o bin/wv4
bin/wv4 w.w -o bin/wv5
cmp wv3 wv4 && cmp wv4 wv5  # fixpoint: ./wbuild verify
```

`./wbuild verify` is the cheapest strong regression guard for compiler
changes: if the compiler still compiles itself to a byte-identical fixpoint,
most codegen regressions are ruled out. `./wbuild verify_x64` does the same
for the 64-bit target, starting from the x86-hosted `wv2` (`bin/wv2 x64 w.w`),
so its first comparison also proves output does not depend on the host word
size. Only run `./wbuild update` (which replaces the seed) after `verify`
passes; it archives the old seed to `old/` first.

## Guidance for agents making changes

- Run `./wbuild verify` after any compiler/grammar/codegen change and
  `./wbuild tests` before considering work done. A change that breaks
  self-hosting can pass individual tests while corrupting the bootstrap.
- W source is tab-indented. Editing `.w` files with spaces introduces
  warnings that `warning_test` (and the clean-fixture check) will catch.
- Because codegen is single-pass with no IR, grammar modules both parse and
  emit; changes to expression/statement handling usually live in
  `grammar/*.w`, while instruction encoding and ELF layout live in
  `code_generator/*.w`.
- Some conveniences need tools that are not required for build/test and may
  be absent: `gdb`/`ddd` (hand-debugging a built binary), `radare2` (`rasm2`
  encoding lookups), `systemtap` with sudo (syscall-trace one-liners), an
  NVIDIA GPU + driver
  (`cuda_smoke`). `threading_test` covers the basic x86 thread path, but the
  threading modules are still not production-grade and are not covered by the
  x64 test gate.

## Tooling for agents

- Use `./bin/wv2 check --json file.w` for compile-only diagnostics without
  writing an ELF. Add `x64` after `--json` for the 64-bit target. Output is
  newline-delimited JSON on stdout with `file`, `line`, `column`, `severity`,
  `message`, `token`, and `arch`; stderr keeps the usual human progress text.
- `w check` reports all warnings reached before the first error, then stops at
  that first error. Multi-error recovery remains out of scope for the
  single-pass compiler.
- Use `./bin/wv2 symbols --json file.w` to dump declaration metadata for
  go-to-definition and indexing: one NDJSON record per user-declared symbol
  (functions, globals, enum values) and type (structs, unions, enums, aliases)
  with `name`, `kind`, `type`, `file`, `line`, `column`, and `arch` (structs
  and unions also carry a `fields` array of `{name, type, offset}`). Omit
  `--json` for a human-readable `file:line:column: kind name: type` listing.
  Compiler-internal declarations without a source location are skipped.
- Use `./wbuild test_changed` to run focused tests for files changed from
  `HEAD`, or call `./bin/wtest changed file...` to list the selected build
  targets without running them. Docs-only changes produce no targets; unknown
  paths fall back to `tests`.
- Agent-facing guidance is committed alongside the code: `.cursor/skills/`
  holds step-by-step skills (`w-check-diagnostics`, `w-select-tests`,
  `w-debug-wdbg`, `w-repl-explore`) and `.cursor/rules/` holds path-scoped
  rules for W sources, the seed-compiled compiler tree, and tests/fixtures.
- The tooling backlog lives in `docs/projects/ai_tooling_next_steps.md`.
  Agents that hit friction or bugs while using the tooling are expected to
  record them there (`.cursor/rules/ai-tooling-feedback.mdc` makes this an
  always-on rule), and to move entries into `docs/projects/ai_tooling.md`'s
  status section when implemented.
- The editor/agent integration layer built on these surfaces — the LSP
  server (`wlsp`), the `w-toolchain`/`w-index`/`w-debug` MCP servers, the
  semantic index (`windex`/`windexd`), and the post-edit check hook
  (`whook`) — moved out of this repo in July 2026 to keep it focused on
  the core compiler/toolchain. Those tools still consume this repo's
  stable surfaces (`w check --json`, `w symbols --json`, `bin/wtest`,
  `bin/wdbg`, `./wbuild`) and run with cwd = a checkout of this repo.
- `./wbuild verify` remains the required gate for compiler changes, and
  `./wbuild tests` remains the full pre-merge suite when the host has the
  i386 libc needed by `dynamic_test`.

## Current major open areas

- Generics polish — explicit instantiation (`max[int](a, b)`) and
  call-site type-argument inference (`max(a, b)`) are implemented
  (`docs/projects/generics.md`); remaining: inference for forward calls
  and generic struct constructors, binding through container/struct
  shapes (`pair[T]*`, `list[T]`), and struct-by-value returns on
  inferred calls.
- CUDA backend Stage 2, the PTX emitter — Stages 0–1 (x64 self-hosting and
  dynamic linking to libcuda) are done; see `docs/projects/cuda.md`.
- REPL line editing/history.
- Debugger: locals inside evaluated expressions, watchpoints, a web UI
  (stepping, breakpoints, variable inspection, expression evaluation at a
  breakpoint and `w --debug` are done).
- Import-scoped type metadata.
- WebAssembly backend.

See `docs/todo.txt` for the running working/missing inventory and
`docs/done.txt` for history.
