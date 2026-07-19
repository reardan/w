# Toward a torch-compatible system

Staged plan for growing the CUDA backend (docs/projects/cuda.md, Stages
0-3 shipped) into a PyTorch-shaped compute stack: GPU tensors, the ops a
training loop needs, and eventually weight-level interop with real torch
models. "Torch-compatible" here means the *capability* stack (tensor ->
ops -> autograd -> layers -> weight interop), not API emulation — W is
not growing a Python binding.

**Status: Stages 1-3 implemented** (#342): the
`gpu_available()` runtime probe, and `lib/tensor.w` — a GPU tensor type
on CUDA managed memory with elementwise ops, ReLU, an atomic-reduction
`tensor_sum`, and a one-thread-per-output-element `tensor_matmul2`,
every op with a CPU fallback path when no GPU is usable.

**Stage 5/6 groundwork landed** (#347, five parallel workstreams): the
op surface a training loop needs (sub, axpy, `tensor_matmul2_tn`/`_nt`
transposed matmuls, row-broadcast bias add, row/col reductions,
`tensor_relu_grad_into`, host-side `tensor_randn`); `lib/autograd.w` —
the Stage 5 tape with all backward rules implemented (matmul via the
transposed variants, relu via the grad mask), finite-difference-tested;
`lib/mnist.w` — IDX loading into `ndf`/`ndi`; `lib/safetensors.w` —
the Stage 6 F32 read/write at the `ndf` level; and device-only
`gpu_exp`/`gpu_log` builtins (`ex2.approx.f32`/`lg2.approx.f32`,
`grammar/gpu_math_builtin.w`) so softmax can later move on-device.
`lib/nn.w` (linear layer, fused `ag_softmax_ce`, SGD) and the
end-to-end training test (`tests/nn_train_gpu.w`: synthetic 4-class
8-D clusters, MLP 8→32→4, asserts loss < 0.2 and accuracy > 0.95 on
both the GPU and CPU-fallback paths) also landed in #347.

**Stage 5 and 6 acceptance met, Stage 4 implemented** (July 2026
follow-up):

- *Stage 5 acceptance*: `tests/mnist_train_gpu.w` trains 784→64→10 on
  10000 real MNIST images (`tools/fetch_mnist.sh` pulls the IDX files
  into `bin/mnist/`) and reaches 0.9069 accuracy on the full held-out
  t10k set — identical on the GPU and CPU-fallback paths (all three
  matmul paths accumulate k-ascending, so the whole training run is
  bit-reproducible across paths). Opt-in `mnist_train_gpu_test`; GPU
  run ~3.4s, CPU ~35s.
- *Stage 6 acceptance*: `tests/torch_infer_gpu.w` +
  `tools/train_mnist_torch.py`. A real PyTorch-trained MLP is checked
  in as `tests/data/mnist_mlp.safetensors` (125KB) in torch's NATIVE
  state_dict layout — the W side does the `(out,in)`→`(in,out)`
  transpose — with the oracle embedded (8 probe images, torch's
  logits, torch's accuracy). W's inference matches torch's logits to
  4e-6 and its t10k accuracy exactly (0.9470). Opt-in
  `torch_infer_gpu_test`; CI needs no Python.
- *Stage 4 shared memory*: `gpu_shared_f32(N)` / `gpu_barrier()`
  device builtins (`grammar/gpu_shared_builtin.w`, the atomic-builtin
  pattern; `.shared` + `cvta.shared` + `bar.sync` in
  `code_generator/ptx.w`). `tensor_sum` is now a block-tree reduction
  (one atomic per 256-element block): 4.6x faster (6.0ms → 1.3ms per
  4M-element sum on an RTX 4080). All three matmuls are 16x16
  shared-memory tiled kernels.
- *Stage 4 async*: per-op `gpu_sync()` is gone — ops enqueue on the
  default stream; the sync points are `tensor_sum` / `tensor_to_ndf` /
  `tensor_free` / `tensor_randn`, autograd's host-side rules, one
  drain at `ag_backward`'s exit, and the public `tensor_sync()` for
  direct `.data` access. MNIST training dropped 4.48s → 3.35s (-25%).
- **Perf finding (the next unlock)**: the tiled matmuls are currently
  perf-NEUTRAL (59ms naive vs 60ms tiled at 1024³, parity at 4096³
  too). A1 stack-machine codegen makes every kernel
  instruction-bound — ~37 GFLOP/s flat across sizes, ~1000x below the
  hardware, because each W operation moves through the `.local`
  evaluation stack. Tiling's memory-hierarchy win is invisible until
  **A2 virtual-register emission** (cuda.md Stage 4) lands; A2 is now
  the highest-value perf item in this project, ahead of any further
  kernel work.

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

## Stage 4 — performance + async (implemented; A2 is the remainder)

- ~~Shared memory (`.shared` declarations + `bar.sync`) in the PTX
  emitter; then a tiled matmul and a block-level `tensor_sum`~~ —
  done: `gpu_shared_f32`/`gpu_barrier` builtins, tiled kernels for
  all three matmul variants, block-tree `tensor_sum` (4.6x). The
  barrier is kernel-body-only in practice: under `gpu for`'s implicit
  bounds guard it would be divergent.
- ~~Remove per-op `gpu_sync()`~~ — done: ops enqueue; host boundaries
  sync (see the status section above for the exact sync-point list).
- A2 virtual-register PTX emission (cuda.md Stage 4): **now the
  critical path.** Kernels are instruction-bound at ~37 GFLOP/s from
  A1 `.local` stack traffic, which flattens every memory-hierarchy
  optimization; the tiled matmuls only start paying once values live
  in registers. (A middle step worth evaluating: a peephole pass over
  the emitted body that rewrites matched push/pop pairs with no
  intervening label/branch into moves through fresh virtual
  registers.)
- float16/bf16 storage (`.f16` loads widening to f32 math — W already
  has storage-only float16 on the host).

## Stage 5 — autograd + layers (implemented, acceptance met)

Tape-based reverse mode as a pure library (`lib/autograd.w`): each op
records (op-id, input tensors, saved scalars) on a tape; `backward()`
walks it in reverse dispatching to backward kernels (all expressible
with the Stage 1-3 surface: elementwise chains, matmul with swapped
operands, atomic-add scatter for broadcast grads). Then `lib/nn.w`:
linear, relu, softmax-cross-entropy, SGD. No compiler work was needed.
Acceptance: the real-MNIST training run (`tests/mnist_train_gpu.w`,
status section above).

## Stage 6 — torch weight interop (implemented, acceptance met)

Read/write the **safetensors** format (`lib/safetensors.w`: a JSON
header + contiguous little-endian F32 tensor data at the `ndf` level).
Acceptance: `tests/torch_infer_gpu.w` runs inference with real
PyTorch-trained weights from a checked-in fixture in torch's native
state_dict layout, matching torch's logits and accuracy (status
section above). ONNX graph execution is explicitly out of scope until
the op surface is much wider.

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
