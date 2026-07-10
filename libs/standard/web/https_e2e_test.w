# End-to-end tests for https:// through libs/standard/web/http_client.w
# (plan 11 phase 9, issue #204, part of #155). Everything runs offline: a
# pure-W tls_accept server (libs/standard/net/tls.w) using the checked-in
# synthetic ECDSA P-256 fixture in libs/standard/net/tls_fixtures/ serves
# HTTP over TLS on a loopback ephemeral port, and the http_client fetches
# https://127.0.0.1:PORT/... through the FULL path (url_parse -> DNS
# literal -> tls_connect -> request -> response). No external tools, no
# network -- the fork()-based fixture-server pattern from
# libs/standard/web/http_client_test.w and libs/standard/net/tls_server_test.w.
#
# The fixture cert's SAN is test.w.example, which cannot match 127.0.0.1, so
# the client connects with tls_insecure_skip_verify = 1: chain + hostname
# checks are skipped, but the real X25519 + ChaCha20-Poly1305 handshake, the
# server's ECDSA CertificateVerify signature, and the Finished MAC are all
# still exercised. Every network wait on both sides is bounded (client:
# req.timeout_ms via SO_RCVTIMEO; server: an explicit 5s recv/send timeout)
# so a stalled peer can never wedge a test.
#
# Coverage: a full GET (status + headers + body), SSE streamed over TLS,
# keep-alive reuse of a cached TLS connection, an http->https cross-scheme
# redirect, and the handshake / header / idle-stream timeouts each firing.
import lib.testing
import lib.net
import lib.time
import structures.string
import libs.standard.web.http_client
import libs.standard.web.sse
import libs.standard.net.tls


# ---- shared helpers -----------------------------------------------------------

char* hs_cert_path():
	return c"libs/standard/net/tls_fixtures/server_p256_cert.pem"


char* hs_key_path():
	return c"libs/standard/net/tls_fixtures/server_p256_key.pem"


# Listener on 127.0.0.1 with a kernel-assigned port (returned via out_port).
int hs_listen(int* out_port):
	int listener = socket_tcp_ipv4()
	if (listener < 0):
		exit(31)
	socket_set_reuseaddr(listener)
	if (socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0) < 0):
		exit(32)
	if (socket_listen(listener, 8) < 0):
		exit(33)
	sockaddr_in bound
	if (socket_getsockname_ipv4(listener, &bound) < 0):
		exit(34)
	*out_port = net_htons(bound.port)
	return listener


char* hs_scheme_url(char* scheme, int port, char* path):
	string_builder* out = string_new()
	string_append(out, scheme)
	string_append(out, c"://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


char* hs_url(int port, char* path):
	return hs_scheme_url(c"https", port, path)


char* hs_http_url(int port, char* path):
	return hs_scheme_url(c"http", port, path)


# Offset just past the CRLFCRLF that ends a request head, or -1.
int hs_head_end(char* buf, int total):
	int i = 0
	while (i + 3 < total):
		if ((buf[i] == 13) & (buf[i + 1] == 10) & (buf[i + 2] == 13) & (buf[i + 3] == 10)):
			return i + 4
		i = i + 1
	return (-1)


# ---- (child) server-side helpers ----------------------------------------------

# Accept one TCP connection and complete the TLS server handshake with the
# fixture credentials, bounding the child's own recv/send so a stalled
# client cannot wedge it. Exits the child on any failure (distinct codes).
tls_conn* hs_child_accept(int listener):
	int conn = socket_accept_connection(listener)
	if (conn < 0):
		exit(21)
	socket_set_recv_timeout(conn, 5000)
	socket_set_send_timeout(conn, 5000)
	tls_server_config* scfg = tls_server_config_new()
	scfg.cert_chain_path = hs_cert_path()
	scfg.key_path = hs_key_path()
	tls_conn* tc = tls_accept(conn, scfg)
	if (tc == 0):
		exit(22)
	return tc


# Read one request head over TLS (until CRLFCRLF, EOF, or the recv timeout).
void hs_child_read_request(tls_conn* tc):
	char* buf = malloc(8192)
	int total = 0
	int done = 0
	while (done == 0):
		if (total >= 8192):
			done = 1
		else:
			int got = tls_read(tc, buf + total, 8192 - total)
			if (got <= 0):
				done = 1
			else:
				total = total + got
				if (hs_head_end(buf, total) >= 0):
					done = 1
	free(buf)


# Same over a raw (plaintext) socket.
void hs_child_read_request_raw(int conn):
	char* buf = malloc(8192)
	int total = 0
	int done = 0
	while (done == 0):
		if (total >= 8192):
			done = 1
		else:
			int got = read(conn, buf + total, 8192 - total)
			if (got <= 0):
				done = 1
			else:
				total = total + got
				if (hs_head_end(buf, total) >= 0):
					done = 1
	free(buf)


# Send every byte over a raw socket (best effort; SIGPIPE-proof).
void hs_send_all_raw(int conn, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(conn, data + total, n - total, msg_nosignal())
		if (got <= 0):
			total = n
		else:
			total = total + got


# Drain a raw socket until the peer closes (or the recv timeout fires).
void hs_drain_raw(int conn):
	char* d = malloc(1024)
	int got = read(conn, d, 1024)
	while (got > 0):
		got = read(conn, d, 1024)
	free(d)


# (child) After serving, wait for the client's close_notify (returns 0) so
# the connection tears down cleanly, then close.
void hs_child_wait_close(tls_conn* tc):
	char* d = malloc(64)
	tls_read(tc, d, 64)
	free(d)
	tls_close(tc)


# ---- (parent) reaping ---------------------------------------------------------

# Drop the cached keep-alive connection (so it never leaks into the next
# test), reap the child, and assert it exited cleanly.
void hs_finish(int pid, int listener):
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	close(listener)
	asserts(c"server child exited cleanly", status == 0)


# ---- tests --------------------------------------------------------------------

# A full GET over TLS: status line, headers, and a Content-Length body all
# survive the round trip through url_parse -> tls_connect -> request/response.
void test_https_loopback_get():
	int port = 0
	int listener = hs_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		tls_conn* tc = hs_child_accept(listener)
		hs_child_read_request(tc)
		char* resp = c"HTTP/1.1 200 OK\x0d\x0aContent-Type: text/plain\x0d\x0aContent-Length: 5\x0d\x0aX-W-Test: yes\x0d\x0a\x0d\x0ahello"
		tls_write(tc, resp, strlen(resp))
		hs_child_wait_close(tc)
		exit(0)

	char* target = hs_url(port, c"/hi")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello", resp.body)
	assert_equal(5, resp.body_len)
	assert_strings_equal(c"text/plain", http_response_header(resp, c"content-type"))
	assert_strings_equal(c"yes", http_response_header(resp, c"x-w-test"))
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hs_finish(pid, listener)


# Two GETs to the same https origin: the second reuses the cached TLS
# connection. The server only tls_accepts ONE socket, so a second GET can
# succeed only if the client reused the first connection (keying the idle
# cache on scheme+host+port).
void test_https_keep_alive_reuse():
	int port = 0
	int listener = hs_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		tls_conn* tc = hs_child_accept(listener)
		int k = 0
		while (k < 2):
			hs_child_read_request(tc)
			char* resp = c"HTTP/1.1 200 OK\x0d\x0aContent-Length: 3\x0d\x0a\x0d\x0aabc"
			tls_write(tc, resp, strlen(resp))
			k = k + 1
		hs_child_wait_close(tc)
		exit(0)

	char* target = hs_url(port, c"/keep")
	http_req* req1 = http_req_new(c"GET", target)
	req1.tls_insecure_skip_verify = 1
	http_response* r1 = http_request(req1)
	assert_equal(0, r1.error)
	assert_equal(200, r1.status)
	assert_strings_equal(c"abc", r1.body)
	http_response_free(r1)
	http_req_free(req1)

	http_req* req2 = http_req_new(c"GET", target)
	req2.tls_insecure_skip_verify = 1
	http_response* r2 = http_request(req2)
	assert_equal(0, r2.error)
	assert_equal(200, r2.status)
	assert_strings_equal(c"abc", r2.body)
	http_response_free(r2)
	http_req_free(req2)
	free(target)
	hs_finish(pid, listener)


# SSE composed over TLS: the server streams event-stream records, the client
# opens an https stream and sse_open/sse_next consume events incrementally.
void test_https_sse_over_tls():
	int port = 0
	int listener = hs_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		tls_conn* tc = hs_child_accept(listener)
		hs_child_read_request(tc)
		char* head = c"HTTP/1.1 200 OK\x0d\x0aContent-Type: text/event-stream\x0d\x0aConnection: close\x0d\x0a\x0d\x0a"
		tls_write(tc, head, strlen(head))
		char* e1 = c"data: one\n\n"
		tls_write(tc, e1, strlen(e1))
		char* e2 = c"event: tick\ndata: two\n\n"
		tls_write(tc, e2, strlen(e2))
		char* e3 = c"data: three\n\n"
		tls_write(tc, e3, strlen(e3))
		tls_close(tc)
		exit(0)

	char* target = hs_url(port, c"/events")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	http_stream* st = http_open(req)
	http_response* head = http_stream_headers(st)
	assert_equal(0, head.error)
	assert_equal(200, head.status)
	sse_reader* r = sse_open(st)

	sse_event* ev1 = sse_next(r)
	asserts(c"sse event 1 present", ev1 != 0)
	assert_strings_equal(c"message", ev1.event)
	assert_strings_equal(c"one", ev1.data)
	sse_event_free(ev1)

	sse_event* ev2 = sse_next(r)
	asserts(c"sse event 2 present", ev2 != 0)
	assert_strings_equal(c"tick", ev2.event)
	assert_strings_equal(c"two", ev2.data)
	sse_event_free(ev2)

	sse_event* ev3 = sse_next(r)
	asserts(c"sse event 3 present", ev3 != 0)
	assert_strings_equal(c"three", ev3.data)
	sse_event_free(ev3)

	sse_event* ev4 = sse_next(r)
	asserts(c"sse stream ends", ev4 == 0)
	assert_equal(sse_error_none(), sse_reader_error(r))

	sse_reader_free(r)
	http_stream_close(st)
	http_req_free(req)
	free(target)
	hs_finish(pid, listener)


# An http:// request that 302-redirects to an https:// URL: the client must
# switch transport from plaintext to TLS across the hop.
void test_https_cross_scheme_redirect():
	int plain_port = 0
	int plain_listener = hs_listen(&plain_port)
	int tls_port = 0
	int tls_listener = hs_listen(&tls_port)

	int pid_a = fork()
	asserts(c"fork failed", pid_a >= 0)
	if (pid_a == 0):
		close(tls_listener)
		int conn = socket_accept_connection(plain_listener)
		if (conn < 0):
			exit(1)
		socket_set_recv_timeout(conn, 5000)
		hs_child_read_request_raw(conn)
		string_builder* redirect = string_new()
		string_append(redirect, c"HTTP/1.1 302 Found\x0d\x0aLocation: https://127.0.0.1:")
		string_append_int(redirect, tls_port)
		string_append(redirect, c"/final\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a")
		hs_send_all_raw(conn, redirect.data, redirect.length)
		string_free(redirect)
		hs_drain_raw(conn)
		close(conn)
		exit(0)

	int pid_b = fork()
	asserts(c"fork failed", pid_b >= 0)
	if (pid_b == 0):
		close(plain_listener)
		tls_conn* tc = hs_child_accept(tls_listener)
		hs_child_read_request(tc)
		char* resp = c"HTTP/1.1 200 OK\x0d\x0aContent-Length: 7\x0d\x0a\x0d\x0aarrived"
		tls_write(tc, resp, strlen(resp))
		hs_child_wait_close(tc)
		exit(0)

	char* target = hs_http_url(plain_port, c"/start")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"arrived", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)

	http_client_close_idle()
	int status_a = 0
	int status_b = 0
	wait4(pid_a, &status_a, 0, 0)
	wait4(pid_b, &status_b, 0, 0)
	close(plain_listener)
	close(tls_listener)
	asserts(c"plaintext redirect child clean", status_a == 0)
	asserts(c"tls target child clean", status_b == 0)


# The connect step is bounded: a black-hole address (RFC 5737 TEST-NET-1,
# which never answers) makes connect fail within the timeout rather than
# hang -- a timeout when the SYN is silently dropped, or a connect error
# when the route is unreachable. Either way it returns fast.
void test_https_connect_timeout():
	http_req* req = http_req_new(c"GET", c"https://192.0.2.1:443/x")
	req.tls_insecure_skip_verify = 1
	req.timeout_ms = 500
	int started = time_monotonic_ms()
	http_response* resp = http_request(req)
	int elapsed = time_monotonic_ms() - started
	assert_equal(0, resp.status)
	int bounded_error = 0
	if (resp.error == http_error_timeout()):
		bounded_error = 1
	if (resp.error == http_error_connect()):
		bounded_error = 1
	asserts(c"connect fails bounded", bounded_error != 0)
	asserts(c"connect timeout too long", elapsed < 5000)
	http_response_free(resp)
	http_req_free(req)


# The TLS handshake times out when the server accepts the TCP connection but
# never answers the ClientHello. tls_handshake_timeout_ms drives it directly
# (no response to wait for, so no slow crypto is involved).
void test_https_handshake_timeout():
	int port = 0
	int listener = hs_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		socket_set_recv_timeout(conn, 8000)
		# Read the ClientHello but never handshake; stall until the client
		# gives up and closes.
		hs_drain_raw(conn)
		close(conn)
		exit(0)

	char* target = hs_url(port, c"/hs")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 500
	int started = time_monotonic_ms()
	http_response* resp = http_request(req)
	int elapsed = time_monotonic_ms() - started
	assert_equal(http_error_tls(), resp.error)
	assert_equal(0, resp.status)
	asserts(c"handshake timeout too early", elapsed >= 300)
	asserts(c"handshake timeout too long", elapsed < 5000)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hs_finish(pid, listener)


# The header read times out when the server completes the handshake but
# never sends a response. A generous handshake budget lets the (slow,
# pure-W) handshake finish; timeout_ms then bounds the header read.
void test_https_header_timeout():
	int port = 0
	int listener = hs_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		tls_conn* tc = hs_child_accept(listener)
		hs_child_read_request(tc)
		# Never respond; wait for the client to time out and close.
		hs_child_wait_close(tc)
		exit(0)

	char* target = hs_url(port, c"/slow")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 20000
	req.timeout_ms = 500
	http_response* resp = http_request(req)
	assert_equal(http_error_timeout(), resp.error)
	assert_equal(0, resp.status)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hs_finish(pid, listener)


# The idle-stream read times out mid-stream: the server sends one event then
# stalls, and the next sse_next surfaces the timeout without hanging.
void test_https_idle_stream_timeout():
	int port = 0
	int listener = hs_listen(&port)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		tls_conn* tc = hs_child_accept(listener)
		hs_child_read_request(tc)
		char* head = c"HTTP/1.1 200 OK\x0d\x0aContent-Type: text/event-stream\x0d\x0aConnection: close\x0d\x0a\x0d\x0a"
		tls_write(tc, head, strlen(head))
		char* first = c"data: first\n\n"
		tls_write(tc, first, strlen(first))
		# Stall: never send more; wait for the client to give up and close.
		hs_child_wait_close(tc)
		exit(0)

	char* target = hs_url(port, c"/drip")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 20000
	req.timeout_ms = 500
	http_stream* st = http_open(req)
	http_response* head = http_stream_headers(st)
	assert_equal(0, head.error)
	assert_equal(200, head.status)
	sse_reader* r = sse_open(st)

	sse_event* ev1 = sse_next(r)
	asserts(c"first drip event present", ev1 != 0)
	assert_strings_equal(c"first", ev1.data)
	sse_event_free(ev1)

	sse_event* ev2 = sse_next(r)
	asserts(c"stalled stream yields no event", ev2 == 0)
	assert_equal(sse_error_stream(), sse_reader_error(r))
	assert_equal(http_error_timeout(), head.error)

	sse_reader_free(r)
	http_stream_close(st)
	http_req_free(req)
	free(target)
	hs_finish(pid, listener)
