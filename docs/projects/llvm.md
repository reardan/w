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
  arrays `T[N]`, slices `T[]` and slice values, and the built-in `list[T]`, `map[K, V]`
  and `set[T]` containers of any of these.
- Locals with or without initializers (storage is zeroed at the
  declaration, as are fixed-array headers), parameters, globals with
  constant, C string, `&global` or function initializers, and `const`
  globals.
- Expressions: integer arithmetic and comparisons (unsigned where W uses
  unsigned word operations), bitwise operations and shifts (counts masked
  to six bits), short-circuit `&&`/`||`, `?:`, casts, assignments and
  compound assignments, `++`/`--`, address-of, dereference, field access,
  pointer subscripts, bounds-checked array, slice and string subscripts,
  ranges `a[i:j]`/`a[i:]`/`a[:j]` over arrays, slices and strings (a
  bounds-checked, freshly allocated `{data, length}` descriptor, as the
  native legacy range ABI builds it), array-to-slice decay and decay of
  arrays and slices to their data pointer, record copies,
  `new T` and `new T(field=value, ...)`, C and UTF-8 string literals,
  string equality, direct, indirect and `syscall` calls, the `print`/
  `println` builtins, `enum_name` and the `max`/`min`/`abs`/`strlen`
  helpers, the limb
  and bit intrinsics (`mul_hi`, `mul_wide`, `add_carry`, `shr`, `rotl`,
  `rotr`, `popcount`, `clz`, `ctz`) and the host atomics.
- Containers: `new list[T]`/`new map[K, V]`/`new set[T]`, map defaults
  (`new map[K, V](value)`, a factory, or an empty inner container),
  `list[T]{...}`/`map[K, V]{k: v}`/`set[T]{...}` literals, `l[i]` as a
  place, `l[a:b]` slices, `m[k]` reads, stores and compound stores,
  `.length`, `in`, every list, map and set method, and the `it` forms
  (`l.map(it * 2)`, `l.filter(...)`, `l.min_by(...)`, ...), and the
  prelude's `print(list)`, `len`, `any`/`all`, `split`/`join`,
  `input`/`read_all`/`ints`/`lines`/`words`. Each lowers
  to the same `structures/` runtime call the native front end makes, with
  the element slot size and key kind taken from the retained types.
- Statements: `if`/`elif`/`else`, `while`, `for i in range(...)` with one
  to three arguments, cursor loops (`for x in l`, `for i, x in l`,
  `enumerate`, `for k, v in m`, `for k in s`, fixed arrays and slices,
  strings through `lib.utf8`, and `T*` iterables with `T_iter_*`
  functions), `break`, `continue`, `pass`, `return`, `unsafe:` blocks,
  `name := value`, parallel assignment (`a, b = b, a + b`: every target
  address, then every value, then the stores) and expression statements.

Division and remainder guard zero divisors and signed minimum divided by
minus one, and an out-of-range array subscript traps; LLVM traps report a
different signal (SIGILL) from the native backend's. Calls and operands
preserve evaluation order.

Not yet supported, and rejected with a diagnostic: floats, records
passed or returned by value, arrays inside records, generics, f-strings, `switch`, `defer`,
`goto`, generators (see below), checked pointers (`own`, `ref`, ... and their
slices), GPU code, C imports and other `extern` functions
without a W body, and the remaining assembly stubs (`repl_setjmp`,
`thread_create`, ...). A container trap (out-of-range index, missing
key) prints its message and then reaches the `print_stack_trace` trap
stub.

Generators are stackful coroutines: `lib/generator.w` builds an initial
frame on a private mmap'd stack and `gen_switch`, an assembly stub from
`code_generator/x64_asm.w`, swaps stack pointers. Supporting them needs
`gen_switch` as module-level inline assembly (save the SysV callee-saved
registers, store `rsp` through the first argument, load the second, pop
and return), a per-generator entry thunk that unpacks the arguments
`__w_gen_create` leaves on the new stack (it lays them out for the native
stack-argument convention, not LLVM's register arguments), calls the body
with them and the hidden trailing `generator*` and then calls
`__w_gen_return`, 16-byte stack alignment at that call, and lowering
`yield v` to `__w_gen_yield(self, v)`, `return` to `__w_gen_return(self)`
and the call site to `__w_gen_create(thunk, argv, argc)`; the
`generator_iter_*` cursor loop then works as it is.

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
| siphash_keys | 0.313s | 0.498s | 0.242s | 0.282s |
| strcmp_sort | 0.221s | 0.367s | 0.155s | 0.159s |

At `-O2` the LLVM build of the W source runs as fast as the hand-written C
twin, 1.07x to 1.9x faster than W's own x64 code (`sum` folds to a
constant under both LLVM builds). The container benchmarks
(`siphash_keys` maps and sets, `strcmp_sort` lists) run their runtime
helpers through LLVM too. `inflate_corpus` uses generics and is not yet
accepted.

## Tests

```sh
./wbuild wllvm_test
./wbuild tests
```

`wllvm_test` always checks deterministic IR, its memory and library
lowering, unsupported-program diagnostics, CLI errors and input/output
identity protection, including preservation of existing output on
rejected input. When `clang` is on `PATH`, it also builds
`tests/wllvm_scalar_fixture.w`, `tests/wllvm_memory_fixture.w`,
`tests/wllvm_container_fixture.w` and `tests/wllvm_slice_fixture.w` with
W's x64 backend and with wllvm at `-O0` and `-O2` and compares exit status
and both output streams, builds hand-linked IR with the documented flags,
checks the division and bounds traps, and checks that a library trap stub
leaves the rest of the program working. Without Clang it reports the
native comparison as skipped; the structural and rejection checks still
run. No LLVM dependency is added to the seed or the production compiler's
import graph.

## Next steps

1. Records by value (copy-in parameters, caller-provided result buffers),
   floats, f-strings and `switch`.
2. Other targets: arm64 Linux needs only a different `_start` and syscall
   constraint string.
