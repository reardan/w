# WebSocket (RFC 6455) client + server for the pure-W web stack (issue
# #436 "Protocols"). The opening handshake rides on the existing HTTP/1.1
# pieces -- libs/standard/web/http_client.w's connect/TLS/request writer
# for ws:// and wss:// clients, libs/standard/web/http_server.w's parsed
# ServerRequest + ConnectionContext for servers -- and every upgraded
# connection, client or server, then speaks frames over one
# libs/standard/web/connection.w ConnectionContext (blocking socket with
# SO_RCVTIMEO/SO_SNDTIMEO, optional TLS).
#
# SHA-1 (the Sec-WebSocket-Accept digest). RFC 6455 section 4 hard-codes
# base64(SHA-1(key + GUID)). SHA-1 is quarantined in libs/x/unsafe and
# nothing under libs/standard may import it (unsafe_import_test), so this
# module follows the same seam libs/standard/crypto/hmac.w uses for
# legacy HMAC-SHA1: the digest is looked up through the whash registry
# of libs/standard/crypto/sha2.w, and the APPLICATION (a leaf program,
# never a libs/standard module) imports libs/x/unsafe/sha1.w and opts in
# once with
#
#	ws_use_sha1(WHASH_SHA1())
#
# (libs/x/unsafe/websocket_sha1_test.w is the worked example).
# ws_use_sha1 refuses anything that is not a registered 20-byte whash
# extension producing the RFC 6455 section 1.3 known answer, and every
# handshake fails closed (ws_error_no_sha1; a server answers 500) until it
# has been called. The accept value is a protocol-confusion guard, not a
# security property, so SHA-1's broken collision resistance is harmless
# here -- but the opt-in keeps the "legacy crypto is explicit" rule.
#
# Public API:
#   int   ws_use_sha1(int whash_alg)            1 = accepted
#   char* ws_accept_key(char* key)              malloc'd, 0 without SHA-1
#
#   ws_conn* ws_connect(char* url)              ws:// or wss://; never 0
#   ws_conn* ws_open(http_req* req)             same, with req's headers,
#                                               timeout and TLS knobs
#   ws_conn* ws_accept(RequestContext* rc, char* subprotocol)   never 0
#   ws_conn* ws_server_accept(ConnectionContext* cc, ServerRequest* req, char* subprotocol)
#   int      ws_request_offers_protocol(ServerRequest* req, char* protocol)
#   ws_conn* ws_conn_wrap(ConnectionContext* cc, int is_client, int owns_cc)
#
#   ws_message* ws_recv(ws_conn* c)             next text/binary message or 0
#   int ws_send_text(ws_conn* c, char* data, int len)     1 = sent
#   int ws_send_binary(ws_conn* c, char* data, int len)
#   int ws_send_ping(ws_conn* c, char* data, int len)
#   int ws_send_pong(ws_conn* c, char* data, int len)
#   int ws_send_frame(ws_conn* c, int fin, int opcode, char* data, int len)
#   int ws_close(ws_conn* c, int code, char* reason)      1 = clean handshake
#   void ws_set_timeout(ws_conn* c, int timeout_ms)
#   void ws_set_max_message(ws_conn* c, int max_bytes)
#   int  ws_conn_error(ws_conn* c)  /  char* ws_error_string(int code)
#   void ws_conn_free(ws_conn* c)  /  void ws_message_free(ws_message* m)
#
#   int ws_frame_encode(string_builder* out, int fin, int opcode, char* payload, int len, char* mask_key)
#   int ws_frame_decode(char* buf, int len, ws_frame* f, int max_payload)
#   int ws_op_*()  /  int ws_close_*()  /  int ws_error_*()
#
# Behavior notes:
# - Frames: FIN + the six RFC opcodes; RSV bits (no extension is ever
#   negotiated) and reserved opcodes fail the connection with 1002.
#   Payload lengths use the 7-bit, 16-bit and 64-bit encodings; the
#   64-bit form is accepted only when it fits in 31 bits (so it means
#   the same thing on the 32-bit x86 target as on 64-bit ones) and within
#   the size cap -- anything larger fails closed with 1009, a set MSB or a
#   non-minimal length encoding with 1002.
# - Masking: clients mask every frame with a fresh random key
#   (libs/standard/crypto/random.w); a server rejects unmasked frames and
#   a client rejects masked ones (1002).
# - Messages: fragmented messages are reassembled (control frames may be
#   interleaved), capped by ws_set_max_message (default 16 MiB, 1009 when
#   exceeded), and text messages must be valid UTF-8 (lib/utf8.w, 1007).
#   ws_send_text refuses invalid UTF-8 instead of sending it.
# - Control frames: pings are answered with a pong carrying the same
#   payload automatically inside ws_recv; pongs are counted and dropped.
#   Control frames must be final and carry at most 125 bytes.
# - Closing: a received close frame is validated (status code range,
#   UTF-8 reason), echoed with the same status code, and ends ws_recv
#   (returns 0 with ws_conn_error == ws_error_closed()). ws_close sends
#   our close frame and reads until the peer's close arrives. A protocol
#   violation "fails the connection": a close frame with the matching
#   status is sent (best effort) and the connection is marked broken.
# - Timeouts: every blocking read/write is bounded by the connection's
#   timeout (the http_req timeout for clients, 30s by default; the
#   server's for accepted connections; ws_set_timeout changes it, 0
#   disables it). A timeout at a frame boundary returns 0 from ws_recv
#   with ws_error_timeout() and leaves the connection usable; mid-frame
#   it is fatal.
# - ws_accept integrates with http_server.w routes: call it from a
#   request_handler_fn, run the session inside the handler, and return;
#   the upgraded connection is closed when the handler returns (the
#   RequestContext is marked as already responded, keep-alive off).
#   Validation failures answer 400 (426 + Sec-WebSocket-Version: 13 for
#   an unsupported version, 500 without SHA-1) and return a failed conn.
#
# Ownership: ws_connect/ws_open conns own their transport; server conns
# borrow the ConnectionContext (the server destroys it). A ws_message is
# owned by the caller (ws_message_free). Every ws_conn is released with
# ws_conn_free.
import lib.lib
import lib.str
import lib.net
import lib.stream
import lib.utf8
import structures.string
import libs.standard.crypto.base64
import libs.standard.crypto.random
import libs.standard.crypto.sha2
import libs.standard.web.connection
import libs.standard.web.urlparse
import libs.standard.web.http_client
import libs.standard.web.http_server
import libs.standard.net.dns
import libs.standard.net.tls


# One decoded frame header (+ payload once read). mask_offset is where
# the 4-byte masking key sits inside the header bytes (-1 when the frame
# is unmasked); payload points into the decode buffer for
# ws_frame_decode and is a malloc'd, NUL-terminated copy for frames read
# off a connection.
struct ws_frame:
	int fin
	int rsv
	int opcode
	int masked
	int mask_offset
	int header_len
	int payload_len
	char* payload


# One complete data message. opcode is ws_op_text() or ws_op_binary();
# data is malloc'd and NUL-terminated one byte past len.
struct ws_message:
	int opcode
	char* data
	int len


# One upgraded connection. cc is the frame transport; owns_cc says
# whether ws_conn_free destroys it (clients) or leaves it to the server.
# tls_cfg is the client-side TLS config the tls_conn inside cc borrows.
# broken marks a failed connection (no further I/O). frag/frag_opcode
# reassemble a fragmented message (frag_opcode 0 = none in progress).
# hdr is scratch for one frame header (at most 14 bytes).
struct ws_conn:
	ConnectionContext* cc
	int owns_cc
	tls_config* tls_cfg
	int is_client
	int error
	int broken
	int close_sent
	int close_received
	int local_close_code
	int peer_close_code
	char* peer_close_reason
	int max_message
	string_builder* frag
	int frag_opcode
	char* hdr
	char* subprotocol
	int http_status
	int pings_received
	int pongs_received


/* Opcodes (RFC 6455 section 5.2) */

int ws_op_continuation():
	return 0


int ws_op_text():
	return 1


int ws_op_binary():
	return 2


int ws_op_close():
	return 8


int ws_op_ping():
	return 9


int ws_op_pong():
	return 10


/* Close status codes (RFC 6455 section 7.4.1) */

int ws_close_normal():
	return 1000


int ws_close_going_away():
	return 1001


int ws_close_protocol_error():
	return 1002


int ws_close_unsupported():
	return 1003


# Reserved: "no status code was present" (never sent on the wire).
int ws_close_no_status():
	return 1005


# Reserved: "closed without a close frame" (never sent on the wire).
int ws_close_abnormal():
	return 1006


int ws_close_invalid_payload():
	return 1007


int ws_close_policy():
	return 1008


int ws_close_too_big():
	return 1009


int ws_close_internal_error():
	return 1011


/* Error codes reported by ws_conn_error */

int ws_error_none():
	return 0


# The closing handshake completed (not a failure: the peer said goodbye).
int ws_error_closed():
	return 1


int ws_error_bad_url():
	return 2


# A caller-supplied handshake header was invalid or reserved.
int ws_error_bad_request():
	return 3


int ws_error_dns():
	return 4


int ws_error_connect():
	return 5


int ws_error_tls():
	return 6


int ws_error_io():
	return 7


int ws_error_timeout():
	return 8


# The peer's opening handshake was not a valid WebSocket upgrade.
int ws_error_handshake():
	return 9


# ws_use_sha1 was never called (or refused its argument).
int ws_error_no_sha1():
	return 10


# Frame-level protocol violation by the peer (close 1002).
int ws_error_protocol():
	return 11


# Text message or close reason that is not UTF-8 (close 1007).
int ws_error_bad_utf8():
	return 12


# Frame or message over the size cap (close 1009).
int ws_error_too_big():
	return 13


# The transport ended without a close frame (1006).
int ws_error_eof():
	return 14


char* ws_error_string(int code):
	if (code == ws_error_none()):
		return c""
	if (code == ws_error_closed()):
		return c"connection closed"
	if (code == ws_error_bad_url()):
		return c"invalid websocket URL"
	if (code == ws_error_bad_request()):
		return c"invalid handshake header"
	if (code == ws_error_dns()):
		return c"DNS lookup failed"
	if (code == ws_error_connect()):
		return c"connect failed"
	if (code == ws_error_tls()):
		return c"TLS handshake failed"
	if (code == ws_error_io()):
		return c"send or receive failed"
	if (code == ws_error_timeout()):
		return c"timed out"
	if (code == ws_error_handshake()):
		return c"invalid websocket handshake"
	if (code == ws_error_no_sha1()):
		return c"SHA-1 not configured (ws_use_sha1)"
	if (code == ws_error_protocol()):
		return c"websocket protocol error"
	if (code == ws_error_bad_utf8()):
		return c"invalid UTF-8 in text frame"
	if (code == ws_error_too_big()):
		return c"message too big"
	if (code == ws_error_eof()):
		return c"connection closed without close frame"
	return c"unknown error"


/* Limits */

# Default cap on one reassembled message (and so on one frame).
int ws_default_max_message():
	return 16777216


# Largest length ws_frame_encode will write (fits every target's int).
int ws_max_encodable():
	return 2147483647


# Frames ws_close discards while waiting for the peer's close frame.
int ws_close_drain_frames():
	return 1024


# Cap on the handshake response header block a client accepts.
int ws_max_handshake_bytes():
	return 65536


/* SHA-1 opt-in and the accept key */

# whash algorithm id of the application-registered SHA-1 (0 = none).
int ws_sha1_alg


char* ws_guid():
	return c"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# base64(SHA-1(key + GUID)) with an explicit algorithm id.
char* ws_accept_key_with(int alg, char* key):
	char* joined = strjoin(key, ws_guid())
	char* digest = malloc(20)
	whash_oneshot(alg, joined, strlen(joined), digest)
	char* out = base64_encode(digest, 20)
	free(digest)
	free(joined)
	return out


# Opts this process into the handshake digest: alg must be a registered
# whash extension (id >= 100) with a 20-byte digest that reproduces the
# RFC 6455 section 1.3 example. Returns 1 when accepted, 0 otherwise
# (the previous setting is kept).
int ws_use_sha1(int alg):
	if (alg < 100):
		return 0
	if (whash_ext_find(alg) == 0):
		return 0
	if (whash_digest_size(alg) != 20):
		return 0
	char* probe = ws_accept_key_with(alg, c"dGhlIHNhbXBsZSBub25jZQ==")
	int ok = strcmp(probe, c"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") == 0
	free(probe)
	if (ok == 0):
		return 0
	ws_sha1_alg = alg
	return 1


# Sec-WebSocket-Accept for a Sec-WebSocket-Key (RFC 6455 section 4.2.2).
# malloc'd 28-character string, or 0 when ws_use_sha1 was never called.
char* ws_accept_key(char* key):
	if (ws_sha1_alg == 0):
		return 0
	return ws_accept_key_with(ws_sha1_alg, key)


# A fresh Sec-WebSocket-Key: base64 of 16 random bytes (malloc'd), or 0
# when the CSPRNG fails.
char* ws_new_key():
	char* nonce = malloc(16)
	if (random_bytes(nonce, 16) == 0):
		free(nonce)
		return 0
	char* key = base64_encode(nonce, 16)
	free(nonce)
	return key


/* Frame codec (pure: no I/O) */

int ws_is_control(int opcode):
	return opcode >= 8


int ws_opcode_known(int opcode):
	if ((opcode >= 0) && (opcode <= 2)):
		return 1
	if ((opcode >= 8) && (opcode <= 10)):
		return 1
	return 0


# Total header bytes implied by the second header byte.
int ws_header_length(int b1):
	int n = 2
	int len7 = b1 & 127
	if (len7 == 126):
		n = n + 2
	else if (len7 == 127):
		n = n + 8
	if ((b1 & 128) != 0):
		n = n + 4
	return n


# XORs len bytes at data with the 4-byte key (RFC 6455 section 5.3).
void ws_mask_bytes(char* data, int len, char* key):
	int i = 0
	while (i < len):
		data[i] = (data[i] & 255) ^ (key[i & 3] & 255)
		i = i + 1


# Parses a complete header of hlen bytes (ws_header_length). Returns 0,
# or the close status the violation calls for: 1002 for RSV bits,
# reserved opcodes, fragmented or oversized control frames, a set 64-bit
# MSB, or a non-minimal length; 1009 when a data frame's payload exceeds
# max_payload or does not fit in 31 bits.
int ws_parse_header(char* h, int hlen, ws_frame* f, int max_payload):
	int b0 = h[0] & 255
	int b1 = h[1] & 255
	f.fin = (b0 >> 7) & 1
	f.rsv = (b0 >> 4) & 7
	f.opcode = b0 & 15
	f.masked = (b1 >> 7) & 1
	f.header_len = hlen
	f.mask_offset = (-1)
	f.payload_len = 0
	f.payload = 0
	if (f.rsv != 0):
		return ws_close_protocol_error()
	if (ws_opcode_known(f.opcode) == 0):
		return ws_close_protocol_error()
	int len7 = b1 & 127
	int control = ws_is_control(f.opcode)
	if (control != 0):
		if (f.fin == 0):
			return ws_close_protocol_error()
		if (len7 > 125):
			return ws_close_protocol_error()
	int length = len7
	int at = 2
	if (len7 == 126):
		length = ((h[2] & 255) << 8) | (h[3] & 255)
		if (length < 126):
			return ws_close_protocol_error()
		at = 4
	else if (len7 == 127):
		if ((h[2] & 128) != 0):
			return ws_close_protocol_error()
		# Only 31-bit lengths are representable on every target: the top
		# four bytes must be zero and the fifth below 0x80.
		if (((h[2] & 255) | (h[3] & 255) | (h[4] & 255) | (h[5] & 255)) != 0):
			return ws_close_too_big()
		if ((h[6] & 128) != 0):
			return ws_close_too_big()
		length = ((h[6] & 255) << 24) | ((h[7] & 255) << 16) | ((h[8] & 255) << 8) | (h[9] & 255)
		if (length < 65536):
			return ws_close_protocol_error()
		at = 10
	if (f.masked != 0):
		f.mask_offset = at
	if (control == 0):
		if (length > max_payload):
			return ws_close_too_big()
	f.payload_len = length
	return 0


# Decodes one frame from buf[0..len). Returns the bytes consumed (> 0),
# 0 when more input is needed, or the negated close status for a
# protocol violation (see ws_parse_header). A masked payload is unmasked
# IN PLACE; f.payload points into buf.
int ws_frame_decode(char* buf, int len, ws_frame* f, int max_payload):
	if (len < 2):
		return 0
	int hlen = ws_header_length(buf[1] & 255)
	if (len < hlen):
		return 0
	int code = ws_parse_header(buf, hlen, f, max_payload)
	if (code != 0):
		return 0 - code
	if (len - hlen < f.payload_len):
		return 0
	f.payload = buf + hlen
	if (f.mask_offset >= 0):
		ws_mask_bytes(f.payload, f.payload_len, buf + f.mask_offset)
	return hlen + f.payload_len


# Appends one encoded frame to out. mask_key is 4 bytes (a client frame)
# or 0 (a server frame). Always uses the minimal length encoding.
# Returns 1, or 0 for a negative or unencodable length or opcode.
int ws_frame_encode(string_builder* out, int fin, int opcode, char* payload, int len, char* mask_key):
	if ((len < 0) || (len > ws_max_encodable())):
		return 0
	if ((opcode < 0) || (opcode > 15)):
		return 0
	int b0 = opcode
	if (fin != 0):
		b0 = b0 | 128
	int mask_bit = 0
	if (mask_key != 0):
		mask_bit = 128
	string_append_char(out, b0)
	if (len < 126):
		string_append_char(out, mask_bit | len)
	else if (len < 65536):
		string_append_char(out, mask_bit | 126)
		string_append_char(out, (len >> 8) & 255)
		string_append_char(out, len & 255)
	else:
		string_append_char(out, mask_bit | 127)
		string_append_char(out, 0)
		string_append_char(out, 0)
		string_append_char(out, 0)
		string_append_char(out, 0)
		string_append_char(out, (len >> 24) & 255)
		string_append_char(out, (len >> 16) & 255)
		string_append_char(out, (len >> 8) & 255)
		string_append_char(out, len & 255)
	if (mask_key != 0):
		string_append_bytes(out, mask_key, 4)
	int start = out.length
	if (len > 0):
		string_append_bytes(out, payload, len)
	if (mask_key != 0):
		ws_mask_bytes(out.data + start, len, mask_key)
	return 1


# Whether a received close frame may carry this status (RFC 6455
# section 7.4: the registered sendable codes plus the 3000-4999
# registered/private range; 1004-1006 and 1015 are never on the wire).
int ws_close_code_valid(int code):
	if ((code >= 1000) && (code <= 1003)):
		return 1
	if ((code >= 1007) && (code <= 1014)):
		return 1
	if ((code >= 3000) && (code <= 4999)):
		return 1
	return 0


/* Connection lifecycle */

ws_conn* ws_conn_new():
	ws_conn* c = new ws_conn()
	c.cc = 0
	c.owns_cc = 0
	c.tls_cfg = 0
	c.is_client = 0
	c.error = 0
	c.broken = 0
	c.close_sent = 0
	c.close_received = 0
	c.local_close_code = 0
	c.peer_close_code = 0
	c.peer_close_reason = 0
	c.max_message = ws_default_max_message()
	c.frag = string_new()
	c.frag_opcode = 0
	c.hdr = malloc(16)
	c.subprotocol = 0
	c.http_status = 0
	c.pings_received = 0
	c.pongs_received = 0
	return c


# A conn that failed before any frame could flow (never 0).
ws_conn* ws_conn_failed(int error):
	ws_conn* c = ws_conn_new()
	c.error = error
	c.broken = 1
	return c


# Wraps an already-upgraded connection (no handshake is performed).
# is_client selects the masking role; owns_cc hands cc to the ws_conn
# (ws_conn_free then destroys it).
ws_conn* ws_conn_wrap(ConnectionContext* cc, int is_client, int owns_cc):
	ws_conn* c = ws_conn_new()
	c.cc = cc
	c.is_client = is_client
	c.owns_cc = owns_cc
	return c


void ws_conn_free(ws_conn* c):
	if (c == 0):
		return
	if ((c.owns_cc != 0) && (c.cc != 0)):
		connection_context_destroy(c.cc)
	if (c.tls_cfg != 0):
		tls_config_free(c.tls_cfg)
	string_free(c.frag)
	free(c.hdr)
	if (c.peer_close_reason != 0):
		free(c.peer_close_reason)
	if (c.subprotocol != 0):
		free(c.subprotocol)
	free(c)


void ws_message_free(ws_message* m):
	if (m == 0):
		return
	free(m.data)
	free(m)


int ws_conn_error(ws_conn* c):
	return c.error


# Bounds every later blocking read/write (0 disables the bound).
void ws_set_timeout(ws_conn* c, int timeout_ms):
	if (c.cc == 0):
		return
	c.cc.timeout_ms = timeout_ms
	socket_set_recv_timeout(c.cc.fd, timeout_ms)
	socket_set_send_timeout(c.cc.fd, timeout_ms)


void ws_set_max_message(ws_conn* c, int max_bytes):
	if (max_bytes > 0):
		c.max_message = max_bytes


/* Transport */

# Reads exactly n bytes: 1, 0 on EOF, -1 on a transport error, -2 on a
# timeout.
int ws_read_exact(ws_conn* c, char* out, int n):
	if (n <= 0):
		return 1
	if (connection_context_read_exact(c.cc, out, n) != 0):
		return 1
	if (c.cc.error == connection_error_timeout()):
		return (-2)
	if (c.cc.error != 0):
		return (-1)
	return 0


# Marks the connection broken after a transport failure (r from
# ws_read_exact, or -1 for a failed write).
void ws_transport_failed(ws_conn* c, int r):
	c.broken = 1
	if (r == (-2)):
		c.error = ws_error_timeout()
	else if (r == 0):
		c.error = ws_error_eof()
	else:
		c.error = ws_error_io()


# Encodes and writes one frame, masking it in the client role. Returns
# 1, or 0 with the connection marked broken.
int ws_write_frame(ws_conn* c, int fin, int opcode, char* data, int len):
	string_builder* out = string_new_sized(len + 16)
	char* key = 0
	if (c.is_client != 0):
		key = malloc(4)
		if (random_bytes(key, 4) == 0):
			free(key)
			string_free(out)
			c.broken = 1
			c.error = ws_error_io()
			return 0
	int ok = ws_frame_encode(out, fin, opcode, data, len, key)
	if (key != 0):
		free(key)
	if (ok != 0):
		ok = connection_context_write_all(c.cc, out.data, out.length)
		if (ok == 0):
			if (c.cc.error == connection_error_timeout()):
				ws_transport_failed(c, (-2))
			else:
				ws_transport_failed(c, (-1))
	string_free(out)
	return ok


# Writes a close frame carrying code (0 = no status) and reason.
int ws_write_close(ws_conn* c, int code, char* reason, int reason_len):
	string_builder* body = string_new()
	if (code != 0):
		string_append_char(body, (code >> 8) & 255)
		string_append_char(body, code & 255)
		if (reason_len > 0):
			string_append_bytes(body, reason, reason_len)
	int ok = ws_write_frame(c, 1, ws_op_close(), body.data, body.length)
	string_free(body)
	c.close_sent = 1
	return ok


# "Fail the WebSocket connection" (RFC 6455 section 7.1.7): send a
# close frame with close_code unless one already went out, then mark the
# connection broken with error.
void ws_fail(ws_conn* c, int close_code, int error):
	if ((c.broken == 0) && (c.close_sent == 0)):
		ws_write_close(c, close_code, 0, 0)
	c.local_close_code = close_code
	c.broken = 1
	c.error = error


int ws_error_for_close(int close_code):
	if (close_code == ws_close_invalid_payload()):
		return ws_error_bad_utf8()
	if (close_code == ws_close_too_big()):
		return ws_error_too_big()
	return ws_error_protocol()


# Reads one frame off the connection into f (payload malloc'd and
# unmasked). Returns 1, or 0 with the connection failed -- except a
# timeout before the first header byte, which leaves it usable.
int ws_read_frame(ws_conn* c, ws_frame* f, int max_payload):
	char* h = c.hdr
	int r = ws_read_exact(c, h, 1)
	if (r == (-2)):
		c.error = ws_error_timeout()
		return 0
	if (r != 1):
		ws_transport_failed(c, r)
		return 0
	r = ws_read_exact(c, h + 1, 1)
	if (r != 1):
		ws_transport_failed(c, r)
		return 0
	int hlen = ws_header_length(h[1] & 255)
	r = ws_read_exact(c, h + 2, hlen - 2)
	if (r != 1):
		ws_transport_failed(c, r)
		return 0
	if (max_payload < 0):
		max_payload = 0
	int code = ws_parse_header(h, hlen, f, max_payload)
	if (code != 0):
		ws_fail(c, code, ws_error_for_close(code))
		return 0
	if ((c.is_client != 0) && (f.masked != 0)):
		ws_fail(c, ws_close_protocol_error(), ws_error_protocol())
		return 0
	if ((c.is_client == 0) && (f.masked == 0)):
		ws_fail(c, ws_close_protocol_error(), ws_error_protocol())
		return 0
	char* payload = malloc(f.payload_len + 1)
	r = ws_read_exact(c, payload, f.payload_len)
	if (r != 1):
		free(payload)
		ws_transport_failed(c, r)
		return 0
	payload[f.payload_len] = 0
	if (f.mask_offset >= 0):
		ws_mask_bytes(payload, f.payload_len, h + f.mask_offset)
	f.payload = payload
	return 1


# Handles a received close frame (payload freed here). Validates it,
# records the peer's status/reason, echoes the status unless we already
# sent our close, and ends the session. Always returns 0 (ws_recv's
# "no message").
int ws_handle_close(ws_conn* c, ws_frame* f):
	char* p = f.payload
	int len = f.payload_len
	int code = ws_close_no_status()
	if (len == 1):
		free(p)
		ws_fail(c, ws_close_protocol_error(), ws_error_protocol())
		return 0
	if (len >= 2):
		code = ((p[0] & 255) << 8) | (p[1] & 255)
		if (ws_close_code_valid(code) == 0):
			free(p)
			ws_fail(c, ws_close_protocol_error(), ws_error_protocol())
			return 0
		if (utf8_validate_bytes(p + 2, len - 2) == 0):
			free(p)
			ws_fail(c, ws_close_invalid_payload(), ws_error_bad_utf8())
			return 0
	c.close_received = 1
	c.peer_close_code = code
	if (c.peer_close_reason != 0):
		free(c.peer_close_reason)
	if (len > 2):
		c.peer_close_reason = substring(p, 2, len)
	else:
		c.peer_close_reason = strclone(c"")
	free(p)
	if (c.close_sent == 0):
		if (code == ws_close_no_status()):
			ws_write_close(c, 0, 0, 0)
		else:
			ws_write_close(c, code, 0, 0)
	if (c.broken == 0):
		c.error = ws_error_closed()
	return 0


ws_message* ws_message_new(int opcode, char* data, int len):
	ws_message* m = new ws_message()
	m.opcode = opcode
	m.data = data
	m.len = len
	return m


# Finishes a data message: text must be UTF-8. Returns the message, or
# 0 with the connection failed (data freed).
ws_message* ws_finish_message(ws_conn* c, int opcode, char* data, int len):
	if (opcode == ws_op_text()):
		if (utf8_validate_bytes(data, len) == 0):
			free(data)
			ws_fail(c, ws_close_invalid_payload(), ws_error_bad_utf8())
			return 0
	return ws_message_new(opcode, data, len)


# Next complete text or binary message, answering pings and dropping
# pongs along the way. Returns 0 when the session is over (clean close:
# ws_conn_error == ws_error_closed(); otherwise the failure) or on a
# recoverable frame-boundary timeout (ws_error_timeout()).
ws_message* ws_recv(ws_conn* c):
	if (c == 0):
		return 0
	if ((c.broken != 0) || (c.close_received != 0) || (c.cc == 0)):
		return 0
	if (c.error == ws_error_timeout()):
		c.error = 0
	c.cc.error = 0
	while (1):
		ws_frame f
		int room = c.max_message
		if (c.frag_opcode != 0):
			room = c.max_message - c.frag.length
		if (ws_read_frame(c, &f, room) == 0):
			return 0
		int op = f.opcode
		if (op == ws_op_ping()):
			c.pings_received = c.pings_received + 1
			int pong_ok = 1
			if (c.close_sent == 0):
				pong_ok = ws_write_frame(c, 1, ws_op_pong(), f.payload, f.payload_len)
			free(f.payload)
			if (pong_ok == 0):
				return 0
		else if (op == ws_op_pong()):
			c.pongs_received = c.pongs_received + 1
			free(f.payload)
		else if (op == ws_op_close()):
			ws_handle_close(c, &f)
			return 0
		else if (op == ws_op_continuation()):
			if (c.frag_opcode == 0):
				free(f.payload)
				ws_fail(c, ws_close_protocol_error(), ws_error_protocol())
				return 0
			string_append_bytes(c.frag, f.payload, f.payload_len)
			free(f.payload)
			if (f.fin != 0):
				int message_op = c.frag_opcode
				string_builder* done = c.frag
				c.frag = string_new()
				c.frag_opcode = 0
				char* data = done.data
				int data_len = done.length
				free(done)
				return ws_finish_message(c, message_op, data, data_len)
		else:
			# text or binary
			if (c.frag_opcode != 0):
				free(f.payload)
				ws_fail(c, ws_close_protocol_error(), ws_error_protocol())
				return 0
			if (f.fin != 0):
				return ws_finish_message(c, op, f.payload, f.payload_len)
			c.frag_opcode = op
			string_clear(c.frag)
			string_append_bytes(c.frag, f.payload, f.payload_len)
			free(f.payload)
	return 0


/* Sending */

# Low-level send of one frame (for fragmentation: a text/binary frame
# with fin 0, then continuation frames). Control frames must be final
# and at most 125 bytes. Returns 1, or 0 when refused or on failure.
int ws_send_frame(ws_conn* c, int fin, int opcode, char* data, int len):
	if (c == 0):
		return 0
	if ((c.broken != 0) || (c.close_sent != 0) || (c.cc == 0)):
		return 0
	if (ws_opcode_known(opcode) == 0):
		return 0
	if (opcode == ws_op_close()):
		return 0
	if (len < 0):
		return 0
	if (ws_is_control(opcode) != 0):
		if ((fin == 0) || (len > 125)):
			return 0
	return ws_write_frame(c, fin, opcode, data, len)


# Sends one unfragmented text message. Refuses (returns 0 without
# touching the connection) text that is not valid UTF-8.
int ws_send_text(ws_conn* c, char* data, int len):
	if (utf8_validate_bytes(data, len) == 0):
		return 0
	return ws_send_frame(c, 1, ws_op_text(), data, len)


int ws_send_binary(ws_conn* c, char* data, int len):
	return ws_send_frame(c, 1, ws_op_binary(), data, len)


int ws_send_ping(ws_conn* c, char* data, int len):
	return ws_send_frame(c, 1, ws_op_ping(), data, len)


int ws_send_pong(ws_conn* c, char* data, int len):
	return ws_send_frame(c, 1, ws_op_pong(), data, len)


# Starts (or completes) the closing handshake: sends a close frame with
# code (0 = no status; otherwise a sendable status, see
# ws_close_code_valid) and reason (0 or at most 123 UTF-8 bytes), then
# reads -- discarding data -- until the peer's close frame arrives.
# Returns 1 when both close frames were exchanged, 0 otherwise.
int ws_close(ws_conn* c, int code, char* reason):
	if (c == 0):
		return 0
	if ((c.broken != 0) || (c.cc == 0)):
		return 0
	if ((c.close_sent != 0) && (c.close_received != 0)):
		return 1
	int reason_len = 0
	if (reason != 0):
		reason_len = strlen(reason)
	if (code != 0):
		if (ws_close_code_valid(code) == 0):
			return 0
		if (reason_len > 123):
			return 0
		if (utf8_validate_bytes(reason, reason_len) == 0):
			return 0
	else if (reason_len > 0):
		return 0
	if (c.close_sent == 0):
		c.local_close_code = code
		if (ws_write_close(c, code, reason, reason_len) == 0):
			return 0
	c.cc.error = 0
	int drained = 0
	while (c.close_received == 0):
		if (drained >= ws_close_drain_frames()):
			ws_fail(c, ws_close_policy(), ws_error_protocol())
			return 0
		ws_frame f
		if (ws_read_frame(c, &f, c.max_message) == 0):
			if (c.broken == 0):
				# A timeout while waiting for the peer's close is fatal here.
				c.broken = 1
			return 0
		if (f.opcode == ws_op_close()):
			ws_handle_close(c, &f)
		else:
			free(f.payload)
		drained = drained + 1
	if (c.broken != 0):
		return 0
	c.error = ws_error_closed()
	return 1


/* Client handshake */

# Whether text starts with prefix, ASCII case-insensitively.
int ws_prefix_ieq(char* text, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (text[i] == 0):
			return 0
		if (http_lower_char(text[i] & 255) != http_lower_char(prefix[i] & 255)):
			return 0
		i = i + 1
	return 1


# "ws://..." / "wss://..." -> the http(s):// form url_parse accepts
# (malloc'd), or 0 for any other scheme.
char* ws_http_url(char* url):
	if (ws_prefix_ieq(url, c"ws://") != 0):
		return strjoin(c"http://", url + 5)
	if (ws_prefix_ieq(url, c"wss://") != 0):
		return strjoin(c"https://", url + 6)
	return 0


# Handshake headers the client owns; caller copies are rejected.
int ws_reserved_header(char* name):
	if (http_str_ieq(name, c"upgrade") != 0):
		return 1
	if (http_str_ieq(name, c"connection") != 0):
		return 1
	if (http_str_ieq(name, c"sec-websocket-key") != 0):
		return 1
	if (http_str_ieq(name, c"sec-websocket-version") != 0):
		return 1
	if (http_str_ieq(name, c"sec-websocket-accept") != 0):
		return 1
	if (http_str_ieq(name, c"sec-websocket-extensions") != 0):
		return 1
	return 0


# Reads the handshake response head into resp. Returns 1, or 0 with the
# ws error in *out_error.
int ws_read_response_head(http_conn* hc, http_response* resp, int* out_error):
	string_builder* line = string_new()
	int got = http_conn_read_line(hc, line, http_error_headers_too_large())
	if (got <= 0):
		string_free(line)
		if (hc.error == http_error_timeout()):
			*out_error = ws_error_timeout()
		else:
			*out_error = ws_error_handshake()
		return 0
	int status = 0
	int minor = 0
	if (http_parse_status_line(line.data, &status, &minor) == 0):
		string_free(line)
		*out_error = ws_error_handshake()
		return 0
	resp.status = status
	int total = 0
	while (1):
		got = http_conn_read_line(hc, line, http_error_headers_too_large())
		if (got <= 0):
			string_free(line)
			if (hc.error == http_error_timeout()):
				*out_error = ws_error_timeout()
			else:
				*out_error = ws_error_handshake()
			return 0
		if (line.length == 0):
			string_free(line)
			return 1
		total = total + line.length + 2
		if (total > ws_max_handshake_bytes()):
			string_free(line)
			*out_error = ws_error_handshake()
			return 0
		if (http_store_header(resp, line.data, line.length) == 0):
			string_free(line)
			*out_error = ws_error_handshake()
			return 0
	return 0


# Validates a 101 response against the key we sent and the protocols we
# offered (0 = none). Returns 1/0.
int ws_validate_response(http_response* resp, char* key, char* offered):
	if (resp.status != 101):
		return 0
	char* upgrade = http_response_header(resp, c"upgrade")
	if (upgrade == 0):
		return 0
	if (http_str_ieq(upgrade, c"websocket") == 0):
		return 0
	char* connection = http_response_header(resp, c"connection")
	if (connection == 0):
		return 0
	if (http_value_has_token(connection, c"upgrade") == 0):
		return 0
	char* accept = http_response_header(resp, c"sec-websocket-accept")
	if (accept == 0):
		return 0
	char* expected = ws_accept_key(key)
	if (expected == 0):
		return 0
	int match = strcmp(expected, accept) == 0
	free(expected)
	if (match == 0):
		return 0
	# No extension was offered, so none may be accepted.
	if (http_response_header(resp, c"sec-websocket-extensions") != 0):
		return 0
	char* proto = http_response_header(resp, c"sec-websocket-protocol")
	if (proto != 0):
		if (offered == 0):
			return 0
		if (http_is_token(proto) == 0):
			return 0
		if (http_value_has_token(offered, proto) == 0):
			return 0
	return 1


# Converts the handshake's http_conn into the frame transport: a
# blocking ConnectionContext (SO_RCVTIMEO/SO_SNDTIMEO armed) that keeps
# any frame bytes already buffered behind the 101 head.
void ws_adopt_http_conn(ws_conn* c, http_conn* hc):
	int fd = hc.fd
	if (hc.tls == 0):
		socket_set_blocking(fd)
		socket_set_recv_timeout(fd, hc.timeout_ms)
		socket_set_send_timeout(fd, hc.timeout_ms)
	ConnectionContext* cc = connection_context_new(fd, hc.timeout_ms, hc.tls)
	stream_free(cc.reader)
	cc.reader = hc.reader
	c.cc = cc
	c.owns_cc = 1
	c.tls_cfg = hc.tls_cfg
	free(hc)


# Connects (TCP, then TLS for wss), sends the upgrade request, and
# validates the 101 response.
ws_conn* ws_dial(http_req* inner, URL* u, char* key, char* offered):
	int timeout = inner.timeout_ms
	if (timeout <= 0):
		timeout = http_default_timeout_ms()
	int ip = 0
	if (dns_resolve_ipv4(u.host, &ip) == 0):
		return ws_conn_failed(ws_error_dns())
	int fd = http_connect_fd(ip, u.port, timeout)
	if (fd < 0):
		if ((0 - fd) == http_error_timeout()):
			return ws_conn_failed(ws_error_timeout())
		return ws_conn_failed(ws_error_connect())
	tls_conn* tls = 0
	tls_config* tls_cfg = 0
	if (http_url_is_tls(u) != 0):
		if (socket_set_blocking(fd) < 0):
			close(fd)
			return ws_conn_failed(ws_error_connect())
		int hs_timeout = timeout
		if (inner.tls_handshake_timeout_ms > 0):
			hs_timeout = inner.tls_handshake_timeout_ms
		socket_set_recv_timeout(fd, hs_timeout)
		socket_set_send_timeout(fd, hs_timeout)
		tls_cfg = http_build_tls_config(inner)
		tls = tls_connect(fd, u.host, tls_cfg)
		if (tls == 0):
			tls_config_free(tls_cfg)
			close(fd)
			return ws_conn_failed(ws_error_tls())
		socket_set_recv_timeout(fd, timeout)
		socket_set_send_timeout(fd, timeout)
	http_conn* hc = http_conn_new(fd, timeout)
	hc.tls = tls
	hc.tls_cfg = tls_cfg
	if (http_send_request(hc, inner, u, c"GET", 0) == 0):
		int send_error = ws_error_io()
		if (hc.error == http_error_timeout()):
			send_error = ws_error_timeout()
		http_conn_destroy(hc)
		return ws_conn_failed(send_error)
	http_response* resp = http_response_new()
	int error = 0
	if (ws_read_response_head(hc, resp, &error) == 0):
		http_response_free(resp)
		http_conn_destroy(hc)
		return ws_conn_failed(error)
	int status = resp.status
	if (ws_validate_response(resp, key, offered) == 0):
		http_response_free(resp)
		http_conn_destroy(hc)
		ws_conn* failed = ws_conn_failed(ws_error_handshake())
		failed.http_status = status
		return failed
	ws_conn* c = ws_conn_new()
	c.is_client = 1
	c.http_status = status
	char* proto = http_response_header(resp, c"sec-websocket-protocol")
	if (proto != 0):
		c.subprotocol = strclone(proto)
	http_response_free(resp)
	ws_adopt_http_conn(c, hc)
	return c


ws_conn* ws_open_inner(http_req* inner, int bad_header, char* key, char* offered):
	if ((bad_header != 0) || (http_validate_req(inner) != 0)):
		return ws_conn_failed(ws_error_bad_request())
	if (key == 0):
		return ws_conn_failed(ws_error_io())
	http_req_add_header(inner, c"Upgrade", c"websocket")
	http_req_add_header(inner, c"Connection", c"Upgrade")
	http_req_add_header(inner, c"Sec-WebSocket-Key", key)
	http_req_add_header(inner, c"Sec-WebSocket-Version", c"13")
	URL* u = url_parse(inner.url)
	if (u == 0):
		return ws_conn_failed(ws_error_bad_url())
	if (http_validate_url(u) != 0):
		url_free(u)
		return ws_conn_failed(ws_error_bad_url())
	ws_conn* c = ws_dial(inner, u, key, offered)
	url_free(u)
	return c


# Opens a client connection: req.url is ws:// or wss://; req's extra
# headers (e.g. Origin, Sec-WebSocket-Protocol), timeout_ms and TLS
# knobs apply; its method must be GET and it must carry no body. The
# request is only read, never modified. Never returns 0: check
# ws_conn_error(c) == ws_error_none().
ws_conn* ws_open(http_req* req):
	if (req == 0):
		return ws_conn_failed(ws_error_bad_url())
	if (strcmp(req.method, c"GET") != 0):
		return ws_conn_failed(ws_error_bad_request())
	if (req.body != 0):
		return ws_conn_failed(ws_error_bad_request())
	char* http_url = ws_http_url(req.url)
	if (http_url == 0):
		return ws_conn_failed(ws_error_bad_url())
	if (ws_sha1_alg == 0):
		free(http_url)
		return ws_conn_failed(ws_error_no_sha1())
	http_req* inner = http_req_new(c"GET", http_url)
	inner.timeout_ms = req.timeout_ms
	inner.max_redirects = 0
	inner.tls_trust_store_path = req.tls_trust_store_path
	inner.tls_insecure_skip_verify = req.tls_insecure_skip_verify
	inner.tls_has_now_unix = req.tls_has_now_unix
	inner.tls_now_unix = req.tls_now_unix
	inner.tls_handshake_timeout_ms = req.tls_handshake_timeout_ms
	char* offered = 0
	int bad_header = 0
	for http_header* h in req.headers:
		if (ws_reserved_header(h.name) != 0):
			bad_header = 1
		if (http_str_ieq(h.name, c"sec-websocket-protocol") != 0):
			offered = h.value
		http_req_add_header(inner, h.name, h.value)
	char* key = ws_new_key()
	ws_conn* c = ws_open_inner(inner, bad_header, key, offered)
	if (key != 0):
		free(key)
	http_req_free(inner)
	free(http_url)
	return c


# ws_open with default timeout and no extra headers. Never returns 0.
ws_conn* ws_connect(char* url):
	http_req* req = http_req_new(c"GET", url)
	ws_conn* c = ws_open(req)
	http_req_free(req)
	return c


/* Server handshake */

# Whether the client offered protocol in Sec-WebSocket-Protocol.
int ws_request_offers_protocol(ServerRequest* req, char* protocol):
	char* offered = server_request_header(req, c"sec-websocket-protocol")
	if (offered == 0):
		return 0
	return http_value_has_token(offered, protocol)


# Writes a small plain-text error response (connection closes after).
void ws_write_http_error(ConnectionContext* cc, int status, char* reason, int version_hint):
	string_builder* out = string_new()
	string_append(out, c"HTTP/1.1 ")
	string_append_int(out, status)
	string_append_char(out, ' ')
	string_append(out, reason)
	string_append(out, c"\x0d\x0a")
	if (version_hint != 0):
		string_append(out, c"Sec-WebSocket-Version: 13\x0d\x0a")
	string_append(out, c"Content-Type: text/plain\x0d\x0aContent-Length: ")
	string_append_int(out, strlen(reason))
	string_append(out, c"\x0d\x0aConnection: close\x0d\x0a\x0d\x0a")
	string_append(out, reason)
	connection_context_write_all(cc, out.data, out.length)
	string_free(out)


# Checks an upgrade request (RFC 6455 section 4.2.1). Returns 0 when it
# is acceptable, else the HTTP status to answer with.
int ws_check_upgrade_request(ServerRequest* req, char* subprotocol):
	if (strcmp(req.method, c"GET") != 0):
		return 400
	if (req.http_minor < 1):
		return 400
	if (server_request_header(req, c"host") == 0):
		return 400
	char* upgrade = server_request_header(req, c"upgrade")
	if (upgrade == 0):
		return 400
	if (http_value_has_token(upgrade, c"websocket") == 0):
		return 400
	char* connection = server_request_header(req, c"connection")
	if (connection == 0):
		return 400
	if (http_value_has_token(connection, c"upgrade") == 0):
		return 400
	char* version = server_request_header(req, c"sec-websocket-version")
	if (version == 0):
		return 426
	if (strcmp(version, c"13") != 0):
		return 426
	char* key = server_request_header(req, c"sec-websocket-key")
	if (key == 0):
		return 400
	int nonce_len = 0
	char* nonce = base64_decode(key, strlen(key), &nonce_len)
	if (nonce == 0):
		return 400
	free(nonce)
	if (nonce_len != 16):
		return 400
	if (subprotocol != 0):
		if ((http_is_token(subprotocol) == 0) || (ws_request_offers_protocol(req, subprotocol) == 0)):
			return 500
	if (ws_sha1_alg == 0):
		return 500
	return 0


# Completes the server side of the opening handshake on cc for the
# already-parsed req: validates it and writes the 101 (with subprotocol,
# which must be one the client offered, or 0 for none). On failure an
# error response (400, 426 for an unsupported version, 500 for a
# server-side misconfiguration) is written and a failed conn returned
# (ws_error_handshake, or ws_error_no_sha1). cc stays owned by the
# caller/server. Never returns 0.
ws_conn* ws_server_accept(ConnectionContext* cc, ServerRequest* req, char* subprotocol):
	int status = ws_check_upgrade_request(req, subprotocol)
	if (status != 0):
		if (status == 426):
			ws_write_http_error(cc, 426, c"Upgrade Required", 1)
		else if (status == 500):
			ws_write_http_error(cc, 500, c"Internal Server Error", 0)
		else:
			ws_write_http_error(cc, 400, c"Bad Request", 0)
		if ((status == 500) && (ws_sha1_alg == 0)):
			return ws_conn_failed(ws_error_no_sha1())
		ws_conn* failed = ws_conn_failed(ws_error_handshake())
		failed.http_status = status
		return failed
	char* accept = ws_accept_key(server_request_header(req, c"sec-websocket-key"))
	string_builder* out = string_new()
	string_append(out, c"HTTP/1.1 101 Switching Protocols\x0d\x0aUpgrade: websocket\x0d\x0aConnection: Upgrade\x0d\x0aSec-WebSocket-Accept: ")
	string_append(out, accept)
	string_append(out, c"\x0d\x0a")
	if (subprotocol != 0):
		string_append(out, c"Sec-WebSocket-Protocol: ")
		string_append(out, subprotocol)
		string_append(out, c"\x0d\x0a")
	string_append(out, c"\x0d\x0a")
	int ok = connection_context_write_all(cc, out.data, out.length)
	string_free(out)
	free(accept)
	if (ok == 0):
		return ws_conn_failed(ws_error_io())
	ws_conn* c = ws_conn_wrap(cc, 0, 0)
	c.http_status = 101
	if (subprotocol != 0):
		c.subprotocol = strclone(subprotocol)
	return c


# ws_server_accept for an http_server.w route handler. Either way the
# RequestContext is marked as answered with keep-alive off, so the
# server writes nothing more and closes the connection once the handler
# returns -- run the whole session inside the handler. Never returns 0.
ws_conn* ws_accept(RequestContext* rc, char* subprotocol):
	ws_conn* c = ws_server_accept(rc.conn, rc.request, subprotocol)
	rc.stream_started = 1
	rc.stream_chunked = 0
	rc.responded = 1
	rc.keep_alive = 0
	return c
