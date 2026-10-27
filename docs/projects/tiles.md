# Tile programs (#480)

Tile programs extend the existing CUDA/PTX backend with operations on logical
tiles. A whole tile body is recorded in the production retained arena, analyzed,
and only then lowered to PTX and a host launch. This is a bounded tree-then-emit
region; ordinary function bodies, generic instantiation and unsupported deferred
syntax retain their existing compilation paths.

## Compilation contract

Both frontend entry modes, including `--streaming`, recognize the construct and
call the same tile parser. The surrounding frontend options are unchanged. The
compiler implementation uses pinned-seed-compatible W; tile syntax may be used
by leaf programs compiled with the newly bootstrapped compiler.

The representation is deliberately small:

1. `compiler/tile_ast.w` owns structured statements, expression operands, lexical
   binding identities, capture references and source locations. Its allocations
   use the retained session arena and follow checkpoint rollback. A retained
   statement owns the region through its tile payload.
2. `grammar/ast_tile.w` records a complete body without calling the backend.
   Unsupported constructs fail explicitly instead of falling back to an emitter.
3. `compiler/tile_analysis.w` checks types, shapes, scalar broadcasting, masks,
   captures, and uniform control flow. It does not allocate physical registers
   or emit instructions.
4. `compiler/tile_plan.w` assigns the element-to-thread mapping, per-dot shared
   buffers and block synchronization points in an arena-owned lowering plan.
   Planning emits no code, uses no parser state and is cached on the program;
   semantic reanalysis invalidates the cached plan. An arena rollback generation
   prevents reuse of a plan whose allocation was reclaimed by a checkpoint.
5. `code_generator/tile_ptx.w` consumes that plan to emit registers, shared
   declarations, staging and barriers. `code_generator/tile_host.w` evaluates
   the recorded header and captured host values and passes the planned thread
   count and logical width to the launch runtime.

The old GPU capture lookup and retained phase queues cannot simply be delayed:
lookup emits addresses, and nested phase queues assume draining during parsing.
Tile bindings and child expressions instead have independent owned storage.
Emission must remain possible after the parser's temporary storage is recycled.

## One-dimensional tiles

```text
gpu[1024] for tile in range(n):
	c[tile] = a[tile] + b[tile]
```

The width is a supported positive integer literal, at most 1024. It counts
logical elements per program, not threads. Each program uses 256 threads;
thread `t` processes positions `t + j*256` within its tile. Program `p` starts
at `p*width`. The grid covers `ceil(n/width)` programs; a nonpositive bound
launches nothing. Ceiling division does not add to the bound before dividing.

The first implementation supports contiguous float32 buffers and elementwise
arithmetic with scalar broadcasts. Rank-one accesses must use the region's
tile identifier directly (`a[tile]`); transformed indices such as `a[tile+1]`
are rejected. Masked loads return zero and masked stores do nothing. Addressing
uses element indices, not W's raw-byte pointer addition. Buffers must be disjoint
or alias at the same base for elementwise in-place updates. Cross-element
overlapping reads/writes are unsupported, including within a single program.
The current lowering runs each thread's body for successive 256-element chunks;
it does not implement whole-tile snapshots or inter-lane ordering for aliases.

Captures are values passed in kernel parameter cells. Device-accessible plain
float32 pointers and GPU-qualified float32 pointers follow the existing CUDA
memory model. The compiler cannot prove that an unqualified pointer names a
device-accessible allocation. Captured scalars cannot be assigned by the body.
Launches are asynchronous; call `gpu_sync()` before reading results on the host.

## Explicit matrix tiles

A width of one makes the range count program instances directly. The uniform
`tile_program_id()` gives the instance index. Matrix operations use explicit
origins, element strides and bounds:

```text
tile_load(pointer, row, column, row_stride, column_stride,
          rows_bound, columns_bound, rows, columns)
tile_zero(rows, columns)
dot(left_tile, right_tile)
tile_store(pointer, row, column, row_stride, column_stride,
           rows_bound, columns_bound, value)
```

Each static dimension is the literal 16, 32, 64 or 128, so shapes range from
16 by 16 to 128 by 128 and need not be square. A load zero-fills elements
outside either bound. A store masks both dimensions. `dot` multiplies an
m-by-k tile by a k-by-n tile and produces an m-by-n float32 tile. Elementwise
operators need equal shapes; only scalars broadcast. The physical
implementation stages both inputs in shared memory, synchronizes the block,
computes the product, and synchronizes before buffer reuse. Uniform range loops
allow a program to accumulate successive K tiles.

For example, a row-major product uses inferred tile locals (`:=`) and scalar
program coordinates. Each program computes a 128 by 128 output tile from
16-deep K slices:

```text
gpu[1] for tile in range(programs):
	int columns = (n + 127) / 128
	int row = tile_program_id() / columns * 128
	int col = tile_program_id() % columns * 128
	acc := tile_zero(128, 128)
	for int block in range((k + 15) / 16):
		left := tile_load(a, row, block * 16, k, 1, m, k, 128, 16)
		right := tile_load(b, block * 16, col, n, 1, k, n, 16, 128)
		acc += dot(left, right)
	tile_store(out, row, col, n, 1, m, n, acc)
```

A dot accumulates its K products in ascending K order with float32 fused
multiply-add. `acc += dot(a, b)` accumulates straight into `acc`; any other dot
starts from zero, and its result is then combined by the enclosing operator.
Results therefore need not be bit-identical to the hand-written kernel's single
running multiply-then-add accumulator. Compare with an appropriate
floating-point tolerance, or use small integer inputs, which stay exact.

All threads participate in cooperative operations, including threads whose
final output is out of bounds. There is no implicit whole-body lane guard.
Conditions and loop bounds must be block-uniform; tile-valued conditions are
rejected. Tensor-core instructions, asynchronous copies, software pipelining
and automatic tuning are outside the current implementation; the block shape is
chosen by the program's static tile dimensions.

## Lowering plan

`tile_program.plan` points to a `tile_lowering_plan` owned by the same retained
arena as the syntax tree. Vector tiles keep the original mapping: 256 threads,
`element = thread + pass * 256`, and `ceil(width/256)` passes.
`tile_plan_element`, `tile_plan_thread`, `tile_plan_pass`, `tile_plan_row` and
`tile_plan_col` expose this mapping for independent tests and future consumers.

Rank-two tiles of every shape use a 16 by 16 thread grid, `r = thread >> 4` and
`c = thread & 15`. Thread `(r, c)` holds a strided fragment of
`(rows/16) * (cols/16)` elements: fragment element `f = i * (cols/16) + j` is
logical element `(r + 16i, c + 16j)` (`tile_plan_fragments`,
`tile_plan_fragment_row`, `tile_plan_fragment_col`). Neighbouring threads touch
neighbouring columns, so global loads and stores coalesce, and every tile
of one shape, including a dot's result, shares the same layout. The emitter
gives each fragment element its own register, so a 128 by 128 accumulator is
64 registers per thread.

Each syntactic dot has a `tile_dot_plan` keyed by its owned node identity.
Plans follow evaluation order, including nested dots and both uniform branches.
A dot's plan records its m, k and n extents, whether it is fused into an
`acc += dot(...)` accumulation, the left and right shared buffers, and two
block barriers: inputs ready, and readers finished before the buffers are
reused. The left operand is staged row-major at offset zero and the right
operand directly after it. A buffer's row holds the tile's columns, padded by
16 words when the width is a multiple of 32 words, so the two rows a warp
touches in one access fall in disjoint banks. Rows are 16-byte aligned.

All dots in a program reuse that one shared region, sized for the largest dot
(`tile_dot_shared_bytes`); the reuse barrier makes this safe across loop
iterations, branches and nested dots. PTX declares one `__tile_smem` array per
kernel and addresses the operands by the planned offsets. A program whose
largest dot needs more than 48 KiB is rejected. For each K step, a thread reads
`m/16` left values and `n/16` right values from shared memory and issues
`(m/16) * (n/16)` fused multiply-adds, an outer product held in registers.

The planner is the source of layout and staging choices. Register assignment
and PTX spelling remain emitter responsibilities. Changing the plan is not yet
a supported public tuning interface: its current invariants are established by
analysis and the planner, and tests with artificial plans inspect text only.

## Scope and validation

Supported scalar/control syntax is intentionally narrower than a general W
function. Aggregates, containers, arbitrary calls, generic calls, `defer`, raw
assembly, `goto`, and nested GPU regions are unsupported. Diagnostics retain the
offending operation's source location.

GPU-independent tests must prove whole-body recording, stable binding lifetime,
shape and control diagnostics, and generated PTX structure. Recording and
analysis must leave host/PTX output and backend execution state unchanged.
Rollback must allow a later successful compilation. GPU execution tests compare
tile add with a CPU reference and staged dot with both CPU results and
`tensor_matmul_tiled_kernel`, including partial M, N and K tiles. They also
run 64 by 64, 128 by 128 and rectangular 32 by 64 products, one with a
transposed operand, and elementwise operations on multi-register fragments.

Every compiler change is gated by structured diagnostics, diff-selected tests,
self-host fixpoints, the ordinary suite and changed-line compiler coverage.
Frontend integration also runs the required-AST suite. The separate AST speed
target and streaming-grammar release/seed gate are not prerequisites for tiles.

The new targets are `tile_ast_test` / `tile_ast_64_test`,
`tile_analysis_unit_test` / `tile_analysis_unit_64_test`,
`tile_diagnostics_test`, `tile_ptx_test` and `tile_tree_query_test`.
`tile_gpu_compile_test` and
`tile_ops_gpu_compile_test` exercise both GPU fixtures without running CUDA;
`tile_gpu_test` and `tile_ops_gpu_test` execute them on a real device.
`w tree --json` (schema version 3) exposes the tile syntax hierarchy, source
locations and the analysis. Each tile node record carries `tile_op`,
`tile_type` (a compiler type name such as `float32*`), `tile_rank`,
`tile_rows`, `tile_cols`, `tile_uniform`, `tile_masked`, `tile_effect` (its
memory-effect order, or 0) and `tile_binding` (a binding ID, or -1). The
owning `gpu` statement's record is followed by a `tile_program` record
(`node`, `kernel`, `width`, `analyzed`, `matrix`, `shared_bytes`,
`captures`, `bindings`, and once planned `threads`, `lane_passes`, `dots`),
one `tile_binding` record per binding (`program`, `id`, `name`, `kind`,
`type`, `rank`, `rows`, `cols`, `uniform`, `capture_slot`), and one
`tile_dot` record per planned dot (`program`, `node`, `m`, `k`, `n`,
`fused`, and the buffer offsets and row strides). Every record carries
`source`. `tile_tree_query_test` covers the format.

The first 16 by 16 implementation measured about 121 microseconds per 512x512
product on an RTX 4080 SUPER, against 110 microseconds for the hand-tiled
kernel. Register-tiled shapes changed that. Development measurements on the
same GPU (driver 580.178.04, 20 timed launches after warm-up, desktop load
present) gave these results for square float32 products, in GFLOP/s:

| size | `tensor_matmul_tiled_kernel` | 64 by 64 tiles | 128 by 128 tiles | cuBLAS sgemm |
| ---- | ---------------------------- | -------------- | ---------------- | ------------ |
| 2048 | 2,200 | 16,300 | 18,100 | 34,300 |
| 4096 | 2,400 | 12,900-14,900 | 20,000-22,500 | 27,400 |

So 128 by 128 tile programs are about 8-9 times faster than the hand-tiled
kernel and reach 60-75% of cuBLAS at these sizes. Small products are bound by
launch overhead, and a 128 by 128 grid under-fills the GPU below about 2048.
Every result was checked exactly against the reference kernel.


## Reproducible benchmark

Build the driver with `./wbuild tile_benchmark_compile_test` (also included in
`./wbuild tests`). On a machine with CUDA, run:

```sh
nvidia-smi --query-gpu=name,driver_version --format=csv > bin/tile_benchmark_environment.txt
git rev-parse HEAD >> bin/tile_benchmark_environment.txt
sha256sum bin/wv2 bin/tile_benchmark >> bin/tile_benchmark_environment.txt
./bin/tile_benchmark 100 3 > bin/tile_benchmark.csv
```

The two optional arguments are launches per batch and number of batches;
defaults are 100 and 3. `./wbuild tile_benchmark` runs those defaults. Runtime
benchmarking is opt-in and is not an ordinary-suite performance gate.

The fixed input sweep runs the 16, 64 and 128 tile programs (rows `matrix16`,
`matrix64` and `matrix128`) on square products from 16 through 4096, 1x1
products with zero/nonzero K, and partial 15x17x19 and 511x513x509 products.
It also runs vector widths 1, 17, 255, 256, 257, 513 and 1024. Each vector width
runs its exact boundary, boundary plus one, and 65539 elements. Every case
checks all results against a GPU reference, plus output guards, before warming
up or timing. Products up to 512 cubed are also checked entirely against a CPU
calculation; larger ones check their first, middle and last rows on the CPU.
Deterministic small integer inputs make these checks exact in float32 at the
chosen sizes.

Matrix reference timings use the existing `tensor_matmul_tiled_kernel`;
vector references use the scalar GPU addition loop used by `tensor_add_into`.
After five warm-up pairs, each batch reports nanoseconds per launch, including
host launch overhead and one synchronization at the end of the batch, and for
matrix rows the corresponding GFLOP/s. The two implementations alternate
first/second timing order between batches. Products larger than 512 cubed halve
the launches per batch, down to three, for each doubling of work. Allocation,
CPU validation and managed-memory first-touch costs are outside timing. Keep
individual batch results and record GPU/driver/compiler revision when comparing
runs; normal device load and clock variation still affect results. This baseline
does not replace or select the existing tensor kernel.
