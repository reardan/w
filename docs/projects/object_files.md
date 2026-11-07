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
  `objtool` to understand each object; literal bytes kept in `.text`
  stop it today, so such objects must be marked
  `OBJECT_FILES_NON_STANDARD` until read-only data moves out of `.text`.

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
`extern` call, is added explicitly. Export adapters (`[adapter]`) and
FFI shims (`[c-call]`) have fixed frames of their own. W has no
dynamically sized stack allocation, so every entry is `static`. The
test checks the report against the ptrace stepper's measurement of the
linked corpus: no function goes deeper than its entry (the entries are
exact for most functions and one word high for some leaves).

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
