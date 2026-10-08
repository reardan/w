# wbuild: x64
import lib.testing
import lib.transport_tls
import lib.task


tls_config* tlt_client_config():
	tls_config* cfg = tls_config_new()
	cfg.trust_store_path = c"libs/standard/distributed/raft_tls_fixtures/ca.pem"
	return cfg


tls_server_config* tlt_server_config():
	tls_server_config* cfg = tls_server_config_new()
	cfg.cert_chain_path = c"libs/standard/distributed/raft_tls_fixtures/server.pem"
	cfg.key_path = c"libs/standard/distributed/raft_tls_fixtures/server_key.pem"
	return cfg


# Real handshakes and encrypted records, outside any task runtime. Both
# blocking and nonblocking input sockets must honor operation deadlines.
void tlt_fork_exchange(int mode):
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	if (mode == 7):
		assert_equal(0, socket_set_nonblocking(fds[0]))
		assert_equal(0, socket_set_nonblocking(fds[1]))
	int pid = fork()
	assert1(pid >= 0)
	if (pid == 0):
		close(fds[0])
		tls_server_config* cfg = tlt_server_config()
		io_result r
		transport* t = transport_tls_accept(fds[1], c"test-client", cfg, 4000, &r)
		tls_server_config_free(cfg)
		if (mode == 1 || mode == 2):
			assert1(t == 0)
			assert_equal(IO_IO_ERROR, r.status)
			exit(0)
		assert1(t != 0)
		assert_equal(0, transport_authenticated(t))
		assert_equal(IO_UNSUPPORTED, transport_require_authenticated(t, &r))
		transport_set_timeout(t, 2000)
		if (mode == 4):
			# No application reads: force the sender to stop mid-record.
			sleep_ms(300)
			transport_free(t)
			exit(0)
		if (mode == 5):
			# TCP EOF without close_notify is truncation, not clean EOF.
			close(fds[1])
			exit(0)
		char* buf = cast(char*, malloc(8))
		if (mode == 6):
			assert_equal(IO_IO_ERROR, transport_read_some(t, buf, 8, &r))
			transport_free(t)
			free(buf)
			exit(0)
		assert_equal(IO_OK, transport_read_exact(t, buf, 4, &r))
		assert_bytes_equal(c"ping", buf, 4)
		assert_equal(IO_OK, transport_write_all(t, c"pong", 4, &r))
		assert_equal(IO_EOF, transport_read_some(t, buf, 8, &r))
		# The peer closed its socket after close_notify. The reply alert
		# may hit EPIPE; closing still releases the socket and all keys.
		transport_close(t, &r)
		assert_equal(IO_OK, transport_close(t, &r))
		transport_free(t)
		free(buf)
		exit(0)
	close(fds[1])
	tls_config* cfg = tlt_client_config()
	char* hostname = c"test.w.example"
	if (mode == 1): hostname = c"wrong.w.example"
	if (mode == 2): cfg.trust_store_path = c"/missing-transport-test-ca.pem"
	if (mode == 3):
		cfg.insecure_skip_verify = 1
		hostname = c"wrong.w.example"
	io_result r
	transport* t = transport_tls_connect(fds[0], hostname, cfg, 4000, &r)
	if (mode == 1 || mode == 2):
		assert1(t == 0)
		assert_equal(IO_IO_ERROR, r.status)
		assert1(tls_last_error(cfg) != 0)
	else:
		assert1(t != 0)
		int authenticated = 1
		if (mode == 3): authenticated = 0
		assert_equal(authenticated, transport_authenticated(t))
		assert_equal(IO_OK, r.status)
		transport_set_timeout(t, 2000)
		char* buf = cast(char*, malloc(8))
		if (mode == 4):
			char* payload = cast(char*, malloc(1 << 20))
			for i in range(1 << 20): payload[i] = 97
			transport_set_timeout(t, 60)
			assert_equal(IO_TIMED_OUT, transport_write_all(t, payload, 1 << 20, &r))
			assert1(r.transferred > 0)
			assert1(r.transferred < (1 << 20))
			assert_equal(0, r.transferred % TLS_MAX_PLAINTEXT)
			assert1(transport_tls_last_error(t) != 0)
			# Resetting the deadline cannot resurrect a truncated record.
			transport_set_timeout(t, 1000)
			assert_equal(IO_TIMED_OUT, transport_write_all(t, c"x", 1, &r))
			assert_equal(0, r.transferred)
			free(payload)
		else if (mode == 6):
			transport_set_timeout(t, 0)
			assert_equal(IO_TIMED_OUT, transport_close(t, &r))
			assert_equal(IO_OK, transport_close(t, &r))
			assert_equal(0 - TRANSPORT_EBADF, socket_recv(fds[0], buf, 1, 0))
		else if (mode == 5):
			assert_equal(IO_IO_ERROR, transport_read_some(t, buf, 8, &r))
			assert_equal(0, r.transferred)
			assert_strings_equal(c"tls: truncated stream", transport_tls_last_error(t))
		else:
			assert_equal(IO_OK, transport_write_all(t, c"ping", 4, &r))
			assert_equal(IO_OK, transport_read_exact(t, buf, 4, &r))
			assert_bytes_equal(c"pong", buf, 4)
			assert_equal(IO_OK, transport_close(t, &r))
			assert_equal(IO_IO_ERROR, transport_read_some(t, buf, 1, &r))
			assert_equal(TRANSPORT_EBADF, r.native_error)
		transport_free(t)
		free(buf)
	tls_config_free(cfg)
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	free(fds)


void test_tls_transport_verified_identity_and_shutdown():
	tlt_fork_exchange(0)


void test_tls_transport_rejects_hostname_and_untrusted_chain():
	tlt_fork_exchange(1)
	tlt_fork_exchange(2)


void test_tls_transport_insecure_never_claims_authentication():
	tlt_fork_exchange(3)


void test_tls_transport_partial_write_preserves_complete_records():
	tlt_fork_exchange(4)


void test_tls_transport_detects_truncation():
	tlt_fork_exchange(5)


void test_tls_transport_nonblocking_outside_tasks():
	tlt_fork_exchange(7)


void test_tls_transport_handshake_deadline_and_missing_identity():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	io_result r
	tls_config* cfg = tlt_client_config()
	int start = time_monotonic_ms()
	transport* t = transport_tls_connect(fds[0], c"test.w.example", cfg, 40, &r)
	assert1(t == 0)
	assert_equal(IO_TIMED_OUT, r.status)
	assert1(time_monotonic_ms() - start < 2000)
	close(fds[1])
	assert_equal(0, socket_pair(fds))
	t = transport_tls_connect(fds[0], 0, cfg, 40, &r)
	assert1(t == 0)
	assert_equal(IO_IO_ERROR, r.status)
	assert_strings_equal(c"tls: no server name to verify", tls_last_error(cfg))
	close(fds[1])
	tls_config_free(cfg)
	free(fds)


struct tlt_tasks:
	int client_fd
	int server_fd
	transport* client
	transport* server
	task* reader
	int status
	int native_error


generator int tlt_task_client(tlt_tasks* pair):
	tls_config* cfg = tlt_client_config()
	io_result r
	pair.client = transport_tls_connect(pair.client_fd, c"test.w.example", cfg, 4000, &r)
	tls_config_free(cfg)
	assert1(pair.client != 0)
	char* buf = cast(char*, malloc(1))
	pair.status = transport_read_some(pair.client, buf, 1, &r)
	pair.native_error = r.native_error
	free(buf)


generator int tlt_task_server(tlt_tasks* pair):
	tls_server_config* cfg = tlt_server_config()
	io_result r
	pair.server = transport_tls_accept(pair.server_fd, c"task-client", cfg, 4000, &r)
	tls_server_config_free(cfg)
	assert1(pair.server != 0)
	task_sleep_ms(10)
	assert_equal(1, task_cancel(pair.reader))


void test_tls_transport_cancellation_is_distinct_and_tasks_park():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	tlt_tasks pair
	pair.client_fd = fds[0]
	pair.server_fd = fds[1]
	pair.client = 0
	pair.server = 0
	pair.status = -1
	task_scheduler* scheduler = task_scheduler_new()
	pair.reader = task_spawn(scheduler, tlt_task_client(&pair))
	task_spawn(scheduler, tlt_task_server(&pair))
	task_run(scheduler)
	assert_equal(IO_CANCELLED, pair.status)
	assert_equal(IO_ERRNO_ECANCELED, pair.native_error)
	assert1(transport_tls_last_error(pair.client) != 0)
	transport_free(pair.client)
	transport_free(pair.server)
	task_scheduler_free(scheduler)
	free(fds)


void test_tls_transport_expired_shutdown_still_closes_fd():
	tlt_fork_exchange(6)


void test_tls_transport_native_error_and_connection_error_isolation():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	close(fds[1])
	io_result r
	assert1(transport_tls_connect(fds[0], c"test.w.example", 0, 1000, &r) == 0)
	assert_equal(IO_IO_ERROR, r.status)
	assert_equal(32, r.native_error)
	free(fds)
	# One config can serve concurrent connections; its compatibility
	# diagnostic does not overwrite the individual connection errors.
	tls_config* cfg = tlt_client_config()
	tls_conn* a = tls_conn_new(-1, 1, cfg)
	tls_conn* b = tls_conn_new(-1, 1, cfg)
	tls_fail(a, c"first failure")
	tls_fail(b, c"second failure")
	assert_strings_equal(c"first failure", a.last_error)
	assert_strings_equal(c"second failure", b.last_error)
	tls_conn_free(a)
	tls_conn_free(b)
	tls_config_free(cfg)


generator int tlt_ready_cancelled(int fd):
	tls_conn* c = tls_conn_new(fd, 0, 0)
	c.checked_io = 1
	transport_tls_begin(c, 1000)
	char* buf = cast(char*, malloc(1))
	task_deadline_scope scope
	task_deadline_enter(&scope, 0)
	assert_equal(0, tls_io_recv_full(c, buf, 1))
	assert_equal(IO_TIMED_OUT, c.last_io_status)
	task_deadline_exit(&scope)
	transport_tls_begin(c, 1000)
	task_cancel(task_current())
	assert_equal(0, tls_io_recv_full(c, buf, 1))
	assert_equal(IO_CANCELLED, c.last_io_status)
	assert_equal(0, tls_io_send_all(c, c"x", 1))
	task_current().shielded = 1
	transport_tls_begin(c, 1000)
	assert_equal(1, tls_io_recv_full(c, buf, 1))
	assert_equal(113, buf[0])
	free(buf)
	tls_conn_free(c)


void test_tls_transport_ready_syscalls_honor_task_state():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	assert_equal(1, socket_send(fds[1], c"q", 1, 0))
	task_scheduler* scheduler = task_scheduler_new()
	task_spawn(scheduler, tlt_ready_cancelled(fds[0]))
	assert_equal(0, task_run(scheduler))
	task_scheduler_free(scheduler)
	close(fds[0])
	close(fds[1])
	free(fds)


int tlt_interrupt_count


int tlt_wait_available():
	return 1


int tlt_interrupt_then_timeout(int fd, int events, int timeout_ms):
	tlt_interrupt_count = tlt_interrupt_count + 1
	if (tlt_interrupt_count == 1): return -4
	return -110


void test_tls_transport_wait_retries_eintr_without_poison_or_spin():
	io_wait_fn* saved_wait = io_wait_hook
	io_wait_active_fn* saved_active = io_wait_active_hook
	io_wait_hook = tlt_interrupt_then_timeout
	io_wait_active_hook = tlt_wait_available
	tlt_interrupt_count = 0
	tls_conn* c = tls_conn_new(-1, 0, 0)
	c.checked_io = 1
	transport_tls_begin(c, 1000)
	assert_equal(0, tls_io_wait_ready(c, poll_in))
	assert_equal(2, tlt_interrupt_count)
	assert_equal(IO_TIMED_OUT, c.last_io_status)
	io_wait_hook = saved_wait
	io_wait_active_hook = saved_active
	# Terminal retryable errno must not cause transport_op to spin on a
	# poisoned TLS connection; preserve errno but return a terminal status.
	c.last_io_status = IO_WOULD_BLOCK
	c.last_native_error = 11
	transport_tls state
	state.conn = c
	state.owner = 0
	state.last_error = 0
	io_result r
	assert_equal(IO_IO_ERROR, transport_tls_failure(&state, &r))
	assert_equal(11, r.native_error)
	tls_conn_free(c)
