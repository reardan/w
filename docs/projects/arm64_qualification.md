# Native ARM64 ordered-memory qualification (#607)

The checked-in command is:

```sh
python3 tools/qualify_native.py --suite atomic --rounds 20 --output bin/atomic-native.json
```

Run it from a checkout with a native W compiler on both ARM64 Linux and Apple
Silicon macOS. The default compiler is `bin/wv2_darwin` on macOS and `bin/wv2`
elsewhere; `--compiler /path/to/w` overrides it. On a Mac with the pinned seed,
`./wbuild atomic_native_darwin_test` builds the native compiler and runs all three
modes for 20 repetitions. The command rejects
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
The shared words occupy separate 128-byte slots, including payload and control
flags, so the tested locations do not share an Apple Silicon cache line.
The fixture asserts each slot's address as well as word alignment.

Each binary runs 100,000 publication rounds and 100,000 fence rounds. The driver
rebuilds and repeats under streaming, retained AST, and optimized retained AST
compilation. It checks eight-byte words, aligned shared addresses and full-width
values above 2^32. Misaligned atomics remain outside the contract; the harness
does not intentionally issue architecturally invalid unaligned accesses. A
watchdog kills the whole process group on failure or timeout, including workers
left spinning if another worker failed.
Each rebuild publishes a fresh executable inode to avoid macOS's vnode-based
code-signature cache when running the qualification command repeatedly.

The JSON records host/OS/CPU information, compiler and source hashes, compiler
flags, output hashes and completed repetitions. A passing statistical stress run
is evidence for that hardware/OS/compiler combination, not proof of every weak
memory execution. Save additional hardware model, available-core restrictions
and virtualization status if not fully described in the report.

## Evidence status

| Target | Current evidence | Native acceptance |
|---|---|---|
| ARM64 Linux | All three modes cross-compile | Pending real ARM64 Linux run |
| ARM64 Darwin | All three modes pass 20 native repetitions on M3 Pro/macOS 26.3 | Passed on the recorded configuration below |
| Linux x64 | All three modes execute the harness successfully | Supplementary only |

The original implementation session ran on Linux x86_64. The Darwin follow-up
below supplies native Apple Silicon evidence; #607 remains open for real ARM64
Linux qualification. Supplementary commands are part of `./wbuild tests`:

```sh
./wbuild native_qualification_cross_test native_qualification_host_test
```

## Apple Silicon result (2026-10-10 UTC)

The [recorded JSON report](arm64_qualification_m3_pro.json) passed on a physical
Apple M3 Pro, model Mac15,6, with 12 physical/logical CPUs, 128-byte cache lines,
macOS 26.3 (25D125), Darwin 25.3.0. `kern.hv_vmm_present=0`; execution was native
arm64 on the macOS host, without Rosetta, a container, or CPU-affinity limits.

Compiler sources were `cc2d322d9395d615f59eb2436481cddaf7b444fd` plus this
qualification patch. The compiler was bootstrapped natively with the
SHA256-verified v0.3.0 Darwin seed (`8827faf7ee2bafd01c29dd40eeb896d3095171eab7d6f2ad4bdce11cc70cdbbb`).
The checkout's different local seed stalled, so the pinned seed was downloaded
separately to `bin/seed-607-darwin`, preserving the local seed. The native
`wv3_darwin_raw` and `wv4_darwin_raw` compiler stages compared byte-identical.
The driver records compiler, fixture, source-tree and driver hashes and every
compilation command. Its final invocation was:

```sh
python3 tools/qualify_native.py --suite atomic --rounds 20 --output bin/atomic-native-final.json
```

Streaming (`--streaming`), retained (`--ast-required --ast-retain`) and optimized
retained (`--ast-required --ast-retain --ast-opt`) each completed 20 repetitions
of 100,000 publication rounds and 100,000 store-buffer/fence rounds: **6 million
rounds per litmus across the three modes, with zero failures**. Earlier runs and
the native build target also passed, exercising repeated executable replacement.
This qualifies the ordered access/fence path on this configuration; no compiler
lowering change was required. Host-specific paths in the saved report identify
the original run, not prerequisites for reproducing it.

A temporary streaming negative control with both worker `atomic_fence()` calls
removed hit the forbidden both-zero assertion on this machine; the watchdog
cleaned up the remaining workers. This demonstrates harness sensitivity here,
but observing a failure without fences is statistical and is not a test gate.

Supplementary validation passed the native Darwin compiler fixpoint and
`arm64_optimization_darwin_test`. The generated W parser also accepted the
tracked sources when the file list was supplied from the macOS host. The Linux
full-suite run in the local emulated container finished with 909 targets
succeeded, 121 failed and seven skipped. Failures included missing tools/loaders
and failures in emulated x64 execution; this is not a clean regression pass.
Those results do not establish native ARM64 Linux acceptance.

Ordered loads/stores and full fences do **not** supply ARM64 atomic RMW lowering
(`atomic_add`/`atomic_cas`) or the W thread/mutex/condition-variable port. Those
remain separate work. These instructions require normal inner-shareable memory,
not device memory or MMIO. See [the memory-order contract](threads.md).
