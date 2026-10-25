# LLVM offload (#337)

`bin/wllvm` is an opt-in LLVM backend over the production compiler's
retained AST. A visitor walks the semantic forest the normal front end
already builds and emits LLVM IR text; for an executable it hands that IR
to clang, which produces a freestanding x86-64 or AArch64 Linux binary. The production
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
bin/wllvm arm64 program.w -o bin/program    # AArch64 Linux (or --target arm64)
```

`arm64` runs the front end for AArch64, so the standard library resolves
its `lib/__arch__/arm64` modules (the generic-table syscall numbers of
`lib/arm64/syscalls.w`). The module targets `aarch64-unknown-linux-gnu`;
`syscall`/`syscall7` become `svc #0` with the number in `x8` and arguments
in `x0`-`x5`, `_start` passes `[sp]` and `sp + 8` as argc and argv, and the
exit is `exit_group` (94). Clang links it with `--target=aarch64-linux-gnu
-fuse-ld=lld`, so ld.lld must be installed; run the result on AArch64
Linux or under `qemu-aarch64`.

Clang is needed only to turn IR into an executable: `--cc PATH`, else
`$WLLVM_CC`, else `clang` on `PATH`. Emitting `.ll`, bootstrapping W and the
existing backends need no LLVM installation. The output uses the textual
format of the [LLVM language reference](https://llvm.org/docs/LangRef.html)
and was developed against Clang 18.

The executable keeps W's no-C-runtime model. The module defines `_start`
(module-level assembly) and calls the program's real entry, `lib.lib`'s
`_main`, when the program imports it, else `main`; it exits with
`exit_group`. W's `syscall`/`syscall7` stubs become inline `syscall`
(x86-64) or `svc #0` (AArch64) instructions, so the standard library's own I/O and `malloc`
(mmap-based) lower like any other W code. The module also defines
`memset`, `memcpy` and `memmove`, which LLVM may call for large copies,
as loops marked `"no-builtins"`, with hidden visibility. A program
without C imports links statically against nothing. The runtime
functions the native backends write in assembly
(`code_generator/x64_asm.w`) are module-asm twins with the SysV argument
registers and the same memory layouts: `repl_setjmp`/`setjmp` (declared
`returns_twice`), `repl_longjmp`/`longjmp`, `thread_create`,
`stack_create` and `__w_tls_set`; `__w_tls_size()` reads the block size
the module settles once every function is emitted. These and
`thread_local` globals (`gs:[0]`) are x86-64 only; AArch64 rejects them.

### C imports

`extern` functions and objects without a W body, whether declared by hand
(`c_lib "libc.so.6"`, `extern int printf(char* fmt, ...)`, `= "symbol"`
aliases) or by `c_import`, lower to LLVM declarations of the library
symbol, and such a program links dynamically. The front end binds each
extern symbol to a dynamic-registry import: a function through its GOT
slot (`sym_got_vaddr`, which the front end now records for every import,
not only variadic ones), an object through the address it reserved. Calls
use the C ABI while W functions keep the i64 ABI: each fixed parameter and
the result take the LLVM type of their W type (`ptr`, `i8` to `i64` with
`signext`/`zeroext` below 32 bits, `float`, `double`), so a W `int` is an
`i64` and an `int32` an `i32` whose result sign-extends. A variadic call
spells its function type (`call i64 (ptr, i64, ptr, ...) @"snprintf"(...)`)
and passes the tail as words, a `float32` promoted to `double` and a
fixed array or slice decayed to its data pointer, as the native inline
call does. `c_import`'s weak imports become `extern_weak`; its integer
macros and enumerators (`SEEK_END`, `ENOENT`) are constants, and its
layout padding fields are skipped.

Linking keeps W's own `_start` (`-nostartfiles`) rather than crt1 and
`__libc_start_main`, the model the native backends use: the dynamic
loader initializes libc before `_start` runs, and the program still exits
with `exit_group`, so C `atexit` handlers do not run and buffered stdio
must be flushed explicitly (`fflush(0)`), exactly as natively. The link
names every `c_lib` the program declares (`-l:libc.so.6 -l:libm.so.6`),
since the native image lists each as `DT_NEEDED` and the loader resolves
an import in any of them; the IR's header comment repeats that command
for `--emit-llvm` output.

An imported object is the library's own storage rather than a COPY of it
sized by its W type, so its W type must match the C object: `extern int
optind` (8 bytes) reads past libc's 4-byte `int` under wllvm, while the
native COPY space zero-fills the rest. AArch64 dynamic links (which need
an AArch64 sysroot) are not covered.

An import used as a value (`call_text(puts, s)`, a function-typed
argument or global) is the address of a per-binding W-ABI thunk,
`@wllvm.cthunk.<binding>`, which takes and returns words and makes the C
call, as the native symbol names the import's ABI shim; a variadic
import's thunk passes the fixed parameters only, like that shim.

C bit-fields: c_import gives each bit-field member an access type whose
side table holds the storage unit's size and the field's bit offset,
width and signedness. A member access names the unit, a read loads it
zero-extended and sign-extends (shift left, arithmetic shift right) or
shifts and masks, and a write is the read-modify-write of
`grammar/promote.w`'s `bit_field_assign_store`.

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
  `bfloat16`, pointers of any level, function values and aliases of them,
  `string` handles, records (structs whose fields are all of these,
  fixed-array fields included), fixed arrays `T[N]`, slices `T[]` and
  slice values, generator handles, the built-in `list[T]`, `map[K, V]` and
  `set[T]` containers of any of these, generic records (`pair[int]`), and
  checked pointers (`own`, `optown`, `ref`, `refmut`, `optref`,
  `optrefmut`) with checked slices (`ref T[]`) and borrowed records as
  locals and fields.
- Locals with or without initializers (storage is zeroed at the
  declaration, as are fixed-array headers; a record's fixed-array fields
  get their inline headers wherever a record comes into being: its
  declaration, `new`, a record copy and a global's initializer),
  parameters, globals with constant, C string, `&global` or function
  initializers, `const` globals, and `thread_local` globals (offsets in
  one per-thread block reached through `gs:[0]`, the main thread's block
  in `.data` and installed before the entry runs, as natively).
- Expressions: integer arithmetic and comparisons (unsigned where W uses
  unsigned word operations), bitwise operations and shifts (counts masked
  to six bits), short-circuit `&&`/`||`, `?:`, casts, assignments and
  compound assignments (`<<=` and `>>=` included), `++`/`--`, address-of,
  dereference, field access,
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
- Generic functions with explicit (`max[int](a, b)`) or inferred type
  arguments, including generic methods: each instantiation is retained as
  an ordinary function under its mangled name (`max$int`), and a generic
  call names it, as does a generic referenced before its declaration
  (the front end retains that reference's mangled instance name).
- Checked owners, with the drops the tree leaves implicit reproduced from
  types as `grammar/safe_cleanup.w` does: moving an owner into an owner
  destination (argument, return, initializer, assignment, `new T(...)`
  field) clears a named source local, parameter or owned field; assigning
  to an owner drops the value it replaces; and owners still in scope are
  dropped, newest first, at block ends, `break`/`continue`, and returns
  (then the function's owner parameters). A drop runs the audited
  destructor for `lib/safe_buffer.w` and `lib/safe_thread.w` records,
  else drops owned fields in reverse order and frees the allocation.
- Floats: literals, arithmetic, comparisons, unary minus, compound
  assignment and `++`/`--`, implicit and `cast` conversions between
  integers, `float32` and `float64`, and mixed integer/float operands, all
  with the native backend's SSE semantics (see below). A `float16` or
  `bfloat16` value is a `float32` rounded to the type: loads widen and
  stores narrow, `float16` with `vcvtph2ps`/`vcvtps2ph` on x86-64 (F16C)
  and `fpext`/`fptrunc` of `half` (`fcvt`) on AArch64, nearest-even like
  the native backends, and `bfloat16` with
  `code_generator/bfloat.w`'s integer rounding.
- C math calls: `sqrt`, `fabs`, `floor`, `ceil`, `trunc`, `fmin`, `fmax`,
  `copysign` and their `float32` `...f` forms, declared `extern` or
  through `c_import`. On x86-64 they are ordinary C imports (libm, linked
  dynamically, below); on AArch64, whose dynamic links are not covered,
  and for a declaration with no import behind it, they lower inline with
  libm's bits:
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
  blocks, inferred declarations (`name := value`) and expression
  statements.
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
  functions, generators included), `break`, `continue`, `pass`, `return`,
  `yield`, `unsafe:` blocks,
  `name := value`, parallel assignment (`a, b = b, a + b`: every target
  address, then every value, then the stores) and expression statements.

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
comparisons are false; float-to-integer conversion is the saturating
`llvm.fptosi.sat` (LLVM's `fptosi` is poison out of range), and on x86 a
NaN or a value at or above 2^63 selects `cvttss2si`/`cvttsd2si`'s integer
indefinite `0x8000000000000000` instead; a float cast to a narrow integer
keeps that whole word as natively; integer-to-float takes the whole signed
word. LLVM leaves a NaN result's sign and payload open and folds `0.0 /
0.0` to `0x7ff8...`, so each arithmetic result selects the SSE answer
explicitly: the first NaN operand quieted, else the second, else the
default NaN `0xfff8...` (`0xffc00000` for `float32`).

On AArch64 the same IR follows `bin/wv2 arm64`'s instructions: `fcvtzs`
saturates (NaN gives 0), which is `llvm.fptosi.sat` exactly; `fcmp` with
`cset eq`/`ne` makes `==` false and `!=` true on NaN (the ordered
comparisons stay false, since `<` and `<=` swap into `gt`/`ge`); and with
FPCR.DN clear a signaling NaN operand wins over a quiet one, the first
operand before the second, and the default NaN is positive (`0x7ff8...`,
`0x7fc00000`). `tests/wllvm_float_fixture.w` runs under qemu against the
native arm64 build. Generators are rejected on AArch64: their entry thunk
and `gen_switch` follow the x86-64 stack layout.

Not yet supported, and rejected with a diagnostic: `var`, records
passed or returned by value (including checked slices and borrowed records
crossing a call), `switch`, `defer`, `goto`, GPU code, the `debugger`
statement, and the `get_context`/`store_context` stubs. A container trap
(out-of-range index, missing key) prints its message and then the stack
trace.

Generators are stackful coroutines (`lib/generator.w`) and lower with the
native runtime unchanged. The body is an ordinary function whose last
parameter is the hidden `__w_gen_self`; `yield v` calls
`__w_gen_yield(self, v)`, and `return` or falling off the end calls
`__w_gen_return(self)`. A call `counter(a, b)` stores its arguments into
an entry-block argv (last argument first) and calls
`__w_gen_create(@wg<n>, argv, argc)`. `__w_gen_create` seeds the new
stack for the native stack-argument convention (a zero return address,
then self, then the arguments), so `@wg<n>` is a per-generator entry
thunk: it reads those words relative to
`llvm.addressofreturnaddress` and calls the body with register
arguments. `"stackrealign"` covers the stack, which is not call-aligned
there. `gen_switch` is module assembly with the native stub's protocol:
push rbx, rbp and r12-r15, store rsp through the first argument, load the
second, pop and return. A cursor loop over a generator calls `gen_free`
on its exit edges, and a `return` inside such loops frees each enclosing
generator first, as `for_cleanup_emit_all` does.

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
`tests/wllvm_container_fixture.w`, `tests/wllvm_slice_fixture.w`,
`tests/wllvm_generator_fixture.w`,
`tests/wllvm_generic_fixture.w` (generics and checked owners),
`tests/wllvm_extern_fixture.w` (libc and libm calls through the C ABI,
variadic, float and narrow-integer signatures, an alias, an imported
object and a `c_import` constant; linked dynamically),
`tests/wllvm_float_fixture.w` (floats, NaN and conversion edge cases,
f-strings), `tests/wllvm_registry_fixture.w` (the synthesized test
registry), `tests/wllvm_runtime_fixture.w` (`setjmp`/`longjmp`, a thread,
`stack_trace_collect` frames and lines, compound shifts, `float16` and
`bfloat16` storage) and `tests/wllvm_math_fixture.w` (the C math calls,
bit for bit against libm) and `tests/wllvm_half_fixture.w` (`float16` and
`bfloat16` rounding, overflow and NaN payloads; also run on AArch64) with W's x64 backend and with wllvm at `-O0` and `-O2` and compares exit status
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

1. Records by value (copy-in parameters, caller-provided result buffers)
   and `switch`.
2. Other targets: AArch64 Darwin (Mach-O, `svc #0x80` with BSD numbers
   and code signing) and win64 would need their own entry and system-call
   layers.
