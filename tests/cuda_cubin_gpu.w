# Opt-in cubin embedding (docs/projects/cuda.md "Execution notes (cubin
# embedding)"): a raw kernel plus a 'gpu for' loop, CPU-verified, then
# reports which embedded image the runtime loaded (gpu_module_source:
# 1 = PTX via driver JIT, 2 = the --cubin-file cubin). cuda_cubin_test
# builds it three ways through tools/cuda/build_cubin.sh: plain, with a
# native-arch cubin, and with a wrong-arch cubin that must fall back to
# the PTX. Needs a GPU and ptxas, so it stays out of './wbuild tests';
# cuda_cubin_embed_test covers the compile side GPU-less.
import lib.lib
import lib.cuda

kernel scale_add(float32* y, float32* x, float32 a, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = a * x[i] + y[i]


int main():
	int n = 1000
	float32* x = cast(float32*, gpu_alloc(n * 4))
	float32* y = cast(float32*, gpu_alloc(n * 4))
	int* z = cast(int*, gpu_alloc(n * 8))
	int i = 0
	while (i < n):
		x[i] = i
		y[i] = 1.0
		z[i] = 0
		i = i + 1
	int threads = 256
	int blocks = (n + threads - 1) / threads
	launch scale_add[blocks, threads](y, x, 2.0, n)
	gpu for int j in range(n):
		z[j] = j * 3 + 1
	gpu_sync()
	int ok = 1
	i = 0
	while (i < n):
		float32 want = 2 * i + 1
		if (y[i] != want):
			ok = 0
		if (z[i] != i * 3 + 1):
			ok = 0
		i = i + 1
	int src = gpu_module_source()
	if (ok == 0):
		println(c"cuda cubin FAILED: wrong results")
		return 1
	if (src == 2):
		println(c"cuda cubin OK source=cubin")
	else if (src == 1):
		println(c"cuda cubin OK source=ptx")
	else:
		println(c"cuda cubin FAILED: no module loaded")
		return 1
	return 0
