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
  the C symbol. Supported signatures are those of native exports:
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
  pointers match C directly; a fixed array `int[4] a` is a W array
  (a two-word header, then the elements), not a C array.
- **Static pointer data.** File-scope address initializers
  (`grammar/program.w`, `global_address_initializer`) make static pointer
  tables expressible: `int* p = &g`, `unary* f = some_function` (defined
  before or after) and `char* s = c"text"`. They work in every native
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
  types, `float32`, `float64` and `void` results. Rejected with a
  diagnostic naming the function: struct (or union) arguments or results
  by value, W variadic functions (`int... xs`), more than 10
  parameters, generators, and taking the address of a generic function
  or of a function with no entry (an asm runtime stub). A function with
  an unsupported signature that is neither global nor address-taken is
  fine: its stub jumps to a `ud2` trap nothing reaches.
- **Restrictions.** `--c-abi` requires `--freestanding` (the W runtime's
  own callbacks keep W's convention) and rejects `--no-direct-calls`
  (a function name's value use must stay distinguishable from a callee).

Next steps for the mode: struct arguments and results by value (the
System V classification of small aggregates into registers, and the
hidden result pointer for large ones), C-variadic W functions (`va_list`
over the register save area), binding global symbols straight to the
adapters (one `jmp` fewer; today the stub keeps pointer identity), and
the same mode for arm64 (AAPCS64 adapters reuse `elf_emit_arm64_export`).

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
an array stays in `.data`).

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

Under `--c-abi` a function's global symbol is its System V entry stub,
which sits at the start of the function's range and so lands in its
section; its adapter (or the shared trap) follows it there. `@weak`
makes that symbol weak, and W function values of it (`fp = f`, static
tables) bind through the symbol, so a strong C definition wins for them
too, while direct W calls keep calling the W body. `@alias` gives the
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

## Not covered yet

Rejected with a diagnostic: other targets (`--emit=obj requires the x64
Linux target`), `thread_local` storage, profiling and coverage
instrumentation, and combining with `--static`/`--shared`. Not
diagnosed but unsupported: calling a W function pointer from C without
`--c-abi`, C consumers of W fixed arrays as plain arrays, and (untested) the
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
   aliases, alignment, `.rodata` and `.bss` are done (above). Left:
   symbol visibility (`STV_HIDDEN`), `SHF_MERGE` string sections, and a
   no-red-zone/no-SSE audit of the generated code and adapters. The
   adapter already preserves every System V callee-saved register;
   interrupt-context use needs that audit.
4. **Exported data and C-shaped aggregates.** An explicit marker for
   exported globals (today: any root global), C-layout arrays, and
   struct arguments by value in the adapters.
5. **Several W objects in one link.** Each object today carries its own
   copy of whatever runtime it uses; a shared freestanding support
   object (or `COMDAT` groups) would let several W objects share one.
6. **Debug info.** DWARF line tables per object (`.debug_line` with
   relocations) so gdb sees W source lines in the linked program.
