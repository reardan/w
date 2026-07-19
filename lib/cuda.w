/*
CUDA host runtime for gpu kernels (docs/projects/cuda.md, Stage 2/3).

Programs using 'launch' or 'gpu for' must import this module — the
compiler checks for __w_gpu_launch_raw and errors with "gpu code
requires 'import lib.cuda'" otherwise (the lib.generator precedent).
Only the driver API is used (libcuda.so.1 ships with the NVIDIA
driver): the embedded PTX module (__w_ptx_module, synthesized by the
compiler) is JIT-loaded on first use, kernel handles are cached by
name, and memory comes from cuMemAllocManaged so one pointer is valid
on both host and device (the MVP memory model).

LAUNCHES ARE ASYNC: 'launch' and 'gpu for' enqueue work and return.
Call gpu_sync() before the host reads or writes any buffer an
in-flight kernel touches; gpu_alloc'd managed memory must not be
accessed concurrently from both sides.

Alongside the managed path there is an explicit one (Stage 4):
gpu_device_alloc(bytes) returns device-only memory (cuMemAlloc — no
page migration, the performance-oriented path; the pointer is only
meaningful inside kernels) and gpu_memcpy_to/gpu_memcpy_from move
bytes across. The copies use the non-async cuMemcpy forms on the
default stream: they start after every previously enqueued launch
finishes and block the host until done, so a gpu_memcpy_from after a
launch implicitly waits for it — no gpu_sync() needed on the explicit
path. Atomics and kernel stores must only target device-accessible
memory (gpu_alloc/gpu_device_alloc), never host malloc or stack
addresses.

User API: gpu_alloc(bytes), gpu_device_alloc(bytes), gpu_free(p),
gpu_memcpy_to(dst_dev, src_host, bytes),
gpu_memcpy_from(dst_host, src_dev, bytes), gpu_sync().

Driver errors print the CUresult code and exit(1) — GPU state after an
error is not recoverable at this layer. The _v2 symbol names are the
current libcuda ABI revisions (the CUDA headers hide the renaming; see
docs/projects/cuda.md H1).
*/
import lib.lib
import code_generator.integer

c_lib "libcuda.so.1"

extern int cuInit(int flags)
extern int cuDeviceGet(char* device, int ordinal)
extern int cuCtxCreate_v2(char* pctx, int flags, int dev)
extern int cuModuleLoadData(char* module, char* image)
extern int cuModuleGetFunction(char* func, int module, char* name)
extern int cuMemAllocManaged(char* dptr, int bytesize, int flags)
extern int cuMemAlloc_v2(char* dptr, int bytesize)
extern int cuMemcpyHtoD_v2(int dst, char* src, int bytesize)
extern int cuMemcpyDtoH_v2(char* dst, int src, int bytesize)
extern int cuMemFree_v2(int dptr)
extern int cuLaunchKernel(int f, int gx, int gy, int gz, int bx, int by, int bz, int shared, int stream, char* params, int extra)
extern int cuCtxSynchronize()

# The embedded PTX module text, synthesized by the compiler for every
# program that defines kernels.
char* __w_ptx_module();


int __w_gpu_inited
int __w_gpu_module

# Kernel-handle cache: parallel name/handle arrays, linear lookup (a
# program has a handful of kernels).
char* __w_gpu_cache_names
char* __w_gpu_cache_handles
int __w_gpu_cache_count
int __w_gpu_cache_capacity


void __w_gpu_check(int err, char* what):
	if (err != 0):
		print_error(c"cuda error ")
		print_error(itoa(err))
		print_error(c" at ")
		print_error(what)
		print_error(c"\x0a")
		exit(1)


# An 8-byte, zero-initialized output cell for a driver handle.
char* __w_gpu_cell():
	char* cell = malloc(8)
	save_i(cell, 0, 8)
	return cell


# One-time driver init + context + JIT-load of the embedded module.
# A program with no kernels (explicit-memory use only) has an empty
# module: skip the load — nothing could be launched anyway.
void __w_gpu_init():
	if (__w_gpu_inited):
		return;
	__w_gpu_check(cuInit(0), c"cuInit")
	char* dev = __w_gpu_cell()
	__w_gpu_check(cuDeviceGet(dev, 0), c"cuDeviceGet")
	char* ctx = __w_gpu_cell()
	__w_gpu_check(cuCtxCreate_v2(ctx, 0, load_i(dev, 8)), c"cuCtxCreate")
	char* module_text = __w_ptx_module()
	if (module_text[0] != 0):
		char* module = __w_gpu_cell()
		__w_gpu_check(cuModuleLoadData(module, module_text), c"cuModuleLoadData")
		__w_gpu_module = load_i(module, 8)
		free(module)
	free(dev)
	free(ctx)
	__w_gpu_inited = 1


int __w_gpu_kernel_handle(char* name):
	int i = 0
	while (i < __w_gpu_cache_count):
		if (strcmp(cast(char*, load_ptr(__w_gpu_cache_names + i * __word_size__)), name) == 0):
			return load_i(__w_gpu_cache_handles + i * 8, 8)
		i = i + 1
	char* func = __w_gpu_cell()
	__w_gpu_check(cuModuleGetFunction(func, __w_gpu_module, name), c"cuModuleGetFunction")
	int handle = load_i(func, 8)
	free(func)
	if (__w_gpu_cache_count >= __w_gpu_cache_capacity):
		int old = __w_gpu_cache_capacity
		__w_gpu_cache_capacity = (__w_gpu_cache_capacity + 8) << 1
		__w_gpu_cache_names = realloc(__w_gpu_cache_names, old * __word_size__, __w_gpu_cache_capacity * __word_size__)
		__w_gpu_cache_handles = realloc(__w_gpu_cache_handles, old * 8, __w_gpu_cache_capacity * 8)
	save_ptr(__w_gpu_cache_names + __w_gpu_cache_count * __word_size__, cast(int, strclone(name)))
	save_i(__w_gpu_cache_handles + __w_gpu_cache_count * 8, handle, 8)
	__w_gpu_cache_count = __w_gpu_cache_count + 1
	return handle


# The 'launch' statement's entry point. vals points at the LAST-pushed
# argument cell: argument i (declaration order) lives at
# vals + (count-1-i)*8. cuLaunchKernel copies the parameter values
# before returning, so the cells may die with the caller's statement.
void __w_gpu_launch_raw(char* name, int grid, int block, char* vals, int count):
	__w_gpu_init()
	int f = __w_gpu_kernel_handle(name)
	char* params = malloc(count * 8 + 8)
	int i = 0
	while (i < count):
		save_ptr(params + i * 8, cast(int, vals) + (count - 1 - i) * 8)
		i = i + 1
	__w_gpu_check(cuLaunchKernel(f, grid, 1, 1, block, 1, 1, 0, 0, params, 0), c"cuLaunchKernel")
	free(params)


# The 'gpu for' entry point: one thread per iteration, 256-thread
# blocks, grid sized to cover n (the kernel carries the i < n guard).
void __w_gpu_launch(char* name, int n, char* vals, int count):
	if (n <= 0):
		return;
	int block = 256
	int grid = (n + block - 1) / block
	__w_gpu_launch_raw(name, grid, block, vals, count)


# Managed allocation: one pointer valid on host and device
# (CU_MEM_ATTACH_GLOBAL). Remember the async contract above.
char* gpu_alloc(int bytes):
	__w_gpu_init()
	char* cell = __w_gpu_cell()
	__w_gpu_check(cuMemAllocManaged(cell, bytes, 1), c"cuMemAllocManaged")
	int p = load_i(cell, 8)
	free(cell)
	return cast(char*, p)


# Device-only allocation (no page migration): the returned pointer is
# only dereferenceable inside kernels; move data with gpu_memcpy_to/
# gpu_memcpy_from. Freed with the same gpu_free.
char* gpu_device_alloc(int bytes):
	__w_gpu_init()
	char* cell = __w_gpu_cell()
	__w_gpu_check(cuMemAlloc_v2(cell, bytes), c"cuMemAlloc")
	int p = load_i(cell, 8)
	free(cell)
	return cast(char*, p)


# Host -> device copy. Blocks the host; ordered after prior launches.
void gpu_memcpy_to(char* dst_dev, char* src_host, int bytes):
	__w_gpu_check(cuMemcpyHtoD_v2(cast(int, dst_dev), src_host, bytes), c"cuMemcpyHtoD")


# Device -> host copy. Blocks the host; ordered after prior launches,
# so a copy-back after a launch implicitly waits for the kernel.
void gpu_memcpy_from(char* dst_host, char* src_dev, int bytes):
	__w_gpu_check(cuMemcpyDtoH_v2(dst_host, cast(int, src_dev), bytes), c"cuMemcpyDtoH")


void gpu_free(char* p):
	__w_gpu_check(cuMemFree_v2(cast(int, p)), c"cuMemFree")


# Block until every enqueued launch has finished.
void gpu_sync():
	__w_gpu_check(cuCtxSynchronize(), c"cuCtxSynchronize")
