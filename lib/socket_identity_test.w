# wbuild: x64
import lib.testing
import lib.transport
import lib.task


void socket_identity_assert_credentials(transport* t):
	net_peer_credentials cred
	io_result r
	assert_equal(IO_OK, transport_peer_credentials(t, &cred, &r))
	assert_equal(getuid(), cred.uid)
	assert_equal(getgid(), cred.gid)
	if (msg_nosignal() == 0): assert_equal(-1, cred.pid)
	else: assert_equal(getpid(), cred.pid)
	assert_equal(0, transport_authenticated(t))
	assert_equal(IO_UNSUPPORTED, transport_require_authenticated(t, &r))


# Exercise FIN and SHUT_RD on both TCP and Unix, with surviving writes
# after SHUT_RD and surviving reads after SHUT_WR. Every wait is bounded.
void socket_identity_assert_half_close(transport* a, transport* b):
	transport_set_timeout(a, 1000)
	transport_set_timeout(b, 1000)
	io_result r
	char[8] buf
	assert_equal(IO_OK, transport_write_all(a, c"request", 7, &r))
	assert_equal(IO_OK, transport_shutdown(a, NET_SHUT_WRITE, &r))
	assert_equal(IO_OK, transport_shutdown(a, NET_SHUT_WRITE, &r))
	assert_equal(IO_OK, transport_read_exact(b, cast(char*, &buf[0]), 7, &r))
	assert_bytes_equal(c"request", cast(char*, &buf[0]), 7)
	assert_equal(IO_EOF, transport_read_some(b, cast(char*, &buf[0]), 1, &r))
	assert_equal(IO_IO_ERROR, transport_write_all(a, c"x", 1, &r))
	assert_equal(32, r.native_error) # EPIPE on Linux and Darwin; no SIGPIPE
	assert_equal(IO_OK, transport_shutdown(b, NET_SHUT_READ, &r))
	assert_equal(IO_OK, transport_shutdown(b, NET_SHUT_READ, &r))
	assert_equal(IO_OK, transport_write_all(b, c"reply", 5, &r))
	assert_equal(IO_OK, transport_read_exact(a, cast(char*, &buf[0]), 5, &r))
	assert_bytes_equal(c"reply", cast(char*, &buf[0]), 5)
	assert_equal(IO_OK, transport_shutdown(b, NET_SHUT_BOTH, &r))
	assert_equal(IO_OK, transport_shutdown(b, NET_SHUT_BOTH, &r))
	assert_equal(IO_EOF, transport_read_some(a, cast(char*, &buf[0]), 1, &r))
	assert_equal(IO_OK, transport_close(a, &r))
	assert_equal(IO_OK, transport_close(a, &r))
	assert_equal(IO_IO_ERROR, transport_shutdown(a, NET_SHUT_WRITE, &r))
	assert_equal(9, r.native_error)
	net_peer_address address
	assert_equal(IO_IO_ERROR, transport_peer_address(a, &address, &r))
	assert_equal(9, r.native_error)
	assert_equal(0, address.length)
	net_peer_credentials cred
	assert_equal(IO_IO_ERROR, transport_peer_credentials(a, &cred, &r))
	assert_equal(9, r.native_error)
	assert_equal(-1, cred.uid)


void test_socket_identity_tcp_connected_and_accepted():
	int listener = socket_tcp_ipv4()
	assert1(listener >= 0)
	int loopback = ip4_from_string(c"127.0.0.1")
	assert_equal(0, socket_bind_ipv4(listener, loopback, 0))
	assert_equal(0, socket_listen(listener, 4))
	sockaddr_in bound
	assert_equal(0, socket_getsockname_ipv4(listener, &bound))
	int port = net_htons(bound.port) & 65535
	io_result r
	transport* client = transport_tcp_connect(loopback, port, 1000, &r)
	assert1(client != 0)
	transport* server = transport_tcp_accept(listener, 1000, &r)
	assert1(server != 0)
	net_peer_address address
	assert_equal(IO_OK, transport_peer_address(client, &address, &r))
	assert_equal(af_inet, address.family)
	assert_equal(16, address.length)
	assert_bytes_equal(cast(char*, &bound) + 2, cast(char*, &address.data[0]) + 2, 6)
	assert_equal(0, socket_getsockname_ipv4(transport_socket_fd(client), &bound))
	assert_equal(IO_OK, transport_peer_address(server, &address, &r))
	assert_bytes_equal(cast(char*, &bound) + 2, cast(char*, &address.data[0]) + 2, 6)
	net_peer_credentials cred
	assert_equal(IO_UNSUPPORTED, transport_peer_credentials(client, &cred, &r))
	assert_equal(0, r.native_error)
	assert_equal(-1, cred.uid)
	assert_equal(IO_UNSUPPORTED, transport_peer_credentials(server, &cred, &r))
	socket_identity_assert_half_close(client, server)
	transport_free(client)
	transport_free(server)
	close(listener)


void test_socket_identity_unix_connected_and_accepted():
	char* pid = itoa(getpid())
	char* path = strjoin(c"/tmp/w_socket_identity_", pid)
	free(pid)
	int listener = socket_listen_unix_path(path, 4)
	assert1(listener >= 0)
	io_result r
	transport* client = transport_unix_connect(path, &r)
	assert1(client != 0)
	transport* server = transport_unix_accept(listener, path, 1000, &r)
	assert1(server != 0)
	net_peer_address address
	assert_equal(IO_OK, transport_peer_address(client, &address, &r))
	assert_equal(af_unix, address.family)
	assert1(address.length >= 2 + strlen(path))
	assert_bytes_equal(path, cast(char*, &address.data[0]) + 2, strlen(path))
	assert_equal(IO_OK, transport_peer_address(server, &address, &r))
	assert_equal(af_unix, address.family)
	# An unbound Unix client's address contains no pathname. The listener's
	# path used for display must never appear as the client's kernel address.
	assert1(address.length <= 3)
	char* peer_bytes = cast(char*, &address.data[0])
	assert_equal(0, peer_bytes[2])
	socket_identity_assert_credentials(client)
	socket_identity_assert_credentials(server)
	socket_identity_assert_half_close(client, server)
	transport_free(client)
	transport_free(server)
	close(listener)
	unlink(path)
	free(path)


void test_socket_identity_errors_deadline_and_borrowed_ownership():
	io_result r
	net_peer_address address
	net_peer_credentials cred
	assert_equal(IO_IO_ERROR, socket_peer_address_checked(-1, &address, &r))
	assert_equal(9, r.native_error)
	assert_equal(IO_IO_ERROR, socket_peer_credentials_checked(-1, &cred, &r))
	assert_equal(9, r.native_error)
	assert_equal(IO_IO_ERROR, socket_shutdown_checked(-1, NET_SHUT_WRITE, &r))
	assert_equal(9, r.native_error)
	int[2] fds
	assert_equal(0, socket_pair(cast(int*, &fds[0])))
	transport* a = transport_from_socket(fds[0], c"untrusted display label", 0)
	assert_equal(IO_IO_ERROR, transport_shutdown(a, 99, &r))
	assert_equal(22, r.native_error)
	assert_equal(0, a.shutdown_mask)
	transport_set_timeout(a, 0)
	assert_equal(IO_TIMED_OUT, transport_peer_address(a, &address, &r))
	assert_equal(0, address.length)
	assert_equal(IO_TIMED_OUT, transport_peer_credentials(a, &cred, &r))
	assert_equal(-1, cred.uid)
	assert_equal(IO_TIMED_OUT, transport_shutdown(a, NET_SHUT_WRITE, &r))
	assert_equal(0, a.shutdown_mask)
	transport_set_timeout(a, -1)
	assert_equal(IO_OK, transport_peer_address(a, &address, &r))
	assert_equal(af_unix, address.family)
	assert_equal(0, transport_authenticated(a))
	assert_equal(IO_OK, transport_close(a, &r))
	transport_free(a)
	# Borrowing and closing the wrapper has not closed the descriptor.
	assert_equal(1, socket_send(fds[0], c"x", 1, msg_nosignal()))
	assert_equal(IO_OK, socket_shutdown_checked(fds[0], NET_SHUT_WRITE, &r))
	assert_equal(0, close(fds[0]))
	assert_equal(0, close(fds[1]))


int socket_identity_noop(void* context, io_result* r):
	return io_result_set(r, 0, IO_OK, 0)


void test_socket_identity_optional_adapter_is_explicitly_unsupported():
	transport* t = transport_new(malloc(1), 0, 0, socket_identity_noop, c"display only")
	io_result r
	net_peer_address address
	net_peer_credentials cred
	assert_equal(IO_UNSUPPORTED, transport_peer_address(t, &address, &r))
	assert_equal(0, r.native_error)
	assert_equal(0, address.length)
	assert_equal(IO_UNSUPPORTED, transport_peer_credentials(t, &cred, &r))
	assert_equal(-1, cred.uid)
	assert_equal(IO_UNSUPPORTED, transport_shutdown(t, NET_SHUT_WRITE, &r))
	assert_equal(0, t.shutdown_mask)
	transport_free(t)


generator int socket_identity_cancelled_task(transport* t):
	task_cancel(task_current())
	io_result r
	net_peer_address address
	net_peer_credentials cred
	assert_equal(IO_CANCELLED, transport_peer_address(t, &address, &r))
	assert_equal(IO_CANCELLED, transport_peer_credentials(t, &cred, &r))
	assert_equal(IO_CANCELLED, transport_shutdown(t, NET_SHUT_WRITE, &r))
	assert_equal(0, t.shutdown_mask)


void test_socket_identity_control_honors_task_cancellation():
	int[2] fds
	assert_equal(0, socket_pair(cast(int*, &fds[0])))
	transport* t = transport_from_socket(fds[0], 0, 1)
	task_scheduler* scheduler = task_scheduler_new()
	task_spawn(scheduler, socket_identity_cancelled_task(t))
	task_run(scheduler)
	task_scheduler_free(scheduler)
	assert_equal(1, socket_send(fds[0], c"x", 1, msg_nosignal()))
	transport_free(t)
	close(fds[1])


void test_socket_identity_read_shutdown_keeps_write_direction_live():
	int[2] fds
	assert_equal(0, socket_pair(&fds[0]))
	transport* a = transport_from_socket(fds[0], 0, 1)
	transport* b = transport_from_socket(fds[1], 0, 1)
	transport_set_timeout(a, 1000)
	transport_set_timeout(b, 1000)
	io_result r
	char[4] buf
	assert_equal(IO_OK, transport_shutdown(a, NET_SHUT_READ, &r))
	assert_equal(IO_OK, transport_shutdown(a, NET_SHUT_READ, &r))
	assert_equal(IO_EOF, transport_read_some(a, &buf[0], 1, &r))
	assert_equal(IO_OK, transport_write_all(a, c"live", 4, &r))
	assert_equal(IO_OK, transport_read_exact(b, &buf[0], 4, &r))
	assert_bytes_equal(c"live", &buf[0], 4)
	transport_free(a)
	transport_free(b)


void test_socket_identity_preserves_enotsock_and_enotconn():
	io_result r
	net_peer_address address
	net_peer_credentials cred
	int fd = open(c"/dev/null", 0, 0)
	assert1(fd >= 0)
	int enotsock = 88
	int enotconn = 107
	if (msg_nosignal() == 0):
		enotsock = 38
		enotconn = 57
	assert_equal(IO_IO_ERROR, socket_peer_address_checked(fd, &address, &r))
	assert_equal(enotsock, r.native_error)
	assert_equal(IO_IO_ERROR, socket_peer_credentials_checked(fd, &cred, &r))
	assert_equal(enotsock, r.native_error)
	assert_equal(IO_IO_ERROR, socket_shutdown_checked(fd, NET_SHUT_WRITE, &r))
	assert_equal(enotsock, r.native_error)
	close(fd)
	fd = socket_tcp_ipv4()
	assert1(fd >= 0)
	assert_equal(IO_IO_ERROR, socket_peer_address_checked(fd, &address, &r))
	assert_equal(enotconn, r.native_error)
	assert_equal(IO_IO_ERROR, socket_shutdown_checked(fd, NET_SHUT_WRITE, &r))
	assert_equal(enotconn, r.native_error)
	close(fd)


void test_socket_identity_rejects_linux_datagram_dummy_credentials():
	if (msg_nosignal() == 0): return
	char* pid = itoa(getpid())
	char* path = strjoin(c"/tmp/w_socket_identity_dgram_", pid)
	free(pid)
	int server = sys_socket(af_unix, sock_dgram, 0)
	int client = sys_socket(af_unix, sock_dgram, 0)
	assert1(server >= 0 && client >= 0)
	assert_equal(0, socket_bind_unix(server, path))
	assert_equal(0, socket_connect_unix(client, path))
	net_peer_address address
	net_peer_credentials credentials
	io_result r
	assert_equal(IO_OK, socket_peer_address_checked(client, &address, &r))
	assert_equal(af_unix, address.family)
	assert_equal(IO_UNSUPPORTED, socket_peer_credentials_checked(client, &credentials, &r))
	assert_equal(0, r.native_error)
	assert_equal(-1, credentials.pid)
	assert_equal(-1, credentials.uid)
	assert_equal(-1, credentials.gid)
	close(client)
	close(server)
	unlink(path)
	free(path)
