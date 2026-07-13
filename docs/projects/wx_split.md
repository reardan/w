# W^X Everywhere: Extending the Text/Data Split to x86, x64 and win64

**Status: proposed.** No code changed yet; this document scopes the work.
Motivated by a reproducible crash (below) rather than a hypothetical
hardening exercise.

## Problem

`w x64 file.w` (and `w file.w`, and `w win64 file.w`) all emit a **single
RWX segment**: one block of memory that is simultaneously writable and
executable, holding code, read-only data, and — for targets with dynamic
imports — the GOT/IAT slots the loader patches at load time. `arm64` and
`arm64_darwin` are the exception: they already split code (R+X) and
mutable data (R+W) into separate segments (`docs/projects/arm64.md` Stage
3/4), because Apple Silicon's kernel refuses to map an RWX Mach-O segment
at all.

x86/x64 Linux and win64 don't refuse RWX outright, but modern Windows
does reject the *load-time write* half of it under **Memory Integrity
(HVCI)** — Hypervisor-enforced Code Integrity, which many Windows 11
machines run by default (Secure Boot + VBS). HVCI enforces strict W^X at
the hypervisor level: a page cannot be both executable and freshly
written to. The win64 loader's IAT-binding step is exactly that kind of
write, into a page that is also marked executable — so on an HVCI
machine, the loader's writes into the IAT are silently dropped, and the
image runs with every import unresolved.

### Repro

Confirmed on a real Windows 11 x64 box with Memory Integrity active
(`Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard
Win32_DeviceGuard` → `SecurityServicesRunning` includes `2`, HVCI). The
pinned `w.exe` seed (v0.1.0) downloads and hash-verifies fine via
`wbuild.cmd`, but crashes immediately on the first run:

- `STATUS_ACCESS_VIOLATION` (`0xc0000005`), `RIP=0`, faulting module
  `unknown`, fault offset `0x0` (Windows Event Log, `Application Error`).
- A local crash dump (`%LOCALAPPDATA%\CrashDumps\w.exe.*.dmp`, opened
  with `cdb.exe`) shows the crash is `call qword ptr [w+0x19bc]` inside
  `_win_start`, where `0x19bc` is `GetCommandLineA`'s IAT slot
  (`FirstThunk`) — and that slot, along with two other checked slots
  (`ExitProcess` ×2), all read back as `0000000000000000`.
- The PE headers, import directory, hint/name table and ILT were all
  manually verified byte-correct (matches `code_generator/pe_64.w`
  exactly), and every imported name (`ExitProcess`, `GetCommandLineA`,
  etc.) resolves fine via `GetProcAddress` on this machine's real
  `kernel32.dll`. The import *table* is fine; the loader just never
  writes the resolved pointers into it, because the IAT lives inside the
  same RWX section HVCI won't let it write to.

This isn't hypothetical or Wine-vs-real-Windows drift in the emitted
bytes — the binary is correct, the loader's *behavior* under HVCI is the
mismatch. Wine, which is the project's current win64 CI/dev proxy
(`docs/projects/windows.md`), does not model HVCI, so this has never
been caught before.

Win32 (32-bit PE) isn't affected by this specific bug because it doesn't
exist yet — it's still listed as future work in `docs/projects/windows.md`.

## Existing mechanism (already built, already proven twice)

The fix primitive already exists and is target-generic, not
arm64-specific:

- `code_generator/code_emitter.w` carries a second buffer (`data`,
  `datapos`, `data_offset`) alongside the code buffer, gated by one flag:
  `data_split`. `emit_data_zeros` / `emit_data_word` append to it.
- `code_generator/dynamic_registry.w`'s `dyn_emit_import_slot()`
  **already branches on `data_split`**: when set, the GOT/IAT slot goes
  into the RW data buffer instead of inline in the code stream
  (`dynamic_registry.w:68-80`). This is the exact function both
  `elf_dynamic.w` (GOT) and `pe_64.w` (IAT) call — win64 gets this for
  free once `data_split` is turned on for it.
- `grammar/program.w`'s `define_global_variable()` also already branches
  on `data_split` (`program.w:194-204`), routing mutable globals to the
  data segment.
- Two container writers already turn this on and ship it:
  `code_generator/elf_arm64.w` (arm64 Linux, `docs/projects/arm64.md`
  Stage 3 — two `PT_LOAD` segments, R+X text and R+W data 16MB above it)
  and `code_generator/macho_64.w` (arm64_darwin, Stage 4 — Apple Silicon
  *requires* this, it won't run an RWX Mach-O at all). Both self-host and
  pass `./wbuild verify_arm64` / `verify_darwin` today.

So this isn't "design a W^X scheme" — it's "port the arm64 recipe to
three more container writers." arm64's version also carries a PIE
rebase-table mechanism (`arm64_entry_rebase_stub`, `rebase_note`) for a
future ASLR stage; **that part is out of scope here** — x86, x64 and
win64 all stay fixed-base (`ImageBase`/`base_code_offset` constant, no
slide), exactly like arm64 does *today* (its rebase walk is already a
documented no-op under the current non-PIE `ET_EXEC`). `rebase_note()`
calls from `program.w` are harmless no-ops for these targets since
nothing reads the table without a rebase walk wired up.

wasm needs no change: `data_split = 1` is already mandatory there
(`compiler.w:328`) since linear memory isn't executable at all — it was
never RWX to begin with.

## Plan

Three independent container-writer changes, ordered by blast radius
(smallest/most urgent first):

### Stage A — win64 (`code_generator/pe_64.w`)

Fixes the crash above. Lowest blast radius: touches only the win64
target, which has no other consumers depending on exact byte layout
(`./wbuild verify_win` is a self-consistency fixpoint, not a comparison
against old output).

- Split the single `.text` section into two PE sections: `.text` (R+X:
  code, the entry stub, the import directory/ILT/hint-name tables — all
  read-only after link time, so they're fine in a non-writable section)
  and `.data` (R+W, no execute: IAT slots, and any mutable globals via
  the already-`data_split`-aware `program.w` path).
- `data_offset` must be fixed **before** code size is known (global and
  IAT-slot vaddrs are baked into emitted code as they appear), so
  `.data` gets a fixed RVA the same way arm64 does it: `ImageBase +
  16MB`. PE sections should be virtually adjacent, so `.text` declares
  `VirtualSize` as the full span up to `.data`'s RVA while its
  `SizeOfRawData` stays the actual code size — standard zero-fill
  semantics, the same mechanism `.bss` uses. `SizeOfImage` grows to
  cover `.data`'s end.
- The "RVA equals file offset" invariant survives for `.text` (where
  all the finish-time patching happens) but **not** for `.data`, whose
  file offset is the page-aligned end of the code stream. That's fine:
  nothing addresses the data section by file offset — the IAT
  `FirstThunk` RVAs come from `dyn_import_got_vaddr(i) - code_offset`,
  which is layout-independent. `pe_finish_64()` writes the two regions
  back-to-back, mirroring `elf_finish_arm64()`'s two-`PT_LOAD` write
  (`elf_arm64.w:188-208`).
- `NumberOfSections` becomes 2; add the second `IMAGE_SECTION_HEADER`
  (characteristics `0xC0000040`: `INITIALIZED_DATA | READ | WRITE`, no
  `EXECUTE`).
- `dyn_emit_import_slot()` and `pe_emit_imports()`'s `FirstThunk`
  computation need no change — they already resolve through
  `dyn_import_got_vaddr()`, and the slot allocator already goes to
  `data` when `data_split` is set.
- `compiler.w`'s `win64` branch of `target_selector_apply` gains
  `data_split = 1`.
- Optional nice-to-have once `.text` is genuinely non-writable: set
  `IMAGE_DLLCHARACTERISTICS_NX_COMPAT` (0x0100) in the optional header —
  currently 0 (`pe_64.w:106`). Not required for correctness, but signals
  the loader this image is DEP-clean, which it now actually is.

### Stage B — x64 Linux (`code_generator/elf_64.w`)

Mirrors `elf_arm64.w` almost exactly, minus the rebase table:

- `elf_phdr_count_64()`: 4 → 5 (one more reserved slot, matching
  `elf_phdr_count_arm64()`'s pattern of text + data + 3 reserved for
  dynamic linking).
- `elf_start_64()` reserves a second program header (R+W, type
  `PT_LOAD`) alongside the existing R+X one; `data_offset` set the same
  way arm64 does it (`base_code_offset + 16MB`, keeping the two targets'
  layouts easy to reason about together).
- `elf_finish_64()` grows to place the data segment on its own file page
  after code and write both buffers, copying
  `elf_finish_arm64()`'s tail (`elf_arm64.w:188-208`) verbatim in
  substance.
- `compiler.w`'s `x64` branch of `target_selector_apply` gains
  `data_split = 1`.
- **Extern data objects (COPY relocations) must move too.** This is the
  part the arm64 recipe does NOT cover, because arm64 sidesteps it by
  rejecting extern data outright — `grammar/extern_statement.w:71-75`
  says exactly why: *"The copy space below is reserved in the code
  stream, which W^X arm64 targets map read-execute — the loader's COPY
  write would fault."* x86/x64 DO support extern data and it is
  load-bearing: `extern void* stdout` (`extern_data_test`) and
  `c_import`'s weak data imports (stdout/errno/optind,
  `libs/extras/c_import/importer.w:1129`). ld.so's COPY-relocation
  write is exactly the same class of load-time loader write as the
  win64 IAT bind — with `data_split` on and the copy space still in the
  code stream, every `c_import` test segfaults at load. Fix: both
  emission sites (`extern_statement.w:84-89`, `importer.w:1129`) route
  the copy space through `emit_data_zeros` + `sym_define_global_at`
  when `data_split` is set, the same branch shape
  `define_global_variable` already has. Once that lands, arm64's
  "extern data not supported yet" error can be lifted as a free
  follow-up — its blocker is this exact issue — but that's optional and
  not part of this plan's gates.

### Stage C — x86 32-bit Linux (`code_generator/elf.w` / `elf_32.w`)

Same shape as Stage B, adjusted for `Elf32_Phdr` (32-bit fields:
`elf_program_header()` in `elf_32.w:36-44` takes `flags` as a plain arg
already unlike the 64-bit header, so the R+W variant is a second call
with `flags=6` instead of `7`). Stage B's extern-data/COPY fix carries
over automatically — it branches on `data_split`, not on a target. **Highest blast radius of the three**:
x86 is the *default* target (no selector keyword — `link_impl`'s initial
reset, `compiler.w:362-370`) and is the seed/bootstrap chain root
(`./w w.w -> wv2 -> wv3 -> wv4 -> wv5`). Do this last, after A and B have
proven the pattern out in review and in CI, and give it its own PR.

### What deliberately does not change

- **The REPL and wdbg are unaffected.** Both compile in-process into
  their own RWX `mmap` buffer (`repl/core.w:1038`, `debugger/wdbg.w`'s
  header comment) and never call `target_selector_apply` or the
  container writers, so `data_split` stays 0 on their path and globals
  stay inline in the executed buffer — exactly as
  `code_emitter.w:10-15` documents. This is not a hope: the arm64
  selector has set `data_split = 1` since Stage 3 without breaking
  either tool, so the isolation is already proven, not newly relied on.
- wasm: already mandatory-split (`compiler.w:328`), no change.

### Non-goals

- PIE/ASLR for x86/x64/win64 — arm64's rebase-table groundwork stays
  arm64/Mach-O-only; these targets stay fixed-base like arm64 is today.
- win32 (32-bit PE) — not implemented at all yet, unrelated project.
- `.reloc`, `LARGE_ADDRESS_AWARE`, `__imp_`-style PE data imports —
  already-documented separate win64 future work.

## Consequences for seeds and CI

Every changed target's output bytes change (even though the fixpoint
property doesn't — `verify`/`verify_x64`/`verify_win` still just check
`wv3==wv4==wv5`, self-consistency, not old-vs-new equality). Per the
existing process (`docs/release.md`), a normal release cut after each
stage lands republishes that target's seed; no new process needed, just
noting it happens. `win64_header_test` (the `objdump` structural check
in `docs/projects/windows.md`'s testing section) needs updating for the
two-section layout in the same PR as Stage A.

## Testing gap this doc doesn't close

Wine — the project's win64 CI/dev proxy — does not enforce HVCI, so
`./wbuild tests_win64` passing under Wine does **not** confirm this fix
actually resolves the reported crash. The only real confirmation is
running the built `w.exe` on an HVCI-enabled Windows machine, which is
how the bug was found in the first place (this session had one
available and used it for the repro above). Whoever lands Stage A should
plan for a manual real-Windows smoke test before calling it done, not
just a green Wine run.
