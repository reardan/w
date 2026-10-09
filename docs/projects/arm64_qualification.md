# Native ARM64 ordered-memory qualification (#607)

The checked-in command is:

```sh
python3 tools/qualify_native.py --suite atomic --rounds 20 --output bin/atomic-native.json
```

Run it from a checkout with a native W compiler on both ARM64 Linux and Apple
Silicon macOS. `--compiler /path/to/w` selects that compiler. The command rejects
non-ARM64 hosts and machines with fewer than two logical CPUs. Run on real
hardware with at least two available cores; do not present virtual-machine,
QEMU, Rosetta, or cross-compilation results as native qualification. Retain the
JSON report and note any container/cpuset restrictions alongside it.

`tests/atomic_native_fixture.w` uses independent forked workers and an anonymous
`MAP_SHARED` mapping. These are genuinely concurrent processes sharing the same
normal memory, with no W thread runtime, mutexes, scheduler hooks, or C atomic
implementation involved. The workers execute W's own atomic instructions. One
worker and the parent repeatedly publish a payload with release/acquire flags
and acknowledge consumption before reuse. Two workers then run the store-buffer
litmus with full fences; the coordinator resets and starts each round, waits for
both completion flags, and rejects the forbidden both-zero result. Coordination
does not serialize the tested store/fence/load sequences.

Each binary runs 100,000 publication rounds and 100,000 fence rounds. The driver
rebuilds and repeats under streaming, retained AST, and optimized retained AST
compilation. It checks eight-byte words, aligned shared addresses and full-width
values above 2^32. Misaligned atomics remain outside the contract; the harness
does not intentionally issue architecturally invalid unaligned accesses. A
watchdog kills the whole process group on failure or timeout, including workers
left spinning if another worker failed.

The JSON records host/OS/CPU information, compiler and source hashes, compiler
flags, output hashes and completed repetitions. A passing statistical stress run
is evidence for that hardware/OS/compiler combination, not proof of every weak
memory execution. Save additional hardware model, available-core restrictions
and virtualization status if not fully described in the report.

## Evidence status

| Target | Current evidence | Native acceptance |
|---|---|---|
| ARM64 Linux | All three modes cross-compile | Pending real ARM64 Linux run |
| ARM64 Darwin | All three modes cross-compile | Pending Apple Silicon run |
| Linux x64 | All three modes execute the harness successfully | Supplementary only |

The implementation session ran on Linux x86_64, without QEMU or either native
ARM64 host. No native ARM64 pass is claimed; #607's hardware acceptance remains
open. Supplementary commands are part of `./wbuild tests`:

```sh
./wbuild native_qualification_cross_test native_qualification_host_test
```

Ordered loads/stores and full fences do **not** supply ARM64 atomic RMW lowering
(`atomic_add`/`atomic_cas`) or the W thread/mutex/condition-variable port. Those
remain separate work. These instructions require normal inner-shareable memory,
not device memory or MMIO. See [the memory-order contract](threads.md).
