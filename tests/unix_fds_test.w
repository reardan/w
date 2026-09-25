# wbuild: x64
# lib/unix_fds.w: SCM_RIGHTS descriptor passing over an AF_UNIX
# socketpair -- the mechanism tools/wbuildd.w's build RPC uses to hand
# a client's stdin/stdout/stderr to the daemon's build process.
import lib.testing
import lib.net
import lib.process
import lib.unix_fds


# Sends pipe write ends across the pair, then proves the received
# descriptors are live copies (a write through each lands in its pipe)
# and were installed close-on-exec.
void test_unix_fds_pass_pipe_ends():
	int* pair = malloc(2 * __word_size__)
	assert_equal(0, socket_pair(pair))
	int a_read = 0
	int a_write = 0
	int b_read = 0
	int b_write = 0
	assert_equal(0, process_make_pipe(&a_read, &a_write))
	assert_equal(0, process_make_pipe(&b_read, &b_write))
	int* send_fds = malloc(2 * __word_size__)
	send_fds[0] = a_write
	send_fds[1] = b_write
	assert_equal(3, unix_send_fds(pair[0], c"fds", 3, send_fds, 2))
	close(a_write)
	close(b_write)

	char* buf = malloc(16)
	int* got_fds = malloc(4 * __word_size__)
	int count = 0
	assert_equal(3, unix_recv_fds(pair[1], buf, 16, got_fds, 4, &count))
	buf[3] = 0
	assert_strings_equal(c"fds", buf)
	assert_equal(2, count)
	# F_GETFD (1) reports FD_CLOEXEC (1).
	assert_equal(1, sys_fcntl(got_fds[0], 1, 0) & 1)
	assert_equal(1, sys_fcntl(got_fds[1], 1, 0) & 1)

	assert_equal(2, write(got_fds[0], c"hi", 2))
	assert_equal(3, write(got_fds[1], c"yo!", 3))
	close(got_fds[0])
	close(got_fds[1])
	assert_equal(2, read(a_read, buf, 16))
	assert1((buf[0] == 'h') && (buf[1] == 'i'))
	assert_equal(3, read(b_read, buf, 16))
	assert1((buf[0] == 'y') && (buf[2] == '!'))
	# Every copy of each write end is closed now: EOF.
	assert_equal(0, read(a_read, buf, 16))
	assert_equal(0, read(b_read, buf, 16))
	close(a_read)
	close(b_read)
	close(pair[0])
	close(pair[1])


# Plain data with no descriptors attached reports a count of zero, and
# a closed peer reads as EOF.
void test_unix_fds_plain_data_and_eof():
	int* pair = malloc(2 * __word_size__)
	assert_equal(0, socket_pair(pair))
	assert_equal(4, write(pair[0], c"data", 4))
	close(pair[0])
	char* buf = malloc(16)
	int* got_fds = malloc(2 * __word_size__)
	int count = 7
	assert_equal(4, unix_recv_fds(pair[1], buf, 16, got_fds, 2, &count))
	assert_equal(0, count)
	assert_equal(0, unix_recv_fds(pair[1], buf, 16, got_fds, 2, &count))
	assert_equal(0, count)
	close(pair[1])
