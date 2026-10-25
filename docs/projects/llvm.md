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
as loops marked `"no-builtins"`. Nothing links against libc. The runtime
functions the native backends write in assembly
(`code_generator/x64_asm.w`) are module-asm twins with the SysV argument
registers and the same memory layouts: `repl_setjmp`/`setjmp` (declared
`returns_twice`), `repl_longjmp`/`longjmp`, `thread_create`,
`stack_create` and `__w_tls_set`; `__w_tls_size()` reads the block size
the module settles once every function is emitted.

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
wllvm: note: print_registers traps if called: .../lib/context_x86_64.w:36:2: wllvm: unsupported call to a function without a W body 'get_context'
```

The program still builds; it traps only if that function actually runs,
and a trace through the trap names the function at its own line.
Functions of the input module never degrade:
anything unsupported there is an error, with the call path from the entry
point, and the output file is left untouched.

## Supported subset

- Types: `int`, `uint`, the fixed-width integers, `char`, `byte`, `bool`,
  enums, `float32` (`float`) and `float64`, the storage-only `float16` and
  `bfloat16`, pointers of any level,
  function values and aliases of them, `string` handles, records (structs whose fields are all of these), fixed
  arrays `T[N]` and slice handles.
- Locals with or without initializers (storage is zeroed at the
  declaration, as are fixed-array headers), parameters, globals with
  constant, C string, `&global` or function initializers, `const`
  globals, and `thread_local` globals (offsets in one per-thread block
  reached through `gs:[0]`, the main thread's block in `.data` and
  installed before the entry runs, as natively).
- Expressions: integer arithmetic and comparisons (unsigned where W uses
  unsigned word operations), bitwise operations and shifts (counts masked
  to six bits), short-circuit `&&`/`||`, `?:`, casts, assignments and
  compound assignments (`<<=` and `>>=` included), `++`/`--`, address-of, dereference, field access,
  pointer subscripts, bounds-checked array subscripts, record copies,
  `new T` and `new T(field=value, ...)`, C and UTF-8 string literals,
  string equality, direct, indirect and `syscall` calls, the `print`/
  `println` builtins and the `max`/`min`/`abs`/`strlen` helpers, the limb
  and bit intrinsics (`mul_hi`, `mul_wide`, `add_carry`, `shr`, `rotl`,
  `rotr`, `popcount`, `clz`, `ctz`) and the host atomics.
- Floats: literals, arithmetic, comparisons, unary minus, compound
  assignment and `++`/`--`, implicit and `cast` conversions between
  integers, `float32` and `float64`, and mixed integer/float operands, all
  with the native backend's SSE semantics (see below). A `float16` or
  `bfloat16` value is a `float32` rounded to the type: loads widen and
  stores narrow, `float16` with `vcvtph2ps`/`vcvtps2ph` (nearest-even,
  F16C, the instructions the native backend uses) and `bfloat16` with
  `code_generator/bfloat.w`'s integer rounding.
- C math calls: `sqrt`, `fabs`, `floor`, `ceil`, `trunc`, `fmin`, `fmax`,
  `copysign` and their `float32` `...f` forms, declared `extern` or
  through `c_import`. Natively these bind libm through the dynamic linker
  (W code uses `lib/fmath*.w`, which lowers like any W code); the
  freestanding build lowers them inline with the same bits:
  `llvm.sqrt`, `llvm.minnum`/`llvm.maxnum`, sign-mask arithmetic, and a
  `cvtt` round trip below 2^52 (2^23) for the roundings, so neither SSE4.1
  nor libm is needed. Other libm functions (`pow`, `fmod`, `fma`, ...)
  stay unsupported.
- f-strings, with every value type the native lowering accepts except
  `var` (integers, `char`, `bool`, enums, `char*`, `string`, `float32`,
  `float64`) and the `{value:spec}` format mini-language, through the same
  `__w_template_*` runtime calls; a string literal or f-string passed
  where a `char*` is wanted decays to its data pointer.
- `lib/testing.w` programs: wllvm builds `__w_test_main` from the retained
  forest the way the native driver synthesizes it (compiler/test_registry.w),
  as a private symbol like native's zero-sized one, and their crash
  handler installs normally.
- `setjmp`/`longjmp`, threads (`lib/thread.w`, raw `thread_create`) and
  `lib/stack_trace.w` / `lib/crash.w` traces (below).
- Statements: `if`/`elif`/`else`, `while`, `for i in range(...)` with one
  to three arguments, `break`, `continue`, `pass`, `return`, `unsafe:`
  blocks and expression statements.

Division and remainder guard zero divisors and signed minimum divided by
minus one and then divide by zero, raising SIGFPE as the native `idiv`
does; an out-of-range array subscript traps with SIGILL (`llvm.trap`).
Calls and operands preserve evaluation order.

Two native memory behaviors are kept explicitly. In a function that calls
`setjmp`, every load and store is volatile, so a `longjmp` back sees each
local's latest value (native locals always live in memory). In a program
that starts threads, every load and store of a global is volatile, so a
thread spinning on a flag another thread sets rereads it.

### Stack traces and crash reports

`lib/stack_trace.w` symbolizes from the running image: it walks the
frame-pointer chain, finds functions in the mapped `.symtab` and lines in
a DWARF 2 `.debug_line`, and stops at the frame named `main`. wllvm
produces that image:

- Functions keep their W names as ELF symbols (`@"name"`); a name defined
  twice, or `memset`/`memcpy`/`memmove`/`_start`, gets a `.<linkage>`
  suffix.
- Every function has `"frame-pointer"="all"`, `"disable-tail-calls"` and
  `null_pointer_is_valid` (a null read faults as natively instead of
  becoming LLVM undefined behavior); clang runs with shrink wrapping off,
  so each prologue starts its function. Once a program reaches
  `lib/stack_trace.w` (every `lib/testing.w` program does, through the
  crash handler), every function is also `noinline`, so `-O2` keeps the
  frames a trace shows.
- Statements leave line markers that become `!dbg` locations in a
  line-tables-only compile unit with `"Dwarf Version"` 2.
- Globals live in `.data` (no `.bss`), and after linking `tools/wllvm.w`
  extends the last `PT_LOAD` to the end of the file, so the section
  headers, `.symtab` and `.debug_line` are mapped at the image base plus
  their file offset, where the reader looks. It does so only when every
  `PT_LOAD` shares one address-to-offset delta and the first maps the ELF
  header: GNU ld's default static layout (clang's default linker here).
  Other layouts, `lld` among them, and IR linked by hand are left alone,
  and traces then print nothing, like a native binary without symbols.
- The lib/signal.w handler thunk passes `(sig, &uc_mcontext)` in rdi/rsi
  on an aligned stack as well as on the W stack, and `st_call_site` also
  accepts LLVM's indirect call forms (`call *%reg`, `call *rel32(%rip)`).

With that, `print_stack_trace`, `stack_trace_collect` and the
`lib/crash.w` report match native frame for frame and line for line
(`stack_trace_test`, `stack_trace_chain_test`, `crash_install_test` and
the `crash_*_fixture` programs compare equal). What differs: a frame's
file is the base name (`crash_deep_chain_fixture.w:29`), since LLVM's
DWARF 2 file table splits the directory off and the reader prints only
the entry's name; register values, addresses and the build-id differ as
they do between any two builds.

A float value travels in its 64-bit word as its bit pattern (a `float32`
in the low 32 bits) and is bitcast around each LLVM `float`/`double`
operation, so it uses the same internal ABI as every other word. The
native semantics are spelled out where LLVM's differ: float `==` is true
and `!=` false on NaN operands (`ucomisd` + `sete`), the ordered
comparisons are false; float-to-integer conversion uses the
`cvttss2si`/`cvttsd2si` intrinsics, whose out-of-range result is
`0x8000000000000000` (LLVM's `fptosi` is poison there), and a float cast to
a narrow integer keeps that whole word as natively; integer-to-float takes
the whole signed word. LLVM leaves a NaN result's sign and payload open
and folds `0.0 / 0.0` to `0x7ff8...`, so each arithmetic result selects
the SSE answer explicitly: the first NaN operand quieted, else the second,
else the default NaN `0xfff8...` (`0xffc00000` for `float32`).

Not yet supported, and rejected with a diagnostic: `var`, containers (`list`, `map`, `set`, cursor
`for` loops), records passed or returned by value, arrays inside records,
generics, `switch`, `defer`,
`goto`, generators, checked pointers (`own`, `ref`, ... and their
slices), GPU code, C imports and other `extern` functions
without a W body (except the math functions above), the `debugger`
statement, and the `get_context`/`store_context` and generator
(`gen_switch`) stubs. Containers are the largest gap: about half of the
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
`tests/wllvm_scalar_fixture.w`, `tests/wllvm_memory_fixture.w`,
`tests/wllvm_float_fixture.w` (floats, NaN and conversion edge cases,
f-strings), `tests/wllvm_registry_fixture.w` (the synthesized test
registry), `tests/wllvm_runtime_fixture.w` (`setjmp`/`longjmp`, a thread,
`stack_trace_collect` frames and lines, compound shifts, `float16` and
`bfloat16` storage) and `tests/wllvm_math_fixture.w` (the C math calls,
bit for bit against libm) with W's x64 backend and with wllvm at `-O0` and `-O2` and compares exit status
and both output streams, builds hand-linked IR with the documented flags,
checks the division and bounds traps, checks that the crash reporter
prints the native frames and lines for `tests/crash_deep_chain_fixture.w`
(without the heuristic-scan note) and SIGFPE for
`tests/crash_div_zero_fixture.w`, and checks that a library trap stub
leaves the rest of the program working. Without Clang it reports the
native comparison as skipped; the structural and rejection checks still
run. No LLVM dependency is added to the seed or the production compiler's
import graph.

## Next steps

1. Containers: `list`/`map`/`set` values are runtime pointers whose
   operations are calls into `structures/`, which already lower; the
   missing piece is reproducing each operation's helper protocol (element
   slot sizes, key kinds, aggregate variants) from retained types.
2. Records by value (copy-in parameters, caller-provided result buffers)
   and `switch`.
3. Other targets: arm64 Linux needs only a different `_start` and syscall
   constraint string.
