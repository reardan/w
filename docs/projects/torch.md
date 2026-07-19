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
- **A2 step 1 landed — the push/pop peephole** (`ptx_peephole` in
  `code_generator/ptx.w`): a post-pass over each finished kernel body
  converts every push/pop pair whose span stays inside one basic block
  into moves through depth-indexed virtual registers (`%v<N>`),
  deleting the pair's four `.local` stack instructions and rewriting
  the `[%sp+K]` slot references whose distance to `%sp` changes (only
  references to slots older than the eliminated word shift by 8).
  Anything unrecognized bails to the untransformed body. Measured on
  the RTX 4080: kernels went from ~37 to ~230–270 GFLOP/s (~6–7x) —
  naive 1024³ matmul 59ms → 8.0ms — and the tiled matmul now beats
  naive at 4096³ (615ms vs 705ms) where L2 stops covering, exactly the
  memory-hierarchy win that was invisible pre-peephole (at 1024³
  everything L2-caches and naive still edges tiled).
- **A2 step 2 landed — local promotion** (`ptx_promote` in
  `code_generator/ptx.w`): a second post-pass, run before the
  push/pop peephole, promotes every stack slot (declared local,
  kernel-parameter spill, `gpu for` capture cell) whose every
  appearance is a recognized load/store into a `%l<N>` register,
  re-widening sub-word stores with the slot's load suffix so
  truncate-then-reload semantics survive bit for bit. Escaped
  addresses (`&local` into an intrinsic, aggregates) bail the kernel;
  a written capture (pointer reassignment) or suffix-mismatched slot
  just stays in memory. In the tensor kernels this empties the body of
  `.local` traffic entirely. Measured on the same RTX 4080 SUPER
  (vs the step-1 numbers): naive 1024³ matmul 7ms → 1ms, naive 4096³
  466ms → 86ms, tiled 4096³ 604ms → 48ms (~2.9 TFLOP/s, ~12x), 4M
  `tensor_sum` 410us → 320us; MNIST end-to-end barely moves
  (3.0s → 2.9s) because at that size the loop is launch/host-bound,
  and all GPU tests keep bit-identical numerics.
  `tests/gpu_promote_gpu.w` pins the risky edges (sub-word locals,
  reassigned captured pointer). With both steps in, full A2 (grammar
  rules returning register names) looks unnecessary — the remaining
  distance to peak is algorithmic (deeper tiling/vectorized loads) and
  launch overhead, not the stack-machine encoding.

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
- ~~A2 virtual-register PTX emission (cuda.md Stage 4)~~ — done as
  two text-level post-passes: the push/pop peephole (step 1, ~6–7x)
  and local promotion (step 2, a further ~5–12x; see the status
  section above). The full grammar-contract A2 is retired: kernel
  bodies now carry no `.local` traffic to eliminate.
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

## Micro-GPT — transformer training capstone (implemented)

`tests/gpt_train_gpu.w`: a 2-layer, 4-head, 64-dim decoder-only
transformer (token + learned positional embeddings, pre-LN causal
attention, relu MLP, linear head; ~112K params) trains char-level
next-token prediction on tiny-shakespeare
(`tools/fetch_shakespeare.sh` → `bin/shakespeare.txt`, the nanoGPT
dataset) with AdamW. Loss falls 4.17 (= ln 65, the uniform-head
sanity floor asserted at step 1) to ~2.39 in 500 steps — through the
~2.45 bigram entropy — in ~17s on the RTX 4080 SUPER, then
greedy-samples 150 chars of word-shaped output. Deterministic: fixed
seeds + k-ascending matmuls make the run bit-reproducible, and the
CPU-fallback path (20 steps, same binary) matches the GPU step-1 loss
exactly. Opt-in `gpt_train_gpu_test` + default-umbrella
`gpt_train_compile_test`.

What it took (and all it took):

- Four autograd ops in `lib/autograd.w`, finite-difference-tested in
  `tests/autograd_gpu.w` like the rest: `ag_embedding` (row gather,
  scatter-add backward; ids ride the node's labels field),
  `ag_layernorm` (a two-input `ag_layernorm_core` for gamma·xhat
  composed with the existing `ag_add_row` for beta; backward
  recomputes row stats), `ag_softmax_causal` (mask + row softmax
  fused, masked entries exactly 0, backward off the node's own
  output), and `ag_matmul_nt` (q @ k^T without materializing the
  transpose; backward via the existing plain/_tn kernels).
- `nn_adamw` state + `nn_adamw_step` in `lib/nn.w` (bias-corrected,
  decoupled weight decay; host loop, the ag_softmax_ce precedent).
- Composition patterns, no compiler work: per-head weight tensors
  (concat-free multi-head — per-head output projections summed),
  positional embeddings as an `ag_embedding` gather of wpe (so
  shorter sampling contexts reuse the training path), matmuls on the
  GPU tensor kernels, elementwise glue host-side over managed memory.

Known limits, deliberately kept: batch=1 per step (grad accumulation
across multiple backwards on one tape would double-count earlier
windows — a per-window tape or persistent grad buffers is the fix if
bigger batches are ever needed); host-side LN/softmax sync per call,
so the step is launch/host-bound (~30ms) rather than kernel-bound —
device-side fused kernels are the next lever if this becomes a
training platform rather than a capability proof.

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
