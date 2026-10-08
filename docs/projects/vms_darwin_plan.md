# macOS Apple Silicon VM backend implementation plan

Status: initial D0–D7 implementation delivered, 2026-10-07. Tracks
[#591](https://github.com/reardan/w/issues/591). The original plan follows;
[usage and limits](vms_darwin.md) describe the shipped scope and
[native validation](vms_darwin_validation.md) records evidence and remaining
Linux validation limits. Darwin runtime support is implemented; Linux
completion PR #593 integration remains subject to its eventual merge.
The existing architecture and Linux behavior are described in [vms.md](vms.md).

## Baseline and scope

Source baseline: `c310878c3b24eb3a08e33a0b6fc453940e64b66b`.
The Linux completion [PR #593](https://github.com/reardan/w/pull/593) is still
open at writing. Reconcile its daemon, template and debugger interfaces before
implementing the integration stages below; do not duplicate those interfaces.
Its Linux work is not evidence of a Darwin implementation.

Current coupling that must be removed or adapted:

| Surface | Current implementation | Darwin work |
|---|---|---|
| Host VM | `lib/kvm.w`, `lib/__arch__/arm64_darwin/kvm.w` | Darwin stub returns `-38`; add a separate Hypervisor.framework adapter |
| Cell state and memory | `lib/vmm/memory.w`, `x64.w`, `cell.w` | Separate portable policy from KVM records, x64 page tables and Linux signal watchdog |
| Image loading | `lib/vmm/elf.w` | Validate static AArch64 ELF and initialize ARM64 user state |
| Syscalls | `lib/vmm/syscalls.w`, `threads.w`, `filesystem.w`, `network.w` | Decode ARM64 guest ABI and use explicit Darwin host services |
| Templates and pools | `lib/vmm/snapshot.w`, `pool.w` | Replace memfd/seals/reset assumptions with a tested Darwin backing contract |
| Control plane | `tools/wvm.w`, `tools/wvmd.w`, `lib/wvm_client.w`, `lib/vmm/control.w` | Select capabilities and manage one worker process per VM |
| Build | `build.base.json`, source `# wbuild:` directives | Native host compiler, worker signing and mandatory native execution path |

Initial deliverable: one-vCPU ARM64 cells, bounded stdin/stdout/stderr,
checked basic syscalls, deadlines/cancellation, immutable ready templates,
private clones, reset, and daemon/client lifecycle integration. The runtime
implementation stays in W using framework imports; a C SDK probe may verify
FFI layouts during development but is not the shipping runtime.

Linux KVM cells/boxes retain their existing behavior. Darwin initially rejects
Linux boxes, x64 images, Mach-O guests, guest threads, explicit shared regions,
live/layered checkpoints, filesystem/network grants and debugger operations
that have not passed native tests. These limitations must be queryable and
documented, not silently ignored. Porting these features is follow-up work;
the #591 checklist permits explicit rejection of unsupported checkpoint state.

## Native evidence already collected

On 2026-10-07, on a MacBook Pro `Mac15,6`, Apple M3 Pro (12 cores, 18 GiB),
macOS 26.3 (`25D125`), `kern.hv_support=1`:

- The SHA256-verified v0.3.0 Darwin seed compiled current sources to a native
  `wv2 -> wv3 -> wv4` chain; `wv3` and `wv4` were byte-identical. The six
  `arm64_darwin_smoke_test` programs ran 119 tests, with no failures or skips;
  native dynamic linking passed too.
- A separate C Hypervisor.framework probe executed `mov x0,#87; hvc #0`.
  Writable-memory control, read-only store, non-executable fetch and unmapped
  store cases passed, as did teardown followed by VM recreation. Ad-hoc signing
  with `com.apple.security.hypervisor=true` enabled VM creation; the same
  program without the entitlement returned `HV_DENIED` (`0xfae94007`).
- W's Darwin `kvm_create` rejected execution and cleaned up its failed state.
  `memfd_create`, `mmap_fd` and `madvise` reported unsupported. A native build
  of `wvm available` exited 77; running the W hello fixture exited 125 with a
  Linux-KVM-required diagnostic.

These observations establish host readiness, not W guest execution, snapshot
CoW, cancellation or leak freedom. The C probe used an external ten-second
process timeout, not an implemented VM deadline. Raw logs/probes were local
ignored `bin/issue591` artifacts; they are not a repository test gate. D0/D1
must add maintained reproducible equivalents.

The local `w_darwin` differed from its pin and did not finish bootstrap within
the observation period. Testing used an isolated verified seed without
replacing that local seed. `./wbuild tests` was attempted but stopped in that
bootstrap; the documented Linux SSH host was unreachable. No full-suite pass
is claimed by this planning change.

## Architecture decisions

### Host adapter and process ownership

Introduce a narrow host interface under `lib/vmm/` for capability discovery,
VM/vCPU creation, memory registration/protection, register state, exits,
interruption and destruction. Keep KVM constants and Hypervisor records behind
their respective implementations. Start by adapting Linux without changing
its observable behavior; avoid a wholesale rewrite of its execution loop.

On Darwin, the daemon owns policy, template references and worker lifetimes;
an exec-created, signed worker owns one VM. Create/run/destroy each vCPU on
its owning host thread. Do not fork a process that has already initialized
Hypervisor state. The framework requires one VM per process and the
`com.apple.security.hypervisor` entitlement; check `kern.hv_support` and then
perform a real create/destroy probe rather than treating hardware support as
execution availability. See [Apple's Hypervisor documentation](https://developer.apple.com/documentation/hypervisor).

Use bounded, versioned worker messages over an owned pipe/socket, with
request IDs, response limits and explicit cancellation acknowledgements.
Transfer only allowlisted descriptors; authenticate worker startup through
the parent-owned channel. Document the Darwin descriptor-transfer mechanism
(inherited descriptors at exec for v1, or validated `SCM_RIGHTS` if needed).
Guest paths and descriptor numbers must never select host resources directly.

Capabilities include host backend, guest arch/ABI, page granules, snapshot
format, ready-template support, live-checkpoint support, quotas, debug, file
and network services. Unsupported requests fail before allocating a session
or accepting a lease. Preserve existing CLI status conventions and stable
client errors, adding distinct unsupported-host, missing-entitlement,
unsupported-image and backend-initialization diagnostics. Never host-exec a
rejected image or silently route it to another architecture.

### Guest image and syscall boundary

Use static little-endian ELF64 `ET_EXEC`, `EM_AARCH64` (183), emitted with
the compiler's existing `arm64` target. The worker is `arm64_darwin` Mach-O;
the guest uses the Linux AArch64 ABI. Compiling source for a Darwin cell
therefore selects `arm64`, not `arm64_darwin`. Reject x64/ARM32/Mach-O,
dynamic/interpreted images and unsupported relocation/ABI variants explicitly.

Run untrusted guest code at EL0. A small protected EL1 monitor supplies
exception vectors and a syscall exit gate; `svc #0` reaches the monitor,
which exits through a checked HVC site. Validate exit origin, exception class,
saved user state and syscall number before dispatch. Never permit guest EL0
access to monitor code, stacks, page tables or the saved syscall frame.
Restore user state with the correct return PC; do not skip/reexecute the SVC.
Reject forged gates and unexpected exceptions. Direct guest HVC is not an
alternative permission path.

Keep the existing ARM64 convention: syscall number in x8, arguments in
x0–x5, result/negative guest errno in x0. Extract portable service handlers
from the current x64 dispatcher. Translate syscall numbers, flags, errno,
struct layouts and guest pointers explicitly; never forward a guest number
to Darwin's raw syscall surface. Audit startup, allocator, exit, TLS,
clock and random paths used by the chosen static W fixtures. Unsupported
calls return a documented guest error, or terminate where required by policy.

Initially allow only the services required by the basic fixtures: exit,
bounded stdin/stdout/stderr, anonymous guest memory management and explicitly
selected runtime queries. Reject file/network/thread capabilities. Every
buffer and nested structure must have overflow-safe bounds and permission
checks across all touched guest pages; zero-length and wrapping ranges get
separate tests. Bound syscall count and captured output independently of time.

Guest page tables and framework mappings have different roles: EL0/EL1
isolation and per-image permissions belong to ARM64 stage-1 tables; the host
controls which backing RAM reaches the VM. Discover host page size and the
supported IPA mapping granule, and choose/document the guest translation
granule. Do not reuse the x64 loader's hard-coded 4096-byte rounding for
host mappings. Test ELF segment permission boundaries that share a larger
host page. Initialize and reset general, stack, system, TLS and FP/SIMD state
used by W; feature-dependent registers must be probed, not assumed.

### Deadlines, cancellation and failure recovery

Use monotonic absolute deadlines and a watchdog/control thread that calls
`hv_vcpus_exit`; it must interrupt a CPU-only guest loop with no syscalls.
The installed SDK documents that `hv_vcpu_run` blocks until exit/cancellation
and runs on its owning thread. Keep framework interruption separate from
command completion: after the run loop exits, revoke per-run resources and
acknowledge cancellation before recycling a worker.

Bound host-side syscall servicing too. A blocked read or output consumer
must not defeat the guest deadline. The parent applies a final cleanup
deadline, terminates/reaps a nonresponsive worker and replaces it. Use
request generations so delayed watchdog events cannot cancel a later lease.
Join the watchdog before destroying its vCPU IDs. Cancellation, natural exit
and daemon disconnect must converge on one idempotent cleanup path.

### Darwin snapshots and private clones

V1 captures only ready, never-run cells with pristine I/O and no external
resources. Store architecture/ABI, RAM size, page geometry, image identity,
format version and initial register state in a validated header. Live guest
state is rejected explicitly, including imported Linux snapshots.

Prototype file-backed private mappings as the first candidate, with a
specific ownership contract: the trusted template owner creates an exclusive
file in a private directory, writes/finalizes it, opens a read-only handle,
unlinks its name, removes writable mappings and closes all writable handles
before publishing. Workers receive only read-only backing handles and map
private writable views. Each clone retains its own handle independently of
the source/template handle. Account for backing-file allocation and cleanup.

This is lifecycle-enforced immutability inside the trusted host runtime;
it is not equivalent to Linux kernel seals and does not defend against a
malicious host owner retaining a writable handle. Keep that trust boundary
explicit. Add Darwin mapping primitives with checked semantics; leave Linux
memfd/sealing calls unsupported rather than aliasing them to anonymous RAM.

**D2 is a go/no-go experiment:** prove that actual guest writes through
`hv_vm_map` preserve private CoW isolation between worker processes and do
not mutate the template. Host writes alone cannot establish this. Measure
whether framework registration eagerly materializes or pins pages. If the
candidate fails, evaluate a Mach memory-entry/remap approach separately;
do not publish clone-sharing support or memory savings until one passes.
A full-copy fallback may be exposed only as a distinct capability with its
cost reported, and does not satisfy the shared-backing milestone.

Reset first quiesces all execution, detaches guest memory, unmaps the private
view, remaps from the retained template handle, restores permissions and
initial CPU state, and clears all per-run resources. Recreate the VM/vCPU
when necessary for a complete reset. Do not depend on Linux
`MADV_DONTNEED` semantics. Optimize retention only after repeated reset tests
prove architectural state, watchdogs, output and guest memory are pristine.
Destroying the source, template registry entry or another clone must not
invalidate surviving clones.

## Delivery sequence and acceptance gates

Names below are proposed. Each stage should be independently reviewable;
add conventional tests and source-owned build directives as it lands.

| Stage | Deliverable / likely files | Required evidence |
|---|---|---|
| D0: native prerequisites | Native build/run script under `tools/mac/`; signed worker fixture and entitlement plist; `build.base.json` only where no source owns the target | Fresh pinned-seed Darwin fixpoint, six smoke programs, dynamic FFI, strict checks; record host/SDK/seeds/signature |
| D1: host interface | New W framework adapter, host selector and standalone worker; Linux adapter extraction | Real ARM64 HVC hello, writable/read-only/NX/unmapped cases, missing entitlement, unsupported host, repeated create/destroy and failure cleanup; Linux gates stay green |
| D2: backing experiment | Darwin snapshot backing and descriptor ownership prototype | Two worker processes with actual guest writes; unchanged source and sibling; source/owner destruction, reset after dirty writes, failure cleanup, template-inclusive resident-memory evidence; decide backing mechanism before D5 |
| D3: ARM64 cells | Checked ELF loader, EL0 entry/EL1 monitor, ARM64 register/syscall adapter; split portable parts of `memory.w`, `elf.w`, `syscalls.w` | Static W hello and allocator/container fixtures execute inside HV; malformed images, wrong architecture, protected monitor, bad buffers, denied calls, bounded output and guest faults |
| D4: bounded lifecycle | Worker protocol, monotonic watchdog, cancellation, parent recovery | CPU-only loop, blocked I/O, output flood, cancel-before-start/during-run, deadline/exit races, worker crash and daemon disconnect; every worker reaped, leases released and next command succeeds |
| D5: templates/reset/pool | Darwin implementation behind snapshot/pool contracts, versioned metadata and independent clone ownership | Clone isolation and reset loops, template/source deletion, truncated/corrupt backing rejection, injected failures at each resource acquisition, stable process/descriptor counts, bounded replacement |
| D6: CLI/daemon/client | `wvm`, `wvmd`, `wvm_client`, scheduler/control integration reconciled with #593 | Same supported lifecycle through CLI and RPC; capability negotiation, multi-session isolation, queue/admission/lease/cancel tests, unsupported boxes/quotas/regions/checkpoints/debug operations rejected |
| D7: required native gate | `tools/mac/run_vm_tests.sh` (proposed), Darwin targets, recorded benchmark/report schema | No-skip real-HV run of every supported acceptance case, reproducible host instructions and measurements; existing Linux full suite and VM gate pass |

Order: D0 -> D1; D2 and D3 require D1; D4 requires D3; D5 requires D2
and D4; D6 requires D5; D7 closes acceptance. Native execution checks start
at D1 and run throughout, not only at D7. If #593 has not landed, hold its
dependent integration changes or explicitly stack them; keep this planning
PR based on main.

## Validation and completion criteria

The native gate must build/sign its worker onto a fresh inode and verify its
entitlement. Ordinary compiler self-signing does not grant Hypervisor access.
It records the exact source revision, compiler seed hash, macOS/SDK, model,
chip, RAM and runtime capabilities. Missing hardware, signing or an execution
skip makes this gate fail; a cross-compile-only CI job is separately named.
Use a dedicated Apple Silicon runner when available, otherwise ship the
reproducible manual script and attach its complete result to implementation
PRs. Nested virtualization availability must be detected, not assumed.

Map every #591 acceptance requirement to an executable case or an explicit
unsupported-operation assertion:

| Requirement | Acceptance |
|---|---|
| Native compiler + VM hello + static W guest | D0/D1/D3; distinguish host probe from W fixture execution |
| Permissions, malformed images, syscalls/buffers, output | D1/D3 negative cases with positive controls and exact status/diagnostics |
| Deadlines/cancellation | D4; no-syscall loop and host-I/O stalls both bounded |
| Clones/reset/source destruction | D2/D5 across separate processes, after dirty guest writes |
| Resource cleanup/failure recovery | D4/D5; repeated success/failure/cancel cycles; track descriptors, live processes, mappings and retained template references |
| Fault/debugger/checkpoint behavior | Report ARM64 PC, exception syndrome and available symbols; unsupported debugger/live checkpoint requests fail explicitly without mutating the session |
| Latency and memory | D7 measurement protocol below |
| Native reproducibility | D7 no-skip script checked into the repository |

Do not label admission limits, RAM allocation ceilings or a watchdog as
Darwin equivalents of cgroup CPU/memory/pids accounting. Reject Linux quota
requests that cannot be enforced. Default filesystem/network denial remains
until a Darwin confinement design passes its own tests; Linux `openat2` and
`/proc/self/fd` assumptions do not provide Darwin confinement.

Measure VM/process creation, template capture, restore, first command,
ready-pool acquisition and replacement separately with a monotonic clock.
Report cold/warm conditions, RAM/image/workload sizes, sample counts and
p50/p95/p99, including process startup and signing separately where relevant.
Measure template-owner plus worker resident memory at idle and at defined
dirty-page fractions for one and multiple clones. Use Darwin VM accounting
(`vmmap`/Mach region data as available), distinguish resident/private/shared
from virtual size, avoid double-counting shared backing, and disclose any
unattributable or pinned memory. Include file backing and a full-copy baseline.
If actual sharing cannot be established, report it as unproven; do not infer
it from `MAP_PRIVATE` or claim the design's latency targets as results.

For each implementation diff, follow `AGENTS.md`: structured diagnostics,
architecture checks, manifest-selected tests, bootstrap fixpoints and full
`./wbuild tests` on a supported Linux host. Run `verify_x64` for word-size/
codegen changes and `verify_darwin` plus the native VM gate for this backend.
Preserve pinned-seed compatibility in compiler import closures; extend the
parser-generator grammar if syntax changes become necessary. Gate any
refactoring of common Linux VM behavior with its real-KVM execution tests.

Issue #591 is complete only when the supported Darwin cell path and all
applicable tests above execute natively, unsupported features are explicit,
the documented backing contract is proven, and reproducible measurements
are attached. A plan, host-only probe or cross-compilation does not close it.
