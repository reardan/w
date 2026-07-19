# wbuild: x64
# Loopback tests for libs/standard/web/http_server.w's base HTTP/1.1
# server and libs/standard/web/connection.w's ConnectionContext (issue
# #235, phases 1-2). Each test forks: the parent binds a ServerContext
# on 127.0.0.1:0 (a kernel-assigned ephemeral port) so it knows the
# port before forking, the child runs the accept loop with a small
# handler, and the parent drives it with libs/standard/web/http_client.w's
# real client -- the same fork()-based fixture-server pattern
# libs/standard/web/http_client_test.w and https_e2e_test.w use, except
# here the "fixture" IS the module under test. One test (chunked request
# body) drives a raw socket instead, since http_client.w has no
# chunked-request-body encoder to test against.
import lib.testing
import lib.net
import structures.string
import libs.standard.web.connection
import libs.standard.web.http_server
import libs.standard.web.http_client
import libs.standard.net.tls


/* ---- shared helpers ---- */

char* hst_url(int port, char* path):
	string_builder* out = string_new()
	string_append(out, c"http://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


char* hst_https_url(int port, char* path):
	string_builder* out = string_new()
	string_append(out, c"https://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


int hst_contains(char* hay, char* needle):
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


# Binds on 127.0.0.1 with a kernel-assigned port; the caller forks
# afterwards so the child inherits the already-bound listener.
ServerContext* hst_new_server(server_handler_fn* handler):
	ServerContext* s = server_context_new(c"127.0.0.1", 0, handler, 0)
	s.timeout_ms = 5000
	asserts(c"server bind", server_context_bind(s) != 0)
	return s


# Drops the client's cached keep-alive connection (so it never leaks
# into the next test), reaps the child, and asserts it exited cleanly.
void hst_finish(int pid):
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	asserts(c"server child exited cleanly", status == 0)


/* ---- handlers (plain functions -- W has no closures) ---- */

ServerResponse* hst_handler_hello(ServerRequest* req, void* context):
	ServerResponse* resp = server_response_new(200)
	server_response_add_header(resp, c"X-W-Test", c"yes")
	server_response_set_text(resp, c"hello")
	return resp


# Echoes the request body back verbatim, whatever framing delivered it
# (Content-Length or chunked) -- proves server_read_request normalizes
# both into the same req.body/req.body_len.
ServerResponse* hst_handler_echo_body(ServerRequest* req, void* context):
	ServerResponse* resp = server_response_new(200)
	server_response_add_header(resp, c"X-Method", req.method)
	server_response_set_body(resp, req.body, req.body_len)
	return resp


int hst_keep_alive_counter


ServerResponse* hst_handler_counter(ServerRequest* req, void* context):
	hst_keep_alive_counter = hst_keep_alive_counter + 1
	ServerResponse* resp = server_response_new(200)
	server_response_set_text(resp, itoa(hst_keep_alive_counter))
	return resp


/* ---- tests ---- */

# A plain GET: status, a response header, and the body all survive the
# round trip through ServerContext's accept loop, server_read_request,
# and server_write_response.
void test_http_get_round_trip():
	ServerContext* s = hst_new_server(hst_handler_hello)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hst_url(port, c"/hi")
	http_req* req = http_req_new(c"GET", target)
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello", resp.body)
	assert_strings_equal(c"yes", http_response_header(resp, c"x-w-test"))
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hst_finish(pid)


# POST with a Content-Length-delimited body: the server parses and
# hands the exact bytes to the handler, which echoes them back.
void test_http_post_with_body():
	ServerContext* s = hst_new_server(hst_handler_echo_body)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hst_url(port, c"/echo")
	http_req* req = http_req_new(c"POST", target)
	http_req_add_header(req, c"Connection", c"close")
	char* body = c"the quick brown fox jumps over the lazy dog"
	req.body = body
	req.body_len = strlen(body)
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(body, resp.body)
	assert_strings_equal(c"POST", http_response_header(resp, c"x-method"))
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hst_finish(pid)


# A chunked request body: http_client.w has no chunked-request encoder,
# so this drives a raw socket with a hand-written chunked POST and
# checks the (still Content-Length-framed, since the server always
# responds with a fully buffered body) response for the reassembled
# bytes -- proving server_read_chunked_body dechunks correctly.
void test_http_chunked_request_body():
	ServerContext* s = hst_new_server(hst_handler_echo_body)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	int fd = socket_tcp_ipv4()
	asserts(c"raw socket", fd >= 0)
	asserts(c"raw connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) == 0)
	socket_set_recv_timeout(fd, 5000)
	socket_set_send_timeout(fd, 5000)
	string_builder* req_text = string_new()
	string_append(req_text, c"POST /echo HTTP/1.1\x0d\x0a")
	string_append(req_text, c"Host: 127.0.0.1\x0d\x0a")
	string_append(req_text, c"Transfer-Encoding: chunked\x0d\x0a")
	string_append(req_text, c"Connection: close\x0d\x0a")
	string_append(req_text, c"\x0d\x0a")
	string_append(req_text, c"5\x0d\x0aHello\x0d\x0a")
	string_append(req_text, c"6\x0d\x0a World\x0d\x0a")
	string_append(req_text, c"0\x0d\x0a\x0d\x0a")
	int wrote = socket_send(fd, req_text.data, req_text.length, msg_nosignal())
	asserts(c"raw send", wrote == req_text.length)
	string_free(req_text)

	string_builder* resp_text = string_new()
	char* buf = malloc(4096)
	int done = 0
	while (done == 0):
		int got = read(fd, buf, 4096)
		if (got <= 0):
			done = 1
		else:
			string_append_bytes(resp_text, buf, got)
	free(buf)
	close(fd)

	asserts(c"chunked response status", hst_contains(resp_text.data, c"HTTP/1.1 200") != 0)
	asserts(c"chunked body reassembled", hst_contains(resp_text.data, c"Hello World") != 0)
	string_free(resp_text)
	hst_finish(pid)


# Two GETs over one accepted connection: the client's default
# keep-alive headers let http_client.w reuse the idle connection, and
# the server's per-connection handler-call counter proves both
# requests were served by the same ConnectionContext loop (accept_loop
# is bounded to exactly one accepted connection, so a second physical
# connection was never available).
void test_http_keep_alive_two_requests():
	ServerContext* s = hst_new_server(hst_handler_counter)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hst_url(port, c"/count")
	http_req* req1 = http_req_new(c"GET", target)
	http_response* r1 = http_request(req1)
	assert_equal(0, r1.error)
	assert_equal(200, r1.status)
	assert_strings_equal(c"1", r1.body)
	http_response_free(r1)
	http_req_free(req1)

	http_req* req2 = http_req_new(c"GET", target)
	http_req_add_header(req2, c"Connection", c"close")
	http_response* r2 = http_request(req2)
	assert_equal(0, r2.error)
	assert_equal(200, r2.status)
	assert_strings_equal(c"2", r2.body)
	http_response_free(r2)
	http_req_free(req2)
	free(target)
	hst_finish(pid)


# https:// through the same ServerContext, TLS enabled via
# server_context_set_tls composing tls_accept -- one code path serves
# both http and https. Reuses the https_e2e_test.w synthetic ECDSA
# P-256 fixture (SAN test.w.example, which cannot match 127.0.0.1, so
# the client connects with tls_insecure_skip_verify).
void test_https_get_round_trip():
	ServerContext* s = server_context_new(c"127.0.0.1", 0, hst_handler_hello, 0)
	s.timeout_ms = 5000
	server_context_set_tls(s, c"libs/standard/net/tls_fixtures/server_p256_cert.pem", c"libs/standard/net/tls_fixtures/server_p256_key.pem")
	asserts(c"https server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hst_https_url(port, c"/hi")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 60000
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hst_finish(pid)
