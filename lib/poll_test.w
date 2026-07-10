# wbuild: x64
import lib.testing
import lib.net
import lib.poll
import lib.time


void test_poll_single_times_out_when_no_data():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	assert_equal(0, poll_single(fds[1], poll_in(), 0))
	close(fds[0])
	close(fds[1])
	free(fds)


void test_poll_single_reports_readable():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	assert_equal(4, write(fds[0], c"ping", 4))
	int revents = poll_single(fds[1], poll_in(), 1000)
	assert_equal(poll_in(), revents & poll_in())

	char* buf = malloc(8)
	assert_equal(4, read(fds[1], buf, 8))
	close(fds[0])
	close(fds[1])
	free(buf)
	free(fds)


void test_poll_single_reports_writable():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	int revents = poll_single(fds[0], poll_out(), 1000)
	assert_equal(poll_out(), revents & poll_out())
	close(fds[0])
	close(fds[1])
	free(fds)


void test_poll_single_reports_peer_close():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	close(fds[0])
	# A closed stream peer becomes readable (read then reports EOF).
	int revents = poll_single(fds[1], poll_in(), 1000)
	assert_equal(poll_in(), revents & poll_in())
	char* buf = malloc(4)
	assert_equal(0, read(fds[1], buf, 4))
	close(fds[1])
	free(buf)
	free(fds)


void test_poll_wait_array_mixed_readiness():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	assert_equal(2, write(fds[0], c"hi", 2))

	pollfd* watches = pollfd_new_array(2)
	pollfd_set(watches, 0, fds[1], poll_in())
	pollfd_set(watches, 1, fds[0], poll_in())

	assert_equal(1, poll_wait(watches, 2, 1000))
	pollfd* readable = pollfd_at(watches, 0)
	assert_equal(poll_in(), readable.revents & poll_in())
	pollfd* idle = pollfd_at(watches, 1)
	assert_equal(0, idle.revents)

	close(fds[0])
	close(fds[1])
	free(cast(char*, watches))
	free(fds)


void test_poll_timeout_waits():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	int start = time_monotonic_ms()
	assert_equal(0, poll_single(fds[1], poll_in(), 50))
	int elapsed = time_monotonic_ms() - start
	asserts(c"poll returned before its timeout", elapsed >= 40)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_nonblocking_read_returns_eagain():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	asserts(c"socket_set_nonblocking failed", socket_set_nonblocking(fds[1]) >= 0)

	char* buf = malloc(8)
	# EAGAIN is errno 11.
	assert_equal(0 - 11, read(fds[1], buf, 8))

	assert_equal(4, write(fds[0], c"ping", 4))
	assert_equal(4, read(fds[1], buf, 8))

	close(fds[0])
	close(fds[1])
	free(buf)
	free(fds)
