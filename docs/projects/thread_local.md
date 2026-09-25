# Thread-local storage (`thread_local` globals)

Issue #497. The prerequisite for per-thread allocator heaps (#498) and
any other per-thread runtime state (errno, I/O buffers, a current
allocator).

Status: **implemented** for Linux x86 and x86-64 executables, static
and dynamically linked (`thread_local_test`,
`thread_local_dynamic_test` and their `_64` twins, diagnostics in
`thread_local_error_test`).

## Surface

```
thread_local int counter
thread_local heap* current_heap
thread_local my_struct scratch
```

A module-level declaration prefixed with the contextual keyword
`thread_local` gives every thread its own copy, the main thread
included. Every copy starts zeroed. Reads, writes and `&x` work as they
do for any global, and `&x` gives the calling thread's copy. As with
`kernel`/`export`, a type or symbol named `thread_local` keeps the
identifier meaning.

Rejected with a diagnostic:

- an initializer (`thread_local int x = 3`): copies start zeroed, and
  there is no per-thread initialization image yet;
- fixed arrays, including struct fields that are fixed arrays: a fixed
  array's `{data, length}` header points into its own storage, which
  differs per thread. Use a pointer instead;
- functions;
- every target except x86/x64 Linux, and the in-process REPL/wdbg.

## Design

**Block layout.** The compiler assigns each `thread_local` a byte
offset in one per-thread block as it is declared. Word 0 is the block's
self pointer, and variables follow at word-aligned offsets
(`global_storage_size`). A W executable is one compilation unit with no
link step, so the offsets are compile-time constants. In ELF terms this
is the local-exec TLS model, without the `PT_TLS` machinery. The final
size, rounded up to 16 bytes and capped at 1MB, is patched into the
`__w_tls_size()` stub when the executable is finished.

**Access.** `sym_get_value` sees the symbol's thread-local flag (symbol
record slot +142) and emits `be_tls_address(offset)` instead of an
address slot:

- x64: `mov rax, gs:[0] ; add rax, off`
- x86: `mov eax, fs:[0] ; add eax, off`

These are the segment registers libc leaves alone. The x86-64 psABI
puts libc's thread pointer in `fs` and the i386 psABI puts it in `gs`,
so W's block rides the other register. A program that loads libc
(`c_lib`/`extern`/`c_import`) keeps libc's TLS (errno, the stack
protector canary, stdio locks) intact on the main thread, with no
`PT_TLS` segment or loader cooperation needed
(`thread_local_dynamic_test`).

The result is an ordinary pointer, so loads, stores, `&x`, struct field
access and the rest of the expression machinery need no changes.

**Installing a block.** `__w_tls_set(block)` is an asm stub. It writes
the self pointer to `block[0]`, then:

- on x64, calls `arch_prctl(ARCH_SET_GS, block)`;
- on x86, calls `set_thread_area` with a flat 4GB data descriptor based
  at `block`, then loads `fs` with the entry's selector. The entry
  number comes from the inherited `fs` selector, or is `-1` (the kernel
  picks a free TLS slot, one libc is not using) while `fs` is still 0
  on the main thread. Spawned threads
  therefore reuse the main thread's GDT slot with their own base. TLS
  GDT entries are per-thread in the kernel.

**Main thread.** When `tls_size > 0`, `elf_emit_tls_entry_thunk`
reserves the main thread's block in the data segment (zero-filled) and
emits a thunk that the entry stub calls instead of `_main`:
`push block ; call __w_tls_set ; add sp, word ; jmp _main`. The `jmp`
keeps the entry stub's return address and argument, so `_main` sees
the same frame as before. Programs that declare no `thread_local` get
no thunk and no extra syscalls. Their only change is the two unused
stubs.

**Spawned threads** (`lib/thread.w`). `thread_entry` installs the
bottom `__w_tls_size()` bytes of the thread's own 4MB stack mapping as
its block before running anything else. mmap has already zeroed it, it
needs no allocation, and `thread_join`'s munmap reclaims it with the
stack. The 1MB cap keeps at least 3MB for the stack. Pool workers keep
their block across jobs, so a worker's `thread_local` state persists
from one `parallel_for` to the next until `thread_pool_shutdown`.
Threads made directly with the raw `thread_create` builtin (not through
`lib/thread.w`) inherit the spawner's thread pointer and therefore
share its copies. Threads created by libc (`pthread_create` through
`c_import`) start with no W block at all, so they must not touch a
`thread_local`.

**Seed.** `thread_local` is new syntax, so nothing in the seed's
import graph (`lib/memory.w`, `compiler/`, the container runtime) may
use it until `SEEDS` points at a release that contains it
(docs/release.md). The compiler support is ordinary seed-compatible W,
because only the emitted bytes are new.

## Staging

1. **Initializers**: a `.tdata`-style image copied into each new block
   (the main block could simply be pre-initialized in the data
   segment).
2. **arm64 Linux / darwin** via `tpidr_el0`, together with arm64
   threads (docs/projects/threads.md staging). **wasm32** has no
   threads, so `thread_local` could lower to a plain global.
   **win64** needs TLS slots or a `.tls` directory.
3. **Debugger**: the attach debugger has no view of a thread's block
   yet. Printing a thread-local means reading `fs_base`/`gs` from the
   stopped thread (`gs_base` on x64, the `fs` descriptor on x86).
4. **Allocator** (#498): per-thread heaps whose pointer lives in a
   `thread_local` once the seed can compile it.
