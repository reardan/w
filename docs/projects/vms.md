# Agent VMs: instant microVMs with shared memory (`wvm`)

Status: design 2026-10-04. Nothing below is implemented yet.

Goal: let agents (wharness, wexec steps, anything driving the toolchain)
run work inside virtual machines that start and stop in well under a
millisecond, and that share RAM pages with each other instead of each
paying for its own copy of the same image.

## 0. Summary

There is no VM or sandbox support in either repo today. Agent tool
calls (`bash`, `w_run`, `w_test` in w-private's `wharness/wharness_tools.w`)
run as plain host processes through `lib/process.w`'s `process_run`,
gated only by `--ask` / `--no-bash`.

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

## 1. What exists today

| Area | State | Where |
|---|---|---|
| Agent execution | Unconfined host processes; no isolation beyond a permission prompt | w-private `wharness/wharness_tools.w` (`wh_run_shell`, `wh_tool_bash`) |
| Process control | fork/execve/wait4, pipes, poll-driven timeouts, `process_wait_any` | `lib/process.w`, `docs/projects/process.md` |
| Raw syscalls | Generic `syscall` / `syscall7`, `sys_ioctl`, clone, ptrace, mmap, eventfd, epoll, AF_UNIX | `lib/syscalls_linux_x86.w`, `lib/__arch__/*/syscalls.w` |
| File-backed mmap | **Missing.** `mmap(addr, len, prot, flags)` hardwires `fd = -1, offset = 0` | `lib/syscalls_linux_x86.w:162` |
| memfd, seals, madvise, userfaultfd | **Missing** (no wrappers, no syscall numbers) | |
| KVM | **Missing** entirely | |
| Signal handlers on x64 | Working, including the SA_RESTORER thunk (needed to kick a vCPU out of `KVM_RUN`) | `lib/signal.w` |
| Where `syscall` instructions come from | Runtime stubs the compiler emits: `syscall`, `syscall7`, `thread_create` (clone), `stack_create` (mmap), `__w_tls_set` (arch_prctl), plus the ELF exit stub | `code_generator/x64_asm.w:68-118`, `code_generator/elf_64.w:49` |
| Daemon pattern | AF_UNIX server with client auto-start | `tools/wbuildd.w`, `docs/projects/wbuildd.md`, `lib/json_rpc.w` |
| In-memory FS | Volatile/durable model behind the `file_ops` table, crash simulation | `lib/fake_fs.w`, `lib/file_ops.w` |
| Software sandbox | wasm32/WASI backend, run under wasmtime/node | `docs/projects/wasm_backend.md` |
| Out-of-process debugging | ptrace attach, core files | `docs/projects/debugger_attach.md`, `lib/core_file.w` |

Hosts: the Claude cloud container this doc was written in has no
`/dev/kvm` and no `vmx` CPU flag (nested virtualization off), so KVM
tests cannot run there. Whether ssh host `w` exposes `/dev/kvm` is
unchecked and decides where the KVM gates run (§10).

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
   seal the memfd with `F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW`. A
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
  sets `EFER.SCE` and points `LSTAR` at a three-instruction ring-0
  trampoline that does `out` to a syscall port (a VM exit carrying the
  registers) and `sysretq`. Any existing x64 W binary runs as is.
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
| M0 | Syscall primitives: `mmap_fd`, `memfd_create`, `madvise`, seals | `tests/memfd_test.w`: a `MAP_PRIVATE` clone sees the parent's bytes, its writes stay private, `MADV_DONTNEED` resets it |
| M1 | `lib/kvm.w` and a guest that writes to a port | `tests/kvm_hello_test.w` (skips cleanly with no `/dev/kvm`) |
| M2 | Cells: ELF loader, long-mode setup, LSTAR trampoline, syscall subset; `wvm run tests/hello.w` | Selected existing x64 tests pass inside a cell |
| M3 | Snapshots, clones, reset in place | Latency gate (spawn < 1 ms) and sharing gate (100 clones of a 64 MB snapshot add only their dirty pages to RSS) |
| M4 | Policy, overlay fs, deterministic clock/random, symbolized faults | Policy-denial tests; replay test |
| M5 | `wvmd`, warm pools, shared regions; wharness `--sandbox=cell` | wharness mock-mode run inside cells |
| M6 | `--syscall-abi=vmcall` in the compiler | `verify_x64`; measured syscall round-trip win |
| M7 | Boxes (or the Firecracker backend, §10); `wvm_init`; `--sandbox=box` | bash + git inside a box from a snapshot |
| M8 | Threads as vCPUs, wdbg attach to cells, userfaultfd layered snapshots, arm64 KVM and macOS Hypervisor.framework ports | per-port gates |

A ptrace backend (`PTRACE_SYSEMU`) for the cell syscall handler is
worth adding alongside M2: the same policy code runs on hosts without
KVM (including the Claude cloud container), slower but testable
everywhere, with `fork` from a zygote giving the same page sharing.

## 10. Open decisions

1. **Where KVM runs.** The cloud container has no `/dev/kvm`. If host
   `w` has it, the KVM gates run there; otherwise a GitHub runner with
   KVM enabled, or the ptrace backend carries CI.
2. **Tier 2 build vs adopt.** Recommended: build Tier 1 natively (it is
   small and plays to W's strengths), and start Tier 2 as a Firecracker
   backend behind the same `wvmd` API, replacing it with a W-native box
   runtime later if it earns its keep.
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
