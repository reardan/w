# ARM64 Backend for W (Apple M3, Mach-O, Pointer Authentication)

Plan for adding an AArch64 backend targeting Apple Silicon (M3) hardware,
including pointer authentication (PAC). Companion to the x64 work, which is the
template this plan follows: same grammar, a per-target instruction module, a
per-target container writer, an `__arch__` runtime split, and a CLI target
flag (`docs/projects/cuda.md` describes the same pattern for PTX).

**Status: Stages 1–3 implemented.** `w arm64 file.w` compiles to a static
AArch64 Linux ELF: the A64 emitter (`code_generator/arm64.w`), runtime stubs
(`arm64_asm.w`), two-segment W^X ELF writer (`elf_arm64.w`) and Darwin-less
Linux syscalls (`lib/__arch__/arm64/`) are all in place, with `--pac=ret`
return-address signing on by default. The full toolchain self-hosts: the
x86 compiler cross-compiles `w.w` to arm64, and running that binary under
`qemu-aarch64 -cpu max` recompiles `w.w` byte-for-byte (`./wbuild verify_arm64`).
A 34-test slice of the suite passes under qemu (`./wbuild arm64_smoke_test`
covers a representative subset), and `./wbuild verify` / `verify_x64` stay
byte-identical. Stage 4 (Mach-O + Darwin syscalls + signing, plus native
Darwin self-hosting and dynamic linking) and Stage 5 (`--pac=off|ret|full`,
function-pointer signing, arm64e — see the execution notes in D6) are
landed as well. The core codegen model was first validated with the
hand-written A64 spikes in the appendix.

Build/run: `./wbuild build` then `./wbuild verify_arm64` (self-host fixpoint) and
`./wbuild arm64_smoke_test`; both need `qemu-aarch64-static`. Compile a single
program with `./bin/wv2 arm64 file.w -o out && qemu-aarch64-static -cpu max out`.

## Target definition: what "Apple M3" implies

Four mostly-independent layers, only the first of which exists in any form
today:

1. **ISA** — A64 (AArch64). The M3 cores implement Armv8.6-A. Fixed 4-byte
   instructions, 31 GP registers, PC-relative addressing (`adr`/`adrp`),
   `svc` for syscalls.
2. **OS ABI** — Darwin, not Linux: different syscall convention (`x16` +
   `svc #0x80`, carry-flag errors) and numbers, `x18` reserved, no stable
   raw-syscall contract (Apple's supported entry is libSystem).
3. **Container** — Mach-O, not ELF: load commands instead of program headers,
   `__PAGEZERO`, strict W^X on Apple Silicon (no RWX segment, unlike the
   single RWX PT_LOAD W emits today), mandatory ad-hoc **code signature**
   (kernel SIGKILLs unsigned arm64 binaries), PIE + ASLR slide.
4. **Pointer authentication** — the M3 has FEAT_PAuth, FEAT_PAuth2 and
   FEAT_FPAC (immediate trap on authentication failure; the M1 lacks
   PAuth2/FPAC). Two distinct levels:
   - *Compiler-internal PAC*: sign return addresses and W function pointers
     with our own conventions. No external ABI to match; works in any slice.
   - *arm64e ABI*: Apple's PAC ABI (cpusubtype `CPU_SUBTYPE_ARM64E`). It was
     preview-only for years; Apple stabilized it for third parties in
     macOS 26 ("Enhanced Security", `ENABLE_POINTER_AUTHENTICATION`). In a
     plain `arm64` process macOS disables the PAC keys, so `pacia`/`autia`
     execute as no-ops — real enforcement on macOS requires the arm64e slice.

The layers are separable, and the plan exploits that: **A64 + Linux + ELF** is
fully testable today under `qemu-aarch64` in CI, while Darwin + Mach-O +
arm64e land as later stages that reuse the finished ISA backend unchanged.

## What W's backend model is today (recap)

- Single-pass, syntax-directed: grammar rules emit machine bytes immediately
  through helper functions in `code_generator/x86.w` (~64 helpers:
  `push_eax`, `alu_add`, `jmp_zero_int32`, ...). x64 is the same module plus
  a REX.W prefix (`emit_x64_opcode()`) and `word_size == 8` branches.
- Evaluation is a stack machine: `eax`/`rax` is the accumulator, `ebx` the
  secondary, operands spill with `push`/`pop`, locals and arguments are
  addressed `[esp + k]` with `stack_pos` bookkeeping (`sym_get_value` in
  `compiler/symbol_table.w`).
- The container writer is a one-shot static ELF emitter (`elf_32.w` /
  `elf_64.w`) around a single growing buffer; globals, string literals and
  runtime stubs are interleaved with code in one RWX segment at a fixed base.
- Undefined globals are linked by threading a backpatch chain *through the
  imm32 fields of the emitted `mov eax, imm32` instructions*
  (`sym_define_global` walks `load_int(code + i)`).
- The OS layer is `lib/linux.w` → `lib/__arch__/{x86,x64}/syscalls.w`;
  per-target asm stubs (`syscall`, `get_context`, `gen_switch`, ...) are
  emitted into every binary by `x86_asm.w` / `x64_asm.w`.
- The compiler itself always runs as the committed 32-bit x86 seed binary and
  *cross-emits* other targets; `verify_x64` proves output is independent of
  the host stage. The same cross-emit approach works for arm64.

## Design decisions

### D1: Target selection and naming

`w x64 file.w` today conflates ISA and OS (x64 = x86-64 **Linux** ELF). ARM
forces the split. Proposal:

- `w arm64 file.w` — AArch64 + Linux + ELF. The CI-testable target.
- `w arm64_darwin file.w` (working name; `m3` as an alias is cute but too
  narrow) — AArch64 + Darwin + Mach-O.
- `--pac=off|ret|full` — PAC level, default `ret` on arm64 targets (see D6).
- arm64e is `arm64_darwin --pac=full` plus the arm64e cpusubtype mark.

Plumbing, mirroring the `x64` flag in `compiler/compiler.w`:

- New globals beside `word_size`: `target_isa` (0 = x86 family, 1 = arm64)
  and `target_os` (0 = linux, 1 = darwin). arm64 sets `word_size = 8`, so all
  existing `word_size == 8` type-system behavior (int64, 8-byte pointers,
  float64) is inherited for free.
- `import_resolve_arch` (`grammar/import_statement.w`) gains `arm64` (and
  later `arm64_darwin`) as `__arch__` values; `tools/wmeta.w` expands the new
  values; `package.wmeta` lists the new modules.
- `be_start`/`be_finish` (`code_generator/elf.w`) dispatch on the new globals
  to the arm64 ELF/Mach-O writers.

### D2: Mapping the stack machine onto A64 (validated by spike)

The cc500 model survives almost unchanged, with one hardware wrinkle: AArch64
enforces **16-byte alignment on any memory access that uses `sp` as the base
register** (both Linux and Darwin enable the SP alignment check). W pushes
single 8-byte words constantly, so the real `sp` cannot be the W evaluation
stack.

Decision: dedicate **`x28` as the W stack pointer**.

- Entry stub: `mov x28, sp`, then park the real `sp` a few KB below
  (`sub sp, sp, #N`) so the OS always has an aligned stack for signal frames.
- `push_eax` → `str x0, [x28, #-8]!`; `pop_ebx` → `ldr x1, [x28], #8`;
  locals/args → `ldr/str [x28, #k]`. `stack_pos` bookkeeping and
  `sym_get_value`'s offset math are unchanged (still 8-byte words,
  `word_size_log2 = 3`).
- Register map: `x0` = accumulator (eax), `x1` = secondary (ebx), `x2` =
  shift/scratch (ecx), `x16`/`x17` = intra-procedure-call scratch for long
  immediates and veneers, `x28` = W stack. **Never touch `x18`** (Darwin
  reserves it) or `x29` (frame pointer conventions of foreign code).
- Calls stay `bl`/`blr x0`; since A64 has no hardware return-address push,
  each function prologue pushes `x30` onto the x28 stack and the epilogue
  pops it before `ret` — which is exactly where PAC slots in (D6).
- The one-instruction spike in the appendix runs this model end-to-end under
  qemu: nested calls, odd numbers of stack slots, syscalls, correct exit.

Alternative rejected: 16-byte slots on the real `sp` — would fork
`word_size_log2` from `word_size`, wasting half the stack and touching every
offset computation for no benefit.

### D3: Instruction emission and the patching abstraction

`code_generator/arm64.w` becomes the A64 twin of `x86.w`: the same ~64 helper
entry points, each composing one or a few 32-bit instruction words via
`emit_int32` with bitfield encoders (`a64_ldr_pre(rt, rn, imm)`, ...). A64 is
*easier* to encode than x86 — no prefixes, no ModRM — with one exception:
logical/arithmetic immediates have narrow or exotic encodings, so the MVP
materializes any awkward immediate into `x16` via `movz`/`movk` and uses the
register form.

Dispatch style: keep the existing helper names and branch inside them, the
same pattern `emit_x64_opcode()` established:

```
void push_eax():
	if (target_isa == 1):
		a64_push_x0()
	else:
		emit(1, c"\x50")
```

This avoids a formal backend interface (which the codebase deliberately does
not have), keeps the grammar untouched for the common case, and — critically —
keeps x86/x64 output byte-identical, so `./wbuild verify` and `verify_x64` remain
the regression guard for the refactor itself.

What *does* have to change outside `code_generator/` is every place that
assumes x86 instruction shapes:

1. **Branch patch sites** (~21 `save_int32(code + p - 4, disp)` sites in
   `grammar/while_statement.w`, `for_statement.w`, `statement.w`,
   `unary_expression.w`, `json_builtin.w`): x86 patches a rel32 measured from
   instruction end; A64 branches encode word-scaled displacement bitfields
   measured from instruction start (imm26 for `b`/`bl`, imm19 for `b.cond`).
   Replace raw `save_int32` with `be_patch_jump(pos, target_pos)` /
   `be_patch_cond(pos, target_pos)` helpers that own the per-ISA encoding.
   Ranges are a non-issue (±128 MB / ±1 MB vs current binaries < 2 MB).
2. **Address materialization + backpatch chains**: `sym_get_value` and six
   grammar sites emit raw `mov eax, imm32` (`emit(5, c"\xb8....")`) and
   `sym_define_global` threads its chain through those imm32 fields. Replace
   with `be_emit_addr_slot(v)` / `be_addr_slot_read(pos)` /
   `be_addr_slot_write(pos, v)`. On arm64 the slot is a fixed-length
   `movz/movk[/movk]` sequence (or, once PIE lands, `adrp+add`); the chain
   read/write helpers reassemble the split immediate so the linker logic in
   `symbol_table.w` is unchanged.
3. **Inline-data tricks**: string literals emit `call rel32` over their bytes
   so the pushed return address becomes the data pointer
   (`grammar/string_literal.w`). On A64, `bl` lands the address in `x30`
   instead of on the stack — same trick, different epilogue (`mov x0, x30`
   instead of `pop`). Wrap as `be_inline_data(len, bytes)` returning the
   address in the accumulator. Bonus: this construction is inherently
   position-independent, which D5 needs.
4. **Runtime asm stubs**: new `code_generator/arm64_asm.w` mirroring
   `x64_asm.w` — `syscall`/`syscall7` (marshal from the x28 stack into
   `x0..x5` + `x8`/`x16`), `get_context`/`store_context`,
   `repl_setjmp`/`repl_longjmp`, `gen_switch` (save/restore x19–x28 + both
   stacks), `swap_endian` (`rev`), `function_call`.
5. **Misc**: `int3` → `brk #0` (bounds checks, SIGTRAP semantics preserved);
   division (`sdiv` computes the quotient; remainder needs `msub`);
   `alu_cmp_set` → `cmp` + `cset`; entry stub argv address from the initial
   `sp`; entry `call _main` patch in `be_finish` goes through the same
   `be_patch_jump` helper.

Float support maps cleanly: the "float bits ride the integer pipeline" design
(`docs/projects/float.md`) works identically with `fmov d0, x0` replacing
`movq xmm0, rax`; a `code_generator/a64_float.w` twin of `sse.w` provides the
~36 scalar helpers (`fadd`, `fcmp` + `cset`, `scvtf`, `fcvtzs`, `fcvt`).

Seed constraint: everything above lives in `code_generator/`, `grammar/`,
`compiler/` — compiled by the committed seed — but requires **no new W
syntax**, so no seed update (`./wbuild update`) is needed.

### D4: Syscall layer

**Stage: Linux first.** New `lib/__arch__/arm64/syscalls.w` with the AArch64
generic syscall table — note the numbers differ from x86-64 *and* several
legacy calls do not exist: no `open` (use `openat` + `AT_FDCWD`), no
`getdents` (only `getdents64`), no `poll` (use `ppoll`), `write` = 64,
`exit_group` = 94, `mmap` = 222, `brk` = 214. `lib/linux.w`'s wrapper surface
stays identical, so `lib/` and `structures/` compile unmodified.

**Darwin.** Two options:

- **Raw BSD syscalls** (`svc #0x80`, number in `x16`, errors via carry flag +
  positive errno — the stubs must convert to the -errno convention the W
  runtime already expects). In-character for W (static, self-contained), and
  the calls the runtime needs (`read`/`write`/`open`/`mmap`/`exit`/...) have
  been stable in practice for decades. Risk: Apple explicitly does not
  guarantee this ABI (Go was famously broken by it and moved to libSystem);
  we accept the risk consciously for the MVP and document it.
- **libSystem via dyld** — the "supported" route, but it drags in the entire
  dynamic-linking stage (LC_LOAD_DYLINKER, chained fixups, lazy binding,
  Darwin AAPCS64 variadics where variadic args go on the stack). This is the
  Mach-O equivalent of `elf_dynamic.w` and is deferred to a later stage,
  where it also unlocks `c_import` on macOS.

`brk` does not exist on Darwin: `lib/memory.w` already has an mmap fallback
mode (`malloc_mmap_mode`), so the Darwin allocator forces that mode.

The OS split also needs a naming decision in `lib/`: today `lib/lib.w`
imports `lib.linux` unconditionally. Rename the concept to an OS module
resolved like `__arch__` (e.g. `lib/__os__/{linux,darwin}.w`), or simply let
`__arch__` values encode the OS pair (`arm64` vs `arm64_darwin`) and keep one
import line. Recommendation: the latter — one axis, four values, no new
resolver machinery; revisit only if a third OS ever shows up.

### D5: Mach-O container writer

New `code_generator/macho_64.w` + `macho_sign.w`, dispatched from
`be_start`/`be_finish`. Differences from the ELF writers that actually bite:

- **W^X.** Apple Silicon refuses writable+executable segments outright. W's
  single-buffer model interleaves mutable globals with code. Fix: split the
  emitter into a text buffer and a data buffer (`emit_data*` twins in
  `code_emitter.w`); `emit_global_storage`, `extern` data and mutable
  builtins move to the data buffer; read-only inline data (string literals,
  jump-over-data) stays in text. This split is prerequisite work that can be
  done and regression-tested entirely on the ELF targets first (two PT_LOAD
  segments, RX + RW) before Mach-O consumes it — it is also a security
  improvement Linux W binaries should get anyway.
- **PIE + ASLR.** arm64 macOS main executables are PIE; the kernel slides the
  image and nothing applies rebases in a dyld-less binary. Consequences:
  symbol-address materialization becomes PC-relative (`adrp+add` in the
  `be_emit_addr_slot` helpers — A64 makes this natural), and the few places
  that embed absolute pointers in *data* (UTF-8 string descriptors from
  `emit_utf8_string_descriptor`) either become offset+add-at-use or get a
  compiler-emitted rebase table that the entry stub applies at startup
  (compute slide = runtime `adr` result − linked address; add to each listed
  site). Recommendation: rebase table; it is ~30 lines of startup code and
  keeps descriptor layout unchanged.
- **Structure**: `__PAGEZERO` (4 GB), `__TEXT` (rx), `__DATA` (rw),
  `__LINKEDIT` (signature only), `LC_BUILD_VERSION` (macOS min version),
  `LC_MAIN` requires dyld, so a static binary uses **`LC_UNIXTHREAD`** with
  the arm64 thread state (entry pc + initial sp). Known-working construction
  for handmade dyld-less arm64 Mach-Os, with the caveat that Apple does not
  officially bless static binaries (same risk bucket as raw syscalls, same
  mitigation path: the later libSystem stage).
- **Code signing.** The kernel kills unsigned arm64 binaries. An "ad-hoc"
  signature is just an embedded SHA-256 CodeDirectory over each **16 KB**
  page (`pageSizeLog2 = 14`, the arm64 macOS VM page), no certificate —
  entirely computable by W itself. Implemented: SHA-256 in `lib/sha256.w`
  (also useful to replace the weak rolling hash in `tools/wexec.w` later),
  and a CodeDirectory writer in `macho_sign.w` (references: ld64
  `libcodedirectory.c`, lld's `D96164`). The interim `codesign -s -` host
  fallback is gone once the Darwin seed self-signs. Gotcha when rewriting
  a previously-executed path: the kernel caches signature validation by
  vnode, so prefer write-then-rename (Go and lld both hit this);
  `run_darwin_tests.sh` copies to a fresh inode before exec.
- cpusubtype: `CPU_SUBTYPE_ARM64_ALL`, or `CPU_SUBTYPE_ARM64E` + versioned
  ABI bits for the arm64e slice (D6). No fat/universal binaries — one
  architecture per output file, consistent with W's one-target-per-invocation
  model.

### D6: Pointer authentication design

PAC in W is attractive precisely because the backend owns the whole runtime:
there is no foreign ABI to be compatible with until the libSystem stage.

- **`--pac=ret` (default on arm64 targets): sign return addresses.** In the
  prologue, `pacia x30, x28` signs LR against the current W stack pointer as
  modifier before it is pushed; the epilogue pops and `autia x30, x28`
  before `ret`. Using x28 as the modifier binds the signature to the frame
  (a saved LR replayed at a different stack depth fails), the same idea as
  clang's `-mbranch-protection=pac-ret` with `sp` modifier. Cost: 2
  instructions per call — in line with the codebase's tolerance (bounds
  checks are on by default).
  Note the non-HINT encodings (`pacia xN, xM`) are Armv8.3+ only, i.e. this
  mode requires PAuth hardware (any Apple Silicon; `-cpu max` in qemu). The
  HINT-space `paciasp` nop-compatibility trick is useless to us anyway since
  our modifier is x28, not sp.
- **`--pac=full`: additionally sign code pointers at rest.** W function
  pointers (from `sym_get_value` on functions, stored in variables, vtables
  are not a thing here) get signed with the IA key and zero discriminator at
  materialization; indirect calls use `blraa x0, xzr` instead of `blr x0`
  (authenticate-and-branch, and on FPAC hardware like the M3 a forged
  pointer traps immediately). `gen_switch`/`repl_setjmp` buffers hold a
  signed resume address with the buffer address as discriminator. This is
  W's *own* convention — deliberately simpler than arm64e's per-type
  discriminators — and can tighten later.
- **Enforcement reality per platform**: on Linux/qemu (`-cpu max`,
  FEAT_FPAC) both modes are fully enforced — that is the CI story. On macOS,
  a plain arm64 slice runs with PAC keys disabled (instructions become
  no-ops: compatible but inert), so real M3 enforcement requires marking the
  binary arm64e. Since macOS 26 the arm64e ABI is open to third parties;
  for a W static binary the only ABI surface is the cpusubtype mark itself,
  making W unusually well-positioned to ship arm64e early — nothing inside
  the binary follows Apple's C++/ObjC signing schema because nothing inside
  is Apple's.
- Negative testing is mandatory: a fixture that corrupts a saved return
  address and *must* die (spike 2 in the appendix demonstrates exactly this
  under qemu: exit 132, SIGILL from the failed `autia`).

### D6 execution notes (Stage 5 landed, 2026-07-09)

- `--pac=off|ret|full` parses in a **pre-scan** before `be_start` in
  `link_impl` (`compiler/compiler.w`), not the positional flag loop: the
  level must agree across every compiled file (a mixed image traps at
  runtime) and the Mach-O writer consumes it while emitting the header.
- Sign-at-materialization lives in `be_code_ptr_sign()`
  (`code_generator/arm64.w`), called wherever a callee's address becomes a
  value. That is `sym_get_value` (`compiler/symbol_table.w`) **plus the
  four chain-slot sites that bypass it**: `print_builtin.w`,
  `json_builtin.w` and the generic call/forward paths in `generic.w` all
  emit `be_addr_slot_emit` slots of their own — the initial bring-up missed
  them and every print faulted at the first `blraaz`. Anything that adds a
  new chain-slot call target must call `be_code_ptr_sign()` after its chain
  bookkeeping (the signature word must not become the recorded chain cell).
- **`gen_switch` deviates from the sketch above**: resume addresses are
  signed with **zero discriminator** (`paciza`/`autiza`), not the buffer
  address. `__w_gen_create` (`lib/generator.w`) seeds a fresh generator
  stack with the body's entry address exactly as it received it — already
  zero-disc signed by materialization — so one convention covers first
  resume and every later suspend/resume, and `lib/generator.w` stays free
  of target-specific code. `repl_setjmp`/`repl_longjmp` do use the buffer
  address as discriminator as sketched (self-contained in the stubs, x9
  holds the buffer in both).
- **arm64e**: cpusubtype `0x81000002` (CPU_SUBTYPE_ARM64E, versioned-ABI
  bit, ptrauth ABI version 1 — byte-identical to what `clang -arch arm64e`
  emits on macOS 26). Verified natively on the M3 (macOS 26.3): ad-hoc
  signed arm64e W binaries load and run with the keys enforced, the
  corruption fixtures die (SIGSEGV/SIGBUS — macOS's spelling of the same
  faults qemu reports as SIGILL/132), and the compiler itself built with
  `--pac=full` self-hosts as arm64e with byte-identical output.
- **Known limitation**: a W function pointer handed to C code (callback,
  ObjC IMP) under `--pac=full` is a signed value the C side will call with
  a plain `blr` — wrong address on Linux, trap on arm64e. Imported C
  pointers stay unsigned (`blr x16` in `ffi.w`) so *calling* C is fine;
  *exporting* W code pointers is not. Default stays `ret`, so nothing
  regresses; revisit if a real consumer needs C callbacks under full.
- Tests: `pac_flag_test` (byte-pattern artifact assertions — x86 hosts have
  no aarch64 objdump — via `tools/pac_flag_check.sh`, in the default
  `tests`), `pac_full_test_arm64` + `pac_corrupt_test_arm64` (qemu, out of
  the `tests` umbrella like `arm64_smoke_test`), `pac_darwin` (compile-only arm64e
  guard) + must-die handling in `tools/mac/run_darwin_tests.sh`.

## Staged path

- **Stage 0 — model spikes (done, see appendix):** x28-stack + accumulator
  model and PAC sign/auth round-trip verified under `qemu-aarch64 -cpu max`,
  including the negative (corrupted LR traps) and a gcc `pac-ret` reference
  binary under the same emulator.
- **Stage 1 — A64 emitter + Linux ELF MVP (done).** `code_generator/arm64.w`
  (the A64 twin of `x86.w`, dispatched on `target_isa`), `arm64_asm.w`
  (syscall/context/setjmp/gen_switch stubs), `elf_arm64.w` (e_machine 183),
  `lib/__arch__/arm64/{syscalls,context,elf_introspect}.w`, the `arm64` CLI
  flag, and the `be_*` patching abstractions (branch patch/link via imm26/
  imm19, address slots via ldr-literal, inline `bl`+data string literals,
  function prologue). Every function's prologue signs the return address
  (`pacia x30,x28`) and the epilogue authenticates it. Kept x86/x64 output
  byte-identical (`./wbuild verify` / `verify_x64`).
- **Stage 2 — full language + self-host fixpoint (done).** Float codegen in
  `sse.w` (NEON scalar: `fmov`/`fadd`/…/`scvtf`/`fcvtzs`/`fcvt`), generators
  (`gen_switch` + `__target_isa__`-aware `__w_gen_switch_regs`), defer,
  generics, containers, strings. A 34-test slice runs under qemu; the arm64
  self-host fixpoint (`./wbuild verify_arm64`) is byte-identical, the analog of
  `verify_x64`.
- **Stage 3 — W^X text/data split (done).** The arm64 ELF now emits a
  read-execute text segment and a separate read-write data segment (globals
  reserved via `emit_data_zeros`/`emit_data_word`, addressed at
  `data_offset`); `sym_define_global_at` places a global's definition in the
  right segment. x86/x64 keep the single RWX image (byte-identical). The
  read-only text exposed two latent write-to-literal bugs (`putc`, `getchar`)
  and two test-only in-place literal mutations, all fixed to use stack/heap
  buffers.
- **Stage 4 (future) — Mach-O + Darwin + signing**, and **Stage 5 (future) —
  `--pac=full` / arm64e for macOS enforcement**, as described below.
- **Stage 4 — Mach-O + Darwin syscalls + signing.** `macho_64.w`,
  `arm64_darwin` syscall module, PIE/rebase-table startup, SHA-256 +
  CodeDirectory ad-hoc signing. Acceptance: hello + `lib_test` subset on a
  real Apple Silicon machine (arm64 slice, PAC inert), plus a GitHub-Actions
  macOS arm64 runner job if CI is desired.
- **Stage 5 — PAC to production (done, 2026-07-09).** `--pac=ret` default-on
  for arm64 targets, `--pac=full` function-pointer signing, arm64e
  cpusubtype emission, negative-test fixtures in the suite (enforced under
  qemu CI; enforced on M3 via the arm64e slice on macOS 26.3). Acceptance
  met: full arm64 suite green with pac=ret; corruption fixtures die on both
  qemu and the M3; the compiler self-hosts natively as arm64e under
  `--pac=full`. See the D6 execution notes for what shifted in flight.
- **Dynamic linking (landed with the graphics/macOS project, 2026-07):**
  `c_lib`/`extern` now work on both arm64 targets. AAPCS64 FFI shims in
  `code_generator/ffi.w` (x0-x7/v0-v7, 8-byte Linux stack spill; the C
  frame parks below the W stack); aarch64 ELF `.interp`/`.dynamic`
  (`elf_dynamic.w`, R_AARCH64_GLOB_DAT/COPY, phdr slots 2/3); Mach-O
  binds via classic LC_DYLD_INFO_ONLY opcodes (`macho_dynamic.w` —
  macOS 26.3 still accepts them, no chained fixups needed). GOT slots
  live in the RW data segment (W^X). Caveats: binds only (no extern
  data objects on arm64 — COPY space lives in the code stream);
  variadic externs work on arm64 Linux but are rejected on
  arm64_darwin (Darwin's variadic ABI packs the tail on the stack);
  arm64_darwin extern calls take at most 8 integer + 8 float args
  (Darwin packs stack args at natural size); imported function
  pointers are unsigned (plain arm64, not arm64e).
- **Deferred (own projects):** full `c_import` on macOS (header-driven
  bulk imports on top of the above); REPL on arm64
  (in-process; needs an arm64 host and replaces the x64 `MAP_32BIT` hack
  with movz/movk addressing); `wdbg` on arm64 (breakpoints are `brk #0`,
  but there is no x86-style trap flag — stepping needs breakpoint-hopping or
  out-of-process ptrace, and Darwin signal contexts differ; substantial);
  threading (`thread_create` is x86-only even on x64 today).

## Testing / CI strategy

- **Everything through Stage 3 runs in the existing Linux CI** via
  `qemu-user-static` (`-cpu max` enables PAuth+FPAC, matching M3 semantics
  for PAC failures). qemu-user is a package install, not a service; the
  environment setup should bake it in the same way `libc6:i386` is baked in
  for `dynamic_test`.
- **Stage 4+ needs real or virtual macOS.** Options: a manual runbook for an
  M3 machine (`wbuild tests_darwin` + `codesign` fallback), or GitHub
  Actions `macos-14`+ arm64 runners for the arm64 slice. arm64e enforcement
  testing needs macOS 26+; until then the qemu negative tests carry the PAC
  regression load. Darling (Darwin-on-Linux) is not viable for arm64e.
- **The x86/x64 fixpoint is the refactor guard**: every stage must keep
  `wbuild verify` + `verify_x64` byte-identical, proving the dispatch
  refactor (D3) is inert for existing targets.

## Open questions

- Raw Darwin syscalls vs biting off libSystem linking immediately — the plan
  says raw first; if an early macOS point release breaks a syscall number,
  the libSystem stage gets promoted.
- Does `arm64_darwin` warrant a distinct `__arch__` value (plan: yes, values
  are cheap) or an orthogonal `__os__` resolver (plan: no, until a third OS)?
- Signing: is the `codesign -s -` fallback acceptable for the first Darwin
  milestone, or is in-house SHA-256 signing a hard requirement before
  anything ships? (Plan: fallback for bring-up only; W signs its own output
  by end of Stage 4.)
- `--pac=full` discriminator scheme for function pointers stored in
  long-lived data structures (zero discriminator is replay-prone across
  objects; address-diversified signing complicates `memcpy`-style moves of
  structs containing function pointers — W's `lib` does move such data).
- DWARF: `dwarf.w` hardcodes `address_size` assumptions already flagged in
  `docs/todo.txt` for x64; arm64 inherits that cleanup.

## Appendix: validated spikes (qemu-aarch64, 2026-07)

Environment: `qemu-aarch64-static` + `binutils-aarch64-linux-gnu` on the
x86-64 dev host; `-cpu max` provides FEAT_PAuth/FEAT_PAuth2/FEAT_FPAC (the
M3's PAC feature set).

Spike 1 — the D2/D6 model end-to-end: x28 W-stack with 8-byte pushes (odd
slot counts included), x0 accumulator, nested `bl` calls, LR signed with
`pacia x30, x28` and authenticated before `ret`, `svc #0` syscalls. Runs
correctly and exits 0:

```asm
_start:
    mov  x28, sp          // W stack = initial sp (argv still reachable)
    sub  sp, sp, #0x8000  // park real sp below: signal frames land here
    bl   fn_outer
    mov  x0, #0
    mov  x8, #93          // exit_group
    svc  #0
fn_outer:
    pacia x30, x28        // sign LR, modifier = W stack pointer
    str  x30, [x28, #-8]! // push signed LR (8-byte slot: sp-alignment
    mov  x0, #41          //   rules do not apply to x28)
    str  x0, [x28, #-8]!  // push a local (odd slot count on purpose)
    bl   fn_inner
    ldr  x1, [x28], #8    // pop local
    add  x0, x0, x1
    ldr  x30, [x28], #8   // pop LR
    autia x30, x28        // authenticate before return
    ret
fn_inner:                 // same prologue/epilogue; write(1, msg, 25)
    ...
```

Spike 2 — negative test: identical prologue, but the saved LR is XOR-corrupted
before `autia` (simulated ROP overwrite). Dies with SIGILL (exit 132) under
`-cpu max`, exactly the FPAC trap the M3 would raise; exiting 0 would have
meant PAC missed the corruption.

Spike 3 — reference: `aarch64-linux-gnu-gcc -static -march=armv8.3-a
-mbranch-protection=pac-ret` hello-world runs under the same emulator
(`paciasp`/`autiasp` visible in `objdump`), confirming the toolchain/emulator
PAC baseline independently of our hand-written code.

## References

- Arm ARM, A64 ISA + FEAT_PAuth/PAuth2/FPAC:
  https://developer.arm.com/documentation/ddi0487/latest
- AArch64 PCS (AAPCS64) incl. Darwin divergences:
  https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst ,
  https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms
- Apple M-series feature matrices (M3: PAuth+PAuth2+FPAC):
  https://github.com/lelegard/arm-cpusysregs/blob/main/docs/apple-m1-features.md
- arm64 vs arm64e on macOS (keys disabled in arm64 processes, preview-ABI
  history): https://github.com/lelegard/arm-cpusysregs/blob/main/docs/arm64e-on-macos.md
- arm64e ABI stabilization (macOS 26 "Enhanced Security"):
  https://developer.apple.com/documentation/xcode/enabling-enhanced-security-for-your-app
- Clang pointer-authentication model (keys, discriminators, FPAC notes):
  https://releases.llvm.org/19.1.0/tools/clang/docs/PointerAuthentication.html
- Mach-O ad-hoc code signing: ld64 `libcodedirectory.c`
  (https://opensource.apple.com/source/ld64/), lld review with the vnode
  cache/msync gotcha: https://reviews.llvm.org/D96164
- Dyld-less Mach-O construction (LC_UNIXTHREAD + signature requirement):
  https://stackoverflow.com/questions/68977603/handmade-macos-executable
- Linux AArch64 syscall table (generic unistd):
  https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/unistd.h
- XNU syscall convention on arm64 (x16, svc #0x80, carry-flag errors):
  https://github.com/apple-oss-distributions/xnu (osfmk/mach + bsd/kern)
