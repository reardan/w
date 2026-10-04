# Agent VMs: instant microVMs with shared memory (`wvm`)

Status: memory primitives, KVM cells, confined filesystem/TCP access,
guest threads, ready-cell snapshots/CoW clones, RAM pools, persistent Linux
box command sessions, and an initial bounded `wvmd` scheduler are implemented
(issue [#519](https://github.com/reardan/w/issues/519)). Private workspaces and
pinned image assembly are available. Live Linux snapshots, retained-vCPU
warm pools, cgroup fleet quotas, and external harness wiring remain open.
The usage sections below distinguish these implementations from the target
architecture.

Goal: let agents (wharness, wexec steps, anything driving the toolchain)
run work inside virtual machines that start and stop in well under a
millisecond, and that share RAM pages with each other instead of each
paying for its own copy of the same image.

## 0. Summary

`bin/wvm run` now executes a static x64 W program in a KVM cell, with
guest page permissions, checked syscall buffers, bounded output, and a
wall-clock timeout. Filesystem and network capabilities are explicit options;
threads use per-thread vCPUs. `bin/wvm box` boots a full Linux guest;
`--exec` uses the persistent command protocol. `wvmd` exposes bounded box
sessions to `lib.wvm_client`. Agent tool calls in the separate w-private
repository still need to be wired to that client.

The recommendation is a two-tier design on one W-native VMM core:

- **Tier 1, "cells"**: a KVM VM with no guest kernel that runs a static
  x64 W executable directly. Every syscall exits to the host, which
  services it against a policy. W is unusually well suited to this: its
  binaries are static, libc-free, and use a small syscall set, all
  emitted from a handful of runtime stubs the compiler controls. This is
  the Hyperlight model, and it is where "instant" lives.
- **Tier 2, "boxes"**: a minimal Linux guest for arbitrary agent work
  (bash, git, python, foreign compilers), restored from a snapshot.

Both tiers share the memory design that answers the "sharing RAM pages"
ask: guest RAM is a `MAP_PRIVATE` mapping of a sealed snapshot memfd, so
every clone shares every page until it writes one, spawn cost does not
grow with RAM size, and decommission is `close` + `munmap`.

Build order: syscall primitives, then a KVM hello-world, then Tier 1
cells with snapshots, then the `wvmd` daemon and wharness integration,
then Tier 2. Each milestone lands on its own (§9).

Sections 3–8 describe the target architecture, including later work.
The usage sections in §9 describe the implemented surface and its limits.

## 1. What exists today

| Area | State | Where |
|---|---|---|
| Agent execution | Unconfined host processes; no isolation beyond a permission prompt | w-private `wharness/wharness_tools.w` (`wh_run_shell`, `wh_tool_bash`) |
| Process control | fork/execve/wait4, pipes, poll-driven timeouts, `process_wait_any` | `lib/process.w`, `docs/projects/process.md` |
| Raw syscalls | Generic `syscall` / `syscall7`, `sys_ioctl`, clone, ptrace, mmap, eventfd, epoll, AF_UNIX | `lib/syscalls_linux_x86.w`, `lib/__arch__/*/syscalls.w` |
| File-backed mmap | `mmap_fd(addr, len, prot, flags, fd, offset)` with byte offsets on Linux x86/x64/ARM64; anonymous `mmap` retained | `lib/__arch__/*/syscalls.w` |
| memfd, seals, madvise | Implemented on Linux x86/x64/ARM64; named constants and lifecycle contract in `lib/memfd.w`; other targets return `-1` for the new primitives | `lib/memfd.w`, `tests/memfd_test.w` |
| userfaultfd | **Missing** (later milestone) | |
| KVM / cells | Per-thread x64 vCPUs, ELF validation, syscall gates, confined filesystem/TCP capabilities, fault vectors/RIP, timeout | `lib/kvm.w`, `lib/vmm/`, `tools/wvm.w` |
| Linux boxes | Persistent command channel, bounded separate output/status, private workspace overlay, optional 9p/network devices | `lib/vmm/box.w`, `lib/vmm/guest_agent.w`, `tools/wvm_init.w` |
| Cell snapshots | Sealed memfd ready templates, private clones, RAM reset and bounded pools | `lib/vmm/snapshot.w`, `lib/vmm/pool.w` |
| Session scheduler | Process-isolated Linux box workers, queue/admission/lease/cancellation, JSON-RPC client | `tools/wvmd.w`, `lib/wvm_client.w` |
| Signal handlers on x64 | Working, including the SA_RESTORER thunk (needed to kick a vCPU out of `KVM_RUN`) | `lib/signal.w` |
| Where `syscall` instructions come from | Runtime stubs the compiler emits: `syscall`, `syscall7`, `thread_create` (clone), `stack_create` (mmap), `__w_tls_set` (arch_prctl), plus the ELF exit stub | `code_generator/x64_asm.w:68-118`, `code_generator/elf_64.w:49` |
| Daemon pattern | AF_UNIX server with client auto-start | `tools/wbuildd.w`, `docs/projects/wbuildd.md`, `lib/json_rpc.w` |
| In-memory FS | Volatile/durable model behind the `file_ops` table, crash simulation | `lib/fake_fs.w`, `lib/file_ops.w` |
| Software sandbox | wasm32/WASI backend, run under wasmtime/node | `docs/projects/wasm_backend.md` |
| Out-of-process debugging | ptrace attach, core files | `docs/projects/debugger_attach.md`, `lib/core_file.w` |

Hosts: execution was tested on a Linux x64 host with accessible
`/dev/kvm`. KVM tests skip the execution leg if opening the device is
unavailable; layout and ELF validation tests still run. A failure after
opening KVM fails the tests. `bin/wvm available` checks VM creation
(exit 0 on success, 77 when unavailable); execution never falls back to
running the guest as a host process.

## 2. Goals and non-goals

Goals:

- Spawn a Tier 1 cell from a snapshot in under 1 ms, a Tier 2 box in
  tens of ms. Measured by gates, not asserted.
- Decommission instantly, and reset a VM to its snapshot in place even
  faster than destroying it.
- Share pages: N clones of one snapshot cost one copy plus each clone's
  dirty pages. Also explicit shared regions that several VMs map on
  purpose.
- One control API (`wvmd`) that wharness, wexec and humans all use.
- Everything written in W, with no new runtime dependencies on the host
  beyond the kernel.

Non-goals for now: live migration, GPU passthrough, Windows hosts,
running untrusted code on a multi-tenant host (the threat model is "an
agent's mistakes stay in the VM", not "hostile tenants").

## 3. Architecture

```
 wharness / wexec / wvm CLI
          │  JSON-RPC over AF_UNIX
          ▼
        wvmd ─── templates, snapshots, warm pools, shared regions
          │
     VMM core (lib/vmm/)
     ├── lib/kvm.w        ioctls, struct layouts, kvm_run
     ├── guest memory     memfd + MAP_PRIVATE clones, dirty log
     ├── cell runtime     ELF loader, page tables, syscall exits, policy
     └── box runtime      Linux boot, virtio-mmio (vsock, blk), serial
```

One process (`wvmd`) owns many VMs; each vCPU is a W thread
(`lib/thread.w`). KVM allows many VMs per process, which keeps
cross-VM sharing a matter of mapping the same memfd twice.

## 4. Memory: snapshots, clones and shared pages

This is the core of the request and is shared by both tiers.

1. **Guest RAM is a memfd.** A template VM's RAM is `memfd_create` +
   `ftruncate`, mapped `MAP_SHARED` while the template boots and warms
   up (loads the image, runs to a "ready" point).
2. **Snapshot.** Pause the vCPUs, save registers (`KVM_GET_REGS`,
   `KVM_GET_SREGS`, MSRs, LAPIC for Tier 2) into a small header, and
   unmap all shared writable RAM mappings before sealing the memfd
   with `F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW` (otherwise Linux
   returns `-EBUSY`; `mprotect` alone is insufficient). A
   snapshot is now an immutable (memfd, register blob) pair, persisted
   to disk only when asked.
3. **Clone = spawn.** `mmap(snapshot_fd, MAP_PRIVATE)`, then
   `KVM_SET_USER_MEMORY_REGION` with that address, then restore
   registers and `KVM_RUN`. The host kernel shares every page with the
   snapshot and with every other clone until the guest writes it (copy
   on write). Cost is a few syscalls regardless of RAM size; pages fault
   in lazily.
4. **Reset in place.** `madvise(MADV_DONTNEED)` on a clone's private
   mapping drops its dirty pages, so the next access sees snapshot
   contents again. Restoring registers on top gives a fresh VM without
   touching the VM or vCPU fds, which is what warm pools recycle.
   `KVM_GET_DIRTY_LOG` tells us which pages diverged, for accounting and
   for diff snapshots.
5. **Decommission.** Close the vCPU and VM fds and `munmap`. The
   clone's private pages are freed immediately; the snapshot lives on as
   long as any clone or the registry holds it.
6. **Explicit shared regions.** A named memfd mapped `MAP_SHARED` into
   several VMs at a fixed guest-physical address. Two uses:
   - read-only: a prebuilt toolchain or stdlib image every agent VM sees
     without copying (mapped read-only via `KVM_MEM_READONLY`);
   - read-write: a mailbox ring for agent-to-agent messages, with an
     eventfd (`KVM_IRQFD` for boxes, a cell syscall for cells) as the
     doorbell.
7. **Snapshot of a clone.** Linux cannot stack `MAP_PRIVATE` layers, so
   v1 materializes: copy the snapshot memfd into a new memfd and write
   the clone's dirty pages (from the dirty log) over it. That is
   O(RAM) but fine for 64–256 MB guests. v2 replaces it with a
   `userfaultfd` page server that resolves faults through a chain of
   page layers, which makes snapshot-of-clone O(dirty pages) and
   unlocks cheap per-turn checkpoints (§8).
8. **Cross-template dedupe** (optional): `MADV_MERGEABLE` on box RAM so
   KSM merges identical pages between guests from different templates.

## 5. Tier 1: cells (no guest kernel)

A cell runs one static x64 W executable.

- **Guest setup.** The host builds identity-mapped 4-level page tables
  in reserved low guest memory, a flat GDT, and an IDT whose every
  vector traps to the host (an `out` to a fault port), and enters long
  mode directly via `KVM_SET_SREGS`. No firmware, no boot code.
- **Loading.** Map the ELF's `PT_LOAD` segments, set up a stack with
  argv/envp exactly as `lib/lib.w`'s `_main` expects (envp right after
  argv's NULL), and set `rip` to the entry. Snapshot here: this is the
  "ready" point, so every spawn skips loading too.
- **Syscalls, unmodified binaries.** The program runs at CPL 3. The host
  sets `EFER.SCE` and points `LSTAR` at a ring-0 trampoline that does
  `out` to a syscall port (a VM exit carrying the registers), reloads
  CR3 to flush changed guest page permissions, and returns with
  `sysretq`. Existing static x64 W binaries using the implemented
  syscall subset run without recompilation.
- **Syscalls, compiled for cells** (the compiler piece, §7). A
  `--syscall-abi=vmcall` option makes the runtime stubs in
  `code_generator/x64_asm.w` and the exit stub in
  `code_generator/elf_64.w` emit `vmcall` instead of `syscall`, which
  skips the trampoline hop, and turns `__w_tls_set`'s `arch_prctl` into
  a hypercall the host answers by setting `GS.base` directly.
- **Host syscall handler.** A table over the syscalls the W runtime
  and stdlib actually issue: `read`, `write`, `openat`, `close`,
  `lseek`, `statx`, `getdents`, `mmap`/`munmap`/`brk` (served from the
  cell's own RAM), `clock_gettime`, `getrandom`, `futex`,
  `exit_group`. Unsupported calls return `-ENOSYS`, logged so the gap
  list is data-driven. `clone(CLONE_VM)` becomes a new vCPU, so W
  threads work; `fork`/`execve` are `-ENOSYS` in v1 (an agent that
  needs them wants a box).
- **Policy.** Per-cell: a filesystem view (a read-only host root plus a
  private in-memory upper layer, reusing `lib/fake_fs.w`'s volatile
  model behind `file_ops`), an fd budget, a wall-clock and instruction
  budget, and network off by default (later: allowlisted `connect`
  proxied by the host).
- **Determinism for free.** Every syscall exits, so `clock_gettime` and
  `getrandom` can be virtualized from a seed. A cell run is then
  replayable from its syscall log, which ties straight into
  `docs/projects/simulation.md`.
- **Faults.** A guest exception exits with the vector and `rip`; the
  host symbolizes it from the binary's DWARF (`code_generator/dwarf.w`
  already emits it) and reports it the way `lib/crash.w` does.
- **Timeouts.** A watchdog thread sets `kvm_run.immediate_exit` and
  signals the vCPU thread; `lib/signal.w`'s x64 thunks make the needed
  handler possible.

## 6. Tier 2: boxes (Linux guest)

For work that needs a real OS: shells, git, package managers.

- **VMM pieces.** Linux boot protocol (load `vmlinux`, `boot_params`,
  command line), an 8250 serial console on port IO, and three
  virtio-mmio devices: vsock (the exec channel), blk (a read-only root
  image, with an overlay on tmpfs inside the guest), and later net.
- **Guest agent.** `wvm_init`, a static W binary running as PID 1,
  listens on vsock, spawns commands with `lib/process.w`, streams
  stdout/stderr back, and enforces in-guest timeouts. The guest's init
  being W keeps the image tiny and dogfoods the toolchain.
- **Templates.** Boot once, start `wvm_init`, snapshot (registers +
  LAPIC + device state + RAM). Spawns restore that; Firecracker's
  numbers for the same pattern are in the low tens of ms, dominated by
  device restore rather than memory.
- **Shared regions** appear as a reserved physical range
  (`memmap=` on the kernel command line) that `wvm_init` maps via
  `/dev/mem`; a virtio-pmem device is the cleaner follow-up.

This tier is several thousand lines of VMM. The alternative is a
`wvmd` backend that drives Firecracker over its API socket and uses its
snapshot memory file (which it already maps `MAP_PRIVATE`, giving the
same page sharing). See §10 for the decision.

## 7. Compiler and stdlib changes

Concrete inventory, all seed-era syntax (none of it adds language
syntax, so `tests/parser_generator/w.pg` is untouched):

- `lib/syscalls_linux_x86.w` and `lib/__arch__/{x86,x64,arm64}/syscalls.w`:
  `mmap_fd(addr, len, prot, flags, fd, offset)` (the existing `mmap`
  stays as the anonymous shorthand), `memfd_create`, `madvise`,
  `fcntl` seals, `userfaultfd` (later), with per-arch numbers and `-1`
  stubs on darwin/win64/wasm.
- `lib/kvm.w`: ioctl numbers, `kvm_regs` / `kvm_sregs` /
  `kvm_userspace_memory_region` / `kvm_run` layouts written with the
  `save_int32`/`save_int64` helpers. x64 host only; the i386 build gets
  a stub through `lib/__arch__/` since 32-bit KVM userspace is not
  worth supporting.
- `lib/vmm/`: guest memory, snapshot, cell runtime, box runtime.
- `code_generator/x64_asm.w`, `code_generator/elf_64.w`: the
  `--syscall-abi=vmcall` lowering (§5), selected the same way the arch
  selectors are. Gated by `./wbuild verify_x64`, since it touches the
  x64 runtime stubs.
- `tools/wvmd.w`, `tools/wvm.w` (CLI: `wvm run file.w`, `wvm snapshot`,
  `wvm ls`, `wvm kill`), `tools/wvm_init.w` (box guest agent), each
  owning its targets with `# wbuild:` directives.
- `lib/wvm_client.w`: the client side wharness and wexec import.

## 8. Control plane and agent integration

`wvmd` follows the wbuildd pattern: AF_UNIX socket, JSON-RPC
(`lib/json_rpc.w`), auto-started by clients.

| RPC | Does |
|---|---|
| `template_create(image, warmup)` | Boot or load, run to ready, snapshot; returns a snapshot id |
| `vm_spawn(snapshot, policy, regions)` | Clone; served from a warm pool when one exists |
| `vm_exec(vm, argv, stdin, timeout)` | Run a command (box) or the cell's program; returns status + output |
| `vm_snapshot(vm)` | Snapshot a running VM; returns a snapshot id |
| `vm_reset(vm)` / `vm_destroy(vm)` | Reset in place / decommission |
| `region_create(name, size, mode)` | Named shared region for later spawns |
| `stats()` | Per-VM private RSS (dirty pages), shared bytes, spawn latency |

Warm pools keep N reset clones per hot template, so a spawn is handing
out an fd set.

Integrations, in order of value:

1. **wharness `--sandbox=cell|box|none`** (w-private): routes `bash`,
   `w_run` and `w_test` through `wvmd`. One VM per agent session, with a
   snapshot per turn, gives agents cheap rollback of their own
   mistakes ("undo the last turn" is `vm_spawn(previous_snapshot)`).
2. **wexec `"sandbox": "cell"`** on a step: hermetic, deterministic test
   runs; parallel test workers clone one warm template.
3. **Fan-out**: an agent spawns K clones of its current state to try K
   approaches, keeps the winner's snapshot, and destroys the rest.

## 9. Staged path

Each milestone lands green on its own.

| # | Milestone | Gate |
|---|---|---|
| M0 | **Implemented:** syscall primitives `mmap_fd`, `memfd_create`, `madvise`, seals | `tests/memfd_test.w` (x86/x64): shared initialization, seal enforcement, isolated private clones, byte offsets, errors, partial/full reset, fd/mapping lifetime |
| M1 | **Implemented:** `lib/kvm.w` and a guest that writes to a port | `tests/kvm_hello_test.w`: ABI layouts, real port write and halt (execution skips with no `/dev/kvm`) |
| M2 | **Implemented:** ELF loader, ring-3 long mode, LSTAR gate, syscall subset; `wvm run tests/hello.w` | `tests/wvm_test.w`: existing x64 map/set, compound-assignment and float64 suites; TLS, syscall boundary, faults, timeout, malformed ELF |
| M3 | **Partial:** ready-cell snapshots, CoW clones and RAM reset; vCPUs recreated | `wvm_snapshot_test`; `wvm_pool_bench` reports timings and memory, no universal latency claim |
| M4 | Policy, overlay fs, deterministic clock/random, symbolized faults | Policy-denial tests; replay test |
| M5 | **Partial:** bounded box scheduler, client, independent cell RAM pools; shared regions/harness wiring pending | `wvmd_test`; external wharness gate pending |
| M6 | `--syscall-abi=vmcall` in the compiler | `verify_x64`; measured syscall round-trip win |
| M7 | **Partial:** persistent QEMU/KVM boxes, daemon integration, pinned image builder; Linux snapshots pending | `wvm_box_test`, `wvm_channel_test`, `wvm_image_test`; Linux snapshot gate pending |
| M8 | **Threads implemented:** per-thread vCPUs, futexes, TLS, preemption. wdbg attach, layered snapshots, and other host ports pending | `wvm_thread_test`; per-port gates pending |

A ptrace backend (`PTRACE_SYSEMU`) for the cell syscall handler is
worth adding alongside M2: the same policy code runs on hosts without
KVM (including the Claude cloud container), slower but testable
everywhere, with `fork` from a zygote giving the same page sharing.

### M0 usage and limits

Import `lib.memfd` for the Linux constants and syscall surface. Create
with `memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING)`, size with
`sys_ftruncate`, then initialize with `mmap_fd(..., MAP_SHARED, fd, 0)`.
Unmap shared writable mappings before adding seals with
`sys_fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW)`.
Writable `MAP_PRIVATE` clones can then be reset with
`madvise(addr, length, MADV_DONTNEED)`. Close descriptors and unmap each
mapping separately; mappings remain valid after closing their fd.

Offsets are signed, word-sized **bytes**, aligned to host pages. On
i386 the wrapper converts to `mmap2`'s 4096-byte units and rejects
unaligned offsets, with a maximum offset of `2^31 - 1`; x64/ARM64 use
64-bit words. Linux errors are raw negative errno values. A successful
x86 mapping can look negative, so check the range `[-4095, -1]`, not
merely `< 0`. Darwin, win64 and wasm return `-1` for `mmap_fd`,
`memfd_create` and `madvise`; their anonymous `mmap` is unchanged.
Linux seal command numbers must not be sent to non-Linux `sys_fcntl`.

The M0 gate needs no KVM: `./wbuild memfd_test memfd_64_test`.
It establishes memory semantics, not VM spawn latency or RSS gates
(M3). The [Linux memfd documentation](https://man7.org/linux/man-pages/man2/memfd_create.2.html)
describes the required unmap-before-seal lifecycle.

### Running a cell (M1–M2 and capability extensions)

From the repository root, on Linux x64 with access to `/dev/kvm`:

```sh
./wbuild wvm
./bin/wvm available
./bin/wvm run tests/hello.w
./bin/wvm run --timeout-ms 1000 bin/map_set_builtin_64_test
./wbuild kvm_hello_test wvm_test
```

`.w` input is compiled **on the host** with `bin/wv2 x64` into a private
temporary directory under `bin/`, then the ELF executes in KVM. The
temporary image is removed after loading. An existing ELF is loaded
directly. Source compilation is not sandboxed. Guest arguments follow
the input filename. The host environment is not inherited; the only
guest environment entry is `W_CRASH_TRACE=0`, because faults are reported
by the VMM. The CLI supplies EOF on stdin; the library API accepts a
borrowed binary input buffer through `input` / `input_length`.

The runner returns the guest's exit code. Timeout returns 124; loader,
KVM, or output-budget errors return 125. Guest page/protection faults
return 139, invalid instructions 132, and divide faults 136, with the
exception vector and guest RIP on stderr. Fault symbolization is M4.
Output is captured while running, then emitted to stdout/stderr.

Current syscall support:

- `read` from the supplied input, `write` to captured stdout/stderr,
  `close` of those three virtual descriptors, `exit` / `exit_group`.
- `brk`, private anonymous `mmap`, `mprotect`, and `munmap` of mmap
  allocations. Mappings are bounded and allocated monotonically; unmap
  releases backing pages but does not recycle virtual addresses yet.
- `arch_prctl` setting FS/GS (W TLS), realtime/monotonic `clock_gettime`,
  nonblocking `getrandom`, virtual `getpid`/`gettid`, and `sched_yield`.
- Shared-address-space `clone`, per-thread FS/GS and register state,
  `set_tid_address`, private/shared futex wait/wake with relative timeouts,
  per-thread `exit`, and group `exit_group`. Threads use separate KVM vCPUs
  scheduled on one host thread with a 5 ms preemption quantum. Default
  limit: 16 threads, configurable with `--max-threads 1..64`.
- Optional confined filesystem and IPv4 TCP capabilities (below).
  File opens and sockets are denied by default. Fork/exec and guest signal
  registration remain unsupported (`-ENOSYS`); the CLI reports the last
  unsupported syscall number.

Guest descriptors are translated through bounded private tables; guest paths
are resolved beneath an explicitly granted root. Every syscall copy checks
overflow, mapped pages, and read/write permissions.
Low 2 MiB guest memory holds supervisor-only tables and traps. The
256 MiB guest address space reserves 2–128 MiB for anonymous mappings,
128–224 MiB for static ELF load segments, heap growth up to 240 MiB,
and a stack at 248–256 MiB. Only touched pages consume physical RAM.
The ELF loader rejects dynamic/interpreter images, overlapping load
pages, invalid offsets/alignment, and non-executable entry points.

Execution has a default 5-second timeout (configurable 1–600000 ms), a
combined 4 MiB stdout/stderr budget, and a million syscall-exit limit.
The watchdog interrupts even a guest that never makes a syscall. The
`lib.vmm.cell` API is one-shot and must be serialized in a single-threaded
host process: it temporarily owns SIGALRM, restores the previous handler
and signal mask, and refuses an already active/pending real-time alarm.
`cell_free` releases every vCPU, VM, run mapping, guest RAM, buffer,
filesystem descriptor, and socket.

Ready-cell snapshots and reset are available through `lib.vmm.snapshot`;
live snapshots, deterministic services and instruction-count budgets remain
later work. The threat model in §2 still applies.

### Filesystem and networking capabilities

```sh
./bin/wvm run --fs-root ./workspace program.w
./bin/wvm run --fs-root ./workspace --fs-write program.w
./bin/wvm run --net-allow 127.0.0.1:8080 --max-threads 8 program.w
./wbuild wvm_fs_test wvm_net_test wvm_thread_test
```

`--fs-root` pins a host directory before execution. Guest absolute paths
are relative to that root; directory descriptors remain confined
capabilities. `openat2` enforces BENEATH, NO_SYMLINKS, NO_MAGICLINKS, and
NO_XDEV. All symlinks, devices, FIFOs, and mount crossings are denied.
Linux `openat2` and host `/proc/self/fd` are required; unsupported hosts
fail closed. Regular-file I/O, seeking, stat/statx, directory enumeration,
and confined mkdir/unlink/rename/truncate/sync operations are supported.
The default is read-only; `--fs-write` permits **actual writes to the
exported host directory**, not a copy-on-write overlay. File descriptors
occupy guest slots 3–63. Library: `cell_fs_configure(cell, root, writable)`.

Repeat `--net-allow IPV4:PORT` to allow up to 64 exact TCP destinations.
There is no DNS resolution, UDP, raw socket, listener, Unix-domain socket,
or arbitrary-destination send support. Socket descriptors occupy guest
slots 64–127. Host sockets always remain nonblocking; guest blocking I/O
and `poll` park the calling vCPU so other guest threads can progress,
while the cell deadline remains active. Closing a socket cancels parked
operations on it with `EBADF`, so descriptor reuse cannot redirect them.
Guest nonblocking sockets return
Linux `EAGAIN`/`EINPROGRESS` as appropriate. Library:
`cell_net_allow(cell, ipv4, port)` before `cell_run`.

Thread support targets W's static runtime and Linux's shared-thread clone
subset, not general process cloning or complete pthread/glibc compatibility.
The fixed anonymous-mapping arena still limits repeated stack allocation.

### Running a Linux box

```sh
./wbuild wvm wvm_init
./bin/wvm box --kernel /path/to/bzImage --initrd /path/to/root.cpio.gz
./bin/wvm box --kernel /path/to/bzImage --initrd /path/to/root.cpio.gz \
  --cpus 4 --memory-mb 512 --timeout-ms 60000 \
  --fs-root ./workspace --network --append 'quiet -- /bin/sh /job.sh'
```

Boxes use the installed `qemu-system-x86_64` microvm machine with KVM
acceleration and the host CPU. They require Linux x64, accessible
`/dev/kvm`, a compatible x64 Linux kernel, and a supplied initramfs with
an executable `/init`. There is no runtime download or emulation fallback.
QEMU provides Linux boot and virtio devices; the cell backend remains W's
native KVM implementation. Persistent sessions use a dedicated virtio-serial
channel rather than vsock. Linux snapshots and disk-image management remain
open.

The default is 2 vCPUs, 256 MiB RAM, a 30-second deadline, no network
device, and no host filesystem export. Limits are 1–64 vCPUs, 64–32768 MiB,
and 1–600000 ms. Without `--exec`, the console streams to inherited stdio. Deadline expiry
kills and reaps QEMU, restores terminal settings, and returns 124;
launch/configuration errors return nonzero. Without `--exec`, the CLI returns
**QEMU's exit status**, not a command's exit status; a kernel panic followed
by reboot can also produce QEMU status 0. Inspect the guest console/job
protocol for workload success.

Place `bin/wvm_init` at `/init` in an initramfs to use the supplied small W
PID 1. It mounts proc/sys/dev, executes the arguments after the kernel
command line's `--` (default `/bin/sh`), prints `wvm-init: exit N`, syncs,
and reboots. Include the command and its required binaries/libraries in
the initramfs; this tool does not assemble a distribution. An initramfs
should include `/dev/console` (character device 5:1) for early output.
The exit line is guest-controlled console output, not an authenticated
host status channel.

`--fs-root` adds a read-only virtio-9p export tagged `work`; mount inside
Linux with `mount -t 9p -o trans=virtio,version=9p2000.L work /workspace`.
`--fs-write` explicitly permits host writes using QEMU's mapped-xattr
security model. `--network` adds QEMU user-mode networking with outbound
connectivity (including host services), DHCP/DNS, and no inbound forwarding.
This is broader than the cell's destination allowlist. The guest kernel
must provide virtio-mmio, 9p/virtio filesystem, and virtio-net support
(built in or included modules), and the guest must configure its network.
No tap device, elevated host privileges, or host network reconfiguration
is needed.

`wvm_box_test` always checks device policy/argument construction. Set
`WVM_TEST_KERNEL=/path/to/bzImage` to also generate a minimal initramfs and
boot a real Linux guest that exercises filesystem I/O and thread creation:

```sh
WVM_TEST_KERNEL=/path/to/bzImage ./wbuild --no-cache wvm_box_test
```

The implementation was boot-tested with Alpine's 6.12 virt kernel.
The minimal boot fixture does not contain 9p/network driver modules;
box export and network device selection have construction tests, while
cell filesystem and TCP paths have real KVM integration coverage.
Backend references: [QEMU microvm](https://www.qemu.org/docs/master/system/i386/microvm.html)
and [QEMU invocation](https://www.qemu.org/docs/master/system/invocation.html).

### Persistent commands and private workspaces

```sh
./wbuild wvm wvm_init wvmd
./bin/wvm box --kernel /path/to/bzImage --initrd /path/to/root.cpio \
  --workspace ./project --cwd /work --exec /bin/sh -c 'git status --short'
```

`--exec` returns the guest command status, keeps stdout/stderr separate,
and caps each stream at 1 MiB. Timeout returns 124; setup/transport/output
limit errors return 125. The direct CLI closes the box after that command.
Library callers retain `box_session_open(options)` and call
`box_session_exec(session, argv, cwd, timeout_ms, output_limit)` repeatedly;
`box_session_close` destroys it. Argv must start with an absolute executable
path. Stdin is `/dev/null`; interactive stdin and incremental output streaming
are not implemented. The guest kills command descendants before replying,
so filesystem changes persist but background services do not.

The host requires a readiness greeting on a dedicated UNIX-socket-backed
virtio-serial channel, independent of console text. PID 1 opens
`/dev/vport0p1`; the guest kernel must have `CONFIG_VIRTIO_CONSOLE` built in
(or the image must load it before starting the agent). Malformed replies,
disconnects and host deadlines invalidate the session. Cancellation destroys
the entire box. QEMU receives a parent-death signal so a crashed worker does
not leave it running. The persistent backend requires Linux 5.9+ for
`close_range` descriptor isolation; filesystem confinement also requires
`openat2`.

`--workspace` prepares a private host copy using Linux `openat2` confinement.
Files use `FICLONE` when supported, otherwise bounded copying; host inodes
are never shared. Symlinks, special files and mount crossings are rejected.
Preparation limits are 1 GiB, 100000 entries, 64 directory levels and 60 s
for the CLI. With `--exec`, the copy is exported read-only and mounted beneath
a guest overlay at `/work`. Its tmpfs upper layer defaults to 64 MiB;
`--workspace-mb 1..1024` sets its byte cap. The guest kernel must supply
9p/virtio, tmpfs and overlayfs. Requested mount failures prevent readiness.
Guest commands retain filesystem capabilities only and cannot regain admin
capabilities through exec; this prevents remounting the capped tmpfs. The
remaining root filesystem still consumes the VM's fixed RAM budget.
The source tree must remain stable while copying and contain its own Git
metadata: external `.git` worktree pointers are not materialized.
`--workspace` requires
`--exec`; use the daemon for several commands in one workspace. Cleanup runs
after the VM stops. Explicit `--fs-write` retains the older direct host-write
semantics and must not be used for independent agent workspaces.

Networking remains absent by default. `--network-restricted` selects QEMU
user networking with `restrict=on`; `--network` deliberately allows broad
outbound access, including host services. Daemon sessions deny networking.
Host environment variables and credentials are not injected into the guest;
only the supplied image and explicit filesystem export are visible. A
credential broker and destination-allowlisted box egress are still open.

`wvm_channel_test` exercises framing and command lifecycles without KVM.
`WVM_TEST_KERNEL=bin/wvm_linux_kernel ./wbuild wvm_box_test wvmd_box_test`
adds real Linux command and concurrent-daemon tests. The workspace overlay
boot test additionally requires `WVM_TEST_WORKSPACE_KERNEL` pointing to a
kernel with built-in 9p/virtio and overlayfs. The available minimal Alpine
kernel passed channel tests but lacks those built-in filesystem drivers;
real overlay behavior remains unverified on this checkout's fixture kernel.

### Reproducible Linux image assembly

```sh
python3 tools/wvm_image.py --rootfs /images/agent-rootfs.tar.gz \
  --sha256 <pinned-rootfs-sha256> --init bin/wvm_init --output bin/agent.cpio
```

The rootfs archive must already contain the chosen shell, Git, language
runtimes, shared libraries and CA certificates. Assembly does no networking
or host extraction. It verifies the required rootfs digest, normalizes entry
ordering, ownership and timestamps, strips setuid/setgid, installs W PID 1,
and creates the early console device and mountpoints. It rejects duplicate,
traversing and special-file entries, and paths beneath symlinks. Output is
atomically replaced only after successful assembly. `agent.cpio.json` records
rootfs, init and output SHA256 values; keep the rootfs digest and kernel pin
in deployment configuration. Python is a build-time dependency only. This
provides reproducible assembly, not a maintained distribution/package lock.

### Session daemon and harness client

```sh
./bin/wvmd serve --socket bin/wvmd.sock --max-active 4 --max-pending 16 \
  --cpus 8 --memory-mb 2048 --workspace-mb 1024
# From another terminal:
./bin/wvmd call bin/wvmd.sock vm_spawn \
  '{"kernel":"/images/bzImage","initrd":"/images/agent.cpio","workspace":"/src/project","workspace_mb":64,"lease_ms":60000}'
./bin/wvmd call bin/wvmd.sock vm_status '{"session":1}'
# Once ready:
./bin/wvmd call bin/wvmd.sock vm_exec \
  '{"session":1,"argv":["/bin/sh","-c","git status --short"],"cwd":"/work","timeout_ms":10000}'
./bin/wvmd call bin/wvmd.sock vm_result '{"session":1,"offset":0,"length":1024}'
./bin/wvmd call bin/wvmd.sock vm_destroy '{"session":1}'
./bin/wvmd call bin/wvmd.sock stats
./bin/wvmd call bin/wvmd.sock stop
```

The foreground daemon uses mode-0600 local JSON-RPC with Content-Length
framing. It admits a bounded FIFO queue into process-isolated workers, with
aggregate vCPU/guest-RAM/workspace reservations. Completed sessions occupy
bounded table slots until destroyed or expired. `vm_exec` submits work;
`vm_result` polls status and bounded chunks of binary-safe hex stdout/stderr.
`vm_cancel` destroys a session; `vm_renew` extends its lease. Boot/command
failure, lease expiry, cancellation and orderly shutdown reclaim workers.
No shell command is ever executed on the host as a fallback.

The daemon owns a private `<socket>.state` directory and holds an exclusive
lock. Before releasing a new worker, it durably records its process group
and workspace identity. On restart it waits for old groups to disappear
without signaling recycled PIDs, then reclaims only owned workspaces and
channel directories. Unexpected ownership, malformed records or surviving
groups fail closed. This recovers abandoned storage; it does not resume
commands or reconstruct running agent sessions. Keep this state directory
with the socket between restarts.

`lib.wvm_client` provides the reusable control interface for external
harnesses. The w-private harness is outside this checkout, so its tool-routing
integration is not part of this change. Automatic daemon startup, session
recovery, multi-host scheduling and Linux snapshot pools remain future work.
CPU/RAM admission limits constrain guest configurations; they are not host
cgroup quotas and do not include all QEMU overhead. Per-process, CPU-time,
network-rate and aggregate host-RSS enforcement need a delegated cgroup
policy before treating this as a multi-tenant fleet manager.

A real fleet benchmark uses that same daemon API:

```sh
python3 tools/wvm_fleet_bench.py --socket bin/wvmd.sock \
  --kernel /images/bzImage --initrd /images/agent.cpio --count 16 -- /bin/true
```

It submits concurrent sessions and reports launch latency including queueing,
command latency including polling, throughput, failures and daemon counters
before/after cleanup. All benchmark-owned sessions are destroyed, including
on failure. A local eight-session run with two active boxes completed all
eight commands in 5.85 seconds and returned active/queued/reserved CPU/RAM
counters to zero. This is a small smoke measurement, not a capacity guarantee. Size the daemon's active/pending limits for the requested count;
admission rejection is reported as a benchmark failure. This operational
helper uses only Python's standard library.

### Cell templates, RAM pools and measurement

`cell_snapshot_create(cell)` captures a loaded, stacked, never-run cell with
pristine I/O and no external resources. Capture scans RAM once, writes
nonzero pages into a sparse memfd, and seals it. Clones use `MAP_PRIVATE` and
retain backing independently of the template owner's lifetime. Input is
owned per clone. Configure filesystem/network capabilities separately after
cloning. `cell_snapshot_reset` drops private pages and clears all per-run
resources, descriptors, output, fault and watchdog state; it recreates KVM
VM/vCPUs on the next run. It does not capture a running process or roll back
external filesystem writes.

`cell_pool_new(snapshot, capacity)`, `cell_pool_acquire` and
`cell_pool_release` provide bounded RAM-ready leases. A pool owns its cells;
release them to the pool instead of freeing them. Exhaustion returns null.
The API remains serialized within a host process, including snapshot
reference counts. Pools do not retain initialized vCPUs or serve Linux boxes.

```sh
./wbuild wvm_snapshot_test wvm_pool_bench
./bin/wvm_pool_bench bin/wvm_fixture 100 100 smoke payload
```

The benchmark emits JSON with clone/reset/run latency percentiles,
whole-process `/proc/self/smaps_rollup` RSS/PSS/private/shared memory at
baseline/shared/dirty/reset/cleanup, dirty-page workload, pool counters,
failures and file-descriptor counts. It measures serial cell runs and RAM
sharing, not concurrent Linux-agent throughput. Results depend on the host;
there is no unconditional sub-millisecond startup/reset gate. On this host,
100 RAM clones plus 400 deliberately dirty pages added 1604 KiB private
dirty memory; reset returned near baseline and descriptor counts stayed
4 → 4. Clone p50/p95 were 4.35/7.83 µs; real-KVM reset p50/p95 were
17.38/23.38 ms. These results include KVM teardown and explain why retained
vCPU pools remain a separate performance milestone.

## 10. Open decisions

1. **Where KVM runs.** The implementation host runs the KVM gates.
   Hosts without `/dev/kvm` run loader/layout tests and skip execution;
   a required KVM CI runner or the proposed ptrace backend remains to
   be configured.
2. **Tier 2 build vs adopt.** The initial implementation adopts QEMU
   microvm with KVM. A W-native runtime or Firecracker backend can replace
   it behind a future `wvmd` API if measured deployment needs justify it.
3. **Repo split.** VMM core, cells, `wvmd` and the compiler flag in
   `w`; the wharness integration in `w-private`.
4. **macOS.** Hypervisor.framework allows one VM per process, so on the
   Mac `wvmd` would run a helper process per VM, sharing snapshot pages
   through a mapped file instead of a memfd.

## 11. Risks

- **Struct layouts.** KVM structs are fixed-width and padded; W's
  word-sized `int` means every field goes through explicit
  `save_int32`/`save_int64` at known offsets. A layout test per struct
  against the kernel header values guards this.
- **The hex-literal gotcha.** Several KVM ioctl numbers and CR0/CR4/EFER
  bits have bit 31 set; build them at runtime as `lib/sha256.w` does.
- **Syscall coverage drift.** New stdlib code that issues a syscall the
  cell handler does not implement fails only in cells. The `-ENOSYS`
  log plus running a slice of `tests_x64` inside cells catches it.
- **CoW is not a security boundary for side channels.** Shared pages
  leak timing between clones; acceptable under the stated threat model,
  not for hostile tenants.
