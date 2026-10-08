# wbuild: x64
# Resource-limit tests for the HTTP server and client (issue #533):
# static-path containment (server_static_path), header-count and
# header-line caps (431), oversized Content-Length, a slow client that
# must not block a second one, the whole-request deadline, the
# open-connection cap, and the client's buffered-body and header-count
# caps. Socket tests use the fork()-based loopback pattern of
# http_server_test.w on 127.0.0.1 with short timeouts.
import lib.testing
import lib.net
import lib.io_wait
import lib.time
import structures.string
import libs.standard.web.http_server
import libs.standard.web.http_client
import libs.standard.web.testing


ServerContext* hlt_new_server(server_handler_fn* handler):
	ServerContext* s = server_context_new(c"127.0.0.1", 0, handler, 0)
	s.timeout_ms = 5000
	asserts(c"server bind", server_context_bind(s) != 0)
	return s


ServerResponse* hlt_handler_hello(ServerRequest* req, void* context):
	ServerResponse* resp = server_response_new(200)
	server_response_set_text(resp, c"hello")
	return resp


# Forks a child that serves `connections` connections on s, then exits.
int hlt_fork_server(ServerContext* s, int connections):
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, connections)
		exit(0)
	server_context_close(s)
	server_context_free(s)
	return pid


int hlt_connect(int port):
	int fd = socket_tcp_ipv4()
	asserts(c"socket", fd >= 0)
	socket_set_recv_timeout(fd, 10000)
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	return fd


/* ---- static paths ---- */

void hlt_expect_static(char* request_path, char* expected):
	char* got = server_static_path(c"/srv/static", request_path)
	if (expected == 0):
		if (got != 0):
			print2(c"unexpectedly served: ")
			println2(got)
		assert_equal(0, cast(int, got))
		return
	asserts(c"expected a static path", got != 0)
	assert_strings_equal(expected, got)
	free(got)


void test_static_path_stays_in_root():
	hlt_expect_static(c"/index.html", c"/srv/static/index.html")
	hlt_expect_static(c"/css/../index.html", c"/srv/static/index.html")
	hlt_expect_static(c"/a%20b.txt", c"/srv/static/a b.txt")
	hlt_expect_static(c"/", c"/srv/static")
	hlt_expect_static(c"/../../etc/passwd", 0)
	hlt_expect_static(c"/css/../../etc/passwd", 0)
	hlt_expect_static(c"/..", 0)
	# Percent-encoded traversal is decoded before the containment check.
	hlt_expect_static(c"/%2e%2e/%2e%2e/etc/passwd", 0)
	hlt_expect_static(c"/%2E%2E%2F%2E%2E%2Fetc%2Fpasswd", 0)
	hlt_expect_static(c"/css/%2e%2e/index.html", c"/srv/static/index.html")
	# A sibling directory sharing the root's prefix is still outside.
	hlt_expect_static(c"/../static2/x", 0)
	# Invalid escapes and an encoded NUL are refused outright.
	hlt_expect_static(c"/a%zz", 0)
	hlt_expect_static(c"/a%00.txt", 0)
	hlt_expect_static(c"/a%2", 0)


# A static handler rooted at libs/standard/web: answers with the
# resolved path, or 404 when server_static_path refuses it.
void hlt_static_handler(RequestContext* rc, void* user_data):
	char* full = server_static_path(c"libs/standard/web", request_context_path(rc))
	if (full == 0):
		request_context_text(rc, 404, c"not found")
		return
	request_context_text(rc, 200, full)
	free(full)


void test_static_traversal_over_the_wire():
	ServerContext* s = hlt_new_server(0)
	server_route(s, c"GET", c"/*", hlt_static_handler, 0)
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 4)

	char* text = net_test_exchange(port, c"GET /testing.w HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	asserts(c"in-root path served", net_test_contains(text, c" 200 "))
	asserts(c"resolved under root", net_test_contains(text, c"libs/standard/web/testing.w"))
	free(text)
	text = net_test_exchange(port, c"GET /../../../lib/path.w HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	asserts(c"dot-dot refused", net_test_contains(text, c" 404 "))
	free(text)
	text = net_test_exchange(port, c"GET /%2e%2e/%2e%2e/%2e%2e/lib/path.w HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	asserts(c"encoded dot-dot refused", net_test_contains(text, c" 404 "))
	free(text)
	text = net_test_exchange(port, c"GET /x/..%2f..%2f..%2f..%2flib/path.w HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	asserts(c"encoded slash refused", net_test_contains(text, c" 404 "))
	free(text)
	web_test_finish(pid, -1)


/* ---- request header caps ---- */

void test_header_count_flood_gets_431():
	ServerContext* s = hlt_new_server(hlt_handler_hello)
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 2)

	# http_max_header_count + 1 tiny headers (no terminator needed: the
	# server must give up at the cap).
	string_builder* req = string_new()
	string_append(req, c"GET / HTTP/1.1\r\nHost: x\r\n")
	for i in range(http_max_header_count):
		string_append(req, c"X-F: 1\r\n")
	char* text = net_test_exchange(port, req.data)
	asserts(c"header flood gets 431", net_test_contains(text, c" 431 "))
	free(text)
	string_free(req)

	# Exactly at the cap is still fine.
	req = string_new()
	string_append(req, c"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n")
	for j in range(http_max_header_count - 2):
		string_append(req, c"X-F: 1\r\n")
	string_append(req, c"\r\n")
	text = net_test_exchange(port, req.data)
	asserts(c"headers at the cap accepted", net_test_contains(text, c" 200 "))
	free(text)
	string_free(req)
	web_test_finish(pid, -1)


void test_header_line_too_long_gets_431():
	ServerContext* s = hlt_new_server(hlt_handler_hello)
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 1)

	string_builder* req = string_new()
	string_append(req, c"GET / HTTP/1.1\r\nHost: x\r\nX-Long: ")
	# One byte past the per-line cap, unterminated.
	int filler = connection_max_line_bytes + 1 - 8
	for i in range(filler): string_append_char(req, 'a')
	char* text = net_test_exchange(port, req.data)
	asserts(c"long header line gets 431", net_test_contains(text, c" 431 "))
	free(text)
	string_free(req)
	web_test_finish(pid, -1)


void test_oversized_content_length_rejected():
	ServerContext* s = hlt_new_server(hlt_handler_hello)
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 2)

	char* text = net_test_exchange(port, c"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999\r\n\r\n")
	asserts(c"overflowing Content-Length refused", net_test_contains(text, c" 400 "))
	free(text)
	text = net_test_exchange(port, c"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4294967301\r\n\r\nhello")
	asserts(c"wrapping Content-Length refused", net_test_contains(text, c" 400 "))
	free(text)
	web_test_finish(pid, -1)


/* ---- concurrency and deadlines ---- */

# A client that sends half a request and then goes quiet must not hold
# up a second client: the plain accept loop serves both concurrently.
void test_slow_client_does_not_block_another():
	ServerContext* s = hlt_new_server(hlt_handler_hello)
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 2)

	int slow = hlt_connect(port)
	net_test_send_text(slow, c"GET / HTTP/1.1\r\nHost: x\r\n")
	sleep_ms(50)

	int t0 = time_monotonic_ms()
	char* target = net_test_url(c"http", port, c"/")
	http_req* req = http_req_new(c"GET", target)
	req.timeout_ms = 3000
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	int elapsed = time_monotonic_ms() - t0
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello", resp.body)
	asserts(c"second client served while the first stalls", elapsed < 2000)
	http_response_free(resp)
	http_req_free(req)
	free(target)

	close(slow)
	web_test_finish(pid, -1)


# A client dribbling one header line every 100 ms stays inside the
# per-wait timeout forever; the whole-request deadline still ends it.
void test_request_deadline_ends_dribbling_client():
	ServerContext* s = hlt_new_server(hlt_handler_hello)
	s.request_timeout_ms = 300
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 1)

	int fd = hlt_connect(port)
	int t0 = time_monotonic_ms()
	net_test_send_text(fd, c"GET / HTTP/1.1\r\nHost: x\r\n")
	int answered = 0
	int rounds = 0
	while ((answered == 0) && (rounds < 50)):
		if (io_poll(fd, poll_in, 100) > 0): answered = 1
		else: net_test_send_text(fd, c"X-Drip: 1\r\n")
		rounds = rounds + 1
	asserts(c"server answered the dribbling client", answered)
	char* text = net_test_read_all(fd)
	asserts(c"dribbling client gets 408", net_test_contains(text, c" 408 "))
	asserts(c"deadline fired promptly", (time_monotonic_ms() - t0) < 3000)
	free(text)
	close(fd)
	web_test_finish(pid, -1)


# With max_open_connections = 1 a second client waits for the first
# connection's slot (here freed by the request deadline), then is served.
void test_open_connection_cap_queues_clients():
	ServerContext* s = hlt_new_server(hlt_handler_hello)
	s.max_open_connections = 1
	s.request_timeout_ms = 500
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 2)

	int slow = hlt_connect(port)
	net_test_send_text(slow, c"GET / HTTP/1.1\r\n")
	sleep_ms(50)

	int t0 = time_monotonic_ms()
	char* target = net_test_url(c"http", port, c"/")
	http_req* req = http_req_new(c"GET", target)
	req.timeout_ms = 5000
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	int elapsed = time_monotonic_ms() - t0
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	asserts(c"second client waited for the slot", elapsed >= 300)
	http_response_free(resp)
	http_req_free(req)
	free(target)

	char* text = net_test_read_all(slow)
	asserts(c"stalled client timed out with 408", net_test_contains(text, c" 408 "))
	free(text)
	close(slow)
	web_test_finish(pid, -1)


/* ---- client caps ---- */

void hlt_big_fixed(RequestContext* rc, void* user_data):
	char* body = cast(char*, malloc(1000))
	for i in range(1000): body[i] = 'b'
	request_context_set_status(rc, 200)
	request_context_write_body(rc, body, 1000)
	free(body)


void hlt_big_chunked(RequestContext* rc, void* user_data):
	char* body = cast(char*, malloc(400))
	for i in range(400): body[i] = 'c'
	request_context_set_status(rc, 200)
	request_context_begin_stream(rc)
	for j in range(3): request_context_write_body(rc, body, 400)
	request_context_end_stream(rc)
	free(body)


void hlt_many_headers(RequestContext* rc, void* user_data):
	for i in range(http_max_header_count + 1):
		request_context_set_header(rc, c"X-Many", c"1")
	request_context_text(rc, 200, c"ok")


http_response* hlt_get(int port, char* path, int max_body):
	char* target = net_test_url(c"http", port, path)
	http_req* req = http_req_new(c"GET", target)
	req.timeout_ms = 3000
	if (max_body > 0): req.max_body_bytes = max_body
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	http_req_free(req)
	free(target)
	return resp


void test_client_body_and_header_caps():
	assert_equal(http_default_max_response_bytes, http_req_new(c"GET", c"http://x/").max_body_bytes)
	ServerContext* s = hlt_new_server(0)
	server_route(s, c"GET", c"/fixed", hlt_big_fixed, 0)
	server_route(s, c"GET", c"/chunked", hlt_big_chunked, 0)
	server_route(s, c"GET", c"/many", hlt_many_headers, 0)
	int port = server_context_port(s)
	int pid = hlt_fork_server(s, 5)

	# Content-Length above the cap fails before the body is read.
	http_response* resp = hlt_get(port, c"/fixed", 100)
	assert_equal(http_error_body_too_large, resp.error)
	assert_strings_equal(c"response body too large", http_error_string(resp.error))
	http_response_free(resp)

	# The same body fits under the default cap.
	resp = hlt_get(port, c"/fixed", 0)
	assert_equal(0, resp.error)
	assert_equal(1000, resp.body_len)
	http_response_free(resp)

	# A chunked body is cut off once it outgrows the cap.
	resp = hlt_get(port, c"/chunked", 1000)
	assert_equal(http_error_body_too_large, resp.error)
	asserts(c"buffered no more than the cap", resp.body_len <= 1000)
	http_response_free(resp)

	resp = hlt_get(port, c"/chunked", 1200)
	assert_equal(0, resp.error)
	assert_equal(1200, resp.body_len)
	http_response_free(resp)

	# Too many response headers fail closed.
	resp = hlt_get(port, c"/many", 0)
	assert_equal(http_error_headers_too_large, resp.error)
	http_response_free(resp)
	web_test_finish(pid, -1)
