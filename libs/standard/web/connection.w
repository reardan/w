# ConnectionContext: one accepted TCP connection (plain or TLS) for the
# pure-W HTTP server framework (issue #235, phase 1). This is the
# transport layer that libs/standard/web/http_server.w's ServerContext
# accept loop hands requests off from.
#
# A ConnectionContext wraps a buffered reader (lib/stream.w's wstream)
# over a BLOCKING socket with SO_RCVTIMEO/SO_SNDTIMEO armed (the timeout
# plumbing libs/standard/web/http_client.w's https path added for issue
# #204: socket_set_recv_timeout/socket_set_send_timeout bound every wait
# so a stalled peer can never wedge the server), plus an optional TLS
# transport wired by libs/standard/net/tls.w's server role (tls_accept).
# Unlike http_client.w's http_conn -- which keeps the plaintext path
# nonblocking (poll-driven, to support its nonblocking connect) and only
# the https path blocking -- a ConnectionContext is always blocking:
# server_context_accept_loop() completes accept()/tls_accept() before a
# ConnectionContext exists, so there is no connect step to interleave,
# and one blocking-with-timeout code path serves both http and https
# identically (the caller passes tls == 0 for plain, or the tls_conn*
# from tls_accept).
#
# NAMING: ConnectionContext, and libs/standard/web/http_server.w's
# ServerContext/ServerRequest/ServerResponse, use PascalCase -- a
# deliberate departure from the codebase's lowercase_snake_case
# convention, chosen by the maintainer (issue #235) to mark the
# high-level public server-framework surface, as distinct from the
# lowercase_snake_case primitives underneath (tls_conn, wstream,
# sockaddr_in, URL, ...). Function names stay snake_case throughout,
# matching the rest of the codebase; only these struct type names are
# capitalized.
#
# Public API:
#   ConnectionContext* connection_context_new(int fd, int timeout_ms, tls_conn* tls)
#   void connection_context_set_peer(ConnectionContext* c, int ip, int port)
#   void connection_context_destroy(ConnectionContext* c)
#   int connection_context_read_byte(ConnectionContext* c)
#   int connection_context_read(ConnectionContext* c, char* out, int want)
#   int connection_context_read_exact(ConnectionContext* c, char* out, int n)
#   int connection_context_read_line(ConnectionContext* c, string_builder* line, int oversize_error)
#   int connection_context_expect_crlf(ConnectionContext* c)
#   int connection_context_write_all(ConnectionContext* c, char* data, int n)
#   int connection_error_*()  /  char* connection_error_string(int code)
import lib.lib
import lib.net
import lib.stream
import structures.string
import libs.standard.net.tls


# One accepted connection. reader is a buffered reader over fd; tls is 0
# for a plain connection or the completed server-side tls_conn from
# tls_accept for https (owned by this ConnectionContext -- destroy closes
# it). peer_ip/peer_port are the client's address (0/0 until
# connection_context_set_peer is called; see socket_accept_connection_from
# in lib/net.w). keep_alive is server_context's running verdict on
# whether to read another request off this connection after the current
# response -- request parsing and response writing both update it.
struct ConnectionContext:
	int fd
	wstream* reader
	int timeout_ms
	int error
	int received_any
	tls_conn* tls
	int peer_ip
	int peer_port
	int keep_alive


int connection_error_none():
	return 0


int connection_error_recv():
	return 1


int connection_error_send():
	return 2


int connection_error_timeout():
	return 3


char* connection_error_string(int code):
	if (code == connection_error_none()):
		return c""
	if (code == connection_error_recv()):
		return c"receive failed"
	if (code == connection_error_send()):
		return c"send failed"
	if (code == connection_error_timeout()):
		return c"timed out"
	return c"unknown error"


# Cap on one line read by connection_context_read_line (request line,
# one header line, one chunk-size line). Mirrors http_client.w's
# http_max_header_line(); kept as an independent constant here so this
# module stays a generic buffered-connection layer with no HTTP-specific
# import (http_server.w, which is HTTP-specific, reuses http_client.w's
# http_max_header_bytes()/http_max_chunk_size()/http_max_body_bytes()
# directly for the whole-header-block and body caps).
int connection_max_line_bytes():
	return 8192


# fd must already be a connected/accepted socket with SO_RCVTIMEO/
# SO_SNDTIMEO armed to timeout_ms (server_context_accept_loop does this
# before constructing a ConnectionContext); tls is the completed
# tls_accept() connection for https, or 0 for plain http. Ownership of
# both fd and tls transfers to the ConnectionContext.
ConnectionContext* connection_context_new(int fd, int timeout_ms, tls_conn* tls):
	ConnectionContext* c = new ConnectionContext()
	c.fd = fd
	c.reader = stream_reader(fd)
	c.timeout_ms = timeout_ms
	c.error = 0
	c.received_any = 0
	c.tls = tls
	c.peer_ip = 0
	c.peer_port = 0
	c.keep_alive = 1
	return c


void connection_context_set_peer(ConnectionContext* c, int ip, int port):
	c.peer_ip = ip
	c.peer_port = port


# Closes the transport (TLS gets a close_notify and its keys wiped, via
# tls_close, before the fd closes) and releases the reader.
void connection_context_destroy(ConnectionContext* c):
	if (c == 0):
		return
	if (c.tls != 0):
		tls_close(c.tls)
	close(c.fd)
	stream_free(c.reader)
	free(c)


# Refills the reader buffer from the socket/TLS record layer, blocking up
# to timeout_ms (SO_RCVTIMEO / TLS read timeout). Returns 1 when bytes
# are buffered, 0 on EOF, -1 on error or timeout (c.error set). Mirrors
# http_client.w's http_conn_fill, but always blocking (see the module
# doc): no poll loop is needed because the timeout is a socket option,
# not a connect-style wait.
int connection_context_fill(ConnectionContext* c):
	wstream* r = c.reader
	if (r.position < r.limit):
		return 1
	if (r.eof != 0):
		return 0
	r.position = 0
	r.limit = 0
	if (c.tls != 0):
		int tcount = tls_read(c.tls, r.buffer, r.capacity)
		if (tcount > 0):
			r.limit = tcount
			c.received_any = 1
			return 1
		if (tcount == 0):
			r.eof = 1
			return 0
		if (c.tls.broken != 0):
			c.error = connection_error_recv()
		else:
			c.error = connection_error_timeout()
		return (-1)
	while (1):
		int count = socket_recv(c.fd, r.buffer, r.capacity, 0)
		if (count > 0):
			r.limit = count
			c.received_any = 1
			return 1
		if (count == 0):
			r.eof = 1
			return 0
		if (count == (0 - 4)):
			# EINTR: retry the same recv.
			pass
		else if (count == (0 - net_eagain())):
			c.error = connection_error_timeout()
			return (-1)
		else:
			c.error = connection_error_recv()
			return (-1)


# Next byte, or -1 on EOF/error (EOF leaves c.error at 0).
int connection_context_read_byte(ConnectionContext* c):
	int state = connection_context_fill(c)
	if (state <= 0):
		return (-1)
	wstream* r = c.reader
	int b = r.buffer[r.position] & 255
	r.position = r.position + 1
	return b


# Reads up to want bytes (at least 1 unless the stream ends). Returns
# the count, 0 on EOF, -1 on error (c.error set).
int connection_context_read(ConnectionContext* c, char* out, int want):
	int state = connection_context_fill(c)
	if (state <= 0):
		return state
	wstream* r = c.reader
	int n = r.limit - r.position
	if (n > want):
		n = want
	int i = 0
	while (i < n):
		out[i] = r.buffer[r.position + i]
		i = i + 1
	r.position = r.position + n
	return n


# Reads exactly n bytes into out, looping over short reads. Returns 1,
# or 0 on EOF/error before n bytes arrived.
int connection_context_read_exact(ConnectionContext* c, char* out, int n):
	int total = 0
	while (total < n):
		int got = connection_context_read(c, out + total, n - total)
		if (got <= 0):
			return 0
		total = total + got
	return 1


# Reads one line, accepting CRLF or bare LF and stripping both. Returns
# 1 on a line, 0 on EOF before any byte, -1 on error: c.error is
# oversize_error when the line exceeds http_max_header_line(), stays 0
# for EOF mid-line (caller picks the code), or is already set by the
# transport.
int connection_context_read_line(ConnectionContext* c, string_builder* line, int oversize_error):
	string_clear(line)
	while (1):
		int b = connection_context_read_byte(c)
		if (b < 0):
			if (c.error != 0):
				return (-1)
			if (line.length == 0):
				return 0
			return (-1)
		if (b == 10):
			if (line.length > 0):
				if (line.data[line.length - 1] == 13):
					line.length = line.length - 1
					line.data[line.length] = 0
			return 1
		if (line.length >= connection_max_line_bytes()):
			c.error = oversize_error
			return (-1)
		string_append_char(line, b)


# The CRLF that terminates each chunk's data in a chunked body (bare LF
# tolerated), mirroring http_client.w's http_conn_expect_crlf.
int connection_context_expect_crlf(ConnectionContext* c):
	int b = connection_context_read_byte(c)
	if (b == 13):
		b = connection_context_read_byte(c)
	if (b != 10):
		return 0
	return 1


# Sends all n bytes, blocking up to SO_SNDTIMEO. Returns 1, or 0 with
# c.error set.
int connection_context_write_all(ConnectionContext* c, char* data, int n):
	if (c.tls != 0):
		if (n <= 0):
			return 1
		int wrote = tls_write(c.tls, data, n)
		if (wrote == n):
			return 1
		c.error = connection_error_send()
		return 0
	int total = 0
	while (total < n):
		int count = socket_send(c.fd, data + total, n - total, msg_nosignal())
		if (count > 0):
			total = total + count
		else if (count == 0):
			c.error = connection_error_send()
			return 0
		else if (count == (0 - 4)):
			# EINTR: retry the same send.
			pass
		else if (count == (0 - net_eagain())):
			c.error = connection_error_timeout()
			return 0
		else:
			c.error = connection_error_send()
			return 0
	return 1
