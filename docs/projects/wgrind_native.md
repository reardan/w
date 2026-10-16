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

This is a multi-stage implementation. Stage 1 and the shared event-driven shadow
engine described in stage 2 are implemented. Neither execution frontend is wired
to that engine yet: automatic native uninitialized-value checking and
precompiled-library checking remain unimplemented. `wgrind --native` still means
the guard allocator. The new engine is internal infrastructure, not a claim that
existing programs are now checked at instruction level.

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

Implemented in `libs/wgrind/` with no Valgrind runtime dependency:

- `shadow.w`: sparse 4 KiB shadow pages, byte read/write permissions, eight
  undefined bits per application byte, and an origin token per byte. Unknown
  addresses are inaccessible. Loads and copies propagate undefined bits without
  reporting a consequential use. Whole-range checks precede shadow stores/copies.
- `heap.w`: allocation, checked calloc sizing, free and realloc events; an AVL
  index detects live overlap, an exact-address hash identifies frees, and a
  bounded free-order history retains allocation/free sites. Failed realloc keeps
  the original state; moved and in-place realloc preserve prefix definedness and
  give new tail bytes the resize origin.
- `values.w`: word-sized bitwise, addition/subtraction, equality, shifts and
  truth-value propagation. Known bits can eliminate uncertainty (`x & 0`,
  `x | -1`, a known differing comparison bit). Addition/subtraction propagate
  possible carry bits; shifts merge all possible normalized counts rather than
  reporting a mere use of an undefined count. Unsupported operations and widths
  report incomplete.
- `registers.w`: separate frontend-owned integer register files with byte
  origins, partial-register updates and explicit clearing of upper bits for
  x64 EAX-style writes. This models integer aliases; it is not thread scheduling
  or SIMD/flags support.
- `report.w`: deterministic JSON diagnostics with error kind/code, failing
  address, access size, access/origin/allocation/free tokens and allocation-relative
  offset. Error attribution picks a containing retained object or the nearest
  edge within 64 bytes, preferring live objects over overlapping freed history.
  Ties among freed objects select the latest free, not hash-table order.
  It does not claim that arbitrary distant addresses belong to an allocation.

The engine allocates checker metadata from private mmap-backed 256 KiB slabs,
without calling the application allocator. Pages and allocation records are
reused. Callers set page, allocation-record and freed-history limits in
`wg_create`; exhaustion produces `WG_INCOMPLETE`, never silently unchecked
execution. Reserved storage retains its high-water mark until `wg_destroy`.
The straightforward shadow representation currently costs six bytes per tracked
application byte on x86 and ten on x64, plus tables/slab overhead; compression
and performance work remain necessary.

### Event API contract

Check both the pointer returned by `wg_create` and its `error` field before use.
The caller supplies real application addresses and stable site/origin tokens;
the engine never dereferences application data. `wg_load` fills only definedness
and origin; the frontend supplies the actual `wg_value.value`. Access checks must
run **before** the corresponding machine access. Calling `wg_use` reports a
consequential use (branch, computed address, etc.), not a mere copy.
For truth-value branches, first apply `wg_nonzero`: a value with undefined bits
can still have a defined truth value when a known bit is one. Zero site/origin
tokens indicate unavailable attribution; frontends must supply or attach their
current instruction/source location when an operation reports an error.

`wg_allocate`/`wg_callocate` describe successful allocator events. A null result
is ignored. `wg_reallocate` takes an explicit success bit so failed realloc and
a successful zero-size free cannot be confused. Heap backing mappings/redzones
must remain inaccessible to application accesses except for allocated payloads:
marking a whole allocator arena addressable would hide bounds errors. Frontends
must distinguish allocator-internal accesses from application accesses. The event
engine alone neither intercepts allocator calls nor establishes those policies.

`wg_mark` supplies mapping/stack transitions. `wg_kernel_read` checks a kernel
input buffer for addressability and definedness; `wg_kernel_write` defines only
the actual successful output byte count, leaving tails and failed calls unchanged.
These helpers are not a syscall decoder or syscall interception layer.

Return zero means checking failed; inspect `error`. Codes 1–6 are memory/value
errors and 100 means checking is incomplete. The first error is sticky; an
explicit `wg_clear_error` can resume after ordinary errors. Incomplete errors
cannot be cleared because resource failures can leave partially installed state;
the frontend must terminate that checking run. These are engine error codes,
not new `wgrind` command-line exit codes.

Contexts are single-owner/externally synchronized. Each application thread needs
its own register file; shared-memory event synchronization remains frontend work.
Origins are stable opaque tokens, not yet interned stack traces. Each scalar
`wg_value` carries one representative origin: combining bytes from distinct
origins can lose precise attribution even though definedness is preserved.
Source symbolization, full instruction/flag/SIMD semantics, automatic mappings,
stack and syscall events, and reachability-based leak classification remain open.
The `live_blocks`/`live_bytes` counters count unfreed allocations, not proven leaks.

### Validation

`wgrind_shadow_test` and its x64 twin cover cross-page/wide accesses, partial
stores, use after free, invalid/double frees, address reuse, overlapping moves,
calloc overflow, failed/moved/in-place realloc, short/failed kernel output,
bounded churn and explicit resource exhaustion. An independent concrete-value
oracle exhaustively checks all pairs of four-bit abstract values (81 states per
operand) for six binary operations, including carry propagation into higher bits.
Another exhaustive oracle checks shifts with both undefined data and counts,
including sign-bit extension and results that become defined independently of
the count.
Word-sized cases exercise high-bit shifts and register aliases/thread isolation.

`wgrind_report_test` and its x64 twin parse diagnostics as JSON, check deterministic
output, full-width hexadecimal addresses, signed integer extremes and output
failure. A manually instrumented real-allocation consumer tests copied undefined
data, masking and invalid access/free attribution. It is explicitly **not** an
automatic compiler or binary execution test. The x64 engine/diagnostic tests also
run clean under Memcheck as a development check; full differential testing of
both execution frontends remains a later acceptance requirement.

### Remaining semantic requirements

The complete engine and frontends must support these transitions:


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
