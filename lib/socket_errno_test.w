# wbuild: x64
import lib.testing
import lib.net
import lib.socket_errno_darwin


void test_darwin_socket_errno_collisions_are_generic_errors():
	# Darwin ENOTSOCK must not become Linux ENOSYS/unsupported;
	# Darwin EDEADLK must not become Linux EAGAIN/would-block.
	assert_equal(IO_IO_ERROR, io_status_from_errno(socket_darwin_status_errno(38)))
	assert_equal(IO_IO_ERROR, io_status_from_errno(socket_darwin_status_errno(11)))
	assert_equal(IO_IO_ERROR, io_status_from_errno(socket_darwin_status_errno(95)))
	assert_equal(IO_IO_ERROR, io_status_from_errno(socket_darwin_status_errno(110)))
	assert_equal(IO_IO_ERROR, io_status_from_errno(socket_darwin_status_errno(125)))
	assert_equal(IO_WOULD_BLOCK, io_status_from_errno(socket_darwin_status_errno(35)))
	assert_equal(IO_INTERRUPTED, io_status_from_errno(socket_darwin_status_errno(4)))
	assert_equal(IO_TIMED_OUT, io_status_from_errno(socket_darwin_status_errno(60)))
	assert_equal(IO_CANCELLED, io_status_from_errno(socket_darwin_status_errno(89)))
	assert_equal(IO_NO_SPACE, io_status_from_errno(socket_darwin_status_errno(28)))
	assert_equal(IO_NO_SPACE, io_status_from_errno(socket_darwin_status_errno(69)))
	assert_equal(IO_UNSUPPORTED, io_status_from_errno(socket_darwin_status_errno(45)))
	assert_equal(IO_UNSUPPORTED, io_status_from_errno(socket_darwin_status_errno(78)))
	assert_equal(IO_UNSUPPORTED, io_status_from_errno(socket_darwin_status_errno(102)))
	assert_equal(IO_OK, io_status_from_errno(socket_darwin_status_errno(0)))


void test_socket_wait_synthetic_errors_are_separate_from_native_errors():
	assert_equal(IO_TIMED_OUT, net_wait_status_from_errno(110))
	assert_equal(IO_CANCELLED, net_wait_status_from_errno(125))
	io_result r
	assert_equal(IO_TIMED_OUT, net_wait_result_from_syscall(&r, -110))
	assert_equal(110, r.native_error)
	assert_equal(IO_CANCELLED, net_wait_result_from_syscall(&r, -125))
	assert_equal(125, r.native_error)
	net_result_from_syscall(&r, -38)
	assert_equal(38, r.native_error)
	if (sol_socket() == 65535): assert_equal(IO_IO_ERROR, r.status)
	else: assert_equal(IO_UNSUPPORTED, r.status)
	net_result_from_syscall(&r, -11)
	assert_equal(11, r.native_error)
	if (sol_socket() == 65535): assert_equal(IO_IO_ERROR, r.status)
	else: assert_equal(IO_WOULD_BLOCK, r.status)
