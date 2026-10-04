# wbuild: x64
import lib.testing
import lib.io
import lib.process


void test_io_empty_requests_touch_nothing():
	io_result r
	# fd -1 would fail with EBADF if it were touched.
	assert_equal(IO_OK, io_write_all(-1, c"", 0, &r))
	assert_equal(0, r.transferred)
	assert_equal(IO_OK, io_read_exact(-1, 0, 0, &r))
	assert_equal(IO_OK, io_read_some(-1, 0, 0, &r))
	assert_equal(IO_OK, io_write_some(-1, c"", 0, &r))


void test_io_write_all_then_read_exact_eof():
	int rd = 0
	int wr = 0
	assert_equal(0, process_make_pipe(&rd, &wr))
	io_result r
	assert_equal(IO_OK, io_write_all(wr, c"hello", 5, &r))
	assert_equal(5, r.transferred)
	assert_equal(IO_OK, io_close(wr, &r))
	char* buf = malloc(16)
	assert_equal(IO_OK, io_read_exact(rd, buf, 3, &r))
	assert_equal(3, r.transferred)
	# Only two bytes remain: EOF with the partial count, not success.
	assert_equal(IO_EOF, io_read_exact(rd, buf, 8, &r))
	assert_equal(2, r.transferred)
	assert_equal('l', buf[0])
	assert_equal('o', buf[1])
	io_close(rd, &r)
	free(buf)


void test_io_errors_keep_native_errno():
	io_result r
	assert_equal(IO_IO_ERROR, io_write_all(-1, c"x", 1, &r))
	assert_equal(9, r.native_error)  # EBADF
	assert_equal(0, r.transferred)
	assert_equal(IO_IO_ERROR, io_close(-1, &r))
	assert_equal(9, r.native_error)


void test_io_status_classification():
	assert_equal(IO_WOULD_BLOCK, io_status_from_errno(11))
	assert_equal(IO_INTERRUPTED, io_status_from_errno(4))
	assert_equal(IO_NO_SPACE, io_status_from_errno(28))
	assert_equal(IO_NO_SPACE, io_status_from_errno(122))
	assert_equal(IO_TIMED_OUT, io_status_from_errno(110))
	assert_equal(IO_CANCELLED, io_status_from_errno(125))
	assert_equal(IO_UNSUPPORTED, io_status_from_errno(38))
	assert_equal(IO_IO_ERROR, io_status_from_errno(5))
	assert_strings_equal(c"no_space", io_status_name(IO_NO_SPACE))
