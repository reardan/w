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
4. `code_generator/tile_ptx.w` maps the analyzed tree to a fixed thread layout,
   registers, shared storage and synchronization. `code_generator/tile_host.w`
   evaluates the recorded header and captured host values and emits the launch.

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
          rows_bound, columns_bound, 16, 16)
dot(left_tile, right_tile)
tile_store(pointer, row, column, row_stride, column_stride,
           rows_bound, columns_bound, value)
```

The initial matrix shape is 16 by 16. A load zero-fills elements outside either
bound. A store masks both dimensions. `dot` produces a float32 matrix tile.
The physical implementation stages two inputs in shared memory, synchronizes
the block, computes the dot product, and synchronizes before buffer reuse.
Uniform range loops allow a program to accumulate successive K tiles.

For example, a row-major product uses inferred tile locals (`:=`) and scalar
program coordinates:

```text
gpu[1] for tile in range(programs):
	int columns = (n + 15) / 16
	int row = tile_program_id() / columns * 16
	int col = tile_program_id() % columns * 16
	acc := tile_zero(16, 16)
	for int block in range((k + 15) / 16):
		left := tile_load(a, row, block * 16, k, 1, m, k, 16, 16)
		right := tile_load(b, block * 16, col, n, 1, k, n, 16, 16)
		acc += dot(left, right)
	tile_store(out, row, col, n, 1, m, n, acc)
```

Each dot accumulates its 16 products in ascending K order with separate
float32 multiplication and addition. Adding successive dot results groups the
sum by K tile, so results need not be bit-identical to the hand-written kernel's
single running accumulator. Compare with an appropriate floating-point tolerance.

All threads participate in cooperative operations, including threads whose
final output is out of bounds. There is no implicit whole-body lane guard.
Conditions and loop bounds must be block-uniform; tile-valued conditions are
rejected. Tensor-core instructions, automatic layout search, asynchronous copies
and automatic tuning are outside this first implementation.

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
`tensor_matmul_tiled_kernel`, including partial M, N and K tiles.

Every compiler change is gated by structured diagnostics, diff-selected tests,
self-host fixpoints, the ordinary suite and changed-line compiler coverage.
Frontend integration also runs the required-AST suite. The separate AST speed
target and streaming-grammar release/seed gate are not prerequisites for tiles.

The new targets are `tile_ast_test` / `tile_ast_64_test`,
`tile_analysis_unit_test` / `tile_analysis_unit_64_test`,
`tile_diagnostics_test`, and `tile_ptx_test`. `tile_gpu_compile_test` and
`tile_ops_gpu_compile_test` exercise both GPU fixtures without running CUDA;
`tile_gpu_test` and `tile_ops_gpu_test` execute them on a real device.
Tree queries expose the tile syntax hierarchy and source locations; analyzed
shape and binding information currently lives in the retained tile payload.

A development smoke measurement on an RTX 4080 SUPER (driver 580.173.02),
using a 512x512 float32 product, five warm-up pairs and three batches of 100
launches, measured about 121 microseconds per tile matmul versus 110 microseconds
for the existing hand-tiled kernel. Timing includes host launch overhead and a
synchronization at each batch end. This establishes a starting point for later
layout/register tuning; the initial implementation does not claim a speedup.
