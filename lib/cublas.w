/*
lib.cublas: optional cuBLAS v2 GEMM for W GPU code (docs/projects/cuda.md,
"Execution notes (cuBLAS interop)"). x64 Linux only, like lib/cuda.w.

cuBLAS ships with the CUDA *toolkit*, not the driver, so it is loaded at
RUN time through lib/dlcall.w (dlopen + W->System V trampolines) rather
than with `c_lib`: a `c_lib "libcublas.so.12"` would put a DT_NEEDED
entry in the executable and a machine without the toolkit would refuse
to start the program at all. Here a missing library, a missing symbol,
no usable GPU or a failing cublasCreate all make cublas_available()
return 0 and callers keep their own path (lib/tensor_cublas.w falls back
to lib/tensor.w's tiled kernels). The program itself still needs
libcuda.so.1 at load time, via lib/cuda.w -- the same floor every GPU
program has.

Context sharing: cuBLAS runs on the CUDA runtime API, which binds to
whatever driver context is current on the calling thread and only falls
back to the device's primary context when none is. cublas_init first
runs lib/cuda.w's __w_gpu_init, so the context lib/cuda.w created with
cuCtxCreate is current and cuBLAS uses it: gpu_alloc/gpu_device_alloc
pointers are valid cuBLAS operands, and cuBLAS work goes on the same
legacy default stream (stream 0) as 'launch'/'gpu for' -- ordering with
kernels needs no extra syncs and gpu_sync() waits for cuBLAS work too.
Call from the thread that first touched the GPU (the main thread).

Layout: W tensors are row-major, cuBLAS is column-major. A row-major
r x c matrix with leading dimension c is, bit for bit, its column-major
transpose, so row-major C = op(A) op(B) is computed as column-major
C^T = op(B)^T op(A)^T: swap the operands (and their trans flags and
leading dimensions) and swap m with n. cublas_sgemm_rm/cublas_dgemm_rm
take cblas-style ROW-MAJOR arguments and do that swap.

Results are not bit-identical to lib/tensor.w's tiled kernel (cuBLAS
picks its own blocking/split-k and summation order; the default math
mode is plain FP32, no TF32), so compare with a tolerance.

User API:
	cublas_available()            1 when the fast path is usable (lazy,
	                              cached; never exits)
	cublas_sgemm_rm(ta, tb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
	cublas_dgemm_rm(...)          same on float64
	cublas_version()              cublasGetVersion (e.g. 120002), 0 if
	                              unavailable
	cublas_shutdown()             destroy the handle (optional at exit)
ta/tb are CUBLAS_OP_N (0) or CUBLAS_OP_T (1); the gemm wrappers return
the cublasStatus_t (0 = success) and are asynchronous like a launch.
*/
import lib.lib
import lib.cuda
import lib.dlcall
import code_generator.integer

type cublas_fn1 = fn(char*) -> int
type cublas_fn2 = fn(char*, char*) -> int

int CUBLAS_OP_N = 0
int CUBLAS_OP_T = 1

int __cublas_state          # 0 unknown, 1 usable, 2 unusable
char* __cublas_lib
char* __cublas_handle
char* __cublas_scalars      # 32 bytes: alpha at 0, beta at 16 (host pointer mode)
cublas_fn1* __cublas_create
cublas_fn1* __cublas_destroy
cublas_fn2* __cublas_get_version
# The 14-argument gemm entry points go through the argv trampoline form
# (lib/dlcall.w: fn-type aliases cap out at 10 parameters today).
int __cublas_sgemm
int __cublas_dgemm
int* __cublas_args          # 14 argument words, reused per call


# First soname that dlopens: the CUDA 12 ABI name, then neighbors (the
# gemm entry points kept their signatures across these majors), then
# the unversioned dev symlink.
char* __cublas_open():
	char* h = dl_open(c"libcublas.so.12")
	if (h == 0): h = dl_open(c"libcublas.so.13")
	if (h == 0): h = dl_open(c"libcublas.so.11")
	if (h == 0): h = dl_open(c"libcublas.so")
	return h


int __cublas_bind(int nargs, char* name):
	return dl_trampoline(dl_sym(__cublas_lib, name), nargs, 1)


int __cublas_bind_argv(int nargs, char* name):
	return dl_trampoline_argv(dl_sym(__cublas_lib, name), nargs, 1)


# Lazy one-time setup: library, symbols, GPU, context, handle. Any
# failure marks the fast path unusable (state 2) without exiting.
int cublas_init():
	if (__cublas_state != 0):
		return __cublas_state == 1
	__cublas_state = 2
	if (__word_size__ != 8): return 0
	if (gpu_available() == 0): return 0
	__cublas_lib = __cublas_open()
	if (__cublas_lib == 0): return 0
	__cublas_create = cast(cublas_fn1*, __cublas_bind(1, c"cublasCreate_v2"))
	__cublas_destroy = cast(cublas_fn1*, __cublas_bind(1, c"cublasDestroy_v2"))
	__cublas_get_version = cast(cublas_fn2*, __cublas_bind(2, c"cublasGetVersion_v2"))
	__cublas_sgemm = __cublas_bind_argv(14, c"cublasSgemm_v2")
	__cublas_dgemm = __cublas_bind_argv(14, c"cublasDgemm_v2")
	if (cast(int, __cublas_create) == 0 || cast(int, __cublas_destroy) == 0 || cast(int, __cublas_get_version) == 0 || __cublas_sgemm == 0 || __cublas_dgemm == 0):
		return 0
	# Make lib/cuda.w's driver context current before the runtime API
	# inside cuBLAS looks for one (see the header).
	__w_gpu_init()
	char* cell = malloc(8)
	save_i(cell, 0, 8)
	if (__cublas_create(cell) != 0):
		free(cell)
		return 0
	__cublas_handle = cast(char*, load_i(cell, 8))
	free(cell)
	__cublas_scalars = malloc(32)
	__cublas_args = cast(int*, malloc(14 * 8))
	__cublas_state = 1
	return 1


int cublas_available():
	return cublas_init()


int cublas_version():
	if (cublas_init() == 0): return 0
	char* cell = malloc(8)
	save_i(cell, 0, 8)
	int v = 0
	if (__cublas_get_version(__cublas_handle, cell) == 0): v = load_i(cell, 4)
	free(cell)
	return v


# The column-major call for a row-major product (the operand swap
# described in the header): cublas?gemm(handle, transb, transa, n, m, k,
# &alpha, B, ldb, A, lda, &beta, C, ldc). alpha/beta are already stored
# in __cublas_scalars (host pointer mode: cuBLAS reads them before the
# call returns, so the cells can be reused right away).
int __cublas_gemm(int stub, int transa, int transb, int m, int n, int k, char* a, int lda, char* b, int ldb, char* c, int ldc):
	int* v = __cublas_args
	v[0] = cast(int, __cublas_handle)
	v[1] = transb
	v[2] = transa
	v[3] = n
	v[4] = m
	v[5] = k
	v[6] = cast(int, __cublas_scalars)
	v[7] = cast(int, b)
	v[8] = ldb
	v[9] = cast(int, a)
	v[10] = lda
	v[11] = cast(int, __cublas_scalars + 16)
	v[12] = cast(int, c)
	v[13] = ldc
	return dl_call(stub, v)


# Row-major C = alpha * op(A) op(B) + beta * C, with C m x n and
# op(A) m x k, op(B) k x n; lda/ldb/ldc are the row-major row pitches
# (in elements) of the matrices as STORED. Column-major cuBLAS computes
# C^T = op(B)^T op(A)^T: operands, flags and leading dimensions swap,
# and so do m and n. Returns the cublasStatus_t, or 1
# (CUBLAS_STATUS_NOT_INITIALIZED) when cuBLAS is unavailable.
int cublas_sgemm_rm(int transa, int transb, int m, int n, int k, float alpha, float* a, int lda, float* b, int ldb, float beta, float* c, int ldc):
	if (cublas_init() == 0): return 1
	float* s = cast(float*, __cublas_scalars)
	s[0] = alpha
	s[4] = beta
	return __cublas_gemm(__cublas_sgemm, transa, transb, m, n, k, cast(char*, a), lda, cast(char*, b), ldb, cast(char*, c), ldc)


int cublas_dgemm_rm(int transa, int transb, int m, int n, int k, float64 alpha, float64* a, int lda, float64* b, int ldb, float64 beta, float64* c, int ldc):
	if (cublas_init() == 0): return 1
	float64* s = cast(float64*, __cublas_scalars)
	s[0] = alpha
	s[2] = beta
	return __cublas_gemm(__cublas_dgemm, transa, transb, m, n, k, cast(char*, a), lda, cast(char*, b), ldb, cast(char*, c), ldc)


# Destroy the handle (waits for outstanding cuBLAS work). Afterwards the
# module reports unavailable; optional at program exit.
void cublas_shutdown():
	if (__cublas_state == 1):
		__cublas_destroy(__cublas_handle)
		__cublas_handle = cast(char*, 0)
	__cublas_state = 2
