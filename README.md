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
  it is only replaced via `make update`.
- **Output**: static ELF executables by default (x86 via
  `code_generator/elf_32.w`, x86-64 via `elf_64.w`), with DWARF line-number
  info for gdb. Programs declaring `c_lib`/`extern` get PT_INTERP/PT_DYNAMIC
  headers and eager GOT relocations for real dynamic linking against shared
  libraries such as libc (`code_generator/elf_dynamic.w`, `ffi.w`).
- **No package manager, no services**: everything is driven by `make`.

## Build, verify, test

The `bin/` output directory is `.gitignore`d and Make targets do **not**
create it — run `mkdir -p bin` first if it is missing (a redirection or
`chmod` error like `bin/wv2: No such file or directory` means it is missing).

```sh
mkdir -p bin
make build       # bootstrap: ./w w.w -> bin/wv2 -> wv3 -> wv4 -> wv5
make verify      # self-host fixpoint: wv3 == wv4 == wv5 (key regression guard)
make tests       # full suite: verify, x64 fixpoint, lib/structure/grammar
                 # tests, warnings, REPL, debugger, dynamic linking, hello
make update      # after verify: archive current seed, promote bin/wv2 to ./w
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
make repl        # build and launch the interactive REPL (bin/repl)
make wdbg        # build the in-process debugger (bin/wdbg)
make verify_x64  # x64 self-host fixpoint (wv2_64 == wv3_64 == wv4_64);
                 # the first cmp also proves output is host-word-size independent
make warning_test  # asserts the compiler's type/style warnings ("the linter")
make cuda_smoke  # GPU-only: PTX vector add through libcuda (not part of 'tests')
```

There is no separate linter or formatter. "Lint" is the compiler's own
warnings (type mismatches, spaces-instead-of-tabs, missing trailing newline),
asserted by `make warning_test`.

Host requirement: `dynamic_test` (part of `make tests`) produces a 32-bit
dynamically linked binary, so the host needs the i386 loader and libc
(`/lib/ld-linux.so.2`; on Debian/Ubuntu:
`dpkg --add-architecture i386 && apt-get install libc6:i386`). Everything
else, including the seed and the 64-bit dynamic test, works on a stock
x86-64 system.

## Repository layout

| Path | Contents |
|---|---|
| `w` | Committed 32-bit static ELF seed binary of the compiler |
| `w.w` | Compiler entry point (imports `compiler.compiler`, calls `link()`) |
| `compiler/` | Driver, tokenizer, symbol table, type table |
| `grammar/` | One module per grammar rule; parsing and code emission are fused |
| `grammar.w`, `codegen.w` | Umbrella modules that import the grammar/ and code_generator/ trees |
| `code_generator/` | Byte emitter, x86/x64 encoders, ELF32/ELF64 writers, dynamic linking, DWARF |
| `lib/` | Standard library: syscalls, memory, strings, math, format, args, assert/testing |
| `lib/__arch__/{x86,x64}/` | Per-architecture modules (syscalls, register context, ELF introspection) selected by the reserved `__arch__` import segment |
| `structures/` | hash map, array list, linked list, string builder (+ their tests) |
| `repl.w` | Interactive REPL: compiles each line into an mmap buffer and calls it |
| `debugger/` | `wdbg`, an in-process SIGTRAP debugger driven by `debugger` statements |
| `tests/` | End-to-end test programs and compile-only warning fixtures |
| `docs/` | Design notes; `docs/projects/` holds larger design docs |
| `Makefile` | All build/test/run entry points |
| `archive.sh` | Backs up the seed before `make update` promotes a new one |

## Language snapshot

Implemented and covered by tests:

- Types: `int`, `char`, pointers (`int*`, `char**`, ...), structs with mixed-width
  fields, by-value struct parameters, `new type(args)` constructor-style allocation.
- Expressions: full C-style operator set — arithmetic, shifts, relational
  (with chaining), equality, bitwise, `&&`/`||`/`!`, unary `+`/`-`, `&`/`*`
  address/deref, `[]` indexing, struct field access, hex literals, string
  escapes (`\x0a` style).
- Statements: `if`/`else`, `while`, `for int i in range(start, end, step)`
  (1–3 args), `break`, `continue`, `return`, `debugger` (emits `int3`).
- Modules: `import dotted.path` maps to `dotted/path.w`; the reserved
  `__arch__` path segment resolves to `x86` or `x64` per target;
  `__word_size__` is a compile-time constant (4 or 8).
- FFI: `c_lib "libc.so.6"` plus `extern int puts(char* s)` declarations link
  against shared libraries, with per-arch calling-convention shims (cdecl
  re-push on x86, System V registers on x64). See `tests/dynamic_test.w` and
  `tests/cuda_smoke.w`.
- Raw syscalls via `syscall(...)`. The ELF entry stub calls `_main`:
  `lib/lib.w` provides a `_main` that forwards to your `main(argc, argv)`,
  or a program can define `_main` itself and skip the library entirely
  (e.g. `tests/hello.w`).
- Diagnostics: type-mismatch warnings for assignments, initialization,
  arguments, and returns; style warnings for space-indentation and missing
  final newline.

Toolchain beyond the compiler:

- **REPL** (`make repl`): each line compiles as the body of a fresh anonymous
  function into an executable mmap buffer and runs immediately; compile errors
  roll back via checkpoint instead of killing the process. Known limitation:
  locals do not persist between lines. `:quit` exits.
- **Debugger** (`make wdbg`, or `w --debug file.w`): `./bin/wdbg file.w`
  compiles and runs the program in-process, trapping on `debugger` statements,
  patched breakpoints and fatal signals into a gdb-flavored command loop:
  `step`/`next`/`stepi`/`finish`, `break function|line|file:line` (+ `tbreak`,
  `delete`), `print` of locals/args/globals by name or of any compiled-on-the-
  fly W expression, `set`, `x`, `backtrace`, `list`, `info locals|args|...`,
  `registers`, `stack`. SIGSEGV and friends stop for post-mortem inspection.
  See `docs/debugging.txt` and `debug_test` in the Makefile.

## How the bootstrap works

```
./w w.w        > bin/wv2    # seed compiles current sources
bin/wv2 w.w -o bin/wv3      # wv2 recompiles the sources
bin/wv3 w.w -o bin/wv4
bin/wv4 w.w -o bin/wv5
cmp wv3 wv4 && cmp wv4 wv5  # fixpoint: make verify
```

`make verify` is the cheapest strong regression guard for compiler changes:
if the compiler still compiles itself to a byte-identical fixpoint, most
codegen regressions are ruled out. `make verify_x64` does the same for the
64-bit target, starting from the x86-hosted `wv2` (`bin/wv2 x64 w.w`), so its
first comparison also proves output does not depend on the host word size.
Only run `make update` (which replaces the seed) after `verify` passes; it
archives the old seed to `old/` first.

## Guidance for agents making changes

- Run `make verify` after any compiler/grammar/codegen change and `make tests`
  before considering work done. A change that breaks self-hosting can pass
  individual tests while corrupting the bootstrap.
- W source is tab-indented. Editing `.w` files with spaces introduces
  warnings that `warning_test` (and the clean-fixture check) will catch.
- Because codegen is single-pass with no IR, grammar modules both parse and
  emit; changes to expression/statement handling usually live in
  `grammar/*.w`, while instruction encoding and ELF layout live in
  `code_generator/*.w`.
- Optional targets need tools that are not required for build/test and may be
  absent: `gdb`/`ddd` (`*_debug`), `radare2` (`asm_codegen_get_context`),
  `systemtap` with sudo (`net_log*`, `log_write`), an NVIDIA GPU + driver
  (`cuda_smoke`). The threading modules are known to be in poor shape.

## Current major open areas

- `for x in <container>` iteration and generators — design in
  `docs/projects/iteration.md` (nothing implemented yet).
- CUDA backend Stage 2, the PTX emitter — Stages 0–1 (x64 self-hosting and
  dynamic linking to libcuda) are done; see `docs/projects/cuda.md`.
- REPL local persistence between entries.
- Debugger: locals inside evaluated expressions, watchpoints, a web UI
  (stepping, breakpoints, variable inspection and `w --debug` are done).
- Import-scoped type metadata.
- WebAssembly backend.

See `docs/todo.txt` for the running working/missing inventory and
`docs/done.txt` for history.
