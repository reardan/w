# LLVM offload (#337)

`bin/wllvm` is an opt-in LLVM backend over the production compiler's
retained AST. A visitor walks the semantic forest the normal front end
already builds and emits LLVM IR text; for an executable it hands that IR
to clang, which produces a freestanding x86-64 Linux binary. The production
parser and semantic analyzer remain the source of truth: the tool adds no
second W parser or type checker and does not use the parser-generator
grammar. The original proposal and dependency tradeoffs are recorded in
[compilation_model.md §3](compilation_model.md#3-337-llvm-offload).

## Build and run

```sh
./wbuild wllvm
bin/wllvm program.w -o bin/program          # executable, clang -O2
bin/wllvm -O3 program.w -o bin/program      # any of -O0 -O1 -O2 -O3 -Os
bin/wllvm program.w -o bin/program.ll       # IR text only (or --emit-llvm)
clang -O2 -static -nostdlib bin/program.ll -o bin/program
```

Clang is needed only to turn IR into an executable: `--cc PATH`, else
`$WLLVM_CC`, else `clang` on `PATH`. Emitting `.ll`, bootstrapping W and the
existing backends need no LLVM installation. The output uses the textual
format of the [LLVM language reference](https://llvm.org/docs/LangRef.html)
and was developed against Clang 18.

The executable keeps W's no-C-runtime model. The module defines `_start`
(module-level assembly) and calls the program's real entry, `lib.lib`'s
`_main`, when the program imports it, else `main`; it exits with
`exit_group`. W's `syscall`/`syscall7` stubs become x86-64 inline
`syscall` instructions, so the standard library's own I/O and `malloc`
(mmap-based) lower like any other W code. The module also defines
`memset`, `memcpy` and `memmove`, which LLVM may call for large copies,
as loops marked `"no-builtins"`. Nothing links against libc.

This is not a switch on `wv2` and does not replace a production backend.

## Architecture

The CLI runs the production compiler for the x64 target in a
semantic-retaining session (`--ast-required`, so every expression has a
tree), then hands the retained forest to `tools/wllvm_emit.w`. The front end
still performs its native lowering to the null device during analysis; this
does not establish independent whole-module AST compilation or a
compile-time speedup. See [AST migration](ast_migration.md) for that work.

Emission starts at the entry point and follows calls, function values and
global references across every imported module, so only reachable library
code is lowered. Every function of the input module is lowered whether or
not it is called. Locals, calls and globals resolve through retained
binding identities, so equal spellings in different scopes stay distinct.

Value model: every W word is an `i64`, including pointers. W pointer
arithmetic is unscaled bytes, so `add`/`sub` on the words keep W
semantics exactly; only subscripts scale. Places (locals, globals,
dereferences, fields, subscripts) are LLVM `ptr` operands, so a local whose
address is never taken stays an `alloca` that LLVM promotes to registers.
Loads and stores use the width and signedness of the place's W type
(`int8` and `char` sign-extend, `uint8`/`uint16`/`uint32` zero-extend), as
the native backend's `promote` does. Functions use one internal ABI: every
parameter and result is an `i64`, which also makes indirect calls through W
function values line up.

Global initializers are retained by the front end for this purpose: each
global declaration record carries its constant, C string bytes, or the
binding whose address it holds (`retained_initializer`, also printed by
`bin/wv2 tree` as `initializer_*` fields).

### Library functions outside the subset

When a reachable function from an imported module falls outside the
subset, wllvm replaces its body with `llvm.trap` and prints a note:

```
wllvm: note: print_stack_trace traps if called: .../lib/stack_trace.w:873:2: wllvm: unsupported call to a function without a W body 'repl_setjmp'
```

The program still builds; it traps only if that function actually runs.
In practice this is the stack-trace path of the allocator's fatal errors
and of failed assertions. Functions of the input module never degrade:
anything unsupported there is an error, with the call path from the entry
point, and the output file is left untouched.

## Supported subset

- Types: `int`, `uint`, the fixed-width integers, `char`, `byte`, `bool`,
  enums, pointers of any level, function values and aliases of them,
  `string` handles, records (structs whose fields are all of these), fixed
  arrays `T[N]` and slice handles, generic records (`pair[int]`), and
  checked pointers (`own`, `optown`, `ref`, `refmut`, `optref`,
  `optrefmut`) with checked slices (`ref T[]`) and borrowed records as
  locals and fields.
- Locals with or without initializers (storage is zeroed at the
  declaration, as are fixed-array headers), parameters, globals with
  constant, C string, `&global` or function initializers, and `const`
  globals.
- Expressions: integer arithmetic and comparisons (unsigned where W uses
  unsigned word operations), bitwise operations and shifts (counts masked
  to six bits), short-circuit `&&`/`||`, `?:`, casts, assignments and
  compound assignments, `++`/`--`, address-of, dereference, field access,
  pointer subscripts, bounds-checked array subscripts, record copies,
  `new T` and `new T(field=value, ...)`, C and UTF-8 string literals,
  string equality, direct, indirect and `syscall` calls, the `print`/
  `println` builtins and the `max`/`min`/`abs`/`strlen` helpers, the limb
  and bit intrinsics (`mul_hi`, `mul_wide`, `add_carry`, `shr`, `rotl`,
  `rotr`, `popcount`, `clz`, `ctz`) and the host atomics.
- Generic functions with explicit (`max[int](a, b)`) or inferred type
  arguments, including generic methods: each instantiation is retained as
  an ordinary function under its mangled name (`max$int`), and a generic
  call names it.
- Checked owners, with the drops the tree leaves implicit reproduced from
  types as `grammar/safe_cleanup.w` does: moving an owner into an owner
  destination (argument, return, initializer, assignment, `new T(...)`
  field) clears a named source local, parameter or owned field; assigning
  to an owner drops the value it replaces; and owners still in scope are
  dropped, newest first, at block ends, `break`/`continue`, and returns
  (then the function's owner parameters). A drop runs the audited
  destructor for `lib/safe_buffer.w` and `lib/safe_thread.w` records,
  else drops owned fields in reverse order and frees the allocation.
- Statements: `if`/`elif`/`else`, `while`, `for i in range(...)` with one
  to three arguments, `break`, `continue`, `pass`, `return`, `unsafe:`
  blocks, inferred declarations (`name := value`) and expression
  statements.

Division and remainder guard zero divisors and signed minimum divided by
minus one, and an out-of-range array subscript traps; LLVM traps report a
different signal (SIGILL) from the native backend's. Calls and operands
preserve evaluation order.

Not yet supported, and rejected with a diagnostic: floats, containers
(`list`, `map`, `set`, cursor `for` loops), records passed or returned by
value (including checked slices and borrowed records crossing a call),
arrays inside records, f-strings, `switch`, `defer`, `goto`,
generators, GPU code, C imports and other `extern` functions
without a W body, and the remaining assembly stubs (`repl_setjmp`,
`thread_create`, ...). Containers are the largest gap: about half of the
rejected test programs below declare one.

## Evidence (2026-10-24)

Differential corpus: every `tests/*.w` program with a `main` was built by
`bin/wllvm` and by `bin/wv2 x64`, and the two executables were run with no
input. Of 708 programs, wllvm accepted 196: 170 produced identical stdout
and exit status, and the other 26 reached a trap stub (assertion failures
and stack-trace tests, the crash-handler and `memory_debug` fixtures,
`dlcall`, the VM fixtures) or were 32-bit-only tests. The run also found
five `own` fixtures that built but leaked, because the retained tree leaves
the automatic drops implicit; checked pointers are now rejected. The other
512 were rejected with a diagnostic, most often for containers, floats,
`switch`/`defer`, generics and records by value.

Benchmarks: `tests/bench` programs that fit the subset, best of five wall
times on the development container (x86-64, Clang 18.1.3). W x64 is
`bin/wv2 x64` with its default register promotion; the C column is the
`tests/bench/c/` twin at `clang -O2`. All builds print the same checksum.

| program | W x64 | wllvm -O0 | wllvm -O2 | C clang -O2 |
|---|---|---|---|---|
| sum | 0.201s | 0.479s | folded | folded |
| sieve | 0.284s | 0.463s | 0.266s | 0.256s |
| sha256_1m | 0.151s | 0.296s | 0.109s | 0.108s |
| regex_backtrack | 0.273s | 0.574s | 0.145s | 0.152s |
| matmul_256 | 0.199s | 0.404s | 0.166s | 0.173s |

At `-O2` the LLVM build of the W source runs as fast as the hand-written C
twin, 1.07x to 1.9x faster than W's own x64 code (`sum` folds to a
constant under both LLVM builds). `siphash_keys`, `inflate_corpus` and
`strcmp_sort` use containers and are not yet accepted.

## Tests

```sh
./wbuild wllvm_test
./wbuild tests
```

`wllvm_test` always checks deterministic IR, its memory and library
lowering, unsupported-program diagnostics, CLI errors and input/output
identity protection, including preservation of existing output on
rejected input. When `clang` is on `PATH`, it also builds
`tests/wllvm_scalar_fixture.w` and `tests/wllvm_memory_fixture.w` with
W's x64 backend and with wllvm at `-O0` and `-O2` and compares exit status
and both output streams, builds hand-linked IR with the documented flags,
checks the division and bounds traps, and checks that a library trap stub
leaves the rest of the program working. Without Clang it reports the
native comparison as skipped; the structural and rejection checks still
run. No LLVM dependency is added to the seed or the production compiler's
import graph.

## Next steps

1. Containers: `list`/`map`/`set` values are runtime pointers whose
   operations are calls into `structures/`, which already lower; the
   missing piece is reproducing each operation's helper protocol (element
   slot sizes, key kinds, aggregate variants) from retained types.
2. Records by value (copy-in parameters, caller-provided result buffers),
   floats, f-strings and `switch`.
3. Other targets: arm64 Linux needs only a different `_start` and syscall
   constraint string.
