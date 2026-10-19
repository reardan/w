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
  command-line root files are `GLOBAL`. `extern` functions and data
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
  callers; C should call exported functions by name.

## Relocations

x64 code already reaches data only through RIP-relative address slots,
and every absolute pointer stored in data is a PIE rebase cell
(`docs/projects/pie_aslr.md`). The `WLIB64` static-library writer
(`code_generator/static_library.w`) relies on exactly these records;
`code_generator/elf_object.w` turns them into ELF relocations:

| Site | Relocation |
|---|---|
| Text address slot (`lea`, FFI `call [rip+...]`) reaching data | `R_X86_64_PC32` against `.data` plus offset |
| The same reaching an `extern` data object | `R_X86_64_PC32` against the undefined symbol |
| Pointer cell in data (array headers, string descriptors, address initializers) | `R_X86_64_64` against `.text` or `.data` |
| The same pointing at an `extern` data object | `R_X86_64_64` against the undefined symbol |
| FFI slot of an `extern` function | `R_X86_64_64` against the undefined symbol |

Text-to-text references (calls, jumps, function addresses) are
PC-relative inside `.text` and need nothing. A slot whose target lies
outside the object is an internal error rather than a silent bad link.
The object contains `.text` (code and read-only literals), `.data` (all
mutable storage; there is no separate `.bss`), `.symtab`, `.strtab`,
`.rela.text`, `.rela.data` and an empty `.note.GNU-stack`, so linked
programs keep a non-executable stack. `extern` data gets an unused
placeholder in `.data`; every reference to it is relocated to the C
symbol instead.

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
diagnosed but unsupported: calling a W function pointer from C, C
consumers of W fixed arrays as plain arrays, and (untested) the
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
3. **Kernel-oriented controls.** Section placement and attributes
   (`.text.*`, read-only data split out of `.text`, a real `.bss`,
   alignment), symbol visibility, and a no-red-zone/no-SSE audit of the
   generated code and adapters, so a kernel's linker script can place W
   code. The adapter already preserves every System V callee-saved
   register; interrupt-context use needs that audit.
4. **Exported data and C-shaped aggregates.** An explicit marker for
   exported globals (today: any root global), C-layout arrays, and
   struct arguments by value in the adapters.
5. **Several W objects in one link.** Each object today carries its own
   copy of whatever runtime it uses; a shared freestanding support
   object (or `COMDAT` groups) would let several W objects share one.
6. **Debug info.** DWARF line tables per object (`.debug_line` with
   relocations) so gdb sees W source lines in the linked program.
