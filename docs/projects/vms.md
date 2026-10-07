# Agent VMs: instant microVMs with shared memory (`wvm`)

Status: Linux x64 cells and QEMU/KVM boxes support sealed CoW templates,
bounded pools, process-isolated daemon sessions, explicit cell shared regions,
private workspaces and delegated cgroup-v2 quotas (issue
[#519](https://github.com/reardan/w/issues/519)). Cells additionally support
seeded syscall services, replay verification, retained vCPUs, paused live
checkpoints, bounded snapshot layers and a scriptable guest debugger. The
external wharness companion adds per-turn checkpoints, rollback and branches.
A required real-VM CI workflow is implemented; ordinary developer tests may
still skip unavailable optional host facilities. The usage and validation
sections below distinguish implemented code from measured proof and follow-ups.

The latency goal is cheap cell reuse and Linux snapshot restore, with shared
RAM backing across clones. Ready-pool acquisition is distinct from VM creation,
command execution and dirty-session replacement; measurements below report
those costs separately and impose no machine-independent timing promise.

## 0. Summary

`bin/wvm run` now executes a static x64 W program in a KVM cell, with
guest page permissions, checked syscall buffers, bounded output, and a
wall-clock timeout. Filesystem and network capabilities are explicit options;
threads use per-thread vCPUs. `bin/wvm box` boots a full Linux guest;
`--exec` uses the persistent command protocol. `wvmd` exposes bounded cell and box
sessions to `lib.wvm_client`. The separate w-private
harness routes all tool calls through that client when VM mode is selected.

The implementation has two execution tiers:

- **Tier 1, "cells"**: a KVM VM with no guest kernel that runs a static
  x64 W executable directly. Every syscall exits to the host, which
  services it against a policy. W is unusually well suited to this: its
  binaries are static, libc-free, and use a small syscall set, all
  emitted from a handful of runtime stubs the compiler controls. This is
  the Hyperlight model; ready mapping and retained-vCPU reuse target very
  low overhead.
- **Tier 2, "boxes"**: a minimal Linux guest for arbitrary agent work
  (bash, git, python, foreign compilers), restored from a snapshot.

Both tiers share immutable backing through private mappings. Cell RAM is
mapped directly by W; QEMU maps Linux CoW RAM and restores device/vCPU state.
Creating a checkpoint still scans or materializes RAM. Restoring a box still
starts QEMU and restores devices; sharing RAM does not make that work constant
or free. Sections 3–8 explain the implemented architecture and explicitly
marked extensions; §9 provides commands, measurements and limits.

## 1. What exists today

| Area | State | Where |
|---|---|---|
| Agent execution | Companion adapter: guest tool routing, turn checkpoints, rollback and branches; host execution remains the default | w-private `wharness/wharness_tools.w`, `wharness/tests/vm_test.py` |
| Process control | fork/execve/wait4, pipes, poll-driven timeouts, `process_wait_any` | `lib/process.w`, `docs/projects/process.md` |
| Raw syscalls | Generic `syscall` / `syscall7`, `sys_ioctl`, clone, ptrace, mmap, eventfd, epoll, AF_UNIX | `lib/syscalls_linux_x86.w`, `lib/__arch__/*/syscalls.w` |
| File-backed mmap | `mmap_fd(addr, len, prot, flags, fd, offset)` with byte offsets on Linux x86/x64/ARM64; anonymous `mmap` retained | `lib/__arch__/*/syscalls.w` |
| memfd, seals, madvise | Implemented on Linux x86/x64/ARM64; named constants and lifecycle contract in `lib/memfd.w`; other targets return `-1` for the new primitives | `lib/memfd.w`, `tests/memfd_test.w` |
| userfaultfd | **Missing** (later milestone) | |
| KVM / cells | Per-thread x64 vCPUs, ELF validation, syscall gates, confined filesystem/TCP capabilities, fault vectors/RIP, timeout | `lib/kvm.w`, `lib/vmm/`, `tools/wvm.w` |
| Linux boxes | Persistent command channel, bounded separate output/status, bounded tmpfs workspace import, optional explicit 9p/network devices | `lib/vmm/box.w`, `lib/vmm/guest_agent.w`, `tools/wvm_init.w` |
| Cell snapshots | Ready templates, bounded layers, paused live checkpoints, private clones and retained-vCPU reset | `lib/vmm/snapshot.w`, `lib/vmm/live_snapshot.w`, `lib/vmm/pool.w` |
| Guest debugging | Fresh-cell instruction stepping, hardware execute breakpoints, thread/register/memory inspection | `lib/vmm/debug.w`, `tools/wvm_debug.w`, `bin/wdbg vm` |
| Linux snapshots | Idle-session RAM/device capture, imported-workspace rollback, sealed CoW RAM and independent restores | `lib/vmm/box_snapshot.w`, `lib/vmm/qmp.w` |
| Host quotas | Delegated cgroup v2 CPU, memory, swap and process enforcement | `lib/vmm/cgroup.w` |
| Session scheduler | Process-isolated cell/box workers, template/shared-region registries, queue/admission/lease/cancellation, JSON-RPC client | `tools/wvmd.w`, `lib/wvm_client.w` |
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
  tens of ms. Benchmarks report host-specific results; correctness gates
  do not assert universal timing thresholds.
- Bound cleanup and reuse costs. Cells support in-place RAM/vCPU reset;
  Linux pools replace dirty guests from a template.
- Share pages: N clones of one snapshot cost one copy plus each clone's
  dirty pages. Also explicit shared regions that several VMs map on
  purpose.
- One control API (`wvmd`) that wharness, wexec and humans all use.
- Keep the control plane, cell VMM and guest agent in W. Linux boxes
  currently require installed QEMU; image/benchmark tooling also uses Python.

Non-goals for now: cross-host live migration, GPU passthrough, Windows hosts,
running untrusted code on a multi-tenant host (the threat model is "an
agent's mistakes stay in the VM", not "hostile tenants").

## 3. Architecture

```text
 wharness / wexec / wvmd CLI
          │  JSON-RPC over AF_UNIX
          ▼
        wvmd ─── template and cell shared-region registries, quotas, leases
          │
          ├── isolated cell worker ── W KVM runtime, per-thread guest vCPUs
          └── isolated box worker  ── QEMU/KVM microvm + W guest PID 1
```

The daemon owns registries and admission state; each session runs in a worker
process. Shared sealed descriptors cross process boundaries with SCM_RIGHTS.
Cell guest threads are vCPUs scheduled on one host execution thread, not one
host thread per vCPU. QEMU supplies the Linux device model. The standalone
cell and box pool APIs are serialized library interfaces; the daemon restores
box templates on demand and retains sessions between commands, with no pool RPC.

## 4. Memory: snapshots, clones and shared pages

Ready cell snapshots scan RAM into sparse sealed memfds; clones privately map
the immutable backing. Reset drops private pages and clears run state. The
retained pool also restores vCPU state without replacing VM/vCPU descriptors.
Snapshot ownership and clone ownership are independent; freeing a template
handle does not invalidate existing clones.

Cell layers retain their parent and store changed pages, including pages
changed to zero. Restore overlays disjoint private mappings of the latest
page runs over ancestor backing. Capture still compares the full RAM image:
O(RAM) comparison, O(changed pages) storage, depth at most 16. This is
implemented layering, without a userfaultfd page server or O(dirty-pages)
capture. The host naturally faults mapped pages on access; explicit remote
or userfaultfd-managed demand paging remains unimplemented.

Linux CoW capture first creates a complete QEMU migration, restores it into
a paused shared-RAM helper, captures devices separately, destroys the helper
and seals the RAM. Clones map RAM privately and restore only the device stream.
Capture costs O(RAM) and temporarily consumes another QEMU and migration image.
Linux checkpoints have no parent layers. Dirty Linux pool guests are destroyed
and replaced; there is no in-place Linux device/RAM reset.

Explicit cell shared regions intentionally map one bounded capability into
several cells. Immutable regions cannot be upgraded by guest mprotect; writable
regions require a per-session grant. Their writes survive private-cell reset.
Box shared regions, eventfd doorbells and cross-template KSM deduplication
remain extensions; the CoW box backend disables mergeable RAM and does not
rely on KSM to establish sharing.

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
- **Policy.** Filesystem access is absent by default. Explicit read-only or
  writable roots use confined host descriptors; private mode eagerly copies
  into a separately owned directory with lifetime quotas. Exact IPv4/TCP
  destination grants, fd/output/syscall budgets and a wall deadline are
  implemented. An optional single-thread instruction budget uses KVM stepping.
- **Seeded services.** `clock_gettime` and `getrandom` can use deterministic
  syscall services, with bounded transcript verification. CPU instructions
  such as RDTSC/RDRAND and wall deadlines remain outside that guarantee.
- **Faults.** A guest exception exits with the vector and `rip`; the
  host symbolizes it from the binary's DWARF (`code_generator/dwarf.w`
  already emits it) and reports it the way `lib/crash.w` does.
- **Timeouts.** A watchdog thread sets `kvm_run.immediate_exit` and
  signals the vCPU thread; `lib/signal.w`'s x64 thunks make the needed
  handler possible.

## 6. Tier 2: boxes (Linux guest)

Boxes run arbitrary guest binaries supplied in a Linux initramfs: shells,
Git, language runtimes and foreign compilers. The installed QEMU microvm
machine provides boot, vCPU/device state and KVM execution. W controls QEMU
through bounded QMP calls and private sockets; no shell migration command or
host tool fallback is used.

`wvm_init` is a static W PID 1. Persistent commands use virtio-serial, with
bounded argv/cwd, separate binary-safe stdout/stderr and status. Stdin is
`/dev/null`, replies arrive after command completion, and command descendants
are killed before replying. Streaming stdin/output and persistent background
services are not supported by this protocol.

Private workspaces are imported into bounded guest tmpfs before readiness,
so snapshots include edits and deletions without a live host filesystem
attachment. Explicit 9p exports and optional QEMU user networking remain
separate opt-ins and prevent snapshots. Daemon boxes deny networking.
Disk-image lifecycle/rollback, box shared regions, destination-allowlisted
egress and credential/network brokers remain unimplemented.

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
- `tools/wvmd.w` (serve/call), `tools/wvm.w` (available/run/box),
  `tools/wvm_debug.w` (scriptable guest debugging), and `tools/wvm_init.w`
  (box guest agent), each owning targets with `# wbuild:` directives.
- `lib/wvm_client.w`: the client side wharness and wexec import.

## 8. Control plane and agent integration

`wvmd` serves mode-0600 AF_UNIX JSON-RPC (`lib/json_rpc.w`). Clients connect
explicitly; automatic startup is not implemented. Each admitted session owns
a worker process. Cells share sealed ready-image backing; box templates share
sealed Linux RAM with separate device state.

| RPC | Implemented behavior |
|---|---|
| `template_create` | `{image}` loads a static x64 cell ELF and returns `template`; `{backend:"box",session}` submits CoW capture and returns a command number |
| `vm_spawn` | `{backend:"cell",template}` or `{backend:"box",template}` clones a template; a box may also cold-boot from `{kernel,initrd}` |
| `vm_exec` / `vm_result` | Submit a command, then poll its identity/status and bounded binary-safe output; cell commands restart the template program with the supplied argv |
| `vm_snapshot` / `vm_restore` | Capture/restore one worker-owned checkpoint of an idle box; these do not publish a cross-session template |
| `vm_destroy` / `vm_cancel` / `vm_renew` | Destroy a session or renew its bounded lease |
| `template_destroy` / `template_renew` / `templates` | Revoke new admissions, renew a handle, or enumerate bounded template metadata |
| `region_create` / `region_destroy` / `region_renew` | Create, revoke or renew an explicit shared-memory capability for cells |
| `stats` | Admission, template/shared-region reservations, command/failure and cleanup counters |

Box template capture completes through `vm_result`, whose successful result
contains `template`. Clones keep the backing after the source and template
handle are destroyed. This permits checkpoint/rollback and fan-out through
one API; source images must still be available at their original paths.

`wexec` manifest steps accept `"sandbox":"cell"`, an explicit daemon socket
and an optional shared template handle. They run without filesystem/network
capabilities and use seeded single-thread syscall services. CPU instructions
and wall-clock deadlines are not deterministic. Ordinary steps keep their
existing execution behavior. See [wexec](wexec.md#cell-sandbox-steps).

The external w-private harness routes all tool dispatch through persistent
box sessions when VM mode is selected. Its adapter and integration gates
ship separately. It checkpoints before each turn and exposes rollback and
bounded fan-out through model tools and REPL controls. Library box pools are
available, while a daemon pool RPC, region eventfd doorbells and automatic
startup remain later work. The cell worker reuses one RAM clone and recreates
vCPUs on each command.

## 9. Staged path

Each milestone lands green on its own.

| # | Milestone | Gate |
|---|---|---|
| M0 | **Implemented:** syscall primitives `mmap_fd`, `memfd_create`, `madvise`, seals | `tests/memfd_test.w` (x86/x64): shared initialization, seal enforcement, isolated private clones, byte offsets, errors, partial/full reset, fd/mapping lifetime |
| M1 | **Implemented:** `lib/kvm.w` and a guest that writes to a port | `tests/kvm_hello_test.w`: ABI layouts, real port write and halt (execution skips with no `/dev/kvm`) |
| M2 | **Implemented:** ELF loader, ring-3 long mode, LSTAR gate, syscall subset; `wvm run tests/hello.w` | `tests/wvm_test.w`: existing x64 map/set, compound-assignment and float64 suites; TLS, syscall boundary, faults, timeout, malformed ELF |
| M3 | **Implemented for ready cells:** CoW clones, RAM reset and optional retained-vCPU pools | `wvm_snapshot_test`; `wvm_pool_bench` reports timings and memory, no universal latency claim |
| M4 | Private filesystem copies with lifetime quotas, seeded clock/random and syscall transcript verification, symbolized faults | `wvm_policy_test`, `wvm_cli_test`, `wvm_fault_test`; determinism is explicitly limited to supported syscall services |
| M5 | **Implemented with documented limits:** cell/box scheduler, cgroup quotas, template and cell shared-region registries, wexec client and companion harness checkpoints | `wvmd_test`, `wvmd_cell_test`, `wvmd_box_test`, `wexec_cell_test`, `wvm_cgroup_test`; separate wharness real-guest gate |
| M6 | `--syscall-abi=vmcall` compiler ABI using KVM's CPL3 Xen interception | `wvm_vmcall_test`, `verify_x64`; `wvm_syscall_bench` measures both ABIs on the deployment host |
| M7 | Persistent QEMU/KVM sessions, imported private workspaces, CoW RAM/device snapshots, daemon templates, bounded ready pools and pinned image builder | `wvm_box_test`, `wvmd_box_test`, `wvm_qmp_test`, `wvm_channel_test`, `wvm_image_test` |
| M8 | **Partial:** threads, guest debugger, paused live checkpoints and bounded cell layers implemented; existing-session debugger attach, userfaultfd demand paging and other host ports deferred | `wvm_thread_test`, `wvm_live_test`, `wvm_snapshot_test`, `wvm_debug_script_test`; unsupported ports have no execution gate |

Linux x64 with real KVM is the execution platform. A ptrace/PTRACE_SYSEMU
cell backend and a macOS Hypervisor.framework backend are not implemented;
there is no fallback to either. Existing host-process ptrace debugging is a
different facility and does not provide a VM execution backend.

### Required VM validation

[`.github/workflows/vm.yml`](../../.github/workflows/vm.yml) runs on pushes to
main and pull requests. It requires KVM, installs QEMU/build dependencies,
verifies the pinned Linux 6.12.1 source digest, builds the guest kernel and
delegates cgroup-v2 CPU/memory/pids controllers. [`tools/wvm_ci.sh`](../../tools/wvm_ci.sh)
selects every `wvm*_test` plus memfd/KVM gates from the generated manifest,
disables cached results, sets `W_CI_NO_SKIP=1` and rejects any SKIP output.
Missing prerequisites fail this workflow. Whether GitHub branch protection
requires its check is repository configuration outside the workflow file.

Run the same gate against prepared local fixtures:

```sh
WVM_TEST_KERNEL=/images/bzImage WVM_TEST_CGROUP=/sys/fs/cgroup/delegated \
  bash tools/wvm_ci.sh
```

Ordinary `./wbuild tests` still permits optional host-facility skips. Such a
pass proves neither real KVM execution nor host quota enforcement; use the
required gate and its uploaded log/kernel digest for that evidence. The
external harness roundtrip is a separate companion-repository test.

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
exception vector and guest RIP on stderr. Original-ELF symbols and source locations supplement supported fault reports.
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
`lib.vmm.cell` execution APIs must be serialized in a single-threaded
host process: it temporarily owns SIGALRM, restores the previous handler
and signal mask, and refuses an already active/pending real-time alarm.
`cell_free` releases every vCPU, VM, run mapping, guest RAM, buffer,
filesystem descriptor, and socket.

Ready snapshots/reset, bounded layers, paused live snapshots,
seeded services and optional instruction budgets are available under the
restrictions below. The threat model in §2 still applies.

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
channel rather than vsock. RAM/device snapshots are described below;
disk-image management remains open.

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
for the CLI. With `--exec`, a bounded archive imports the copy into a private
guest tmpfs at `/work`, then removes the import staging directory before
readiness. There is no persistent host filesystem device. The tmpfs defaults
to 64 MiB; `--workspace-mb 1..1024` caps **all imported files plus edits**.
This differs from the earlier overlay-upper-only limit. The guest kernel
needs tmpfs and virtio-console; private workspaces no longer require 9p or
overlayfs. Requested import/mount failures prevent readiness.
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
adds real Linux command, workspace/snapshot and concurrent-daemon tests.
The minimal Alpine kernel supports the complete imported-workspace path.
Explicit shared 9p exports still need the corresponding guest drivers.
Build a compatible kernel from a supplied Linux source tree:

```sh
./tools/wvm_kernel.sh /sources/linux /build/wvm-kernel 16
WVM_TEST_KERNEL=/build/wvm-kernel/arch/x86/boot/bzImage \
  ./wbuild wvm_box_test wvmd_box_test
```

The script merges `tools/wvm_kernel.config` over `x86_64_defconfig`, rejects
missing built-ins after dependency resolution, and records kernel/config
SHA256 values. It requires the normal Linux build dependencies (C toolchain,
make, flex, bison, bc and libelf headers); it does no downloads or installs.
Pin the source and resulting kernel in deployment configuration. Validation
used Linux 6.12.1 (source tar.xz SHA256
`0193b1d86dd372ec891bae799f6da20deef16fc199f30080a4ea9de8cef0c619`):
private edits, unchanged host lower files, persistent edits and tmpfs ENOSPC
all passed in real KVM boots.

### Live Linux snapshots

`box_snapshot_create(session, timeout_ms)` pauses an idle Linux command
session, captures RAM and device/vCPU state into a sealed memfd, then resumes
the source. `box_snapshot_restore(snapshot, timeout_ms)` creates an independent
session without rebooting Linux. `box_snapshot_free` releases the template;
restored sessions remain valid. Calls must be serialized with command execution.
Each restore opens an independent migration-stream file description.

The backend uses QMP `stop`, `getfd`, `migrate`/`migrate-incoming` and `cont`.
SCM_RIGHTS transfers descriptors; there are no shell migration commands or
writable snapshot paths. Control reads, events and migration waits are bounded.
Uncertain capture failures destroy the source session. Failed restores destroy
only the new VM. Successful captures survive source-session destruction.

Snapshots require the same host CPU/QEMU version and unchanged kernel/initrd
artifacts. Imported private workspaces live in tmpfs and are included, so
edits and deletions roll back with the guest. Explicit shared 9p exports and
network devices are rejected. Ordinary `box_snapshot_create` restores still
materialize RAM through migration.

`box_snapshot_create_cow(session, timeout_ms)` instead produces sealed RAM
and a separate device-state stream. Capture materializes a conventional
snapshot into a shared-memfd helper that never resumes, saves device-only
state using QEMU's `x-ignore-shared` migration capability, destroys the helper,
and seals RAM. Restores use QEMU's read-only, private file-backed RAM mapping;
clean pages are physically shared and writes are private. Unsupported QEMU
features or failed sealing fail explicitly, with no copy fallback. Capturing
a dirty clone is supported; capture still costs O(RAM) and one temporary QEMU.
This does not provide disk-image rollback, cross-host portability or a
sub-millisecond Linux boot. See [QEMU VM templating](https://www.qemu.org/docs/master/system/vm-templating.html).

A paused materialization helper never applies the imported clock to its KVM
runtime. Its second migration must therefore omit QEMU's reliable-clock
subsection (`kvmclock.x-mach-use-reliable-get-clock=off` on that helper), so
a clone derives time from the captured pvclock RAM and vCPU TSC. Otherwise
helper uptime can replace guest time, stalling timers after old or repeated
checkpoints. Delayed dirty-clone recapture tests cover this regression. The
path was validated with QEMU 8.2.2; it depends on QEMU's
[kvmclock migration implementation](https://github.com/qemu/qemu/blob/v8.2.2/hw/i386/kvm/clock.c),
so snapshot compatibility remains tied to the host CPU/QEMU version.

The daemon owns one replaceable snapshot per session. `vm_snapshot` captures
it; `vm_restore` rolls the session back to it. Both require a ready session,
return a command number, and complete through `vm_result` like `vm_exec`.
Per-session rollback storage disappears with its worker/session. The separate
daemon `template_create` operation exports immutable CoW backing into a bounded
registry for independent `vm_spawn` clones; those templates outlive the source
session. See the control-plane usage below.

`lib.vmm.box_pool` provides `box_pool_new`, `box_pool_acquire`,
`box_pool_release`, `box_pool_refill` and `box_pool_free`. It owns a bounded
set of 1–64 ready clones and independent snapshot descriptors. The input must
be a CoW snapshot; its original owner may free it after pool creation. Acquisition never
boots or expands the pool; exhaustion returns null. Release consumes the
lease, destroys its dirty guest and explicitly restores a replacement. Refill
cost is distinct from acquisition latency, and failure leaves a vacancy.
Pool destruction also destroys outstanding leases. Callers must serialize
operations and must not separately free a pool-owned session. The daemon
currently uses restore-on-demand templates rather than this library pool.

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

The same daemon accepts ready cell templates and live box templates:

```sh
./bin/wvmd call bin/wvmd.sock template_create '{"image":"/absolute/path/program-x64"}'
./bin/wvmd call bin/wvmd.sock vm_spawn '{"backend":"cell","template":1,"seed":0}'
# Use the session returned by vm_spawn, once ready:
./bin/wvmd call bin/wvmd.sock vm_exec '{"session":2,"argv":["/program","arg"],"stdin":"input","timeout_ms":1000}'
# For an existing ready box session:
./bin/wvmd call bin/wvmd.sock template_create '{"backend":"box","session":3}'
# Poll vm_result for session 3 and the returned command number; its final
# result contains the template handle used in the next request.
./bin/wvmd call bin/wvmd.sock vm_spawn '{"backend":"box","template":2}'
./bin/wvmd call bin/wvmd.sock template_destroy '{"template":2}'
```

Handles above are illustrative; use the IDs returned by the daemon. Cell
creation accepts a regular static ELF up to 64 MiB, with no host compilation.
Each cell session reserves 256 MiB and one scheduled CPU. `vm_exec` runs the
same loaded program with new argv and a pristine private image each time;
argv[0] does not select another executable. Cwd is absent or `/`, stdin is a
bounded text string, and filesystem/network capabilities are denied. An
optional `seed` selects deterministic syscall services and one guest thread;
shared regions cannot be combined with that mode.

Box templates capture a ready session, including an imported private `/work`,
using `box_snapshot_create_cow`. They transfer sealed RAM/device descriptors
to the daemon without copying their backing. Clones inherit CPU/RAM sizes
and cannot add exports or network devices. Capture temporarily needs an extra
QEMU and materialized migration memory; insufficient host quota fails the
capture. This is a materialized checkpoint, not an O(dirty-pages) layered
snapshot. Source destruction and template revocation do not invalidate
already admitted clones.

The registry holds at most 16 templates. Each reserves its full guest RAM
size from `--memory-mb`, in addition to active-session reservations. Cell
handles default to 60-second leases; box handles to one hour after successful
capture. `lease_ms` accepts 100..3600000 and `template_renew` extends a live
handle. Expiry/destruction stops new admissions; queued/running references
keep the backing until session teardown. `templates` reports handles,
source-session IDs, availability, references and remaining leases, allowing
cleanup after an uncertain capture response. Handles are not persisted across
daemon restart.

Explicit shared regions use a separate bounded registry:

```sh
./bin/wvmd call bin/wvmd.sock region_create '{"length":4096,"writable":1,"data":"hello"}'
./bin/wvmd call bin/wvmd.sock vm_spawn '{"backend":"cell","template":1,"region":1,"region_write":1}'
./bin/wvmd call bin/wvmd.sock region_destroy '{"region":1}'
```

One region can be mapped per cell at guest address 251658240 (240 MiB).
Lengths must be page-aligned and 4 KiB..8 MiB; the registry allows 64 handles
and 64 MiB total backing. Default regions are immutable; writable regions
require an explicit write grant per session. Guest mprotect cannot upgrade
region permissions. Initial `data` is bounded text; guest writes can contain
arbitrary bytes. Region leases default to one hour and support `region_renew`.
Existing sessions retain revoked/expired backing. Reset revokes and remaps
each command's binding while preserving deliberate shared writes. Direct
library bindings reject retained-vCPU and deterministic cells. There is no
box-region mapping or eventfd notification API yet.

The daemon owns a private `<socket>.state` directory and holds an exclusive
lock. Before releasing a new worker, it durably records its process group
and workspace identity. On restart it waits for old groups to disappear
without signaling recycled PIDs, then reclaims only owned workspaces and
channel directories. Unexpected ownership, malformed records or surviving
groups fail closed. This recovers abandoned storage; it does not resume
commands or reconstruct running agent sessions. Keep this state directory
with the socket between restarts.

`lib.wvm_client` provides synchronous `wvm_client_open`,
`wvm_client_exec_wait`, `wvm_client_exec_wait_input`, `wvm_client_cell_run`
and `wvm_client_destroy` helpers as well as the raw RPC
interface. The command helper polls command identities, decodes bounded
binary-safe output chunks, and destroys uncertain sessions on transport or
deadline failure. There is no automatic daemon launch or local execution
fallback.

The external `w-private/wharness` companion accepts `--vm-socket`,
`--vm-kernel`, `--vm-initrd` and optional `--vm-harness` (default
`/usr/bin/wharness`). It opens a private-workspace session before the first
turn, renews its lease on guest tool calls and saves a CoW checkpoint before
each turn. Checkpoint failure stops the turn before any tool executes.
Ordinary tools run in the matching guest harness at `/work`; VM control tools
use the host daemon client. The supplied image must contain that harness and
its tool/runtime dependencies. Prompts and model API traffic remain host-side;
credentials are not forwarded and VM errors never authorize host tools.

`vm_checkpoint`, `vm_rollback`, `vm_fork`, `vm_select` and `vm_discard` are
model tools and REPL controls (`:vm checkpoint`, `:vm rollback`, `:vm fork N`,
`:vm select ID`, `:vm discard ID`). Fork creates at most eight inactive owned
branches; partial admission destroys the clones already created. Rollback
creates a replacement before retiring the active guest, requiring a spare
fleet slot. Selecting a branch retains the previous active guest. Failed
turns keep changes for explicit inspection/rollback; conversation history is
not rolled back. Re-read files after changing workspaces. Orderly close
retires owned sessions/checkpoints; source-session reconciliation and daemon
leases bound uncertain replies and client crashes.

The companion changes ship separately, with no gitlink updated here. Run its
real guest test against this W checkout and a supplied local kernel:

```sh
# From the companion repository:
python3 wharness/tests/vm_test.py --w-repo /path/to/w --kernel /images/bzImage
```

It builds a matching static x86 harness and temporary image, uses real KVM
Linux tools for two turn checkpoints/rollback/independent branches, verifies
host isolation and checks resource counters return to baseline. Only model
responses are fixtures. The kernel needs IA32 emulation for that static test
harness; no credentials or model API are involved.

Host quotas are opt-in and independent of guest admission reservations:

```sh
./bin/wvmd serve --socket bin/wvmd.sock \
  --cgroup /sys/fs/cgroup/my-delegated-parent \
  --host-cpu-percent 400 --host-memory-mb 4096 --host-pids 512
```

The caller must delegate a cgroup-v2 parent with `cpu`, `memory` and `pids`
enabled in `cgroup.subtree_control`. The daemon creates an exclusive
`wvmd-<pid>` leaf, configures `cpu.max` (100000 µs period), `memory.max`,
`memory.swap.max=0` and `pids.max`, and moves each gated worker into it
**before** releasing the worker. QEMU and worker-created snapshot memory are
charged to that leaf. Cell template/region creation also runs in a bounded
helper attached to the leaf before allocating backing, then transfers sealed
fds with SCM_RIGHTS; backing remains charged after the helper exits. Quota
attachment failure never falls back to allocation in the daemon. The daemon
remains outside to handle OOM/failure cleanup.
CPU percentages allow multiple cores (400 means four cores); memory includes
worker/QEMU overhead and snapshot pages, not just guest RAM. Defaults with
`--cgroup` are 800%, 4096 MiB and 512 tasks. Host-limit flags without a cgroup,
missing controllers, or failed quota writes/attachment fail closed. `stats`
reports `host_quotas`. With no cgroup option only admission limits apply.

Normal shutdown removes the empty leaf. After a daemon crash its empty quota
leaf may need removal by the delegating supervisor; durable session recovery
still reclaims workers and workspaces. These are aggregate limits, not
per-tenant guarantees, CPU-time budgets or network-rate limits. Automatic daemon
startup, running-session recovery, multi-host scheduling and a daemon warm-pool
RPC remain future work; standalone Linux ready pools are implemented.

`WVM_TEST_CGROUP=<delegated-parent> ./wbuild wvm_cgroup_test wvmd_cell_test`
verifies real process-limit rejection, OOM enforcement and retained memfd
charges without moving the test process into the bounded leaf. `wvmd_cell_test`
also exercises real cell workers, private reset, shared-region permissions,
handle leases and cleanup; `wexec_cell_test` covers the executor/client path
and absence of host fallback. `wvmd_box_test` with `WVM_TEST_KERNEL` exercises
CoW template export, independent workspace clones and source/handle teardown.

A real fleet benchmark uses that same daemon API:

```sh
python3 tools/wvm_fleet_bench.py --socket bin/wvmd.sock \
  --kernel /images/bzImage --initrd /images/agent.cpio --count 16 -- /bin/true
```

The default mode submits concurrent sessions and reports launch latency
including queueing, command latency including polling, throughput, failures
and daemon counters before/after cleanup. Size the active/pending limits for
the requested count; admission rejection is a failure. Comparison mode
requires an idle daemon with no templates/regions and a wave width that fits
its capacity:

```sh
python3 tools/wvm_fleet_bench.py --socket bin/wvmd.sock \
  --kernel /images/bzImage --initrd /images/agent.cpio \
  --compare --count 8 --width 4 --timeout 180 -- /bin/true
./wbuild wvm_box_pool_bench
./bin/wvm_box_pool_bench /images/bzImage /images/agent.cpio 30 4 /bin/true
```

Comparison runs cold waves, independent CoW clone waves and repeated commands
in a persistent CoW fleet. It reports whole-QEMU RSS/PSS/shared/private memory
and the separate named CoW RAM mappings. `mincore` measures complete sealed
template residency without faulting pages in. The inclusive memory estimate
replaces mapped RAM PSS with complete template residency plus private
anonymous CoW pages; it excludes host kernel/KVM overhead. Summed shared
counts double-count shared pages, and template residency overlaps mapped PSS:
neither may simply be added to process PSS.

A local Linux 6.12.1/QEMU 8.2.2 run used four 256 MiB guests per wave, eight
cold and eight CoW waves, plus persistent reuse (69 sessions, 97 commands).
The median of wave readiness medians was 2653 ms cold and 52 ms CoW; template
capture took 869 ms. Last-wave QEMU PSS was 562649 KiB cold and 158393 KiB CoW,
but the CoW template itself retained 262144 KiB. Including that backing and
4000 KiB private anonymous CoW pages gave estimates of 562649 versus 405459 KiB.
This is the comparison to use for total savings, not the QEMU-only PSS ratio.
Active/queued, CPU/RAM/template/workspace/shared-region reservations and
cleanup-failure counters returned to their starting values. This benchmark
used admission reservations without delegated host cgroup enforcement.

The standalone pool benchmark reports ready acquisition, command execution,
and destruction/refill separately. Thirty local cycles at capacity four
measured medians of 627 ns acquisition, 14.8 ms command execution and 75.3 ms
replacement, with zero failures and descriptor counts 4 → 4. The workload was
the W fixture's capability check in a minimal image; these are host/workload
measurements, not arbitrary agent-tool or sub-millisecond Linux startup
guarantees. Real pool tests separately cover dirty workspace isolation,
exhaustion, missing-artifact refill failure/recovery and outstanding-lease
cleanup. Python benchmark tooling uses only the standard library.

### Cell templates, RAM pools and measurement

`cell_snapshot_create(cell)` captures a loaded, stacked, never-run cell with
pristine I/O and no external resources. Capture scans RAM once, writes
nonzero pages into a sparse memfd, and seals it. Clones use `MAP_PRIVATE` and
retain backing independently of the template owner's lifetime. Input is
owned per clone. Configure filesystem/network capabilities separately after
cloning. `cell_snapshot_reset` drops private pages and clears all per-run
resources, descriptors, output, fault and watchdog state. Ordinary clones
recreate KVM VM/vCPUs on the next run. It does not capture a running process or roll back
external filesystem writes.

`cell_pool_new(snapshot, capacity)`, `cell_pool_acquire` and
`cell_pool_release` provide bounded RAM-ready leases. A pool owns its cells;
release them to the pool instead of freeing them. Exhaustion returns null.
The API remains serialized within a host process, including snapshot
reference counts. `cell_pool_new_retained(snapshot, capacity)` eagerly creates
main vCPUs and retains all subsequently created thread vCPUs. Release completes
pending I/O exits, restores registers, segments, XSAVE/XCRS, events/debug/MP
state and syscall gates, revokes host capabilities, and drops private RAM.
CPUID stays fixed for the lifetime of each vCPU. There is no silent cold
fallback if preparation/reset fails. These APIs serve cells; `lib.vmm.box_pool`
provides the separate Linux ready-pool lifecycle described above.

```sh
./wbuild wvm_snapshot_test wvm_pool_bench
./bin/wvm_pool_bench bin/wvm_fixture 100 100 smoke payload
WVM_RETAIN_CPUS=1 ./bin/wvm_pool_bench bin/wvm_fixture 100 4 smoke payload
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
17.38/23.38 ms for the original cold-reset path. A later 100-run comparison
with capacity four measured retained reset p50/p95 at 35.8/39.7 µs versus
18.25/24.03 ms for cold reset; both had zero failures and descriptor counts
4 → 4 after cleanup. These are local serialized measurements, not fleet
latency guarantees.

### Paused cell checkpoints, layers and guest debugging

`cell.pause_after` requests a pause after an absolute syscall-count boundary;
`cell_resume(cell, timeout_ms)` continues with a new wall deadline while
preserving cumulative counters. `cell_live_capture`, `cell_live_restore` and
`cell_live_free` capture paused guest execution and restore an independent
paused clone. The snapshot preserves allocated vCPU state, exact CPUID and
supported gate/TLS MSRs, scheduler/thread state, relative futex deadlines,
input position, output and seeded/transcript service state. Runnable and
futex-wait threads are supported; external I/O waits, filesystem/network/shared
region capabilities, retained pools and active debugger controls are rejected.
Host CPU clock timing is not replayed. Ready-image reset is rejected for live
restores: restore the live snapshot again to roll back.

`cell_snapshot_create_layer(cell, parent)` and
`cell_live_capture_layer(cell, parent_live)` retain bounded parent chains with
changed-page storage. Capture scans RAM even when few pages changed. Restore
maps ancestor backing and overlays changed page runs privately, including
explicit zero changes. Depth is at most 16. These APIs provide real immutable
layers and independent lifetime ownership, without a userfaultfd service or
remote/disk demand-page loader. Linux box snapshots do not use these layers.

```sh
./wbuild wdbg
./bin/wv2 x64 tests/wvm_live_fixture.w -o bin/live_guest
printf 'regs\nstep\ncontinue\nquit\n' | ./bin/wdbg vm bin/live_guest
```

`wdbg vm` launches a fresh KVM cell paused before entry through `wvm_debug`;
it does not attach an existing daemon cell, Linux box or host process. The
scriptable commands are `status`, `regs`, `step`, `continue`, `break
SYMBOL_OR_ADDRESS`, `delete SLOT`, `threads`, `thread TID`, `read ADDRESS
LENGTH`, `write ADDRESS HEX`, and `quit`. Four hardware execution breakpoints
apply to guest threads. Address aliases include `$entry`, `$stack`, `$heap`,
`$rip` and `$rsp`; reads/writes respect guest permissions and are bounded to
1024 bytes. A blocked thread can be inspected but cannot single-step. Output
streams are hex encoded and fault locations use the original ELF metadata.
Source-level stepping, watchpoints and expression evaluation are not provided.
See [guest debugger commands](debugger_attach.md) for the frontend contract;
`wvm_live_test` and `wvm_debug_script_test` exercise the KVM library/frontend.
Local execution passed all eight live-checkpoint/debug/budget tests and all
four frontend tests without skips, including multithread layered clones,
source/template destruction, TLS/XMM/heap/stack restoration and futex expiry.

### Private cell filesystems, syscall replay and fault reports

```sh
./bin/wvm run --fs-root ./project --fs-private bin/my_guest
./bin/wvm run --seed 42 --record bin/run.transcript bin/my_guest
./bin/wvm run --seed 42 --replay bin/run.transcript bin/my_guest
```

`--fs-private` creates a confined eager private copy (64 MiB, 10000 entries,
60-second preparation deadline). All guest changes target that copy; cleanup
removes it after execution. This is an independently owned host directory,
not a lazy in-memory overlay. The library's `cell_fs_configure_private` lets
callers choose bounded limits. Initial contents, file growth and created
entries consume lifetime quotas; deletion/shrinking does not refund them,
including open-unlinked files. The original explicit `--fs-write` continues
to mutate the supplied directory; the two modes are mutually exclusive.

`--seed 0..2147483646` enables single-threaded, capability-free deterministic
clock/random syscall services. Randomness in this mode is reproducible and
not cryptographic. Record/replay verifies the syscall arguments, results and
I/O bytes in a bounded 4 MiB binary transcript. A mismatch, truncation, surplus
record or overflow fails the run. Recording creates a new mode-0600 file and
never overwrites an existing transcript. Image, argv/input and seed must
match; the format is local/version-specific. CPU instructions such as RDTSC
and RDRAND and wall-clock deadlines are not virtualized, so this is syscall
replay verification, not arbitrary-program determinism.

`--max-syscalls 1..1000000000` limits guest syscall dispatches (default one
million), independently of the wall deadline. It does not count instructions.
`--max-instructions 0..1000000000` adds an optional single-thread budget;
0 disables it. It counts KVM single-step exits, including supervisor syscall
trampoline instructions, rather than a hardware retired-instruction counter.
This mode is expensive and fails explicitly when stepping is unavailable or
the budget is exhausted (status 125). It cannot be combined with multiple
guest threads. Ordinary execution retains only the syscall and wall budgets.
Snapshots preserve the seed and budget and reset per-run state. Filesystem,
network and shared-memory capabilities are incompatible with deterministic
services and are rejected, not silently ignored.

Fault output retains the exception vector and raw RIP and adds a containing
function and source file/line when the original ELF has valid symbols and
W DWARF2 data. Metadata is bounded and parsed from the original file bytes,
not guest-mutated memory; stripped/unsupported metadata leaves the raw report.

### Optional vmcall syscall ABI

```sh
./bin/wv2 x64 --syscall-abi=vmcall tests/wvm_fixture.w -o bin/guest
./bin/wvm run bin/guest smoke payload
./wbuild wvm_syscall_bench
./bin/wvm_syscall_bench
```

The flag changes all compiler-generated Linux runtime calls, including exit,
TLS, stack allocation and thread creation. The ELF `e_flags` marker
`0x57564d01` identifies W VM syscall ABI version 1. Native Linux `syscall`
remains the default; `--syscall-abi=linux` selects it explicitly. vmcall images
require the cell runtime and cannot run as ordinary host executables. PIE,
dynamic imports and non-x64-Linux targets are rejected.

The VMM enables `KVM_XEN_HVM_CONFIG_INTERCEPT_HCALL` and validates CPL3
`KVM_EXIT_XEN` exits. This uses the Linux x64 argument registers and preserves
the existing buffer checks and guest permissions. It does not run guest code
in ring 0 or require a modified host kernel. Ordinary KVM hypercalls reject
CPL3; this distinct interception mechanism is required. Unsupported hosts
fail explicitly. See the [KVM API](https://www.kernel.org/doc/html/v6.12/virt/kvm/api.html#kvm-xen-hvm-config).
The benchmark alternates five 100000-call runs of each ABI, includes CPU setup,
and reports mean nanoseconds per gettid; it imposes no machine-independent
speed threshold.

## 10. Open decisions

1. **Execution platforms.** The required Linux KVM CI workflow is implemented.
   A ptrace cell backend, macOS Hypervisor.framework port and other host ports
   remain unimplemented; unavailable execution facilities never trigger a host
   process fallback.
2. **Tier 2 build vs adopt.** The initial implementation adopts QEMU
   microvm with KVM. A W-native runtime or Firecracker backend can replace
   it behind a future `wvmd` API if measured deployment needs justify it.
3. **Repo split.** VMM core, cells, `wvmd` and the compiler flag in
   `w`; the wharness integration in `w-private`.
4. **Deferred extensions.** Existing-session/box debugger attach, streaming
   stdin/output, disk-image rollback, a credential/network broker, box shared
   regions/doorbells, daemon-managed ready pools and userfaultfd demand paging
   remain separate work. Cell page layers do not supply demand paging or
   O(dirty-pages) capture; Linux checkpoints remain fully materialized.

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
