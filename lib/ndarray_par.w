/*
lib.ndarray_par: parallel_for-chunked twins of lib.ndarray's ndf
elementwise ops plus the two-phase sum reduction -- Stage 3 of
docs/projects/ndarray.md ("Interaction with parallel_for").

A separate module, not part of lib/ndarray.w, because it imports
lib.thread, which is Linux x86/x86-64 ONLY: lib.ndarray must stay
importable on every target. Import this only from code already gated to
those targets (the lib/ndarray64.w precedent for target-gated twins).

The doc's contract, implemented literally:

- **Chunk the leading axis.** Every op splits [0, n0) with
  parallel_for; a worker owning rows [r0, r1) of a contiguous
  row-major array owns exactly the disjoint flat element range
  [r0 * s0, r1 * s0), so no two workers ever write the same element.
  Contiguity is a fatal-assert precondition (ndf_is_contiguous), the
  same predicate kernels rely on.
- **Bit-identical results.** Each output element is computed by the
  same expression as the serial twin (ndf_add_into / ndf_axpy_into),
  only on a different thread, so the parallel results are bit-identical
  to the serial ones for every nthreads (asserted by
  tests/ndarray_stage3_test.w).
- **Reductions are two-phase.** ndf_sum_par gives each worker its own
  slot of a float[nthreads] scratch array (allocated and combined on
  the calling thread; workers never allocate) and combines the partials
  serially in chunk order. Chunk boundaries are parallel_for's
  deterministic split, so the result is a pure function of
  (data, shape, nthreads): nthreads <= 1 is bit-identical to the serial
  ndf_sum, and any fixed nthreads is reproducible run to run -- a
  different nthreads changes the float association, not correctness.
- **Context via pointer.** W has no closures; each op boxes its
  operands in a stack struct passed as the void* argument
  (lib/event_loop.w callback precedent).

Threading constraints inherited from lib/thread.w: call these from the
MAIN THREAD only, and note the workers only loop over caller-owned
buffers (no allocation off the main thread). nthreads follows
parallel_for's semantics: clamped to the row count, <= 1 runs inline on
the calling thread with no clone (the degenerate single-thread path).
*/
import lib.lib
import lib.assert
import lib.array
import lib.ndarray
import lib.thread


# Operand box for the elementwise chunk callbacks.
struct ndf_par_ctx:
	ndf* out
	ndf* a
	ndf* b
	float s


void ndf_par_assert_contiguous(ndf* a, char* who):
	asserts(who, ndf_is_contiguous(a))


void ndf_par_add_chunk(int row0, int row1, void* p):
	ndf_par_ctx* ctx = cast(ndf_par_ctx*, p)
	ndf* out = ctx.out
	ndf* a = ctx.a
	ndf* b = ctx.b
	int i = row0 * a.s0
	int end = row1 * a.s0
	while (i < end):
		out.data[i] = a.data[i] + b.data[i]
		i = i + 1


# Parallel twin of ndf_add_into: out = a + b, chunked over the leading
# axis. out may alias a and/or b (each element is read before it is
# written, and workers own disjoint element ranges). Main thread only.
void ndf_add_into_par(ndf* out, ndf* a, ndf* b, int nthreads):
	ndf_assert_same_shape(a, b, c"ndf_add_into_par: shape mismatch")
	ndf_assert_same_shape(a, out, c"ndf_add_into_par: output shape mismatch")
	ndf_par_assert_contiguous(a, c"ndf_add_into_par: a must be contiguous")
	ndf_par_assert_contiguous(b, c"ndf_add_into_par: b must be contiguous")
	ndf_par_assert_contiguous(out, c"ndf_add_into_par: out must be contiguous")
	ndf_par_ctx ctx
	ctx.out = out
	ctx.a = a
	ctx.b = b
	ctx.s = 0.0
	parallel_for(0, a.n0, nthreads, ndf_par_add_chunk, cast(void*, &ctx))


void ndf_par_axpy_chunk(int row0, int row1, void* p):
	ndf_par_ctx* ctx = cast(ndf_par_ctx*, p)
	ndf* out = ctx.out
	ndf* x = ctx.a
	ndf* y = ctx.b
	float s = ctx.s
	int i = row0 * x.s0
	int end = row1 * x.s0
	while (i < end):
		out.data[i] = s * x.data[i] + y.data[i]
		i = i + 1


# Parallel twin of ndf_axpy_into: out = s * x + y, chunked over the
# leading axis. out may alias x and/or y. Main thread only.
void ndf_axpy_into_par(ndf* out, float s, ndf* x, ndf* y, int nthreads):
	ndf_assert_same_shape(x, y, c"ndf_axpy_into_par: shape mismatch")
	ndf_assert_same_shape(x, out, c"ndf_axpy_into_par: output shape mismatch")
	ndf_par_assert_contiguous(x, c"ndf_axpy_into_par: x must be contiguous")
	ndf_par_assert_contiguous(y, c"ndf_axpy_into_par: y must be contiguous")
	ndf_par_assert_contiguous(out, c"ndf_axpy_into_par: out must be contiguous")
	ndf_par_ctx ctx
	ctx.out = out
	ctx.a = x
	ctx.b = y
	ctx.s = s
	parallel_for(0, x.n0, nthreads, ndf_par_axpy_chunk, cast(void*, &ctx))


# Operand box for the two-phase sum reduction.
struct ndf_par_sum_ctx:
	ndf* a
	float[] partials
	int nthreads


void ndf_par_sum_chunk(int row0, int row1, void* p):
	ndf_par_sum_ctx* ctx = cast(ndf_par_sum_ctx*, p)
	ndf* a = ctx.a
	# Recover this chunk's index from its deterministic start row:
	# chunk k of parallel_for's split starts at
	# thread_chunk_offset(n0, nthreads, k), and every chunk is nonempty
	# (nthreads was clamped to n0), so the start rows are strictly
	# increasing and the match is unique.
	int k = 0
	while (k + 1 < ctx.nthreads && thread_chunk_offset(a.n0, ctx.nthreads, k) != row0):
		k = k + 1
	float acc = 0.0
	int i = row0 * a.s0
	int end = row1 * a.s0
	while (i < end):
		acc = acc + a.data[i]
		i = i + 1
	# Disjoint slot per chunk: plain store, no synchronization needed
	# beyond the join (lib/thread.w's visibility argument).
	ctx.partials[k] = acc


# Two-phase parallel sum: phase 1 chunks the leading axis and each
# worker accumulates its rows left-to-right into its own slot of a
# float[nthreads] scratch array; phase 2 combines the partials serially
# in chunk order on the calling thread. No atomics (doc: "Reductions
# are two-phase"). Deterministic for a given (data, shape, nthreads);
# nthreads <= 1 (after clamping to n0) is exactly the serial ndf_sum.
# Main thread only.
float ndf_sum_par(ndf* a, int nthreads):
	ndf_par_assert_contiguous(a, c"ndf_sum_par: array must be contiguous")
	if (nthreads > a.n0):
		nthreads = a.n0
	if (nthreads <= 1):
		return ndf_sum(a)
	float[] partials = new float[nthreads]
	ndf_par_sum_ctx ctx
	ctx.a = a
	ctx.partials = partials
	ctx.nthreads = nthreads
	parallel_for(0, a.n0, nthreads, ndf_par_sum_chunk, cast(void*, &ctx))
	float total = 0.0
	int k = 0
	while (k < nthreads):
		total = total + partials[k]
		k = k + 1
	array_free[float](partials)
	return total
