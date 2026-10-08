# wbuild: x64
import lib.testing
import lib.transport
import lib.task


const int EPIPE = 32
const int ECONNRESET = 104
const int ENOENT = 2


void transport_test_pair(transport** a, transport** b):
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	*a = transport_from_socket(fds[0], c"socketpair", 1)
	*b = transport_from_socket(fds[1], c"socketpair", 1)
	free(cast(char*, fds))


void test_transport_socketpair_round_trip_and_identity():
	transport* a = 0
	transport* b = 0
	transport_test_pair(&a, &b)
	io_result r
	assert_equal(IO_OK, transport_write_all(a, c"hello", 5, &r))
	assert_equal(5, r.transferred)
	char* buf = cast(char*, malloc(16))
	assert_equal(IO_OK, transport_read_exact(b, buf, 5, &r))
	assert_bytes_equal(c"hello", buf, 5)
	# Empty requests succeed without touching anything.
	assert_equal(IO_OK, transport_read_some(b, buf, 0, &r))
	assert_equal(IO_OK, transport_write_all(b, buf, 0, &r))
	# Plain sockets carry an address, never an authenticated identity.
	assert_strings_equal(c"socketpair", transport_peer(a))
	assert_equal(0, transport_authenticated(a))
	assert_equal(IO_UNSUPPORTED, transport_require_authenticated(a, &r))
	transport_free(a)
	transport_free(b)
	free(buf)


void test_transport_peer_close_is_eof_like_raw_io():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	transport* a = transport_from_socket(fds[0], c"socketpair", 1)
	io_result r
	assert_equal(IO_OK, io_close(fds[1], &r))
	char* buf = cast(char*, malloc(16))
	assert_equal(IO_EOF, transport_read_some(a, buf, 16, &r))
	assert_equal(0, r.transferred)
	# Same category as checked descriptor I/O on the raw socket.
	assert_equal(IO_EOF, io_read_some(fds[0], buf, 16, &r))
	# Short input: EOF together with the partial count.
	assert_equal(0, socket_pair(fds))
	transport* c = transport_from_socket(fds[0], 0, 1)
	assert_strings_equal(c"unknown", transport_peer(c))
	assert_equal(3, socket_send(fds[1], c"abc", 3, 0))
	close(fds[1])
	assert_equal(IO_EOF, transport_read_exact(c, buf, 8, &r))
	assert_equal(3, r.transferred)
	transport_free(a)
	transport_free(c)
	free(buf)
	free(cast(char*, fds))


void test_transport_write_to_closed_peer_is_an_error_not_sigpipe():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	transport* a = transport_from_socket(fds[0], c"socketpair", 1)
	close(fds[1])
	io_result r
	assert_equal(IO_IO_ERROR, transport_write_all(a, c"data", 4, &r))
	assert_equal(EPIPE, r.native_error)
	assert_equal(0, r.transferred)
	# Parity: the raw errno maps to the same category.
	assert_equal(IO_IO_ERROR, io_status_from_errno(EPIPE))
	transport_free(a)
	free(cast(char*, fds))


void test_transport_read_deadline_times_out():
	transport* a = 0
	transport* b = 0
	transport_test_pair(&a, &b)
	io_result r
	char* buf = cast(char*, malloc(16))
	transport_set_timeout(a, 50)
	int start = time_monotonic_ms()
	assert_equal(IO_TIMED_OUT, transport_read_some(a, buf, 16, &r))
	int elapsed = time_monotonic_ms() - start
	assert1(elapsed >= 40)
	assert1(elapsed < 5000)
	# The deadline has passed: later operations fail at once, even with
	# data waiting, and never touch the socket.
	assert_equal(IO_OK, transport_write_all(b, c"x", 1, &r))
	assert_equal(IO_TIMED_OUT, transport_read_some(a, buf, 16, &r))
	assert_equal(0, transport_remaining_ms(a))
	# Clearing the deadline makes the pending byte readable.
	transport_set_timeout(a, -1)
	assert_equal(-1, transport_remaining_ms(a))
	assert_equal(IO_OK, transport_read_some(a, buf, 16, &r))
	assert_equal(1, r.transferred)
	transport_free(a)
	transport_free(b)
	free(buf)


void test_transport_write_deadline_reports_confirmed_prefix():
	transport* a = 0
	transport* b = 0
	transport_test_pair(&a, &b)
	# Nobody reads b: the socket buffers fill and the write must stop at
	# the deadline instead of blocking forever.
	int len = 16 * 1024 * 1024
	char* big = cast(char*, malloc(len))
	io_result r
	transport_set_timeout(a, 100)
	assert_equal(IO_TIMED_OUT, transport_write_all(a, big, len, &r))
	assert1(r.transferred > 0)
	assert1(r.transferred < len)
	transport_free(a)
	transport_free(b)
	free(big)


void test_transport_closed_descriptor_is_never_touched():
	transport* a = 0
	transport* b = 0
	transport_test_pair(&a, &b)
	io_result r
	assert_equal(IO_OK, transport_close(a, &r))
	assert_equal(IO_OK, transport_close(a, &r))
	char* buf = cast(char*, malloc(4))
	assert_equal(IO_IO_ERROR, transport_read_some(a, buf, 4, &r))
	assert_equal(9, r.native_error)
	assert_equal(IO_IO_ERROR, transport_write_all(a, buf, 4, &r))
	assert_equal(9, r.native_error)
	# The peer sees an orderly EOF.
	assert_equal(IO_EOF, transport_read_some(b, buf, 4, &r))
	transport_free(a)
	transport_free(b)
	free(buf)


char* transport_test_socket_path():
	char* pid = itoa(getpid())
	char* a = strjoin(c"/tmp/w_transport_test_", pid)
	char* path = strjoin(a, c".sock")
	free(pid)
	free(a)
	return path


void test_transport_unix_socket_round_trip():
	char* path = transport_test_socket_path()
	int listener = socket_listen_unix_path(path, 4)
	assert1(listener >= 0)
	io_result r
	transport* client = transport_unix_connect(path, &r)
	assert_equal(IO_OK, r.status)
	transport* server = transport_unix_accept(listener, path, 1000, &r)
	assert_equal(IO_OK, r.status)
	char* want_client_peer = strjoin(c"unix:", path)
	assert_strings_equal(want_client_peer, transport_peer(client))
	assert_contains(transport_peer(server), c"unix-client@")
	assert_equal(0, transport_authenticated(server))
	assert_equal(IO_OK, transport_write_all(client, c"ping", 4, &r))
	char* buf = cast(char*, malloc(8))
	assert_equal(IO_OK, transport_read_exact(server, buf, 4, &r))
	assert_bytes_equal(c"ping", buf, 4)
	assert_equal(IO_OK, transport_write_all(server, c"pong", 4, &r))
	assert_equal(IO_OK, transport_read_exact(client, buf, 4, &r))
	assert_bytes_equal(c"pong", buf, 4)
	assert_equal(IO_OK, transport_close(client, &r))
	assert_equal(IO_EOF, transport_read_some(server, buf, 8, &r))
	# Nobody is connecting now: the accept wait times out.
	assert_equal(0, cast(int, transport_unix_accept(listener, path, 20, &r)))
	assert_equal(IO_TIMED_OUT, r.status)
	transport_free(client)
	transport_free(server)
	close(listener)
	unlink(path)
	# A missing socket keeps its errno.
	assert_equal(0, cast(int, transport_unix_connect(path, &r)))
	assert_equal(IO_IO_ERROR, r.status)
	assert_equal(ENOENT, r.native_error)
	free(want_client_peer)
	free(path)
	free(buf)


int transport_test_listen_loopback(int* port):
	int server = socket_tcp_ipv4()
	assert1(server >= 0)
	socket_set_reuseaddr(server)
	assert_equal(0, socket_bind_ipv4(server, ip4_from_string(c"127.0.0.1"), 0))
	assert_equal(0, socket_listen(server, 4))
	sockaddr_in bound
	assert_equal(0, socket_getsockname_ipv4(server, &bound))
	*port = net_htons(bound.port) & 65535
	return server


void test_transport_tcp_loopback_round_trip_and_reset():
	int port = 0
	int listener = transport_test_listen_loopback(&port)
	int loopback = ip4_from_string(c"127.0.0.1")
	io_result r
	transport* client = transport_tcp_connect(loopback, port, 1000, &r)
	asserts(c"tcp connect", client != 0)
	transport* server = transport_tcp_accept(listener, 1000, &r)
	asserts(c"tcp accept", server != 0)
	char* want = transport_format_tcp_peer(loopback, port)
	assert_strings_equal(want, transport_peer(client))
	assert_contains(transport_peer(server), c"tcp:127.0.0.1:")
	assert_equal(0, transport_authenticated(client))
	assert_equal(IO_UNSUPPORTED, transport_require_authenticated(server, &r))
	assert_equal(IO_OK, transport_write_all(client, c"request", 7, &r))
	char* buf = cast(char*, malloc(64))
	assert_equal(IO_OK, transport_read_exact(server, buf, 7, &r))
	assert_bytes_equal(c"request", buf, 7)
	# Peer closes: EOF on the reader, then errors (never SIGPIPE) on the
	# writer once the reset arrives.
	transport_close(server, &r)
	assert_equal(IO_EOF, transport_read_some(client, buf, 64, &r))
	int status = IO_OK
	int tries = 0
	while ((status == IO_OK) && (tries < 100)):
		status = transport_write_all(client, buf, 64, &r)
		tries = tries + 1
	assert_equal(IO_IO_ERROR, status)
	assert1((r.native_error == EPIPE) || (r.native_error == ECONNRESET))
	transport_free(client)
	transport_free(server)
	# No pending client: accept times out.
	assert_equal(0, cast(int, transport_tcp_accept(listener, 20, &r)))
	assert_equal(IO_TIMED_OUT, r.status)
	close(listener)
	# The port is closed now: connecting fails with an error status.
	assert_equal(0, cast(int, transport_tcp_connect(loopback, port, 1000, &r)))
	assert_equal(IO_IO_ERROR, r.status)
	free(want)
	free(buf)


void test_transport_metrics_record_latency_and_failures():
	transport* a = 0
	transport* b = 0
	transport_test_pair(&a, &b)
	metrics* m = metrics_new(0)
	metrics_enable_latency(m)
	metrics_enable_events(m, 4)
	transport_set_metrics(a, m)
	io_result r
	char* buf = cast(char*, malloc(8))
	assert_equal(IO_OK, transport_write_all(a, c"x", 1, &r))
	assert_equal(IO_OK, transport_read_some(b, buf, 8, &r))
	transport_set_timeout(a, 10)
	assert_equal(IO_TIMED_OUT, transport_read_some(a, buf, 8, &r))
	assert_equal(2, m.latency.count)
	assert1(m.latency.max >= 5000)
	assert_equal(1, m.events.count)
	metrics_event_record* e = metrics_event_ring_at(m.events, 0)
	assert_equal(IO_TIMED_OUT, e.kind)
	assert_strings_equal(c"socketpair", e.text)
	transport_free(a)
	transport_free(b)
	metrics_free(m)
	free(buf)


/* Inside tasks the waits park only the calling task (lib/io_wait.w). */

struct transport_task_state:
	transport* reader
	transport* writer
	int read_status
	int read_count
	int timeout_status


generator int transport_test_reader(transport_task_state* st):
	io_result r
	char* buf = cast(char*, malloc(8))
	transport_set_timeout(st.reader, 2000)
	st.read_status = transport_read_some(st.reader, buf, 8, &r)
	st.read_count = r.transferred
	# Nothing more is coming: this wait ends at the deadline.
	transport_set_timeout(st.reader, 30)
	st.timeout_status = transport_read_some(st.reader, buf, 8, &r)
	free(buf)


generator int transport_test_writer(transport_task_state* st):
	io_result r
	task_sleep_ms(20)
	transport_write_all(st.writer, c"hi", 2, &r)


void test_transport_waits_park_tasks_not_the_thread():
	transport_task_state st
	transport_test_pair(&st.reader, &st.writer)
	st.read_status = -1
	st.timeout_status = -1
	task_scheduler* s = task_scheduler_new()
	task_spawn(s, transport_test_reader(&st))
	task_spawn(s, transport_test_writer(&st))
	task_run(s)
	task_scheduler_free(s)
	# Had the reader blocked the thread, the writer could not have run.
	assert_equal(IO_OK, st.read_status)
	assert_equal(2, st.read_count)
	assert_equal(IO_TIMED_OUT, st.timeout_status)
	transport_free(st.reader)
	transport_free(st.writer)


# An adapter may report a confirmed prefix together with its failure.
int transport_test_partial_failure(void* context, char* buf, int len, int timeout_ms, io_result* r):
	return io_result_set(r, 3, IO_IO_ERROR, 5)


int transport_test_noop_close(void* context, io_result* r):
	return io_result_set(r, 0, IO_OK, 0)


void test_transport_keeps_adapter_partial_failure_count():
	transport* t = transport_new(malloc(1), transport_test_partial_failure, transport_test_partial_failure, transport_test_noop_close, 0)
	io_result r
	assert_equal(IO_IO_ERROR, transport_write_all(t, c"abcdef", 6, &r))
	assert_equal(3, r.transferred)
	assert_equal(5, r.native_error)
	char* buf = cast(char*, malloc(6))
	assert_equal(IO_IO_ERROR, transport_read_exact(t, buf, 6, &r))
	assert_equal(3, r.transferred)
	assert_equal(5, r.native_error)
	transport_free(t)
	free(buf)


generator int transport_test_ready_cancelled(transport* t):
	io_result r
	char* buf = cast(char*, malloc(4))
	task_deadline_scope scope
	task_deadline_enter(&scope, 0)
	assert_equal(IO_TIMED_OUT, transport_read_some(t, buf, 1, &r))
	assert_equal(0, r.transferred)
	task_deadline_exit(&scope)
	task_cancel(task_current())
	assert_equal(IO_CANCELLED, transport_read_some(t, buf, 1, &r))
	assert_equal(0, r.transferred)
	assert_equal(IO_CANCELLED, transport_write_all(t, c"x", 1, &r))
	# Shielded cleanup can still consume the byte neither check touched.
	task_current().shielded = 1
	assert_equal(IO_OK, transport_read_some(t, buf, 1, &r))
	assert_equal(113, buf[0])
	free(buf)


void test_transport_ready_io_honors_task_cancellation_and_deadline():
	transport* a = 0
	transport* b = 0
	transport_test_pair(&a, &b)
	io_result r
	assert_equal(IO_OK, transport_write_all(b, c"q", 1, &r))
	task_scheduler* s = task_scheduler_new()
	task_spawn(s, transport_test_ready_cancelled(a))
	assert_equal(0, task_run(s))
	task_scheduler_free(s)
	transport_free(a)
	transport_free(b)


int transport_test_wait_active():
	return 1


int transport_test_wait_cancelled(int fd, int events, int timeout_ms):
	return 0 - IO_ERRNO_ECANCELED


void test_transport_wait_preserves_synthetic_task_cancellation():
	io_wait_fn* saved_wait = io_wait_hook
	io_wait_active_fn* saved_active = io_wait_active_hook
	io_wait_hook = transport_test_wait_cancelled
	io_wait_active_hook = transport_test_wait_active
	io_result r
	assert_equal(IO_CANCELLED, transport_socket_wait(-1, poll_in, 100, &r))
	assert_equal(IO_ERRNO_ECANCELED, r.native_error)
	io_wait_hook = saved_wait
	io_wait_active_hook = saved_active
