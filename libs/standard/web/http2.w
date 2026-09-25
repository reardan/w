# HTTP/2 (RFC 9113) over a blocking socket, part of issue #436
# ("Protocols"). Header compression is libs/standard/web/hpack.w;
# libs/standard/web/grpc.w builds gRPC on top of this file.
#
# Scope: HTTP/2 with prior knowledge, either cleartext ("h2c", RFC 9113
# section 3.3) or over TLS 1.3 with ALPN "h2" (RFC 9113 section 3.2,
# libs/standard/net/tls.w): the client sends the connection preface
# straight away, and the server expects it. There is no HTTP/1.1
# Upgrade path.
#
# Transport: an h2_conn owns a socket fd and, for h2 over TLS, a
# tls_conn (h2_conn.tls, 0 for h2c). All connection I/O goes through
# h2_conn_write_all / h2_conn_read, which pick the TLS record stream or
# the bare fd; everything above them (framing, flow control, streams) is
# transport-agnostic. The TLS side requires the ALPN selection to be
# exactly "h2": a peer that negotiated anything else (or nothing) is
# refused before any HTTP/2 byte is sent.
#
# Public API (connection):
#   h2_conn* h2_connect(char* host, int port, int timeout_ms)  0 on failure
#   h2_conn* h2_connect_tls(char* host, int port, int timeout_ms,
#                           char* server_name, tls_config* cfg)
#                                        TLS + ALPN "h2"; 0 on failure, the reason
#                                        in tls_last_error(cfg) when cfg != 0
#   h2_conn* h2_client_new(int fd)       preface + SETTINGS on a connected fd
#   h2_conn* h2_client_new_tls(int fd, tls_conn* t)
#                                        same over an established TLS session;
#                                        0 (t closed) unless ALPN selected "h2"
#   h2_conn* h2_conn_new(int fd, int is_server) + void h2_client_start(h2_conn* c)
#                                        same, with local_* settings tuned in between
#                                        (set c.tls first for h2 over TLS)
#   h2_conn* h2_server_new(int fd)       reads the client preface; 0 on failure
#   h2_conn* h2_server_new_tls(int fd, tls_conn* t)
#                                        same over a tls_accept'ed session; 0 unless "h2"
#   h2_conn* h2_accept_tls(int fd, tls_server_config* scfg)
#                                        tls_accept requiring ALPN "h2" (sets it on
#                                        scfg), then h2_server_new_tls
#   int  h2_pump(h2_conn* c)             read + handle one frame: 0 / -1 dead / -2 timeout
#   int  h2_ping(h2_conn* c)             PING and wait for its ACK; 0 on success
#   int  h2_await_settings(h2_conn* c)   wait for the peer's first SETTINGS
#   void h2_goaway(h2_conn* c, int code) send GOAWAY (graceful when code == 0)
#   void h2_close(h2_conn* c)            GOAWAY(NO_ERROR) if needed, close_notify
#                                        (TLS), close fd, free
#   void h2_set_deadline(h2_conn* c, int deadline_ms)  absolute monotonic ms, 0 = none
#   int  h2_conn_has_pending(h2_conn* c) 1 when h2_pump can make progress without
#                                        waiting: a whole frame buffered, decrypted
#                                        TLS plaintext not yet consumed, or a
#                                        readable socket
#
# Public API (client streams):
#   h2_stream* h2_request_start(h2_conn* c, char* method, char* scheme, char* authority,
#                               char* path, list[hpack_header*] extra, int end_stream)
#   h2_stream* h2_request(h2_conn* c, char* method, char* scheme, char* authority,
#                         char* path, list[hpack_header*] extra, char* body, int body_len)
#   int  h2_await_headers(h2_conn* c, h2_stream* s)   response headers arrived
#   int  h2_await_end(h2_conn* c, h2_stream* s)       peer's END_STREAM arrived
#
# Public API (server streams):
#   h2_stream* h2_server_next_request(h2_conn* c)     next complete request, 0 at end
#   int  h2_respond_headers(h2_conn* c, h2_stream* s, int status, list[hpack_header*] extra, int end_stream)
#   int  h2_respond(h2_conn* c, h2_stream* s, int status, list[hpack_header*] extra, char* body, int len)
#
# Public API (either side):
#   int  h2_send_headers(h2_conn* c, h2_stream* s, list[hpack_header*] h, int end_stream)
#   int  h2_send_data(h2_conn* c, h2_stream* s, char* data, int len, int end_stream)
#   int  h2_send_trailers(h2_conn* c, h2_stream* s, list[hpack_header*] trailers)
#   int  h2_send_rst(h2_conn* c, h2_stream* s, int code)
#   int  h2_stream_status(h2_stream* s)               :status (client), 0 when none
#   char* h2_stream_header(h2_stream* s, char* name)  / h2_stream_trailer(...)
#   char* h2_stream_body(h2_stream* s) / int h2_stream_body_len(h2_stream* s)
#   int  h2_stream_ok(h2_stream* s)       1 = END_STREAM received, not reset/refused
#   void h2_stream_free(h2_conn* c, h2_stream* s)     RST_STREAM(CANCEL) if still open
#   int  h2_error_*() / h2_frame_*() / h2_flag_*() / h2_settings_*() constants
#   char* h2_error_string(int code)
#
# Public API (raw frames on a bare fd, for fixtures and tools):
#   int  h2_raw_write_frame(int fd, int type, int flags, int stream_id, char* payload, int len)
#   int  h2_raw_read_frame(int fd, h2_frame* f)   malloc'd f.payload; 1 / 0 on EOF
#   char* h2_preface() / int h2_preface_len()
#
# Tunables (h2_conn fields): timeout_ms (30 s; SO_RCVTIMEO/SO_SNDTIMEO
# on the fd, an idle read past it kills the connection), max_block,
# max_body, max_streams, and -- between h2_conn_new and h2_client_start
# (client only; h2_server_new advertises the defaults) --
# local_initial_window, local_conn_window, local_max_concurrent,
# local_max_header_list.
#
# Return conventions: send/await functions return 0 on success and -1
# when the stream was reset/refused or the connection is gone (c.dead);
# -2 means the deadline set by h2_set_deadline passed (the connection is
# still usable: the reader keeps partial frames buffered).
#
# Model: single-threaded and blocking. Every frame is read by h2_pump,
# which dispatches it to its stream, so any number of streams may be in
# flight at once: start several requests, then await them in any order
# (frames for other streams are buffered on their h2_stream while one
# is awaited). Bodies are buffered whole in memory (h2_conn.max_body
# per stream, fail closed with RST_STREAM(ENHANCE_YOUR_CALM)).
#
# Protocol coverage:
#   - frames: DATA, HEADERS, PRIORITY (validated, ignored), RST_STREAM,
#     SETTINGS (+ACK), PUSH_PROMISE (always rejected: we send
#     ENABLE_PUSH=0, so receipt is a PROTOCOL_ERROR), PING (+ACK),
#     GOAWAY, WINDOW_UPDATE, CONTINUATION; unknown types are ignored;
#   - padding (PADDED on DATA/HEADERS) with pad-length validation;
#   - frame size: frames above our SETTINGS_MAX_FRAME_SIZE are a
#     FRAME_SIZE_ERROR; we split outgoing DATA and header blocks
#     (HEADERS + CONTINUATION) to the peer's value;
#   - flow control: connection and stream send windows gate DATA (the
#     sender pumps frames until WINDOW_UPDATE opens them), SETTINGS
#     INITIAL_WINDOW_SIZE deltas apply to open streams, receive windows
#     are enforced (FLOW_CONTROL_ERROR) and replenished once half used;
#   - stream states idle / open / half-closed (local, remote) / closed,
#     with STREAM_CLOSED and PROTOCOL_ERROR handling for frames in the
#     wrong state; peer stream ids must be increasing and correctly
#     odd/even; MAX_CONCURRENT_STREAMS is honored both ways;
#   - GOAWAY: received -> streams above last-stream-id are marked
#     refused (safe to retry) and no new streams start; connection
#     errors send GOAWAY with the error code and stop the connection;
#   - message checks: responses need a valid :status (1xx informational
#     headers are skipped), trailers must end the stream and carry no
#     pseudo-headers, requests need :method/:path (+ :scheme unless
#     CONNECT), content-length must match the DATA received, and
#     connection-specific headers are rejected (stream PROTOCOL_ERROR).
#
# Hard caps (fail closed): accumulated header block (h2_conn.max_block),
# decoded header list (hpack caps, SETTINGS_MAX_HEADER_LIST_SIZE),
# buffered body per stream (h2_conn.max_body), tracked streams.
import lib.lib
import lib.net
import lib.time
import lib.container
import structures.string
import lib.poll
import libs.standard.net.dns
import libs.standard.net.tls
import libs.standard.web.hpack
import lib.bytes
import lib.mem


/* Constants */

int h2_frame_data():
	return 0


int h2_frame_headers():
	return 1


int h2_frame_priority():
	return 2


int h2_frame_rst_stream():
	return 3


int h2_frame_settings():
	return 4


int h2_frame_push_promise():
	return 5


int h2_frame_ping():
	return 6


int h2_frame_goaway():
	return 7


int h2_frame_window_update():
	return 8


int h2_frame_continuation():
	return 9


int h2_flag_end_stream():
	return 1


int h2_flag_ack():
	return 1


int h2_flag_end_headers():
	return 4


int h2_flag_padded():
	return 8


int h2_flag_priority():
	return 32


int h2_error_no_error():
	return 0


int h2_error_protocol():
	return 1


int h2_error_internal():
	return 2


int h2_error_flow_control():
	return 3


int h2_error_settings_timeout():
	return 4


int h2_error_stream_closed():
	return 5


int h2_error_frame_size():
	return 6


int h2_error_refused_stream():
	return 7


int h2_error_cancel():
	return 8


int h2_error_compression():
	return 9


int h2_error_connect():
	return 10


int h2_error_enhance_your_calm():
	return 11


int h2_error_inadequate_security():
	return 12


int h2_error_http_1_1_required():
	return 13


char* h2_error_string(int code):
	if (code == 0):
		return c"NO_ERROR"
	if (code == 1):
		return c"PROTOCOL_ERROR"
	if (code == 2):
		return c"INTERNAL_ERROR"
	if (code == 3):
		return c"FLOW_CONTROL_ERROR"
	if (code == 4):
		return c"SETTINGS_TIMEOUT"
	if (code == 5):
		return c"STREAM_CLOSED"
	if (code == 6):
		return c"FRAME_SIZE_ERROR"
	if (code == 7):
		return c"REFUSED_STREAM"
	if (code == 8):
		return c"CANCEL"
	if (code == 9):
		return c"COMPRESSION_ERROR"
	if (code == 10):
		return c"CONNECT_ERROR"
	if (code == 11):
		return c"ENHANCE_YOUR_CALM"
	if (code == 12):
		return c"INADEQUATE_SECURITY"
	if (code == 13):
		return c"HTTP_1_1_REQUIRED"
	return c"UNKNOWN_ERROR"


int h2_settings_header_table_size():
	return 1


int h2_settings_enable_push():
	return 2


int h2_settings_max_concurrent_streams():
	return 3


int h2_settings_initial_window_size():
	return 4


int h2_settings_max_frame_size():
	return 5


int h2_settings_max_header_list_size():
	return 6


int h2_max_window():
	return 2147483647


int h2_default_window():
	return 65535


int h2_default_max_frame():
	return 16384


int h2_max_frame_limit():
	return 16777215


# Stream states (RFC 9113 section 5.1; reserved states never occur
# because push is disabled).
int h2_state_idle():
	return 0


int h2_state_open():
	return 1


int h2_state_half_closed_local():
	return 2


int h2_state_half_closed_remote():
	return 3


int h2_state_closed():
	return 4


char* h2_preface():
	return c"PRI * HTTP/2.0\x0d\x0a\x0d\x0aSM\x0d\x0a\x0d\x0a"


int h2_preface_len():
	return 24


/* Types */

# One frame as read off the wire. payload points into the connection's
# read buffer (h2_pump) or is malloc'd (h2_raw_read_frame).
struct h2_frame:
	int type
	int flags
	int stream_id
	int length
	char* payload


struct h2_stream:
	int id
	int state
	int send_window
	int recv_window
	list[hpack_header*] headers
	list[hpack_header*] trailers
	string_builder* body
	int headers_received
	int end_received
	int end_sent
	int reset_code
	int reset_by_peer
	int refused
	int delivered
	int status


struct h2_conn:
	int fd
	tls_conn* tls           # h2 over TLS: the record stream (0 = h2c on fd)
	tls_config* own_tls_cfg # client config h2_connect_tls allocated, or 0
	int is_server
	int dead
	int io_error
	int error
	int timeout_ms
	int deadline_ms
	char* rbuf
	int rcap
	int rstart
	int rend
	int local_initial_window
	int local_max_frame
	int local_max_header_list
	int local_max_concurrent
	int local_conn_window
	int peer_enable_push
	int peer_max_concurrent
	int peer_initial_window
	int peer_max_frame
	int peer_max_header_list
	int got_peer_settings
	int settings_acks
	int conn_send_window
	int conn_recv_window
	hpack_encoder* enc
	hpack_decoder* dec
	list[h2_stream*] streams
	int next_stream_id
	int last_peer_stream_id
	int cont_stream
	int cont_end_stream
	string_builder* cont_block
	int goaway_received
	int goaway_last_stream
	int goaway_code
	char* goaway_debug
	int goaway_sent
	int ping_sent
	int ping_acked
	int max_block
	int max_body
	int max_streams


/* Forward declarations */

int h2_send_window_update(h2_conn* c, int stream_id, int inc);
int h2_write_frame_raw_bytes(h2_conn* c, char* p, int n);
int h2_fill(h2_conn* c, int n);
void h2_close(h2_conn* c);
h2_conn* h2_server_start(h2_conn* c);
int h2_contains(char* hay, char* needle);


/* Byte helpers */

# 31-bit value with the high (reserved) bit masked off.
int h2_get_u31(char* p):
	return ((p[0] & 127) << 24) | ((p[1] & 255) << 16) | ((p[2] & 255) << 8) | (p[3] & 255)


int h2_min(int a, int b):
	if (a < b):
		return a
	return b


/* Raw frame I/O on a bare fd */

int h2_fd_write_all(int fd, char* p, int n):
	int off = 0
	while (off < n):
		int got = socket_send(fd, p + off, n - off, msg_nosignal())
		if (got <= 0):
			return (-1)
		off = off + got
	return 0


# Reads exactly n bytes. 1 on success, 0 on EOF/error.
int h2_fd_read_exact(int fd, char* p, int n):
	int off = 0
	while (off < n):
		int got = read(fd, p + off, n - off)
		if (got <= 0):
			return 0
		off = off + got
	return 1


# Serializes one frame (9-byte header + payload) into a malloc'd buffer
# of 9 + len bytes.
char* h2_frame_encode(int type, int flags, int stream_id, char* payload, int len):
	char* buf = malloc(9 + len)
	store_be24(buf, len)
	buf[3] = type
	buf[4] = flags
	store_be32(buf + 5, stream_id)
	mem_copy(buf + 9, payload, len)
	return buf


int h2_raw_write_frame(int fd, int type, int flags, int stream_id, char* payload, int len):
	char* buf = h2_frame_encode(type, flags, stream_id, payload, len)
	int rc = h2_fd_write_all(fd, buf, 9 + len)
	free(buf)
	return rc


int h2_raw_read_frame(int fd, h2_frame* f):
	char* head = malloc(9)
	if (h2_fd_read_exact(fd, head, 9) == 0):
		free(head)
		return 0
	f.length = load_be24(head)
	f.type = head[3] & 255
	f.flags = head[4] & 255
	f.stream_id = h2_get_u31(head + 5)
	free(head)
	f.payload = malloc(f.length + 1)
	if (h2_fd_read_exact(fd, f.payload, f.length) == 0):
		free(f.payload)
		f.payload = 0
		return 0
	return 1


/* Connection construction */

h2_conn* h2_conn_new(int fd, int is_server):
	h2_conn* c = new h2_conn()
	c.fd = fd
	c.tls = 0
	c.own_tls_cfg = 0
	c.is_server = is_server
	c.dead = 0
	c.io_error = 0
	c.error = 0
	c.timeout_ms = 30000
	c.deadline_ms = 0
	c.rcap = 32768
	c.rbuf = malloc(c.rcap)
	c.rstart = 0
	c.rend = 0
	c.local_initial_window = h2_default_window()
	c.local_max_frame = h2_default_max_frame()
	c.local_max_header_list = hpack_default_max_list_size()
	c.local_max_concurrent = 100
	c.local_conn_window = 1048576
	c.peer_enable_push = 1
	c.peer_max_concurrent = 2147483647
	c.peer_initial_window = h2_default_window()
	c.peer_max_frame = h2_default_max_frame()
	c.peer_max_header_list = 2147483647
	c.got_peer_settings = 0
	c.settings_acks = 0
	c.conn_send_window = h2_default_window()
	c.conn_recv_window = h2_default_window()
	c.enc = hpack_encoder_new(hpack_default_table_size())
	c.dec = hpack_decoder_new(hpack_default_table_size())
	c.dec.max_list_size = c.local_max_header_list
	c.streams = new list[h2_stream*]
	c.next_stream_id = 1
	if (is_server != 0):
		c.next_stream_id = 2
	c.last_peer_stream_id = 0
	c.cont_stream = 0
	c.cont_end_stream = 0
	c.cont_block = string_new()
	c.goaway_received = 0
	c.goaway_last_stream = 2147483647
	c.goaway_code = 0
	c.goaway_debug = 0
	c.goaway_sent = 0
	c.ping_sent = 0
	c.ping_acked = 0
	c.max_block = 262144
	c.max_body = 16777216
	c.max_streams = 1000
	socket_set_recv_timeout(fd, c.timeout_ms)
	socket_set_send_timeout(fd, c.timeout_ms)
	return c


/* Transport seam: every connection byte goes through these two */

# Writes all n bytes to the peer: TLS application data when c.tls is
# set, the bare fd otherwise. 0 on success, -1 on error.
int h2_conn_write_all(h2_conn* c, char* p, int n):
	if (c.tls != 0):
		if (n <= 0):
			return 0
		if (tls_write(c.tls, p, n) != n):
			return (-1)
		return 0
	return h2_fd_write_all(c.fd, p, n)


# Reads up to n bytes (at least one): > 0 bytes read, <= 0 EOF/error,
# or -net_eagain() when the connection deadline passed first (only
# while deadline_ms is set). On TLS the deadline is enforced by
# polling the fd before a record is started (a record is then read
# whole, bounded by timeout_ms), so an expired deadline never splits a
# TLS record.
int h2_conn_read(h2_conn* c, char* p, int n):
	int left = 0
	if (c.deadline_ms != 0):
		left = c.deadline_ms - time_monotonic_ms()
		if (left <= 0):
			return (0 - net_eagain())
	if (c.tls != 0):
		if ((c.deadline_ms != 0) && (c.tls.app_pos >= c.tls.app_len)):
			int ready = poll_single(c.fd, poll_in(), left)
			if (ready == 0):
				return (0 - net_eagain())
		return tls_read(c.tls, p, n)
	if (c.deadline_ms != 0):
		socket_set_recv_timeout(c.fd, left)
	int got = read(c.fd, p, n)
	if (c.deadline_ms != 0):
		socket_set_recv_timeout(c.fd, c.timeout_ms)
	return got


# 1 when input is available without blocking: a complete frame already
# in rbuf, plaintext the TLS layer decrypted but h2_conn_read has not
# consumed yet (h2 over TLS: a record can carry several frames, and a
# poll on the fd cannot see it), or a readable socket. 0 otherwise.
int h2_conn_has_pending(h2_conn* c):
	if (c.dead != 0):
		return 0
	int buffered = c.rend - c.rstart
	if ((buffered >= 9) && (buffered >= 9 + load_be24(c.rbuf + c.rstart))):
		return 1
	if ((c.tls != 0) && (c.tls.app_pos < c.tls.app_len)):
		return 1
	if (poll_single(c.fd, poll_in(), 0) > 0):
		return 1
	return 0


int h2_write_frame(h2_conn* c, int type, int flags, int stream_id, char* payload, int len):
	if (c.dead != 0):
		return (-1)
	char* buf = h2_frame_encode(type, flags, stream_id, payload, len)
	int rc = h2_conn_write_all(c, buf, 9 + len)
	free(buf)
	if (rc != 0):
		c.io_error = 1
		c.dead = 1
		return (-1)
	return 0


# Our SETTINGS: push off, stream limit, stream window, header list cap.
# The connection window is raised with a WINDOW_UPDATE right after.
int h2_send_settings(h2_conn* c):
	c.dec.max_list_size = c.local_max_header_list
	char* p = malloc(24)
	p[0] = 0
	p[1] = h2_settings_enable_push()
	store_be32(p + 2, 0)
	p[6] = 0
	p[7] = h2_settings_max_concurrent_streams()
	store_be32(p + 8, c.local_max_concurrent)
	p[12] = 0
	p[13] = h2_settings_initial_window_size()
	store_be32(p + 14, c.local_initial_window)
	p[18] = 0
	p[19] = h2_settings_max_header_list_size()
	store_be32(p + 20, c.local_max_header_list)
	int rc = h2_write_frame(c, h2_frame_settings(), 0, 0, p, 24)
	free(p)
	if (rc != 0):
		return rc
	return h2_send_window_update(c, 0, c.local_conn_window - c.conn_recv_window)


int h2_send_window_update(h2_conn* c, int stream_id, int inc):
	if (inc <= 0):
		return 0
	char* p = malloc(4)
	store_be32(p, inc)
	int rc = h2_write_frame(c, h2_frame_window_update(), 0, stream_id, p, 4)
	free(p)
	if (rc != 0):
		return rc
	if (stream_id == 0):
		c.conn_recv_window = c.conn_recv_window + inc
	return 0


# Client side: sends the preface and our SETTINGS. The local_* fields
# (windows, frame size, limits) may be tuned between h2_conn_new and
# h2_client_start; h2_client_new uses the defaults.
void h2_client_start(h2_conn* c):
	if (h2_write_frame_raw_bytes(c, h2_preface(), h2_preface_len()) != 0):
		return
	h2_send_settings(c)


h2_conn* h2_client_new(int fd):
	h2_conn* c = h2_conn_new(fd, 0)
	h2_client_start(c)
	return c


int h2_write_frame_raw_bytes(h2_conn* c, char* p, int n):
	if (c.dead != 0):
		return (-1)
	if (h2_conn_write_all(c, p, n) != 0):
		c.io_error = 1
		c.dead = 1
		return (-1)
	return 0


# Opens a TCP connection and starts HTTP/2 on it. host may be a dotted
# quad or a name (libs/standard/net/dns.w). Returns 0 on failure.
h2_conn* h2_connect(char* host, int port, int timeout_ms):
	int ip = 0
	if (dns_resolve_ipv4(host, &ip) == 0):
		return 0
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return 0
	socket_set_send_timeout(fd, timeout_ms)
	if (socket_connect_ipv4(fd, ip, port) < 0):
		close(fd)
		return 0
	h2_conn* c = h2_client_new(fd)
	c.timeout_ms = timeout_ms
	socket_set_recv_timeout(fd, timeout_ms)
	if (c.dead != 0):
		h2_close(c)
		return 0
	return c


# Server side of a freshly accepted connection: reads and checks the
# 24-byte client preface, then sends our SETTINGS. 0 on failure (the fd
# is closed).
h2_conn* h2_server_new(int fd):
	return h2_server_start(h2_conn_new(fd, 1))


# Reads the client preface and sends our SETTINGS on a fresh server-side
# connection (plain or TLS). 0 on failure (the connection is closed).
h2_conn* h2_server_start(h2_conn* c):
	if (h2_fill(c, h2_preface_len()) != 0):
		h2_close(c)
		return 0
	char* want = h2_preface()
	int i = 0
	while (i < h2_preface_len()):
		if (c.rbuf[c.rstart + i] != want[i]):
			h2_close(c)
			return 0
		i = i + 1
	c.rstart = c.rstart + h2_preface_len()
	if (h2_send_settings(c) != 0):
		h2_close(c)
		return 0
	return c


# 1 when the TLS session negotiated ALPN "h2" (RFC 9113 section 3.2).
int h2_tls_is_h2(tls_conn* t):
	char* sel = tls_alpn_selected(t)
	if (sel == 0):
		return 0
	return strcmp(sel, c"h2") == 0


# Client side over an established TLS session (ALPN must have selected
# "h2"): sends the preface and SETTINGS as application data. Takes
# ownership of t and fd: on failure both are closed and 0 is returned.
h2_conn* h2_client_new_tls(int fd, tls_conn* t):
	if (h2_tls_is_h2(t) == 0):
		tls_close(t)
		close(fd)
		return 0
	h2_conn* c = h2_conn_new(fd, 0)
	c.tls = t
	h2_client_start(c)
	if (c.dead != 0):
		h2_close(c)
		return 0
	return c


# Server side over a tls_accept'ed session (ALPN must have selected
# "h2"). Takes ownership of t and fd: on failure both are closed.
h2_conn* h2_server_new_tls(int fd, tls_conn* t):
	if (h2_tls_is_h2(t) == 0):
		tls_close(t)
		close(fd)
		return 0
	h2_conn* c = h2_conn_new(fd, 1)
	c.tls = t
	return h2_server_start(c)


# Opens TCP, runs the TLS 1.3 handshake offering ALPN "h2" (server_name
# is the SNI + certificate hostname; 0 = host), then starts HTTP/2.
# cfg supplies trust/verification settings (0 = defaults) and is
# modified: its ALPN offer becomes "h2". A server that does not select
# h2 is refused ("http2: server did not negotiate h2 via ALPN" in
# tls_last_error(cfg)). Returns 0 on any failure.
h2_conn* h2_connect_tls(char* host, int port, int timeout_ms, char* server_name, tls_config* cfg):
	int ip = 0
	if (dns_resolve_ipv4(host, &ip) == 0):
		return 0
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return 0
	socket_set_send_timeout(fd, timeout_ms)
	socket_set_recv_timeout(fd, timeout_ms)
	if (socket_connect_ipv4(fd, ip, port) < 0):
		close(fd)
		return 0
	tls_config* own = 0
	if (cfg == 0):
		own = tls_config_new()
		cfg = own
	tls_config_set_alpn(cfg, c"h2")
	if (server_name == 0):
		server_name = host
	tls_conn* t = tls_connect(fd, server_name, cfg)
	if (t == 0):
		close(fd)
		if (own != 0):
			tls_config_free(own)
		return 0
	if (h2_tls_is_h2(t) == 0):
		cfg.last_error = c"http2: server did not negotiate h2 via ALPN"
	h2_conn* c = h2_client_new_tls(fd, t)
	if (c == 0):
		if (own != 0):
			tls_config_free(own)
		return 0
	c.own_tls_cfg = own
	c.timeout_ms = timeout_ms
	socket_set_recv_timeout(fd, timeout_ms)
	socket_set_send_timeout(fd, timeout_ms)
	return c


# Server side of a freshly accepted TCP connection: TLS handshake with
# ALPN "h2" required (scfg is modified to require it; a client that
# does not offer h2 gets no_application_protocol), then the preface.
# 0 on failure (the fd is closed; tls_server_last_error(scfg) explains
# a TLS failure).
h2_conn* h2_accept_tls(int fd, tls_server_config* scfg):
	tls_server_config_set_alpn(scfg, c"h2", 1)
	tls_conn* t = tls_accept(fd, scfg)
	if (t == 0):
		close(fd)
		return 0
	return h2_server_new_tls(fd, t)


void h2_set_deadline(h2_conn* c, int deadline_ms):
	c.deadline_ms = deadline_ms


/* Buffered reading */

# Ensures n unread bytes are buffered. 0 ok, -1 dead (EOF/error),
# -2 deadline passed (buffered bytes are kept).
int h2_fill(h2_conn* c, int n):
	if (c.dead != 0):
		return (-1)
	while (c.rend - c.rstart < n):
		if (c.rstart > 0):
			int have = c.rend - c.rstart
			mem_copy(c.rbuf, c.rbuf + c.rstart, have)
			c.rstart = 0
			c.rend = have
		if (n > c.rcap):
			int ncap = c.rcap
			while (ncap < n):
				ncap = ncap * 2
			c.rbuf = realloc(c.rbuf, c.rcap, ncap)
			c.rcap = ncap
		int got = h2_conn_read(c, c.rbuf + c.rend, c.rcap - c.rend)
		if ((got < 0) && (got == (0 - net_eagain())) && (c.deadline_ms != 0)):
			return (-2)
		if (got <= 0):
			c.io_error = 1
			c.dead = 1
			return (-1)
		c.rend = c.rend + got
	return 0


/* Errors */

void h2_send_goaway(h2_conn* c, int code, char* debug):
	if (c.goaway_sent != 0):
		return
	c.goaway_sent = 1
	int dlen = 0
	if (debug != 0):
		dlen = strlen(debug)
	char* p = malloc(8 + dlen)
	store_be32(p, c.last_peer_stream_id)
	store_be32(p + 4, code)
	mem_copy(p + 8, debug, dlen)
	h2_write_frame(c, h2_frame_goaway(), 0, 0, p, 8 + dlen)
	free(p)


# Connection error (RFC 9113 section 5.4.1): GOAWAY with code, then the
# connection is finished. Always returns -1.
int h2_conn_error(h2_conn* c, int code, char* why):
	if (c.dead == 0):
		h2_send_goaway(c, code, why)
	c.error = code
	c.dead = 1
	return (-1)


h2_stream* h2_find_stream(h2_conn* c, int id):
	int i = 0
	while (i < c.streams.length):
		h2_stream* s = c.streams[i]
		if (s.id == id):
			return s
		i = i + 1
	return 0


int h2_write_rst(h2_conn* c, int stream_id, int code):
	char* p = malloc(4)
	store_be32(p, code)
	int rc = h2_write_frame(c, h2_frame_rst_stream(), 0, stream_id, p, 4)
	free(p)
	return rc


# Stream error (section 5.4.2): RST_STREAM, stream closed. Returns 0 so
# frame handling continues with the connection intact.
int h2_stream_error(h2_conn* c, int stream_id, int code):
	h2_write_rst(c, stream_id, code)
	h2_stream* s = h2_find_stream(c, stream_id)
	if (s != 0):
		if (s.reset_code < 0):
			s.reset_code = code
		s.state = h2_state_closed()
	return 0


/* Streams */

h2_stream* h2_stream_new(h2_conn* c, int id):
	h2_stream* s = new h2_stream()
	s.id = id
	s.state = h2_state_idle()
	s.send_window = c.peer_initial_window
	s.recv_window = c.local_initial_window
	s.headers = 0
	s.trailers = 0
	s.body = string_new()
	s.headers_received = 0
	s.end_received = 0
	s.end_sent = 0
	s.reset_code = (-1)
	s.reset_by_peer = 0
	s.refused = 0
	s.delivered = 0
	s.status = 0
	c.streams.push(s)
	return s


int h2_stream_active(h2_stream* s):
	return (s.state == h2_state_open()) || (s.state == h2_state_half_closed_local()) || (s.state == h2_state_half_closed_remote())


int h2_active_count(h2_conn* c, int locally_initiated):
	int n = 0
	int i = 0
	while (i < c.streams.length):
		h2_stream* s = c.streams[i]
		int mine = ((s.id & 1) == 1) != (c.is_server != 0)
		if ((h2_stream_active(s) != 0) && (mine == (locally_initiated != 0))):
			n = n + 1
		i = i + 1
	return n


void h2_on_end_received(h2_stream* s):
	s.end_received = 1
	if (s.state == h2_state_open()):
		s.state = h2_state_half_closed_remote()
	else if (s.state == h2_state_half_closed_local()):
		s.state = h2_state_closed()


void h2_on_end_sent(h2_stream* s):
	s.end_sent = 1
	if (s.state == h2_state_open()):
		s.state = h2_state_half_closed_local()
	else if (s.state == h2_state_half_closed_remote()):
		s.state = h2_state_closed()


void h2_stream_free(h2_conn* c, h2_stream* s):
	if (s == 0):
		return
	if ((h2_stream_active(s) != 0) && (c.dead == 0)):
		h2_write_rst(c, s.id, h2_error_cancel())
	int i = 0
	while (i < c.streams.length):
		if (c.streams[i] == s):
			c.streams.remove(i)
			break
		i = i + 1
	hpack_headers_free(s.headers)
	hpack_headers_free(s.trailers)
	string_free(s.body)
	free(s)


/* Accessors */

int h2_stream_status(h2_stream* s):
	return s.status


char* h2_stream_header(h2_stream* s, char* name):
	return hpack_headers_get(s.headers, name)


char* h2_stream_trailer(h2_stream* s, char* name):
	return hpack_headers_get(s.trailers, name)


char* h2_stream_body(h2_stream* s):
	return s.body.data


int h2_stream_body_len(h2_stream* s):
	return s.body.length


int h2_stream_ok(h2_stream* s):
	return (s.end_received != 0) && (s.reset_code < 0) && (s.refused == 0)


/* Message validation */

int h2_is_pseudo(hpack_header* h):
	return (h.name_len > 0) && (h.name[0] == ':')


int h2_name_is(hpack_header* h, char* name):
	return hpack_bytes_equal(h.name, h.name_len, name, strlen(name))


# Header-list checks shared by requests, responses and trailers:
# lowercase names, pseudo-headers first and only from allowed, no
# connection-specific fields, te only "trailers". 1 when valid.
int h2_valid_fields(list[hpack_header*] l, char* allowed_pseudo):
	int seen_regular = 0
	int i = 0
	while (i < l.length):
		hpack_header* h = l[i]
		int k = 0
		while (k < h.name_len):
			int ch = h.name[k] & 255
			if ((ch >= 'A') && (ch <= 'Z')):
				return 0
			k = k + 1
		if (h2_is_pseudo(h) != 0):
			if (seen_regular != 0):
				return 0
			# allowed_pseudo is a ",name,name," list.
			string_builder* key = string_new()
			string_append(key, c",")
			string_append(key, h.name)
			string_append(key, c",")
			int found = h2_contains(allowed_pseudo, key.data)
			string_free(key)
			if (found == 0):
				return 0
		else:
			seen_regular = 1
			if ((h2_name_is(h, c"connection") != 0) || (h2_name_is(h, c"keep-alive") != 0) || (h2_name_is(h, c"proxy-connection") != 0) || (h2_name_is(h, c"transfer-encoding") != 0) || (h2_name_is(h, c"upgrade") != 0)):
				return 0
			if ((h2_name_is(h, c"te") != 0) && (strcmp(h.value, c"trailers") != 0)):
				return 0
		i = i + 1
	return 1


int h2_contains(char* hay, char* needle):
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


int h2_count_name(list[hpack_header*] l, char* name):
	int n = 0
	int i = 0
	while (i < l.length):
		if (h2_name_is(l[i], name) != 0):
			n = n + 1
		i = i + 1
	return n


int h2_valid_request(list[hpack_header*] l):
	if (h2_valid_fields(l, c",:method,:scheme,:authority,:path,:protocol,") == 0):
		return 0
	if (h2_count_name(l, c":method") != 1):
		return 0
	char* method = hpack_headers_get(l, c":method")
	if (strcmp(method, c"CONNECT") == 0):
		return h2_count_name(l, c":authority") == 1
	if ((h2_count_name(l, c":path") != 1) || (h2_count_name(l, c":scheme") != 1)):
		return 0
	return strlen(hpack_headers_get(l, c":path")) > 0


# Parses a 3-digit :status. 0 when absent or invalid.
int h2_parse_status(list[hpack_header*] l):
	if (h2_valid_fields(l, c",:status,") == 0):
		return 0
	if (h2_count_name(l, c":status") != 1):
		return 0
	char* v = hpack_headers_get(l, c":status")
	if (strlen(v) != 3):
		return 0
	int n = 0
	int i = 0
	while (i < 3):
		if ((v[i] < '0') || (v[i] > '9')):
			return 0
		n = n * 10 + (v[i] - '0')
		i = i + 1
	if (n < 100):
		return 0
	return n


# content-length vs received body at END_STREAM. 1 when consistent.
int h2_content_length_ok(h2_stream* s):
	char* cl = hpack_headers_get(s.headers, c"content-length")
	if (cl == 0):
		return 1
	int n = 0
	int i = 0
	if (cl[0] == 0):
		return 0
	while (cl[i] != 0):
		if ((cl[i] < '0') || (cl[i] > '9') || (i > 9)):
			return 0
		n = n * 10 + (cl[i] - '0')
		i = i + 1
	return n == s.body.length


/* Frame handlers */

int h2_on_end_stream_checks(h2_conn* c, h2_stream* s):
	h2_on_end_received(s)
	if (h2_content_length_ok(s) == 0):
		return h2_stream_error(c, s.id, h2_error_protocol())
	return 0


# A complete header block for stream_id (HEADERS plus any
# CONTINUATION). Always decoded first so the HPACK state stays in sync.
int h2_on_header_block(h2_conn* c, int stream_id, int end_stream, char* block, int len):
	list[hpack_header*] out = hpack_headers_new()
	int rc = hpack_decode(c.dec, block, len, out)
	if (rc != 0):
		hpack_headers_free(out)
		if (rc == hpack_error_too_large()):
			return h2_conn_error(c, h2_error_enhance_your_calm(), hpack_error_string(rc))
		return h2_conn_error(c, h2_error_compression(), hpack_error_string(rc))
	h2_stream* s = h2_find_stream(c, stream_id)
	if (c.is_server != 0):
		if (s == 0):
			if (((stream_id & 1) == 0) || (stream_id <= c.last_peer_stream_id)):
				hpack_headers_free(out)
				return h2_conn_error(c, h2_error_protocol(), c"bad stream id")
			c.last_peer_stream_id = stream_id
			if ((c.goaway_sent != 0) || (h2_active_count(c, 0) >= c.local_max_concurrent) || (c.streams.length >= c.max_streams)):
				hpack_headers_free(out)
				return h2_write_rst(c, stream_id, h2_error_refused_stream())
			s = h2_stream_new(c, stream_id)
			s.state = h2_state_open()
			s.headers = out
			s.headers_received = 1
			if (h2_valid_request(out) == 0):
				return h2_stream_error(c, stream_id, h2_error_protocol())
			if (end_stream != 0):
				return h2_on_end_stream_checks(c, s)
			return 0
		# Trailers on an existing request stream.
		if ((s.state != h2_state_open()) && (s.state != h2_state_half_closed_local())):
			hpack_headers_free(out)
			return h2_stream_error(c, stream_id, h2_error_stream_closed())
		if ((end_stream == 0) || (h2_valid_fields(out, c",") == 0)):
			hpack_headers_free(out)
			return h2_stream_error(c, stream_id, h2_error_protocol())
		s.trailers = out
		return h2_on_end_stream_checks(c, s)

	# Client side.
	if (s == 0):
		hpack_headers_free(out)
		if (((stream_id & 1) == 1) && (stream_id < c.next_stream_id)):
			# A stream we already released: ignore.
			return 0
		return h2_conn_error(c, h2_error_protocol(), c"headers on idle stream")
	if ((s.state != h2_state_open()) && (s.state != h2_state_half_closed_local())):
		hpack_headers_free(out)
		return h2_stream_error(c, stream_id, h2_error_stream_closed())
	if (s.headers_received == 0):
		int status = h2_parse_status(out)
		if (status == 0):
			hpack_headers_free(out)
			return h2_stream_error(c, stream_id, h2_error_protocol())
		if (status < 200):
			# Informational (1xx): skipped; the final response follows.
			hpack_headers_free(out)
			if (end_stream != 0):
				return h2_stream_error(c, stream_id, h2_error_protocol())
			return 0
		s.headers = out
		s.status = status
		s.headers_received = 1
		if (end_stream != 0):
			return h2_on_end_stream_checks(c, s)
		return 0
	if ((end_stream == 0) || (h2_valid_fields(out, c",") == 0)):
		hpack_headers_free(out)
		return h2_stream_error(c, stream_id, h2_error_protocol())
	s.trailers = out
	return h2_on_end_stream_checks(c, s)


# Strips padding: sets *start/*len to the fragment. -1 on a malformed
# pad length (connection PROTOCOL_ERROR by the caller).
int h2_unpad(h2_frame* f, int extra, int* start, int* len):
	int pos = 0
	int pad = 0
	if ((f.flags & h2_flag_padded()) != 0):
		if (f.length < 1):
			return (-1)
		pad = f.payload[0] & 255
		pos = 1
	pos = pos + extra
	if (pos + pad > f.length):
		return (-1)
	*start = pos
	*len = f.length - pos - pad
	return 0


int h2_on_headers(h2_conn* c, h2_frame* f):
	if (f.stream_id == 0):
		return h2_conn_error(c, h2_error_protocol(), c"HEADERS on stream 0")
	int extra = 0
	if ((f.flags & h2_flag_priority()) != 0):
		extra = 5
	int start = 0
	int len = 0
	if (h2_unpad(f, extra, &start, &len) != 0):
		return h2_conn_error(c, h2_error_protocol(), c"bad padding")
	int end_stream = (f.flags & h2_flag_end_stream()) != 0
	if ((f.flags & h2_flag_end_headers()) != 0):
		return h2_on_header_block(c, f.stream_id, end_stream, f.payload + start, len)
	c.cont_stream = f.stream_id
	c.cont_end_stream = end_stream
	string_clear(c.cont_block)
	string_append_bytes(c.cont_block, f.payload + start, len)
	return 0


int h2_on_continuation(h2_conn* c, h2_frame* f):
	if ((c.cont_stream == 0) || (f.stream_id != c.cont_stream)):
		return h2_conn_error(c, h2_error_protocol(), c"unexpected CONTINUATION")
	if (c.cont_block.length + f.length > c.max_block):
		return h2_conn_error(c, h2_error_enhance_your_calm(), c"header block too large")
	string_append_bytes(c.cont_block, f.payload, f.length)
	if ((f.flags & h2_flag_end_headers()) == 0):
		return 0
	int id = c.cont_stream
	c.cont_stream = 0
	return h2_on_header_block(c, id, c.cont_end_stream, c.cont_block.data, c.cont_block.length)


# Replenishes a receive window once more than half of it is used.
int h2_replenish(h2_conn* c, h2_stream* s):
	if (c.conn_recv_window < c.local_conn_window / 2):
		if (h2_send_window_update(c, 0, c.local_conn_window - c.conn_recv_window) != 0):
			return (-1)
	if ((s != 0) && (s.end_received == 0) && (s.reset_code < 0) && (s.recv_window < c.local_initial_window / 2)):
		int inc = c.local_initial_window - s.recv_window
		if (h2_send_window_update(c, s.id, inc) != 0):
			return (-1)
		s.recv_window = s.recv_window + inc
	return 0


int h2_on_data(h2_conn* c, h2_frame* f):
	if (f.stream_id == 0):
		return h2_conn_error(c, h2_error_protocol(), c"DATA on stream 0")
	# The whole frame (padding included) counts against flow control.
	if (f.length > c.conn_recv_window):
		return h2_conn_error(c, h2_error_flow_control(), c"connection window exceeded")
	c.conn_recv_window = c.conn_recv_window - f.length
	h2_stream* s = h2_find_stream(c, f.stream_id)
	if (s == 0):
		int ours = ((f.stream_id & 1) == 1) != (c.is_server != 0)
		if (((ours != 0) && (f.stream_id >= c.next_stream_id)) || ((ours == 0) && (f.stream_id > c.last_peer_stream_id))):
			return h2_conn_error(c, h2_error_protocol(), c"DATA on idle stream")
		# A released or refused stream: drop the data, keep the window.
		return h2_replenish(c, 0)
	if ((s.state != h2_state_open()) && (s.state != h2_state_half_closed_local())):
		h2_stream_error(c, s.id, h2_error_stream_closed())
		return h2_replenish(c, 0)
	if ((c.is_server == 0) && (s.headers_received == 0)):
		h2_stream_error(c, s.id, h2_error_protocol())
		return h2_replenish(c, 0)
	if (f.length > s.recv_window):
		h2_stream_error(c, s.id, h2_error_flow_control())
		return h2_replenish(c, 0)
	s.recv_window = s.recv_window - f.length
	int start = 0
	int len = 0
	if (h2_unpad(f, 0, &start, &len) != 0):
		return h2_conn_error(c, h2_error_protocol(), c"bad padding")
	if (s.body.length + len > c.max_body):
		h2_stream_error(c, s.id, h2_error_enhance_your_calm())
		return h2_replenish(c, 0)
	string_append_bytes(s.body, f.payload + start, len)
	if ((f.flags & h2_flag_end_stream()) != 0):
		if (h2_on_end_stream_checks(c, s) != 0):
			return (-1)
	return h2_replenish(c, s)


int h2_on_settings(h2_conn* c, h2_frame* f):
	if (f.stream_id != 0):
		return h2_conn_error(c, h2_error_protocol(), c"SETTINGS on a stream")
	if ((f.flags & h2_flag_ack()) != 0):
		if (f.length != 0):
			return h2_conn_error(c, h2_error_frame_size(), c"SETTINGS ACK with payload")
		c.settings_acks = c.settings_acks + 1
		return 0
	if ((f.length % 6) != 0):
		return h2_conn_error(c, h2_error_frame_size(), c"SETTINGS length")
	int pos = 0
	while (pos < f.length):
		int id = load_be16(f.payload + pos)
		int high = f.payload[pos + 2] & 128
		int v = h2_get_u31(f.payload + pos + 2)
		if (high != 0):
			v = h2_max_window()
		pos = pos + 6
		if (id == h2_settings_header_table_size()):
			hpack_encoder_set_max_table_size(c.enc, v)
		else if (id == h2_settings_enable_push()):
			if ((high != 0) || (v > 1)):
				return h2_conn_error(c, h2_error_protocol(), c"ENABLE_PUSH")
			if ((c.is_server == 0) && (v != 0)):
				return h2_conn_error(c, h2_error_protocol(), c"server ENABLE_PUSH")
			c.peer_enable_push = v
		else if (id == h2_settings_max_concurrent_streams()):
			c.peer_max_concurrent = v
		else if (id == h2_settings_initial_window_size()):
			if (high != 0):
				return h2_conn_error(c, h2_error_flow_control(), c"INITIAL_WINDOW_SIZE")
			int delta = v - c.peer_initial_window
			int i = 0
			while (i < c.streams.length):
				h2_stream* s = c.streams[i]
				if ((delta > 0) && (s.send_window > h2_max_window() - delta)):
					return h2_conn_error(c, h2_error_flow_control(), c"window overflow")
				s.send_window = s.send_window + delta
				i = i + 1
			c.peer_initial_window = v
		else if (id == h2_settings_max_frame_size()):
			if ((high != 0) || (v < h2_default_max_frame()) || (v > h2_max_frame_limit())):
				return h2_conn_error(c, h2_error_protocol(), c"MAX_FRAME_SIZE")
			c.peer_max_frame = v
		else if (id == h2_settings_max_header_list_size()):
			c.peer_max_header_list = v
	c.got_peer_settings = 1
	return h2_write_frame(c, h2_frame_settings(), h2_flag_ack(), 0, f.payload, 0)


int h2_on_ping(h2_conn* c, h2_frame* f):
	if (f.stream_id != 0):
		return h2_conn_error(c, h2_error_protocol(), c"PING on a stream")
	if (f.length != 8):
		return h2_conn_error(c, h2_error_frame_size(), c"PING length")
	if ((f.flags & h2_flag_ack()) != 0):
		c.ping_acked = c.ping_acked + 1
		return 0
	return h2_write_frame(c, h2_frame_ping(), h2_flag_ack(), 0, f.payload, 8)


int h2_on_goaway(h2_conn* c, h2_frame* f):
	if (f.stream_id != 0):
		return h2_conn_error(c, h2_error_protocol(), c"GOAWAY on a stream")
	if (f.length < 8):
		return h2_conn_error(c, h2_error_frame_size(), c"GOAWAY length")
	int last = h2_get_u31(f.payload)
	c.goaway_received = 1
	c.goaway_last_stream = last
	c.goaway_code = h2_get_u31(f.payload + 4)
	if (c.goaway_debug != 0):
		free(c.goaway_debug)
	c.goaway_debug = mem_dup(f.payload + 8, f.length - 8)
	int i = 0
	while (i < c.streams.length):
		h2_stream* s = c.streams[i]
		int mine = ((s.id & 1) == 1) != (c.is_server != 0)
		if ((mine != 0) && (s.id > last) && (h2_stream_active(s) != 0)):
			s.refused = 1
			s.state = h2_state_closed()
		i = i + 1
	return 0


int h2_on_rst_stream(h2_conn* c, h2_frame* f):
	if (f.stream_id == 0):
		return h2_conn_error(c, h2_error_protocol(), c"RST_STREAM on stream 0")
	if (f.length != 4):
		return h2_conn_error(c, h2_error_frame_size(), c"RST_STREAM length")
	h2_stream* s = h2_find_stream(c, f.stream_id)
	if (s == 0):
		int ours = ((f.stream_id & 1) == 1) != (c.is_server != 0)
		if (((ours != 0) && (f.stream_id >= c.next_stream_id)) || ((ours == 0) && (f.stream_id > c.last_peer_stream_id))):
			return h2_conn_error(c, h2_error_protocol(), c"RST_STREAM on idle stream")
		return 0
	s.reset_code = h2_get_u31(f.payload)
	s.reset_by_peer = 1
	s.state = h2_state_closed()
	if (s.reset_code == h2_error_refused_stream()):
		s.refused = 1
	return 0


int h2_on_window_update(h2_conn* c, h2_frame* f):
	if (f.length != 4):
		return h2_conn_error(c, h2_error_frame_size(), c"WINDOW_UPDATE length")
	int inc = h2_get_u31(f.payload)
	if (f.stream_id == 0):
		if (inc == 0):
			return h2_conn_error(c, h2_error_protocol(), c"zero WINDOW_UPDATE")
		if (c.conn_send_window > h2_max_window() - inc):
			return h2_conn_error(c, h2_error_flow_control(), c"connection window overflow")
		c.conn_send_window = c.conn_send_window + inc
		return 0
	h2_stream* s = h2_find_stream(c, f.stream_id)
	if (s == 0):
		return 0
	if (inc == 0):
		return h2_stream_error(c, s.id, h2_error_protocol())
	if (s.send_window > h2_max_window() - inc):
		return h2_stream_error(c, s.id, h2_error_flow_control())
	s.send_window = s.send_window + inc
	return 0


int h2_on_priority(h2_conn* c, h2_frame* f):
	if (f.stream_id == 0):
		return h2_conn_error(c, h2_error_protocol(), c"PRIORITY on stream 0")
	if (f.length != 5):
		return h2_stream_error(c, f.stream_id, h2_error_frame_size())
	return 0


# Dispatches one frame. 0 to continue, -1 when the connection died.
int h2_handle_frame(h2_conn* c, h2_frame* f):
	int t = f.type
	if ((c.cont_stream != 0) && (t != h2_frame_continuation())):
		return h2_conn_error(c, h2_error_protocol(), c"expected CONTINUATION")
	if ((c.got_peer_settings == 0) && ((t != h2_frame_settings()) || ((f.flags & h2_flag_ack()) != 0))):
		return h2_conn_error(c, h2_error_protocol(), c"first frame must be SETTINGS")
	if (t == h2_frame_data()):
		return h2_on_data(c, f)
	if (t == h2_frame_headers()):
		return h2_on_headers(c, f)
	if (t == h2_frame_priority()):
		return h2_on_priority(c, f)
	if (t == h2_frame_rst_stream()):
		return h2_on_rst_stream(c, f)
	if (t == h2_frame_settings()):
		return h2_on_settings(c, f)
	if (t == h2_frame_push_promise()):
		return h2_conn_error(c, h2_error_protocol(), c"PUSH_PROMISE with push disabled")
	if (t == h2_frame_ping()):
		return h2_on_ping(c, f)
	if (t == h2_frame_goaway()):
		return h2_on_goaway(c, f)
	if (t == h2_frame_window_update()):
		return h2_on_window_update(c, f)
	if (t == h2_frame_continuation()):
		return h2_on_continuation(c, f)
	return 0


# Reads and handles one frame. 0 ok, -1 connection dead, -2 deadline.
int h2_pump(h2_conn* c):
	if (c.dead != 0):
		return (-1)
	int rc = h2_fill(c, 9)
	if (rc != 0):
		return rc
	char* head = c.rbuf + c.rstart
	int len = load_be24(head)
	if (len > c.local_max_frame):
		return h2_conn_error(c, h2_error_frame_size(), c"frame too large")
	rc = h2_fill(c, 9 + len)
	if (rc != 0):
		return rc
	head = c.rbuf + c.rstart
	h2_frame f
	f.length = len
	f.type = head[3] & 255
	f.flags = head[4] & 255
	f.stream_id = h2_get_u31(head + 5)
	f.payload = head + 9
	c.rstart = c.rstart + 9 + len
	if (h2_handle_frame(c, &f) != 0):
		return (-1)
	if (c.dead != 0):
		return (-1)
	return 0


/* Sending */

# Encodes headers and writes HEADERS (+ CONTINUATION) frames split at
# the peer's max frame size.
int h2_write_header_block(h2_conn* c, int stream_id, list[hpack_header*] headers, int end_stream):
	string_builder* block = string_new()
	hpack_encode(c.enc, headers, block)
	int pos = 0
	int first = 1
	int rc = 0
	while ((rc == 0) && ((first != 0) || (pos < block.length))):
		int n = h2_min(block.length - pos, c.peer_max_frame)
		int flags = 0
		if (pos + n == block.length):
			flags = h2_flag_end_headers()
		if (first != 0):
			if (end_stream != 0):
				flags = flags | h2_flag_end_stream()
			rc = h2_write_frame(c, h2_frame_headers(), flags, stream_id, block.data + pos, n)
		else:
			rc = h2_write_frame(c, h2_frame_continuation(), flags, stream_id, block.data + pos, n)
		pos = pos + n
		first = 0
	string_free(block)
	return rc


int h2_stream_can_send(h2_stream* s):
	return ((s.state == h2_state_open()) || (s.state == h2_state_half_closed_remote()) || (s.state == h2_state_idle())) && (s.reset_code < 0) && (s.refused == 0)


int h2_send_headers(h2_conn* c, h2_stream* s, list[hpack_header*] headers, int end_stream):
	if ((c.dead != 0) || (h2_stream_can_send(s) == 0)):
		return (-1)
	if (s.state == h2_state_idle()):
		s.state = h2_state_open()
	if (h2_write_header_block(c, s.id, headers, end_stream) != 0):
		return (-1)
	if (end_stream != 0):
		h2_on_end_sent(s)
	return 0


int h2_send_trailers(h2_conn* c, h2_stream* s, list[hpack_header*] trailers):
	return h2_send_headers(c, s, trailers, 1)


# Sends DATA within the connection and stream send windows, pumping
# incoming frames while a window is closed. len == 0 with end_stream
# sends an empty END_STREAM frame.
int h2_send_data(h2_conn* c, h2_stream* s, char* data, int len, int end_stream):
	int pos = 0
	while (1):
		if ((c.dead != 0) || (h2_stream_can_send(s) == 0) || (s.state == h2_state_idle())):
			return (-1)
		int left = len - pos
		int n = h2_min(left, c.peer_max_frame)
		n = h2_min(n, c.conn_send_window)
		n = h2_min(n, s.send_window)
		if ((left > 0) && (n <= 0)):
			int rc = h2_pump(c)
			if (rc != 0):
				return rc
			continue
		if (n < 0):
			n = 0
		int flags = 0
		if ((pos + n == len) && (end_stream != 0)):
			flags = h2_flag_end_stream()
		if (h2_write_frame(c, h2_frame_data(), flags, s.id, data + pos, n) != 0):
			return (-1)
		c.conn_send_window = c.conn_send_window - n
		s.send_window = s.send_window - n
		pos = pos + n
		if (pos == len):
			break
	if (end_stream != 0):
		h2_on_end_sent(s)
	return 0


int h2_send_rst(h2_conn* c, h2_stream* s, int code):
	if (h2_stream_active(s) == 0):
		return 0
	s.reset_code = code
	s.state = h2_state_closed()
	return h2_write_rst(c, s.id, code)


void h2_goaway(h2_conn* c, int code):
	if (c.dead != 0):
		return
	h2_send_goaway(c, code, 0)


# Sends a PING and pumps until its ACK. 0 on success.
int h2_ping(h2_conn* c):
	char* p = malloc(8)
	c.ping_sent = c.ping_sent + 1
	store_be32(p, 0)
	store_be32(p + 4, c.ping_sent)
	int rc = h2_write_frame(c, h2_frame_ping(), 0, 0, p, 8)
	free(p)
	if (rc != 0):
		return rc
	while (c.ping_acked < c.ping_sent):
		rc = h2_pump(c)
		if (rc != 0):
			return rc
	return 0


void h2_close(h2_conn* c):
	if (c == 0):
		return
	if (c.dead == 0):
		h2_send_goaway(c, h2_error_no_error(), 0)
	if (c.tls != 0):
		tls_close(c.tls)
		c.tls = 0
	if (c.own_tls_cfg != 0):
		tls_config_free(c.own_tls_cfg)
	close(c.fd)
	while (c.streams.length > 0):
		h2_stream* s = c.streams[0]
		s.state = h2_state_closed()
		h2_stream_free(c, s)
	list_free[h2_stream*](c.streams)
	hpack_encoder_free(c.enc)
	hpack_decoder_free(c.dec)
	string_free(c.cont_block)
	if (c.goaway_debug != 0):
		free(c.goaway_debug)
	free(c.rbuf)
	free(c)


/* Client */

char* h2_lower_copy(char* s):
	int n = strlen(s)
	char* out = malloc(n + 1)
	int i = 0
	while (i <= n):
		int ch = s[i] & 255
		if ((ch >= 'A') && (ch <= 'Z')):
			ch = ch + 32
		out[i] = ch
		i = i + 1
	return out


# Appends lowercased copies of extra's fields to l.
void h2_append_extra(list[hpack_header*] l, list[hpack_header*] extra):
	if (extra == 0):
		return
	int i = 0
	while (i < extra.length):
		hpack_header* h = extra[i]
		char* name = h2_lower_copy(h.name)
		hpack_header* copy = hpack_header_new(name, strlen(name), h.value, h.value_len)
		copy.sensitive = h.sensitive
		l.push(copy)
		free(name)
		i = i + 1


# Opens a stream and sends the request HEADERS. Waits (pumping) while
# the peer's MAX_CONCURRENT_STREAMS is reached. 0 when no stream can be
# opened (connection dead, GOAWAY received, ids exhausted).
h2_stream* h2_request_start(h2_conn* c, char* method, char* scheme, char* authority, char* path, list[hpack_header*] extra, int end_stream):
	while ((c.dead == 0) && (c.goaway_received == 0) && (h2_active_count(c, 1) >= c.peer_max_concurrent)):
		if (h2_pump(c) != 0):
			return 0
	if ((c.dead != 0) || (c.goaway_received != 0) || (c.next_stream_id > 2147483645)):
		return 0
	list[hpack_header*] l = hpack_headers_new()
	hpack_headers_add(l, c":method", method)
	hpack_headers_add(l, c":scheme", scheme)
	hpack_headers_add(l, c":authority", authority)
	hpack_headers_add(l, c":path", path)
	h2_append_extra(l, extra)
	h2_stream* s = h2_stream_new(c, c.next_stream_id)
	c.next_stream_id = c.next_stream_id + 2
	int rc = h2_send_headers(c, s, l, end_stream)
	hpack_headers_free(l)
	if (rc != 0):
		s.state = h2_state_closed()
		s.reset_code = h2_error_internal()
	return s


# Pumps until the peer's first SETTINGS frame was processed, so sends
# honor its windows and limits instead of the RFC defaults.
int h2_await_settings(h2_conn* c):
	while (c.got_peer_settings == 0):
		int rc = h2_pump(c)
		if (rc != 0):
			return rc
	return 0


int h2_await_headers(h2_conn* c, h2_stream* s):
	while ((s.headers_received == 0) && (s.reset_code < 0) && (s.refused == 0)):
		int rc = h2_pump(c)
		if (rc != 0):
			return rc
	if ((s.reset_code >= 0) || (s.refused != 0)):
		return (-1)
	return 0


int h2_await_end(h2_conn* c, h2_stream* s):
	while ((s.end_received == 0) && (s.reset_code < 0) && (s.refused == 0)):
		int rc = h2_pump(c)
		if (rc != 0):
			return rc
	if ((s.reset_code >= 0) || (s.refused != 0)):
		return (-1)
	return 0


# One whole request/response exchange. Returns the stream (check
# h2_stream_ok; free with h2_stream_free), or 0 when no stream could be
# opened.
h2_stream* h2_request(h2_conn* c, char* method, char* scheme, char* authority, char* path, list[hpack_header*] extra, char* body, int body_len):
	int no_body = (body == 0) || (body_len == 0)
	h2_stream* s = h2_request_start(c, method, scheme, authority, path, extra, no_body)
	if (s == 0):
		return 0
	if ((no_body == 0) && (h2_send_data(c, s, body, body_len, 1) != 0)):
		return s
	h2_await_end(c, s)
	return s


/* Server */

# Pumps until some stream carries a complete request (END_STREAM seen)
# that was not handed out yet. 0 when the connection ends.
h2_stream* h2_server_next_request(h2_conn* c):
	while (1):
		int i = 0
		while (i < c.streams.length):
			h2_stream* s = c.streams[i]
			if ((s.delivered == 0) && (s.end_received != 0) && (s.reset_code < 0)):
				s.delivered = 1
				return s
			i = i + 1
		if (h2_pump(c) != 0):
			return 0
	return 0


int h2_respond_headers(h2_conn* c, h2_stream* s, int status, list[hpack_header*] extra, int end_stream):
	list[hpack_header*] l = hpack_headers_new()
	char* st = itoa(status)
	hpack_headers_add(l, c":status", st)
	free(st)
	h2_append_extra(l, extra)
	int rc = h2_send_headers(c, s, l, end_stream)
	hpack_headers_free(l)
	return rc


int h2_respond(h2_conn* c, h2_stream* s, int status, list[hpack_header*] extra, char* body, int len):
	int no_body = (body == 0) || (len == 0)
	if (h2_respond_headers(c, s, status, extra, no_body) != 0):
		return (-1)
	if (no_body != 0):
		return 0
	return h2_send_data(c, s, body, len, 1)
