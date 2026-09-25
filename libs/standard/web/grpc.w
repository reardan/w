# gRPC over HTTP/2 (libs/standard/web/http2.w), part of issue #436
# ("Protocols"). Implements the gRPC-over-HTTP/2 wire protocol
# (PROTOCOL-HTTP2.md in the grpc repository) for unary, server-streaming,
# client-streaming and bidirectional-streaming RPCs:
#   request:  HEADERS  :method POST, :scheme, :path /pkg.Service/Method,
#                      :authority, content-type application/grpc,
#                      te trailers, grpc-timeout (optional),
#                      grpc-encoding / grpc-accept-encoding, metadata
#             DATA     length-prefixed messages; END_STREAM half-closes
#   response: HEADERS  :status 200, content-type application/grpc,
#                      grpc-encoding / grpc-accept-encoding
#             DATA     length-prefixed messages
#             HEADERS  grpc-status, grpc-message (trailers, END_STREAM)
#   or a "trailers-only" response: a single HEADERS frame carrying
#   :status, content-type, grpc-status and grpc-message with END_STREAM.
# A length-prefixed message is a 1-byte compressed flag, a 4-byte
# big-endian length and the (possibly compressed) bytes.
#
# Transports: cleartext h2c (grpc_channel_open / grpc_server_serve_conn)
# or TLS 1.3 with ALPN "h2" (grpc_channel_open_tls /
# grpc_server_serve_conn_tls, built on h2_connect_tls / h2_accept_tls
# in http2.w). Everything above the h2_conn is transport-agnostic; the
# only difference on the wire is :scheme https.
#
# Messages are opaque bytes here: this file does not depend on a
# serializer, so it stays inside libs/standard. Pair it with
# libs/extras/protobuf/message.w (pb_encode / pb_decode_into) as
# libs/standard/web/grpc_test.w does.
#
# Compression: codings come from the content-coding registry in
# libs/standard/web/codec.w, never from a direct libs/extras import. An
# application that wants gzip/deflate calls compress_codecs_register()
# from libs/extras/compress/codecs.w once; without it only identity is
# offered, which is a complete configuration. Both sides send
# grpc-accept-encoding (the registered names) whenever something is
# registered. The client compresses every request message with the
# channel's coding (grpc_channel_set_compression; grpc-encoding header,
# compressed flag 1). The server answers with the server's configured
# coding (grpc_server_set_compression) when the client accepts it, else
# mirrors the request's coding when the client accepts that, else
# identity; a handler can override per call (grpc_call_set_compression)
# before its first message. A request whose grpc-encoding is not
# registered is answered UNIMPLEMENTED (trailers-only, with the
# server's grpc-accept-encoding); on the client an unsupported response
# coding, or a compressed flag without a grpc-encoding, is INTERNAL.
# Both the wire length and the DECOMPRESSED length of every message are
# capped at max_message (grpc_channel.max_message /
# grpc_server.max_message, default 4 MiB): the decoder stops the moment
# the output would pass the cap and the call fails RESOURCE_EXHAUSTED.
#
# Public API (common):
#   int  grpc_status_ok() ... grpc_status_unauthenticated()   codes 0..16
#   char* grpc_status_name(int code)
#   void grpc_frame_message(string_builder* out, char* msg, int len)   flag 0
#   int  grpc_encode_message(string_builder* out, char* encoding, char* msg, int len)
#                                             flag 1 + compressed unless identity;
#                                             a codec_* status
#   int  grpc_unframe_message(char* body, int len, int max, char** out, int* out_len)
#                                             exactly one uncompressed message;
#                                             a status code; *out is malloc'd
#   int  grpc_take_message(string_builder* buf, char* encoding, int max, char** out,
#                          int* out_len, int* compressed, int* status, char** why)
#                                             pops one message off the front of
#                                             buf: 1 got / 0 incomplete / -1 bad
#   char* grpc_percent_encode(char* s) / char* grpc_percent_decode(char* s)
#   char* grpc_timeout_format(int ms) / int grpc_timeout_parse(char* v, int* out_ms)
#   int  grpc_status_from_http(int http_status)
#   int  grpc_status_from_h2_error(int h2_code)
#
# Public API (client):
#   grpc_channel* grpc_channel_open(char* host, int port, int timeout_ms)   0 on failure
#   grpc_channel* grpc_channel_open_tls(char* host, int port, int timeout_ms,
#                                       char* server_name, tls_config* cfg)
#                                             gRPC over TLS 1.3 + ALPN "h2"
#                                             (h2_connect_tls); :scheme https;
#                                             0 on failure
#   grpc_channel* grpc_channel_from_conn(h2_conn* c, char* authority)       borrows c;
#                                             :scheme https when c.tls is set
#   int  grpc_channel_set_compression(grpc_channel* ch, char* encoding)     1 = set; 0 or
#                                             "identity" turns it off; 0 when unregistered
#   grpc_result*  grpc_unary_call(grpc_channel* ch, char* method, char* req, int req_len,
#                                 list[hpack_header*] metadata, int timeout_ms)
#   char* grpc_result_header(grpc_result* r, char* name)
#   char* grpc_result_trailer(grpc_result* r, char* name)
#   void grpc_result_free(grpc_result* r)
#   void grpc_channel_close(grpc_channel* ch)
# Streaming calls (any of the three kinds; unary is built on these):
#   grpc_client_stream* grpc_stream_open(grpc_channel* ch, char* method,
#                                 list[hpack_header*] metadata, int timeout_ms)   never 0
#   int  grpc_stream_send(grpc_client_stream* cs, char* msg, int len)   0 / -1
#   int  grpc_stream_close_send(grpc_client_stream* cs)                 half-close; 0 / -1
#   int  grpc_stream_recv(grpc_client_stream* cs, char** out, int* out_len)
#                                             1 = a message (*out malloc'd),
#                                             0 = responses ended with OK,
#                                             -1 = the call failed
#   char* grpc_stream_header(grpc_client_stream* cs, char* name)  response header,
#                                             0 before the headers arrived
#   int  grpc_stream_status(grpc_client_stream* cs)   -1 while the call is live
#   void grpc_stream_cancel(grpc_client_stream* cs)   RST_STREAM(CANCEL), CANCELLED
#   grpc_result* grpc_stream_finish(grpc_client_stream* cs)
#                                             half-closes if needed, discards unread
#                                             responses, waits for the status, frees cs;
#                                             the result carries status, message,
#                                             headers and trailers (response == 0)
# A send that fails because the server already finished returns -1
# without deciding the status: keep calling grpc_stream_recv (or
# grpc_stream_finish) to read what the server sent and its status.
#
# Public API (server):
#   type grpc_unary_handler_fn = fn(grpc_call*, void*) -> void
#   grpc_server* grpc_server_new()
#   void grpc_server_register(grpc_server* s, char* path, grpc_unary_handler_fn* h, void* user_data)
#                                             unary: call.request holds the one
#                                             request message; reply with
#                                             grpc_call_reply
#   void grpc_server_register_stream(grpc_server* s, char* path, grpc_unary_handler_fn* h,
#                                    void* user_data)
#                                             streaming (client, server or bidi):
#                                             the handler runs as soon as the
#                                             request headers arrive and uses
#                                             grpc_call_recv / grpc_call_send
#   int  grpc_server_set_compression(grpc_server* s, char* encoding)   preferred response
#                                             coding; 1 = set, 0 when unregistered
#   int  grpc_server_serve_conn(grpc_server* s, int fd)   serves one accepted connection;
#                                                         0 on a clean end, else the h2 error
#   int  grpc_server_serve_conn_tls(grpc_server* s, int fd, tls_server_config* scfg)
#                                             same over TLS (h2_accept_tls; ALPN "h2"
#                                             required); PROTOCOL_ERROR when the
#                                             handshake fails (fd closed)
#   int  grpc_server_serve_h2(grpc_server* s, h2_conn* c)   serves an established
#                                             connection (either transport), closes it
#   void grpc_call_reply(grpc_call* call, char* msg, int len)     unary; copies msg
#   int  grpc_call_recv(grpc_call* call, char** out, int* out_len)
#                                             1 = a message (*out malloc'd), 0 = the
#                                             client half-closed, -1 = cancelled,
#                                             deadline passed or bad message (the
#                                             call's status is already set)
#   int  grpc_call_send(grpc_call* call, char* msg, int len)   0 / -1 (cancelled by the
#                                             client, deadline passed, connection gone)
#   int  grpc_call_set_compression(grpc_call* call, char* encoding)   before the first
#                                             message; 1 when set (registered and
#                                             accepted by the client)
#   void grpc_call_fail(grpc_call* call, int status, char* message)
#   void grpc_call_add_header(grpc_call* call, char* name, char* value)
#   void grpc_call_add_trailer(grpc_call* call, char* name, char* value)
#   char* grpc_call_metadata(grpc_call* call, char* name)
#   int  grpc_call_time_left_ms(grpc_call* call)    -1 when no deadline
#   grpc_call.cancelled (client reset the stream), grpc_call.recv_compressed
#   (count of compressed request messages), grpc_call.send_encoding
#   void grpc_server_free(grpc_server* s)
# A streaming handler finishes by returning: the status is OK unless it
# called grpc_call_fail. Response headers go out with the first message
# (call.headers_first = 1 forces them out before an error status);
# a handler that sent nothing gets a trailers-only response.
#
# Model: single-threaded and blocking, like http2.w. The client can keep
# several calls open on one channel and interleave them (a blocked
# send or receive pumps frames for every stream). The server runs one
# call at a time per connection; frames for other streams are buffered
# (up to h2_conn.max_body per stream) while a handler runs. Receive
# windows are replenished as DATA arrives rather than as messages are
# consumed, so two peers that both block in send (a bidi call where
# neither side reads) never deadlock on flow control; unread input is
# bounded by max_body instead (RST_STREAM(ENHANCE_YOUR_CALM) ->
# RESOURCE_EXHAUSTED). Sends honor the peer's windows (h2_send_data),
# and before every message they process frames that are already
# readable, so a sender notices a cancellation (RST_STREAM) or an early
# server status without waiting for a window to close.
#
# Deadlines: the client sends grpc-timeout (milliseconds) and bounds
# every blocking step of the call with h2_set_deadline; on expiry the
# stream is cancelled with RST_STREAM(CANCEL), the call returns
# DEADLINE_EXCEEDED, and the connection stays usable. The server parses
# grpc-timeout into grpc_call.deadline_ms (any unit, H/M/S/m/u/n),
# bounds grpc_call_recv / grpc_call_send by it, and answers
# DEADLINE_EXCEEDED once it has passed (for unary calls, instead of the
# handler's reply).
#
# Status mapping on the client: grpc-status from the trailers (or from
# the headers of a trailers-only response) wins; a non-200 HTTP status
# maps per the gRPC HTTP-to-status table; a missing grpc-status,
# non-gRPC content-type, or a message count other than one on unary
# success is INTERNAL/UNKNOWN; RST_STREAM codes map per the spec
# (REFUSED_STREAM and GOAWAY-refused streams -> UNAVAILABLE, CANCEL ->
# CANCELLED, ENHANCE_YOUR_CALM -> RESOURCE_EXHAUSTED); a dead connection
# is UNAVAILABLE. grpc-message is percent-encoded on the wire and decoded
# into grpc_result.message.
import lib.lib
import lib.time
import lib.container
import structures.string
import libs.standard.web.hpack
import libs.standard.web.http2
import libs.standard.web.codec
import lib.hex
import lib.bytes
import lib.mem


/* Status codes */

int grpc_status_ok():
	return 0


int grpc_status_cancelled():
	return 1


int grpc_status_unknown():
	return 2


int grpc_status_invalid_argument():
	return 3


int grpc_status_deadline_exceeded():
	return 4


int grpc_status_not_found():
	return 5


int grpc_status_already_exists():
	return 6


int grpc_status_permission_denied():
	return 7


int grpc_status_resource_exhausted():
	return 8


int grpc_status_failed_precondition():
	return 9


int grpc_status_aborted():
	return 10


int grpc_status_out_of_range():
	return 11


int grpc_status_unimplemented():
	return 12


int grpc_status_internal():
	return 13


int grpc_status_unavailable():
	return 14


int grpc_status_data_loss():
	return 15


int grpc_status_unauthenticated():
	return 16


char* grpc_status_name(int code):
	if (code == 0):
		return c"OK"
	if (code == 1):
		return c"CANCELLED"
	if (code == 2):
		return c"UNKNOWN"
	if (code == 3):
		return c"INVALID_ARGUMENT"
	if (code == 4):
		return c"DEADLINE_EXCEEDED"
	if (code == 5):
		return c"NOT_FOUND"
	if (code == 6):
		return c"ALREADY_EXISTS"
	if (code == 7):
		return c"PERMISSION_DENIED"
	if (code == 8):
		return c"RESOURCE_EXHAUSTED"
	if (code == 9):
		return c"FAILED_PRECONDITION"
	if (code == 10):
		return c"ABORTED"
	if (code == 11):
		return c"OUT_OF_RANGE"
	if (code == 12):
		return c"UNIMPLEMENTED"
	if (code == 13):
		return c"INTERNAL"
	if (code == 14):
		return c"UNAVAILABLE"
	if (code == 15):
		return c"DATA_LOSS"
	if (code == 16):
		return c"UNAUTHENTICATED"
	return c"UNKNOWN"


# Default cap on one message (the common gRPC receive default, 4 MiB).
int grpc_default_max_message():
	return 4194304


/* Message framing */

# Parses a whole body of exactly one uncompressed length-prefixed
# message (a compressed flag is UNIMPLEMENTED here; streams with a
# grpc-encoding go through grpc_take_message). Returns
# grpc_status_ok() and a malloc'd copy in *out (NUL-terminated, length
# in *out_len), or the status to fail the call with.
int grpc_unframe_message(char* body, int len, int max, char** out, int* out_len):
	*out = 0
	*out_len = 0
	if (len < 5):
		return grpc_status_internal()
	int flag = body[0] & 255
	if (flag == 1):
		return grpc_status_unimplemented()
	if (flag != 0):
		return grpc_status_internal()
	if ((body[1] & 128) != 0):
		return grpc_status_resource_exhausted()
	int n = h2_get_u31(body + 1)
	if (n > max):
		return grpc_status_resource_exhausted()
	if (n != len - 5):
		return grpc_status_internal()
	*out = mem_dup(body + 5, n)
	*out_len = n
	return grpc_status_ok()


# Appends one length-prefixed message with the given compressed flag.
void grpc_frame_message_flag(string_builder* out, int flag, char* msg, int len):
	string_append_char(out, flag)
	string_append_be32(out, len)
	string_append_bytes(out, msg, len)


void grpc_frame_message(string_builder* out, char* msg, int len):
	grpc_frame_message_flag(out, 0, msg, len)


# Frames msg for a message stream whose grpc-encoding is encoding:
# identity (0 / "identity") -> flag 0, as is; otherwise compressed with
# the registered codec, flag 1. Returns a codec_* status.
int grpc_encode_message(string_builder* out, char* encoding, char* msg, int len):
	if (codec_is_identity(encoding) != 0):
		grpc_frame_message_flag(out, 0, msg, len)
		return codec_ok()
	char* packed = 0
	int packed_len = 0
	int rc = codec_compress(encoding, msg, len, &packed, &packed_len)
	if (rc != codec_ok()):
		return rc
	grpc_frame_message_flag(out, 1, packed, packed_len)
	free(packed)
	return codec_ok()


# Drops the first n bytes of a receive buffer.
void grpc_consume(string_builder* buf, int n):
	int rest = buf.length - n
	mem_copy(buf.data, buf.data + n, rest)
	buf.length = rest
	buf.data[rest] = 0


# Pops one message off the front of a stream's receive buffer, whose
# peer declared grpc-encoding encoding (0 when absent). Returns 1 with a
# malloc'd, NUL-terminated message in *out (*compressed says whether it
# had the flag), 0 when the buffer does not hold a whole message yet, or
# -1 with the status to fail the call with in *status and a static
# reason in *why. Both the wire length and the decompressed length are
# capped at max (RESOURCE_EXHAUSTED).
int grpc_take_message(string_builder* buf, char* encoding, int max, char** out, int* out_len, int* compressed, int* status, char** why):
	*out = 0
	*out_len = 0
	*compressed = 0
	*status = grpc_status_ok()
	*why = c""
	if (buf.length < 5):
		return 0
	char* p = buf.data
	int flag = p[0] & 255
	if (flag > 1):
		*status = grpc_status_internal()
		*why = c"invalid message flag"
		return (-1)
	if (((p[1] & 128) != 0) || (h2_get_u31(p + 1) > max)):
		*status = grpc_status_resource_exhausted()
		*why = c"message larger than the limit"
		return (-1)
	int n = h2_get_u31(p + 1)
	if (buf.length < 5 + n):
		return 0
	if (flag == 0):
		*out = mem_dup(p + 5, n)
		*out_len = n
		grpc_consume(buf, 5 + n)
		return 1
	if (codec_is_identity(encoding) != 0):
		*status = grpc_status_internal()
		*why = c"compressed message without grpc-encoding"
		return (-1)
	int rc = codec_decompress(encoding, p + 5, n, max, out, out_len)
	if (rc == codec_err_too_large()):
		*status = grpc_status_resource_exhausted()
		*why = c"decompressed message larger than the limit"
		return (-1)
	if (rc == codec_err_unsupported()):
		*status = grpc_status_unimplemented()
		*why = c"unsupported grpc-encoding"
		return (-1)
	if (rc != codec_ok()):
		*status = grpc_status_internal()
		*why = c"corrupt compressed message"
		return (-1)
	*compressed = 1
	grpc_consume(buf, 5 + n)
	return 1


/* grpc-message percent-encoding */

# Bytes outside printable ASCII (0x20-0x7E), and '%' itself, become %XX.
char* grpc_percent_encode(char* s):
	string_builder* out = string_new()
	int i = 0
	while (s[i] != 0):
		int c = s[i] & 255
		if ((c < 32) || (c > 126) || (c == '%')):
			string_append_char(out, '%')
			string_append_char(out, hex_digit_upper(c >> 4))
			string_append_char(out, hex_digit_upper(c & 15))
		else:
			string_append_char(out, c)
		i = i + 1
	char* data = out.data
	free(out)
	return data


# Decodes %XX sequences; a malformed sequence is kept literally (the
# spec asks receivers not to fail on bad encoding).
char* grpc_percent_decode(char* s):
	string_builder* out = string_new()
	int i = 0
	while (s[i] != 0):
		int c = s[i] & 255
		if (c == '%'):
			if (s[i + 1] != 0):
				int hi = hex_decode_char(s[i + 1] & 255)
				int lo = hex_decode_char(s[i + 2] & 255)
				if ((hi >= 0) && (lo >= 0)):
					string_append_char(out, (hi << 4) | lo)
					i = i + 3
					continue
		string_append_char(out, c)
		i = i + 1
	char* data = out.data
	free(out)
	return data


/* grpc-timeout */

# At most 8 digits: milliseconds while they fit, else whole seconds.
char* grpc_timeout_format(int ms):
	if (ms < 0):
		ms = 0
	string_builder* out = string_new()
	if (ms <= 99999999):
		string_append_int(out, ms)
		string_append(out, c"m")
	else:
		string_append_int(out, (ms + 999) / 1000)
		string_append(out, c"S")
	char* data = out.data
	free(out)
	return data


# Parses "<1-8 digits><H|M|S|m|u|n>" into milliseconds (sub-millisecond
# values round up to 1 so a live deadline never reads as 0; huge values
# saturate). 1 on success, 0 when malformed.
int grpc_timeout_parse(char* v, int* out_ms):
	int n = 0
	int i = 0
	while ((v[i] >= '0') && (v[i] <= '9')):
		if (i >= 8):
			return 0
		n = n * 10 + (v[i] - '0')
		i = i + 1
	if ((i == 0) || (v[i] == 0) || (v[i + 1] != 0)):
		return 0
	int unit = v[i]
	int cap = 2147483647
	int ms = 0
	if (unit == 'H'):
		if (n > cap / 3600000):
			ms = cap
		else:
			ms = n * 3600000
	else if (unit == 'M'):
		if (n > cap / 60000):
			ms = cap
		else:
			ms = n * 60000
	else if (unit == 'S'):
		if (n > cap / 1000):
			ms = cap
		else:
			ms = n * 1000
	else if (unit == 'm'):
		ms = n
	else if (unit == 'u'):
		ms = (n + 999) / 1000
	else if (unit == 'n'):
		ms = (n + 999999) / 1000000
	else:
		return 0
	*out_ms = ms
	return 1


/* Status mapping */

# gRPC's HTTP status -> status code table for non-200 responses.
int grpc_status_from_http(int http_status):
	if (http_status == 400):
		return grpc_status_internal()
	if (http_status == 401):
		return grpc_status_unauthenticated()
	if (http_status == 403):
		return grpc_status_permission_denied()
	if (http_status == 404):
		return grpc_status_unimplemented()
	if ((http_status == 429) || (http_status == 502) || (http_status == 503) || (http_status == 504)):
		return grpc_status_unavailable()
	return grpc_status_unknown()


int grpc_status_from_h2_error(int h2_code):
	if ((h2_code == h2_error_no_error()) || (h2_code == h2_error_protocol()) || (h2_code == h2_error_internal()) || (h2_code == h2_error_flow_control()) || (h2_code == h2_error_settings_timeout()) || (h2_code == h2_error_frame_size()) || (h2_code == h2_error_compression()) || (h2_code == h2_error_connect())):
		return grpc_status_internal()
	if (h2_code == h2_error_refused_stream()):
		return grpc_status_unavailable()
	if (h2_code == h2_error_cancel()):
		return grpc_status_cancelled()
	if (h2_code == h2_error_enhance_your_calm()):
		return grpc_status_resource_exhausted()
	if (h2_code == h2_error_inadequate_security()):
		return grpc_status_permission_denied()
	return grpc_status_unknown()


# Parses a grpc-status value: 1-2 digits, 0..16; anything else UNKNOWN.
int grpc_parse_status(char* v):
	if ((v == 0) || (v[0] < '0') || (v[0] > '9')):
		return grpc_status_unknown()
	int n = v[0] - '0'
	if (v[1] != 0):
		if ((v[1] < '0') || (v[1] > '9') || (v[2] != 0)):
			return grpc_status_unknown()
		n = n * 10 + (v[1] - '0')
	if (n > 16):
		return grpc_status_unknown()
	return n


int grpc_is_grpc_content_type(char* ct):
	if (ct == 0):
		return 0
	char* want = c"application/grpc"
	int i = 0
	while (want[i] != 0):
		if (ct[i] != want[i]):
			return 0
		i = i + 1
	return (ct[i] == 0) || (ct[i] == '+') || (ct[i] == ';')


/* Pumping without blocking */

# Handles frames that can be read without waiting (h2_conn_has_pending:
# a complete frame buffered, unconsumed TLS plaintext, or a readable
# socket), at most 64 of them, so a
# sender notices RST_STREAM or an early END_STREAM from the peer before
# its window closes. A frame that arrives only partially is waited for
# at most 20 ms (the rest stays buffered). The caller's deadline is kept.
void grpc_pump_ready(h2_conn* c):
	int saved = c.deadline_ms
	int n = 0
	while ((n < 64) && (c.dead == 0)):
		if (h2_conn_has_pending(c) == 0):
			break
		int dl = time_monotonic_ms() + 20
		if ((saved != 0) && (saved < dl)):
			dl = saved
		h2_set_deadline(c, dl)
		int rc = h2_pump(c)
		h2_set_deadline(c, saved)
		if (rc != 0):
			break
		n = n + 1
	h2_set_deadline(c, saved)


# grpc-accept-encoding value for this process: the registered codings,
# or 0 when there are none (identity only; nothing to advertise).
char* grpc_accept_value():
	char* v = codec_accept_list()
	if (v[0] == 0):
		free(v)
		return 0
	return v


void grpc_add_accept_encoding(list[hpack_header*] l, int always):
	char* v = grpc_accept_value()
	if (v != 0):
		hpack_headers_add(l, c"grpc-accept-encoding", v)
		free(v)
	else if (always != 0):
		hpack_headers_add(l, c"grpc-accept-encoding", c"identity")


/* Client */

struct grpc_channel:
	h2_conn* conn
	char* authority
	char* scheme
	int owns_conn
	int max_message
	char* send_encoding


struct grpc_result:
	int status
	char* message
	char* response
	int response_len
	int http_status
	list[hpack_header*] headers
	list[hpack_header*] trailers


grpc_channel* grpc_channel_from_conn(h2_conn* c, char* authority):
	grpc_channel* ch = new grpc_channel()
	ch.conn = c
	ch.authority = strclone(authority)
	ch.scheme = c"http"
	if (c.tls != 0):
		ch.scheme = c"https"
	ch.owns_conn = 0
	ch.max_message = grpc_default_max_message()
	ch.send_encoding = 0
	return ch


grpc_channel* grpc_channel_open(char* host, int port, int timeout_ms):
	h2_conn* c = h2_connect(host, port, timeout_ms)
	if (c == 0):
		return 0
	string_builder* auth = string_new()
	string_append(auth, host)
	string_append(auth, c":")
	string_append_int(auth, port)
	grpc_channel* ch = grpc_channel_from_conn(c, auth.data)
	string_free(auth)
	ch.owns_conn = 1
	return ch


# gRPC over TLS: h2_connect_tls (TLS 1.3, ALPN "h2"; server_name is
# the SNI + certificate hostname, 0 = host; cfg as for h2_connect_tls,
# 0 = defaults, and its ALPN offer becomes "h2"). Calls use :scheme
# https and :authority server_name:port. 0 on failure (the reason in
# tls_last_error(cfg) when cfg != 0).
grpc_channel* grpc_channel_open_tls(char* host, int port, int timeout_ms, char* server_name, tls_config* cfg):
	h2_conn* c = h2_connect_tls(host, port, timeout_ms, server_name, cfg)
	if (c == 0):
		return 0
	if (server_name == 0):
		server_name = host
	string_builder* auth = string_new()
	string_append(auth, server_name)
	string_append(auth, c":")
	string_append_int(auth, port)
	grpc_channel* ch = grpc_channel_from_conn(c, auth.data)
	string_free(auth)
	ch.owns_conn = 1
	return ch


int grpc_channel_set_compression(grpc_channel* ch, char* encoding):
	if (codec_supported(encoding) == 0):
		return 0
	if (ch.send_encoding != 0):
		free(ch.send_encoding)
	ch.send_encoding = 0
	if (codec_is_identity(encoding) == 0):
		ch.send_encoding = strclone(encoding)
	return 1


void grpc_channel_close(grpc_channel* ch):
	if (ch == 0):
		return
	if (ch.owns_conn != 0):
		h2_close(ch.conn)
	if (ch.send_encoding != 0):
		free(ch.send_encoding)
	free(ch.authority)
	free(ch)


grpc_result* grpc_result_new(int status, char* message):
	grpc_result* r = new grpc_result()
	r.status = status
	r.message = strclone(message)
	r.response = 0
	r.response_len = 0
	r.http_status = 0
	r.headers = 0
	r.trailers = 0
	return r


void grpc_result_set(grpc_result* r, int status, char* message):
	r.status = status
	free(r.message)
	r.message = strclone(message)


char* grpc_result_header(grpc_result* r, char* name):
	return hpack_headers_get(r.headers, name)


char* grpc_result_trailer(grpc_result* r, char* name):
	return hpack_headers_get(r.trailers, name)


void grpc_result_free(grpc_result* r):
	if (r == 0):
		return
	free(r.message)
	if (r.response != 0):
		free(r.response)
	hpack_headers_free(r.headers)
	hpack_headers_free(r.trailers)
	free(r)


# One client call. status is -1 while the call is live; once it is
# decided (from the server's status, or locally: deadline, cancel,
# transport failure) it never changes.
struct grpc_client_stream:
	grpc_channel* ch
	h2_stream* s
	int deadline_ms
	int status
	char* message
	int headers_checked
	char* recv_encoding
	int send_closed


int grpc_stream_status(grpc_client_stream* cs):
	return cs.status


char* grpc_stream_header(grpc_client_stream* cs, char* name):
	if ((cs.s == 0) || (cs.s.headers_received == 0)):
		return 0
	return h2_stream_header(cs.s, name)


# Decides the call's status locally; the stream is cancelled if it is
# still open.
void grpc_cs_fail(grpc_client_stream* cs, int status, char* message):
	if (cs.status >= 0):
		return
	cs.status = status
	cs.message = strclone(message)
	if ((cs.s != 0) && (h2_stream_active(cs.s) != 0) && (cs.ch.conn.dead == 0)):
		h2_send_rst(cs.ch.conn, cs.s, h2_error_cancel())


# Validates the response headers once they are in. 0 to go on, -1 when
# they decided the call.
int grpc_cs_check_headers(grpc_client_stream* cs):
	h2_stream* s = cs.s
	if (cs.status >= 0):
		return (-1)
	if ((cs.headers_checked != 0) || (s.headers_received == 0)):
		return 0
	cs.headers_checked = 1
	if (s.status != 200):
		string_builder* m = string_new()
		string_append(m, c"HTTP status ")
		string_append_int(m, s.status)
		grpc_cs_fail(cs, grpc_status_from_http(s.status), m.data)
		string_free(m)
		return (-1)
	if (grpc_is_grpc_content_type(h2_stream_header(s, c"content-type")) == 0):
		grpc_cs_fail(cs, grpc_status_unknown(), c"response is not application/grpc")
		return (-1)
	char* enc = h2_stream_header(s, c"grpc-encoding")
	if (codec_supported(enc) == 0):
		grpc_cs_fail(cs, grpc_status_internal(), c"unsupported grpc-encoding in response")
		return (-1)
	cs.recv_encoding = enc
	return 0


# The peer ended the stream: its grpc-status decides the call.
void grpc_cs_status_from_end(grpc_client_stream* cs):
	h2_stream* s = cs.s
	if (grpc_cs_check_headers(cs) != 0):
		return
	# Trailers-only responses carry the status in the headers.
	list[hpack_header*] status_block = s.trailers
	if (status_block == 0):
		status_block = s.headers
	char* st = hpack_headers_get(status_block, c"grpc-status")
	if (st == 0):
		grpc_cs_fail(cs, grpc_status_internal(), c"missing grpc-status")
		return
	int status = grpc_parse_status(st)
	if ((status == grpc_status_ok()) && (s.body.length != 0)):
		grpc_cs_fail(cs, grpc_status_internal(), c"invalid response message")
		return
	char* raw = hpack_headers_get(status_block, c"grpc-message")
	if (raw != 0):
		char* decoded = grpc_percent_decode(raw)
		grpc_cs_fail(cs, status, decoded)
		free(decoded)
	else:
		grpc_cs_fail(cs, status, c"")


# Maps a failed h2 step (-1 reset/dead, -2 deadline) to the status.
# A stream the server already ended is left to grpc_stream_recv, which
# still delivers the buffered messages before the server's status.
void grpc_cs_io_failed(grpc_client_stream* cs, int rc):
	h2_stream* s = cs.s
	if (rc == (-2)):
		grpc_cs_fail(cs, grpc_status_deadline_exceeded(), c"deadline exceeded")
	else if (s.end_received != 0):
		return
	else if (s.refused != 0):
		grpc_cs_fail(cs, grpc_status_unavailable(), c"stream refused by server")
	else if (s.reset_code >= 0):
		grpc_cs_fail(cs, grpc_status_from_h2_error(s.reset_code), c"stream reset")
	else:
		grpc_cs_fail(cs, grpc_status_unavailable(), c"connection lost")


int grpc_cs_deadline_passed(grpc_client_stream* cs):
	return (cs.deadline_ms != 0) && (time_monotonic_ms() >= cs.deadline_ms)


# Opens a call: sends the request HEADERS (no END_STREAM). method is the
# :path ("/pkg.Service/Method"); metadata may be 0; timeout_ms <= 0
# means no deadline. Never returns 0: when no stream could be opened the
# call is already decided (UNAVAILABLE, or DEADLINE_EXCEEDED).
grpc_client_stream* grpc_stream_open(grpc_channel* ch, char* method, list[hpack_header*] metadata, int timeout_ms):
	h2_conn* c = ch.conn
	grpc_client_stream* cs = new grpc_client_stream()
	cs.ch = ch
	cs.s = 0
	cs.deadline_ms = 0
	cs.status = (-1)
	cs.message = 0
	cs.headers_checked = 0
	cs.recv_encoding = 0
	cs.send_closed = 0
	list[hpack_header*] hdrs = hpack_headers_new()
	hpack_headers_add(hdrs, c"content-type", c"application/grpc")
	hpack_headers_add(hdrs, c"te", c"trailers")
	hpack_headers_add(hdrs, c"user-agent", c"grpc-w/0.2")
	if (timeout_ms > 0):
		char* t = grpc_timeout_format(timeout_ms)
		hpack_headers_add(hdrs, c"grpc-timeout", t)
		free(t)
		cs.deadline_ms = time_monotonic_ms() + timeout_ms
		if (cs.deadline_ms == 0):
			cs.deadline_ms = 1
	if (ch.send_encoding != 0):
		hpack_headers_add(hdrs, c"grpc-encoding", ch.send_encoding)
	grpc_add_accept_encoding(hdrs, 0)
	h2_append_extra(hdrs, metadata)
	h2_set_deadline(c, cs.deadline_ms)
	cs.s = h2_request_start(c, c"POST", ch.scheme, ch.authority, method, hdrs, 0)
	h2_set_deadline(c, 0)
	hpack_headers_free(hdrs)
	if (cs.s == 0):
		if ((grpc_cs_deadline_passed(cs) != 0) && (c.dead == 0)):
			grpc_cs_fail(cs, grpc_status_deadline_exceeded(), c"deadline exceeded")
		else:
			grpc_cs_fail(cs, grpc_status_unavailable(), c"connection unavailable")
	return cs


int grpc_stream_send_ex(grpc_client_stream* cs, char* msg, int len, int end_stream):
	if ((cs.status >= 0) || (cs.send_closed != 0)):
		return (-1)
	h2_conn* c = cs.ch.conn
	h2_stream* s = cs.s
	if (grpc_cs_deadline_passed(cs) != 0):
		grpc_cs_io_failed(cs, (-2))
		return (-1)
	grpc_pump_ready(c)
	if ((s.end_received != 0) || (s.reset_code >= 0) || (s.refused != 0) || (c.dead != 0)):
		grpc_cs_io_failed(cs, (-1))
		return (-1)
	string_builder* body = string_new()
	if (grpc_encode_message(body, cs.ch.send_encoding, msg, len) != codec_ok()):
		string_free(body)
		grpc_cs_fail(cs, grpc_status_internal(), c"request compression failed")
		return (-1)
	h2_set_deadline(c, cs.deadline_ms)
	int rc = h2_send_data(c, s, body.data, body.length, end_stream)
	h2_set_deadline(c, 0)
	string_free(body)
	if (rc != 0):
		grpc_cs_io_failed(cs, rc)
		return (-1)
	if (end_stream != 0):
		cs.send_closed = 1
	return 0


int grpc_stream_send(grpc_client_stream* cs, char* msg, int len):
	return grpc_stream_send_ex(cs, msg, len, 0)


# Half-closes the request side (END_STREAM). 0 also when the server
# already ended the stream (nothing left to close).
int grpc_stream_close_send(grpc_client_stream* cs):
	if (cs.send_closed != 0):
		return 0
	if ((cs.s == 0) || (cs.status >= 0)):
		return (-1)
	h2_conn* c = cs.ch.conn
	cs.send_closed = 1
	if ((h2_stream_active(cs.s) == 0) && (cs.s.end_received != 0)):
		return 0
	h2_set_deadline(c, cs.deadline_ms)
	int rc = h2_send_data(c, cs.s, 0, 0, 1)
	h2_set_deadline(c, 0)
	if (rc != 0):
		grpc_cs_io_failed(cs, rc)
		if (cs.s.end_received != 0):
			return 0
		return (-1)
	return 0


int grpc_stream_recv(grpc_client_stream* cs, char** out, int* out_len):
	*out = 0
	*out_len = 0
	h2_conn* c = cs.ch.conn
	while (1):
		if (cs.status >= 0):
			if (cs.status == grpc_status_ok()):
				return 0
			return (-1)
		h2_stream* s = cs.s
		if (grpc_cs_check_headers(cs) != 0):
			continue
		if (cs.headers_checked != 0):
			int compressed = 0
			int status = 0
			char* why = 0
			int rc = grpc_take_message(s.body, cs.recv_encoding, cs.ch.max_message, out, out_len, &compressed, &status, &why)
			if (rc == 1):
				return 1
			if (rc < 0):
				grpc_cs_fail(cs, status, why)
				continue
		if (s.end_received != 0):
			grpc_cs_status_from_end(cs)
			continue
		if ((s.reset_code >= 0) || (s.refused != 0) || (c.dead != 0)):
			grpc_cs_io_failed(cs, (-1))
			continue
		h2_set_deadline(c, cs.deadline_ms)
		int prc = h2_pump(c)
		h2_set_deadline(c, 0)
		if (prc != 0):
			grpc_cs_io_failed(cs, prc)
	return (-1)


void grpc_stream_cancel(grpc_client_stream* cs):
	grpc_cs_fail(cs, grpc_status_cancelled(), c"cancelled by client")


grpc_result* grpc_stream_finish(grpc_client_stream* cs):
	if ((cs.status < 0) && (cs.send_closed == 0)):
		grpc_stream_close_send(cs)
	while (cs.status < 0):
		char* m = 0
		int n = 0
		if (grpc_stream_recv(cs, &m, &n) == 1):
			free(m)
	grpc_result* r = grpc_result_new(cs.status, cs.message)
	h2_stream* s = cs.s
	if (s != 0):
		r.http_status = s.status
		r.headers = s.headers
		s.headers = 0
		r.trailers = s.trailers
		s.trailers = 0
		h2_stream_free(cs.ch.conn, s)
	free(cs.message)
	free(cs)
	return r


# One unary call: a streaming call with exactly one message each way.
# method is the :path ("/pkg.Service/Method"); metadata may be 0;
# timeout_ms <= 0 means no deadline. Never returns 0.
grpc_result* grpc_unary_call(grpc_channel* ch, char* method, char* req, int req_len, list[hpack_header*] metadata, int timeout_ms):
	grpc_client_stream* cs = grpc_stream_open(ch, method, metadata, timeout_ms)
	grpc_stream_send_ex(cs, req, req_len, 1)
	char* resp = 0
	int resp_len = 0
	int count = 0
	while (1):
		char* m = 0
		int n = 0
		if (grpc_stream_recv(cs, &m, &n) != 1):
			break
		count = count + 1
		if (count == 1):
			resp = m
			resp_len = n
		else:
			free(m)
	grpc_result* r = grpc_stream_finish(cs)
	if ((r.status == grpc_status_ok()) && (count != 1)):
		grpc_result_set(r, grpc_status_internal(), c"invalid response message")
	if ((r.status == grpc_status_ok()) && (resp != 0)):
		r.response = resp
		r.response_len = resp_len
	else if (resp != 0):
		free(resp)
	return r


/* Server */

struct grpc_call:
	char* method
	char* request
	int request_len
	list[hpack_header*] metadata
	int timeout_ms
	int deadline_ms
	int status
	char* status_message
	char* response
	int response_len
	int has_response
	int headers_first
	list[hpack_header*] response_headers
	list[hpack_header*] response_trailers
	h2_conn* conn
	h2_stream* stream
	int max_message
	int streaming
	int headers_sent
	int finished
	int cancelled
	int input_done
	int input_failed
	int recv_compressed
	char* recv_encoding
	char* accept_encoding
	char* send_encoding


type grpc_unary_handler_fn = fn(grpc_call*, void*) -> void


struct grpc_method:
	char* path
	grpc_unary_handler_fn* handler
	void* user_data
	int streaming


struct grpc_server:
	list[grpc_method*] methods
	int max_message
	char* send_encoding


grpc_server* grpc_server_new():
	grpc_server* s = new grpc_server()
	s.methods = new list[grpc_method*]
	s.max_message = grpc_default_max_message()
	s.send_encoding = 0
	return s


void grpc_server_add(grpc_server* s, char* path, grpc_unary_handler_fn* handler, void* user_data, int streaming):
	grpc_method* m = new grpc_method()
	m.path = strclone(path)
	m.handler = handler
	m.user_data = user_data
	m.streaming = streaming
	s.methods.push(m)


void grpc_server_register(grpc_server* s, char* path, grpc_unary_handler_fn* handler, void* user_data):
	grpc_server_add(s, path, handler, user_data, 0)


void grpc_server_register_stream(grpc_server* s, char* path, grpc_unary_handler_fn* handler, void* user_data):
	grpc_server_add(s, path, handler, user_data, 1)


int grpc_server_set_compression(grpc_server* s, char* encoding):
	if (codec_supported(encoding) == 0):
		return 0
	if (s.send_encoding != 0):
		free(s.send_encoding)
	s.send_encoding = 0
	if (codec_is_identity(encoding) == 0):
		s.send_encoding = strclone(encoding)
	return 1


void grpc_server_free(grpc_server* s):
	int i = 0
	while (i < s.methods.length):
		grpc_method* m = s.methods[i]
		free(m.path)
		free(m)
		i = i + 1
	list_free[grpc_method*](s.methods)
	if (s.send_encoding != 0):
		free(s.send_encoding)
	free(s)


void grpc_call_reply(grpc_call* call, char* msg, int len):
	if (call.response != 0):
		free(call.response)
	call.response = mem_dup(msg, len)
	call.response_len = len
	call.has_response = 1
	call.status = grpc_status_ok()


void grpc_call_fail(grpc_call* call, int status, char* message):
	call.status = status
	if (call.status_message != 0):
		free(call.status_message)
	call.status_message = 0
	if (message != 0):
		call.status_message = strclone(message)


void grpc_call_add_header(grpc_call* call, char* name, char* value):
	hpack_headers_add(call.response_headers, name, value)


void grpc_call_add_trailer(grpc_call* call, char* name, char* value):
	hpack_headers_add(call.response_trailers, name, value)


char* grpc_call_metadata(grpc_call* call, char* name):
	return hpack_headers_get(call.metadata, name)


int grpc_call_time_left_ms(grpc_call* call):
	if (call.deadline_ms == 0):
		return (-1)
	int left = call.deadline_ms - time_monotonic_ms()
	if (left < 0):
		return 0
	return left


int grpc_call_deadline_passed(grpc_call* call):
	return (call.deadline_ms != 0) && (time_monotonic_ms() >= call.deadline_ms)


int grpc_call_set_compression(grpc_call* call, char* encoding):
	if (call.headers_sent != 0):
		return 0
	if (codec_is_identity(encoding) != 0):
		if (call.send_encoding != 0):
			free(call.send_encoding)
		call.send_encoding = 0
		return 1
	if ((codec_supported(encoding) == 0) || (codec_list_contains(call.accept_encoding, encoding) == 0)):
		return 0
	if (call.send_encoding != 0):
		free(call.send_encoding)
	call.send_encoding = strclone(encoding)
	return 1


grpc_call* grpc_call_new(grpc_server* srv, h2_conn* c, h2_stream* st):
	grpc_call* call = new grpc_call()
	call.method = h2_stream_header(st, c":path")
	call.request = 0
	call.request_len = 0
	call.metadata = st.headers
	call.timeout_ms = (-1)
	call.deadline_ms = 0
	call.status = grpc_status_unknown()
	call.status_message = 0
	call.response = 0
	call.response_len = 0
	call.has_response = 0
	call.headers_first = 0
	call.response_headers = hpack_headers_new()
	call.response_trailers = hpack_headers_new()
	call.conn = c
	call.stream = st
	call.max_message = srv.max_message
	call.streaming = 0
	call.headers_sent = 0
	call.finished = 0
	call.cancelled = 0
	call.input_done = 0
	call.input_failed = 0
	call.recv_compressed = 0
	call.recv_encoding = h2_stream_header(st, c"grpc-encoding")
	call.accept_encoding = h2_stream_header(st, c"grpc-accept-encoding")
	call.send_encoding = 0
	# Response coding: the server's preference, else the request's own,
	# either only when the client accepts it.
	if ((srv.send_encoding != 0) && (codec_list_contains(call.accept_encoding, srv.send_encoding) != 0)):
		call.send_encoding = strclone(srv.send_encoding)
	else if ((codec_is_identity(call.recv_encoding) == 0) && (codec_find(call.recv_encoding) != 0) && (codec_list_contains(call.accept_encoding, call.recv_encoding) != 0)):
		call.send_encoding = strclone(call.recv_encoding)
	return call


void grpc_call_free(grpc_call* call):
	if (call.request != 0):
		free(call.request)
	if (call.response != 0):
		free(call.response)
	if (call.status_message != 0):
		free(call.status_message)
	if (call.send_encoding != 0):
		free(call.send_encoding)
	hpack_headers_free(call.response_headers)
	hpack_headers_free(call.response_trailers)
	free(call)


int grpc_call_recv(grpc_call* call, char** out, int* out_len):
	*out = 0
	*out_len = 0
	if (call.input_done != 0):
		return 0
	if ((call.input_failed != 0) || (call.cancelled != 0) || (call.finished != 0)):
		return (-1)
	h2_conn* c = call.conn
	h2_stream* st = call.stream
	while (1):
		if ((st.reset_code >= 0) || (c.dead != 0)):
			call.cancelled = 1
			return (-1)
		int compressed = 0
		int status = 0
		char* why = 0
		int rc = grpc_take_message(st.body, call.recv_encoding, call.max_message, out, out_len, &compressed, &status, &why)
		if (rc == 1):
			if (compressed != 0):
				call.recv_compressed = call.recv_compressed + 1
			return 1
		if (rc < 0):
			call.input_failed = 1
			grpc_call_fail(call, status, why)
			return (-1)
		if (st.end_received != 0):
			if (st.body.length != 0):
				call.input_failed = 1
				grpc_call_fail(call, grpc_status_internal(), c"truncated request message")
				return (-1)
			call.input_done = 1
			return 0
		if (grpc_call_deadline_passed(call) != 0):
			call.input_failed = 1
			grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")
			return (-1)
		h2_set_deadline(c, call.deadline_ms)
		int prc = h2_pump(c)
		h2_set_deadline(c, 0)
		if (prc == (-2)):
			call.input_failed = 1
			grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")
			return (-1)
		if (prc != 0):
			call.cancelled = 1
			return (-1)
	return (-1)


int grpc_call_send_headers(grpc_call* call):
	if (call.headers_sent != 0):
		return 0
	call.headers_sent = 1
	list[hpack_header*] head = hpack_headers_new()
	hpack_headers_add(head, c"content-type", c"application/grpc")
	if (call.send_encoding != 0):
		hpack_headers_add(head, c"grpc-encoding", call.send_encoding)
	grpc_add_accept_encoding(head, 0)
	h2_append_extra(head, call.response_headers)
	int rc = h2_respond_headers(call.conn, call.stream, 200, head, 0)
	hpack_headers_free(head)
	return rc


int grpc_call_send(grpc_call* call, char* msg, int len):
	if ((call.finished != 0) || (call.cancelled != 0)):
		return (-1)
	h2_conn* c = call.conn
	h2_stream* st = call.stream
	if (grpc_call_deadline_passed(call) != 0):
		grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")
		return (-1)
	grpc_pump_ready(c)
	if ((st.reset_code >= 0) || (c.dead != 0)):
		call.cancelled = 1
		return (-1)
	if (grpc_call_send_headers(call) != 0):
		call.cancelled = 1
		return (-1)
	string_builder* body = string_new()
	if (grpc_encode_message(body, call.send_encoding, msg, len) != codec_ok()):
		string_free(body)
		grpc_call_fail(call, grpc_status_internal(), c"response compression failed")
		return (-1)
	h2_set_deadline(c, call.deadline_ms)
	int rc = h2_send_data(c, st, body.data, body.length, 0)
	h2_set_deadline(c, 0)
	string_free(body)
	if (rc == (-2)):
		grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")
		return (-1)
	if (rc != 0):
		call.cancelled = 1
		return (-1)
	return 0


# Appends grpc-status / grpc-message (percent-encoded) and the call's
# custom trailers to l.
void grpc_append_status(list[hpack_header*] l, grpc_call* call):
	char* st = itoa(call.status)
	hpack_headers_add(l, c"grpc-status", st)
	free(st)
	if ((call.status_message != 0) && (call.status_message[0] != 0)):
		char* enc = grpc_percent_encode(call.status_message)
		hpack_headers_add(l, c"grpc-message", enc)
		free(enc)
	h2_append_extra(l, call.response_trailers)


# Ends the response with the call's status: trailers after headers that
# went out (or are forced by headers_first), else trailers-only.
int grpc_call_finish(grpc_call* call):
	if (call.finished != 0):
		return 0
	call.finished = 1
	if (call.cancelled != 0):
		return (-1)
	h2_conn* c = call.conn
	h2_stream* st = call.stream
	if ((call.headers_sent == 0) && (call.headers_first != 0)):
		if (grpc_call_send_headers(call) != 0):
			return (-1)
	int rc = 0
	if (call.headers_sent != 0):
		list[hpack_header*] trailers = hpack_headers_new()
		grpc_append_status(trailers, call)
		rc = h2_send_trailers(c, st, trailers)
		hpack_headers_free(trailers)
	else:
		# Trailers-only: one HEADERS frame with END_STREAM.
		list[hpack_header*] head = hpack_headers_new()
		hpack_headers_add(head, c"content-type", c"application/grpc")
		grpc_add_accept_encoding(head, call.status == grpc_status_unimplemented())
		h2_append_extra(head, call.response_headers)
		grpc_append_status(head, call)
		rc = h2_respond_headers(c, st, 200, head, 1)
		hpack_headers_free(head)
	return rc


grpc_method* grpc_find_method(grpc_server* srv, char* path):
	int i = 0
	while (i < srv.methods.length):
		grpc_method* m = srv.methods[i]
		if (strcmp(m.path, path) == 0):
			return m
		i = i + 1
	return 0


# Pumps until the request stream is complete (or reset / the connection
# ends). Used before answering plain-HTTP errors, whose clients expect
# a normal end of stream rather than a reset.
void grpc_drain_request(h2_conn* c, h2_stream* st):
	while ((st.end_received == 0) && (st.reset_code < 0) && (c.dead == 0)):
		if (h2_pump(c) != 0):
			return


# Unary: exactly one request message, then the client's END_STREAM.
void grpc_server_run_unary(grpc_call* call, grpc_method* m):
	int rc = grpc_call_recv(call, &call.request, &call.request_len)
	if (rc == 0):
		grpc_call_fail(call, grpc_status_internal(), c"missing request message")
	if (rc != 1):
		return
	char* extra = 0
	int extra_len = 0
	rc = grpc_call_recv(call, &extra, &extra_len)
	if (rc == 1):
		free(extra)
		grpc_call_fail(call, grpc_status_internal(), c"more than one request message")
		return
	if (rc != 0):
		return
	m.handler(call, m.user_data)
	if (grpc_call_deadline_passed(call) != 0):
		grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")
		call.headers_first = 0
	else if ((call.status == grpc_status_ok()) && (call.has_response == 0)):
		grpc_call_fail(call, grpc_status_unknown(), c"handler produced no response")
	if (call.status == grpc_status_ok()):
		if (grpc_call_send(call, call.response, call.response_len) != 0):
			if (call.status == grpc_status_ok()):
				grpc_call_fail(call, grpc_status_internal(), c"sending the response failed")


void grpc_server_run_stream(grpc_call* call, grpc_method* m):
	call.streaming = 1
	call.status = grpc_status_ok()
	m.handler(call, m.user_data)
	if ((call.cancelled == 0) && (call.status == grpc_status_ok()) && (grpc_call_deadline_passed(call) != 0)):
		grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")


# Runs one request stream to completion.
void grpc_server_handle(grpc_server* srv, h2_conn* c, h2_stream* st):
	char* method = h2_stream_header(st, c":method")
	if (strcmp(method, c"POST") != 0):
		grpc_drain_request(c, st)
		h2_respond(c, st, 405, 0, 0, 0)
		return
	if (grpc_is_grpc_content_type(h2_stream_header(st, c"content-type")) == 0):
		grpc_drain_request(c, st)
		h2_respond(c, st, 415, 0, 0, 0)
		return
	grpc_call* call = grpc_call_new(srv, c, st)
	char* timeout = h2_stream_header(st, c"grpc-timeout")
	if (timeout != 0):
		int ms = 0
		if (grpc_timeout_parse(timeout, &ms) != 0):
			call.timeout_ms = ms
			call.deadline_ms = time_monotonic_ms() + ms
			if (call.deadline_ms == 0):
				call.deadline_ms = 1
	grpc_method* m = grpc_find_method(srv, call.method)
	if (m == 0):
		string_builder* msg = string_new()
		string_append(msg, c"unknown method ")
		string_append(msg, call.method)
		grpc_call_fail(call, grpc_status_unimplemented(), msg.data)
		string_free(msg)
	else if (codec_supported(call.recv_encoding) == 0):
		string_builder* msg = string_new()
		string_append(msg, c"grpc-encoding ")
		string_append(msg, call.recv_encoding)
		string_append(msg, c" is not supported")
		grpc_call_fail(call, grpc_status_unimplemented(), msg.data)
		string_free(msg)
	else if (m.streaming != 0):
		grpc_server_run_stream(call, m)
	else:
		grpc_server_run_unary(call, m)
	grpc_call_finish(call)
	grpc_call_free(call)


# Pumps until some stream has its request headers and was not handed
# out yet; streams that died before that are released. 0 when the
# connection ends.
h2_stream* grpc_server_next_stream(h2_conn* c):
	while (1):
		int i = 0
		while (i < c.streams.length):
			h2_stream* s = c.streams[i]
			if (s.delivered == 0):
				if ((s.reset_code >= 0) || (s.refused != 0)):
					h2_stream_free(c, s)
					continue
				if (s.headers_received != 0):
					s.delivered = 1
					return s
			i = i + 1
		if (h2_pump(c) != 0):
			return 0
	return 0


# Serves every call on an established server connection, then closes
# it. 0 on a clean end, else the h2 error.
int grpc_server_serve_h2(grpc_server* srv, h2_conn* c):
	while (1):
		h2_stream* st = grpc_server_next_stream(c)
		if (st == 0):
			break
		grpc_server_handle(srv, c, st)
		# The response is complete; a client still sending is told to
		# stop with RST_STREAM(NO_ERROR) (RFC 9113 section 8.1).
		if ((h2_stream_active(st) != 0) && (st.end_sent != 0) && (c.dead == 0)):
			h2_send_rst(c, st, h2_error_no_error())
		h2_stream_free(c, st)
	int err = c.error
	h2_close(c)
	return err


int grpc_server_serve_conn(grpc_server* srv, int fd):
	h2_conn* c = h2_server_new(fd)
	if (c == 0):
		return h2_error_protocol()
	return grpc_server_serve_h2(srv, c)


# gRPC over TLS on one accepted TCP connection: h2_accept_tls (TLS 1.3
# handshake requiring ALPN "h2"; scfg is modified to require it), then
# grpc_server_serve_h2. A failed handshake closes fd and returns
# PROTOCOL_ERROR (tls_server_last_error(scfg) explains a TLS failure).
int grpc_server_serve_conn_tls(grpc_server* srv, int fd, tls_server_config* scfg):
	h2_conn* c = h2_accept_tls(fd, scfg)
	if (c == 0):
		return h2_error_protocol()
	return grpc_server_serve_h2(srv, c)
