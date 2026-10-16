# Native wgrind implementation plan

Issue: https://github.com/reardan/w/issues/651

## Required outcome

W needs a native memory checker that does not execute Valgrind. It must support
both existing executables (including precompiled C libraries) and programs
rebuilt with W compiler assistance. The Valgrind launcher added by #667 does
not satisfy this requirement. Guard pages and canaries alone cannot satisfy it.

Use Valgrind Memcheck as a differential test oracle, not a production dependency.
Initial execution support should be Linux x64, with an explicit supported-platform
matrix. Do not silently run unchecked code on unsupported platforms or opcodes.

The acceptance contract is detection of executed invalid reads/writes, invalid
frees, use after free, and consequential uses of undefined values, together with
allocation/free/origin diagnostics and exit-time leak reporting. Both launch paths
must exercise the same checking semantics. Compiler assistance must not be a
prerequisite for checking a supported prebuilt binary.

This is a multi-stage implementation. Only stage 1 below is implemented in this
change. Native uninitialized-value checking and precompiled-library checking
remain unimplemented; `wgrind --native` still means the guard allocator.

## 1. Correct and bound existing allocator bookkeeping

Implemented:

- A FIFO ordered by **free time**, rather than a cursor advancing through
  allocation order. A live allocation skipped by the old cursor could later be
  freed without its mapping ever being reclaimed.
- Reuse metadata slots after native quarantine reclamation. Metadata capacity
  depends on peak live plus quarantined allocations, not total allocation count.
  Capacity retains its high-water mark; this does not shrink after a temporary
  peak in live allocations.
- Bound auxiliary Memcheck free-history metadata to 4096 entries. This is only
  the existing integration's bookkeeping, not the planned native execution engine.
- Delete index entries before recycling slots, preserving collision chains and
  the newest allocation at an address during index rebuilds.
- Allocation sequence IDs preserve per-test leak snapshots across slot reuse.
- Stop with a diagnostic when free-time protection or quarantine release fails.

The existing native quarantine still has a 32 MiB budget. Allocation still uses
one payload mapping per block. This stage fixes unbounded historical metadata and
quarantine reclamation; it does not remove the per-live-allocation VMA cost.

A local x64 before/after run against main (`b3b8dbc0`) kept 5000 allocations
live while making 72000 temporary allocations, draining every 31 frees. Table
usage changed from 77000 slots / 131072 capacity to 5031 slots / 8192 capacity.
Accounting for the two additional arrays, reserved bookkeeping storage changed
from 7 MiB to 576 KiB. These figures describe bookkeeping arrays, not total RSS.
The two-block out-of-order-free reproducer left 4096 quarantined bytes after an
explicit drain on main and zero with the FIFO fix. The committed metadata test
covers both workloads on x86 and x64.

## 2. Shared shadow state and diagnostics

Build a runtime independent of the application allocator. Sparse shadow pages
record addressability, bit-level definedness, and interned origin IDs; register
shadow state is per thread. Keep mappings, allocation objects, and value origins
separate. Application allocations must not recursively allocate checker metadata.

Required transitions:

- `malloc`: addressable payload, undefined values, inaccessible redzones.
- `calloc`: defined zero payload; check size multiplication overflow.
- `free`: inaccessible payload; retain allocation/free traces within a bounded
  quarantine. Metadata recycling must not revive shadow state accidentally.
- `realloc`: preserve definedness and origins for the copied prefix; new tail is
  undefined; failed growth leaves the old allocation and shadow unchanged.
- Copy/move: propagate shadow rather than complain merely because undefined
  bytes were copied. Include overlapping moves and struct padding.
- Definedness propagates through arithmetic, shifts, masking, comparisons and
  conditional moves. Known bits can make results defined (for example `x & 0`).
  Report when undefined data influences control flow, an address, or externally
  visible output, rather than reporting every load of padding.
- Mappings and stack growth/shrink update addressability and initialized state.
  File-backed mappings, anonymous mappings and kernel-written memory have
  different initialization rules.

Diagnostics must name the access site, size, allocation-relative offset,
allocation/free sites and undefined-value origin. Include deterministic error
codes and a machine-readable format. Unsupported operations must produce an
incomplete-check result distinct from a clean execution and a detected error.

## 3. Native execution of existing binaries

Implement a Linux x64 execution frontend with instrumented basic blocks and a
translation cache. The existing `libs/asm` decoder is useful infrastructure but
its documented W-output subset is insufficient for arbitrary C libraries.
Before using it for execution, give decoding a strict error result (the current
one-byte `.byte` fallback is appropriate for display, not execution), and add
explicit read/write/flag semantics for every supported instruction.

Start with a deliberately limited, fail-closed instruction set and grow it
against real ELF executables. Register aliases, partial-register writes, flags,
RIP-relative addressing, FS/GS, string operations, atomics, SIMD and floating
point all need defined shadow semantics. Check addresses before executing memory
operations. Preserve native ABI register state, signal behavior and faults.

Intercept allocation APIs in W and libc, including allocation failures and
realloc edge cases; handle loader resolution, indirect calls and symbol versions.
Do not infer that tracing malloc alone checks C code: instructions *inside* each
shared library must execute through instrumentation too. Stripped binaries,
static binaries, custom allocators and JIT code need explicit support or a clear
unsupported result. Avoid silently treating arbitrary mapped heap as defined.

A ptrace single-step frontend can serve as a correctness reference for small
fixtures; it is not an acceptable performance solution for allocation-heavy
applications. No subprocess invocation of Valgrind or another checker may supply
the production result.

## 4. Compiler-assisted W path

Add a whole-program checking flag and a versioned instrumentation manifest.
Compile loads, stores, value operations, control-flow uses and runtime helpers
against the same shadow semantics as the binary frontend. Carry allocation and
source metadata directly from the compiler where possible.

Audit **all** emission paths, including streaming and retained ASTs, optimized
addressing modes, register promotion, increments, struct copies, bitfields,
closures, generators, inline assembly and explicit syscalls. Unsupported
constructs must fail compilation or transfer to the binary frontend, never run
unchecked. Checking must survive optimization without duplicated evaluation or
changed program behavior.

Crossing from instrumented W into precompiled C transfers to the binary frontend
with the same shadow memory. Returning restores register/value shadow state.
Compiler-inserted checks alone cannot certify a precompiled library.

## 5. OS boundaries, threads and leaks

Model syscall inputs and outputs, including partial reads, vectored I/O,
failed calls, mapping operations, signal frames, thread creation and TLS.
Kernel writes define only bytes actually written; unchecked marking of whole
buffers would hide bugs. Unknown ioctls and device interfaces must be reported
as unsupported until their memory contracts are modeled.

Keep thread state isolated, synchronize shared shadow updates, and test signals,
fork/exec and allocator reentrancy. Access checking is not race detection.

At process exit classify live allocations by reachability from application
roots, excluding checker tables from those roots. Report direct and indirect
leaks, interior-pointer ambiguity and reachable blocks separately. Keep strict
all-live-block reporting as an explicit policy rather than conflating it with
unreachable leaks.

After access checks are reliable, pool native payload storage and use software
redzones plus a bounded quarantine. Measure payload, shadow, origins, translation
cache, resident memory and VMA counts separately. This is the step that can
remove one mapping per live allocation without giving up access checks.

## Acceptance and rollout

Every supported behavior needs both an offending and a clean fixture. Run the
same fixture through native binary mode, compiler-assisted mode, and Valgrind;
compare error class and relevant source/allocation location, not wording.
Valgrind belongs only in this differential test lane.

Required cases include:

- One-byte and wide under/over-reads/writes, crossing allocation/page boundaries,
  UAF reads/writes, invalid/interior/double frees and address reuse.
- Heap and stack undefined values, bitwise-defined results, partial stores,
  copied undefined bytes, initialized struct fields with undefined padding,
  realloc prefix/tail behavior and origin propagation through multiple functions.
- C-library allocations and memory accesses, C/W crossings, aliases, optimized
  libc routines and stripped supported executables.
- Short/failed I/O, readv/writev, mmap/munmap/mremap, signals, threads and TLS.
- Leaked, reachable, indirect and interior-pointer-reachable allocations.
- Unsupported instructions, syscalls, binary formats and assembly: explicit
  incomplete-check failures, never false success.
- Long churn with out-of-order frees, a stable live set and bounded metadata;
  many simultaneously live small allocations without raising vm.max_map_count.
- Clean compiler bootstrap and representative allocation-heavy W applications;
  record slowdown, peak RSS, shadow size and VMA count against normal execution
  and Memcheck before setting performance claims.

The final command-line default can change only after supported cases pass in
both paths, coverage gaps are explicit, and clean real applications run without
false positives. Until then, expose any execution frontend as experimental and
keep this issue open. Passing allocator tests alone is not the completion gate.
