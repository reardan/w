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


##### reduction (torch.md Stage 1: atomic_add) #####


# Sum of every element. GPU path: one atom.add.f32 per element into a
# managed accumulator cell — correct at any size; block-level staging
# is Stage 4. The result depends on addition order on both paths, so
# callers compare with a tolerance, as with any float reduction.
float tensor_sum(tensor* t):
	float* p = t.data
	int n = t.len
	if (t.on_gpu):
		# float32*, not float*: the intrinsic's parameter type is
		# spelled float32* and the alias is a distinct pointer index.
		float32* acc = cast(float32*, gpu_alloc(4))
		acc[0] = 0.0
		gpu for int i in range(n):
			atomic_add(acc, p[i])
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


##### matmul (torch.md Stage 3: naive, one thread per output) #####


# out = a @ b for rank-2 a (m x k), b (k x n), out (m x n). Each device
# thread owns one output element and runs the k-loop; correct at any
# shape, unblocked and memory-bound (tiling with shared memory is
# Stage 4). The CPU fallback is the same loop nest.
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
	int total = m * n
	if (tensor_gpu3(out, a, b)):
		gpu for int idx in range(total):
			int row = idx / n
			int col = idx % n
			float acc = 0.0
			int k = 0
			while (k < kd):
				acc = acc + pa[row * kd + k] * pb[k * n + col]
				k = k + 1
			po[idx] = acc
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
