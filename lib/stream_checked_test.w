# wbuild: x64
# Checked stream I/O (lib/stream.w): failed flushes retain the unwritten
# suffix and latch a sticky error, writes are refused until explicit
# recovery, partial writes resume where they stopped, and a failed read
# is an error rather than end of input. /dev/full supplies ENOSPC; a
# one-page non-blocking pipe supplies partial writes and EAGAIN.
import lib.testing
import lib.stream
import lib.file
import lib.process


int stream_checked_open_full():
	int fd = open(c"/dev/full", 1, 0)
	asserts(c"/dev/full unavailable", fd >= 0)
	return fd


void test_stream_flush_failure_retains_bytes_and_latches():
	int full = stream_checked_open_full()
	wstream* s = stream_writer_sized(full, 16)
	io_result r
	assert_equal(IO_OK, stream_write_checked(s, c"abcdef", 6, &r))
	assert_equal(6, r.transferred)
	assert_equal(IO_NO_SPACE, stream_flush_checked(s, &r))
	assert_equal(0, r.transferred)
	assert_equal(28, r.native_error)  # ENOSPC
	assert_equal(6, stream_pending(s))
	assert_equal(IO_NO_SPACE, stream_error(s))
	assert_equal(28, stream_error_errno(s))

	# Sticky: nothing new is accepted, through any write path.
	assert_equal(IO_NO_SPACE, stream_write_checked(s, c"gh", 2, &r))
	assert_equal(0, r.transferred)
	stream_write(s, c"ij", 2)
	stream_write_byte(s, 'k')
	stream_write_cstr(s, c"a string longer than the sixteen-byte buffer")
	assert_equal(6, stream_pending(s))
	stream_flush(s)
	assert_equal(6, stream_pending(s))

	# Recovery: point the stream at a working descriptor, clear, and the
	# retained bytes arrive in order.
	int good = open(c"bin/stream_checked_recover.txt", 577, 420)
	asserts(c"open failed", good >= 0)
	s.fd = good
	stream_clear_error(s)
	assert_equal(IO_OK, stream_error(s))
	assert_equal(IO_OK, stream_write_checked(s, c"ghi", 3, &r))
	assert_equal(IO_OK, stream_flush_checked(s, &r))
	assert_equal(9, r.transferred)
	assert_equal(IO_OK, stream_close_checked(s, &r))
	close(full)
	char* text = file_read_text(c"bin/stream_checked_recover.txt")
	assert_strings_equal(c"abcdefghi", text)
	free(text)


void test_stream_discard_pending_drops_retained_bytes():
	int full = stream_checked_open_full()
	wstream* s = stream_writer_sized(full, 16)
	io_result r
	stream_write(s, c"xyz", 3)
	assert_equal(IO_NO_SPACE, stream_flush_checked(s, &r))
	assert_equal(3, stream_discard_pending(s))
	assert_equal(0, stream_pending(s))
	stream_clear_error(s)
	# Nothing pending: the flush has nothing to write and succeeds.
	assert_equal(IO_OK, stream_flush_checked(s, &r))
	stream_close(s)


void test_stream_direct_write_failure_latches():
	int full = stream_checked_open_full()
	# Writes at least as large as the buffer bypass it.
	wstream* s = stream_writer_sized(full, 4)
	io_result r
	assert_equal(IO_NO_SPACE, stream_write_checked(s, c"0123456789", 10, &r))
	assert_equal(0, r.transferred)
	assert_equal(IO_NO_SPACE, stream_error(s))
	assert_equal(0, stream_pending(s))
	assert_equal(IO_NO_SPACE, stream_close_checked(s, &r))


void test_stream_close_checked_reports_flush_failure():
	int full = stream_checked_open_full()
	wstream* s = stream_writer_sized(full, 64)
	stream_write_cstr(s, c"buffered until close")
	assert_equal(IO_OK, stream_error(s))
	io_result r
	assert_equal(IO_NO_SPACE, stream_close_checked(s, &r))
	assert_equal(28, r.native_error)


void test_stream_close_checked_reports_close_failure():
	# The descriptor is already gone: the flush succeeds trivially (nothing
	# pending) and close reports EBADF.
	int fd = open(c"bin/stream_checked_close.txt", 577, 420)
	asserts(c"open failed", fd >= 0)
	close(fd)
	wstream* s = stream_writer(fd)
	io_result r
	assert_equal(IO_IO_ERROR, stream_close_checked(s, &r))
	assert_equal(9, r.native_error)


int stream_checked_byte_at(int i):
	return (i * 7 + 3) % 251


# Reads exactly n bytes from a blocking pipe end, checking the pattern
# from offset start.
void stream_checked_drain(int fd, int start, int n):
	char* buf = malloc(n + 1)
	io_result r
	assert_equal(IO_OK, io_read_exact(fd, buf, n, &r))
	for i in range(n): assert_equal(stream_checked_byte_at(start + i), buf[i] & 255)
	free(buf)


int stream_checked_drained


# Drains the pipe up to total bytes delivered so far, checking order.
void stream_checked_drain_upto(int fd, int total):
	int n = total - stream_checked_drained
	if (n <= 0): return
	stream_checked_drain(fd, stream_checked_drained, n)
	stream_checked_drained = total


void test_stream_partial_flush_resumes_after_would_block():
	int rd = 0
	int wr = 0
	assert_equal(0, process_make_pipe(&rd, &wr))
	# F_SETPIPE_SZ (1031) to one page, then O_NONBLOCK via F_SETFL (4).
	int pipe_size = sys_fcntl(wr, 1031, 4096)
	asserts(c"F_SETPIPE_SZ failed", pipe_size > 0)
	asserts(c"F_SETFL failed", sys_fcntl(wr, 4, 2048) >= 0)

	int n = pipe_size * 2 + 100
	char* data = malloc(n)
	for i in range(n): data[i] = stream_checked_byte_at(i)
	wstream* s = stream_writer_sized(wr, pipe_size * 3)
	io_result r
	assert_equal(IO_OK, stream_write_checked(s, data, n, &r))
	assert_equal(n, stream_pending(s))

	stream_checked_drained = 0
	int delivered = 0
	int rounds = 0
	int blocked = 0
	while (delivered < n):
		rounds = rounds + 1
		asserts(c"flush made no progress", rounds < 100)
		int status = stream_flush_checked(s, &r)
		delivered = delivered + r.transferred
		if (status == IO_OK):
			assert_equal(0, stream_pending(s))
		else:
			# The pipe filled part-way: the unwritten suffix is retained.
			blocked = blocked + 1
			assert_equal(IO_WOULD_BLOCK, status)
			assert_equal(IO_WOULD_BLOCK, stream_error(s))
			assert_equal(n - delivered, stream_pending(s))
			# New bytes are refused until recovery.
			assert_equal(IO_WOULD_BLOCK, stream_write_checked(s, c"!", 1, &r))
			assert_equal(0, r.transferred)
			assert_equal(n - delivered, stream_pending(s))
		# Read back what reached the pipe so far: order is preserved.
		stream_checked_drain_upto(rd, delivered)
		stream_clear_error(s)
	asserts(c"expected partial writes", blocked > 0)
	stream_close(s)
	close(rd)
	free(data)


void test_stream_read_error_is_not_eof():
	# read(2) on a directory fails with EISDIR.
	int fd = open(c"lib", 0, 0)
	asserts(c"open lib failed", fd >= 0)
	wstream* in = stream_reader(fd)
	assert_equal(-1, stream_read_byte(in))
	assert_equal(IO_IO_ERROR, stream_error(in))
	assert_equal(21, stream_error_errno(in))  # EISDIR
	assert_equal(0, in.eof)
	char* buf = malloc(64)
	io_result r
	assert_equal(IO_IO_ERROR, stream_read_checked(in, buf, 64, &r))
	assert_equal(0, r.transferred)
	string_builder* all = string_new()
	assert_equal(IO_IO_ERROR, stream_read_all_checked(in, all, &r))
	assert_equal(0, all.length)
	string_free(all)
	free(buf)
	stream_close(in)


void test_stream_read_write_only_fd_is_error():
	int fd = open(c"/dev/null", 1, 0)
	asserts(c"open /dev/null failed", fd >= 0)
	wstream* in = stream_reader(fd)
	string_builder* line = string_new()
	assert_equal(0, stream_read_line(in, line))
	assert_equal(IO_IO_ERROR, stream_error(in))
	assert_equal(9, stream_error_errno(in))  # EBADF
	assert_equal(0, in.eof)
	string_free(line)
	stream_close(in)


void test_stream_real_eof_is_not_an_error():
	assert_equal(1, file_write_text(c"bin/stream_checked_eof.txt", c"ab"))
	wstream* in = stream_open_read(c"bin/stream_checked_eof.txt")
	char* buf = malloc(8)
	io_result r
	assert_equal(IO_EOF, stream_read_checked(in, buf, 8, &r))
	assert_equal(2, r.transferred)
	assert_equal(1, in.eof)
	assert_equal(IO_OK, stream_error(in))
	assert_equal(-1, stream_read_byte(in))
	assert_equal(IO_OK, stream_error(in))
	free(buf)
	stream_close(in)

	wstream* again = stream_open_read(c"bin/stream_checked_eof.txt")
	string_builder* all = string_new()
	assert_equal(IO_OK, stream_read_all_checked(again, all, &r))
	assert_equal(2, r.transferred)
	assert_strings_equal(c"ab", all.data)
	string_free(all)
	stream_close(again)


void test_stream_sync_is_flush_plus_fsync():
	int fd = open(c"bin/stream_checked_sync.txt", 577, 420)
	asserts(c"open failed", fd >= 0)
	wstream* s = stream_writer_sized(fd, 64)
	stream_write_cstr(s, c"durable")
	io_result r
	assert_equal(IO_OK, stream_sync(s, &r))
	assert_equal(7, r.transferred)
	assert_equal(0, stream_pending(s))
	assert_equal(IO_OK, stream_close_checked(s, &r))
	char* text = file_read_text(c"bin/stream_checked_sync.txt")
	assert_strings_equal(c"durable", text)
	free(text)


void test_stream_sync_failure_latches():
	# fsync on a pipe fails (EINVAL); the flush itself succeeded.
	int rd = 0
	int wr = 0
	assert_equal(0, process_make_pipe(&rd, &wr))
	wstream* s = stream_writer_sized(wr, 64)
	stream_write_cstr(s, c"abc")
	io_result r
	asserts(c"sync on a pipe should fail", stream_sync(s, &r) != IO_OK)
	assert_equal(3, r.transferred)
	assert_equal(22, r.native_error)
	assert_equal(22, stream_error_errno(s))
	asserts(c"sync failure should latch", stream_error(s) != IO_OK)
	stream_close(s)
	close(rd)
