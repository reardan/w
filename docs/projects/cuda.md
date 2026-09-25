# CUDA Backend for W

Brainstorm for adding NVIDIA GPU support to the W compiler. Companion to the x64
work: every viable path below assumes a 64-bit host process, because `libcuda.so`
and the CUDA driver API are 64-bit only. Finishing x64 self-hosting (see
`docs/mvp.txt`) is effectively Stage 0 of this project.

**Status: Stages 0–3 are done.** The host side went straight to H1 (real
dynamic linking, both x86 and x64): `c_lib "libcuda.so.1"` + `extern`
declarations link the driver API directly (`grammar/extern_statement.w`,
`code_generator/elf_dynamic.w`, `code_generator/ffi.w`), and `./wbuild cuda_smoke`
runs a hand-written PTX vector add on a real GPU (`tests/cuda_smoke.w`). The
H3 sidecar was skipped. Stage 2 shipped as option A1 (`code_generator/ptx.w`:
`kernel` declarations, the thread-index intrinsics, `launch`) and Stage 3 as
M2 (`gpu for` outlining with capture-as-parameters), both on the M1+M2
surface with the `lib/cuda.w` runtime (managed memory, async launches,
`gpu_sync()`). See "Execution notes (Stages 2–3)" below for the model as
built. A first Stage 4 slice shipped too: gpu atomics
(`atomic_add`/`atomic_min`/`atomic_max`, with an atomic-reduction
`cuda_test` case), the explicit memory API (`gpu_device_alloc` +
`gpu_memcpy_to`/`gpu_memcpy_from`), the nine 32-bit limb/bit intrinsics on
device, `gpu for ... in range(start, end)`, and a const-based diagnostic
for writes to captured scalars. docs/projects/torch.md builds on this:
its Stage 1 added a non-fatal `gpu_available()` driver+device probe to
`lib/cuda.w`, and its Stages 2-3 the `lib/tensor.w` managed-memory
tensor type with CPU fallbacks (reductions ride the Stage 4
`atomic_add`). Remaining Stage 4 material: A2 virtual registers,
`gpu float*` types, recoverable CUresult error handling, multi-GPU
selection, shared memory — and the "someday" list.

## Context: what W is today

- Single-pass, syntax-directed code generator (cc500 heritage). There is no AST or
  IR — grammar rules in `grammar/*.w` emit machine bytes immediately via
  `code_generator/x86.w` (x64 = same module + REX prefix via `emit_x64_opcode()`).
- Output is a static ELF executable by default (`code_generator/elf_32.w` /
  `elf_64.w`) with a single load segment. Programs that declare `c_lib` /
  `extern` or use `c_import` instead get PT_INTERP/PT_DYNAMIC records, eager
  GOT relocations and per-arch C ABI shims, so they can call shared libraries
  such as libc and libcuda directly.
- Target selection is a CLI flag (`w x64 file.w` sets `word_size = 8` in
  `compiler/compiler.w`); a `cuda` flag can follow the same pattern.
- `docs/projects/hiring.txt` already lists `gpu` / `GPUAssembly` knowledge and
  GPU work as a secondary project; `docs/parallel.txt` sketches `thread` / `lock`
  primitives that a GPU model should stay consistent with.

A CUDA backend is really two projects:

1. **Device side** — compile (some subset of) W to code the GPU can run.
2. **Host side** — make the generated W executable talk to the NVIDIA driver to
   load kernels, move memory, and launch.

```mermaid
flowchart LR
    subgraph device [Device side]
        wsrc[W kernel source] --> emitter[PTX emitter]
        emitter --> ptx[PTX text in .rodata]
    end
    subgraph host [Host side]
        main[W host code] --> ffi[FFI shim]
        ffi --> libcuda[libcuda.so driver API]
    end
    ptx --> libcuda
    libcuda --> jit["driver JIT (PTX to SASS)"]
    jit --> gpu[GPU execution]
```

## The CUDA compilation stack (what we can target)

NVIDIA's own trajectory (`nvcc`): CUDA C++ -> PTX -> SASS. The layers, from most
to least portable:

- **CUDA C++** — source language, compiled by `nvcc` (offline) or NVRTC (a library
  that compiles CUDA C++ source strings at runtime, no `nvcc` needed, but requires
  toolkit libraries `libnvrtc.so`).
- **NVVM IR** — an LLVM IR dialect; `libnvvm.so` compiles it to PTX. Requires the
  toolkit compiler SDK. This is the layer Julia's CUDA.jl and (via LLVM's NVPTX
  backend) OpenAI Triton sit on.
- **PTX** — NVIDIA's *documented, stable, virtual* ISA. Plain text. Currently PTX
  ISA 9.3 (CUDA Toolkit 13.3, mid-2026). The driver JIT-compiles PTX to native
  code at module-load time (`cuModuleLoadData` accepts PTX text directly), so
  emitting PTX requires **only `libcuda.so`** on the user's machine — no toolkit.
- **SASS / cubin** — the real per-architecture machine code. Undocumented and
  unstable across GPU generations; NVIDIA publishes only per-arch instruction
  lists (Turing, Ampere/Ada, Hopper, Blackwell) in the binary-utilities docs.
  Community assemblers exist (MaxAs, TuringAs, CuAssembler) but each covers a
  narrow architecture window.

## Device-side options

### Option A: Emit PTX text directly (recommended)

Treat PTX exactly the way the compiler treats x86 today: a new emitter module
(`code_generator/ptx.w`) with small emit helpers, driven by the grammar. Instead
of `emit(1, "\x50")` it appends text lines ("`add.s32 %r3, %r1, %r2;`") using the
existing string builder (`structures/string.w`).

- Pro: matches W's philosophy — no LLVM, no toolkit dependency, self-contained.
  Documented spec (PTX ISA reference). Driver JIT handles PTX -> SASS forever
  forward-compatibly. Precedent: pyptx (Python), oxicuda-ptx (Rust) both emit PTX
  text without LLVM.
- Pro: PTX is much friendlier than x86 bytes — text format, unlimited virtual
  registers (`%r1, %r2, ...`), typed instructions, no encoding tables.
- Con: PTX is a load/store register machine, not a stack machine. The single-pass
  "everything through `%eax`, spill via `push`" pattern from `x86.w` maps awkwardly.
  Two sub-options:
  - **A1 — stack-machine PTX**: mechanically mirror the x86 pattern using a
    `.local` array as the evaluation stack and one accumulator register. Trivially
    reuses grammar code; produces slow PTX, but the driver JIT's optimizer will
    clean up some of it. Good enough for an MVP.
  - **A2 — virtual-register PTX**: have grammar rules return a register name
    (string/int) instead of leaving values in `%eax`. This is a real change to the
    codegen contract (`promote()`, `push_eax()` call sites), but PTX's infinite
    registers make it *easier* than a register allocator for x86 — just bump a
    counter. Could later feed a real x64 register allocator too.
- Con: no libc/syscalls on device — kernels are pure compute over pointers, which
  is fine; the W device subset simply excludes I/O, `new`, and string helpers at
  first.

### Option B: Emit CUDA C source, compile via NVRTC or nvcc

The transpiler route: pretty-print the kernel body as CUDA C, compile it either
offline (build step invoking `nvcc`) or at runtime (link against `libnvrtc.so`).

- Pro: by far the fastest path to a working demo, and NVIDIA's compiler does all
  optimization. Great as a *reference oracle* to validate our PTX emitter output.
- Con: requires the CUDA Toolkit on the user machine (NVRTC is not part of the
  driver), and it abandons W's "we emit the bits ourselves" ethos. W also has no
  way to call `libnvrtc.so` today, so it inherits the same FFI problem as the
  driver API anyway.

### Option C: Emit NVVM IR via libNVVM

Emit LLVM-dialect IR text and let `libnvvm.so` produce PTX.

- Pro: optimization passes for free; the "grown-up" path (Triton/CUDA.jl-style).
- Con: heaviest dependency (toolkit compiler SDK + libdevice), and we'd be
  emitting an IR whose spec tracks LLVM versions. If we're going to emit textual
  IR anyway, PTX itself is simpler and more stable. Not worth it unless W later
  wants LLVM-grade optimization.

### Option D: Emit SASS/cubin directly

The "self-hosted all the way down" fantasy: assemble native GPU machine code like
we assemble x86 bytes.

- Pro: no JIT at load time, total control, maximally in-character for W.
- Con: undocumented, changes per architecture, no official assembler contract,
  community assemblers cover single generations. A research project, not a
  backend. Keep as a long-term curiosity (fits the `GPUAssembly` line in
  `hiring.txt`), possibly by studying `cuobjdump -sass` output of our own PTX.

**Recommendation: A (A1 first, A2 as follow-up), with B used manually as a
validation oracle during development.**

## Host-side options (the harder problem)

The generated executable must call the CUDA **driver API**: `cuInit`,
`cuDeviceGet`, `cuCtxCreate`, `cuModuleLoadData` (accepts PTX text),
`cuModuleGetFunction`, `cuMemAlloc` / `cuMemcpyHtoD` / `cuMemcpyDtoH`,
`cuLaunchKernel`. Driver API (not runtime API `cudaMalloc`/`cudaLaunch`) because
it lives in `libcuda.so`, ships with the driver, and is designed exactly for
"language emits PTX, loads it at runtime".

W's static-ELF, syscall-only runtime cannot call any shared library today. Four
ways in:

### H1: Real dynamic linking in the ELF writer — implemented

Extend `elf_64.w` to emit `PT_INTERP` (ld-linux), `PT_DYNAMIC`, `.dynsym`,
`.dynstr`, PLT/GOT relocations against `libcuda.so`.

- Pro: the "correct" solution, and it unlocks the `c_import` item already on
  `docs/todo.txt` (calling any C library). Biggest long-term payoff.
- Con: biggest lift — dynamic section plumbing, relocation types, symbol
  versioning quirks, plus x64 System V calling convention shims (W's internal
  convention is stack-based; libcuda expects args in rdi/rsi/rdx/rcx/r8/r9).

**This is what shipped, on both targets.** Design notes: eager binding (one
GOT slot per import + one `GLOB_DAT` relocation, no lazy PLT), a generated
per-import shim that converts W's stack convention to the C ABI (System V
registers on x64, re-pushed cdecl args on x86, both 16-byte aligned), and
`DT_HASH`/`.dynsym`/`.dynstr`/`.dynamic` appended to the single load segment
at finish time. Symbol versioning quirk to know about: libcuda's `_v2` ABI
revisions (e.g. `cuCtxCreate_v2`, `cuMemAlloc_v2`) must be named explicitly
in `extern`, since the CUDA headers normally hide that renaming.

### H2: Hand-rolled dlopen in W

Keep the static ELF; at startup, W runtime code opens `libcuda.so`, parses its
dynamic symbol table, mmaps segments, applies relocations — a mini dynamic
linker written in W (we already parse/emit ELF, so the format knowledge exists
in-house).

- Pro: no ELF-writer changes; deeply educational; stays fully static.
- Con: libcuda.so has its own dependencies (libc, libdl, libpthread, librt) and
  expects TLS, ifuncs, and libc runtime state. Realistically we'd be
  reimplementing ld.so. High risk of a tarpit. A middle path: `dlopen` via a
  *host* libc — but that again requires H1-style linking against libdl.

### H3: Sidecar GPU server process

Ship (or generate once) a tiny helper binary — written in C, ~200 lines, linked
against libcuda normally — that speaks a simple protocol over a pipe or Unix
socket: "load this PTX", "alloc N bytes", "copy", "launch f with these args".
The W executable fork/execs it and talks via syscalls it already has.

- Pro: zero changes to W's linking model; W stays pure-syscall; debuggable with
  strace; the protocol doubles as a device abstraction for future backends
  (WebGPU?). Precedent: this is essentially how some sandboxed runtimes reach
  the GPU.
- Con: introduces a compiled-C artifact into a self-hosted project (bootstrap
  smell); per-call IPC latency (fine for coarse kernels, bad for chatty code);
  shared memory (`memfd` + `mmap`) needed to avoid copying buffers through pipes.

### H4: ioctl the kernel driver directly

Skip libcuda entirely and speak to `/dev/nvidia*` via ioctls — the syscall-only
dream.

- Con: the NVIDIA ioctl interface is undocumented, unstable, and enormous
  (libcuda exists precisely to hide it). The open-gpu-kernel-modules source makes
  it *visible* but not *stable*. Even nouveau-based stacks go through Mesa. Not
  viable; listed for completeness.

**Recommendation: H3 to bootstrap (get kernels running with zero linker work),
then H1 as the real investment — it pays for `c_import` and every future C
library, not just CUDA.**

## Programming model options (what W code looks like)

### M1: Explicit kernels, CUDA-style

```
kernel add(float* a, float* b, float* c, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		c[i] = a[i] + b[i]

launch add[blocks, threads](a, b, c, n)
```

Thread-level model, maps 1:1 onto PTX special registers (`%tid.x`, `%ctaid.x`,
`%ntid.x`). Most transparent; most footguns (sizing, bounds masks by hand).

### M2: Parallel-for on existing range loops (best MVP)

W already has `for int i in range(...)`. Add one keyword:

```
gpu for int i in range(n):
	c[i] = a[i] + b[i]
```

The compiler outlines the loop body into a PTX kernel (captured variables become
kernel parameters), auto-generates the guard `if (i < n)`, picks a block size,
and emits host code for launch. This is the smallest surface area that delivers
real value, and it composes with the planned `thread`/`lock` design in
`docs/parallel.txt` (same mental model: annotate a loop, runtime does the rest).

### M3: Triton-style tile programs

Triton's insight (Tillet et al., MAPL 2019; Triton 3.7 today): don't expose
threads at all. A "program" instance owns a *tile*; `tl.load`/`tl.store` on
ranges with masks; the compiler (Triton IR -> TritonGPU MLIR -> LLVM -> PTX)
handles vectorization, shared memory, and layouts. The pipeline is heavy MLIR
machinery, but the *language surface* is the steal-worthy part:

```
gpu[1024] for tile in range(n):        # each program handles 1024 elements
	c[tile] = a[tile] + b[tile]        # loads/stores auto-masked
```

W could adopt tile semantics without the optimizing stack — lower a tile op to a
simple per-thread loop first, and treat Triton-grade codegen (coalescing, shared
memory staging) as future optimization work inside the same syntax.

**Recommendation: M2 first, with syntax designed so M3 tile semantics can layer
on later. M1's builtins fall out for free (the outlined kernel needs them
internally anyway) and can be exposed for power users.**

## Memory model

- **Explicit** (`cuMemAlloc` + `cuMemcpyHtoD/DtoH`): most control, most
  ceremony; host and device pointers are different types (a `gpu float*`
  qualifier would let the type table catch cross-domain bugs).
- **Unified/managed** (`cuMemAllocManaged`): one pointer valid on both sides,
  driver migrates pages on demand. Dramatically simplifies the MVP — `new` on a
  managed heap and `gpu for` just works, no copy calls. Costs performance on
  first touch.

Recommendation: managed memory for the MVP (`gpu new float[n]` or making the
GPU allocator a compile-flag choice), explicit copies as the later
performance-oriented API.

## Suggested staged path

- **Stage 0 — x64 completion** (done): 64-bit self-hosting, `lib_test` on x64,
  working 64-bit pointers/stack.
- **Stage 1 — host plumbing spike** (done, via H1 directly): hand-written
  vector-add PTX as a string literal in `tests/cuda_smoke.w`, loaded with
  `cuModuleLoadData` and launched with `cuLaunchKernel` through `c_lib` /
  `extern`. Acceptance met: `./wbuild cuda_smoke` runs vector add on a real GPU
  (RTX 4080).
- **Stage 2 — PTX emitter** (done): `code_generator/ptx.w` with A1
  stack-machine emission for kernel bodies (int/pointer/float32/float64
  arithmetic, if/while/switch, nested for-range). Kernel PTX is embedded in
  the host image behind a synthesized `char* __w_ptx_module()` and passed to
  `cuModuleLoadData` at runtime; `--ptx=<path>` dumps it for inspection and
  the GPU-less `gpu_ptx_emit_test` asserts on the text.
- **Stage 3 — `gpu for` (M2)** (done): outlining pass (`grammar/gpu_for.w`),
  parameter capture, guard insertion, launch-config heuristic (256-thread
  blocks) and managed-memory allocation (`gpu_alloc`). Acceptance:
  `./wbuild cuda_test` — `gpu for` vector add + `kernel`/`launch` saxpy,
  verified against CPU results (reduction/atomics moved to Stage 4).
- **Stage 4 — quality**: A2 virtual-register emission, explicit memory API,
  `gpu float*` types, error handling for `CUresult` codes, multi-GPU device
  selection.
- **Someday**: tile semantics (M3), shared-memory staging, `cuBLAS` interop via
  `c_import` (host-callable GEMM without writing kernels), SASS study
  (`cuobjdump -sass` on our PTX; CuAssembler experiments), fatbin embedding of
  pre-JIT'd cubins alongside PTX.

## Execution notes (Stages 2–3, as built)

- **Mixed-mode emission.** There is no `cuda` CLI target: a program is host
  x64 code with device bodies. `kernel` bodies and `gpu for` bodies compile
  with `target_isa == 3`, routing every emit helper in
  `code_generator/x86.w`/`sse.w` to a `ptx_*` twin in `code_generator/ptx.w`
  that appends PTX **text** to a module buffer instead of bytes to `code`.
  Host and device instruction streams never interleave, so the single-pass
  model needs no backpatching across the boundary.
- **A1 register model.** `%ax/%bx/%cx` (.b64) mirror eax/ebx/scratch,
  `%fa/%fb`/`%da/%db` mirror xmm0/xmm1 at each float width, `%w0` stages
  32-bit transfers, `%p` holds compare results. The W evaluation stack is a
  4 KB `.local` array converted once with `cvta.local.u64`, so `%sp`/`%bp`
  hold generic addresses and every load/store — stack, parameter or user
  pointer — is a plain generic `ld`/`st` (`&local` keeps working; no
  `cvta.to.global` needed). W `int` is `.s64`, pointers `.u64`, and the
  module header is `.version 6.0 / .target sm_52 / .address_size 64`.
- **Parameters as locals.** Every kernel parameter is `.param .u64 p0..pN`
  (one 8-byte cell each; float32 rides as raw bits, the host convention).
  The prologue `ld.param`s each into the accumulator and pushes it,
  declaring the name as an ordinary `'L'` local, so the existing addressing
  machinery is unchanged.
- **`gpu for` capture layout.** Captures live at fixed offsets below `%bp`
  (capture k at `[%bp - (k+1)*8]`, slot 0 = the range bound, 32 slots
  reserved), so a capture discovered mid-body never invalidates addresses
  already emitted — that is what makes single-pass outlining work. Captured
  scalars are device-local copies: writes do not propagate back (a Stage 4
  diagnostic candidate). Pointers must be device-accessible (`gpu_alloc`).
- **Async launches.** `launch` and `gpu for` enqueue and return;
  `gpu_sync()` (cuCtxSynchronize) is the synchronization point. The host
  must not touch managed buffers while a kernel using them is in flight.
  This is deliberate: W has no async constructs yet, and the explicit sync
  point should later align with the `thread`/`lock` design
  (`docs/parallel.txt`).
- **Device subset.** No function calls, globals, strings, `new`/containers,
  limb/bit intrinsics, `raw_asm`, `defer`, `?`, `yield`, or `return` inside
  `gpu for` (bare `return` is fine in `kernel` bodies). Bounds checks are
  silently off in device code (the trap path calls host runtime helpers);
  float compares are ordered (NaN → false), the wasm divergence model.
  Diagnostics are frozen by `cuda_diagnostics_test`.
- **Testing without a GPU.** `gpu_ptx_emit_test` (in the default umbrella)
  prints/greps the embedded module; `cuda_test` (opt-in, like `cuda_smoke`)
  runs vector add + saxpy on real hardware. The host launch plumbing
  (module text, kernel name, grid/block, kernelParams layout) was verified
  GPU-less against a logging stub libcuda during development.

## Execution notes (Stage 4 slice, as built)

- **Atomics** (`grammar/atomic_builtin.w`): device-only, generic-address
  `atom` ops — `atom.add.u64`/`atom.min.s64`/`atom.max.s64` on `int*`,
  `atom.add.f32` on `float32*` (float64 atomics need sm_60; min/max are
  int-only at sm_52). Each returns the pre-update value. The target must be
  a pointer-TYPED expression (W's `&` and pointer arithmetic yield untyped
  constants) referencing device-accessible memory — generic `atom` on a
  `.local` stack slot is undefined.
- **Device limb/bit intrinsics**: mul_hi/mul_wide/add_carry and
  shr/rotl/rotr/popcount/clz/ctz keep the host contract (low 32 bits
  unsigned, zero-extended results, counts mod 32) via 64-bit masked
  arithmetic plus native `popc`/`clz`/`brev` and the sm_32+ `shf.*.wrap`
  funnel-shift rotates; the register model gained `%w1` for those.
  `cuda_test` cross-checks device results against the same intrinsics run
  natively on the host.
- **`range(start, end)`**: capture slot 0 = start, slot 1 = end (parse
  order; the one-arg form keeps slot 0 = end and stays byte-identical), the
  device prologue adds start to the thread index, and the host passes
  `end - start` to the unchanged `__w_gpu_launch`. Step arguments still
  error.
- **Capture-write diagnostic**: scalar captures come back const-qualified,
  so the existing "assignment to const" enforcement rejects writes to the
  device-local copy. Pointer captures stay writable-through (and
  reassignable — a documented caveat: const-wrapping a pointer record would
  break element-type lookup); bool/var are exempt (their coerce paths
  re-promote const records). `type_float_kind` now strips qualifiers so
  const float reads keep the float pipeline.
- **Explicit memory**: `gpu_device_alloc` + `gpu_memcpy_to`/`gpu_memcpy_from`
  use the blocking default-stream cuMemcpy forms, which order after prior
  launches — a copy-back implicitly waits for the kernel, so the explicit
  path needs no `gpu_sync()`. A program with no kernels (memory API only)
  gets an empty embedded module and the runtime skips `cuModuleLoadData`.

## Execution notes (runtime: device selection + errors)

All in `lib/cuda.w`; no compiler change.

- **Device selection**: `gpu_device_count()` never exits (cuInit +
  cuDeviceGetCount; 0 when the driver fails or sees no device, e.g.
  `CUDA_VISIBLE_DEVICES=`). Lazy init uses ordinal 0, or
  `W_GPU_DEVICE=<n>` when set and non-empty. `gpu_set_device(n)` may be
  called at any time — before first use or to switch later — and is lazy:
  it records the ordinal, and the next GPU call creates that device's
  context (cuCtxCreate + JIT module load) on first use or makes the
  existing one current (cuCtxSetCurrent). Contexts and modules are kept
  per ordinal for the life of the process, and the kernel-handle cache is
  keyed by (name, device), so switching back and forth is correct and
  cheap. `gpu_get_device()` reports the current ordinal (-1 if none is
  usable). Out-of-range ordinals are fatal with a clear message
  (`cuda error: gpu_set_device(4): device ordinal 4 is out of range: 1
  CUDA device(s) visible (valid: 0..0)`, likewise for a bad or
  non-numeric `W_GPU_DEVICE`); `gpu_try_set_device(n)` returns
  CUDA_ERROR_INVALID_DEVICE (101) instead. `gpu_available()` now probes
  the selected ordinal; a bad `W_GPU_DEVICE` reads as unavailable (with a
  stderr note), so the tensor CPU fallback still applies.
- **Per-device caveats**: allocations, copies, frees, launches and
  `gpu_sync()` act on the device current when they run (every entry point
  now calls the init/make-current check, which is one load on the fast
  path). Free and copy a buffer with its owning device current; peer
  access and multi-device streams are not wired. The runtime assumes one
  host thread (contexts are current per thread). Only single-GPU hardware
  was available, so the multi-device switch was exercised as
  device 0 → device count-1 → device 0 on one GPU.
- **Errors**: the plain API still exits, but the message now names the
  code: `cuda error 2 CUDA_ERROR_OUT_OF_MEMORY (out of memory) at
  cuMemAlloc` (cuGetErrorName/cuGetErrorString). Non-exiting variants:
  `gpu_try_alloc`/`gpu_try_device_alloc` (0 on failure),
  `gpu_try_memcpy_to`/`gpu_try_memcpy_from`/`gpu_try_free`/`gpu_try_sync`/
  `gpu_try_set_device` (return the CUresult). Every failing call records
  its code for `gpu_last_error()` — a peek, not reset by later successes;
  `gpu_clear_error()` resets. `gpu_error_name(code)`/`gpu_error_string(code)`
  fall back to `CUDA_ERROR_UNKNOWN_CODE` / "unrecognized CUresult code".
  Try variants never exit even when init fails (no driver device → 100
  CUDA_ERROR_NO_DEVICE). Launches stay fatal on launch-configuration
  errors, but a kernel fault is async: it is reported by the next
  `gpu_try_sync()`/`gpu_sync()` or blocking copy, and sticky errors such
  as CUDA_ERROR_ILLEGAL_ADDRESS (700) leave that context unusable.
- **Tests**: `cuda_runtime_gpu_test` (opt-in, `tests/cuda_runtime_gpu.w`
  + sidecar) checks count ≥ 1, set_device(0) + launch, device switching,
  a 1 PiB try-alloc returning 0 with CUDA_ERROR_OUT_OF_MEMORY and the
  program continuing (copies, launches), an async fault surfacing at
  `gpu_try_sync`, the fatal set_device/OOM/`W_GPU_DEVICE` messages, and a
  `CUDA_VISIBLE_DEVICES=` step where count is 0 and every try variant
  fails gracefully. `cuda_runtime_compile_test` (in `tests`) only
  compiles it: running any lib.cuda program needs libcuda.so.1 at load
  time, which default CI machines lack.

## Execution notes (cubin embedding)

Opt-in pre-compiled GPU code, so a program can skip the driver's PTX JIT at
startup (follow-up to issue #28). The default compile is unchanged: no
external tool runs, no cubin is embedded, and the PTX is JIT-loaded as
before.

- **Two-step, user-driven.** The compiler never spawns processes (W's
  identity is "no external toolchain", and the compiler has no process
  facility on every host it runs on), so the cubin is built by the user
  from the `--ptx` dump and handed back with `--cubin-file=<path>`:

  ```sh
  bin/wv2 x64 prog.w -o prog --ptx=prog.ptx
  ptxas -arch=sm_89 prog.ptx -o prog.cubin
  bin/wv2 x64 prog.w -o prog --cubin-file=prog.cubin
  ```

  `tools/cuda/build_cubin.sh <sm_XX|native> prog.w prog` scripts exactly
  this (`native` asks `nvidia-smi` for GPU 0's compute capability).
- **Embedding.** `ptx_finish_cubin` (`code_generator/ptx.w`, run right after
  `ptx_finish_module`) synthesizes `char* __w_cubin_module()` for every
  program that imports `lib.cuda` (whose prototype declares it): an 8-byte
  little-endian image length followed by the cubin bytes, inline in the code
  stream like the PTX text — or just a zero length without `--cubin-file`
  (also when the program has no kernels). The PTX module stays embedded as
  the fallback.
- **Compile-time checks.** The file must be an ELF with `e_machine ==
  EM_CUDA` (190) — PTX text, host objects and fatbins are rejected — and
  every `.entry` name in this program's PTX must appear in the cubin's
  string table: a cubin built from an older dump would otherwise load and
  then fail at `cuModuleGetFunction`, where no fallback applies (a stale
  cubin whose kernels merely changed bodies or signatures is not caught;
  rebuild it whenever the kernels change). Errors are command-line
  diagnostics (`--cubin-file='<path>': ...`, `<command-line>` in `--json`).
- **Runtime.** `__w_gpu_load_module` (`lib/cuda.w`, called from
  `__w_gpu_init`) copies the image to a heap buffer (the inline bytes sit at
  an arbitrary code address) and tries `cuModuleLoadData` on it; on any
  error — typically `CUDA_ERROR_NO_BINARY_FOR_GPU` (209) for a cubin built
  for a different SM major — it loads the PTX instead, whose errors stay
  fatal. `gpu_module_source()` reports what loaded: 0 nothing yet, 1 PTX,
  2 cubin. SASS is only compatible within one major architecture, so a
  distributed binary should keep relying on the PTX for other GPUs.
- **Tests.** `cuda_cubin_embed_test` (default umbrella, GPU-less) compiles
  `tests/cuda_cubin_gpu.w` with a fake EM_CUDA ELF from
  `tools/cuda/fake_cubin.sh`, checks the blob lands in the binary and not in
  the default build, and freezes the stale/not-CUDA/not-ELF/missing-file
  errors. `cuda_cubin_test` (opt-in: GPU + `ptxas`) runs the program built
  with a native cubin (`source=cubin`), a wrong-arch cubin (falls back,
  `source=ptx`) and no cubin.
- **Measured** (RTX 4080 SUPER, sm_89, `tests/tensor_gpu.w` — the 17
  `lib/tensor.w` kernels, 52 KB PTX / 61 KB cubin; whole-process wall time,
  min of 7): PTX with the driver's JIT cache warm 220 ms, cubin 218 ms;
  with `CUDA_CACHE_DISABLE=1` PTX 302 ms, cubin 220 ms. So the cubin saves
  the cold-JIT cost (~80 ms here, growing with kernel count) on a fresh
  machine or after a driver update; with a warm `~/.nv/ComputeCache` the two
  are indistinguishable.

## Execution notes (cuBLAS interop)

Follow-up to issue #28 (workstream C): vendor GEMM as an opt-in fast
path, fenced off so nothing that does not ask for it changes behavior.

- **Run-time loading, not `c_lib`.** `c_lib "libcublas.so.12"` would add
  a DT_NEEDED entry and `extern` binds eagerly through GLOB_DAT GOT
  slots, so on a machine without the CUDA *toolkit* (cuBLAS is not part
  of the driver) the dynamic loader would refuse to start the program
  before `main` — no probe could run. `lib/dlcall.w` instead needs only
  `libdl.so.2` at load time and `dlopen`s libcublas lazily (sonames .12,
  .13, .11, then the unversioned symlink); a missing library, symbol,
  GPU, or failing `cublasCreate_v2` makes `cublas_available()` return 0.
  The program still needs `libcuda.so.1` via `lib/cuda.w`, the floor
  every GPU program already has.
- **Calling dlsym pointers.** W function pointers use W's stack
  convention, so a dlsym result cannot be called directly.
  `dl_trampoline(sym, nargs, ret32)` writes a tiny x64 stub into an
  mmap'd page (RW, then mprotect RX) that re-loads W's stack arguments
  into rdi..r9 plus a 16-byte-aligned stack tail, zeroes al (variadic
  safe), calls the symbol, and sign-extends a C `int` result;
  `dl_trampoline_argv` + `dl_call` is the same with the arguments read
  from an `int*` array. Integer/pointer arguments only — cuBLAS passes
  alpha/beta by pointer, so that is enough. `tests/dlcall_test.w`
  (`dlcall_test`, default umbrella via tests_x64, no GPU needed) checks
  missing-library/symbol probes and register + stack argument order
  against libc (`strlen`, `abs`, 8- and 9-argument `snprintf`).
- **Why the argv form exists.** A `type ... = fn(...)` alias with more
  than 10 parameters overflows a fixed 10-slot buffer in
  `grammar/type_alias_declaration.w` (heap corruption, SIGSEGV later
  in the compile; logged in ai_tooling_next_steps.md). The 14-argument
  gemm entry points therefore go through `dl_call`.
- **c_import was tried first**: `cublas_v2.h` hits host_defines.h's
  "UNKNOWN COMPILER" `#error` (no `__GNUC__`); a wrapper header that
  predefines `__align__(n)` and `CUDARTAPI` imports cleanly (c_import.md,
  Known limitations). Not used: it would reintroduce DT_NEEDED and a
  hard-coded toolkit include path.
- **Context sharing.** cuBLAS runs on the runtime API, which binds to
  the driver context current on the calling thread and only falls back
  to the primary context when none is current. `cublas_init` runs
  `__w_gpu_init()` before `cublasCreate_v2`, so the `cuCtxCreate`
  context `lib/cuda.w` made current is the one cuBLAS uses: managed
  (`gpu_alloc`) and device (`gpu_device_alloc`) pointers are valid
  operands, and cuBLAS work is enqueued on the same legacy default
  stream as `launch`/`gpu for` — ordering needs no extra syncs and
  `gpu_sync()` covers it. No `lib/cuda.w` change was needed. Caveat:
  the context is current only on the thread that initialized the GPU
  (the main thread); calling from another thread would silently give
  cuBLAS the primary context, a different address space. Switching
  lib/cuda.w to `cuDevicePrimaryCtxRetain` + `cuCtxSetCurrent` would
  make both sides share the primary context on every thread.
- **Row-major vs column-major.** `cublas_sgemm_rm` / `cublas_dgemm_rm`
  take cblas-style row-major arguments; a row-major matrix is its own
  column-major transpose, so C = op(A) op(B) is issued as
  C^T = op(B)^T op(A)^T: operands, trans flags and leading dimensions
  swap, and so do m and n. alpha/beta live in a module scratch cell
  (host pointer mode; cuBLAS reads them before returning).
- **tensor integration is opt-in.** `lib/tensor.w` gained a null
  `tensor_matmul_hook` consulted on the GPU path of
  `tensor_matmul2`/`_tn`/`_nt` (a null check before the tiled launch;
  tensor.w never imports cuBLAS code). `import lib.tensor_cublas` +
  `tensor_use_cublas()` installs a cublasSgemm hook — which every
  `lib/autograd.w` linear layer then uses — and
  `tensor_disable_cublas()` restores the tiled kernels. Results agree
  with the tiled kernel to FP32 rounding, not bit for bit (default math
  mode, no TF32).
- **Tests and numbers.** `cublas_test` (opt-in, needs GPU + toolkit;
  `tests/cublas_gpu.w.wbuild`) checks all four trans combinations,
  alpha/beta, dgemm, and the tensor hook on non-square, non-tile-multiple
  shapes against a float64 CPU reference (max abs error <= 1e-3), and
  checks the probe returns 0 under `CUDA_VISIBLE_DEVICES=`.
  `cublas_compile_test` compiles it in the default umbrella. Informational
  benchmark on an RTX 4080 SUPER (driver 580, libcublas 12.9),
  `tensor_matmul2` square products, per call after warm-up:
  256^3 tiled ~22-25 us vs cuBLAS ~6-7 us (3-3.5x); 1024^3 ~790-870 us
  (~2.5 TFLOP/s) vs ~76-81 us (~27 TFLOP/s, ~10-11x); 2048^3 ~6.2-7.0 ms
  (~2.6 TFLOP/s) vs ~0.5 ms (~34 TFLOP/s, ~13x).

## Open questions

- CI on machines without an NVIDIA GPU: `./wbuild cuda_smoke` needs a driver and a
  GPU, so it stays out of the default `./wbuild tests` for now. Does Stage 3 need
  a CPU fallback (run the outlined loop body on CPU when `cuInit` fails) so
  `cuda_test` can join the default suite?
- ~~H3 sidecar vs going straight to H1 dynamic linking~~ — resolved: went
  straight to H1; no compiled-C helper in the repo.
- Float support: W's type table today is integer/pointer-centric; kernels
  without `float`/SSE support on the host side are of limited use. Does float
  land as part of x64 work or as part of this project? (`cuda_smoke` sidesteps
  this by storing IEEE-754 bit patterns in integer memory.)
- Which GPU generation is the floor? PTX target directive (e.g.
  `.target sm_70`) affects available instructions. (`cuda_smoke` uses
  `.target sm_52`, which the driver JIT accepts on newer parts.)

## References

- PTX ISA reference (v9.3): https://docs.nvidia.com/cuda/parallel-thread-execution/
- CUDA compiler driver (nvcc) docs: https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/
- CUDA Driver API — module loading (`cuModuleLoadData`, accepts PTX text):
  https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__MODULE.html
- CUDA Driver API — execution (`cuLaunchKernel`):
  https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__EXEC.html
- Driver vs Runtime API: https://docs.nvidia.com/cuda/cuda-runtime-api/driver-vs-runtime-api.html
- NVRTC (runtime CUDA C++ compilation): https://docs.nvidia.com/cuda/nvrtc/
- libNVVM / NVVM IR spec: https://docs.nvidia.com/cuda/libnvvm-api/ ,
  https://docs.nvidia.com/cuda/nvvm-ir-spec/
- PTX Compiler API (PTX->cubin without module load):
  https://docs.nvidia.com/cuda/ptx-compiler-api/
- CUDA binary utilities / per-arch SASS instruction lists:
  https://docs.nvidia.com/cuda/cuda-binary-utilities/
- Triton repo and docs: https://github.com/triton-lang/triton ,
  https://triton-lang.org/main/index.html
- Triton paper (Tillet, Kung, Cox — MAPL 2019):
  https://eecs.harvard.edu/~htk/publication/2019-mapl-tillet-kung-cox.pdf
- Triton compilation stages writeup:
  https://pytorch.org/blog/triton-kernel-compilation-stages/
- Direct-PTX emitters without LLVM: https://github.com/patrick-toulme/pyptx ,
  https://crates.io/crates/oxicuda-ptx
- SASS assemblers (research): https://github.com/NervanaSystems/maxas ,
  https://github.com/daadaada/turingas , https://github.com/cloudcores/CuAssembler
- Device-side CUDA C++ abstractions for comparison: CUB
  (https://nvidia.github.io/cccl/unstable/cub/index.html), Cooperative Groups
  (https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cooperative-groups.html)
- Host-callable libraries for later interop: cuBLAS
  (https://docs.nvidia.com/cuda/cublas/), cuDNN
  (https://docs.nvidia.com/deeplearning/cudnn/latest/)
- Contrast: LLVM-based GPU language backends — gpucc
  (https://doi.org/10.1145/2854038.2854041), Julia CUDA.jl
  (https://cuda.juliagpu.org/stable/development/kernel/)
