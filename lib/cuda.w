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
gpu_memcpy_from(dst_host, src_dev, bytes), gpu_sync(),
gpu_available().

DEVICE SELECTION: the runtime drives one "current" device. Lazy init
picks ordinal 0, or $W_GPU_DEVICE=<n> when set; gpu_set_device(n)
selects explicitly and may be called at any time, before or after the
first GPU use. Each device gets its own context, JIT-loaded module and
kernel-handle cache entries, created on first use of that device and
kept for the life of the process; switching back is a cuCtxSetCurrent,
not a re-init. Memory, launches and gpu_sync() apply to the device
that is current when they run: free and copy a buffer with the device
it was allocated on current, and gpu_sync() waits only for the current
device's work. gpu_device_count() never exits (0 when the driver has
no usable device); an out-of-range ordinal (gpu_set_device or
W_GPU_DEVICE) is a fatal, clearly worded error, and
gpu_try_set_device(n) is its non-exiting form. The runtime is
single-threaded: contexts are made current on the calling thread.

ERRORS: the plain API above prints the CUresult code, its name and
description (cuGetErrorName/cuGetErrorString) and exit(1)s — the
default, since GPU state after most errors is not recoverable at this
layer. The gpu_try_* variants never exit: gpu_try_alloc and
gpu_try_device_alloc return 0 on failure; gpu_try_memcpy_to,
gpu_try_memcpy_from, gpu_try_free, gpu_try_sync and
gpu_try_set_device return the CUresult (0 = success). Every failing
driver call (try or fatal path) records its code for gpu_last_error()
(a peek: it is not reset by later successes; gpu_clear_error() resets
it). gpu_error_name(code)/gpu_error_string(code) map a code to its
CUDA_ERROR_* name/description. Launches are async, so a faulting
kernel reports nothing at 'launch' — its error surfaces at the next
gpu_sync()/gpu_try_sync() (or blocking copy), and errors such as
CUDA_ERROR_ILLEGAL_ADDRESS are sticky: that context is unusable
afterwards.

The _v2 symbol names are the current libcuda ABI revisions (the CUDA
headers hide the renaming; see docs/projects/cuda.md H1).
*/
import lib.lib
import lib.env
import code_generator.integer
import lib.mem

c_lib "libcuda.so.1"

extern int cuInit(int flags)
extern int cuDeviceGet(char* device, int ordinal)
extern int cuDeviceGetCount(char* count)
extern int cuCtxCreate_v2(char* pctx, int flags, int dev)
extern int cuCtxSetCurrent(int ctx)
extern int cuModuleLoadData(char* module, char* image)
extern int cuModuleGetFunction(char* func, int module, char* name)
extern int cuMemAllocManaged(char* dptr, int bytesize, int flags)
extern int cuMemAlloc_v2(char* dptr, int bytesize)
extern int cuMemcpyHtoD_v2(int dst, char* src, int bytesize)
extern int cuMemcpyDtoH_v2(char* dst, int src, int bytesize)
extern int cuMemFree_v2(int dptr)
extern int cuLaunchKernel(int f, int gx, int gy, int gz, int bx, int by, int bz, int shared, int stream, char* params, int extra)
extern int cuCtxSynchronize()
extern int cuGetErrorName(int error, char* pstr)
extern int cuGetErrorString(int error, char* pstr)

# The embedded PTX module text, synthesized by the compiler for every
# program that defines kernels.
char* __w_ptx_module();


# CUresult values the runtime reports itself.
int CUDA_ERROR_NO_DEVICE = 100
int CUDA_ERROR_INVALID_DEVICE = 101

# The last failing CUresult (see gpu_last_error) and the stage that
# produced it.
int __w_gpu_last_error
char* __w_gpu_last_what

# Driver probe: 0 not yet run, 1 usable, 2 failed (__w_gpu_driver_err
# holds the CUresult).
int __w_gpu_driver_state
int __w_gpu_driver_err
int __w_gpu_device_total

# Device selection: __w_gpu_device is meaningful once
# __w_gpu_device_chosen is set (by gpu_set_device, or by lazy init
# from W_GPU_DEVICE / the default 0). __w_gpu_ready caches "the chosen
# device's context exists and is current" so the per-launch init check
# stays one load.
int __w_gpu_device
int __w_gpu_device_chosen
int __w_gpu_ready

# Per-device state, indexed by ordinal (8-byte cells, 0 = not yet
# created): the context and the JIT-loaded module handle.
char* __w_gpu_ctxs
char* __w_gpu_modules

# Kernel-handle cache: parallel name/device/handle arrays, linear
# lookup (a program has a handful of kernels; a handle is only valid
# in the module of the device it was fetched on).
char* __w_gpu_cache_names
char* __w_gpu_cache_devs
char* __w_gpu_cache_handles
int __w_gpu_cache_count
int __w_gpu_cache_capacity


# An 8-byte, zero-initialized output cell for a driver handle.
char* __w_gpu_cell():
	char* cell = malloc(8)
	save_i(cell, 0, 8)
	return cell


# The driver's static string for code (cuGetErrorName when want_name,
# else cuGetErrorString), or fallback when the driver does not know it.
char* __w_gpu_error_text(int code, int want_name, char* fallback):
	char* cell = __w_gpu_cell()
	int err = 0
	if (want_name):
		err = cuGetErrorName(code, cell)
	else:
		err = cuGetErrorString(code, cell)
	char* text = cast(char*, load_i(cell, 8))
	free(cell)
	if ((err != 0) || (text == 0)):
		return fallback
	return text


# "CUDA_ERROR_OUT_OF_MEMORY" for 2, "CUDA_SUCCESS" for 0, and
# "CUDA_ERROR_UNKNOWN_CODE" for a value the driver does not define.
char* gpu_error_name(int code):
	return __w_gpu_error_text(code, 1, c"CUDA_ERROR_UNKNOWN_CODE")


# The driver's human-readable description, e.g. "out of memory".
char* gpu_error_string(int code):
	return __w_gpu_error_text(code, 0, c"unrecognized CUresult code")


# Most recent failing CUresult from any runtime call, 0 if none. A
# peek: later successful calls do not reset it (gpu_clear_error does).
int gpu_last_error():
	return __w_gpu_last_error


void gpu_clear_error():
	__w_gpu_last_error = 0
	__w_gpu_last_what = 0


# Record err (when nonzero) as the last error; returns err.
int __w_gpu_note(int err, char* what):
	if (err != 0):
		__w_gpu_last_error = err
		__w_gpu_last_what = what
	return err


void __w_gpu_die(int err, char* what):
	print_error(c"cuda error ")
	print_error(itoa(err))
	print_error(c" ")
	print_error(gpu_error_name(err))
	print_error(c" (")
	print_error(gpu_error_string(err))
	print_error(c") at ")
	print_error(what)
	print_error(c"\x0a")
	exit(1)


void __w_gpu_check(int err, char* what):
	if (__w_gpu_note(err, what) != 0):
		__w_gpu_die(err, what)


# cuInit + device count, run once. Returns the probe's CUresult (0 =
# driver usable, possibly with zero devices).
int __w_gpu_driver():
	if (__w_gpu_driver_state == 1):
		return 0
	if (__w_gpu_driver_state == 2):
		return __w_gpu_note(__w_gpu_driver_err, c"cuInit")
	char* cell = __w_gpu_cell()
	int err = cuInit(0)
	if (err == 0):
		err = cuDeviceGetCount(cell)
	if (err != 0):
		free(cell)
		__w_gpu_driver_state = 2
		__w_gpu_driver_err = err
		__w_gpu_device_total = 0
		return __w_gpu_note(err, c"cuInit")
	__w_gpu_device_total = load_i(cell, 4)
	free(cell)
	int bytes = __w_gpu_device_total * 8 + 8
	__w_gpu_ctxs = malloc(bytes)
	__w_gpu_modules = malloc(bytes)
	int i = 0
	while (i < bytes):
		save_i(__w_gpu_ctxs + i, 0, 8)
		save_i(__w_gpu_modules + i, 0, 8)
		i = i + 8
	__w_gpu_driver_state = 1
	return 0


# Number of visible CUDA devices; 0 when the driver has none (e.g.
# CUDA_VISIBLE_DEVICES="") or fails to initialize. Never exits.
int gpu_device_count():
	if (__w_gpu_driver() != 0):
		return 0
	return __w_gpu_device_total


void __w_gpu_print_range(int n):
	print_error(c"device ordinal ")
	print_error(itoa(n))
	print_error(c" is out of range: ")
	print_error(itoa(__w_gpu_device_total))
	print_error(c" CUDA device(s) visible")
	if (__w_gpu_device_total > 0):
		print_error(c" (valid: 0..")
		print_error(itoa(__w_gpu_device_total - 1))
		print_error(c")")
	print_error(c"\x0a")


# 1 when s is a non-empty run of decimal digits (at most 9, so atoi
# cannot overflow).
int __w_gpu_is_ordinal(char* s):
	int i = 0
	while (s[i] != 0):
		if ((s[i] < '0') || (s[i] > '9')):
			return 0
		i = i + 1
	return (i > 0) && (i <= 9)


# Settle the device ordinal for lazy init: W_GPU_DEVICE when set and
# non-empty, else 0. Returns a CUresult; with loud set, a bad
# W_GPU_DEVICE is explained on stderr (the caller decides whether to
# exit).
int __w_gpu_choose(int loud):
	int err = __w_gpu_driver()
	if (err != 0):
		return err
	if (__w_gpu_device_chosen):
		return 0
	if (__w_gpu_device_total == 0):
		return __w_gpu_note(CUDA_ERROR_NO_DEVICE, c"cuDeviceGetCount")
	int n = 0
	char* env = env_get(c"W_GPU_DEVICE")
	if ((env != 0) && (env[0] != 0)):
		if (__w_gpu_is_ordinal(env) == 0):
			if (loud):
				print_error(c"cuda error: W_GPU_DEVICE=")
				print_error(env)
				print_error(c" is not a device ordinal (expected a non-negative integer)\x0a")
			return __w_gpu_note(CUDA_ERROR_INVALID_DEVICE, c"W_GPU_DEVICE")
		n = atoi(env)
		if (n >= __w_gpu_device_total):
			if (loud):
				print_error(c"cuda error: W_GPU_DEVICE=")
				print_error(env)
				print_error(c": ")
				__w_gpu_print_range(n)
			return __w_gpu_note(CUDA_ERROR_INVALID_DEVICE, c"W_GPU_DEVICE")
	__w_gpu_device = n
	__w_gpu_device_chosen = 1
	return 0


# Opt-in pre-compiled image (docs/projects/cuda.md "Execution notes
# (cubin embedding)"): synthesized by the compiler as an 8-byte image
# length followed by a ptxas cubin given with --cubin-file, length 0
# without one.
char* __w_cubin_module();

# Which image the last module load used: 0 none yet, 1 PTX (driver
# JIT), 2 embedded cubin. Read it with gpu_module_source().
int __w_gpu_module_source

# Load the embedded module into the current context, storing the
# CUmodule handle in cell: the cubin first when present (no JIT),
# falling back to the PTX when the driver rejects it — any error,
# typically CUDA_ERROR_NO_BINARY_FOR_GPU (209) for a cubin built for
# another sm_XX. The image is copied to a heap buffer first: the
# embedded bytes sit at an arbitrary code address. Returns the PTX
# load's CUresult (cubin failures are not recorded as errors).
int __w_gpu_load_module(char* cell, char* module_text):
	char* blob = __w_cubin_module()
	int n = load_i(blob, 8)
	int err = 1
	if (n > 0):
		char* image = malloc(n)
		mem_copy(image, blob + 8, n)
		err = cuModuleLoadData(cell, image)
		free(image)
		if (err == 0):
			__w_gpu_module_source = 2
	if (err != 0):
		save_i(cell, 0, 8)
		err = __w_gpu_note(cuModuleLoadData(cell, module_text), c"cuModuleLoadData")
		if (err == 0):
			__w_gpu_module_source = 1
	return err


int gpu_module_source():
	return __w_gpu_module_source


# Make the chosen device's context current, creating it (and loading
# the embedded module) on the device's first use. A program with no
# kernels (explicit-memory use only) has an empty module: skip the
# load — nothing could be launched anyway. Returns a CUresult.
int __w_gpu_try_init_loud(int loud):
	if (__w_gpu_ready):
		return 0
	int err = __w_gpu_choose(loud)
	if (err != 0):
		return err
	char* ctx_slot = __w_gpu_ctxs + __w_gpu_device * 8
	int ctx = load_i(ctx_slot, 8)
	if (ctx != 0):
		err = __w_gpu_note(cuCtxSetCurrent(ctx), c"cuCtxSetCurrent")
		if (err == 0):
			__w_gpu_ready = 1
		return err
	char* cell = __w_gpu_cell()
	err = __w_gpu_note(cuDeviceGet(cell, __w_gpu_device), c"cuDeviceGet")
	if (err == 0):
		int dev = load_i(cell, 4)
		save_i(cell, 0, 8)
		err = __w_gpu_note(cuCtxCreate_v2(cell, 0, dev), c"cuCtxCreate")
	if (err == 0):
		save_i(ctx_slot, load_i(cell, 8), 8)
		char* module_text = __w_ptx_module()
		if (module_text[0] != 0):
			save_i(cell, 0, 8)
			err = __w_gpu_load_module(cell, module_text)
			if (err == 0):
				save_i(__w_gpu_modules + __w_gpu_device * 8, load_i(cell, 8), 8)
	free(cell)
	if (err == 0):
		__w_gpu_ready = 1
	return err


int __w_gpu_try_init():
	return __w_gpu_try_init_loud(0)


# Fatal init for the plain API.
void __w_gpu_init():
	if (__w_gpu_ready):
		return;
	int err = __w_gpu_try_init_loud(1)
	if (err != 0):
		__w_gpu_die(err, __w_gpu_last_what)


# Select device n (0-based) for all later GPU work; see the module
# comment. Returns 0, CUDA_ERROR_INVALID_DEVICE for an out-of-range
# ordinal, or the driver's CUresult. Never exits. The switch itself is
# lazy: the context is created / made current by the next GPU call.
int gpu_try_set_device(int n):
	int err = __w_gpu_driver()
	if (err != 0):
		return err
	if ((n < 0) || (n >= __w_gpu_device_total)):
		return __w_gpu_note(CUDA_ERROR_INVALID_DEVICE, c"gpu_set_device")
	if ((__w_gpu_device_chosen == 0) || (__w_gpu_device != n)):
		__w_gpu_ready = 0
	__w_gpu_device = n
	__w_gpu_device_chosen = 1
	return 0


void gpu_set_device(int n):
	int err = gpu_try_set_device(n)
	if (err == CUDA_ERROR_INVALID_DEVICE):
		print_error(c"cuda error: gpu_set_device(")
		print_error(itoa(n))
		print_error(c"): ")
		__w_gpu_print_range(n)
		exit(1)
	if (err != 0):
		__w_gpu_die(err, c"gpu_set_device")


# The current device ordinal (resolving W_GPU_DEVICE if nothing has
# been selected yet), or -1 when no device is usable. Never exits.
int gpu_get_device():
	if (__w_gpu_choose(0) != 0):
		return 0 - 1
	return __w_gpu_device


int __w_gpu_kernel_handle(char* name):
	int i = 0
	while (i < __w_gpu_cache_count):
		if (load_i(__w_gpu_cache_devs + i * 8, 8) == __w_gpu_device):
			if (strcmp(cast(char*, load_ptr(__w_gpu_cache_names + i * __word_size__)), name) == 0):
				return load_i(__w_gpu_cache_handles + i * 8, 8)
		i = i + 1
	char* func = __w_gpu_cell()
	int module = load_i(__w_gpu_modules + __w_gpu_device * 8, 8)
	__w_gpu_check(cuModuleGetFunction(func, module, name), c"cuModuleGetFunction")
	int handle = load_i(func, 8)
	free(func)
	if (__w_gpu_cache_count >= __w_gpu_cache_capacity):
		int old = __w_gpu_cache_capacity
		__w_gpu_cache_capacity = (__w_gpu_cache_capacity + 8) << 1
		__w_gpu_cache_names = realloc(__w_gpu_cache_names, old * __word_size__, __w_gpu_cache_capacity * __word_size__)
		__w_gpu_cache_devs = realloc(__w_gpu_cache_devs, old * 8, __w_gpu_cache_capacity * 8)
		__w_gpu_cache_handles = realloc(__w_gpu_cache_handles, old * 8, __w_gpu_cache_capacity * 8)
	save_ptr(__w_gpu_cache_names + __w_gpu_cache_count * __word_size__, cast(int, strclone(name)))
	save_i(__w_gpu_cache_devs + __w_gpu_cache_count * 8, __w_gpu_device, 8)
	save_i(__w_gpu_cache_handles + __w_gpu_cache_count * 8, handle, 8)
	__w_gpu_cache_count = __w_gpu_cache_count + 1
	return handle


# The 'launch' statement's entry point. vals points at the LAST-pushed
# argument cell: argument i (declaration order) lives at
# vals + (count-1-i)*8. cuLaunchKernel copies the parameter values
# before returning, so the cells may die with the caller's statement.
# Launch-configuration errors exit here; faults inside the kernel
# surface later, at the next sync or blocking copy.
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


# Cached driver+device probe: 0 unknown, 1 usable, 2 unusable. Unlike
# the launch path this does not exit on failure — it is the branch
# point for CPU fallbacks (docs/projects/torch.md Stage 1). cuInit
# alone is not enough: it can succeed with zero devices (e.g. under
# CUDA_VISIBLE_DEVICES=""), so the device count and the selected
# ordinal (gpu_set_device / W_GPU_DEVICE) are checked too; a bad
# W_GPU_DEVICE is reported on stderr and reads as "unavailable". Note
# the limit: a program importing this module still needs libcuda.so.1
# present at load time (eager dynamic linking), so this covers "driver
# present, no usable GPU", not a missing driver.
int __w_gpu_avail_state

int gpu_available():
	if (__w_gpu_avail_state == 0):
		__w_gpu_avail_state = 2
		if (__w_gpu_choose(1) == 0):
			char* dev = __w_gpu_cell()
			if (cuDeviceGet(dev, __w_gpu_device) == 0):
				__w_gpu_avail_state = 1
			free(dev)
	return __w_gpu_avail_state == 1


# Managed allocation, or 0 on failure (the CUresult goes to
# gpu_last_error). Never exits.
char* gpu_try_alloc(int bytes):
	if (__w_gpu_try_init() != 0):
		return 0
	char* cell = __w_gpu_cell()
	int err = __w_gpu_note(cuMemAllocManaged(cell, bytes, 1), c"cuMemAllocManaged")
	int p = load_i(cell, 8)
	free(cell)
	if (err != 0):
		return 0
	return cast(char*, p)


# Device-only allocation, or 0 on failure (see gpu_device_alloc).
# Never exits.
char* gpu_try_device_alloc(int bytes):
	if (__w_gpu_try_init() != 0):
		return 0
	char* cell = __w_gpu_cell()
	int err = __w_gpu_note(cuMemAlloc_v2(cell, bytes), c"cuMemAlloc")
	int p = load_i(cell, 8)
	free(cell)
	if (err != 0):
		return 0
	return cast(char*, p)


# Managed allocation (CU_MEM_ATTACH_GLOBAL): one pointer valid on host
# and device. Remember the async contract above.
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


# Host -> device copy; returns the CUresult. Blocks the host; ordered
# after prior launches.
int gpu_try_memcpy_to(char* dst_dev, char* src_host, int bytes):
	int err = __w_gpu_try_init()
	if (err != 0):
		return err
	return __w_gpu_note(cuMemcpyHtoD_v2(cast(int, dst_dev), src_host, bytes), c"cuMemcpyHtoD")


# Device -> host copy; returns the CUresult. The copy waits for prior
# launches, so an earlier kernel fault can surface here.
int gpu_try_memcpy_from(char* dst_host, char* src_dev, int bytes):
	int err = __w_gpu_try_init()
	if (err != 0):
		return err
	return __w_gpu_note(cuMemcpyDtoH_v2(dst_host, cast(int, src_dev), bytes), c"cuMemcpyDtoH")


int gpu_try_free(char* p):
	int err = __w_gpu_try_init()
	if (err != 0):
		return err
	return __w_gpu_note(cuMemFree_v2(cast(int, p)), c"cuMemFree")


# Wait for the current device's enqueued work; returns the CUresult —
# the point where an async kernel fault is reported.
int gpu_try_sync():
	int err = __w_gpu_try_init()
	if (err != 0):
		return err
	return __w_gpu_note(cuCtxSynchronize(), c"cuCtxSynchronize")


# Host -> device copy. Blocks the host; ordered after prior launches.
void gpu_memcpy_to(char* dst_dev, char* src_host, int bytes):
	__w_gpu_init()
	__w_gpu_check(cuMemcpyHtoD_v2(cast(int, dst_dev), src_host, bytes), c"cuMemcpyHtoD")


# Device -> host copy. Blocks the host; ordered after prior launches,
# so a copy-back after a launch implicitly waits for the kernel.
void gpu_memcpy_from(char* dst_host, char* src_dev, int bytes):
	__w_gpu_init()
	__w_gpu_check(cuMemcpyDtoH_v2(dst_host, cast(int, src_dev), bytes), c"cuMemcpyDtoH")


void gpu_free(char* p):
	__w_gpu_init()
	__w_gpu_check(cuMemFree_v2(cast(int, p)), c"cuMemFree")


# Block until every launch enqueued on the current device has finished.
void gpu_sync():
	__w_gpu_init()
	__w_gpu_check(cuCtxSynchronize(), c"cuCtxSynchronize")
