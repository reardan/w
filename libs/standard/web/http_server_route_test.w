# wbuild: x64
# Loopback tests for libs/standard/web/http_server.w's phase 3-5 layer
# (issue #235): RequestContext (parsed-request access, the buffered
# set_status/set_header/write_body writer, and the opt-in streaming
# mode), server_route's method/path dispatch and 404 fallback, the
# framework composing https:// (server_context_set_tls + tls_accept)
# through the RequestContext path, and a hand-formatted SSE stream
# decoded by libs/standard/web/sse.w's real reader (sse.w is a client-
# only module -- see test_sse_streaming_handler's comment). Same
# fork()-based fixture-server pattern as http_server_test.w, which
# covers the phase 1-2 server_handler_fn path and stays untouched: a
# ServerContext that never calls server_route keeps using that path
# byte-for-byte (see http_server.w's module doc), so this file only
# needs to prove the new opt-in path.
import lib.testing
import lib.net
import structures.string
import libs.standard.web.connection
import libs.standard.web.urlparse
import libs.standard.web.http_server
import libs.standard.web.http_client
import libs.standard.web.sse
import libs.standard.net.tls


/* ---- shared helpers ---- */

char* hrt_url(int port, char* path):
	string_builder* out = string_new()
	string_append(out, c"http://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


char* hrt_https_url(int port, char* path):
	string_builder* out = string_new()
	string_append(out, c"https://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


# A handler function pointer is required even for a ServerContext that
# only ever dispatches through server_route (server_serve_connection
# never calls it once s.routes is non-empty) -- this fills that unused
# slot rather than relying on any null-function-pointer behavior.
ServerResponse* hrt_unused_handler(ServerRequest* req, void* context):
	return server_response_new(500)


ServerContext* hrt_new_server():
	ServerContext* s = server_context_new(c"127.0.0.1", 0, hrt_unused_handler, 0)
	s.timeout_ms = 5000
	asserts(c"server bind", server_context_bind(s) != 0)
	return s


void hrt_finish(int pid):
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	asserts(c"server child exited cleanly", status == 0)


/* ---- route handlers (plain functions -- W has no closures) ---- */

void hrt_handler_hello(RequestContext* rc, void* user_data):
	request_context_set_header(rc, c"X-W-Test", c"yes")
	request_context_text(rc, 200, c"hello")


# Exercises the full accessor surface: method, path, a request header,
# and the buffered body.
void hrt_handler_echo(RequestContext* rc, void* user_data):
	string_builder* out = string_new()
	string_append(out, request_context_method(rc))
	string_append_char(out, ' ')
	string_append(out, request_context_path(rc))
	string_append_char(out, ' ')
	char* ua = request_context_header(rc, c"x-echo")
	if (ua != 0):
		string_append(out, ua)
	string_append_char(out, ' ')
	string_append_bytes(out, request_context_body(rc), request_context_body_len(rc))
	request_context_set_status(rc, 200)
	request_context_write_body(rc, out.data, out.length)
	string_free(out)


# Proves request_context_url reconstructs a real URL (path/query) and
# request_query_param percent-decodes a lookup on it.
void hrt_handler_search(RequestContext* rc, void* user_data):
	URL* u = request_context_url(rc)
	asserts(c"parsed URL present", u != 0)
	assert_strings_equal(c"/search", u.path)
	char* q = request_query_param(rc, c"q")
	char* missing = request_query_param(rc, c"missing")
	asserts(c"missing query param is 0", missing == 0)
	if (q == 0):
		request_context_text(rc, 200, c"<absent>")
	else:
		request_context_text(rc, 200, q)
		free(q)


void hrt_handler_json(RequestContext* rc, void* user_data):
	request_context_json(rc, 201, c"{\"ok\":true}")


void hrt_handler_exact(RequestContext* rc, void* user_data):
	request_context_text(rc, 200, c"exact")


void hrt_handler_prefix(RequestContext* rc, void* user_data):
	string_builder* out = string_new()
	string_append(out, c"prefix:")
	string_append(out, request_context_path(rc))
	request_context_text(rc, 200, out.data)
	string_free(out)


void hrt_handler_get_only(RequestContext* rc, void* user_data):
	request_context_text(rc, 200, c"get-only")


void hrt_handler_any_method(RequestContext* rc, void* user_data):
	string_builder* out = string_new()
	string_append(out, c"any:")
	string_append(out, request_context_method(rc))
	request_context_text(rc, 200, out.data)
	string_free(out)


# Streaming handler: begins the stream explicitly (no Content-Length
# set, so the framework picks chunked), writes the body across three
# write_body calls, proving they arrive concatenated on the client
# side via http_client.w's chunked decoder.
void hrt_handler_stream(RequestContext* rc, void* user_data):
	request_context_set_header(rc, c"Content-Type", c"text/plain")
	request_context_begin_stream(rc)
	request_context_write_body(rc, c"Hello, ", 7)
	request_context_write_body(rc, c"streaming ", 10)
	request_context_write_body(rc, c"world!", 6)


# A streaming handler that begins a stream but never writes any body
# bytes: request_context_end_stream (called automatically by
# request_context_flush) must still emit valid chunked framing (just
# the terminal 0-size chunk) rather than hanging the client.
void hrt_handler_stream_empty(RequestContext* rc, void* user_data):
	request_context_set_header(rc, c"Content-Type", c"text/plain")
	request_context_begin_stream(rc)


# SSE (libs/standard/web/sse.w) is a client-only reader -- it consumes
# an http_stream and has no server/writer half to compose here (see
# the module's Public API list and the issue #235 phase 5 note). This
# hand-formats "event: NAME\ndata: VALUE\n\n" records directly over the
# streaming RequestContext (Content-Type: text/event-stream, chunked
# framing), which is exactly the byte format sse.w's real reader
# (sse_open/sse_next) expects, so the test below drives this handler
# with the real client-side parser.
void hrt_handler_sse(RequestContext* rc, void* user_data):
	request_context_set_header(rc, c"Content-Type", c"text/event-stream")
	request_context_begin_stream(rc)
	char* e1 = c"data: one\n\n"
	request_context_write_body(rc, e1, strlen(e1))
	char* e2 = c"event: tick\ndata: two\n\n"
	request_context_write_body(rc, e2, strlen(e2))


/* ---- tests: RequestContext accessors + buffered writer ---- */

void test_request_context_basic_round_trip():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/hi", hrt_handler_hello, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/hi")
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
	hrt_finish(pid)


void test_request_context_method_path_header_body():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"POST", c"/echo", hrt_handler_echo, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/echo")
	http_req* req = http_req_new(c"POST", target)
	http_req_add_header(req, c"Connection", c"close")
	http_req_add_header(req, c"X-Echo", c"marker")
	char* body = c"payload"
	req.body = body
	req.body_len = strlen(body)
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"POST /echo marker payload", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hrt_finish(pid)


void test_request_context_url_and_query_param():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/search", hrt_handler_search, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/search?q=hello%20world&x=1")
	http_req* req = http_req_new(c"GET", target)
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello world", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hrt_finish(pid)


void test_request_context_json_shortcut():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/api", hrt_handler_json, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/api")
	http_req* req = http_req_new(c"GET", target)
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(201, resp.status)
	assert_strings_equal(c"application/json", http_response_header(resp, c"content-type"))
	assert_strings_equal(c"{\"ok\":true}", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hrt_finish(pid)


/* ---- tests: routing dispatch + 404 ---- */

void test_routing_exact_prefix_and_404():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/exact", hrt_handler_exact, 0)
	server_route(s, c"GET", c"/prefix/*", hrt_handler_prefix, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		# Only req4 sets "Connection: close", so r1-r4 all share one
		# keep-alive connection (the client's idle cache reuses it) --
		# exactly one accepted connection total.
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	# Exact match.
	char* t1 = hrt_url(port, c"/exact")
	http_req* r1 = http_req_new(c"GET", t1)
	http_response* resp1 = http_request(r1)
	assert_equal(200, resp1.status)
	assert_strings_equal(c"exact", resp1.body)
	http_response_free(resp1)
	http_req_free(r1)
	free(t1)

	# Prefix match: "/prefix/*" matches anything under "/prefix/".
	char* t2 = hrt_url(port, c"/prefix/anything/deeper")
	http_req* r2 = http_req_new(c"GET", t2)
	http_response* resp2 = http_request(r2)
	assert_equal(200, resp2.status)
	assert_strings_equal(c"prefix:/prefix/anything/deeper", resp2.body)
	http_response_free(resp2)
	http_req_free(r2)
	free(t2)

	# "/prefixX" does not start with "/prefix/" -- no route matches.
	char* t3 = hrt_url(port, c"/prefixX")
	http_req* r3 = http_req_new(c"GET", t3)
	http_response* resp3 = http_request(r3)
	assert_equal(404, resp3.status)
	assert_strings_equal(c"Not Found", resp3.body)
	http_response_free(resp3)
	http_req_free(r3)
	free(t3)

	# An entirely unregistered path also 404s.
	char* t4 = hrt_url(port, c"/nope")
	http_req* req4 = http_req_new(c"GET", t4)
	http_req_add_header(req4, c"Connection", c"close")
	http_response* resp4 = http_request(req4)
	assert_equal(404, resp4.status)
	http_response_free(resp4)
	http_req_free(req4)
	free(t4)

	hrt_finish(pid)


void test_routing_method_exact_and_wildcard():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/only-get", hrt_handler_get_only, 0)
	server_route(s, c"*", c"/any", hrt_handler_any_method, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		# r1 (no close) + r2 (close) share one connection; r2's close
		# means r3 (close) needs a fresh one -- two accepted connections.
		server_context_accept_loop(s, 2)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	# GET matches the exact-method route.
	char* t1 = hrt_url(port, c"/only-get")
	http_req* r1 = http_req_new(c"GET", t1)
	http_response* resp1 = http_request(r1)
	assert_equal(200, resp1.status)
	assert_strings_equal(c"get-only", resp1.body)
	http_response_free(resp1)
	http_req_free(r1)
	free(t1)

	# POST to a GET-only route matches nothing -- 404.
	char* t2 = hrt_url(port, c"/only-get")
	http_req* r2 = http_req_new(c"POST", t2)
	http_req_add_header(r2, c"Connection", c"close")
	http_response* resp2 = http_request(r2)
	assert_equal(404, resp2.status)
	http_response_free(resp2)
	http_req_free(r2)
	free(t2)

	# "*" matches any method.
	char* t3 = hrt_url(port, c"/any")
	http_req* r3 = http_req_new(c"DELETE", t3)
	http_req_add_header(r3, c"Connection", c"close")
	http_response* resp3 = http_request(r3)
	assert_equal(200, resp3.status)
	assert_strings_equal(c"any:DELETE", resp3.body)
	http_response_free(resp3)
	http_req_free(r3)
	free(t3)

	hrt_finish(pid)


/* ---- tests: streaming ---- */

# The client's chunked decoder (http_client.w's http_stream_read_chunked,
# driven here through http_request's buffering loop) reassembles the
# three write_body calls into one body, and the response really was
# framed as chunked (no Content-Length from this handler).
void test_streaming_chunked_round_trip():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/stream", hrt_handler_stream, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/stream")
	http_req* req = http_req_new(c"GET", target)
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"chunked", http_response_header(resp, c"transfer-encoding"))
	assert_strings_equal(c"Hello, streaming world!", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hrt_finish(pid)


# A stream that begins but never writes a body byte still closes out
# with valid (empty) chunked framing instead of hanging the client.
void test_streaming_empty_body():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/empty-stream", hrt_handler_stream_empty, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/empty-stream")
	http_req* req = http_req_new(c"GET", target)
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_equal(0, resp.body_len)
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hrt_finish(pid)


# See hrt_handler_sse's comment: sse.w has no server/writer half, so
# this hand-formats the SSE wire bytes over a streaming RequestContext
# and decodes them with sse.w's real client-side reader (sse_open /
# sse_next) driven through http_client.w's streaming http_open, proving
# the streaming RequestContext plumbing end-to-end against the real
# client library.
void test_sse_streaming_handler():
	ServerContext* s = hrt_new_server()
	int port = server_context_port(s)
	server_route(s, c"GET", c"/events", hrt_handler_sse, 0)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_url(port, c"/events")
	http_req* req = http_req_new(c"GET", target)
	http_stream* st = http_open(req)
	http_response* head = http_stream_headers(st)
	assert_equal(0, head.error)
	assert_equal(200, head.status)
	assert_strings_equal(c"text/event-stream", http_response_header(head, c"content-type"))
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
	asserts(c"sse stream ends", ev3 == 0)
	assert_equal(sse_error_none(), sse_reader_error(r))

	sse_reader_free(r)
	http_stream_close(st)
	http_req_free(req)
	free(target)
	hrt_finish(pid)


/* ---- tests: https through the RequestContext/routing path ---- */

# The same routing + buffered-writer path, this time terminating TLS
# via server_context_set_tls -- one accept loop, one dispatch path
# serves both transports (mirrors http_server_test.w's
# test_https_get_round_trip, reusing the same synthetic P-256 fixture).
void test_https_request_context_round_trip():
	ServerContext* s = server_context_new(c"127.0.0.1", 0, hrt_unused_handler, 0)
	s.timeout_ms = 5000
	server_context_set_tls(s, c"libs/standard/net/tls_fixtures/server_p256_cert.pem", c"libs/standard/net/tls_fixtures/server_p256_key.pem")
	asserts(c"https server bind", server_context_bind(s) != 0)
	server_route(s, c"GET", c"/hi", hrt_handler_hello, 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)

	char* target = hrt_https_url(port, c"/hi")
	http_req* req = http_req_new(c"GET", target)
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 60000
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_strings_equal(c"hello", resp.body)
	assert_strings_equal(c"yes", http_response_header(resp, c"x-w-test"))
	http_response_free(resp)
	http_req_free(req)
	free(target)
	hrt_finish(pid)
