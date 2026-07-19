# Toward a torch-compatible system

Staged plan for growing the CUDA backend (docs/projects/cuda.md, Stages
0-3 shipped) into a PyTorch-shaped compute stack: GPU tensors, the ops a
training loop needs, and eventually weight-level interop with real torch
models. "Torch-compatible" here means the *capability* stack (tensor ->
ops -> autograd -> layers -> weight interop), not API emulation — W is
not growing a Python binding.

**Status: Stages 1-3 implemented** (this PR): the
`gpu_available()` runtime probe, and `lib/tensor.w` — a GPU tensor type
on CUDA managed memory with elementwise ops, ReLU, an atomic-reduction
`tensor_sum`, and a one-thread-per-output-element `tensor_matmul2`,
every op with a CPU fallback path when no GPU is usable. Stages 4-6 are
sketches.

## Where this builds from

- `kernel` / `launch` / `gpu for` compile W device bodies to PTX with no
  toolkit dependency (cuda.md Stage 2-3); `lib/cuda.w` provides managed
  memory (`gpu_alloc`), async launches and `gpu_sync()`, and CUresult
  checking that prints and exits on driver errors.
- `lib/ndarray.w` provides the CPU substrate: `ndf` rank 1-4 float32
  arrays, checked accessors, elementwise in-place ops, naive `matmul2`
  (docs/projects/ndarray.md, Stages 1-2).
- The device subset excludes function calls, globals, strings,
  containers and `new` — device code is loops and arithmetic over
  captured scalars and pointers, which is exactly what tensor kernels
  need.

## Stage 1 — reduction primitive + GPU probe (implemented)

Reductions (sum, mean, losses, norms, softmax denominators) were
inexpressible: `gpu for` captures are device-local copies, so
accumulating through a captured scalar is silently lost, and there was
no atomic. Two pieces:

- **`atomic_add(int*/float32* p, v)`** (plus `atomic_min`/`atomic_max`
  on `int*`) — landed separately via cuda.md's Stage 4 slice
  (`grammar/atomic_builtin.w`): device-only intrinsics, contextual and
  shadowable, parsing as ordinary calls so the parser-generator grammar
  is untouched. They emit PTX `atom.*` through the generic-address
  path and return the pre-update value (which a pure reduction simply
  discards). Frozen in `gpu_ptx_emit_test`.
- **`gpu_available()`** in `lib/cuda.w` — a cached `cuInit` probe that
  reports whether a usable driver+device exists *without* the
  exit-on-error behavior of the launch path. This is the branch point
  for every CPU fallback in Stage 2. Caveat: a binary that imports
  `lib.cuda` still hard-requires `libcuda.so.1` at load time (eager
  dynamic linking), so the fallback covers "driver present, no usable
  GPU", not "no driver installed". Lifting that needs lazy binding —
  noted under cuda.md Stage 4.

Not done here (Stage 4 quality items that unblock *faster* reductions,
not *correct* ones): shared-memory block reduction (`.shared` emission),
warp shuffles, non-fetching `red.*` forms. A per-element global atomic
is hardware-accelerated on sm_70+ and is fine at v1 scale.

## Stage 2 — GPU tensor type (implemented)

`lib/tensor.w` (x64-only, imports `lib.cuda` + `lib.ndarray`): a
`tensor` struct mirroring `ndf`'s shape fields but carrying a raw
`float*` into CUDA managed memory — one pointer valid on both host and
device, so host-side asserts, fills and verification read the same
buffer the kernels write. There is no pointer-to-slice construction in
W (docs/projects/arrays_slices_strings.md leaves it warned-and-manual),
so the tensor does not reuse the `float[]`-backed `ndf` directly;
instead `tensor_from_ndf` / `tensor_to_ndf` copy across — the moral
equivalent of torch's `.to("cuda")` / `.to("cpu")`.

- Constructors `tensor_new1/2` (zeroed), `tensor_full1/2`,
  `tensor_from_ndf`, `tensor_to_ndf`, `tensor_free`; allocation goes to
  `gpu_alloc` when `gpu_available()` and to `malloc` otherwise
  (`on_gpu` records which allocator owns the buffer).
- Ops, each `gpu for` + `gpu_sync()` on the GPU path and a plain loop on
  the CPU path: `tensor_fill`, `tensor_add_into`, `tensor_mul_into`,
  `tensor_add_scalar_into`, `tensor_mul_scalar_into`,
  `tensor_relu_into`, `tensor_sum` (Stage 1 atomic reduction),
  `tensor_matmul2` (Stage 3). Raw pointers are hoisted into locals
  before each `gpu for` — required by the capture model (a captured
  struct pointer would dereference host heap on device) and it keeps
  the device body inside the supported subset.
- **Sync policy**: v1 ops are synchronous (each GPU op ends with
  `gpu_sync()`), trading launch overlap for a simple aliasing story.
  Same-stream ordering would already allow op-to-op chaining without
  syncs; exposing that (and torch-style async with explicit sync at
  read-back) is Stage 4 work.

Testing: `tensor_compile_test` (in the default umbrella) compiles the
GPU test GPU-less, catching device-subset regressions in CI;
`tensor_gpu_test` (opt-in, next to `cuda_test`) runs the full surface
on real hardware and cross-checks every op against the `ndf` CPU
implementations.

## Stage 3 — matmul (implemented, naive)

`tensor_matmul2`: one device thread per output element, each running
the k-loop (`acc += a[row*k+i] * b[i*n+col]`) — the textbook naive
kernel, correct at any shape, memory-bound and unblocked. The CPU
fallback is the same triple loop on raw pointers. Cross-checked against
`ndf_matmul2` in `tensor_gpu_test`.

Deliberately not here:

- **Tiled/shared-memory matmul** — needs `.shared` support in the PTX
  emitter plus a block-cooperative programming surface (`gpu for` hides
  the block structure). The natural shape is cuda.md's M3 tile
  semantics; do the emitter work first (Stage 4 below).
- **cuBLAS interop** — `c_import` + `libcublas.so` would give
  vendor-speed GEMM and a perf oracle, but it drags in the CUDA
  toolkit (cuBLAS does not ship with the driver), against the
  "driver-only at runtime" line the whole backend holds. If it lands,
  it lands opt-in, clearly fenced, and primarily as a *test oracle*.

## Stage 4 — sketch: performance + async (next)

- Shared memory (`.shared` declarations + `bar.sync`) in the PTX
  emitter; then a tiled matmul and a block-level `tensor_sum` (one
  `red` per block instead of per element).
- Remove per-op `gpu_sync()`: ops enqueue on the single stream,
  `tensor_to_ndf`/`tensor_sum`/accessor reads become the sync points —
  torch's actual execution model.
- A2 virtual-register PTX emission (cuda.md Stage 4) once op kernels
  are hot enough for the driver JIT's cleanup of the A1 stack traffic
  to matter.
- float16/bf16 storage (`.f16` loads widening to f32 math — W already
  has storage-only float16 on the host).

## Stage 5 — sketch: autograd + layers

Tape-based reverse mode as a pure library (`lib/autograd.w`): each op
records (op-id, input tensors, saved scalars) on a tape; `backward()`
walks it in reverse dispatching to backward kernels (all expressible
with the Stage 1-3 surface: elementwise chains, matmul with swapped
operands, atomic-add scatter for broadcast grads). Then `lib/nn.w`:
linear, relu, softmax-cross-entropy, SGD — and an MNIST-scale training
loop as the acceptance test. No compiler work expected in this stage.

## Stage 6 — sketch: torch weight interop

Read/write the **safetensors** format (a JSON header + contiguous
little-endian tensor data — well within `lib/json` + file I/O):
`tensor_load_safetensors` mapping f32 tensors into `tensor`s, so W can
run inference with real PyTorch-trained weights. ONNX graph execution
is explicitly out of scope until the op surface is much wider.

## Open questions

- Should `tensor` unify with `ndf` once pointer-to-slice construction
  exists? (Then `ndf` gains an `on_gpu` bit and the copy pair
  disappears.)
- Reduction surface: keep exposing raw atomics, or add a
  `gpu reduce(+)` construct once shared-memory reductions exist?
- Where does the `float64` twin land — mirror `lib/ndarray64.w` with a
  `tensor64`, or wait for generics (docs/projects/generics.md)?

## References

- docs/projects/cuda.md — the backend this builds on (Stage 4 list).
- docs/projects/ndarray.md — the CPU substrate and its non-goals.
- PTX ISA: red/atom — https://docs.nvidia.com/cuda/parallel-thread-execution/#parallel-synchronization-and-communication-instructions-red
- safetensors format — https://github.com/huggingface/safetensors#format
- micrograd (tape autograd in ~100 lines, the Stage 5 shape) —
  https://github.com/karpathy/micrograd
