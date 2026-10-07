# PIE, ASLR and RELRO for ELF output

Issue #537, following #526's non-executable stack and W^X work.

## Using PIE

```
./bin/wv2 x64 --pie program.w -o program
```

`--pie` is a whole-program option and can appear before or after the
input files. It produces an x64 Linux `ET_DYN` executable, with or
without shared-library imports. The kernel randomizes its image on
exec when system ASLR is enabled. The default remains `ET_EXEC` for
compatibility. Other targets reject `--pie` explicitly.

| Target | Image randomization | Dynamic GOT protection |
|---|---|---|
| x64 Linux with `--pie` | PIE / ASLR | GNU RELRO |
| x64 Linux without `--pie` | Fixed-address | GNU RELRO |
| 32-bit x86 Linux | Fixed-address, deliberate policy below | GNU RELRO |
| arm64 Linux | Fixed-address; PIE remains a separate extension | GNU RELRO |
| arm64 Darwin | Existing Mach-O PIE | Separate Mach-O backend |

## x64 code and data

Address slots use `lea rax,[rip+disp32]`. Their read/write helpers convert
between relative displacements and the compiler's nominal virtual
addresses, including the forward-reference backpatch chains. FFI calls
use `call [rip+disp32]`, and profiling increments also address their
counters relative to RIP. Code needs no load-time relocations and stays
read-execute throughout loading.

The nominal code base remains `0x08048000`, with data 16 MB above it.
These are link addresses, not the runtime addresses of a PIE. Keeping
small nominal addresses lets the 32-bit bootstrap compiler emit exactly
the same image as the 64-bit self-hosted compiler. The relative distances
between code, data and the GOT stay within signed 32-bit reach.

UTF-8 descriptors, global array headers (including arrays nested in
structs), JSON/protobuf descriptor pointers, and the profiler's counter-table pointer are recorded in the
rebase table. x64 file output places UTF-8 descriptors in writable data,
leaving only their string bytes in read-execute text. PIE also places
JSON/protobuf descriptor blobs in writable data and relocates their
pointer fields, while preserving scalar kind/length/offset fields.

* **Static PIE:** no interpreter or libc dependency is added. The entry
  stub computes the load bias with RIP-relative `lea`, then adds it to
  each pointer cell recorded in the rebase table before calling W startup.
* **Dynamic PIE:** each recorded cell gets an `R_X86_64_RELATIVE` RELA
  entry with its linked pointer value as the addend. ld.so handles these
  alongside the existing `GLOB_DAT` and `COPY` relocations. The startup
  rebase table has zero entries, preventing a second adjustment.

PIE headers include `PT_PHDR`; `PT_PHDR` and `PT_INTERP` precede the load
headers. Dynamic PIE advertises `DT_FLAGS_1/DF_1_PIE`. The dynamic table
already resides in the read-only text mapping; `PT_DYNAMIC` now correctly
advertises read-only access so the loader does not try to modify it.
No text relocations are emitted.

## RELRO

All Linux ELF dynamic output already uses eager binding: one GOT slot
and `GLOB_DAT` relocation per imported function, with no lazy PLT.
GOT words grow downward from the data base into dedicated whole pages.
`PT_GNU_RELRO` covers those pages and ld.so makes them read-only after
relocation. Mutable globals and `COPY`-relocated imported objects stay
above that range and remain writable. The dynamic table is itself in
read-only text. PIE preserves this layout and its permissions.

## Runtime and tools

x64 signal thunks use a full-width handler address. Thread-local startup
materializes its block with RIP-relative addressing. Stack traces,
DWARF line lookup and crash reports account for the image's load bias.
`wcore` derives it from the matching dumped ELF/build-id or the kernel
core's `AT_PHDR` auxiliary-vector entry.

For a PIE process, pass the same flag when attaching with a 64-bit debugger:

```
./bin/wdbg64 --attach PID program.w --pie
```

The debugger still checks the on-disk image against its recompile before
trusting symbols. It reads `AT_PHDR` from `/proc/PID/auxv`, then translates
breakpoints, global addresses, disassembly and stepping through that bias.

The REPL uses the same RIP-relative x64 address slots. Its JIT arena stays
`MAP_32BIT` because compiler symbol and chain tables still use 32-bit
nominal addresses. This arena restriction is independent of the ELF
image's load address.

## 32-bit policy

32-bit x86 deliberately stays `ET_EXEC`, with RELRO, W^X and a
non-executable stack. i386 has no RIP-relative data addressing. A GOT
base register would change register allocation and syscall stubs; a
call/pop sequence for each address adds overhead on the bootstrap target.
Text relocations would weaken W^X. i386 PIE is not part of this change.

## Regression coverage

`elf_pie_test` checks static and dynamic headers, relocation destinations,
ASLR across separate execs, forward function pointers, UTF-8 descriptors,
arrays, high-address signal handlers, TLS, stack traces, crash-dump
symbolization, profile output, and the PIE compiler's self-host fixpoint.
It also runs `elf_relro_test` as a PIE: libc calls and mutable imported
data work, `/proc/self/maps` shows the GOT read-only, and a GOT write
faults. `attach_test` covers PIE breakpoints, backtraces, global-pointer
evaluation and stepping. The normal x64 suite continues to exercise the
same RIP-relative code model in fixed-address output.
