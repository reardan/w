# Tests for awaitable I/O (lib/task_io.w): an in-process echo server
# with several concurrent clients over TCP loopback, backpressure on
# writes, EOF delivery, and worker processes that suspend instead of
# blocking the loop.
import lib.testing
import lib.task
import lib.task_io
import lib.container


int loopback_ip():
	return 2130706433 /* 127.0.0.1 */


# Listening socket on an ephemeral loopback port; the chosen port is
# stored through port_out.
int listen_on_loopback(int* port_out):
	int fd = socket_tcp_ipv4()
	asserts(c"socket failed", fd >= 0)
	socket_set_reuseaddr(fd)
	asserts(c"bind failed", socket_bind_ipv4(fd, loopback_ip(), 0) >= 0)
	asserts(c"listen failed", socket_listen(fd, 16) >= 0)
	sockaddr_in addr
	asserts(c"getsockname failed", socket_getsockname_ipv4(fd, &addr) >= 0)
	*port_out = net_htons(addr.port)
	asserts(c"nonblocking failed", socket_set_nonblocking(fd) >= 0)
	return fd


/* Echo server: one accept task spawns a handler task per connection;
   handlers echo until EOF. Clients each write one message, read the
   echo back, and record the round-trip in a shared log. */

struct echo_state:
	list[int] log      # completion order, by client id
	int connections    # handlers started
	int port


generator int echo_handler(int fd):
	char* buf = malloc(256)
	while (1):
		int n = task_read(fd, buf, 256)
		if (n <= 0):
			break
		assert_equal(n, task_write_all(fd, buf, n))
	free(buf)
	close(fd)


generator int echo_server(echo_state* state, int listen_fd, int connection_count):
	int i = 0
	while (i < connection_count):
		int fd = task_accept(listen_fd)
		asserts(c"accept failed", fd >= 0)
		state.connections = state.connections + 1
		task_go(echo_handler(fd))
		i = i + 1


generator int echo_client(echo_state* state, int id):
	int fd = socket_tcp_ipv4()
	asserts(c"client socket failed", fd >= 0)
	assert_equal(0, task_connect_ipv4(fd, loopback_ip(), state.port))

	char* message = strjoin(c"hello from client ", itoa(id))
	int length = strlen(message)
	assert_equal(length, task_write_all(fd, message, length))

	char* reply = malloc(length + 1)
	assert_equal(length, task_read_exact(fd, reply, length))
	reply[length] = 0
	asserts(c"echoed bytes differ", strcmp(message, reply) == 0)

	free(reply)
	free(message)
	close(fd)
	state.log.push(id)
	task_finish(id)


void test_echo_server_with_concurrent_clients():
	echo_state* state = new echo_state()
	state.log = new list[int]
	state.connections = 0
	int listen_fd = listen_on_loopback(&state.port)

	task_scheduler* s = task_scheduler_new()
	task_spawn(s, echo_server(state, listen_fd, 3))
	task_spawn(s, echo_client(state, 1))
	task_spawn(s, echo_client(state, 2))
	task_spawn(s, echo_client(state, 3))
	assert_equal(0, task_run(s))

	assert_equal(3, state.connections)
	assert_equal(3, state.log.length)
	int seen = 0
	int i = 0
	while (i < 3):
		seen = seen | (1 << state.log[i])
		i = i + 1
	assert_equal(2 + 4 + 8, seen)

	task_scheduler_free(s)
	close(listen_fd)
	list_free[int](state.log)
	free(cast(void*, state))


/* Backpressure: a megabyte through a socketpair forces the writer into
   repeated EAGAIN suspensions while the reader drains. */

generator int bulk_writer(int fd, int total):
	char* chunk = malloc(4096)
	int i = 0
	while (i < 4096):
		chunk[i] = i & 255
		i = i + 1
	int sent = 0
	while (sent < total):
		int n = total - sent
		if (n > 4096):
			n = 4096
		assert_equal(n, task_write_all(fd, chunk, n))
		sent = sent + n
	free(chunk)
	close(fd)
	task_finish(sent)


generator int bulk_reader(int fd):
	char* buf = malloc(4096)
	int received = 0
	int checksum = 0
	while (1):
		int n = task_read(fd, buf, 4096)
		if (n <= 0):
			break
		int i = 0
		while (i < n):
			checksum = checksum + (buf[i] & 255)
			i = i + 1
		received = received + n
	free(buf)
	task_finish(received + checksum)


void test_write_backpressure_megabyte():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[0])
	socket_set_nonblocking(fds[1])

	int total = 1048576
	# 256 chunks of the 0..4095 byte pattern: each chunk sums to
	# 16 * (0 + 1 + ... + 255) = 522240.
	int expected_checksum = (total / 4096) * 522240

	task_scheduler* s = task_scheduler_new()
	task* writer = task_spawn(s, bulk_writer(fds[0], total))
	task* reader = task_spawn(s, bulk_reader(fds[1]))
	assert_equal(0, task_run(s))
	assert_equal(total, task_result(writer))
	assert_equal(total + expected_checksum, task_result(reader))
	task_scheduler_free(s)
	close(fds[1])
	free(fds)


/* Peer close is delivered as EOF (task_read returns 0). */

generator int read_until_eof(int fd):
	char* buf = malloc(16)
	int n = task_read(fd, buf, 16)
	free(buf)
	task_finish(n)


generator int close_after_5ms(int fd):
	assert_equal(0, task_sleep_ms(5))
	close(fd)


void test_peer_close_reads_as_eof():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)
	socket_set_nonblocking(fds[1])

	task_scheduler* s = task_scheduler_new()
	task* reader = task_spawn(s, read_until_eof(fds[1]))
	task_spawn(s, close_after_5ms(fds[0]))
	assert_equal(0, task_run(s))
	assert_equal(0, task_result(reader))
	task_scheduler_free(s)
	close(fds[1])
	free(fds)


/* Worker processes: output capture, and proof that a waiting task does
   not block the rest of the scheduler. */

generator int run_echo_process():
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/echo")
	strv_set(argv, 1, c"hello from a worker")
	char* out = 0
	int status = task_process_run(c"/bin/echo", argv, &out)
	assert_equal(0, status)
	asserts(c"unexpected process output", strcmp(out, c"hello from a worker\x0a") == 0)
	free(out)
	free(cast(void*, argv))
	task_finish(1)


void test_process_output_captured():
	task_scheduler* s = task_scheduler_new()
	task* t = task_spawn(s, run_echo_process())
	assert_equal(0, task_run(s))
	assert_equal(1, task_result(t))
	task_scheduler_free(s)


struct order_log2:
	list[int] entries


generator int run_sleep_process(order_log2* log):
	char** argv = strv_new(2)
	strv_set(argv, 0, c"/bin/sleep")
	strv_set(argv, 1, c"0.2")
	int status = task_process_run(c"/bin/sleep", argv, 0)
	assert_equal(0, status)
	free(cast(void*, argv))
	log.entries.push(1)


generator int quick_sleeper(order_log2* log):
	assert_equal(0, task_sleep_ms(20))
	log.entries.push(2)


void test_process_wait_does_not_block_other_tasks():
	order_log2* log = new order_log2()
	log.entries = new list[int]

	task_scheduler* s = task_scheduler_new()
	task_spawn(s, run_sleep_process(log))
	task_spawn(s, quick_sleeper(log))
	assert_equal(0, task_run(s))

	# The 20ms task finished while the 200ms child was still running.
	assert_equal(2, log.entries.length)
	assert_equal(2, log.entries[0])
	assert_equal(1, log.entries[1])

	task_scheduler_free(s)
	list_free[int](log.entries)
	free(cast(void*, log))
