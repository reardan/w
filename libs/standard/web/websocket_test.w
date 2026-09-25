# wbuild: x64
# Offline tests for libs/standard/web/websocket.w (RFC 6455, issue #436).
# Everything here runs WITHOUT SHA-1 (nothing under libs/standard may
# import libs/x/unsafe, see unsafe_import_test): the pure frame codec
# against the RFC 6455 section 5.7 examples and the length/opcode/RSV
# edge cases, the SHA-1 opt-in refusing bad digests, framing sessions
# between a client-role and a server-role ws_conn over a forked
# socketpair (ws_conn_wrap: no opening handshake needed), peer protocol
# violations scripted byte-for-byte by a forked raw peer, and the
# server's upgrade-request validation through a forked http_server.w
# route (the fork-a-fixture pattern of http_client_test.w). The SHA-1
# dependent pieces -- the section 1.3 accept-key example and full
# ws://+wss:// handshakes -- live in libs/x/unsafe/websocket_sha1_test.w.
#
# permessage-deflate (RFC 7692): the codec opt-in (ws_use_deflate with
# libs/extras/compress's deflate_window/inflate_window, which a test --
# unlike libs/standard modules -- may import), the section 7.2.3
# examples in both directions, RSV1 rules, offer/response negotiation
# (pure functions), compressed echo sessions over a socketpair with and
# without context takeover and with small windows, and compressed
# violations (bad data 1007, inflating past the cap 1009, references
# beyond the agreed window).
import lib.testing
import lib.net
import lib.utf8
import structures.string
import libs.standard.crypto.sha2
import libs.standard.web.connection
import libs.standard.web.http_client
import libs.standard.web.http_server
import libs.standard.web.websocket
import libs.extras.compress.deflate
import libs.extras.compress.inflate


/* ---- helpers ---- */

# Bytes of a hex string like "81 05 48" (spaces ignored) into a malloc'd
# buffer; *out_len receives the count.
char* wst_hex(char* text, int* out_len):
	int n = strlen(text)
	char* out = malloc(n / 2 + 1)
	int count = 0
	int i = 0
	int high = (-1)
	while (i < n):
		int ch = text[i] & 255
		int v = (-1)
		if ((ch >= '0') && (ch <= '9')):
			v = ch - '0'
		else if ((ch >= 'a') && (ch <= 'f')):
			v = ch - 'a' + 10
		if (v >= 0):
			if (high < 0):
				high = v
			else:
				out[count] = (high << 4) | v
				count = count + 1
				high = (-1)
		i = i + 1
	*out_len = count
	return out


void wst_assert_bytes(char* label, char* expected_hex, char* actual, int actual_len):
	int n = 0
	char* expected = wst_hex(expected_hex, &n)
	if (n != actual_len):
		print_string(label, c": length mismatch")
		assert_equal(n, actual_len)
	int i = 0
	while (i < n):
		if ((expected[i] & 255) != (actual[i] & 255)):
			print_string(label, c": byte mismatch")
			assert_equal(expected[i] & 255, actual[i] & 255)
		i = i + 1
	free(expected)


# Encodes one frame and compares it with the RFC bytes.
void wst_expect_encoding(char* label, int fin, int opcode, char* payload, int len, char* mask_hex, char* expected_hex):
	string_builder* out = string_new()
	char* mask = 0
	int mask_len = 0
	if (mask_hex != 0):
		mask = wst_hex(mask_hex, &mask_len)
	asserts(label, ws_frame_encode(out, fin, opcode, payload, len, mask) == 1)
	wst_assert_bytes(label, expected_hex, out.data, out.length)
	if (mask != 0):
		free(mask)
	string_free(out)


# Decodes the RFC bytes and checks the frame fields + payload text.
void wst_expect_decoding(char* label, char* frame_hex, int fin, int opcode, int masked, char* payload_text):
	int n = 0
	char* buf = wst_hex(frame_hex, &n)
	ws_frame f
	int used = ws_frame_decode(buf, n, &f, 1000)
	if (used != n):
		print_string(label, c": consumed")
		assert_equal(n, used)
	assert_equal(fin, f.fin)
	assert_equal(opcode, f.opcode)
	assert_equal(masked, f.masked)
	assert_equal(strlen(payload_text), f.payload_len)
	int i = 0
	while (i < f.payload_len):
		assert_equal(payload_text[i] & 255, f.payload[i] & 255)
		i = i + 1
	# Every strict prefix is "need more input".
	int k = 0
	while (k < n):
		char* copy = malloc(n)
		int j = 0
		while (j < n):
			copy[j] = buf[j]
			j = j + 1
		ws_frame g
		assert_equal(0, ws_frame_decode(copy, k, &g, 1000))
		free(copy)
		k = k + 1
	free(buf)


int wst_decode_hex(char* frame_hex, int max_payload):
	int n = 0
	char* buf = wst_hex(frame_hex, &n)
	ws_frame f
	int r = ws_frame_decode(buf, n, &f, max_payload)
	free(buf)
	return r


# A connected socketpair with 10s wedge-guard timeouts on both ends.
void wst_pair(int* fds):
	asserts(c"socketpair", socket_pair(fds) >= 0)
	socket_set_recv_timeout(fds[0], 10000)
	socket_set_send_timeout(fds[0], 10000)
	socket_set_recv_timeout(fds[1], 10000)
	socket_set_send_timeout(fds[1], 10000)


void wst_wait_ok(int pid):
	int status = 0
	wait4(pid, &status, 0, 0)
	asserts(c"peer child exited cleanly", status == 0)


void wst_send_all(int fd, char* data, int n):
	int total = 0
	while (total < n):
		int got = socket_send(fd, data + total, n - total, msg_nosignal())
		if (got <= 0):
			return
		total = total + got


/* ---- SHA-1 opt-in ---- */

void wst_fake_compress(int* state, char* block):
	state[0] = state[0] + (block[0] & 255)


void wst_fake_iv(int* state):
	int i = 0
	while (i < 5):
		state[i] = 0
		i = i + 1


void test_ws_sha1_opt_in_fails_closed():
	# Nothing configured: no accept key, no client handshake.
	asserts(c"accept key without SHA-1", ws_accept_key(c"dGhlIHNhbXBsZSBub25jZQ==") == 0)
	ws_conn* c = ws_connect(c"ws://127.0.0.1:9/")
	assert_equal(ws_error_no_sha1(), ws_conn_error(c))
	ws_conn_free(c)
	# Built-in SHA-2 ids, unregistered ids, and a 20-byte digest that is
	# not SHA-1 (fails the RFC 6455 1.3 known answer) are all refused.
	assert_equal(0, ws_use_sha1(WHASH_SHA256()))
	assert_equal(0, ws_use_sha1(173))
	whash_register(174, 20, 64, 5, 0, wst_fake_compress, wst_fake_iv)
	assert_equal(0, ws_use_sha1(174))
	asserts(c"still unconfigured", ws_accept_key(c"x") == 0)


void test_ws_client_request_validation():
	# URL scheme is checked before anything else.
	ws_conn* c = ws_connect(c"http://127.0.0.1:9/")
	assert_equal(ws_error_bad_url(), ws_conn_error(c))
	ws_conn_free(c)
	c = ws_connect(c"ftp://127.0.0.1:9/")
	assert_equal(ws_error_bad_url(), ws_conn_error(c))
	ws_conn_free(c)
	http_req* req = http_req_new(c"POST", c"ws://127.0.0.1:9/")
	c = ws_open(req)
	assert_equal(ws_error_bad_request(), ws_conn_error(c))
	ws_conn_free(c)
	http_req_free(req)
	assert_strings_equal(c"http://h/x", ws_http_url(c"ws://h/x"))
	assert_strings_equal(c"https://h:9/x?q", ws_http_url(c"WSS://h:9/x?q"))
	assert_strings_equal(c"message too big", ws_error_string(ws_error_too_big()))


/* ---- frame codec: RFC 6455 section 5.7 examples ---- */

void test_ws_rfc_5_7_encode():
	wst_expect_encoding(c"unmasked Hello", 1, ws_op_text(), c"Hello", 5, 0, c"81 05 48 65 6c 6c 6f")
	wst_expect_encoding(c"masked Hello", 1, ws_op_text(), c"Hello", 5, c"37 fa 21 3d", c"81 85 37 fa 21 3d 7f 9f 4d 51 58")
	wst_expect_encoding(c"fragment Hel", 0, ws_op_text(), c"Hel", 3, 0, c"01 03 48 65 6c")
	wst_expect_encoding(c"fragment lo", 1, ws_op_continuation(), c"lo", 2, 0, c"80 02 6c 6f")
	wst_expect_encoding(c"unmasked ping", 1, ws_op_ping(), c"Hello", 5, 0, c"89 05 48 65 6c 6c 6f")
	wst_expect_encoding(c"masked pong", 1, ws_op_pong(), c"Hello", 5, c"37 fa 21 3d", c"8a 85 37 fa 21 3d 7f 9f 4d 51 58")

	# 256 bytes of binary data: 16-bit length.
	char* data = malloc(65536)
	int i = 0
	while (i < 65536):
		data[i] = i & 255
		i = i + 1
	string_builder* out = string_new()
	assert_equal(1, ws_frame_encode(out, 1, ws_op_binary(), data, 256, 0))
	assert_equal(260, out.length)
	wst_assert_bytes(c"256 header", c"82 7e 01 00", out.data, 4)
	assert_equal(255, out.data[259] & 255)
	# 64KiB: 64-bit length.
	string_clear(out)
	assert_equal(1, ws_frame_encode(out, 1, ws_op_binary(), data, 65536, 0))
	assert_equal(65546, out.length)
	wst_assert_bytes(c"64KiB header", c"82 7f 00 00 00 00 00 01 00 00", out.data, 10)
	ws_frame f
	assert_equal(65546, ws_frame_decode(out.data, out.length, &f, 65536))
	assert_equal(65536, f.payload_len)
	assert_equal(ws_op_binary(), f.opcode)
	assert_equal(7, f.payload[7] & 255)
	# The same 64KiB frame over a smaller cap fails closed with 1009.
	assert_equal(0 - 1009, ws_frame_decode(out.data, out.length, &f, 65535))
	# Boundaries between the encodings.
	string_clear(out)
	ws_frame_encode(out, 1, ws_op_binary(), data, 125, 0)
	assert_equal(127, out.length)
	string_clear(out)
	ws_frame_encode(out, 1, ws_op_binary(), data, 126, 0)
	wst_assert_bytes(c"126 header", c"82 7e 00 7e", out.data, 4)
	string_clear(out)
	ws_frame_encode(out, 1, ws_op_binary(), data, 65535, 0)
	wst_assert_bytes(c"65535 header", c"82 7e ff ff", out.data, 4)
	assert_equal(0, ws_frame_encode(out, 1, ws_op_binary(), data, (-1), 0))
	string_free(out)
	free(data)


void test_ws_rfc_5_7_decode():
	wst_expect_decoding(c"unmasked Hello", c"81 05 48 65 6c 6c 6f", 1, ws_op_text(), 0, c"Hello")
	wst_expect_decoding(c"masked Hello", c"81 85 37 fa 21 3d 7f 9f 4d 51 58", 1, ws_op_text(), 1, c"Hello")
	wst_expect_decoding(c"fragment Hel", c"01 03 48 65 6c", 0, ws_op_text(), 0, c"Hel")
	wst_expect_decoding(c"fragment lo", c"80 02 6c 6f", 1, ws_op_continuation(), 0, c"lo")
	wst_expect_decoding(c"unmasked ping", c"89 05 48 65 6c 6c 6f", 1, ws_op_ping(), 0, c"Hello")
	wst_expect_decoding(c"masked pong", c"8a 85 37 fa 21 3d 7f 9f 4d 51 58", 1, ws_op_pong(), 1, c"Hello")
	wst_expect_decoding(c"empty close", c"88 00", 1, ws_op_close(), 0, c"")


void test_ws_decode_rejects():
	# RSV bits (no extension negotiated) and reserved opcodes.
	assert_equal(0 - 1002, wst_decode_hex(c"c1 00", 100))
	assert_equal(0 - 1002, wst_decode_hex(c"91 00", 100))
	assert_equal(0 - 1002, wst_decode_hex(c"83 00", 100))
	assert_equal(0 - 1002, wst_decode_hex(c"8b 00", 100))
	# Control frames: fragmented, or longer than 125 bytes.
	assert_equal(0 - 1002, wst_decode_hex(c"09 00", 100))
	assert_equal(0 - 1002, wst_decode_hex(c"89 7e 00 80", 100))
	# Non-minimal 16- and 64-bit lengths.
	assert_equal(0 - 1002, wst_decode_hex(c"82 7e 00 05", 100000))
	assert_equal(0 - 1002, wst_decode_hex(c"82 7f 00 00 00 00 00 00 ff ff", 100000))
	# 64-bit length: MSB set is a protocol error; anything not fitting in
	# 31 bits (2^32, 2^31) is too big on every target, as is > cap.
	assert_equal(0 - 1002, wst_decode_hex(c"82 7f 80 00 00 00 00 00 00 00", 100000))
	assert_equal(0 - 1009, wst_decode_hex(c"82 7f 00 00 00 01 00 00 00 00", 100000))
	assert_equal(0 - 1009, wst_decode_hex(c"82 7f 00 00 00 00 80 00 00 00", 100000))
	assert_equal(0 - 1009, wst_decode_hex(c"82 7f 00 00 00 00 7f ff ff ff", 100000))
	assert_equal(0 - 1009, wst_decode_hex(c"82 65", 100))
	# Control frames are not subject to the data cap.
	assert_equal(0, wst_decode_hex(c"89 7d", 10))
	# Close-code validity.
	assert_equal(1, ws_close_code_valid(1000))
	assert_equal(1, ws_close_code_valid(4999))
	assert_equal(0, ws_close_code_valid(1005))
	assert_equal(0, ws_close_code_valid(1006))
	assert_equal(0, ws_close_code_valid(1015))
	assert_equal(0, ws_close_code_valid(999))
	assert_equal(0, ws_close_code_valid(2000))
	assert_equal(0, ws_close_code_valid(5000))


/* ---- sessions over a socketpair (no handshake) ---- */

# Server-role echo peer: echoes each message with its opcode; on
# "ping-me" pings the client and then sends "pinged"; on "pongs?"
# reports how many pongs it has seen; on "close-me" starts the closing
# handshake itself with 4000 "server bye". Exits 0 after a clean close
# whose status and reason match what the client test sends. cfg != 0
# turns permessage-deflate on first (ws_set_compression).
void wst_echo_peer_z(int fd, ws_deflate_config* cfg):
	ConnectionContext* cc = connection_context_new(fd, 10000, 0)
	ws_conn* c = ws_conn_wrap(cc, 0, 1)
	if (cfg != 0):
		if (ws_set_compression(c, cfg) == 0):
			exit(7)
	while (1):
		ws_message* m = ws_recv(c)
		if (m == 0):
			if (ws_conn_error(c) != ws_error_closed()):
				exit(10 + ws_conn_error(c))
			if (c.peer_close_code != 1000):
				exit(3)
			if (strcmp(c.peer_close_reason, c"bye") != 0):
				exit(4)
			ws_conn_free(c)
			exit(0)
		if ((m.opcode == ws_op_text()) && (strcmp(m.data, c"ping-me") == 0)):
			ws_send_ping(c, c"hi", 2)
			ws_send_text(c, c"pinged", 6)
		else if ((m.opcode == ws_op_text()) && (strcmp(m.data, c"pongs?") == 0)):
			char* count = itoa(c.pongs_received)
			ws_send_text(c, count, strlen(count))
			free(count)
		else if ((m.opcode == ws_op_text()) && (strcmp(m.data, c"close-me") == 0)):
			if (ws_close(c, 4000, c"server bye") == 0):
				exit(5)
			if (c.peer_close_code != 4000):
				exit(6)
			ws_conn_free(c)
			exit(0)
		else if (m.opcode == ws_op_text()):
			ws_send_text(c, m.data, m.len)
		else:
			ws_send_binary(c, m.data, m.len)
		ws_message_free(m)


void wst_echo_peer(int fd):
	wst_echo_peer_z(fd, 0)


# A client-role conn talking to a forked echo peer; cfg != 0 turns
# permessage-deflate on at both ends.
ws_conn* wst_client_to_echo_z(int* out_pid, ws_deflate_config* cfg):
	int* fds = malloc(__word_size__ * 2)
	wst_pair(fds)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		close(fds[0])
		wst_echo_peer_z(fds[1], cfg)
		exit(9)
	close(fds[1])
	*out_pid = pid
	ws_conn* c = ws_conn_wrap(connection_context_new(fds[0], 10000, 0), 1, 1)
	if (cfg != 0):
		assert_equal(1, ws_set_compression(c, cfg))
	return c


ws_conn* wst_client_to_echo(int* out_pid):
	return wst_client_to_echo_z(out_pid, 0)


ws_message* wst_recv_ok(ws_conn* c):
	ws_message* m = ws_recv(c)
	if (m == 0):
		print_string(c"ws_recv failed: ", ws_error_string(ws_conn_error(c)))
		asserts(c"ws_recv returned a message", 0)
	return m


void wst_expect_text(ws_conn* c, char* text):
	ws_message* m = wst_recv_ok(c)
	assert_equal(ws_op_text(), m.opcode)
	assert_strings_equal(text, m.data)
	assert_equal(strlen(text), m.len)
	ws_message_free(m)


void test_ws_session_echo_and_close():
	int pid = 0
	ws_conn* c = wst_client_to_echo(&pid)
	assert_equal(1, ws_send_text(c, c"hello", 5))
	wst_expect_text(c, c"hello")
	# UTF-8 text round trip; invalid UTF-8 is refused before sending.
	assert_equal(1, ws_send_text(c, c"h\xc3\xa9llo \xe2\x82\xac", 10))
	wst_expect_text(c, c"h\xc3\xa9llo \xe2\x82\xac")
	assert_equal(0, ws_send_text(c, c"bad \xc3\x28", 6))
	assert_equal(0, ws_conn_error(c))
	# Empty message.
	assert_equal(1, ws_send_binary(c, c"", 0))
	ws_message* m = wst_recv_ok(c)
	assert_equal(ws_op_binary(), m.opcode)
	assert_equal(0, m.len)
	ws_message_free(m)
	# 16-bit and 64-bit length encodings, both directions.
	int* sizes = malloc(__word_size__ * 2)
	sizes[0] = 300
	sizes[1] = 70000
	int k = 0
	while (k < 2):
		int n = sizes[k]
		char* data = malloc(n)
		int i = 0
		while (i < n):
			data[i] = (i * 7 + k) & 255
			i = i + 1
		assert_equal(1, ws_send_binary(c, data, n))
		m = wst_recv_ok(c)
		assert_equal(ws_op_binary(), m.opcode)
		assert_equal(n, m.len)
		i = 0
		while (i < n):
			if ((m.data[i] & 255) != (data[i] & 255)):
				assert_equal(data[i] & 255, m.data[i] & 255)
			i = i + 1
		ws_message_free(m)
		free(data)
		k = k + 1
	# Fragmented text with a ping interleaved between fragments; the
	# echo peer answers the ping (dropped by our ws_recv) and echoes the
	# reassembled message.
	assert_equal(1, ws_send_frame(c, 0, ws_op_text(), c"frag", 4))
	assert_equal(1, ws_send_ping(c, c"mid", 3))
	assert_equal(1, ws_send_frame(c, 0, ws_op_continuation(), c"men", 3))
	assert_equal(1, ws_send_frame(c, 1, ws_op_continuation(), c"ted", 3))
	wst_expect_text(c, c"fragmented")
	assert_equal(1, c.pongs_received)
	# Control-frame sending rules are enforced locally.
	assert_equal(0, ws_send_frame(c, 0, ws_op_ping(), c"x", 1))
	char* big = malloc(126)
	assert_equal(0, ws_send_ping(c, big, 126))
	free(big)
	assert_equal(0, ws_send_frame(c, 1, 3, c"x", 1))
	# Server-initiated ping is auto-ponged inside ws_recv.
	ws_send_text(c, c"ping-me", 7)
	wst_expect_text(c, c"pinged")
	assert_equal(1, c.pings_received)
	ws_send_text(c, c"pongs?", 6)
	wst_expect_text(c, c"1")
	# Bad close arguments are refused without touching the connection.
	assert_equal(0, ws_close(c, 1005, 0))
	assert_equal(0, ws_close(c, 0, c"reason without code"))
	# Client-initiated close handshake.
	assert_equal(1, ws_close(c, 1000, c"bye"))
	assert_equal(ws_error_closed(), ws_conn_error(c))
	assert_equal(1000, c.peer_close_code)
	asserts(c"no sends after close", ws_send_text(c, c"late", 4) == 0)
	asserts(c"no recv after close", ws_recv(c) == 0)
	ws_conn_free(c)
	wst_wait_ok(pid)


void test_ws_session_server_initiated_close():
	int pid = 0
	ws_conn* c = wst_client_to_echo(&pid)
	ws_send_text(c, c"close-me", 8)
	asserts(c"recv ends at close", ws_recv(c) == 0)
	assert_equal(ws_error_closed(), ws_conn_error(c))
	assert_equal(4000, c.peer_close_code)
	assert_strings_equal(c"server bye", c.peer_close_reason)
	# Our echo already went out; ws_close just reports the handshake done.
	assert_equal(1, ws_close(c, 1000, 0))
	ws_conn_free(c)
	wst_wait_ok(pid)


/* ---- peer protocol violations, scripted byte for byte ---- */

# Raw peer: writes raw[0..n), then reads the frame the side under test
# answers with and exits 0 iff it is a close frame carrying expect_code
# (masked iff the side under test is a client). expect_code 0 means the
# peer just hangs up after writing.
void wst_raw_peer_bytes(int fd, char* raw, int n, int tested_is_client, int expect_code):
	wst_send_all(fd, raw, n)
	if (expect_code == 0):
		close(fd)
		exit(0)
	char* buf = malloc(4096)
	int have = 0
	while (1):
		ws_frame f
		int used = ws_frame_decode(buf, have, &f, 4096)
		if (used < 0):
			exit(2)
		if (used > 0):
			if (f.opcode != ws_op_close()):
				# Skip anything else (e.g. an auto-pong).
				int i = 0
				while (used + i < have):
					buf[i] = buf[used + i]
					i = i + 1
				have = have - used
			else:
				if (f.masked != tested_is_client):
					exit(3)
				if (f.payload_len < 2):
					exit(4)
				int code = ((f.payload[0] & 255) << 8) | (f.payload[1] & 255)
				if (code != expect_code):
					exit(5)
				exit(0)
		else:
			int got = read(fd, buf + have, 4096 - have)
			if (got <= 0):
				exit(6)
			have = have + got


void wst_raw_peer(int fd, char* raw_hex, int tested_is_client, int expect_code):
	int n = 0
	char* raw = wst_hex(raw_hex, &n)
	wst_raw_peer_bytes(fd, raw, n, tested_is_client, expect_code)


# Runs one violation: the side under test (client or server role, max
# message cap, permessage-deflate per cfg when non-zero) must deliver
# `messages` good messages and then fail with expect_error after
# sending expect_code, on raw[0..n) from the peer.
void wst_violation_bytes(char* label, int tested_is_client, int max_message, ws_deflate_config* cfg, char* raw, int n, int messages, int expect_error, int expect_code):
	int* fds = malloc(__word_size__ * 2)
	wst_pair(fds)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		close(fds[0])
		wst_raw_peer_bytes(fds[1], raw, n, tested_is_client, expect_code)
		exit(9)
	close(fds[1])
	ws_conn* c = ws_conn_wrap(connection_context_new(fds[0], 10000, 0), tested_is_client, 1)
	ws_set_max_message(c, max_message)
	if (cfg != 0):
		assert_equal(1, ws_set_compression(c, cfg))
	ws_message* m = 0
	int k = 0
	while (k < messages):
		m = ws_recv(c)
		if (m == 0):
			print_string(label, ws_error_string(ws_conn_error(c)))
			asserts(label, 0)
		ws_message_free(m)
		k = k + 1
	m = ws_recv(c)
	if (m != 0):
		print_string(label, c": unexpected message")
		asserts(label, 0)
	if (ws_conn_error(c) != expect_error):
		print_string(label, ws_error_string(ws_conn_error(c)))
		assert_equal(expect_error, ws_conn_error(c))
	if (expect_error != ws_error_closed()):
		assert_equal(expect_code, c.local_close_code)
	asserts(label, ws_send_text(c, c"x", 1) == 0)
	ws_conn_free(c)
	int status = 0
	wait4(pid, &status, 0, 0)
	if (status != 0):
		print_string(label, c": raw peer rejected the reply")
		asserts(label, 0)


void wst_violation(char* label, int tested_is_client, int max_message, char* raw_hex, int expect_error, int expect_code):
	int n = 0
	char* raw = wst_hex(raw_hex, &n)
	wst_violation_bytes(label, tested_is_client, max_message, 0, raw, n, 0, expect_error, expect_code)
	free(raw)


void test_ws_client_rejects_peer_violations():
	int proto = ws_error_protocol()
	# A server must not mask.
	wst_violation(c"masked server frame", 1, 1000, c"81 85 37 fa 21 3d 7f 9f 4d 51 58", proto, 1002)
	wst_violation(c"rsv bit", 1, 1000, c"c1 01 41", proto, 1002)
	wst_violation(c"reserved opcode", 1, 1000, c"83 00", proto, 1002)
	wst_violation(c"fragmented ping", 1, 1000, c"09 00", proto, 1002)
	wst_violation(c"orphan continuation", 1, 1000, c"80 01 41", proto, 1002)
	wst_violation(c"text inside fragmented text", 1, 1000, c"01 01 41 81 01 42", proto, 1002)
	wst_violation(c"invalid utf-8 text", 1, 1000, c"81 02 c3 28", ws_error_bad_utf8(), 1007)
	wst_violation(c"invalid utf-8 across fragments", 1, 1000, c"01 01 c3 80 01 28", ws_error_bad_utf8(), 1007)
	wst_violation(c"64-bit length 2^32", 1, 1000, c"82 7f 00 00 00 01 00 00 00 00", ws_error_too_big(), 1009)
	wst_violation(c"frame over cap", 1, 100, c"82 65", ws_error_too_big(), 1009)
	wst_violation(c"fragments over cap", 1, 4, c"02 03 41 42 43 00 02 44 45", ws_error_too_big(), 1009)
	wst_violation(c"close with 1 byte", 1, 1000, c"88 01 03", proto, 1002)
	wst_violation(c"close with code 1005", 1, 1000, c"88 02 03 ed", proto, 1002)
	wst_violation(c"close reason not utf-8", 1, 1000, c"88 04 03 e8 c3 28", ws_error_bad_utf8(), 1007)
	# Hang-up without a close frame (here mid-payload, and at a frame
	# boundary) is abnormal closure, not a clean close.
	wst_violation(c"eof mid-frame", 1, 1000, c"81 05 41", ws_error_eof(), 0)
	wst_violation(c"eof at boundary", 1, 1000, c"", ws_error_eof(), 0)


void test_ws_server_rejects_unmasked_frames():
	wst_violation(c"unmasked client frame", 0, 1000, c"81 05 48 65 6c 6c 6f", ws_error_protocol(), 1002)


void test_ws_client_accepts_close_without_status():
	int* fds = malloc(__word_size__ * 2)
	wst_pair(fds)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		close(fds[0])
		# A data message, then an empty close; expect an empty masked
		# close echoed back.
		int n = 0
		char* raw = wst_hex(c"81 02 6f 6b 88 00", &n)
		wst_send_all(fds[1], raw, n)
		char* buf = malloc(64)
		int have = 0
		while (have < 6):
			int got = read(fds[1], buf + have, 64 - have)
			if (got <= 0):
				exit(2)
			have = have + got
		ws_frame f
		if (ws_frame_decode(buf, have, &f, 64) != 6):
			exit(3)
		if ((f.opcode != ws_op_close()) || (f.payload_len != 0) || (f.masked != 1)):
			exit(4)
		exit(0)
	close(fds[1])
	ws_conn* c = ws_conn_wrap(connection_context_new(fds[0], 10000, 0), 1, 1)
	wst_expect_text(c, c"ok")
	asserts(c"close ends recv", ws_recv(c) == 0)
	assert_equal(ws_error_closed(), ws_conn_error(c))
	assert_equal(ws_close_no_status(), c.peer_close_code)
	ws_conn_free(c)
	wst_wait_ok(pid)


/* ---- server upgrade validation through http_server.w routes ---- */

ServerResponse* wst_unused_handler(ServerRequest* req, void* context):
	return server_response_new(500)


# Route handler: tries the upgrade; this binary never configures SHA-1,
# so even a well-formed request must be refused (500).
void wst_ws_route(RequestContext* rc, void* user_data):
	ws_conn* c = ws_accept(rc, 0)
	ws_conn_free(c)


# Sends one raw request to port and returns everything the server says
# before closing (malloc'd).
char* wst_raw_exchange(int port, char* request):
	int fd = socket_tcp_ipv4()
	asserts(c"socket", fd >= 0)
	socket_set_recv_timeout(fd, 10000)
	asserts(c"connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) >= 0)
	wst_send_all(fd, request, strlen(request))
	string_builder* out = string_new()
	char* buf = malloc(1024)
	int got = read(fd, buf, 1024)
	while (got > 0):
		string_append_bytes(out, buf, got)
		got = read(fd, buf, 1024)
	free(buf)
	close(fd)
	char* text = out.data
	free(out)
	return text


int wst_contains(char* hay, char* needle):
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


char* wst_upgrade_request(char* version, char* key):
	string_builder* out = string_new()
	string_append(out, c"GET /ws HTTP/1.1\x0d\x0aHost: 127.0.0.1\x0d\x0aUpgrade: websocket\x0d\x0aConnection: keep-alive, Upgrade\x0d\x0a")
	if (version != 0):
		string_append(out, c"Sec-WebSocket-Version: ")
		string_append(out, version)
		string_append(out, c"\x0d\x0a")
	if (key != 0):
		string_append(out, c"Sec-WebSocket-Key: ")
		string_append(out, key)
		string_append(out, c"\x0d\x0a")
	string_append(out, c"\x0d\x0a")
	char* text = out.data
	free(out)
	return text


void wst_expect_status(int port, char* request, char* status_line):
	char* reply = wst_raw_exchange(port, request)
	if (wst_contains(reply, status_line) == 0):
		print_string(c"reply: ", reply)
		asserts(status_line, 0)
	free(reply)
	free(request)


void test_ws_server_upgrade_validation():
	ServerContext* s = server_context_new(c"127.0.0.1", 0, wst_unused_handler, 0)
	s.timeout_ms = 60000
	asserts(c"bind", server_context_bind(s) != 0)
	server_route(s, c"GET", c"/ws", wst_ws_route, 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 5)
		exit(0)
	server_context_close(s)
	char* key = c"dGhlIHNhbXBsZSBub25jZQ=="
	# Unsupported version: 426 advertising version 13.
	char* reply = wst_raw_exchange(port, wst_upgrade_request(c"8", key))
	asserts(c"426", wst_contains(reply, c"HTTP/1.1 426 Upgrade Required") != 0)
	asserts(c"version hint", wst_contains(reply, c"Sec-WebSocket-Version: 13") != 0)
	free(reply)
	wst_expect_status(port, wst_upgrade_request(c"13", 0), c"HTTP/1.1 400 ")
	# The key must be base64 of exactly 16 bytes.
	wst_expect_status(port, wst_upgrade_request(c"13", c"c2hvcnQ="), c"HTTP/1.1 400 ")
	wst_expect_status(port, strclone(c"GET /ws HTTP/1.1\x0d\x0aHost: h\x0d\x0a\x0d\x0a"), c"HTTP/1.1 400 ")
	# Well-formed, but SHA-1 was never opted into: fail closed.
	wst_expect_status(port, wst_upgrade_request(c"13", key), c"HTTP/1.1 500 ")
	wst_wait_ok(pid)


/* ---- permessage-deflate (RFC 7692) ---- */

char* wst_fake_inflate(char* data, int len, char* window, int window_len, int max_output, int* out_len, int* out_error):
	# Always "Hello": passes the known answers but ignores max_output.
	*out_len = 5
	*out_error = 0
	return strclone(c"Hello")


char* wst_no_flush_deflate(char* data, int len, char* window, int window_len, int window_bits, int level, int* out_len):
	# A final block instead of a sync flush: inflatable, but no 00 00 ff ff.
	deflate_result* r = deflate(data, len, level)
	char* out = r.data
	*out_len = r.length
	free(r)
	return out


void wst_use_deflate():
	assert_equal(1, ws_use_deflate(deflate_window, inflate_window))


ws_deflate_config* wst_cfg(int snct, int cnct, int sbits, int cbits):
	ws_deflate_config* cfg = ws_deflate_config_new()
	cfg.server_no_context_takeover = snct
	cfg.client_no_context_takeover = cnct
	cfg.server_max_window_bits = sbits
	cfg.client_max_window_bits = cbits
	return cfg


void test_ws_deflate_opt_in_fails_closed():
	# No codec yet: compression cannot be switched on.
	ws_conn* c = ws_conn_wrap(0, 1, 0)
	ws_deflate_config* cfg = ws_deflate_config_new()
	assert_equal(0, ws_set_compression(c, cfg))
	assert_equal(0, ws_compression_active(c))
	# Codecs that fail the known answers / contract are refused.
	assert_equal(0, ws_use_deflate(deflate_window, wst_fake_inflate))
	assert_equal(0, ws_use_deflate(wst_no_flush_deflate, inflate_window))
	assert_equal(0, ws_set_compression(c, cfg))
	wst_use_deflate()
	# Window bits must be 0 (default) or 8..15.
	cfg.server_max_window_bits = 7
	assert_equal(0, ws_set_compression(c, cfg))
	cfg.server_max_window_bits = 16
	assert_equal(0, ws_set_compression(c, cfg))
	cfg.server_max_window_bits = 8
	assert_equal(1, ws_set_compression(c, cfg))
	assert_equal(1, ws_compression_active(c))
	free(cfg)
	ws_conn_free(c)
	assert_strings_equal(c"invalid compressed message", ws_error_string(ws_error_compression()))


# Compresses text on c and compares the payload with the RFC bytes.
void wst_expect_compressed(ws_conn* c, char* label, char* text, char* expected_hex):
	int n = 0
	char* z = ws_pmd_compress(c, text, strlen(text), &n)
	asserts(label, z != 0)
	wst_assert_bytes(label, expected_hex, z, n)
	free(z)


# Inflates the RFC payload on c and compares with text.
void wst_expect_decompressed(ws_conn* c, char* label, char* payload_hex, char* text):
	int n = 0
	char* z = wst_hex(payload_hex, &n)
	int out_len = 0
	char* out = ws_pmd_decompress(c, z, n, &out_len)
	asserts(label, out != 0)
	assert_equal(strlen(text), out_len)
	assert_strings_equal(text, out)
	free(out)


void test_ws_deflate_rfc7692_examples():
	wst_use_deflate()
	ws_deflate_config* cfg = ws_deflate_config_new()
	# 7.2.3.1 / 7.2.3.2: "Hello", then "Hello" again over the shared
	# window (a 5-byte back-reference into the previous message).
	ws_conn* c = ws_conn_wrap(0, 0, 0)
	assert_equal(1, ws_set_compression(c, cfg))
	wst_expect_compressed(c, c"7.2.3.1 compress", c"Hello", c"f2 48 cd c9 c9 07 00")
	# The RFC's 7.2.3.2 bytes (zlib's literal "H" + a 4-byte match) are
	# checked on the inflate side below; this encoder takes the whole
	# 5-byte match at distance 5, one byte shorter.
	wst_expect_compressed(c, c"7.2.3.2 compress", c"Hello", c"02 13 00 00")
	ws_conn_free(c)
	c = ws_conn_wrap(0, 1, 0)
	assert_equal(1, ws_set_compression(c, cfg))
	wst_expect_decompressed(c, c"7.2.3.1 inflate", c"f2 48 cd c9 c9 07 00", c"Hello")
	wst_expect_decompressed(c, c"7.2.3.2 inflate", c"f2 00 11 00 00", c"Hello")
	# 7.2.3.3 a stored block, 7.2.3.4 a BFINAL block, 7.2.3.5 two blocks.
	wst_expect_decompressed(c, c"7.2.3.3 inflate", c"00 05 00 fa ff 48 65 6c 6c 6f 00", c"Hello")
	wst_expect_decompressed(c, c"7.2.3.4 inflate", c"f3 48 cd c9 c9 07 00 00", c"Hello")
	wst_expect_decompressed(c, c"7.2.3.5 inflate", c"f2 48 05 00 00 00 ff ff ca c9 c9 07 00", c"Hello")
	# An empty message compresses to the lone empty-block header.
	wst_expect_compressed(c, c"empty", c"", c"00")
	wst_expect_decompressed(c, c"empty inflate", c"00", c"")
	ws_conn_free(c)
	# No context takeover on our side: every message starts afresh.
	cfg.server_no_context_takeover = 1
	c = ws_conn_wrap(0, 0, 0)
	assert_equal(1, ws_set_compression(c, cfg))
	wst_expect_compressed(c, c"no takeover 1", c"Hello", c"f2 48 cd c9 c9 07 00")
	wst_expect_compressed(c, c"no takeover 2", c"Hello", c"f2 48 cd c9 c9 07 00")
	ws_conn_free(c)
	free(cfg)
	# 7.2.3.1 as a whole frame: RSV1 + text, unmasked.
	string_builder* out = string_new()
	int n = 0
	char* z = wst_hex(c"f2 48 cd c9 c9 07 00", &n)
	assert_equal(1, ws_frame_encode_rsv(out, 1, 4, ws_op_text(), z, n, 0))
	wst_assert_bytes(c"rsv1 frame", c"c1 07 f2 48 cd c9 c9 07 00", out.data, out.length)
	free(z)
	string_free(out)


int wst_parse_rsv(char* frame_hex, int rsv_allowed):
	int n = 0
	char* h = wst_hex(frame_hex, &n)
	ws_frame f
	int r = ws_parse_header_rsv(h, n, &f, 1000, rsv_allowed)
	free(h)
	return r


void test_ws_deflate_rsv1_rules():
	# RSV1 on the first frame of a data message is fine once negotiated.
	assert_equal(0, wst_parse_rsv(c"c1 00", 4))
	assert_equal(0, wst_parse_rsv(c"c2 00", 4))
	assert_equal(0, wst_parse_rsv(c"41 00", 4))
	# ... but never without it, never RSV2/RSV3, never on control or
	# continuation frames.
	assert_equal(1002, wst_parse_rsv(c"c1 00", 0))
	assert_equal(1002, wst_parse_rsv(c"e1 00", 4))
	assert_equal(1002, wst_parse_rsv(c"91 00", 4))
	assert_equal(1002, wst_parse_rsv(c"c9 00", 4))
	assert_equal(1002, wst_parse_rsv(c"c8 00", 4))
	assert_equal(1002, wst_parse_rsv(c"c0 00", 4))
	assert_equal(1002, wst_parse_rsv(c"40 00", 4))


# Server negotiation: offers -> expected response (0 = declined).
void wst_expect_negotiate(char* offers, ws_deflate_config* cfg, char* expected):
	ws_pmd_params agreed
	char* got = ws_pmd_negotiate(offers, cfg, &agreed)
	if (expected == 0):
		if (got != 0):
			print_string(c"accepted: ", offers)
			asserts(c"offer declined", 0)
		return
	if (got == 0):
		print_string(c"declined: ", offers)
		asserts(c"offer accepted", 0)
	assert_strings_equal(expected, got)
	free(got)


void wst_expect_agreed(ws_pmd_params* a, int snct, int cnct, int sbits, int cbits):
	assert_equal(snct, a.server_no_context_takeover)
	assert_equal(cnct, a.client_no_context_takeover)
	assert_equal(sbits, a.server_max_window_bits)
	assert_equal(cbits, a.client_max_window_bits)


void test_ws_deflate_server_negotiation():
	ws_deflate_config* plain = ws_deflate_config_new()
	wst_expect_negotiate(c"permessage-deflate", plain, c"permessage-deflate")
	wst_expect_negotiate(c"permessage-deflate; client_max_window_bits", plain, c"permessage-deflate")
	wst_expect_negotiate(c"PerMessage-Deflate ;client_max_window_bits = 10", plain, c"permessage-deflate")
	wst_expect_negotiate(c"permessage-deflate; server_max_window_bits=10; server_no_context_takeover", plain, c"permessage-deflate; server_no_context_takeover; server_max_window_bits=10")
	wst_expect_negotiate(c"permessage-deflate; client_no_context_takeover", plain, c"permessage-deflate")
	# Agreed parameters.
	ws_pmd_params a
	char* r = ws_pmd_negotiate(c"permessage-deflate; client_max_window_bits=\"9\"; server_max_window_bits=12", plain, &a)
	assert_strings_equal(c"permessage-deflate; server_max_window_bits=12", r)
	free(r)
	wst_expect_agreed(&a, 0, 0, 12, 9)
	# Server policy: its own window/takeover, and limits asked of the
	# client when (and only when) the offer allows client_max_window_bits.
	ws_deflate_config* strict = wst_cfg(1, 1, 9, 10)
	r = ws_pmd_negotiate(c"permessage-deflate; client_max_window_bits", strict, &a)
	assert_strings_equal(c"permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=9; client_max_window_bits=10", r)
	free(r)
	wst_expect_agreed(&a, 1, 1, 9, 10)
	r = ws_pmd_negotiate(c"permessage-deflate; server_max_window_bits=8", strict, &a)
	assert_strings_equal(c"permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=8", r)
	free(r)
	wst_expect_agreed(&a, 1, 1, 8, 15)
	wst_expect_negotiate(c"permessage-deflate; client_max_window_bits=8", strict, c"permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=9")
	# Invalid offers are declined; a later valid one is taken instead.
	wst_expect_negotiate(c"permessage-deflate; foo", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; server_no_context_takeover; server_no_context_takeover", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; client_max_window_bits; client_max_window_bits=10", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; server_no_context_takeover=1", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; server_max_window_bits", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; server_max_window_bits=7", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; server_max_window_bits=16", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; server_max_window_bits=08", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; client_max_window_bits=abc", plain, 0)
	wst_expect_negotiate(c"x-webkit-deflate-frame", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; foo=1, permessage-deflate; client_max_window_bits=12", plain, c"permessage-deflate")
	wst_expect_negotiate(c"x-other; a=b, permessage-deflate", plain, c"permessage-deflate")
	# Syntax errors decline everything.
	wst_expect_negotiate(c"permessage-deflate;", plain, 0)
	wst_expect_negotiate(c"permessage-deflate; client_max_window_bits=\"10", plain, 0)
	wst_expect_negotiate(c"permessage-deflate server_no_context_takeover", plain, 0)
	wst_expect_negotiate(c"", plain, 0)
	# An invalid policy never accepts.
	ws_deflate_config* bad = wst_cfg(0, 0, 7, 0)
	wst_expect_negotiate(c"permessage-deflate", bad, 0)
	free(bad)
	free(strict)
	free(plain)


void test_ws_deflate_client_negotiation():
	ws_deflate_config* plain = ws_deflate_config_new()
	ws_deflate_config* strict = wst_cfg(1, 1, 10, 12)
	char* offer = ws_pmd_offer(plain)
	assert_strings_equal(c"permessage-deflate; client_max_window_bits", offer)
	free(offer)
	offer = ws_pmd_offer(strict)
	assert_strings_equal(c"permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=10; client_max_window_bits=12", offer)
	free(offer)
	ws_pmd_params a
	assert_equal(1, ws_pmd_accept_response(c"permessage-deflate", plain, &a))
	wst_expect_agreed(&a, 0, 0, 15, 15)
	assert_equal(1, ws_pmd_accept_response(c"permessage-deflate; server_max_window_bits=12; client_max_window_bits=9; client_no_context_takeover; server_no_context_takeover", plain, &a))
	wst_expect_agreed(&a, 1, 1, 12, 9)
	assert_equal(1, ws_pmd_accept_response(c"permessage-deflate; server_no_context_takeover; server_max_window_bits=9", strict, &a))
	wst_expect_agreed(&a, 1, 1, 9, 12)
	assert_equal(1, ws_pmd_accept_response(c"permessage-deflate; server_no_context_takeover; server_max_window_bits=10; client_max_window_bits=15", strict, &a))
	wst_expect_agreed(&a, 1, 1, 10, 12)
	# Malformed, unknown, duplicate, or not what we offered: fail.
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; client_max_window_bits", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; foo", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; client_no_context_takeover; client_no_context_takeover", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; server_max_window_bits=20", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate, permessage-deflate", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"x-webkit-deflate-frame", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate;", plain, &a))
	assert_equal(0, ws_pmd_accept_response(c"", plain, &a))
	# strict asked for server_no_context_takeover and a server window <= 10.
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; server_max_window_bits=10", strict, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; server_no_context_takeover", strict, &a))
	assert_equal(0, ws_pmd_accept_response(c"permessage-deflate; server_no_context_takeover; server_max_window_bits=11", strict, &a))
	free(strict)
	free(plain)


# n bytes of compressible-but-not-trivial data whose repeats reach
# beyond small windows.
char* wst_pattern(int n, int seed):
	char* data = malloc(n)
	int i = 0
	while (i < n):
		data[i] = ((i / 3) * 7 + seed + ((i >> 9) & 31)) & 255
		i = i + 1
	return data


void wst_expect_binary_echo(ws_conn* c, char* data, int n):
	assert_equal(1, ws_send_binary(c, data, n))
	ws_message* m = wst_recv_ok(c)
	assert_equal(ws_op_binary(), m.opcode)
	assert_equal(n, m.len)
	int i = 0
	while (i < n):
		if ((m.data[i] & 255) != (data[i] & 255)):
			assert_equal(data[i] & 255, m.data[i] & 255)
		i = i + 1
	ws_message_free(m)


# A full compressed echo session under cfg (both ends).
void wst_compressed_session(ws_deflate_config* cfg):
	wst_use_deflate()
	int pid = 0
	ws_conn* c = wst_client_to_echo_z(&pid, cfg)
	assert_equal(1, ws_compression_active(c))
	int k = 0
	while (k < 4):
		assert_equal(1, ws_send_text(c, c"hello hello hello, compressed world", 35))
		wst_expect_text(c, c"hello hello hello, compressed world")
		k = k + 1
	assert_equal(1, ws_send_text(c, c"h\xc3\xa9llo \xe2\x82\xac", 10))
	wst_expect_text(c, c"h\xc3\xa9llo \xe2\x82\xac")
	assert_equal(1, ws_send_binary(c, c"", 0))
	ws_message* m = wst_recv_ok(c)
	assert_equal(0, m.len)
	ws_message_free(m)
	char* big = wst_pattern(70000, 1)
	wst_expect_binary_echo(c, big, 70000)
	wst_expect_binary_echo(c, big, 70000)
	free(big)
	char* noise = malloc(3000)
	int i = 0
	int x = 12345
	while (i < 3000):
		x = (x * 1103515245 + 12345) & 2147483647
		noise[i] = (x >> 16) & 255
		i = i + 1
	wst_expect_binary_echo(c, noise, 3000)
	free(noise)
	# Plain (RSV1-clear) fragmented frames still work alongside.
	assert_equal(1, ws_send_frame(c, 0, ws_op_text(), c"frag", 4))
	assert_equal(1, ws_send_frame(c, 1, ws_op_continuation(), c"mented", 6))
	wst_expect_text(c, c"fragmented")
	ws_send_text(c, c"ping-me", 7)
	wst_expect_text(c, c"pinged")
	assert_equal(1, ws_close(c, 1000, c"bye"))
	ws_conn_free(c)
	wst_wait_ok(pid)


void test_ws_deflate_session_context_takeover():
	ws_deflate_config* cfg = ws_deflate_config_new()
	wst_compressed_session(cfg)
	cfg.level = 2
	wst_compressed_session(cfg)
	free(cfg)


void test_ws_deflate_session_no_context_takeover():
	ws_deflate_config* cfg = wst_cfg(1, 1, 0, 0)
	wst_compressed_session(cfg)
	free(cfg)
	cfg = wst_cfg(0, 1, 0, 0)
	wst_compressed_session(cfg)
	free(cfg)


void test_ws_deflate_session_small_windows():
	ws_deflate_config* cfg = wst_cfg(0, 0, 8, 9)
	wst_compressed_session(cfg)
	free(cfg)
	cfg = wst_cfg(1, 0, 15, 8)
	cfg.level = 0
	wst_compressed_session(cfg)
	free(cfg)


# Reads one small frame off fd into buf (returns its length).
int wst_read_some(int fd, char* buf, int cap):
	int got = read(fd, buf, cap)
	asserts(c"frame read", got > 2)
	return got


void test_ws_deflate_frames_on_the_wire():
	wst_use_deflate()
	ws_deflate_config* cfg = ws_deflate_config_new()
	int* fds = malloc(__word_size__ * 2)
	wst_pair(fds)
	ws_conn* client = ws_conn_wrap(connection_context_new(fds[0], 10000, 0), 1, 1)
	ws_conn* server = ws_conn_wrap(connection_context_new(fds[1], 10000, 0), 0, 1)
	assert_equal(1, ws_set_compression(client, cfg))
	assert_equal(1, ws_set_compression(server, cfg))
	char* text = c"compress me compress me compress me compress me compress me"
	int n = strlen(text)
	# Client to server: FIN + RSV1 + text, masked, smaller than the text;
	# the server inflates it. (Peek with MSG_PEEK-free reads: the frame is
	# re-injected through the client's socket end.)
	assert_equal(1, ws_send_text(client, text, n))
	char* buf = malloc(256)
	int got = wst_read_some(fds[1], buf, 256)
	assert_equal(193, buf[0] & 255)
	assert_equal(128, buf[1] & 128)
	asserts(c"compressed", (buf[1] & 127) < n)
	assert_equal((buf[1] & 127) + 6, got)
	wst_send_all(fds[0], buf, got)
	wst_expect_text(server, text)
	# Server to client: unmasked RSV1 binary; the second copy is a
	# back-reference into the first (context takeover), so it is tiny.
	assert_equal(1, ws_send_binary(server, text, n))
	got = wst_read_some(fds[0], buf, 256)
	assert_equal(194, buf[0] & 255)
	assert_equal(0, buf[1] & 128)
	int first_len = buf[1] & 127
	wst_send_all(fds[1], buf, got)
	ws_message* m = wst_recv_ok(client)
	assert_equal(n, m.len)
	ws_message_free(m)
	assert_equal(1, ws_send_binary(server, text, n))
	got = wst_read_some(fds[0], buf, 256)
	asserts(c"shared window", (buf[1] & 127) < first_len)
	asserts(c"tiny", (buf[1] & 127) <= 8)
	wst_send_all(fds[1], buf, got)
	m = wst_recv_ok(client)
	assert_equal(n, m.len)
	assert_strings_equal(text, m.data)
	ws_message_free(m)
	free(buf)
	free(cfg)
	ws_conn_free(client)
	ws_conn_free(server)


void wst_z_violation(char* label, ws_deflate_config* cfg, int max_message, char* raw_hex, int messages, int expect_error, int expect_code):
	int n = 0
	char* raw = wst_hex(raw_hex, &n)
	wst_violation_bytes(label, 1, max_message, cfg, raw, n, messages, expect_error, expect_code)
	free(raw)


void test_ws_deflate_peer_violations():
	wst_use_deflate()
	ws_deflate_config* cfg = ws_deflate_config_new()
	int proto = ws_error_protocol()
	int bad = ws_error_compression()
	# A good compressed message is delivered, then the violation.
	wst_z_violation(c"rsv1 on ping", cfg, 1000, c"c1 07 f2 48 cd c9 c9 07 00 c9 00", 1, proto, 1002)
	wst_z_violation(c"rsv1 on continuation", cfg, 1000, c"41 03 f2 48 cd c0 04 c9 c9 07 00", 0, proto, 1002)
	wst_z_violation(c"rsv1 on close", cfg, 1000, c"c8 02 03 e8", 0, proto, 1002)
	wst_z_violation(c"rsv2", cfg, 1000, c"a1 00", 0, proto, 1002)
	# A compressed message split over fragments is fine.
	wst_z_violation(c"fragmented compressed", cfg, 1000, c"41 03 f2 48 cd 80 04 c9 c9 07 00 c3 00", 1, proto, 1002)
	# Data that does not inflate: a reserved block type, a stored block
	# with a bad NLEN, a back-reference before any output.
	wst_z_violation(c"reserved btype", cfg, 1000, c"c1 01 ff", 0, bad, 1007)
	wst_z_violation(c"bad stored length", cfg, 1000, c"c1 05 00 05 00 00 00", 0, bad, 1007)
	wst_z_violation(c"distance before window", cfg, 1000, c"c1 05 f2 00 11 00 00", 0, bad, 1007)
	# Decompressed size over the cap fails closed with 1009 (the frame
	# itself is under the cap).
	wst_z_violation(c"inflates past cap", cfg, 50, c"c1 06 4a 4c a4 3d 00 00", 0, ws_error_too_big(), 1009)
	wst_z_violation(c"inflates to the cap", cfg, 100, c"c1 06 4a 4c a4 3d 00 00 c3 00", 1, proto, 1002)
	# Compressed text must still be UTF-8.
	wst_z_violation(c"compressed bad utf-8", cfg, 1000, c"c1 04 3a ac 01 00", 0, ws_error_bad_utf8(), 1007)
	# The server promised no context takeover: its second "Hello" may not
	# reach back into the first message.
	ws_deflate_config* snct = wst_cfg(1, 0, 0, 0)
	wst_z_violation(c"takeover after server_no_context_takeover", snct, 1000, c"c1 07 f2 48 cd c9 c9 07 00 c1 05 f2 00 11 00 00", 1, bad, 1007)
	free(snct)
	free(cfg)


# A 600-byte message with no repeated 3-byte substring, then a message
# whose back-reference reaches 600 bytes back into it: legal for a 2^15
# window, a violation for 2^8.
void test_ws_deflate_window_bits_enforced():
	wst_use_deflate()
	char* first = malloc(600)
	int i = 0
	while (i < 300):
		first[2 * i] = i & 255
		first[2 * i + 1] = i >> 8
		i = i + 1
	int n1 = 0
	char* z1 = deflate_window(first, 600, 0, 0, 15, 1, &n1)
	int n2 = 0
	char* z2 = deflate_window(first, 20, first, 600, 15, 1, &n2)
	asserts(c"second is a back-reference", n2 < 16)
	string_builder* raw = string_new()
	ws_frame_encode_rsv(raw, 1, 4, ws_op_binary(), z1, n1 - 4, 0)
	ws_frame_encode_rsv(raw, 1, 4, ws_op_binary(), z2, n2 - 4, 0)
	string_append(raw, c"\x88\x02\x03\xe8")
	# Server window 15: both messages, then the peer's close (echoed).
	ws_deflate_config* wide = wst_cfg(0, 0, 15, 0)
	wst_violation_bytes(c"window 15", 1, 100000, wide, raw.data, raw.length, 2, ws_error_closed(), 1000)
	# Server window 8: the second message reaches too far.
	ws_deflate_config* narrow = wst_cfg(0, 0, 8, 0)
	wst_violation_bytes(c"window 8", 1, 100000, narrow, raw.data, raw.length, 1, ws_error_compression(), 1007)
	free(wide)
	free(narrow)
	string_free(raw)
	free(z1)
	free(z2)
	free(first)
