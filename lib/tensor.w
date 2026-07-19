/*
lib.tensor: a GPU tensor type on CUDA managed memory
(docs/projects/torch.md, Stages 2-3).

A tensor mirrors lib/ndarray.w's shape surface (rank 1-4, row-major,
float32) but carries a raw float* instead of a float[] slice: the buffer
comes from gpu_alloc (cuMemAllocManaged), so ONE pointer is valid on
both host and device — host code fills and verifies the same memory the
kernels write, no copy calls. There is no pointer-to-slice construction
in W (docs/projects/arrays_slices_strings.md), so ndf is not reused
directly; tensor_from_ndf / tensor_to_ndf copy across instead — the
moral equivalent of torch's .to("cuda") / .to("cpu").

Every op has two paths behind gpu_available() (checked once, at
allocation): a 'gpu for' launch, and a plain CPU loop over the same raw
pointers when no usable GPU exists — so programs run unchanged on
GPU-less machines, provided libcuda.so.1 itself is present to satisfy
the eager dynamic linker (see gpu_available's caveat in lib/cuda.w).

V1 ops are SYNCHRONOUS: each GPU path ends with gpu_sync(), trading
launch overlap for a simple aliasing story (removing the per-op sync is
torch.md Stage 4). Raw pointers are hoisted into locals before every
'gpu for' — a captured struct pointer would dereference host heap on
device — and device bodies stay inside the documented device subset.

x64 Linux only, like lib/ndarray64.w: gpu constructs require the x64
target (libcuda is 64-bit only).
*/
import lib.lib
import lib.assert
import lib.cuda
import lib.ndarray
import lib.rand


struct tensor:
	float* data    # managed (on_gpu) or malloc'd (fallback) buffer
	int len        # flat element count = n0*n1*n2*n3
	int on_gpu     # 1 = data is CUDA managed memory owned by gpu_alloc
	int rank       # 1..4
	int n0         # extents; unused trailing axes hold 1
	int n1
	int n2
	int n3
	int s0         # element strides; row-major at construction
	int s1
	int s2
	int s3


# Shape init shared with ndarray: same row-major stride math, same
# positive-extent and overflow asserts (ndarray_shape_init).
int tensor_init_shape(tensor* t, int rank, int n0, int n1, int n2, int n3):
	t.rank = rank
	t.n0 = n0
	t.n1 = n1
	t.n2 = n2
	t.n3 = n3
	return ndarray_shape_init(n0, n1, n2, n3, &t.s0, &t.s1, &t.s2, &t.s3)


void tensor_fill(tensor* t, float v);


##### construction #####


# Allocate a zero-filled tensor: managed memory when a usable GPU
# exists, host malloc otherwise. Managed memory is not guaranteed
# zeroed, so both paths zero explicitly (host-side: managed memory is
# host-accessible and nothing is in flight yet).
tensor tensor_make(int rank, int n0, int n1, int n2, int n3):
	tensor t
	int n = tensor_init_shape(&t, rank, n0, n1, n2, n3)
	t.len = n
	if (gpu_available()):
		t.data = cast(float*, gpu_alloc(n * 4))
		t.on_gpu = 1
	else:
		t.data = cast(float*, malloc(n * 4))
		t.on_gpu = 0
	float* p = t.data
	int i = 0
	while (i < n):
		p[i] = 0.0
		i = i + 1
	return t


tensor tensor_new1(int n0):
	return tensor_make(1, n0, 1, 1, 1)


tensor tensor_new2(int n0, int n1):
	return tensor_make(2, n0, n1, 1, 1)


tensor tensor_full1(int n0, float v):
	tensor t = tensor_new1(n0)
	tensor_fill(&t, v)
	return t


tensor tensor_full2(int n0, int n1, float v):
	tensor t = tensor_new2(n0, n1)
	tensor_fill(&t, v)
	return t


# Fill t with N(mean, stddev^2) draws from a fresh rand_state seeded
# with `seed` (lib/rand.w: xorshift32 + Box-Muller, deterministic and
# identical on every target for a fixed seed). Host-side only, unlike
# every other op in this file -- t.data is host-writable whether it is
# gpu_alloc'd managed memory or a plain malloc (nothing is in flight
# right after allocation), so there is no device path to branch to.
void tensor_randn(tensor* t, int seed, float mean, float stddev):
	rand_state r
	rand_init(&r, seed)
	float* p = t.data
	int n = t.len
	int i = 0
	while (i < n):
		p[i] = rand_gaussian_scaled(&r, mean, stddev)
		i = i + 1


void tensor_free(tensor* t):
	if (t.on_gpu):
		gpu_free(cast(char*, t.data))
	else:
		free(cast(char*, t.data))
	t.data = cast(float*, 0)
	t.len = 0


##### host <-> device copies (the .to("cuda") / .to("cpu") pair) #####


tensor tensor_from_ndf(ndf* a):
	tensor t = tensor_make(a.rank, a.n0, a.n1, a.n2, a.n3)
	float* p = t.data
	int i = 0
	while (i < a.data.length):
		p[i] = a.data[i]
		i = i + 1
	return t


ndf tensor_to_ndf(tensor* t):
	ndf a
	if (t.rank == 1):
		a = ndf_new1(t.n0)
	else if (t.rank == 2):
		a = ndf_new2(t.n0, t.n1)
	else if (t.rank == 3):
		a = ndf_new3(t.n0, t.n1, t.n2)
	else:
		a = ndf_new4(t.n0, t.n1, t.n2, t.n3)
	float* p = t.data
	int i = 0
	while (i < a.data.length):
		a.data[i] = p[i]
		i = i + 1
	return a


##### shape checks #####


void tensor_assert_same_shape(tensor* a, tensor* b, char* who):
	asserts(who, a.rank == b.rank && a.n0 == b.n0 && a.n1 == b.n1 && a.n2 == b.n2 && a.n3 == b.n3)


# All operands on the GPU path? Uniform in practice (gpu_available is
# stable process-wide), but checked per-op so a mixed set falls back to
# the CPU loop instead of launching on host memory.
int tensor_gpu2(tensor* a, tensor* b):
	return a.on_gpu && b.on_gpu


int tensor_gpu3(tensor* a, tensor* b, tensor* c):
	return a.on_gpu && b.on_gpu && c.on_gpu


##### elementwise ops #####


void tensor_fill(tensor* t, float v):
	float* p = t.data
	int n = t.len
	if (t.on_gpu):
		gpu for int i in range(n):
			p[i] = v
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			p[j] = v
			j = j + 1


void tensor_add_into(tensor* out, tensor* a, tensor* b):
	tensor_assert_same_shape(a, b, c"tensor_add_into: shape mismatch")
	tensor_assert_same_shape(a, out, c"tensor_add_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	float* pb = b.data
	int n = a.len
	if (tensor_gpu3(out, a, b)):
		gpu for int i in range(n):
			po[i] = pa[i] + pb[i]
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			po[j] = pa[j] + pb[j]
			j = j + 1


void tensor_sub_into(tensor* out, tensor* a, tensor* b):
	tensor_assert_same_shape(a, b, c"tensor_sub_into: shape mismatch")
	tensor_assert_same_shape(a, out, c"tensor_sub_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	float* pb = b.data
	int n = a.len
	if (tensor_gpu3(out, a, b)):
		gpu for int i in range(n):
			po[i] = pa[i] - pb[i]
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			po[j] = pa[j] - pb[j]
			j = j + 1


void tensor_mul_into(tensor* out, tensor* a, tensor* b):
	tensor_assert_same_shape(a, b, c"tensor_mul_into: shape mismatch")
	tensor_assert_same_shape(a, out, c"tensor_mul_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	float* pb = b.data
	int n = a.len
	if (tensor_gpu3(out, a, b)):
		gpu for int i in range(n):
			po[i] = pa[i] * pb[i]
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			po[j] = pa[j] * pb[j]
			j = j + 1


void tensor_add_scalar_into(tensor* out, tensor* a, float s):
	tensor_assert_same_shape(a, out, c"tensor_add_scalar_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	int n = a.len
	if (tensor_gpu2(out, a)):
		gpu for int i in range(n):
			po[i] = pa[i] + s
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			po[j] = pa[j] + s
			j = j + 1


void tensor_mul_scalar_into(tensor* out, tensor* a, float s):
	tensor_assert_same_shape(a, out, c"tensor_mul_scalar_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	int n = a.len
	if (tensor_gpu2(out, a)):
		gpu for int i in range(n):
			po[i] = pa[i] * s
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			po[j] = pa[j] * s
			j = j + 1


# y += s*x, in place -- the SGD update primitive (torch's axpy_/add_).
# y doubles as both an input and the output, so the shape check is
# against x directly rather than a separate out.
void tensor_axpy_into(tensor* y, float s, tensor* x):
	tensor_assert_same_shape(y, x, c"tensor_axpy_into: shape mismatch")
	float* py = y.data
	float* px = x.data
	int n = y.len
	if (tensor_gpu2(y, x)):
		gpu for int i in range(n):
			py[i] = py[i] + s * px[i]
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			py[j] = py[j] + s * px[j]
			j = j + 1


void tensor_relu_into(tensor* out, tensor* a):
	tensor_assert_same_shape(a, out, c"tensor_relu_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	int n = a.len
	if (tensor_gpu2(out, a)):
		gpu for int i in range(n):
			float x = pa[i]
			float r = 0.0
			if (x > 0.0):
				r = x
			po[i] = r
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			float y = pa[j]
			if (y > 0.0):
				po[j] = y
			else:
				po[j] = 0.0
			j = j + 1


# ReLU backward: out = dout where the *forward* input a was positive,
# else 0 (the ReLU derivative is 0/1, so this just gates dout through
# that mask). a is the saved forward input, not the forward output --
# same convention as ndf's would-be relu_grad, and what a tape-based
# autograd node replays on the way back.
void tensor_relu_grad_into(tensor* out, tensor* a, tensor* dout):
	tensor_assert_same_shape(a, dout, c"tensor_relu_grad_into: shape mismatch")
	tensor_assert_same_shape(a, out, c"tensor_relu_grad_into: output shape mismatch")
	float* po = out.data
	float* pa = a.data
	float* pd = dout.data
	int n = a.len
	if (tensor_gpu3(out, a, dout)):
		gpu for int i in range(n):
			float x = pa[i]
			float g = 0.0
			if (x > 0.0):
				g = pd[i]
			po[i] = g
		gpu_sync()
	else:
		int j = 0
		while (j < n):
			float x2 = pa[j]
			if (x2 > 0.0):
				po[j] = pd[j]
			else:
				po[j] = 0.0
			j = j + 1


##### broadcast ops (bias add) #####


# out[i,j] = a[i,j] + r[j]: bias add for a rank-2 (m, n) activation and
# a rank-1 (n) bias row, broadcast across every row. Elementwise over
# the flat (m*n) buffer like the ops above -- the broadcast is just
# "index the bias by the flat index modulo the row width" -- so this
# needs no per-row thread mapping (contrast the row/column reductions
# below, which do).
void tensor_add_row_into(tensor* out, tensor* a, tensor* r):
	asserts(c"tensor_add_row_into: a must be rank 2", a.rank == 2)
	asserts(c"tensor_add_row_into: r must be rank 1", r.rank == 1)
	asserts(c"tensor_add_row_into: row width mismatch", a.n1 == r.n0)
	tensor_assert_same_shape(a, out, c"tensor_add_row_into: output shape mismatch")
	int width = a.n1
	float* po = out.data
	float* pa = a.data
	float* pr = r.data
	int total = a.len
	if (tensor_gpu3(out, a, r)):
		gpu for int idx in range(total):
			int col = idx % width
			po[idx] = pa[idx] + pr[col]
		gpu_sync()
	else:
		int j = 0
		while (j < total):
			po[j] = pa[j] + pr[j % width]
			j = j + 1


##### reduction (torch.md Stage 1 atomics, Stage 4 block staging) #####


# Block-level tree reduction (torch.md Stage 4): each 256-thread block
# stages its slice in shared memory, halves it with barriers, then adds
# ONE per-block partial into the global accumulator — 256x fewer
# serialized atomics on the single cell than the Stage 1
# atomic-per-element version.
kernel tensor_sum_kernel(float* p, float32* acc, int n):
	float* buf = gpu_shared_f32(256)
	int tid = thread_idx()
	int gid = block_idx() * block_dim() + tid
	float v = 0.0
	if (gid < n):
		v = p[gid]
	buf[tid] = v
	gpu_barrier()
	int s = 128
	while (s > 0):
		if (tid < s):
			buf[tid] = buf[tid] + buf[tid + s]
		gpu_barrier()
		s = s / 2
	if (tid == 0):
		atomic_add(acc, buf[0])


# Sum of every element. The result depends on addition order on both
# paths (the GPU's block-tree order differs from the CPU's linear
# scan), so callers compare with a tolerance, as with any float
# reduction.
float tensor_sum(tensor* t):
	float* p = t.data
	int n = t.len
	if (t.on_gpu):
		# float32*, not float*: the intrinsic's parameter type is
		# spelled float32* and the alias is a distinct pointer index.
		float32* acc = cast(float32*, gpu_alloc(4))
		acc[0] = 0.0
		launch tensor_sum_kernel[(n + 255) / 256, 256](p, acc, n)
		gpu_sync()
		float s = acc[0]
		gpu_free(cast(char*, acc))
		return s
	float total = 0.0
	int j = 0
	while (j < n):
		total = total + p[j]
		j = j + 1
	return total


##### row/column reductions (softmax stability, bias gradients) #####
#
# One device thread per row/column, an ordinary inner loop over the
# other axis -- unlike tensor_sum there is no cross-thread write, so no
# atomic is needed (each thread owns a disjoint output slot).


# out[j] = sum_i a[i,j] for rank-2 a (m, n): the bias gradient. One
# thread per column, looping down the rows.
void tensor_col_sum_into(tensor* out, tensor* a):
	asserts(c"tensor_col_sum_into: a must be rank 2", a.rank == 2)
	asserts(c"tensor_col_sum_into: out must be rank 1", out.rank == 1)
	asserts(c"tensor_col_sum_into: output width mismatch", out.n0 == a.n1)
	int m = a.n0
	int n = a.n1
	float* po = out.data
	float* pa = a.data
	if (tensor_gpu2(out, a)):
		gpu for int j in range(n):
			float acc = 0.0
			int i = 0
			while (i < m):
				acc = acc + pa[i * n + j]
				i = i + 1
			po[j] = acc
		gpu_sync()
	else:
		int j2 = 0
		while (j2 < n):
			float acc2 = 0.0
			int i2 = 0
			while (i2 < m):
				acc2 = acc2 + pa[i2 * n + j2]
				i2 = i2 + 1
			po[j2] = acc2
			j2 = j2 + 1


# out[i] = sum_j a[i,j] for rank-2 a (m, n). One thread per row, looping
# across the columns.
void tensor_row_sum_into(tensor* out, tensor* a):
	asserts(c"tensor_row_sum_into: a must be rank 2", a.rank == 2)
	asserts(c"tensor_row_sum_into: out must be rank 1", out.rank == 1)
	asserts(c"tensor_row_sum_into: output height mismatch", out.n0 == a.n0)
	int m = a.n0
	int n = a.n1
	float* po = out.data
	float* pa = a.data
	if (tensor_gpu2(out, a)):
		gpu for int i in range(m):
			float acc = 0.0
			int j = 0
			while (j < n):
				acc = acc + pa[i * n + j]
				j = j + 1
			po[i] = acc
		gpu_sync()
	else:
		int i2 = 0
		while (i2 < m):
			float acc2 = 0.0
			int j2 = 0
			while (j2 < n):
				acc2 = acc2 + pa[i2 * n + j2]
				j2 = j2 + 1
			po[i2] = acc2
			i2 = i2 + 1


# out[i] = max_j a[i,j] for rank-2 a (m, n) -- softmax numerical
# stability (subtract the row max before exponentiating). One thread
# per row; the running max seeds from column 0 (n > 0 is guaranteed by
# tensor_init_shape's positive-extent assert), then scans columns 1..n-1.
void tensor_row_max_into(tensor* out, tensor* a):
	asserts(c"tensor_row_max_into: a must be rank 2", a.rank == 2)
	asserts(c"tensor_row_max_into: out must be rank 1", out.rank == 1)
	asserts(c"tensor_row_max_into: output height mismatch", out.n0 == a.n0)
	int m = a.n0
	int n = a.n1
	float* po = out.data
	float* pa = a.data
	if (tensor_gpu2(out, a)):
		gpu for int i in range(m):
			float best = pa[i * n]
			int j = 1
			while (j < n):
				float v = pa[i * n + j]
				if (v > best):
					best = v
				j = j + 1
			po[i] = best
		gpu_sync()
	else:
		int i2 = 0
		while (i2 < m):
			float best2 = pa[i2 * n]
			int j2 = 1
			while (j2 < n):
				float v2 = pa[i2 * n + j2]
				if (v2 > best2):
					best2 = v2
				j2 = j2 + 1
			po[i2] = best2
			i2 = i2 + 1


##### matmul (torch.md Stage 3 naive CPU path, Stage 4 tiled GPU path) #####
#
# The GPU path of all three matmul variants is a 16x16 shared-memory
# tiled kernel (256-thread blocks, the launch-heuristic size): each
# block stages one a-tile and one b-tile in .shared per k-step, so
# every global element is read once per 16 output columns/rows instead
# of once per output element -- the classic tiling that turns the naive
# kernel's redundant global traffic into shared-memory reuse. The
# block's x/y decomposition is done in-kernel from block_idx() (the
# launch surface is 1-D): bx walks output column tiles, by row tiles.
# Partial edge tiles load zeros, so any shape is correct, not just
# multiples of 16. The k-loop product order matches the naive kernel
# and the CPU fallback (ascending k), so all three paths accumulate in
# the same order and agree bit-for-bit.


# out = a @ b: ta stages a[row, t*16+tx], tb stages b[t*16+ty, col];
# both loads are tx-contiguous in global memory (coalesced).
kernel tensor_matmul_tiled_kernel(float* a, float* b, float* out, int m, int kd, int n):
	float* ta = gpu_shared_f32(256)
	float* tb = gpu_shared_f32(256)
	int tid = thread_idx()
	int tx = tid % 16
	int ty = tid / 16
	int nbx = (n + 15) / 16
	int bx = block_idx() % nbx
	int by = block_idx() / nbx
	int row = by * 16 + ty
	int col = bx * 16 + tx
	float acc = 0.0
	int nt = (kd + 15) / 16
	int t = 0
	while (t < nt):
		int ak = t * 16 + tx
		float av = 0.0
		if (row < m):
			if (ak < kd):
				av = a[row * kd + ak]
		ta[ty * 16 + tx] = av
		int bk = t * 16 + ty
		float bv = 0.0
		if (bk < kd):
			if (col < n):
				bv = b[bk * n + col]
		tb[ty * 16 + tx] = bv
		gpu_barrier()
		int q = 0
		while (q < 16):
			acc = acc + ta[ty * 16 + q] * tb[q * 16 + tx]
			q = q + 1
		gpu_barrier()
		t = t + 1
	if (row < m):
		if (col < n):
			out[row * n + col] = acc


# out = aT @ b for a (kd, m): the a-tile load reads a[ak * m + row]
# (column-major walk of a, stride m between tx neighbors -- uncoalesced,
# but the 16x reuse from shared staging still dominates the naive
# kernel's per-element k-loop).
kernel tensor_matmul_tn_tiled_kernel(float* a, float* b, float* out, int m, int kd, int n):
	float* ta = gpu_shared_f32(256)
	float* tb = gpu_shared_f32(256)
	int tid = thread_idx()
	int tx = tid % 16
	int ty = tid / 16
	int nbx = (n + 15) / 16
	int bx = block_idx() % nbx
	int by = block_idx() / nbx
	int row = by * 16 + ty
	int col = bx * 16 + tx
	float acc = 0.0
	int nt = (kd + 15) / 16
	int t = 0
	while (t < nt):
		int ak = t * 16 + tx
		float av = 0.0
		if (row < m):
			if (ak < kd):
				av = a[ak * m + row]
		ta[ty * 16 + tx] = av
		int bk = t * 16 + ty
		float bv = 0.0
		if (bk < kd):
			if (col < n):
				bv = b[bk * n + col]
		tb[ty * 16 + tx] = bv
		gpu_barrier()
		int q = 0
		while (q < 16):
			acc = acc + ta[ty * 16 + q] * tb[q * 16 + tx]
			q = q + 1
		gpu_barrier()
		t = t + 1
	if (row < m):
		if (col < n):
			out[row * n + col] = acc


# out = a @ bT for b (n, kd): the b-tile load reads b[col * kd + bk]
# (row-major walk of b's rows as output columns; stride kd between tx
# neighbors -- same tradeoff as the tn a-tile).
kernel tensor_matmul_nt_tiled_kernel(float* a, float* b, float* out, int m, int kd, int n):
	float* ta = gpu_shared_f32(256)
	float* tb = gpu_shared_f32(256)
	int tid = thread_idx()
	int tx = tid % 16
	int ty = tid / 16
	int nbx = (n + 15) / 16
	int bx = block_idx() % nbx
	int by = block_idx() / nbx
	int row = by * 16 + ty
	int col = bx * 16 + tx
	float acc = 0.0
	int nt = (kd + 15) / 16
	int t = 0
	while (t < nt):
		int ak = t * 16 + tx
		float av = 0.0
		if (row < m):
			if (ak < kd):
				av = a[row * kd + ak]
		ta[ty * 16 + tx] = av
		int bk = t * 16 + ty
		float bv = 0.0
		if (bk < kd):
			if (col < n):
				bv = b[col * kd + bk]
		tb[ty * 16 + tx] = bv
		gpu_barrier()
		int q = 0
		while (q < 16):
			acc = acc + ta[ty * 16 + q] * tb[q * 16 + tx]
			q = q + 1
		gpu_barrier()
		t = t + 1
	if (row < m):
		if (col < n):
			out[row * n + col] = acc


# Shared launch arithmetic: one 256-thread block per 16x16 output tile.
int tensor_matmul_blocks(int m, int n):
	return ((m + 15) / 16) * ((n + 15) / 16)


# out = a @ b for rank-2 a (m x k), b (k x n), out (m x n). GPU path:
# the tiled kernel above; CPU fallback: the naive triple loop.
void tensor_matmul2(tensor* out, tensor* a, tensor* b):
	asserts(c"tensor_matmul2: rank must be 2", a.rank == 2 && b.rank == 2 && out.rank == 2)
	asserts(c"tensor_matmul2: inner dimensions must match", a.n1 == b.n0)
	asserts(c"tensor_matmul2: output shape mismatch", out.n0 == a.n0 && out.n1 == b.n1)
	asserts(c"tensor_matmul2: output must not alias an input", out != a && out != b)
	int m = a.n0
	int kd = a.n1
	int n = b.n1
	float* po = out.data
	float* pa = a.data
	float* pb = b.data
	if (tensor_gpu3(out, a, b)):
		launch tensor_matmul_tiled_kernel[tensor_matmul_blocks(m, n), 256](pa, pb, po, m, kd, n)
		gpu_sync()
	else:
		int i = 0
		while (i < m):
			int j = 0
			while (j < n):
				float sum = 0.0
				int k2 = 0
				while (k2 < kd):
					sum = sum + pa[i * kd + k2] * pb[k2 * n + j]
					k2 = k2 + 1
				po[i * n + j] = sum
				j = j + 1
			i = i + 1


# out = aT @ b for a (k, m), b (k, n), out (m, n) -- i.e. out[i,j] =
# sum_p a[p,i]*b[p,j]. The backward pass of tensor_matmul2 needs exactly
# this shape (dW = xT @ dout for a linear layer), and forming an actual
# transpose would cost an extra full copy, so this walks a's columns
# directly instead. GPU path: the tn tiled kernel above.
void tensor_matmul2_tn(tensor* out, tensor* a, tensor* b):
	asserts(c"tensor_matmul2_tn: rank must be 2", a.rank == 2 && b.rank == 2 && out.rank == 2)
	asserts(c"tensor_matmul2_tn: shared dimension must match", a.n0 == b.n0)
	asserts(c"tensor_matmul2_tn: output shape mismatch", out.n0 == a.n1 && out.n1 == b.n1)
	asserts(c"tensor_matmul2_tn: output must not alias an input", out != a && out != b)
	int kd = a.n0
	int m = a.n1
	int n = b.n1
	float* po = out.data
	float* pa = a.data
	float* pb = b.data
	if (tensor_gpu3(out, a, b)):
		launch tensor_matmul_tn_tiled_kernel[tensor_matmul_blocks(m, n), 256](pa, pb, po, m, kd, n)
		gpu_sync()
	else:
		int i = 0
		while (i < m):
			int j = 0
			while (j < n):
				float sum = 0.0
				int p2 = 0
				while (p2 < kd):
					sum = sum + pa[p2 * m + i] * pb[p2 * n + j]
					p2 = p2 + 1
				po[i * n + j] = sum
				j = j + 1
			i = i + 1


# out = a @ bT for a (m, k), b (n, k), out (m, n) -- i.e. out[i,j] =
# sum_p a[i,p]*b[j,p]. The forward pass of a linear layer wants this
# shape directly (y = x @ WT with W stored (out_features, in_features),
# torch's convention), and the backward pass needs it again for
# dx = dout @ W. GPU path: the nt tiled kernel above.
void tensor_matmul2_nt(tensor* out, tensor* a, tensor* b):
	asserts(c"tensor_matmul2_nt: rank must be 2", a.rank == 2 && b.rank == 2 && out.rank == 2)
	asserts(c"tensor_matmul2_nt: shared dimension must match", a.n1 == b.n1)
	asserts(c"tensor_matmul2_nt: output shape mismatch", out.n0 == a.n0 && out.n1 == b.n0)
	asserts(c"tensor_matmul2_nt: output must not alias an input", out != a && out != b)
	int m = a.n0
	int kd = a.n1
	int n = b.n0
	float* po = out.data
	float* pa = a.data
	float* pb = b.data
	if (tensor_gpu3(out, a, b)):
		launch tensor_matmul_nt_tiled_kernel[tensor_matmul_blocks(m, n), 256](pa, pb, po, m, kd, n)
		gpu_sync()
	else:
		int i = 0
		while (i < m):
			int j = 0
			while (j < n):
				float sum = 0.0
				int p2 = 0
				while (p2 < kd):
					sum = sum + pa[i * kd + p2] * pb[j * kd + p2]
					p2 = p2 + 1
				po[i * n + j] = sum
				j = j + 1
			i = i + 1
