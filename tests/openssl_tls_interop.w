/*
openssl s_client/s_server interop harness (issue #236).

Optional / manual target: NOT part of the tests umbrella. Run it with
`./wbuild openssl_interop_test`; tools/openssl_interop_test.sh gates on
`which openssl` and generates a throwaway ECDSA P-256 cert, and the
manifest runs each harness binary under an external timeout(1).

Usage: openssl_tls_interop <openssl-path> <cert.pem> <key.pem>
(<openssl-path> must be absolute or repo-relative: process_spawn execs
directly, without a PATH search — the runner script resolves it.)

Two real handshakes against the installed openssl:
  1. client direction: spawn `openssl s_server -rev`, tls_connect to it,
     write a line, read the reversed echo.
  2. server direction: listen, spawn `openssl s_client`, tls_accept the
     connection, exchange one line each way through the client's
     stdin/stdout pipes.

Every wait is bounded, which is the #236 lesson: the prototype interop
harness could wedge forever in a blocking recv when its openssl peer was
never going to answer (port collision between concurrently running arch
twins, peer busy with the other twin's connection, or a protocol
mismatch), and wbuild had no per-test timeout. Here the TCP sockets get
SO_RCVTIMEO/SO_SNDTIMEO before the TLS handshake (the listener's
SO_RCVTIMEO also bounds accept), connect retries are counted, pipe reads
go through poll with a timeout, subprocess reaping uses
process_wait_or_kill, and each direction picks a fresh kernel-assigned
port instead of sharing a hardcoded one. A misbehaving peer fails the
test; it cannot hang it.
*/
import lib.lib
import lib.args
import lib.net
import lib.poll
import lib.process
import libs.standard.net.tls


int osl_io_timeout_ms():
	return 10000


# Ask the kernel for a currently free TCP port (bind 0, read it back,
# close). The tiny reuse race is acceptable: a collision fails the test
# within the bounded timeouts instead of hanging it.
int osl_free_port():
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return -1
	if (socket_bind_ipv4(fd, ip4_from_string(c"127.0.0.1"), 0) < 0):
		close(fd)
		return -1
	sockaddr_in addr
	if (socket_getsockname_ipv4(fd, &addr) < 0):
		close(fd)
		return -1
	close(fd)
	return net_htons(addr.port & 65535)


# Kill (best effort) and reap the openssl subprocess, then report failure.
int osl_fail(process* p, char* msg, char* detail):
	print(c"openssl interop: ")
	print(msg)
	if (detail != 0):
		print(c": ")
		print(detail)
	print(c"\x0a")
	if (p != 0):
		process_kill(p, sigkill())
		process_wait_or_kill(p, osl_io_timeout_ms())
		process_free(p)
	return 0


int osl_bytes_equal(char* a, char* b, int n):
	int i = 0
	while (i < n):
		if (a[i] != b[i]):
			return 0
		i = i + 1
	return 1


# Connect to 127.0.0.1:port, retrying while the just-spawned server boots.
# Bounded: ~5s of attempts, then -1.
int osl_connect_retry(int port):
	int tries = 0
	while (tries < 100):
		int fd = socket_tcp_ipv4()
		if (fd < 0):
			return -1
		if (socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0):
			return fd
		close(fd)
		process_sleep_ms(50)
		tries = tries + 1
	return -1


# Direction 1: our tls_connect client against `openssl s_server -rev`.
int osl_client_direction(char* openssl_bin, char* cert, char* key):
	int port = osl_free_port()
	if (port <= 0):
		return osl_fail(0, c"client: no free port", 0)

	char** sargv = strv_new(12)
	strv_set(sargv, 0, c"openssl")
	strv_set(sargv, 1, c"s_server")
	strv_set(sargv, 2, c"-accept")
	strv_set(sargv, 3, itoa(port))
	strv_set(sargv, 4, c"-cert")
	strv_set(sargv, 5, cert)
	strv_set(sargv, 6, c"-key")
	strv_set(sargv, 7, key)
	strv_set(sargv, 8, c"-naccept")
	strv_set(sargv, 9, c"1")
	strv_set(sargv, 10, c"-rev")
	strv_set(sargv, 11, c"-quiet")

	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_null()
	opts.stderr_mode = process_null()
	process* p = process_spawn(openssl_bin, sargv, opts)
	free(opts)
	if (p == 0):
		return osl_fail(0, c"client: spawn s_server failed", 0)

	int fd = osl_connect_retry(port)
	if (fd < 0):
		return osl_fail(p, c"client: connect to s_server failed", 0)
	# Bound every blocking send/recv inside the handshake and after it.
	socket_set_recv_timeout(fd, osl_io_timeout_ms())
	socket_set_send_timeout(fd, osl_io_timeout_ms())

	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1   # throwaway self-signed test cert
	tls_conn* conn = tls_connect(fd, c"localhost", cfg)
	if (conn == 0):
		int r = osl_fail(p, c"client: tls_connect failed", tls_last_error(cfg))
		tls_config_free(cfg)
		close(fd)
		return r
	char* ping = c"ping\x0a"
	if (tls_write(conn, ping, strlen(ping)) != strlen(ping)):
		tls_close(conn)
		tls_config_free(cfg)
		close(fd)
		return osl_fail(p, c"client: tls_write failed", 0)
	char* buf = malloc(64)
	int got = tls_read(conn, buf, 64)
	char* want = c"gnip\x0a"   # -rev echoes the line reversed
	int ok = 0
	if (got == strlen(want)):
		ok = osl_bytes_equal(buf, want, got)
	free(buf)
	tls_close(conn)
	tls_config_free(cfg)
	close(fd)
	if (ok == 0):
		return osl_fail(p, c"client: bad -rev echo payload", 0)
	process_kill(p, sigterm())
	process_wait_or_kill(p, osl_io_timeout_ms())
	process_free(p)
	return 1


# Direction 2: our tls_accept server against `openssl s_client`.
int osl_server_direction(char* openssl_bin, char* cert, char* key):
	int lfd = socket_tcp_ipv4()
	if (lfd < 0):
		return osl_fail(0, c"server: socket failed", 0)
	socket_set_reuseaddr(lfd)
	if (socket_bind_ipv4(lfd, ip4_from_string(c"127.0.0.1"), 0) < 0):
		close(lfd)
		return osl_fail(0, c"server: bind failed", 0)
	sockaddr_in addr
	if (socket_getsockname_ipv4(lfd, &addr) < 0):
		close(lfd)
		return osl_fail(0, c"server: getsockname failed", 0)
	int port = net_htons(addr.port & 65535)
	socket_listen(lfd, 4)
	# SO_RCVTIMEO on a listening socket bounds accept() as well.
	socket_set_recv_timeout(lfd, osl_io_timeout_ms())

	char** sargv = strv_new(7)
	strv_set(sargv, 0, c"openssl")
	strv_set(sargv, 1, c"s_client")
	strv_set(sargv, 2, c"-connect")
	strv_set(sargv, 3, strjoin(c"127.0.0.1:", itoa(port)))
	strv_set(sargv, 4, c"-servername")
	strv_set(sargv, 5, c"localhost")
	strv_set(sargv, 6, c"-quiet")

	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_pipe()
	opts.stdout_mode = process_pipe()
	opts.stderr_mode = process_null()
	process* p = process_spawn(openssl_bin, sargv, opts)
	free(opts)
	if (p == 0):
		close(lfd)
		return osl_fail(0, c"server: spawn s_client failed", 0)

	int cfd = socket_accept_connection(lfd)
	close(lfd)
	if (cfd < 0):
		return osl_fail(p, c"server: accept failed (timeout?)", 0)
	socket_set_recv_timeout(cfd, osl_io_timeout_ms())
	socket_set_send_timeout(cfd, osl_io_timeout_ms())

	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = cert
	scfg.key_path = key
	tls_conn* conn = tls_accept(cfd, scfg)
	if (conn == 0):
		int r = osl_fail(p, c"server: tls_accept failed", tls_server_last_error(scfg))
		tls_server_config_free(scfg)
		close(cfd)
		return r

	# Feed one line into s_client's stdin (it forwards it over TLS after
	# the handshake); a 5-byte pipe write cannot block.
	char* pong = c"pong\x0a"
	write(p.stdin_fd, pong, strlen(pong))
	char* buf = malloc(64)
	int got = tls_read(conn, buf, 64)
	int ok = 0
	if (got == strlen(pong)):
		ok = osl_bytes_equal(buf, pong, got)
	if (ok == 0):
		free(buf)
		tls_close(conn)
		tls_server_config_free(scfg)
		close(cfd)
		return osl_fail(p, c"server: bad payload from s_client", 0)

	# Send one line back; s_client prints it on its stdout pipe.
	char* ping = c"ping\x0a"
	if (tls_write(conn, ping, strlen(ping)) != strlen(ping)):
		free(buf)
		tls_close(conn)
		tls_server_config_free(scfg)
		close(cfd)
		return osl_fail(p, c"server: tls_write failed", 0)
	ok = 0
	if (poll_single(p.stdout_fd, poll_in(), osl_io_timeout_ms()) > 0):
		got = read(p.stdout_fd, buf, 64)
		if (got == strlen(ping)):
			ok = osl_bytes_equal(buf, ping, got)
	free(buf)
	tls_close(conn)
	tls_server_config_free(scfg)
	close(cfd)
	if (ok == 0):
		return osl_fail(p, c"server: s_client did not echo our line", 0)
	process_kill(p, sigterm())
	process_wait_or_kill(p, osl_io_timeout_ms())
	process_free(p)
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_count() < 4):
		print(c"usage: openssl_tls_interop <openssl-path> <cert.pem> <key.pem>\x0a")
		return 2
	char* openssl_bin = args_get(1)
	char* cert = args_get(2)
	char* key = args_get(3)
	if (osl_client_direction(openssl_bin, cert, key) == 0):
		return 1
	if (osl_server_direction(openssl_bin, cert, key) == 0):
		return 1
	print(c"openssl interop OK\x0a")
	return 0
