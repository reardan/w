/*
Checked TLS 1.3 adapter for lib/transport.w. Owns the connected socket on
EVERY constructor path. Client/server configurations are borrowed for the
handshake only. Clients verify the trust chain and expected DNS hostname;
verified connections report authenticated=1 for the verified peer. Servers
can optionally or mandatorily authenticate client certificates; the peer
identity is tls-client-sha256:<leaf DER fingerprint> (see mutual_tls.md).

All syscalls are nonblocking, regardless of the socket's flags. io_poll
parks a task or polls the thread, bounded by the transport's absolute
deadline. A failed TLS record cannot be resumed: an I/O error/timeout/
cancellation during a record poisons this connection, so close/reconnect.
write_all reports plaintext in fully sent records as its confirmed prefix;
bytes in an incomplete encrypted record are never claimed as delivered.
One operation at a time per transport; concurrent read/write is unsupported.

close sends close_notify within the current deadline (at most 1000 ms if
none is set), reports that error or close(2)'s error, then always closes the
socket and wipes keys. It never waits for the peer's close_notify.
*/
import lib.transport
import libs.standard.net.tls


struct transport_tls:
	tls_conn* conn
	transport* owner
	char* last_error                 # static message survives close


void transport_tls_begin(tls_conn* c, int timeout_ms):
	c.last_io_status = IO_OK
	c.last_native_error = 0
	c.last_error = 0
	c.io_timeout_ms = timeout_ms
	c.has_io_deadline = timeout_ms >= 0
	if (timeout_ms >= 0): c.io_deadline_ms = time_monotonic_ms() + timeout_ms


int transport_tls_failure(transport_tls* s, io_result* r):
	tls_conn* c = s.conn
	c.broken = 1
	# A poisoned record can never be retried by the generic transport.
	if (c.last_io_status == IO_OK || c.last_io_status == IO_INTERRUPTED || c.last_io_status == IO_WOULD_BLOCK): c.last_io_status = IO_IO_ERROR
	if (c.last_error == 0): c.last_error = c"tls: protocol failure"
	s.last_error = c.last_error
	return io_result_set(r, 0, c.last_io_status, c.last_native_error)


int transport_tls_read(void* context, char* buf, int len, int timeout_ms, io_result* r):
	transport_tls* s = cast(transport_tls*, context)
	tls_conn* c = s.conn
	if (c.broken): return transport_tls_failure(s, r)
	transport_tls_begin(c, timeout_ms)
	int n = tls_read(c, buf, len)
	if (n < 0): return transport_tls_failure(s, r)
	if (n == 0): return io_result_set(r, 0, IO_EOF, 0)
	return io_result_set(r, n, IO_OK, 0)


int transport_tls_write(void* context, char* buf, int len, int timeout_ms, io_result* r):
	transport_tls* s = cast(transport_tls*, context)
	tls_conn* c = s.conn
	if (c.broken): return transport_tls_failure(s, r)
	transport_tls_begin(c, timeout_ms)
	# One full record per adapter call preserves the confirmed prefix in
	# transport_write_all even when a later record fails partway through.
	if (len > TLS_MAX_PLAINTEXT): len = TLS_MAX_PLAINTEXT
	int n = tls_write(c, buf, len)
	if (n < 0): return transport_tls_failure(s, r)
	return io_result_set(r, n, IO_OK, 0)


int transport_tls_close(void* context, io_result* r):
	transport_tls* s = cast(transport_tls*, context)
	tls_conn* c = s.conn
	int status = IO_OK
	int native_error = 0
	if (c.broken == 0):
		int left = transport_remaining_ms(s.owner)
		if (left < 0): left = 1000
		transport_tls_begin(c, left)
		if (tls_send_alert(c, TLS_ALERT_WARNING, TLS_ALERT_CLOSE_NOTIFY) == 0):
			status = transport_tls_failure(s, r)
			native_error = r.native_error
	io_result closed
	int close_status = net_result_from_syscall(&closed, close(c.fd))
	tls_conn_free(c)
	s.conn = 0
	if (status != IO_OK): return io_result_set(r, 0, status, native_error)
	return io_result_set(r, 0, close_status, closed.native_error)


# Per-connection diagnostic, unaffected by another handshake using the
# same config. Static string, valid until transport_free (also after close).
char* transport_tls_last_error(transport* t):
	transport_tls* s = cast(transport_tls*, t.context)
	return s.last_error


transport* transport_tls_finish(tls_conn* c, int ok, char* peer, int authenticated, io_result* r):
	transport_tls* s = new transport_tls(c, 0, 0)
	if (ok == 0):
		transport_tls_failure(s, r)
		close(c.fd)
		tls_conn_free(c)
		free(s)
		return 0
	# The connection keeps its own errors; do not retain borrowed configs.
	c.cfg = 0
	c.scfg = 0
	transport* t = transport_new(cast(void*, s), transport_tls_read, transport_tls_write, transport_tls_close, peer)
	s.owner = t
	t.authenticated = authenticated
	io_result_set(r, 0, IO_OK, 0)
	return t


# Setup failure still consumes the owned fd. Darwin must install
# SO_NOSIGPIPE successfully before the first handshake write.
int transport_tls_prepare(int fd, io_result* r):
	int ready = io_check()
	if (ready < 0):
		io_result_from_syscall(r, ready)
		close(fd)
		return 0
	ready = socket_set_nosigpipe(fd)
	if (ready < 0):
		net_result_from_syscall(r, ready)
		close(fd)
		return 0
	return 1


# Wrap an already connected fd and perform a TLS handshake. server_name
# is the DNS identity to verify, independent of the socket's IP address.
# Config may be 0 for secure defaults; skip-verify never authenticates.
transport* transport_tls_connect(int fd, char* server_name, tls_config* cfg, int timeout_ms, io_result* r):
	if (transport_tls_prepare(fd, r) == 0): return 0
	tls_conn* c = tls_conn_new(fd, 0, cfg)
	c.checked_io = 1
	transport_tls_begin(c, timeout_ms)
	int verified = 1
	if (cfg != 0):
		if (cfg.insecure_skip_verify): verified = 0
	int ok = tls_do_handshake(c, server_name)
	verified = verified && c.peer_verified
	if (server_name == 0): server_name = c"unknown"
	char* peer = strjoin(c"tls:", server_name)
	transport* t = transport_tls_finish(c, ok, peer, verified, r)
	free(peer)
	return t


# Owns an accepted fd. For an authenticated client, peer is replaced with
# the verified leaf fingerprint. Otherwise it remains an untrusted address
# description. Config must supply certificate/key.
transport* transport_tls_accept(int fd, char* peer, tls_server_config* cfg, int timeout_ms, io_result* r):
	if (transport_tls_prepare(fd, r) == 0): return 0
	tls_conn* c = tls_conn_new(fd, 0, 0)
	c.is_server = 1
	c.scfg = cfg
	c.checked_io = 1
	transport_tls_begin(c, timeout_ms)
	int ok = 0
	if (cfg == 0): tls_fail(c, c"tls: server configuration required")
	else: ok = tls_server_do_handshake(c)
	char* identity = 0
	int verified = ok && c.peer_verified
	if (verified): identity = strjoin(c"tls-client-sha256:", c.peer_certificate_sha256)
	if (identity != 0): peer = identity
	transport* t = transport_tls_finish(c, ok, peer, verified, r)
	if (identity != 0): free(identity)
	return t
