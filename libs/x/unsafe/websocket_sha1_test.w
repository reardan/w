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
responses scripted by a forked raw fixture server. permessage-deflate
(RFC 7692, opted into with ws_use_deflate over libs/extras/compress)
is negotiated end to end: compressed echo sessions against deflate
routes with plain and strict policies, a server without a policy
declining, the raw 101 a server writes for valid and invalid offers,
and the client failing on malformed or non-honoring acceptances. All
offline.
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
import libs.extras.compress.deflate
import libs.extras.compress.inflate
import libs.standard.net.testing


void wsh_opt_in():
	assert_equal(1, ws_use_sha1(WHASH_SHA1()))
	assert_equal(1, ws_use_deflate(deflate_window, inflate_window))


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


# Echo route with permessage-deflate policy user_data (a
# ws_deflate_config*); echoes until the client closes.
void wsh_deflate_route(RequestContext* rc, void* user_data):
	ws_conn* c = ws_accept_deflate(rc, 0, cast(ws_deflate_config*, user_data))
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


ws_deflate_config* wsh_cfg(int snct, int cnct, int sbits, int cbits):
	ws_deflate_config* cfg = ws_deflate_config_new()
	cfg.server_no_context_takeover = snct
	cfg.client_no_context_takeover = cnct
	cfg.server_max_window_bits = sbits
	cfg.client_max_window_bits = cbits
	return cfg


# Binds an echo server (plain or TLS) and forks its accept loop for
# `connections` connections. Returns the port; *out_pid the child.
# Routes: /echo (no compression), /z (default deflate policy), /zstrict
# (no context takeover either way, server window 2^10, client 2^9).
int wsh_start_server(int tls, int connections, int* out_pid):
	wsh_opt_in()
	ServerContext* s = server_context_new(c"127.0.0.1", 0, wsh_unused_handler, 0)
	s.timeout_ms = 60000
	if (tls != 0):
		server_context_set_tls(s, c"libs/standard/net/tls_fixtures/server_p256_cert.pem", c"libs/standard/net/tls_fixtures/server_p256_key.pem")
	asserts(c"bind", server_context_bind(s) != 0)
	server_route(s, c"GET", c"/echo", wsh_echo_route, 0)
	server_route(s, c"GET", c"/z", wsh_deflate_route, ws_deflate_config_new())
	server_route(s, c"GET", c"/zstrict", wsh_deflate_route, wsh_cfg(1, 1, 10, 9))
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
	char* url = net_test_url(c"ws", port, c"/echo")

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
	net_test_finish(pid, -1)


void test_wss_loopback_handshake_and_echo():
	int pid = 0
	int port = wsh_start_server(1, 1, &pid)
	char* url = net_test_url(c"wss", port, c"/echo")
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
	net_test_finish(pid, -1)


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


# permessage-deflate answers to a client that offered it.
int wsh_pmd_unknown_param():
	return 7


int wsh_pmd_not_honored():
	return 8


int wsh_pmd_ok_with_early_frame():
	return 9


int wsh_scenarios():
	return 10


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
		if (scenario == wsh_pmd_unknown_param()):
			string_append(out, c"Sec-WebSocket-Extensions: permessage-deflate; x_bits=1\x0d\x0a")
		if (scenario == wsh_pmd_not_honored()):
			# The client asked for server_max_window_bits=10.
			string_append(out, c"Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=12\x0d\x0a")
		if (scenario == wsh_pmd_ok_with_early_frame()):
			string_append(out, c"Sec-WebSocket-Extensions: permessage-deflate; server_max_window_bits=10\x0d\x0a")
		string_append(out, c"\x0d\x0a")
		if (scenario == wsh_ok_with_early_frames()):
			# Frames in the same write as the 101 head: they sit in the
			# handshake's read buffer and must survive the handover.
			string_append(out, c"\x81\x05early\x88\x02\x03\xe8")
		if (scenario == wsh_pmd_ok_with_early_frame()):
			# RFC 7692 7.2.3.1 "Hello", compressed, then a close.
			string_append_bytes(out, c"\xc1\x07\xf2\x48\xcd\xc9\xc9\x07\x00\x88\x02\x03\xe8", 13)
		net_test_send_all(conn, out.data, out.length)
		string_free(out)
		free(accept)
		free(key)
		net_test_drain(conn)
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
	char* url = net_test_url(c"ws", port, c"/")

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

	# permessage-deflate offers: an unknown parameter or a server window
	# larger than asked fails the handshake; a valid acceptance works
	# and the compressed early frame inflates.
	ws_deflate_config* cfg = wsh_cfg(0, 0, 10, 0)
	http_req* req = http_req_new(c"GET", url)
	c = ws_open_deflate(req, cfg)
	assert_equal(ws_error_handshake(), ws_conn_error(c))
	ws_conn_free(c)
	c = ws_open_deflate(req, cfg)
	assert_equal(ws_error_handshake(), ws_conn_error(c))
	ws_conn_free(c)
	c = ws_open_deflate(req, cfg)
	assert_equal(ws_error_none(), ws_conn_error(c))
	assert_equal(1, ws_compression_active(c))
	m = ws_recv(c)
	asserts(c"compressed early frame delivered", m != 0)
	assert_strings_equal(c"Hello", m.data)
	ws_message_free(m)
	asserts(c"early close", ws_recv(c) == 0)
	assert_equal(ws_error_closed(), ws_conn_error(c))
	ws_conn_free(c)
	http_req_free(req)
	free(cfg)
	free(url)
	close(listener)
	net_test_finish(pid, -1)


/* ---- permessage-deflate end to end ---- */

# One compressed session against path under the client preferences cfg;
# expect_active says whether the server should have accepted.
void wsh_deflate_session(int port, char* path, ws_deflate_config* cfg, int expect_active):
	char* url = net_test_url(c"ws", port, path)
	http_req* req = http_req_new(c"GET", url)
	ws_conn* c = ws_open_deflate(req, cfg)
	if (ws_conn_error(c) != 0):
		print_string(c"ws_open_deflate: ", ws_error_string(ws_conn_error(c)))
	assert_equal(ws_error_none(), ws_conn_error(c))
	assert_equal(expect_active, ws_compression_active(c))
	int k = 0
	while (k < 3):
		wsh_expect_echo(c, ws_op_text(), c"compress me, compress me, compress me", 37)
		k = k + 1
	char* big = malloc(70000)
	int i = 0
	while (i < 70000):
		big[i] = ((i / 5) * 13 + (i >> 11)) & 255
		i = i + 1
	wsh_expect_echo(c, ws_op_binary(), big, 70000)
	wsh_expect_echo(c, ws_op_binary(), big, 70000)
	free(big)
	wsh_expect_echo(c, ws_op_binary(), c"", 0)
	assert_equal(1, ws_close(c, 1000, c"done"))
	ws_conn_free(c)
	http_req_free(req)
	free(url)


void test_ws_deflate_loopback_sessions():
	int pid = 0
	int port = wsh_start_server(0, 6, &pid)
	ws_deflate_config* plain = ws_deflate_config_new()
	ws_deflate_config* strict = wsh_cfg(1, 1, 11, 12)
	wsh_deflate_session(port, c"/z", plain, 1)
	wsh_deflate_session(port, c"/z", strict, 1)
	wsh_deflate_session(port, c"/zstrict", plain, 1)
	wsh_deflate_session(port, c"/zstrict", strict, 1)
	# A server without a policy declines; the session is uncompressed.
	wsh_deflate_session(port, c"/echo", plain, 0)
	# Compression off (ws_open) against a deflate route: nothing offered.
	char* url = net_test_url(c"ws", port, c"/z")
	ws_conn* c = ws_connect(url)
	assert_equal(ws_error_none(), ws_conn_error(c))
	assert_equal(0, ws_compression_active(c))
	wsh_expect_echo(c, ws_op_text(), c"plain", 5)
	assert_equal(1, ws_close(c, 1000, 0))
	ws_conn_free(c)
	free(url)
	# An invalid client config never reaches the network.
	ws_deflate_config* bad = wsh_cfg(0, 0, 0, 16)
	url = net_test_url(c"ws", port, c"/z")
	http_req* req = http_req_new(c"GET", url)
	c = ws_open_deflate(req, bad)
	assert_equal(ws_error_bad_request(), ws_conn_error(c))
	ws_conn_free(c)
	http_req_free(req)
	free(url)
	free(bad)
	free(strict)
	free(plain)
	net_test_finish(pid, -1)


# The raw 101 for an upgrade to /zstrict offering `offer`; a masked,
# empty close frame follows the request so the route's session ends.
char* wsh_offer_reply(int port, char* offer):
	string_builder* out = string_new()
	string_append(out, c"GET /zstrict HTTP/1.1\x0d\x0aHost: 127.0.0.1\x0d\x0aUpgrade: websocket\x0d\x0aConnection: Upgrade\x0d\x0aSec-WebSocket-Version: 13\x0d\x0aSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\x0d\x0aSec-WebSocket-Extensions: ")
	string_append(out, offer)
	string_append(out, c"\x0d\x0a\x0d\x0a\x88\x80\x01\x02\x03\x04")
	char* reply = net_test_exchange(port, out.data)
	string_free(out)
	asserts(c"upgraded", net_test_contains(reply, c"HTTP/1.1 101 Switching Protocols") != 0)
	return reply


void test_ws_deflate_server_response_headers():
	int pid = 0
	int port = wsh_start_server(0, 4, &pid)
	char* reply = wsh_offer_reply(port, c"permessage-deflate; client_max_window_bits")
	asserts(c"accepted", net_test_contains(reply, c"Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=10; client_max_window_bits=9\x0d\x0a") != 0)
	free(reply)
	reply = wsh_offer_reply(port, c"permessage-deflate; server_max_window_bits=8")
	asserts(c"accepted, narrower", net_test_contains(reply, c"Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=8\x0d\x0a") != 0)
	free(reply)
	# Invalid offers are declined but the upgrade still happens.
	reply = wsh_offer_reply(port, c"permessage-deflate; server_max_window_bits=99")
	asserts(c"declined", net_test_contains(reply, c"Sec-WebSocket-Extensions") == 0)
	free(reply)
	reply = wsh_offer_reply(port, c"permessage-deflate; client_no_context_takeover; client_no_context_takeover")
	asserts(c"declined duplicate", net_test_contains(reply, c"Sec-WebSocket-Extensions") == 0)
	free(reply)
	net_test_finish(pid, -1)
