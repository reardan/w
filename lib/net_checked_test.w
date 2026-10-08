# wbuild: x64
import lib.testing
import lib.net


void test_net_connect_checked_preserves_refusal_errno():
	# A bound socket without listen reserves the port and refuses connects.
	int reserved = socket_tcp_ipv4()
	assert1(reserved >= 0)
	assert_equal(0, socket_bind_ipv4(reserved, 0x7f000001, 0))
	sockaddr_in address
	assert_equal(0, socket_getsockname_ipv4(reserved, &address))
	int port = net_htons(address.port)
	io_result r
	assert_equal(-1, net_connect_timeout_checked(0x7f000001, port, 1000, &r))
	assert_equal(IO_IO_ERROR, r.status)
	assert_equal(111, r.native_error)
	assert_equal(0, r.transferred)
	assert_equal(-1, net_connect_timeout(0x7f000001, port, 1000))
	close(reserved)


void test_net_connect_checked_success_retains_nonblocking_fd():
	int server = socket_tcp_ipv4()
	assert1(server >= 0)
	assert_equal(0, socket_bind_ipv4(server, 0x7f000001, 0))
	assert_equal(0, socket_listen(server, 1))
	sockaddr_in address
	assert_equal(0, socket_getsockname_ipv4(server, &address))
	io_result r
	int client = net_connect_timeout_checked(0x7f000001, net_htons(address.port), 1000, &r)
	assert1(client >= 0)
	assert_equal(IO_OK, r.status)
	assert_equal(0, r.native_error)
	assert1((sys_fcntl(client, f_getfl, 0) & o_nonblock()) != 0)
	int accepted = socket_accept_connection(server)
	assert1(accepted >= 0)
	close(accepted)
	close(client)
	close(server)


int net_test_cancelled():
	return -125


void test_net_connect_checks_cancellation_before_opening_socket():
	io_check_fn* previous = io_check_hook
	io_check_hook = net_test_cancelled
	io_result r
	int fd = net_connect_timeout_checked(0x7f000001, 1, 1000, &r)
	io_check_hook = previous
	assert_equal(-1, fd)
	assert_equal(IO_CANCELLED, r.status)
	assert_equal(125, r.native_error)
	assert_equal(0, r.transferred)


int net_test_wait_calls


int net_test_wait_active():
	return 1


int net_test_interrupted_then_timeout(int fd, int events, int timeout_ms):
	net_test_wait_calls = net_test_wait_calls + 1
	if (net_test_wait_calls == 1): return -4
	return 0


void test_net_connect_retries_interrupted_wait_and_preserves_timeout():
	int reserved = socket_tcp_ipv4()
	assert1(reserved >= 0)
	assert_equal(0, socket_bind_ipv4(reserved, 0x7f000001, 0))
	sockaddr_in address
	assert_equal(0, socket_getsockname_ipv4(reserved, &address))
	io_wait_fn* previous = io_wait_hook
	io_wait_active_fn* previous_active = io_wait_active_hook
	io_wait_hook = net_test_interrupted_then_timeout
	io_wait_active_hook = net_test_wait_active
	net_test_wait_calls = 0
	io_result r
	int fd = net_connect_timeout_checked(0x7f000001, net_htons(address.port), 1000, &r)
	io_wait_hook = previous
	io_wait_active_hook = previous_active
	close(reserved)
	assert_equal(-1, fd)
	assert_equal(2, net_test_wait_calls)
	assert_equal(IO_TIMED_OUT, r.status)
	assert_equal(110, r.native_error)
	assert_equal(0, r.transferred)
