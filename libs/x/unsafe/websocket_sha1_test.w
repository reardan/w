# wbuild: x64
/*
WebSocket opening handshakes (libs/standard/web/websocket.w, RFC 6455,
issue #436) with the application-supplied SHA-1 this quarantine
namespace provides. websocket.w lives under libs/standard and so may not
import libs/x/unsafe (unsafe_import_test); it reaches SHA-1 through the
whash registry after the application opts in with
ws_use_sha1(WHASH_SHA1()) -- the same seam sha1_test.w proves for legacy
HMAC-SHA1. Everything that needs no SHA-1 (frame codec, framing
sessions, violations, upgrade-request validation) is covered by
libs/standard/web/websocket_test.w; this file covers the RFC 6455
section 1.3 accept-key example, full ws:// and wss:// loopback
handshakes against an http_server.w route (echo sessions, subprotocol
negotiation, close handshakes), and the client's validation of bad 101
responses scripted by a forked raw fixture server. All offline.
*/
import lib.testing
import lib.net
import structures.string
import libs.standard.crypto.base64
import libs.standard.web.connection
import libs.standard.web.http_client
import libs.standard.web.http_server
import libs.standard.web.websocket
import libs.x.unsafe.sha1


void wsh_opt_in():
	assert_equal(1, ws_use_sha1(WHASH_SHA1()))


char* wsh_url(char* scheme, int port, char* path):
	string_builder* out = string_new()
	string_append(out, scheme)
	string_append(out, c"://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


void wsh_wait_ok(int pid):
	int status = 0
	wait4(pid, &status, 0, 0)
	asserts(c"server child exited cleanly", status == 0)


void wsh_send_all(int fd, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(fd, data + total, n - total, msg_nosignal())
		if (got <= 0):
			return
		total = total + got


/* ---- accept key ---- */

void test_ws_rfc_1_3_accept_key():
	wsh_opt_in()
	# RFC 6455 section 1.3.
	char* accept = ws_accept_key(c"dGhlIHNhbXBsZSBub25jZQ==")
	assert_strings_equal(c"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept)
	free(accept)
	# A second vector, cross-checked with Python (hashlib + base64).
	accept = ws_accept_key(c"x3JJHMbDL1EzLkh9GBhXDw==")
	assert_strings_equal(c"HSmrc0sMlYUkAGmm5OPpG2HaGWk=", accept)
	free(accept)
	# Fresh keys: 24 base64 chars of 16 random bytes, never repeated.
	char* k1 = ws_new_key()
	char* k2 = ws_new_key()
	assert_equal(24, strlen(k1))
	int n = 0
	char* raw = base64_decode(k1, 24, &n)
	assert_equal(16, n)
	free(raw)
	asserts(c"keys differ", strcmp(k1, k2) != 0)
	free(k1)
	free(k2)


/* ---- loopback handshakes against http_server.w ---- */

ServerResponse* wsh_unused_handler(ServerRequest* req, void* context):
	return server_response_new(500)


# Echo route: picks the "chat" subprotocol when offered, echoes every
# message, and ends when the client closes.
void wsh_echo_route(RequestContext* rc, void* user_data):
	char* proto = 0
	if (ws_request_offers_protocol(rc.request, c"chat") != 0):
		proto = c"chat"
	ws_conn* c = ws_accept(rc, proto)
	if (ws_conn_error(c) == ws_error_none()):
		ws_message* m = ws_recv(c)
		while (m != 0):
			if (m.opcode == ws_op_text()):
				ws_send_text(c, m.data, m.len)
			else:
				ws_send_binary(c, m.data, m.len)
			ws_message_free(m)
			m = ws_recv(c)
	ws_conn_free(c)


# Binds an echo server (plain or TLS) and forks its accept loop for
# `connections` connections. Returns the port; *out_pid the child.
int wsh_start_server(int tls, int connections, int* out_pid):
	wsh_opt_in()
	ServerContext* s = server_context_new(c"127.0.0.1", 0, wsh_unused_handler, 0)
	s.timeout_ms = 60000
	if (tls != 0):
		server_context_set_tls(s, c"libs/standard/net/tls_fixtures/server_p256_cert.pem", c"libs/standard/net/tls_fixtures/server_p256_key.pem")
	asserts(c"bind", server_context_bind(s) != 0)
	server_route(s, c"GET", c"/echo", wsh_echo_route, 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, connections)
		exit(0)
	server_context_close(s)
	*out_pid = pid
	return port


void wsh_expect_echo(ws_conn* c, int opcode, char* data, int len):
	if (opcode == ws_op_text()):
		assert_equal(1, ws_send_text(c, data, len))
	else:
		assert_equal(1, ws_send_binary(c, data, len))
	ws_message* m = ws_recv(c)
	if (m == 0):
		print_string(c"ws_recv failed: ", ws_error_string(ws_conn_error(c)))
		asserts(c"echo arrived", 0)
	assert_equal(opcode, m.opcode)
	assert_equal(len, m.len)
	int i = 0
	while (i < len):
		if ((m.data[i] & 255) != (data[i] & 255)):
			assert_equal(data[i] & 255, m.data[i] & 255)
		i = i + 1
	ws_message_free(m)


void test_ws_loopback_handshake_and_echo():
	int pid = 0
	int port = wsh_start_server(0, 2, &pid)
	char* url = wsh_url(c"ws", port, c"/echo")

	ws_conn* c = ws_connect(url)
	if (ws_conn_error(c) != 0):
		print_string(c"ws_connect: ", ws_error_string(ws_conn_error(c)))
	assert_equal(ws_error_none(), ws_conn_error(c))
	assert_equal(101, c.http_status)
	asserts(c"no subprotocol unless offered", c.subprotocol == 0)
	wsh_expect_echo(c, ws_op_text(), c"hello over ws://", 16)
	char* big = malloc(70000)
	int i = 0
	while (i < 70000):
		big[i] = (i * 13) & 255
		i = i + 1
	wsh_expect_echo(c, ws_op_binary(), big, 70000)
	free(big)
	assert_equal(1, ws_close(c, 1000, c"done"))
	assert_equal(1000, c.peer_close_code)
	ws_conn_free(c)

	# Subprotocol negotiation through ws_open's extra headers.
	http_req* req = http_req_new(c"GET", url)
	http_req_add_header(req, c"Sec-WebSocket-Protocol", c"superchat, chat")
	http_req_add_header(req, c"Origin", c"http://127.0.0.1")
	c = ws_open(req)
	assert_equal(ws_error_none(), ws_conn_error(c))
	assert_strings_equal(c"chat", c.subprotocol)
	wsh_expect_echo(c, ws_op_text(), c"chat", 4)
	assert_equal(1, ws_close(c, 1001, 0))
	ws_conn_free(c)
	http_req_free(req)

	# Handshake headers the client owns cannot be overridden.
	req = http_req_new(c"GET", url)
	http_req_add_header(req, c"Sec-WebSocket-Key", c"AAAAAAAAAAAAAAAAAAAAAA==")
	c = ws_open(req)
	assert_equal(ws_error_bad_request(), ws_conn_error(c))
	ws_conn_free(c)
	http_req_free(req)
	req = http_req_new(c"GET", url)
	http_req_add_header(req, c"X-Evil", c"a\x0d\x0aB: c")
	c = ws_open(req)
	assert_equal(ws_error_bad_request(), ws_conn_error(c))
	ws_conn_free(c)
	http_req_free(req)

	free(url)
	wsh_wait_ok(pid)


void test_wss_loopback_handshake_and_echo():
	int pid = 0
	int port = wsh_start_server(1, 1, &pid)
	char* url = wsh_url(c"wss", port, c"/echo")
	http_req* req = http_req_new(c"GET", url)
	# Loopback fixture cert: skip chain/hostname checks (never the
	# handshake signature or Finished MAC); the pure-W server's ECDSA
	# needs handshake headroom under parallel suite load.
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 60000
	req.timeout_ms = 60000
	ws_conn* c = ws_open(req)
	if (ws_conn_error(c) != 0):
		print_string(c"ws_open wss: ", ws_error_string(ws_conn_error(c)))
	assert_equal(ws_error_none(), ws_conn_error(c))
	wsh_expect_echo(c, ws_op_text(), c"hello over wss://", 17)
	assert_equal(1, ws_close(c, 1000, 0))
	ws_conn_free(c)
	http_req_free(req)
	free(url)
	wsh_wait_ok(pid)


/* ---- client validation of bad 101 responses ---- */

# Reads a request head; returns its Sec-WebSocket-Key (malloc'd) or 0.
char* wsh_read_key(int conn):
	string_builder* head = string_new()
	char* one = malloc(1)
	while ((head.length < 4) || (strcmp(head.data + head.length - 4, c"\x0d\x0a\x0d\x0a") != 0)):
		if (read(conn, one, 1) != 1):
			return 0
		string_append_char(head, one[0])
	free(one)
	char* needle = c"Sec-WebSocket-Key: "
	int i = 0
	while (head.data[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (head.data[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			int start = i + j
			int end = start
			while ((head.data[end] != 13) && (head.data[end] != 0)):
				end = end + 1
			char* key = substring(head.data, start, end)
			string_free(head)
			return key
		i = i + 1
	string_free(head)
	return 0


void wsh_drain(int conn):
	char* scratch = malloc(1024)
	int got = read(conn, scratch, 1024)
	while (got > 0):
		got = read(conn, scratch, 1024)
	free(scratch)


# Scenario ids for the raw fixture server.
int wsh_ok_with_early_frames():
	return 0


int wsh_wrong_accept():
	return 1


int wsh_status_200():
	return 2


int wsh_no_upgrade():
	return 3


int wsh_connection_no_upgrade():
	return 4


int wsh_unrequested_protocol():
	return 5


int wsh_extension():
	return 6


int wsh_scenarios():
	return 7


# Raw fixture child: one connection per scenario, in order.
void wsh_raw_server(int listener):
	int scenario = 0
	while (scenario < wsh_scenarios()):
		int conn = socket_accept_connection(listener)
		if (conn < 0):
			exit(1)
		char* key = wsh_read_key(conn)
		if (key == 0):
			exit(2)
		char* accept = ws_accept_key(key)
		string_builder* out = string_new()
		if (scenario == wsh_status_200()):
			string_append(out, c"HTTP/1.1 200 OK\x0d\x0a")
		else:
			string_append(out, c"HTTP/1.1 101 Switching Protocols\x0d\x0a")
		if (scenario != wsh_no_upgrade()):
			string_append(out, c"Upgrade: WebSocket\x0d\x0a")
		if (scenario == wsh_connection_no_upgrade()):
			string_append(out, c"Connection: keep-alive\x0d\x0a")
		else:
			string_append(out, c"Connection: Upgrade\x0d\x0a")
		string_append(out, c"Sec-WebSocket-Accept: ")
		if (scenario == wsh_wrong_accept()):
			string_append(out, c"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
		else:
			string_append(out, accept)
		string_append(out, c"\x0d\x0a")
		if (scenario == wsh_unrequested_protocol()):
			string_append(out, c"Sec-WebSocket-Protocol: chat\x0d\x0a")
		if (scenario == wsh_extension()):
			string_append(out, c"Sec-WebSocket-Extensions: permessage-deflate\x0d\x0a")
		string_append(out, c"\x0d\x0a")
		if (scenario == wsh_ok_with_early_frames()):
			# Frames in the same write as the 101 head: they sit in the
			# handshake's read buffer and must survive the handover.
			string_append(out, c"\x81\x05early\x88\x02\x03\xe8")
		wsh_send_all(conn, out.data, out.length)
		string_free(out)
		free(accept)
		free(key)
		wsh_drain(conn)
		close(conn)
		scenario = scenario + 1
	exit(0)


void wsh_expect_handshake_failure(char* url, int status):
	ws_conn* c = ws_connect(url)
	assert_equal(ws_error_handshake(), ws_conn_error(c))
	assert_equal(status, c.http_status)
	ws_conn_free(c)


void test_ws_client_validates_handshake_response():
	wsh_opt_in()
	int listener = socket_tcp_ipv4()
	asserts(c"socket", listener >= 0)
	socket_set_reuseaddr(listener)
	asserts(c"bind", socket_bind_ipv4(listener, ip4_from_string(c"127.0.0.1"), 0) >= 0)
	asserts(c"listen", socket_listen(listener, 8) >= 0)
	sockaddr_in bound
	socket_getsockname_ipv4(listener, &bound)
	int port = net_htons(bound.port)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		wsh_raw_server(listener)
	char* url = wsh_url(c"ws", port, c"/")

	ws_conn* c = ws_connect(url)
	assert_equal(ws_error_none(), ws_conn_error(c))
	ws_message* m = ws_recv(c)
	asserts(c"early frame delivered", m != 0)
	assert_strings_equal(c"early", m.data)
	ws_message_free(m)
	asserts(c"early close", ws_recv(c) == 0)
	assert_equal(ws_error_closed(), ws_conn_error(c))
	assert_equal(1000, c.peer_close_code)
	ws_conn_free(c)

	wsh_expect_handshake_failure(url, 101)
	wsh_expect_handshake_failure(url, 200)
	wsh_expect_handshake_failure(url, 101)
	wsh_expect_handshake_failure(url, 101)
	wsh_expect_handshake_failure(url, 101)
	wsh_expect_handshake_failure(url, 101)
	free(url)
	close(listener)
	wsh_wait_ok(pid)
