# Relocatable objects and freestanding code

`--emit=obj` writes an x86-64 ELF relocatable object (`ET_REL`, a `.o`)
that a system linker (`cc`, `ld`) combines with C code. `--freestanding`
additionally leaves out W's runtime. Together they are the first step
toward linking W code — including code translated from C by `ctow` —
into a C program or a kernel. This is the first slice: x64 Linux only.

```sh
./bin/wv2 x64 --emit=obj --freestanding lib.w -o lib.o
cc -o app main.c lib.o
```

`tests/object_file_test.w` builds `tests/object_file/library.w`, links
it with `tests/object_file/main.c` as a PIE, a `-no-pie` and a `-static`
executable, and runs each. It also checks the ELF structure, reads
`readelf -a`, and covers the runtime-retaining mode and the diagnostics.

## The interface

```w
extern int c_scale(int x)       # a C function W calls
extern int c_value              # a C global W reads and writes
int w_counter = 7               # a W global C can read and write

export int w_add(int a, int b): # a function C calls
	w_counter = w_counter + 1
	return a + b
```

```c
long c_scale(long x) { return x * 5; }
long c_value = 100;
extern long w_counter;
long w_add(long a, long b);
```

- **Calling convention.** W functions keep W's internal stack-based
  convention. `export` gives a function a System V x86-64 adapter
  (`code_generator/elf_exports.w`, the same adapter `--shared` and
  `--static` libraries use); the adapter is the global symbol. Calls to
  `extern` functions go through the existing FFI shims
  (`code_generator/ffi.w`), which call through a data word relocated to
  the C symbol (under `--c-abi` the shim calls the C symbol directly
  instead; see "Relocations"). Supported signatures are those of native exports:
  word-sized integers and pointers, `float32`, `float64`, void returns.
  A W `int` is 64 bits on x64 (C `long`/`int64_t`). Variadic exports
  and struct arguments or returns by value are rejected.
- **Symbols.** Exported adapters and globals declared in the
  command-line root files (unless marked `static`) are `GLOBAL`. `extern` functions and data
  objects are undefined `GLOBAL` symbols. All other W functions and
  globals — including everything from imported modules and the runtime —
  are `LOCAL`, so two W objects (each with its own runtime) do not clash.
  An exported function's W-convention body has no symbol of its own.
- **Globals.** A global's symbol covers its W storage. Scalars and
  pointers match C directly. A fixed array `int[4] a` is stored as a W
  array (a two-word header, then the elements); its symbol names the
  elements, so C sees `long a[4]` and W code keeps indexing through the
  header just before them.
- **Static pointer data.** File-scope address initializers
  (`grammar/program.w`, `global_address_initializer`) make static pointer
  tables expressible: `int* p = &g`, `int* q = &g + 8` (a byte offset),
  `unary* f = some_function` (defined before or after) and
  `char* s = c"text"`. The `&g` global may be declared later in the
  program, so cyclic tables need no ordering. They work in every native
  executable too (`tests/global_address_init_test.w`). A function
  pointer stored this way holds the W-convention entry, so it is for W
  callers; C should call exported functions by name. `--c-abi` (below)
  makes every function pointer a System V one.
- **File-local symbols.** `static` before a function or global
  definition (`static int helper(int a):`, `static int count = 0`)
  keeps it a `LOCAL` symbol even in a root file, like C's `static`.
  It is contextual like `export` (a type or symbol named `static`
  keeps the identifier meaning), and other outputs accept and ignore
  it, so one source compiles everywhere.
- **Static C-layout data.** A brace initializer
  (`global_brace_initializer`) lays a global's bytes out item by item,
  with no implicit alignment and no code run at startup:

  ```w
  struct entry:      # C: struct { short kind; char flag; int count; long *ref; const char *name; }
  	int16 kind
  	int8 flag
  	uint8 pad0
  	int32 count
  	int* ref
  	char* name

  entry[2] table = {int16 1, int8 -1, pad 1, int32 100, &counter, c"first",
  	int16 2, pad 2, int32 -5, &later_global + 16, c"second"}
  ```

  Items are `T value` (an integer constant stored at the width of the
  integer type `T`, sign-extended; 64-bit values beyond 32 bits are two
  `uint32` halves, low first), an address word (`&g`, `&g + N`, a
  function name -- one not declared yet is resolved at the end of the
  compile -- or `c"..."`, optionally after a word-sized type such as
  `char*`), and `pad N` (N zero bytes). Bytes after the last item are
  zero, `{}` is all zeros, and items may continue on following lines.
  The items fill a fixed array's elements (not its header) or a
  struct's, union's or scalar's bytes; types with nested fixed-array
  headers and runtime-backed types are rejected, and the items must fit. Address
  words are relocated like any address initializer; under `--c-abi` a
  function item holds the System V entry (an `extern` function's, the C
  symbol). A fixed array's symbol is its first element: the W header
  (data pointer and length) sits in `.data` apart from the elements,
  so `@section`/`@align` place and align the elements, an all-zero
  array still lands in `.bss`, and C sees a plain array. The other
  way round, `extern int32[3] c_numbers` imports a C array: W keeps a
  header of its own pointing at the C symbol (elements holding nested
  arrays are rejected). `extern int32[] c_table` imports a C array
  of unknown length (`extern int c_table[];`): the name is an `int32*`
  holding the C symbol's address (a relocated pointer cell, no symbol
  of its own), so `c_table[i]` indexes without a length check and its
  value is the array's address, as in C (objects only); in an
  address initializer `&c_table` and `&c_table + N` are the C symbol
  (plus N), as are `&c_numbers + N` past the end of a sized one. An
  `extern` of a zero-size type (an empty record, one W only knows by
  name) is accepted in an object and references the C symbol too
  (`tests/object_file/static_data.w` links such data with C;
  `tests/static_data_test.w` covers executables).

## The C ABI mode

`--c-abi` (with `--emit=obj --freestanding`, x64 only) makes the
object usable as C code is: assembly and C call any of its functions
by name, store their addresses in tables, and hand W their own
function pointers.

```sh
./bin/wv2 x64 --emit=obj --freestanding --c-abi lib.w -o lib.o
```

`tests/object_c_abi_test.w` links `tests/object_file/c_abi_library.w`
with `tests/object_file/c_abi_main.c` (PIE, `-no-pie`, `-static`, and
under the AST, streaming and `-O0` front-end modes), and checks the
symbol bindings and the diagnostics.

- **Entries.** Every function compiled through `be_function_define`
  gets a 5-byte System V entry right before its W entry: a `jmp` to an
  adapter emitted after the last function (`code_generator/c_abi.w`).
  The adapter is the export adapter's shape — System V arguments
  (`rdi rsi rdx rcx r8 r9`, `xmm0-7`, then the stack) pushed as W stack
  words, `rbx`, `rbp`, `r12-r15` preserved, float results moved to
  `xmm0` — plus the sign or zero extension of each narrow integer
  argument (`int8/16/32`, `uint8/16/32`, `char`, `bool`) to the word W
  expects. Direct W-to-W calls keep W's stack convention and never touch
  the stub.
- **Symbols.** Every function defined in a root file and not marked
  `static`, and every `export`ed function, is a `GLOBAL FUNC` symbol at
  its entry stub. `static` functions and everything imported stay
  `LOCAL` (at the W entry). Globals follow the rules above.
- **Function values.** A function's name used as a value (`fp = f`,
  `&f`, an argument, a `return`) and a file-scope address initializer
  (`binop* table = f`) yield the entry stub, so a pointer W hands out
  compares equal to C's `&f`. An `extern` C function's value is the C
  symbol itself: loaded from its relocated import slot in code, an
  `R_X86_64_64` against the symbol in a static cell.
- **Calls through pointers.** A call through a function-pointer value
  (`f(a, b)` with `f` a variable, field result or parameter) is a
  System V call: the W argument words are moved into registers and a
  16-byte-aligned stack exactly as an `extern` call's shim does
  (`emit_c_abi_call_x64`, here through `r11`), and a narrow integer
  result is extended per the pointer's declared return type. Pointers
  without a signature (`int`, `void*` callees) pass every argument as an
  integer word.
- **Signatures.** Word-sized integers and pointers, the narrow integer
  types, `float32`, `float64`, `void` results, any number of
  parameters, and structs and unions by value. Records follow the
  x86-64 psABI classification (`c_abi_classify`): up to 16 bytes they
  travel in one or two eightbytes, each INTEGER (a general register) or
  SSE (an xmm register, rejected under `--kernel-codegen`); a larger
  record, one with an unaligned field, or one whose eightbytes no longer
  fit in the registers left is copied to the stack (MEMORY). A MEMORY
  result is written through the hidden pointer the caller passes in
  `rdi` and returned in `rax`; a register result comes back in
  `rax`/`rdx`/`xmm0`/`xmm1`. W keeps its own convention inside (record
  arguments as stack words, results through a hidden buffer): the
  adapter, the extern shims and calls through function pointers
  convert. Extern functions taking or returning records get the same
  System V shim in x64 executables too. Rejected with a diagnostic
  naming the function: other multi-word values, W variadic functions
  (`int... xs`), generators, and taking the address of a generic
  function or of a function with no entry (an asm runtime stub). A
  function with an unsupported signature that is neither global nor
  address-taken is fine: its stub jumps to a `ud2` trap nothing
  reaches. A record crossing a function pointer needs the pointer's
  signature.
- **C-variadic definitions.** A trailing `...` parameter, optionally
  named, makes a definition C-variadic:

  ```
  import lib.c_va

  int sum(int n, ... va):
  	c_va_list ap
  	c_va_start(&ap, va)
  	int total = 0
  	for i in range(n): total = total + c_va_arg(&ap)
  	c_va_end(&ap)
  	return total
  ```

  Its adapter stores the six argument registers (and, when `al` is not
  zero and not under `--kernel-codegen`, `xmm0-7`) in a register save
  area in its frame and passes the W body a `void*` to an initialized
  psABI `va_list` (`gp_offset`, `fp_offset`, `overflow_arg_area`,
  `reg_save_area`). `lib/c_va.w` has the C-layout `c_va_list` and
  `c_va_start`, `c_va_arg` (an INTEGER-class word), `c_va_arg_float64_bits`,
  `c_va_arg_record` (the address of a record argument), `c_va_end` and
  `c_va_copy`; a `c_va_list*` is C's `va_list` parameter, so W hands
  its list to `vprintf`-style C functions and back. W calls a
  C-variadic definition like a variadic `extern`: the C convention
  inline (`al` = the vector registers used), through its System V
  entry. The syntax needs `--c-abi` (`w check` accepts it anywhere).
  A struct or union argument of a C-variadic call, among the fixed
  parameters or in the variadic tail, is classified like any System V
  record argument (registers or stack eightbytes; x64 System V only,
  other targets reject it).
- **Restrictions.** `--c-abi` requires `--freestanding` (the W runtime's
  own callbacks keep W's convention) and rejects `--no-direct-calls`
  (a function name's value use must stay distinguishable from a callee).

Next steps for the mode: binding global symbols straight to the
adapters (one `jmp` fewer; today the stub keeps pointer identity),
records aligned beyond 8 bytes on the stack, records with float members
through `c_va_arg_record`, and the same mode for arm64 (AAPCS64
adapters reuse `elf_emit_arm64_export`).

## Relocations

x64 code already reaches data only through RIP-relative address slots,
and every absolute pointer stored in data is a PIE rebase cell
(`docs/projects/pie_aslr.md`). The `WLIB64` static-library writer
(`code_generator/static_library.w`) relies on exactly these records;
`code_generator/elf_object.w` turns them into ELF relocations:

| Site | Relocation |
|---|---|
| Text address slot (`lea`, FFI `call [rip+...]`) reaching data | `R_X86_64_PC32` against the data's section plus offset |
| The same reaching an `extern` data object | `R_X86_64_PC32` against the undefined symbol |
| Pointer cell in data (array headers, string descriptors, address initializers) | `R_X86_64_64` against the target's section |
| The same pointing at an `extern` data object | `R_X86_64_64` against the undefined symbol |
| FFI slot of an `extern` function | `R_X86_64_64` against the undefined symbol |
| `--c-abi`: an FFI shim's `call [rip+slot]` | rewritten to `addr32 call rel32` (`67 e8`), `R_X86_64_PLT32` against the undefined symbol; the slot keeps its relocation only while a function value still loads it |
| Call cell or address slot reaching code in another section | `R_X86_64_PC32` against that section plus offset |
| Call to a weak definition (or its address taken) | `R_X86_64_PLT32` / `R_X86_64_PC32` against the weak symbol |
| Address of weak `extern` data | `lea` becomes `mov` from the GOT, `R_X86_64_REX_GOTPCRELX` |

Text-to-text references (calls, jumps, function addresses) inside one
section are PC-relative and need no relocation; the writer rewrites the
displacement when its two ends land in different pieces of the same
section. Every `call rel32` is recorded while compiling
(`call_relative32`, the export adapters) for this. A slot whose target
lies outside the object is an internal error rather than a silent bad
link.

The object contains `.text` (code), `.data` (initialized mutable
storage), `.rodata` (string literal bytes) and `.bss` (zero-initialized
globals, `NOBITS`) when they are non-empty, the sections named by
attributes (below), `.symtab`, `.strtab`, one `.rela<section>` per
section with relocations, and an empty `.note.GNU-stack`, so linked
programs keep a non-executable stack. `extern` data gets an unused
placeholder in `.data`; every reference to it is relocated to the C
symbol instead. A global goes to `.bss` when its bytes are all zero
and it holds no pointer cell (a W fixed array's header is one, so such
an array stays in `.data`). Nothing relocated ever goes to a `NOBITS`
section: pointer cells, extern function slots and C function-pointer
cells keep their global in `.data` (`ld -r` would drop the records). A
fixed array's header cell is relocated only when some address slot or
pointer cell in the object reaches the header; an array that only C or
a linker script sees (a `.modinfo` string, a `.discard.*` entry) leaves
no `.data` reference into its possibly discarded section.

Two declaration shapes C translators produce get storage of their own
(`grammar/program.w`): a global of a record type completed later in
the file (`static struct s x;` ahead of the body) moves to storage of
the completed size when the body arrives, and the address slots and
pointer cells that took its address meanwhile follow it; a global of a
record with size 0 (one nesting only an empty record, like a
uniprocessor spinlock) still reserves a word, so it never shares an
address or a section with the next declaration (its symbol size stays
0, as gcc's).

## Sections and symbol attributes

Attributes before a function, global or `extern` declaration control
its section, binding and alignment, as a kernel's linker script needs
(`grammar/object_attributes.w`). They go on the declaration's line or
on lines of their own:

```w
@section(".init.text")
export int driver_init():          # code in .init.text (AX)
	return setup(1)

@section(".initcall6.init")
unary* driver_initcall = driver_init_entry   # a table entry

@section(".data..percpu") @align(64)
int per_cpu_counter

@align(4096)
int[512] page_table

@weak
export int arch_hook():            # a strong C definition wins the link
	return 0

@weak
extern int optional_symbol         # undefined weak: address 0 if absent

@alias("driver_init")
int driver_init_alias();           # a second global name, also usable from W
```

| Attribute | Meaning |
|---|---|
| `@section("name")` | Place the function (and its export adapter) or global in section `name`. |
| `@align(n)` | Align the function or global to `n` (a power of two up to 1 MiB); the section's alignment rises to match. |
| `@weak` | `STB_WEAK` binding: on a definition (a function or global symbol that would otherwise be local becomes weak too; for a function that is not exported, that symbol is its W-convention entry) or on an `extern` (an undefined weak reference). |
| `@alias("target")` | On a function prototype or a global without initializer: a second name for `target`'s definition. W code may use either name; the object gets a global symbol at the target's (an exported target's adapter). The target may be defined before or after the alias. |
| `@used` | Accepted for C translators. W never drops an unreferenced function or global, so it changes nothing. |

Section flags follow gcc's rules for what a section holds: functions
give `AX`; data gives `WA`, `A` when the name contains `.rodata`, and
`NOBITS` when it starts with `.bss` (such a global must be
zero-initialized). One section cannot hold both functions and data.
Globals moved out of `.data` are word aligned and packed in declaration
order, so the entries of a table section are contiguous like C's.

Outside `--emit=obj` the attributes are accepted and `@section`,
`@align` and `@weak` change nothing (like `export` on a native
executable); `@alias` works everywhere. Calls from W to a weak
definition in the same object bind to it through its symbol only when
the symbol is the function's W entry: an exported function's weak
symbol is its C adapter, so W callers keep calling the W body.

Function symbols are sized: each runs to the next function entry (or
the end of its section piece), so tools that look code up by address
(objtool, perf, `addr2line`) find the enclosing function. Under
`--c-abi` a function's symbol, local (`static`) or global, is its
System V entry stub, so the stub and its W body are one sized function,
and a C table entry naming a static function lands on its symbol.

System V defines only a narrow integer result's own bits of `rax` (a
`bool` callee may return `setne al` over a pointer still in `rax`), so
an x64 extern's shim zero- or sign-extends `bool`, 8-, 16- and 32-bit
results to the declared type before W reads the word, as calls through
C function pointers and C-variadic calls already did.

Under `--c-abi` a function's global symbol is its System V entry stub,
which sits at the start of the function's range and so lands in its
section; its adapter (or the shared trap) follows it there. `@weak`
makes that symbol weak, and W function values of it (`fp = f`, static
tables) and W calls of it bind through the symbol, so a strong C
definition wins for them too: a call of a weak function is a System V
call of the address the symbol names, never a direct, inlined or
register call of the local body. Declare the function `@weak` (on a
prototype if need be) before its first call; a call that precedes the
attribute still calls the W body. `@alias` gives the
alias the target's entry, both as a symbol and as a W function value.
`static` combines with the attributes: `@section(".init.text") static
int f()` is a local symbol in `.init.text`.

`tests/object_sections_test.w` checks the sections and symbols with
`readelf` and links `tests/object_sections/library.w` into
`tests/object_sections/main.c` with a small linker script
(`sections.ld`, `INSERT AFTER .data`) that collects `.w_initcall.*`
levels in sorted order and a `.w_table` section into tables, which C
and W both iterate, the same under `--c-abi`
(`tests/object_sections/c_abi_library.w`, where C calls the initcall
entries), and checks the diagnostics.

## Two runtime modes

Without `--freestanding` the object keeps W's runtime privately, exactly
like a `--static` library: containers, strings and the allocator work
inside the object, the allocator uses `mmap` so it stays clear of libc's
`brk` heap, and no startup code runs (nothing may depend on `main`'s
argc/argv setup). `tests/object_file/runtime_library.w` uses sets, lists
and maps this way.

`--freestanding` (only with `--emit=obj`) imports no runtime at all: no
auto-imported containers, no allocator, no startup or entry stub, no
libc. A feature that would pull the runtime in is a compile error where
it is used, instead of a link failure later:

- `map`/`set`/`list` types: "'map' types need the W container runtime,
  which --freestanding excludes";
- `new`: "'new' needs the W runtime allocator, ...";
- builtins served by on-demand runtime modules — `print`, f-strings,
  `var`, `to_json`/`from_json`: "this needs the W runtime
  module 'structures.prelude', which --freestanding excludes" (unless the
  program imports that module itself).

A failed bounds check executes `ud2` instead of calling the runtime's
diagnostic helper (unless the program declares `__w_bounds_trap`
before the access).
Explicit `import`s are still honored: importing `lib.lib` brings its
code in, which is the program's choice. The compiler's built-in asm
stubs (`syscall`, `setjmp`, ...) remain as unreferenced local code.

## Kernel code generation

`--kernel-codegen` (only with `--emit=obj --freestanding`) asks for code
that is safe in kernel context, where an interrupt or exception can
arrive on the current stack between any two instructions and the FPU
state belongs to someone else:

```sh
./bin/wv2 x64 --emit=obj --freestanding --kernel-codegen drv.w -o drv.o
```

`tests/kernel_codegen_test.w` checks each property below on
`tests/kernel_codegen/corpus.w`, an integer workload (register-promoted
locals, parked expression registers, recursion, struct copies, narrow
stores, function pointers, `switch`, ten-argument calls, C -> W -> C ->
W chains) linked with a libc-free, `-mno-red-zone` startup
(`tests/kernel_codegen/start.c`).

- **No red zone.** The System V ABI lets user code keep data in the 128
  bytes below `%rsp`; a kernel is built with `-mno-red-zone` because
  interrupts overwrite that memory. W's x64 code never uses it: locals,
  spills and temporaries are pushed (the stack-machine design keeps
  `%rsp` at the top of everything live), parked expression registers
  live in registers, register promotion's saved registers and parameter
  homes are pushed or reserved with `sub rsp` in the prologue, and the
  export adapters and FFI shims (`code_generator/elf_exports.w`,
  `ffi.w`) only push and address `[rbp+disp]` above `%rsp`. Every
  `[rsp+disp]` operand goes through `esp_disp` (`code_generator/x86.w`),
  which under the flag rejects a negative displacement as an internal
  error. The test runs the linked corpus single-stepped under `ptrace`,
  overwriting the 256 bytes below `%rsp` through `/proc/<pid>/mem`
  before every instruction (a signal cannot show this: Linux already
  skips the red zone when it builds a signal frame), and requires the
  same output as a plain run; a C leaf compiled with its red zone is
  the negative control that this clobbering breaks.

- **No SSE, AVX, MMX or x87.** The kernel saves only the general
  registers on entry, so kernel code may not touch the FPU/SSE state.
  W's integer code never does: struct copies, zeroing, array and
  memory moves are word, narrow or `rep`-free integer loops, and the
  prologues, adapters and shims move only general registers. Floating
  point is the only source of SSE (`code_generator/sse.w`; values ride
  the integer pipeline and touch xmm registers inside one operation),
  so under the flag every x86 float emitter, the float paths of the FFI
  shims and export adapters, and float literals stop with "floating
  point is not allowed with --kernel-codegen (no SSE/x87 in kernel
  code)" at the offending line. That covers arithmetic, comparisons,
  conversions, literals, and `extern`/`export` signatures with a float
  parameter or result (an `extern` is rejected where it is declared,
  since its shim is emitted there). A float-typed variable that is only
  copied bit-for-bit emits no SSE and is still accepted. The test
  disassembles the corpus and freestanding-clean library modules
  (`lib/sha256.w`, `lib/hex.w`, `lib/memory.w`, ... — about 50k
  instructions) with `objdump` and rejects any xmm/ymm/zmm/mm/x87
  register, x87 mnemonic or MXCSR/XSAVE instruction, and any operand
  below `%rsp`; a float object built without the flag is the control.

- **Frame pointers.** Every W function already opens with
  `push rbp ; mov rbp,rsp` (`be_function_prologue`; promoted locals'
  registers are pushed after it and popped before `pop rbp`/`leave`),
  as do the export adapters, FFI shims and register entries, and no W
  code allocates `rbp` to anything else. `[rbp]` is the caller's frame
  and `[rbp+8]` the return address, the layout a kernel built with
  `CONFIG_UNWINDER_FRAME_POINTER` walks. The flag changes nothing here;
  the test checks it statically (each direct call target and function
  symbol starts with that sequence) and at run time: C code compiled
  with `-fno-omit-frame-pointer` walks the chain from a C -> W -> C -> W
  -> C call nest back to `_start`, checking each return address lies in
  `.text`. The exceptions are the compiler's built-in assembly stubs
  (`syscall`, `syscall7`, `setjmp`/`longjmp`, `get_context`,
  `gen_switch`, `thread_create`, ...): frameless leaves that a kernel
  object has no use for and that stay as unreferenced local code. A
  kernel built with the ORC unwinder (the x86-64 default) instead needs
  `objtool` to understand each object. String literals are in
  `.rodata` now, but some data tables and descriptor blobs are still
  emitted inside `.text`, which stops it, so such objects must be
  marked `OBJECT_FILES_NON_STANDARD` until those move out as well.

- **Code model.** Kernel code is linked in the top 2GB
  (`0xffffffff80000000` and up; gcc's `-mcmodel=kernel` uses
  sign-extended 32-bit absolute addresses there). W needs no code model
  of its own: x64 code reaches data, `extern` objects, FFI slots and
  functions only RIP-relatively, and every stored pointer is a 64-bit
  word, so an object carries only `R_X86_64_PC32` and `R_X86_64_64`
  relocations, never the `R_X86_64_32`/`32S` forms that overflow above
  4GB. The only constraint is the usual one: `.text`, `.data` and the C
  symbols W references must lie within ±2GB of each other, which a
  kernel image (and any ordinary program) satisfies. The test checks the
  relocation kinds with `readelf -r`, links the corpus with a
  `-mcmodel=kernel` startup by `ld -Ttext-segment=0xffffffff80000000`
  (no truncated relocation; the pointer words to `kc_counter` and
  `kc_add` hold their kernel addresses), and links it at
  `0x7f0000000000` in user space, where it runs and prints exactly what
  the ordinary link prints. This holds with or without the flag.

- **With `--c-abi`.** The flag combines with `--c-abi`
  (`code_generator/c_abi.w`): each 5-byte entry stub is a `jmp` to an
  adapter that opens a standard frame, pushes the System V arguments as
  W words and only pushes below `%rsp`; calls through function-pointer
  values use the FFI shim's frame (`push rbp`, `and rsp,-16`, `call
  r11`). Their xmm moves exist only for float arguments and results,
  which the flag rejects, and `--stack-usage` lists each adapter as
  `name [c-abi]`. The test runs the red-zone, disassembly,
  frame-pointer, code-model and stack-usage checks on the corpus in
  both conventions; the frame check follows each entry stub's `jmp` to
  the adapter it lands in.

- **Discarded reads are performed.** A statement that only reads
  memory (`*p`, a global, `p[i]`, `s.f`) loads it, as a C volatile read
  would; see "Memory accesses" below.

## Stack usage

`--stack-usage` (x86 and x64, any output kind) writes a per-function
report next to the output, `<output minus .o>.su`, in the format of
gcc's `-fstack-usage`, so frames too large for a kernel's 16 KB stack
can be found:

```
drv.w:107:5:kc_promoted	280	static
drv.w:153:12:kc_main [adapter]	56	static
drv.w:12:12:kc_c_mix [c-call]	96	static
```

Each W function's number is the most it takes below its caller's stack
pointer: the return address, `rbp`, saved registers and every word it
pushes (locals, temporaries, outgoing arguments), callees excluded.
`code_generator/stack_usage.w` derives it from the grammar's `stack_pos`
bookkeeping: `emit()` samples the deepest `stack_pos` between the
prologue and the epilogue, which bounds the real depth (parked
expression registers only make the real stack shallower), and the one
frame `stack_pos` does not see, the inline C-call frame of a variadic
`extern` call, is added explicitly. Export adapters (`[adapter]`),
`--c-abi` adapters (`[c-abi]`) and FFI shims (`[c-call]`) have fixed
frames of their own, and a `--c-abi` call through a function pointer
adds its inline C-call frame like a variadic call. W has no
dynamically sized stack allocation, so every entry is `static`. The
test checks the report against the ptrace stepper's measurement of the
linked corpus: no function goes deeper than its entry (the entries are
exact for most functions and one word high for some leaves).

## Memory accesses (volatile)

W has no `volatile` qualifier, so a C translation of volatile objects,
`READ_ONCE`/`WRITE_ONCE` and device registers depends on how the code
generator treats ordinary accesses. The audit for kernel use found that
every global, pointer, subscript and field access the source names is
emitted once, in source order, at the declared width (this holds for all
x86/x64 code, with or without `--kernel-codegen`):

- **No caching across statements.** Register promotion
  (`compiler/regalloc_scan.w`) keeps only locals and parameters in
  registers, never a global, and never a local whose address is taken
  (`int* q = &x` leaves `x` in its stack slot, read and written there).
  A loop condition such as `while (flag == 0)` or `while (*p == 0)`
  reloads every iteration; nothing hoists a load out of a loop
  (induction-variable pointers step the address, the element is still
  loaded each time), and a store followed by a load of the same
  location reloads it.
- **No merging or splitting.** Narrow stores stay narrow (`mov byte`,
  `mov word`, `mov dword`), adjacent ones are not combined, and narrow
  loads use the matching `movsx`/`movzx`. Struct copies move whole
  words then the narrow tail; that is a bulk copy, as in C.
- **No elimination.** Two stores to one location are both emitted; a
  read stays even when its value is unused or multiplied by zero.
  The one fold of a memory read is a `const` integer global whose
  initializer this compilation wrote, loaded as an immediate (O1,
  `const_global_note`): a translator must not mark a C `volatile const`
  object `const`.
- **Discarded reads (`--kernel-codegen`).** An expression statement
  that is only a read -- `*p`, `g`, `p[i]`, `a[i]`, `s.f` -- computes
  the address and stops, dropping the load that C's `(void)*p` or a
  bare `READ_ONCE(x);` performs (a device register read for its side
  effect). Under the flag the AST front end loads it
  (`statement_ast_bare_read`, `code_generator/statement_ast.w`);
  assignment, call, increment and cast roots are unchanged, since they
  already made their accesses. Without the flag the load is still
  dropped: the `--streaming` front end cannot tell such a root apart
  and `tests/ast_expression_test.w` requires both front ends to emit
  identical images, so making it unconditional waits for the streaming
  front end's retirement. `tests/kernel_codegen_test.w` calls each
  bare read of `tests/kernel_codegen/reads.w` on a `PROT_NONE` page
  and requires a fault (address arithmetic alone must not fault);
  `tests/memory_access_order_test.w` (x86 and x64) checks that spin
  loops on a global and on a pointer end when another thread stores,
  and that narrow stores leave their neighbours intact.

Ordering between CPUs is the hardware's: W emits no fences, so a
kernel's `smp_mb()` and friends remain inline assembly (or calls).

## Segment-relative accesses

Kernels keep per-CPU data in a section linked at offset 0 and reach the
running CPU's copy through a segment base (`%gs` on x86-64 Linux, `%fs`
on 32-bit). C spells this with GCC's named address spaces `__seg_gs`
and `__seg_fs`; W has the same two qualifiers (x86 and x64 targets
only, in every output mode):

```w
extern __seg_gs pcpu_hot const_pcpu_hot     # the object lives in gs
__seg_gs int* p                             # points into gs
__seg_gs(task*)* slot                       # points at a task* in gs
int cpu = *cast(__seg_gs int*, cast(uint64, &cpu_number))
```

`__seg_gs T` qualifies the object type T, as `const` does; the
parenthesized form takes a whole type, so a pointer object in the
segment (C's `T * __seg_gs`) is `__seg_gs(T*)`. A load or store of such
an lvalue is the ordinary instruction with the override prefix (`65` /
`64`, ahead of REX: `mov %gs:(%rax),%rax`), at the declared width;
compound assignments and `++` load and store through it. The fields of
a struct in a segment are in that segment. The address of a segment
lvalue (`&x`, `cast(uint64, p)`) is its offset in the segment, which is
the flat address the linker gave the symbol: a translator writes C's
`*(T __seg_gs *)(uintptr_t)&var` as above. Converting between segment
and flat pointers needs a `cast()`.

Only globals and externs live in a segment; a local, a parameter or a
field may point into one but not be in one (`a local variable cannot
live in a segment address space`), and the qualified type must be a
scalar, pointer or struct, not a W array, slice, string or container.
Struct copies to or from a segment are rejected; assign the fields. The
lowering is in the streaming front end (`promote`, `assign_store` and
`seg_override` in `code_generator/x86.w`); the AST front end hands any
expression with a segment lvalue to it. Such an access is never folded
into a later memory-operand form, so each one is a single prefixed
instruction. `tests/object_segment_test.w` links a W object with a C
driver that points `%gs` and `%fs` at a copy of the data with
`arch_prctl` and checks every width, fields, pointer objects, indexing
in a loop and gcc's own `__seg_gs` reads against W's.

## Not covered yet

Rejected with a diagnostic: other targets (`--emit=obj requires the x64
Linux target`), `thread_local` storage, profiling and coverage
instrumentation, and combining with `--static`/`--shared`. Not
diagnosed but unsupported: calling a W function pointer from C without
`--c-abi`, and (untested) the
runtime's panic and stack-trace reporting inside a runtime-retaining
object, which expects a W-built ELF image around its code.

Next steps, roughly in order:

1. **32-bit x86.** Code addresses there are absolute `mov eax,imm32`
   slots (`be_addr_slot_write`), so every address slot — intra-text
   included — needs an `R_386_32`, and the slot list would have to be
   kept for all slots, not only cross-segment ones.
2. **arm64 (Linux, then Darwin Mach-O `MH_OBJECT`).** `adrp`/`add`
   pairs map to `R_AARCH64_ADR_PREL_PG_HI21` / `ADD_ABS_LO12_NC`; the
   static-library slot notes already exist for arm64
   (`arm64_addr_slot_write`).
3. **Kernel-oriented controls.** Section placement, weak symbols,
   aliases, alignment, `.rodata` and `.bss` are done (above), and so is
   the code-generation side: `--kernel-codegen` (no red zone, no
   SSE/x87, frame pointers; see "Kernel code generation"), the
   code-model check, `--stack-usage`, and the volatile/ordering audit
   ("Memory accesses"). Left: symbol visibility (`STV_HIDDEN`),
   `SHF_MERGE` string sections, retpoline/IBT forms for indirect calls
   (`call *%rax` is emitted as is), and the built-in assembly stubs,
   which stay in every object as unreferenced code.
4. **Exported data and C-shaped aggregates.** An explicit marker for
   exported globals (today: any root global), floating-point items in
   brace initializers, and struct arguments by value in the adapters.
5. **Several W objects in one link.** Each object today carries its own
   copy of whatever runtime it uses; a shared freestanding support
   object (or `COMDAT` groups) would let several W objects share one.
6. **Debug info.** DWARF line tables per object (`.debug_line` with
   relocations) so gdb sees W source lines in the linked program.
