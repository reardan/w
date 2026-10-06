# PIE, ASLR and RELRO for ELF output

Issue #537, the long-horizon follow-up to #526 (non-executable stack,
guard pages, sigaltstack; see `docs/projects/wx_split.md`).

Status, October 2026:

| Item | State |
|---|---|
| `PT_GNU_RELRO` for dynamically linked output (x86, x64, arm64 Linux) | **Landed** (this doc's first stage) |
| x64 RIP-relative code model | Designed below, deferred |
| `ET_DYN` / PIE with the relocations it needs | Designed below, deferred |
| 32-bit x86 PIE | Recommendation: stay fixed-address (below) |

Every W ELF executable is still `ET_EXEC` at the fixed base
`0x08048000` with its R+W data load at base + 16MB, so no W binary
gets ASLR for its own image. The stack, heap, `mmap` regions and shared
libraries are randomized by the kernel as usual.

## 1. RELRO (landed)

### Before

Imports bind eagerly: every `extern` / `c_import` function gets one GOT
word and one `GLOB_DAT` relocation, and ld.so writes the resolved
address before the entry point runs (no PLT, no lazy binding;
`code_generator/elf_dynamic.w`). Under the W^X split those words lived
in the R+W data load, interleaved with ordinary globals, and stayed
writable for the life of the process. A memory-corruption bug that
reached a GOT word could redirect every later call to that import.

### After

On the Linux ELF targets (`target_os == 0` with `data_split`, so x86,
x64 and arm64), `dyn_emit_import_slot` (`code_generator/dynamic_registry.w`)
allocates GOT words **downwards from the data base**: slot *k* is
`data_offset - (k + 1) * word_size`. A slot's address is final the
moment it is allocated, which the single-pass compiler needs (the FFI
shim embeds it immediately), and no import count is needed up front.

At finish, `elf_patch_load_segments` (`code_generator/elf_all.w`)
rounds the GOT up to whole pages (`dyn_relro_size()`), starts the R+W
load that many pages below the data base, writes the pages' zero bytes
into the file ahead of the data, and fills program header slot 5 with

```
GNU_RELRO  offset = data load's offset   vaddr = data load's vaddr
           filesz = memsz = GOT pages    flags = R   align = 1
```

ld.so applies the relocations and then `mprotect`s exactly those pages
read-only (`_dl_protect_relro` rounds the end *down*, which is why the
range must be whole pages with nothing else in them). For one import
the run-time map looks like:

```
08048000-08068000 r-xp ...  text
09047000-09048000 r--p ...  GOT (RELRO)
09048000-0904a000 rw-p ...  globals, COPY-relocated data
```

What stays writable: COPY-relocated data objects (`extern int optind`,
`extern FILE* stdout`) are emitted into the ordinary data area above
the base, because the program legitimately writes them. Imported
arrays (`ci_import_data_array`) take a GOT-shaped pointer slot and so
become read-only, which matches C (an array name is not assignable).

Layout cost: program headers went from 6 to 7 (slot 5 is
`PT_GNU_RELRO`, `PT_NULL` in a static image), so every entry point
moved by one header (32 or 56 bytes); a dynamic image's file grows by
whole pages: one per 1024 (x86) or 512 (x64, arm64) imports, rounded
up. win64 (IAT slots stay
in `.data`) and Mach-O are unchanged.

No `DT_FLAGS`/`DF_BIND_NOW` is emitted: there are no `JUMP_SLOT`
relocations to bind lazily, so "full RELRO" and "partial RELRO" are the
same thing here.

Tests: `elf_wx_segment_test` asserts the header (whole pages, ends at
the data base, every `GLOB_DAT` target inside it, every `COPY` target
outside it); `elf_relro_test` / `elf_relro_64_test` run a dynamically
linked program that calls libc through the GOT, writes its
COPY-relocated `optind`, finds its GOT page `r--p` in
`/proc/self/maps`, and checks that a write to a GOT slot faults with
SIGSEGV.

## 2. Why the image is fixed-address today

Everything below is what an `ET_DYN` image would have to stop assuming.

- **Code materializes absolute addresses.** `be_addr_slot_emit`
  (`code_generator/arm64.w`, shared by the x86 family) emits
  `mov eax, imm32` for every symbol address: globals, string literals,
  function pointers, generic instantiations, lazily emitted runtime
  helpers. The imm32 also doubles as the link cell of the backpatch
  chain for forward references (`addr_chain_link` /
  `addr_chain_patch` in `compiler/symbol_table.w`). On x64 the
  zero-extended imm32 is what pins the image into the low 2GB
  (`image_begin(134512640)` in `elf_image_headers`, elf_all.w; the
  `ET_EXEC` type in `elf_header_fields`).
- **Calls through the GOT use absolute memory operands.** x64 FFI shims
  emit `call qword [abs32]` (`code_generator/ffi.w`
  `emit_c_abi_call_x64`), x86 `call [abs32]`.
- **Data cells hold absolute pointers.** String descriptors, global
  array headers and a few other pointer-valued initializers are
  recorded with `rebase_note` on every target, but only the arm64
  entry stub applies the table (`arm64_entry_rebase_stub`,
  elf_arm64.w), and only the Mach-O output actually slides.
- **Runtime code assumes a low, fixed image.** `lib/signal.w` builds x64
  signal thunks with `mov eax, imm32` handler addresses ("the image
  loads in the low 2GB"); `repl/core.w`'s `repl_inprocess_setup` maps
  its JIT buffer `MAP_32BIT` because the codegen embeds addresses as
  32-bit immediates, and `lib/memory_freelist.w` keeps `malloc` chunks
  `MAP_32BIT` on x64 for the same in-process eval.
- **Tools assume load address == link address.** wdbg's attach mode
  (`debugger/attach.w`, "symbolization calibration") compares
  `/proc/<pid>/exe` with a fresh compile and treats the mapping delta as
  zero; `lib/stack_trace.w`, `lib/crash_dump.w` and `tools/wcore.w`
  symbolize with link-time `.symtab` / `.debug_line` addresses.
  `st_code_address` already exists for the darwin slide and is the
  natural place to subtract a load bias.

## 3. x64: a RIP-relative code model (deferred)

The arm64 backend already did this work: its address slot is an
`adrp` + `add` pair that is PC-relative, with
`arm64_addr_slot_write/read` converting between the absolute value the
compiler threads through the slot and the PC-relative immediates
(including backpatch-chain links, which are arbitrary 31-bit values).
The x64 plan copies that shape:

1. `be_addr_slot_emit` on x64 emits `lea rax, [rip + disp32]` (7 bytes,
   `48 8d 05 disp32`) instead of `mov eax, imm32` (5 bytes). The slot
   position stays "the last 4 bytes", so callers that pass
   `codepos - 4` are unchanged.
2. `be_addr_slot_write(pos, v)` stores `v - (code_offset + pos + 4)`;
   `be_addr_slot_read` adds it back. Chain links survive the round
   trip exactly as on arm64 (they are only ever read back through the
   same helpers).
3. FFI shims switch to `call qword [rip + disp32]` (`ff 15`), and the
   GOT stays reachable because it is within ±2GB of the code by
   construction (16MB apart).
4. Global loads/stores already go through an address slot then a
   register-indirect access, so they need no separate change; any
   remaining `[abs32]` SIB forms (`04 25 disp32`) have to be found and
   converted (a disassembly sweep of wv2_64 for `ModRM.rm=100, SIB
   base=101, mod=00` is the cheap audit).
5. The constant-folding note (`imm_note_*` in `x86.w`) must keep
   ignoring address slots: it already does, because only
   `mov_eax_int` sets the note.

Costs: two extra bytes per address materialization, plus one fixpoint
round where wv2_64 (old model) and wv3_64 (new) differ. Nothing in the
x64 pipeline needs relocations for code after this change, so the code
segment stays read-execute and shared.

The 32-bit-pointer assumptions in item 2 of section 2 (`lib/signal.w`,
`repl/core.w`, `memory_freelist.w`) then become independent of the
image and can be lifted separately: the signal thunk can use
`movabs rax, imm64`, and the REPL keeps `MAP_32BIT` until its own
codegen path is moved to the same model.

## 4. `ET_DYN` / PIE and the relocations it needs (deferred)

With code position-independent, the remaining absolute values are data
cells. Two ways to fix them up, both already half-built:

- **Self-rebase (static PIE).** Emit `ET_DYN` with no `PT_INTERP`; the
  kernel loads it at a random base. The entry stub computes the slide
  (`lea rax, [rip]` minus its link address) and walks the existing
  rebase table, exactly as `arm64_entry_rebase_stub` does. Cheapest
  route; works for static images, which is most W binaries.
- **`R_*_RELATIVE` relocations (dynamic PIE).** When the image already
  has `PT_INTERP`, emit one `R_X86_64_RELATIVE` (`R_386_RELATIVE`,
  `R_AARCH64_RELATIVE`) per rebase-table entry into `.rela.dyn` and let
  ld.so apply them before it applies RELRO. `GLOB_DAT` targets become
  base-relative automatically because ld.so adds `l_addr` to every
  `r_offset`. The self-rebase stub must not also run (double slide):
  pick one mechanism per image.

Either way: `e_type = ET_DYN`, link base 0 (conventional; a nonzero
`p_vaddr` also works, since the kernel slides an `ET_DYN` image as a
whole), `PT_PHDR` for ld.so, `DT_FLAGS_1 =
DF_1_PIE` for tools that care, and the GOT/RELRO layout from section 1
unchanged (it is already relative to the image). The tools in section
2 then need the load bias: read it from `AT_PHDR - phdr link address`
(auxv) or `/proc/self/maps`, and subtract it in `st_code_address`,
wcore and wdbg attach.

Data cells that still escape the rebase table would be silent bugs
(a pointer into the unslid image), so the PIE change needs a check: an
`ET_EXEC` image loaded at its link base plus an `ET_DYN` twin loaded
elsewhere, run over the full `tests_x64` umbrella, with the crash
report's pc symbolization as the canary.

## 5. 32-bit x86: recommendation

**Keep 32-bit x86 fixed-address (`ET_EXEC`), with RELRO, W^X and
`PT_GNU_STACK`; do not build i386 PIE.**

- i386 has no PC-relative data addressing. Position-independent code
  must dedicate a register to the GOT/image base (the classic
  `call __x86.get_pc_thunk.bx` + `ebx` convention) or recompute it with
  a `call`/`pop` before every address materialization. Reserving `ebx`
  ripples through every runtime stub that uses it (the `int 0x80`
  syscall wrappers pass their first argument in `ebx`), and the
  alternative of a `call`/`pop` per address adds ~6 bytes and a call
  to the hottest instruction sequence, on the target that is also the
  bootstrap seed.
- The alternative of text relocations would make the text writable at
  load time, undoing the W^X split.
- The payoff is small: the i386 mmap layout gives an `ET_DYN` image
  roughly 8 bits of entropy, which brute force defeats quickly.
- 32-bit is the seed/bootstrap target, where layout stability is worth
  more than hardening, and its users are expected to be toolchain
  bring-up rather than exposed services.

Revisit only if a 32-bit target ever runs untrusted input in
production, in which case the `call`/`pop` thunk per function prologue
(caching the base in a stack slot, not a register) is the
least-invasive design.

## Deferred, in order

1. x64 RIP-relative address slots and FFI calls (section 3), with the
   `[abs32]` audit.
2. Static-PIE `ET_DYN` for x64 using the existing rebase table and a
   self-rebase entry stub; load-bias support in `lib/stack_trace.w`,
   wcore and wdbg attach.
3. Dynamic PIE via `RELATIVE` relocations, and the x64 signal thunk /
   REPL `MAP_32BIT` cleanups.
4. arm64 Linux `ET_DYN` (the code is already PC-relative; only the
   container and the tooling bias remain).
