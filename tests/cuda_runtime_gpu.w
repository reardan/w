# lib/cuda.w runtime surface: device selection (gpu_device_count,
# gpu_set_device, W_GPU_DEVICE) and recoverable CUresult handling
# (gpu_try_*, gpu_last_error, gpu_error_name/_string). With a GPU the
# default mode checks count >= 1, set_device(0) + a launch, an
# absurd-size try-alloc failing with a sensible error while the program
# keeps working, and finally an async kernel fault surfacing at
# gpu_try_sync (sticky, so it runs last). Without a usable device
# (CUDA_VISIBLE_DEVICES=) it checks that count is 0 and every try
# variant fails gracefully. Mode arguments exercise the fatal paths:
# "set_out_of_range" (gpu_set_device(count)), "fatal_oom" (the named
# CUresult in the exit message) and "alloc" (lazy init, run under
# W_GPU_DEVICE=0 and =99 by the sidecar). x64 only
# (libcuda.so is 64-bit); the targets live in the .wbuild sidecar.
import lib.lib
import lib.args
import lib.cuda

kernel fill(int* out, int v, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		out[i] = v + i


int failures


void check(int ok, char* what):
	if (ok == 0):
		print(c"cuda runtime: FAILED ")
		println(what)
		failures = failures + 1


int streq(char* a, char* b):
	return strcmp(a, b) == 0


# Launch fill on managed memory and verify, on whatever device is
# current.
int launch_works(int n):
	int* out = cast(int*, gpu_alloc(n * 8))
	int threads = 128
	launch fill[(n + threads - 1) / threads, threads](out, 5, n)
	gpu_sync()
	int ok = 1
	int i = 0
	while (i < n):
		if (out[i] != 5 + i):
			ok = 0
		i = i + 1
	gpu_free(cast(char*, out))
	return ok


void error_strings():
	check(streq(gpu_error_name(0), c"CUDA_SUCCESS"), c"gpu_error_name(0)")
	check(streq(gpu_error_name(2), c"CUDA_ERROR_OUT_OF_MEMORY"), c"gpu_error_name(2)")
	check(streq(gpu_error_string(2), c"out of memory"), c"gpu_error_string(2)")
	check(streq(gpu_error_name(123456), c"CUDA_ERROR_UNKNOWN_CODE"), c"gpu_error_name(unknown)")


void no_gpu_path():
	println(c"cuda runtime: no gpu path")
	check(gpu_available() == 0, c"gpu_available() with no device")
	check(gpu_get_device() == 0 - 1, c"gpu_get_device() with no device")
	check(gpu_try_alloc(64) == 0, c"gpu_try_alloc with no device")
	check(gpu_last_error() != 0, c"gpu_last_error after failed try_alloc")
	check(gpu_try_device_alloc(64) == 0, c"gpu_try_device_alloc with no device")
	check(gpu_try_sync() != 0, c"gpu_try_sync with no device")
	check(gpu_try_set_device(0) != 0, c"gpu_try_set_device(0) with no device")
	char* host = malloc(8)
	check(gpu_try_memcpy_from(host, host, 8) != 0, c"gpu_try_memcpy_from with no device")
	free(host)
	print(c"cuda runtime: no-device error ")
	println(gpu_error_name(gpu_last_error()))


void gpu_path(int count):
	println(c"cuda runtime: gpu path")
	check(count >= 1, c"gpu_device_count() >= 1")
	check(gpu_available(), c"gpu_available()")
	check(gpu_get_device() == 0, c"default device is 0")
	check(gpu_try_set_device(count) == 101, c"gpu_try_set_device(count) is CUDA_ERROR_INVALID_DEVICE")
	check(gpu_try_set_device(0 - 1) == 101, c"gpu_try_set_device(-1) is CUDA_ERROR_INVALID_DEVICE")
	gpu_clear_error()
	gpu_set_device(0)
	check(gpu_get_device() == 0, c"gpu_set_device(0)")
	check(launch_works(1000), c"launch after gpu_set_device(0)")

	# Switching away and back (to the same device when only one exists)
	# must keep the cached context, module and kernel handle usable.
	gpu_set_device(count - 1)
	check(launch_works(300), c"launch on the last device")
	gpu_set_device(0)
	check(launch_works(300), c"launch after switching back to device 0")

	# Recoverable failure: 1 PiB cannot be allocated.
	int absurd = 1 << 50
	check(gpu_last_error() == 0, c"no error recorded yet")
	check(gpu_try_device_alloc(absurd) == 0, c"gpu_try_device_alloc(1 PiB) returns 0")
	int err = gpu_last_error()
	check(err != 0, c"gpu_last_error nonzero after failed device alloc")
	print(c"cuda runtime: absurd device alloc -> ")
	print(gpu_error_name(err))
	print(c": ")
	println(gpu_error_string(err))
	check(streq(gpu_error_name(err), c"CUDA_ERROR_UNKNOWN_CODE") == 0, c"error name is a real CUresult name")
	gpu_clear_error()
	check(gpu_try_alloc(absurd) == 0, c"gpu_try_alloc(1 PiB) returns 0")
	check(gpu_last_error() != 0, c"gpu_last_error nonzero after failed managed alloc")

	# The program continues: normal allocation, copies and launches.
	char* ok_buf = gpu_try_device_alloc(4096)
	check(ok_buf != 0, c"gpu_try_device_alloc(4096) after a failure")
	char* host = malloc(4096)
	save_i(host, 1234567, 8)
	check(gpu_try_memcpy_to(ok_buf, host, 4096) == 0, c"gpu_try_memcpy_to")
	save_i(host, 0, 8)
	check(gpu_try_memcpy_from(host, ok_buf, 4096) == 0, c"gpu_try_memcpy_from")
	check(load_i(host, 8) == 1234567, c"round trip through device memory")
	check(gpu_try_free(ok_buf) == 0, c"gpu_try_free")
	free(host)
	check(launch_works(512), c"launch after a recovered error")
	check(gpu_try_sync() == 0, c"gpu_try_sync with no pending fault")

	# Async fault: the launch itself succeeds, the illegal store is
	# reported at the sync. Sticky — nothing may use the GPU after this.
	gpu_clear_error()
	int* bad = cast(int*, 8)
	launch fill[1, 32](bad, 0, 32)
	int sync_err = gpu_try_sync()
	print(c"cuda runtime: faulting kernel -> ")
	println(gpu_error_name(sync_err))
	check(sync_err != 0, c"kernel fault surfaces at gpu_try_sync")
	check(gpu_last_error() == sync_err, c"gpu_last_error records the sync error")


int main(int argc, int argv):
	args_init(argc, argv)
	error_strings()
	int count = gpu_device_count()
	if ((argc > 1) && streq(args_get(1), c"set_out_of_range")):
		gpu_set_device(count)
		println(c"cuda runtime: FAILED (gpu_set_device(count) returned)")
		return 1
	if ((argc > 1) && streq(args_get(1), c"alloc")):
		gpu_free(gpu_alloc(64))
		print(c"cuda runtime: allocated on device ")
		println(itoa(gpu_get_device()))
		return 0
	if ((argc > 1) && streq(args_get(1), c"fatal_oom")):
		gpu_device_alloc(1 << 50)
		println(c"cuda runtime: FAILED (absurd gpu_device_alloc returned)")
		return 1
	if (count == 0):
		no_gpu_path()
	else:
		gpu_path(count)
	if (failures != 0):
		return 1
	println(c"cuda runtime OK")
	return 0
