# Darwin VM native validation

On 2026-10-07, `sh tools/mac/run_vm_tests.sh` passed all 83 steps on an
Apple M3 Pro (Mac15,6, 18 GiB), macOS 26.3 build 25D125, SDK 26.2.
The gate verified the pinned seed, built a strict native compiler fixpoint,
signed executables with the Hypervisor entitlement and executed real guests.

## Coverage

- Entitlement failure, VM/vCPU lifecycle, guest output, read-only and
  non-executable mappings, unmapped access, deadlines and cancellation.
- Static ARM64 ELF validation; argv, binary stdin, allocation, floating point,
  containers, checked buffers and syscall restrictions; protected monitor and
  forged trap rejection.
- Private snapshot mappings across exec-created workers, independent guest
  writes, template/source destruction, pristine reset, corrupt/truncated
  metadata, descriptor exhaustion and recovery without losing a valid mapping.
- Daemon admission, leases, templates, session commands/results, restore,
  cancellation, worker crash/replacement, parent death and descriptor isolation.
- Malformed/partial requests, blocked consumers, stopped workers/daemon, FIFO
  rejection and private source-compilation directories.
- Ready pool ownership/replacement, lifecycle timings and memory measurements.

Separate native validation passed manifest generation (1,043 targets, 763
source-generated), metadata checks (91 modules), the generated W grammar
(1,629 files in 41 batches), and affected architecture checks for x64 and
ARM64 Darwin. Diff-based test selection includes the native VM gate.

The complete Linux suite was attempted under Docker/QEMU, but its result is
inconclusive: a validation mirror caused shared-filesystem read interference
in addition to emulator/environment failures. The mirror was corrected.
No Linux full-suite pass is claimed; no further emulation work was requested.

## Measurements

These measurements are observations from this host, not performance guarantees.
Lifecycle cases have five samples each; these are too few to estimate reliable
tail latency. Signing is excluded. Filesystem caches are warm, workers are new
processes, and daemon/client polling is included.

| Operation | Median (ms) |
| --- | ---: |
| Daemon process start | 3.81 |
| Cold image spawn to ready | 204.50 |
| Template capture | 196.72 |
| Template clone spawn to ready | 8.27 |
| Clone first command | 4.26 |
| Restore after dirty execution to ready | 7.32 |
| Restored first command | 4.29 |

Spawn readiness includes a Hypervisor availability create/destroy probe and
private snapshot mapping. Execution VM/vCPU creation occurs at the first
command, so spawn timing is not full guest execution startup.

The ready-RAM pool measured 21 samples per operation: first command median
1.395 ms and replacement median 1.308 ms. Acquisition's 42 ns median measures
only an ownership transfer near the clock's 41.7 ns resolution; it is not a
VM creation or RPC readiness measurement. The pool does not retain vCPUs.

The memory experiment used 16 MiB guest data RAM, one and two exec workers,
0%, 25% and 100% dirty fractions, private snapshots versus full copies, and
five samples per combination (60 runs). Below are medians of summed process
footprint for the template owner and two workers:

| Dirty fraction | Private snapshot (MiB) | Full copy (MiB) |
| --- | ---: | ---: |
| 0% | 5.92 | 38.03 |
| 25% | 14.31 | 46.35 |
| 100% | 38.33 | 70.38 |

Backing-file allocation was separately 16.03 MiB. Shared Mach object IDs and
initial private-page counts support sharing before guest writes; reports retain
private/shared resident counts. Hypervisor shadow/reference accounting prevents
exact attribution of unique physical or pinned bytes. Summed RSS and footprint
must not be interpreted as unique physical memory, or added to backing-file
allocation as though these were disjoint quantities.

## Reproduction and evidence

Run `sh tools/mac/run_vm_tests.sh` on an entitled Apple Silicon host. Each run
writes logs plus `report.json`, `lifecycle.json`, `pool.json` and `memory.json`
under its printed `bin/darwin-vm-gate/` directory. Missing native prerequisites
fail the gate. The scripts record host, seed/compiler/binary hashes, source
revision and source-content identities, conditions, raw runs and summaries.

This run's local artifact directory was
`bin/darwin-vm-gate/20261007-140428/`. Its starting source-content SHA-256 was
`931536fd24c004ed624b1aebe473a7dbd47f8f938ba4967dfe8c14e1cbbe4b31`.
Documentation changed while measurements ran; before/after identities are
recorded. Runtime sources were unchanged during the final gate. Generated
binaries and full local logs remain ignored rather than committed.

See [backend usage and limits](vms_darwin.md) and the
[implementation plan](vms_darwin_plan.md). Live checkpoints, retained-vCPU
pools, Linux boxes, x64 guests, shared regions, external filesystem/network
capabilities and interactive guest debugging remain unsupported explicitly.
