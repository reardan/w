# CUDA driver-API smoke test (x64 only: libcuda.so is 64-bit).
#
# Proves H1 dynamic linking end to end: a hand-written PTX vector-add
# kernel is JIT-loaded through libcuda.so.1 and launched on the GPU, and
# the result is copied back and checked. cuLaunchKernel (11 args) also
# exercises the x64 shim's on-stack argument path.
#
# Handles and device pointers are 64-bit, so cells are 8-byte and accessed
# with save_i/load_i; float data is stored as raw IEEE-754 bit patterns
# (1.0f = 0x3f800000, 2.0f = 0x40000000, sum 3.0f = 0x40400000).

import code_generator.integer

c_lib "libcuda.so.1"
c_lib "libc.so.6"

extern char* malloc(int size)
extern int puts(char* s)
extern int printf(char* fmt, int a, int b)
extern int fflush(int stream)

extern int cuInit(int flags)
extern int cuDeviceGet(char* device, int ordinal)
extern int cuCtxCreate_v2(char* pctx, int flags, int dev)
extern int cuModuleLoadData(char* module, char* image)
extern int cuModuleGetFunction(char* func, int module, char* name)
extern int cuMemAlloc_v2(char* dptr, int bytesize)
extern int cuMemcpyHtoD_v2(int dst, char* src, int bytesize)
extern int cuMemcpyDtoH_v2(char* dst, int src, int bytesize)
extern int cuLaunchKernel(int f, int gx, int gy, int gz, int bx, int by, int bz, int shared, int stream, char* params, int extra)
extern int cuCtxSynchronize()


int had_error

void check(int err, char* name):
	if (err != 0):
		printf(c"CUDA error %d at %s\x0a", err, name)
		had_error = 1


# An 8-byte, zero-initialized cell (for a handle or device pointer output).
char* cell():
	char* c = malloc(8)
	save_i(c, 0, 8)
	return c


int _main():
	char* ptx = c".version 6.0\x0a.target sm_52\x0a.address_size 64\x0a.visible .entry vecAdd(.param .u64 a, .param .u64 b, .param .u64 c, .param .u32 n)\x0a{\x0a.reg .pred %p<2>;\x0a.reg .f32 %f<4>;\x0a.reg .b32 %r<6>;\x0a.reg .b64 %rd<11>;\x0ald.param.u64 %rd1, [a];\x0ald.param.u64 %rd2, [b];\x0ald.param.u64 %rd3, [c];\x0ald.param.u32 %r2, [n];\x0amov.u32 %r3, %ntid.x;\x0amov.u32 %r4, %ctaid.x;\x0amov.u32 %r5, %tid.x;\x0amad.lo.s32 %r1, %r4, %r3, %r5;\x0asetp.ge.s32 %p1, %r1, %r2;\x0a@%p1 bra DONE;\x0acvta.to.global.u64 %rd4, %rd1;\x0acvta.to.global.u64 %rd5, %rd2;\x0acvta.to.global.u64 %rd6, %rd3;\x0amul.wide.s32 %rd7, %r1, 4;\x0aadd.s64 %rd8, %rd4, %rd7;\x0aadd.s64 %rd9, %rd5, %rd7;\x0aadd.s64 %rd10, %rd6, %rd7;\x0ald.global.f32 %f1, [%rd8];\x0ald.global.f32 %f2, [%rd9];\x0aadd.f32 %f3, %f1, %f2;\x0ast.global.f32 [%rd10], %f3;\x0aDONE:\x0aret;\x0a}\x0a"

	int n = 256
	int bytes = n * 4

	# Host inputs: a[i]=1.0f, b[i]=2.0f
	char* h_a = malloc(bytes)
	char* h_b = malloc(bytes)
	char* h_c = malloc(bytes)
	int i = 0
	while (i < n):
		save_i(h_a + i * 4, 0x3f800000, 4)
		save_i(h_b + i * 4, 0x40000000, 4)
		i = i + 1

	check(cuInit(0), c"cuInit")
	if (had_error):
		puts(c"cuda smoke: no CUDA driver available")
		fflush(0)
		return 1

	char* dev = cell()
	check(cuDeviceGet(dev, 0), c"cuDeviceGet")
	char* ctx = cell()
	check(cuCtxCreate_v2(ctx, 0, load_i(dev, 8)), c"cuCtxCreate")
	if (had_error):
		puts(c"cuda smoke: could not create a context")
		fflush(0)
		return 1

	char* module = cell()
	check(cuModuleLoadData(module, ptx), c"cuModuleLoadData")
	char* func = cell()
	check(cuModuleGetFunction(func, load_i(module, 8), c"vecAdd"), c"cuModuleGetFunction")

	char* d_a = cell()
	char* d_b = cell()
	char* d_c = cell()
	check(cuMemAlloc_v2(d_a, bytes), c"cuMemAlloc a")
	check(cuMemAlloc_v2(d_b, bytes), c"cuMemAlloc b")
	check(cuMemAlloc_v2(d_c, bytes), c"cuMemAlloc c")

	check(cuMemcpyHtoD_v2(load_i(d_a, 8), h_a, bytes), c"cuMemcpyHtoD a")
	check(cuMemcpyHtoD_v2(load_i(d_b, 8), h_b, bytes), c"cuMemcpyHtoD b")

	# kernelParams: a void** where each entry points to one argument value.
	char* pn = cell()
	save_i(pn, n, 4)
	char* params = malloc(8 * 4)
	save_i(params + 0, d_a, 8)
	save_i(params + 8, d_b, 8)
	save_i(params + 16, d_c, 8)
	save_i(params + 24, pn, 8)

	int threads = 256
	int blocks = (n + threads - 1) / threads
	check(cuLaunchKernel(load_i(func, 8), blocks, 1, 1, threads, 1, 1, 0, 0, params, 0), c"cuLaunchKernel")
	check(cuCtxSynchronize(), c"cuCtxSynchronize")
	check(cuMemcpyDtoH_v2(h_c, load_i(d_c, 8), bytes), c"cuMemcpyDtoH c")

	# Verify every element equals 3.0f.
	int ok = 1
	i = 0
	while (i < n):
		if (load_i(h_c + i * 4, 4) != 0x40400000):
			ok = 0
		i = i + 1

	if (had_error):
		puts(c"cuda smoke: FAILED (driver error)")
		fflush(0)
		return 1
	if (ok == 0):
		puts(c"cuda smoke: FAILED (wrong results)")
		fflush(0)
		return 1

	puts(c"cuda vector add OK")
	fflush(0)
	return 0
