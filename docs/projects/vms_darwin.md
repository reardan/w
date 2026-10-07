# Apple Silicon cells with Hypervisor.framework

The initial Darwin cell backend for [#591](https://github.com/reardan/w/issues/591)
is implemented in W. It runs static ARM64 Linux-ABI W executables inside
Hypervisor.framework, with guest code at EL0 and a protected EL1 syscall
monitor. The host executables are ARM64 Darwin Mach-O. There is no x64
emulation or host-execution fallback in this backend.

The [implementation plan](vms_darwin_plan.md) records the staging and acceptance
criteria; [native validation](vms_darwin_validation.md) records results and
remaining validation limits. Linux KVM cells and boxes keep their existing
entry points and protocol.

## Build and required native test

On Apple Silicon macOS with Xcode command-line tools and Python 3:

```sh
# Reproducible required gate: verifies a separately downloaded SEEDS pin,
# builds a native compiler fixpoint, signs workers and executes every VM test.
sh tools/mac/run_vm_tests.sh

# Optional existing compiler; its hash is recorded in the report.
W_DARWIN_COMPILER=bin/wv2_darwin sh tools/mac/run_vm_tests.sh

# Ordinary local build, using this checkout's w_darwin bootstrap seed.
./wbuild wvm_darwin wvmd_darwin
bin/wvm_darwin available
bin/wvm_darwin capabilities
```

The gate puts binaries, complete logs and JSON reports in a timestamped
`bin/darwin-vm-gate/` directory and prints that path. It never replaces a local
seed. `./wbuild vm_darwin_native_test` invokes the same gate after the ordinary
executor bootstrap. A missing Hypervisor capability, entitlement, executable
or native test is a failure, not a skip. Cross-compilation is useful but is
not execution evidence.

`tools/mac/hypervisor.entitlements` grants `com.apple.security.hypervisor`.
Workers are ad-hoc signed on a fresh inode before execution; compiler
self-signing alone does not grant this entitlement. `kern.hv_support` plus an
actual create/destroy probe determine availability. The negative entitlement
case is tested using an otherwise identical unentitled executable.

## One-shot execution

```sh
bin/wv2_darwin arm64 tests/wvm_darwin_fixture.w -o bin/arm64_cell
bin/wvm_darwin run --timeout-ms 1000 bin/arm64_cell hello
# Prints hello from an ARM64 cell and returns the guest's status 7.

printf 'bounded input\n' | bin/wvm_darwin run bin/arm64_cell input
W_DARWIN_COMPILER=bin/wv2_darwin bin/wvm_darwin run tests/hello.w
```

Source compilation happens on the host in a private temporary directory and
selects the `arm64` target. Only the resulting checked static ELF executes in
the VM. CLI redirected stdin is bounded to 4 MiB; interactive terminal input
is not consumed. `--timeout-ms` accepts 1..600000 and `--output-limit` accepts
1..4194304 combined stdout/stderr bytes. Input and output transport waits are
bounded too. Normal guest exit is returned unchanged; unavailable capability
returns 77, guest deadline 124, runtime/policy failure 125 and guest fault 139.
Invalid CLI options return 2. Fault responses carry ARM64 PC and syndrome;
interactive debugger and symbolized guest stack traces are not implemented.

The guest has one vCPU and a fixed 256 MiB address space. The checked syscall
subset provides buffered standard I/O, anonymous memory management, selected
process-identity queries, clocks, randomness and exit. Guest syscall numbers,
flags and buffer permissions are decoded explicitly; they never reach raw
Darwin syscalls as host operations. File/network/thread capabilities, Mach-O,
x64, dynamic ELF, foreign ELF ABI and TLS program segments are rejected.
The compiler currently rejects ARM64 Linux `thread_local` syntax too.

## Daemon and existing client protocol

```sh
bin/wvmd_darwin serve --socket bin/wvmd-darwin.sock \
  --worker bin/wvm_darwin --max-active 4 --max-pending 16 --memory-mb 4096

bin/wvmd_darwin call bin/wvmd-darwin.sock capabilities
bin/wvmd_darwin call bin/wvmd-darwin.sock template_create \
  '{"backend":"cell","image":"bin/arm64_cell","lease_ms":60000}'
bin/wvmd_darwin call bin/wvmd-darwin.sock vm_spawn \
  '{"backend":"cell","template":1,"lease_ms":60000}'
bin/wvmd_darwin call bin/wvmd-darwin.sock vm_status '{"session":1}'
# After the session is ready:
bin/wvmd_darwin call bin/wvmd-darwin.sock vm_exec \
  '{"session":1,"argv":["cell","hello"],"timeout_ms":1000,"output_limit":65536}'
bin/wvmd_darwin call bin/wvmd-darwin.sock vm_result \
  '{"session":1,"offset":0,"length":2048}'
bin/wvmd_darwin call bin/wvmd-darwin.sock vm_destroy '{"session":1}'
bin/wvmd_darwin call bin/wvmd-darwin.sock template_destroy '{"template":1}'
bin/wvmd_darwin call bin/wvmd-darwin.sock stop
```

IDs in the example assume a fresh daemon. `vm_spawn` also accepts `image`
instead of `template`. Every session must explicitly select `backend=cell`;
`cpus` and `memory_mb`, when provided, must be 1 and 256. Sessions move through
queued, booting, ready, busy and failed. `vm_exec` returns a command ID; poll
`vm_status`/`vm_result` until ready or failed. Results use the existing
`stdout_hex`/`stderr_hex` chunk protocol. Optional `stdin_hex` supplies up to
2048 bytes, including NULs; it is cleared before the next command. Requests
are limited to 8192 JSON bytes, argv to 128 strings/4096 total bytes, and RPC
output to 1 MiB. The existing `lib.wvm_client` works on Darwin; socket signal
suppression and EAGAIN use the platform ABI.

`vm_restore` replaces an idle worker from its original ready backing.
Every command also remaps pristine RAM before executing: commands do not
retain a guest filesystem, process or mutable memory session. `vm_cancel`
and `vm_destroy` kill and reap the session worker. `vm_renew` and
`template_renew` accept leases of 100..3600000 ms. Template destruction or
expiry prevents new clones but does not invalidate existing session handles.
`stats` reports reservations, active/queued sessions and completions.

Each worker is exec-created with only stdio and its explicit read-only
backing descriptor. The parent never owns an initialized VM. A monotonic
pthread watchdog interrupts CPU-only loops; parent death interrupts an active
guest, and control-channel EOF terminates idle workers. Slow result consumers
are bounded. Failure recovery tests cover stopped/crashed workers, a stopped
or killed daemon, descriptor isolation and successful replacement.

The socket is mode 0600. Startup refuses an occupied path; after a forced
kill, remove its stale socket only after verifying no daemon owns it. Orderly
`stop` removes the socket and releases sessions/templates. Admission reserves
256 MiB per retained session/template conservatively; these reservations and
deadlines are not equivalents of Linux cgroup quotas. Linux boxes, external
filesystem/network grants, shared regions, live checkpoints and debugger
requests fail explicitly.

## Snapshot ownership and ready pools

`lib/vmm/darwin_snapshot.w` creates an exclusive backing file in a private
directory, publishes only a read-only descriptor, then unlinks the file and
closes every writable mapping/handle. Clones own independent descriptors and
map private writable views. Ready cell metadata records architecture, ABI,
geometry, image fingerprint, permissions, initial state and bounded input.
Only never-run, pristine cells can be captured. Corrupt/truncated records and
writable backing handles are rejected.

This is immutability enforced by trusted host ownership, not Linux kernel
sealing. The host owner is trusted not to retain an undisclosed writable
handle. A fingerprint detects accidental inconsistency; it is not snapshot
authentication. Arbitrary user-supplied live checkpoints are unsupported.

Reset quiesces execution and replaces the private mapping from the retained
backing descriptor. The initial CPU state is recreated on the next command;
no Linux `MADV_DONTNEED` behavior is assumed. Actual guest writes in separate
processes, source/template destruction and allocation-failure cleanup are
covered by native tests.

`lib/vmm/darwin_pool.w` provides a bounded ready-RAM pool: `darwin_pool_new`,
`darwin_pool_acquire`, `darwin_pool_replenish` and `darwin_pool_free`.
Acquisition transfers a prepared cell to the caller; replacement restores a
new private mapping. Calls are serialized and HV execution is one cell at a
time per process. These are prepared RAM/metadata pools, not retained-vCPU
pools. The daemon can separately keep multiple exec-created workers ready.

The gate records pool acquisition/replacement separately from VM creation,
process startup, capture, clone restore and first command. Mach region and
process memory counters include the template owner and a full-copy baseline.
Reports preserve private/shared resident counts and disclose Hypervisor
shadow/reference effects; summed RSS is never presented as unique physical
memory. See [validation and measurements](vms_darwin_validation.md).
