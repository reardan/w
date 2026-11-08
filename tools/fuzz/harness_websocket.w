# wbuild: target=wfuzz_websocket_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/websocket/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_websocket.w -o bin/wfuzz_websocket_harness"
# wbuild: step="rm -rf bin/wfuzz_websocket_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_websocket_harness --bytes --ext .ws --max-len 70000 --corpus tools/fuzz/seeds/websocket --out bin/wfuzz_websocket_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_websocket tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_websocket.w -o bin/wfuzz_websocket_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_websocket_harness --bytes --ext .ws --max-len 70000 --corpus tools/fuzz/seeds/websocket --out bin/wfuzz_websocket" timeout=3600000
# Fuzz harness for libs/standard/web/websocket.w (issue #909). Each input
# is used three ways:
#   - the pure codec: ws_frame_decode walks it frame by frame (masked
#     payloads unmasked in place, on a copy), and every decoded frame
#     must re-encode with ws_frame_encode_rsv -- same FIN, RSV, opcode,
#     payload and masking key -- to exactly the bytes it was decoded
#     from (lengths are always minimal: the decoder rejects anything
#     else). Unmasking twice must restore the payload, and a header
#     ws_parse_header accepts must also pass with RSV1 allowed;
#   - a connection: the bytes arrive on a socketpair wrapped by
#     ws_conn_wrap (no handshake), read with ws_recv until the session
#     ends. The role follows the first frame: masked means the peer is a
#     client, so we are the server. RSV1 on the first frame turns
#     permessage-deflate on (ws_use_deflate with libs/extras/compress),
#     so compressed messages are inflated against the receive window.
#     The message cap is 64 KiB. Every message must be text or binary,
#     within the cap, NUL-terminated, and valid UTF-8 when text; the
#     library's replies (pongs, the close echo) land in the unread
#     socket buffer;
#   - Sec-WebSocket-Extensions text (up to the first NUL): ws_pmd_negotiate
#     as a server with the default policy; an accepted offer must agree
#     window bits in 8..15, and its response element must be accepted by
#     ws_pmd_accept_response for a client with the default configuration.
# Seeds are hand-built frames mirroring websocket_test.w's cases: masked
# and unmasked text/binary, fragmentation with interleaved pings, the
# 16- and 64-bit length forms, close frames, a permessage-deflate
# message, and extension offers.
import tools.fuzz.harness
import lib.net
import lib.utf8
import libs.standard.web.websocket
import libs.extras.compress.inflate
import libs.extras.compress.deflate


const int fh_ws_max_message = 65536
const int fh_ws_max_messages = 64


void fh_ws_codec(char* data, int length):
	char* buf = cast(char*, malloc(length + 1))
	mem_copy(buf, data, length)
	int pos = 0
	int running = 1
	while (running && (pos < length)):
		ws_frame f
		int n = ws_frame_decode(buf + pos, length - pos, &f, 1 << 20)
		if (n <= 0): running = 0
		else:
			fh_check(n == f.header_len + f.payload_len, c"ws_frame_decode consumed the wrong byte count")
			fh_check(f.rsv == 0, c"ws_frame_decode accepted RSV bits")
			char* mask = 0
			if (f.mask_offset >= 0): mask = data + pos + f.mask_offset
			string_builder* sb = string_new()
			fh_check(ws_frame_encode_rsv(sb, f.fin, f.rsv, f.opcode, f.payload, f.payload_len, mask), c"a decoded frame does not re-encode")
			fh_check((sb.length == n) && fh_bytes_equal(sb.data, data + pos, n), c"frame decode then encode changed the bytes")
			string_free(sb)
			if (mask != 0):
				char* copy = cast(char*, malloc(f.payload_len + 1))
				mem_copy(copy, f.payload, f.payload_len)
				ws_mask_bytes(copy, f.payload_len, mask)
				ws_mask_bytes(copy, f.payload_len, mask)
				fh_check(fh_bytes_equal(copy, f.payload, f.payload_len), c"masking twice did not restore the payload")
				free(copy)
			ws_frame g
			fh_check(ws_parse_header_rsv(data + pos, f.header_len, &g, 1 << 20, 4) == 0, c"RSV1-allowed parse rejected a valid header")
			fh_check((g.payload_len == f.payload_len) && (g.opcode == f.opcode) && (g.mask_offset == f.mask_offset), c"RSV1-allowed parse disagrees")
			pos = pos + n
	free(buf)


int fh_ws_session(char* data, int length):
	if (length < 2): return 1
	int[2] fds
	if (socket_pair(&fds[0]) < 0):
		println2(c"harness: socketpair failed")
		exit(2)
	int sent = 0
	while (sent < length):
		int w = write(fds[1], data + sent, length - sent)
		if (w <= 0):
			println2(c"harness: socket write failed")
			exit(2)
		sent = sent + w
	io_result r
	socket_shutdown_checked(fds[1], 1, &r)
	int is_client = (data[1] & 128) == 0
	ws_conn* c = ws_conn_wrap(connection_context_new(fds[0], 2000, 0), is_client, 1)
	ws_set_max_message(c, fh_ws_max_message)
	if ((data[0] & 64) != 0):
		fh_check(ws_use_deflate(deflate_window, inflate_window), c"ws_use_deflate refused the compress codecs")
		ws_deflate_config* cfg = ws_deflate_config_new()
		fh_check(ws_set_compression(c, cfg), c"ws_set_compression refused the default config")
		free(cfg)
	int messages = 0
	int running = 1
	while (running && (messages < fh_ws_max_messages)):
		ws_message* m = ws_recv(c)
		if (m == 0): running = 0
		else:
			fh_check((m.opcode == ws_op_text) || (m.opcode == ws_op_binary), c"ws_recv returned a non-data message")
			fh_check((m.len >= 0) && (m.len <= fh_ws_max_message), c"message above the cap")
			fh_check(m.data[m.len] == 0, c"message not NUL-terminated")
			if (m.opcode == ws_op_text): fh_check(utf8_validate_bytes(m.data, m.len), c"text message is not UTF-8")
			ws_message_free(m)
			messages = messages + 1
	ws_conn_free(c)
	close(fds[1])
	return messages


void fh_ws_extensions(char* data):
	ws_deflate_config* cfg = ws_deflate_config_new()
	ws_pmd_params agreed
	char* response = ws_pmd_negotiate(data, cfg, &agreed)
	if (response != 0):
		fh_check((agreed.server_max_window_bits >= 8) && (agreed.server_max_window_bits <= 15), c"negotiated server window bits out of range")
		fh_check((agreed.client_max_window_bits >= 8) && (agreed.client_max_window_bits <= 15), c"negotiated client window bits out of range")
		ws_pmd_params client
		fh_check(ws_pmd_accept_response(response, cfg, &client), c"a default client rejects our own server's response")
		free(response)
	ws_pmd_params ignored
	ws_pmd_accept_response(data, cfg, &ignored)
	free(cfg)


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	fh_ws_codec(data, length)
	fh_ws_extensions(data)
	if (fh_ws_session(data, length) > 0): return 0
	return 1
