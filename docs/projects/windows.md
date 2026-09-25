# Windows / .exe Compatibility (win64 PE Backend)

Early Windows support: `w win64 file.w -o out.exe` cross-compiles a W
program from Linux into a PE32+ console executable that runs under Wine or
real Windows. Follows the same pattern as the x64 and arm64 backends (one
per-target container writer, an `__arch__` runtime split, a CLI target
flag), reusing the x86-64 instruction emitter unchanged.

**Status: implemented (early).** The container writer
(`code_generator/pe_64.w`), the Win64 C ABI (`emit_c_abi_call_win64` in
`code_generator/ffi.w`), and the kernel32-backed runtime
(`lib/__arch__/win64/`) are in place. Hello world, a runtime smoke test
(heap, files, containers, generators, time) and the msvcrt dynamic-linking
twin of `dynamic_test` pass under Wine. `./wbuild verify` / `verify_x64` /
`verify_arm64` stay byte-identical.

Build/run: `./wbuild build` then `./wbuild tests_win64`;
the runtime tests need `wine` (the header check only needs binutils).
Compile a single program with
`./bin/wv2 win64 file.w -o out.exe && wine out.exe`.

## Target definition

Windows on x86-64 differs from the Linux x64 target in three layers; the
ISA layer is identical, which is what makes this backend cheap:

1. **Container** — PE32+ instead of ELF: DOS header, COFF header, optional
   header, section table, import directory. No program headers, no
   interpreter path; the loader resolves imports itself.
2. **OS ABI** — there is **no stable raw-syscall contract** on Windows;
   syscall numbers change between builds. The supported entry is the DLL
   surface (`kernel32.dll` and friends), so even hello world needs the
   import table. This is why the dynamic-import machinery sits on the
   critical path here, while the ELF targets treat it as optional.
3. **C calling convention** — Microsoft x64, not System V: the first four
   arguments go positionally in `rcx/rdx/r8/r9` or `xmm0..xmm3`, the caller
   reserves 32 bytes of shadow space, and variadic float arguments are
   duplicated into the GP registers. No `al` vector count.

## How it works

### Address model (unchanged on purpose)

W links with 32-bit absolute address slots (`sym_get_value` backpatch
chains), so the image must load at a fixed base below 2^31. The PE writer
keeps the exact single-buffer scheme the ELF writers use:

- `ImageBase` is fixed at 0x400000 and `code_offset = 0x400000`.
- `SectionAlignment == FileAlignment == 0x1000`, headers padded to one
  page, `.text` at RVA 0x1000 — so **every `.text` RVA equals its file
  offset** and buffer position `p` lives at vaddr `code_offset + p`.
- `IMAGE_FILE_RELOCS_STRIPPED` is set and `DllCharacteristics` has no
  `DYNAMIC_BASE`, so the loader never rebase the image (there is no
  `.reloc` section to do it with).
- Not `LARGE_ADDRESS_AWARE`: the loader keeps all user addresses below
  2GB, the same low-address world the fixed ELF base provides.

The image is W^X (`docs/projects/wx_split.md` Stage A): a read-execute
`.text` section (code + read-only import metadata) and a read-write
`.data` section at ImageBase + 16MB holding the IAT slots and mutable
globals via the `data_split` buffer, the same recipe as the arm64
targets. `.text`'s `VirtualSize` spans up to `.data`'s fixed RVA
(zero-fill, `.bss`-style) so the sections stay virtually adjacent while
global vaddrs could be baked into code before the code size was known;
`.data` is the one region whose RVA does not equal its file offset, and
nothing addresses it by file offset. `DllCharacteristics` sets
`NX_COMPAT`. `SizeOfStackCommit` equals the 8MB reserve, so large W
frames never need `__chkstk` stack probes.

### Imports (the shared dynamic-linking layer)

The registry in `code_generator/dynamic_registry.w` is shared by all
container writers: the grammar (`c_lib` / `extern`, and `c_import`'s bulk
importer) fills it, and at finish time exactly one writer drains it:

- ELF: `elf_dynamic.w` emits `.dynamic` + GLOB_DAT/COPY relocations.
- PE: `pe_emit_imports()` in `pe_64.w` emits the import directory.
- Mach-O (future, `docs/projects/arm64.md` stage 4+): dyld bind tables.

Contract notes for other backends building on the registry:

- `dyn_import_get_lib(i)` records which `c_lib` each import belongs to
  (the most recent one at declaration time). ELF ignores it — ELF symbol
  resolution is global — but PE groups its import directory by DLL and a
  Mach-O writer will need the same for dylib ordinals.
- `dyn_emit_import_slot()` reserves the in-image word the loader fills
  (GOT slot on ELF, one-entry IAT on PE) and every emitted call site
  reaches the function through that slot, so backends never have to move
  or rewrite code at finish time.

On disk every IAT slot holds its hint/name RVA, mirroring the lookup
table, until the loader overwrites it. This is required, not cosmetic:
the Windows loader walks the IAT itself and stops at the first zero
slot, so zero-filled slots are silently never bound and the first
kernel32 call jumps to address 0 (Wine binds them anyway, which is how
the bug hid).

Because extern slots are emitted inline next to their shims (scattered
through the image), the PE writer emits **one import descriptor per
import**: each descriptor's lookup table holds a single name and its
`FirstThunk` points at that import's own slot (followed by a zero
terminator word). Loaders resolve repeated DLL names from the module
cache, so this only costs a few bytes of directory per import.

Weak imports (`c_import` bulk headers) are registered like normal ones;
the PE loader has no weak-import concept and will fail the load if a
symbol is missing. Imported **data** objects are rejected on win64 — PE
has no COPY-relocation equivalent (`__imp_` indirection is future work).

### Entry and startup

`AddressOfEntryPoint` targets a stub that materializes the W entry
contract (argc, argv pushed with argv on top) with `argc = 0` and an
empty argv/env block, then calls the entry function; if it returns, the
stub passes the result to `ExitProcess` through the import slot the
writer registers itself (kernel32!ExitProcess).

The entry function is `_win_start` (defined at the bottom of
`lib/__arch__/win64/syscalls.w`) whenever `_main` exists for it to chain
to, else `_main` / `main` directly, mirroring `elf_finish_64()`.
`_win_start` rebuilds real argc/argv from `GetCommandLineA` (spaces/tabs
separate, double quotes group; the full `CommandLineToArgvW` backslash
rules are not implemented) and chains to `_main`, so `lib/lib.w` stays
target-independent.

### Runtime (`lib/__arch__/win64/`)

The reserved `__arch__` import segment resolves to `win64` when
`target_os` is windows, so `import lib.__arch__.syscalls` binds the
kernel32-backed module. It keeps the Linux wrappers' surface where a
mapping exists:

- `write`/`read` → `WriteFile`/`ReadFile` (+ `GetStdHandle` for fds 0-2),
  `open`/`create_file` → `CreateFileA` (translating the Linux O_* bits the
  rest of lib/ passes in), `close`/`seek`/`unlink`, `mkdir`/`rmdir`/
  `chdir`/`getcwd`.
- `brk` is emulated on a 256MB `VirtualAlloc` reservation committed as
  the break grows (lib/memory.w's allocator only moves it upward);
  `mmap`/`munmap` map to `VirtualAlloc`/`VirtualFree`, which also backs
  generator stacks.
- `linux_time` converts `GetSystemTimeAsFileTime` to the Unix epoch;
  `clock_gettime` uses the performance counter; `nanosleep` → `Sleep`.
- `exit` → `ExitProcess`; `getpid` → `GetCurrentProcessId`.
- `sys_mincore` is emulated with `VirtualQuery` (committed, readable
  pages), which is what lets `lib/stack_trace.w` probe memory safely.
- The environment vector comes from `GetEnvironmentStringsA` (hidden
  `=C:` drive entries skipped), and `lib/env.w` matches names
  case-insensitively on Windows (`Path` is `PATH`).
- A read-only `open` passes `FILE_FLAG_BACKUP_SEMANTICS`, so opening a
  directory succeeds as it does on Linux (existence probes rely on it).
- `win_callback(fn, nargs)` builds a Microsoft-x64-ABI thunk that calls
  the W function `fn` (saving the Win64 callee-saved registers, pushing
  rcx/rdx/r8/r9 and the stack arguments W-style): window procedures and
  exception handlers are W functions. `win_c_function(sym, nargs,
  ret32)` is the reverse, a W-callable trampoline for a C function
  pointer from `GetProcAddress`/`wglGetProcAddress`; it loads every
  register argument into both its GP and xmm register, so float32
  arguments pass correctly. Both live in executable pages that are only
  writable while a thunk is being written.
- Primitives with no win64 implementation yet (fork/execve/wait4,
  poll, ioctl, signals, getdents, ...) return -1 so modules that merely
  mention them still compile. Sockets are deliberately absent: `lib/net.w`
  does not compile on win64.

The asm stubs with no syscall instructions (`get_context`,
`store_context`, `repl_setjmp`, `repl_longjmp`, `gen_switch`) are shared
with the Linux x64 target via `define_asm_functions_x64_portable()`
(`code_generator/x64_asm.w`); the Linux `syscall`/`syscall7` stubs are
not emitted on win64.

### Toolchain plumbing

- `target_os` global in `code_emitter.w` beside `target_isa`:
  0 = linux, 1 = darwin (reserved for the arm64 plan's Mach-O stage),
  2 = windows. `be_start`/`be_finish` (`code_generator/elf.w`) dispatch
  on it.
- The `win64` CLI flag (`compiler/compiler.w`) selects `word_size = 8`,
  `target_isa = 0`, `target_os = 2`.
- Debug info: `emit_debugging_symbols` writes the same ELF section
  table, `.symtab` and DWARF `.debug_line` into `.text` as on Linux,
  behind a stand-in ELF64 header that `pe_start_64` places page-aligned
  at the start of `.text` (`debug_elf_origin` makes e_shoff and every
  sh_offset relative to it). `lib/stack_trace.w` meets that header
  walking down from any code address, so `print_stack_trace()` and
  crash reports show `function (file:line)` frames on Windows.
  CodeView/PDB (for WinDbg/Visual Studio) is still future work.
- Crash reports: `crash_handler_install()` (`lib/crash.w`, installed by
  the compiler driver and `lib/testing.w`) registers a vectored
  exception handler. `SetUnhandledExceptionFilter` does not work for W
  code: without `.pdata` unwind info the frame-based dispatcher cannot
  unwind through W frames to the top-level filter and the process dies
  without calling it. The handler reports only fatal hardware
  exceptions (access violation, divide by zero, illegal instruction,
  stack overflow, ...) and returns `EXCEPTION_CONTINUE_SEARCH`.
- `lib/testing.w` works on win64 (tests are discovered at compile time).
- Graphics: `graphics.window` opens a Win32 window with a WGL context
  (`graphics/window_win32.w`, `graphics/gl_win32.w`); see
  `docs/projects/graphics.md`.

## Testing

- `./wbuild tests_win64` = `win64_header_test`
  (plain-W structural check of the emitted PE: PE32+ header, R+X
  `.text` / R+W `.data`, the kernel32 import, IAT slots pre-filled from
  the lookup table, the embedded symbol header; no Wine or binutils
  needed, also part of `tests`) + `win64_hello_test` +
  `win64_smoke_test` (heap growth, strings, file round trip, map/list
  builtins, generators, time) + `dynamic_test_win64` (msvcrt `_getpid`
  vs `GetCurrentProcessId`, variadic `printf` with on-stack args and a
  promoted float, `sqrt` float ABI).
- Natively on Windows, `wbuild.cmd tests_win64` and `wbuild.cmd
  verify_win` run the same targets without Wine (wexec runs targets
  serially there, since there is no fork). The GL window is checked by
  running `graphics/gl_smoke_test.w` / `gl_texture_test.w` compiled
  with `win64` on a desktop session.
- Wine is the CI/dev proxy for Windows; on Cursor Cloud it should be
  baked into the VM snapshot like qemu (see AGENTS.md).
- Regression guards: `./wbuild verify`, `verify_x64`, `verify_arm64` and the
  full `./wbuild tests` stay green; Linux output is byte-identical because
  the win64 paths only activate under the flag.

## Future work (not "early" scope)

- **win32 (PE32 / i386)**: same writer with 32-bit optional header and
  IAT entries; the x86 cdecl shims already exist.
- **`.reloc` + ASLR**, LARGE_ADDRESS_AWARE, and `__imp_` data imports.
  (W^X `.text`/`.data` sections landed — `docs/projects/wx_split.md`
  Stage A.)
- **CodeView/PDB debug info** for native debuggers (the runtime's own
  traces already symbolize through the embedded ELF tables).
- **Threads, sockets, process spawning** over WinAPI
  (`CreateThread`, Winsock, `CreateProcessA`).
- **Self-hosting on Windows**: the compiler itself runs on Windows with
  `w.exe win64 w.w -o wv2.exe`; the fixpoint is verified via
  `./wbuild verify_win` (needs Wine on Linux) or `wbuild.cmd verify_win`
  (natively on Windows — `wbuild.cmd` downloads the pinned `w.exe` seed
  from GitHub Releases per `SEEDS` on cold start; wexec drops the
  manifest's `wine` prefix when `os_windows()`). Path handling
  (`GetCurrentDirectoryA` backslash normalization, Windows drive-letter
  absolute paths, `NUL` device for check mode) is implemented in
  `compiler/compiler.w`; the normalization is a no-op on Unix. Process
  spawning for the build executor (`tools/wexec.w`) uses
  `CreateProcessA` / `WaitForSingleObject` / `PeekNamedPipe` via the
  `lib/process.w` Windows path, gated by `os_windows()` in
  `lib/__arch__/win64/syscalls.w`; the non-win64 syscall modules carry
  linkable stubs for that Win32 surface (the mirror image of the win64
  module's Unix-primitive stubs), so Linux/darwin builds are unaffected.
  wexec on Windows runs targets inline one at a time (no fork),
  treats the manifest's seed-driven `wv2` target as satisfied by
  `bin\wv2.exe`, compiles untargeted `bin/wv2 f.w -o bin/tool` host-tool
  steps for win64 (`bin/tool.exe`, e.g. the generated-source
  generators), supplies `echo`/`cmp` when PATH has neither, and walks
  the source tree with FindFirstFileA so the generated manifest has
  every target. `wbuild.cmd` promotes the refreshed `wv2_win` /
  `wexec_win` outputs to `bin\wv2.exe` / `bin\wexec.exe`. The pinned
  v0.1.0 `w.exe` seed predates the IAT pre-fill fix and crashes on
  Windows hosts that bind strictly (it runs under Wine); a cold
  bootstrap on such a host needs a seed released after the fix.
  Known limits: `process_run` on Windows writes stdin up front (a child
  that fills its output pipes before reading a >4KB stdin can deadlock)
  and `spawn_options.env` is ignored by `CreateProcessA` (child inherits
  the parent environment).
  Outstanding: `lib/testing.w` ELF introspection, sockets, signals.
