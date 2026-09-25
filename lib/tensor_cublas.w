/*
lib.tensor_cublas: opt-in cuBLAS fast path for lib/tensor.w's matmuls.

	import lib.tensor_cublas
	...
	tensor_use_cublas()      # 1 = installed, 0 = cuBLAS unavailable

installs a hook that routes tensor_matmul2 / _tn / _nt (and so every
lib/autograd.w linear layer built on them) to cublasSgemm when all
three operands are GPU tensors; otherwise, or if cuBLAS is missing,
the tiled kernels run as before. lib/tensor.w itself never imports
this module, so programs that do not ask for cuBLAS never load it.
tensor_disable_cublas() puts the tiled kernels back (benchmarks, A/B
checks). Results match the tiled kernels to FP32 rounding, not bit for
bit (see lib/cublas.w).
*/
import lib.tensor
import lib.cublas


# The tensor.w hook: op 0 = a @ b, 1 = aT @ b, 2 = a @ bT, shapes as in
# the tensor_matmul2* doc comments (m x n output, kd the shared axis).
# Returns 1 when the GEMM was enqueued, 0 to make the caller launch its
# own kernel.
int tensor_cublas_gemm(int op, float* a, float* b, float* out, int m, int kd, int n):
	int status = 1
	if (op == 0):
		status = cublas_sgemm_rm(CUBLAS_OP_N, CUBLAS_OP_N, m, n, kd, 1.0, a, kd, b, n, 0.0, out, n)
	else if (op == 1):
		status = cublas_sgemm_rm(CUBLAS_OP_T, CUBLAS_OP_N, m, n, kd, 1.0, a, m, b, n, 0.0, out, n)
	else if (op == 2):
		status = cublas_sgemm_rm(CUBLAS_OP_N, CUBLAS_OP_T, m, n, kd, 1.0, a, kd, b, kd, 0.0, out, n)
	return status == 0


int tensor_use_cublas():
	if (cublas_available() == 0): return 0
	tensor_matmul_hook = tensor_cublas_gemm
	return 1


void tensor_disable_cublas():
	tensor_matmul_hook = cast(tensor_matmul_fn*, 0)
