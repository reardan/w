# Errno classification shared by native I/O and cooperative task results.
# wbuild: x64
import lib.testing
import lib.io
import lib.io_wait
import lib.fs_flags_arm64

void test_native_errno_categories_preserve_native_values():
	io_result r
	assert_equal(IO_WOULD_BLOCK, io_result_from_syscall(&r, 0 - IO_ERRNO_EAGAIN))
	assert_equal(IO_ERRNO_EAGAIN, r.native_error)
	assert_equal(IO_TIMED_OUT, io_result_from_syscall(&r, 0 - IO_ERRNO_ETIMEDOUT))
	assert_equal(IO_CANCELLED, io_result_from_syscall(&r, 0 - IO_ERRNO_ECANCELED))
	assert_equal(IO_UNSUPPORTED, io_result_from_syscall(&r, 0 - IO_ERRNO_ENOTSUP))
	assert_equal(IO_ERRNO_ENOTSUP, r.native_error)
	assert_equal(IO_UNSUPPORTED, io_result_from_syscall(&r, 0 - IO_ERRNO_ENOSYS))
	assert_equal(IO_WOULD_BLOCK, io_result_from_syscall(&r, io_wait(-1, 1, 0)))
	assert_equal(IO_IO_ERROR, io_result_from_syscall(&r, 0 - IO_ERRNO_EDEADLK))

# wbuild: target=native_qualification_cross_test tag=tests dep=wv2
# wbuild: step="python3 tools/qualify_native.py --cross arm64 arm64_darwin --rounds 1"
# wbuild: step="bin/wv2 arm64_darwin tests/native_qualification_test.w -o bin/native_errno_darwin_test"
# wbuild: target=native_qualification_host_test tag=tests dep=wv2
# wbuild: step="python3 tools/qualify_native.py --host-smoke --rounds 1"

void test_arm64_openat_flag_translation():
	assert_equal(16384, arm64_fs_open_flags(65536))
	assert_equal(32768, arm64_fs_open_flags(131072))
	assert_equal(65536, arm64_fs_open_flags(16384))
	assert_equal(131072, arm64_fs_open_flags(32768))
	assert_equal(2 | 64 | 128 | 524288, arm64_fs_open_flags(2 | 64 | 128 | 524288))
	assert_equal(16384 | 524288, arm64_fs_open_flags(65536 | 524288))
