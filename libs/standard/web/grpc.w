# gRPC unary calls over HTTP/2 (libs/standard/web/http2.w), part of
# issue #436 ("Protocols"). Implements the gRPC-over-HTTP/2 wire
# protocol (PROTOCOL-HTTP2.md in the grpc repository) for unary RPCs:
#   request:  HEADERS  :method POST, :scheme, :path /pkg.Service/Method,
#                      :authority, content-type application/grpc,
#                      te trailers, grpc-timeout (optional), metadata
#             DATA     one length-prefixed message, END_STREAM
#   response: HEADERS  :status 200, content-type application/grpc
#             DATA     one length-prefixed message
#             HEADERS  grpc-status, grpc-message (trailers, END_STREAM)
#   or a "trailers-only" response: a single HEADERS frame carrying
#   :status, content-type, grpc-status and grpc-message with END_STREAM.
#
# Messages are opaque bytes here: this file does not depend on a
# serializer, so it stays inside libs/standard. Pair it with
# libs/extras/protobuf/message.w (pb_encode / pb_decode_into) as
# libs/standard/web/grpc_test.w does. Length-prefixed messages must have
# the compressed flag 0: compression (grpc-encoding) is not negotiated,
# and a compressed message is answered with UNIMPLEMENTED.
#
# Public API (common):
#   int  grpc_status_ok() ... grpc_status_unauthenticated()   codes 0..16
#   char* grpc_status_name(int code)
#   void grpc_frame_message(string_builder* out, char* msg, int len)
#   int  grpc_unframe_message(char* body, int len, int max, char** out, int* out_len)
#                                             a status code; *out is malloc'd
#   char* grpc_percent_encode(char* s) / char* grpc_percent_decode(char* s)
#   char* grpc_timeout_format(int ms) / int grpc_timeout_parse(char* v, int* out_ms)
#   int  grpc_status_from_http(int http_status)
#   int  grpc_status_from_h2_error(int h2_code)
#
# Public API (client):
#   grpc_channel* grpc_channel_open(char* host, int port, int timeout_ms)   0 on failure
#   grpc_channel* grpc_channel_from_conn(h2_conn* c, char* authority)       borrows c
#   grpc_result*  grpc_unary_call(grpc_channel* ch, char* method, char* req, int req_len,
#                                 list[hpack_header*] metadata, int timeout_ms)
#   char* grpc_result_header(grpc_result* r, char* name)
#   char* grpc_result_trailer(grpc_result* r, char* name)
#   void grpc_result_free(grpc_result* r)
#   void grpc_channel_close(grpc_channel* ch)
#
# Public API (server):
#   type grpc_unary_handler_fn = fn(grpc_call*, void*) -> void
#   grpc_server* grpc_server_new()
#   void grpc_server_register(grpc_server* s, char* path, grpc_unary_handler_fn* h, void* user_data)
#   int  grpc_server_serve_conn(grpc_server* s, int fd)   serves one accepted connection;
#                                                         0 on a clean end, else the h2 error
#   void grpc_call_reply(grpc_call* call, char* msg, int len)     copies msg
#   void grpc_call_fail(grpc_call* call, int status, char* message)
#   void grpc_call_add_header(grpc_call* call, char* name, char* value)
#   void grpc_call_add_trailer(grpc_call* call, char* name, char* value)
#   char* grpc_call_metadata(grpc_call* call, char* name)
#   int  grpc_call_time_left_ms(grpc_call* call)    -1 when no deadline
#   void grpc_server_free(grpc_server* s)
#
# Deadlines: the client sends grpc-timeout (milliseconds) and bounds its
# own wait with h2_set_deadline; on expiry the stream is cancelled with
# RST_STREAM(CANCEL), the call returns DEADLINE_EXCEEDED, and the
# connection stays usable. The server parses grpc-timeout into
# grpc_call.deadline_ms (any unit, H/M/S/m/u/n) and answers
# DEADLINE_EXCEEDED instead of the handler's reply once it has passed.
#
# Status mapping on the client: grpc-status from the trailers (or from
# the headers of a trailers-only response) wins; a non-200 HTTP status
# maps per the gRPC HTTP-to-status table; a missing grpc-status,
# non-gRPC content-type, or a message count other than one on success
# is INTERNAL/UNKNOWN; RST_STREAM codes map per the spec (REFUSED_STREAM
# and GOAWAY-refused streams -> UNAVAILABLE, CANCEL -> CANCELLED,
# ENHANCE_YOUR_CALM -> RESOURCE_EXHAUSTED); a dead connection is
# UNAVAILABLE. grpc-message is percent-encoded on the wire and decoded
# into grpc_result.message.
import lib.lib
import lib.time
import lib.container
import structures.string
import libs.standard.web.hpack
import libs.standard.web.http2


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

void grpc_frame_message(string_builder* out, char* msg, int len):
	string_append_char(out, 0)
	string_append_char(out, (len >> 24) & 255)
	string_append_char(out, (len >> 16) & 255)
	string_append_char(out, (len >> 8) & 255)
	string_append_char(out, len & 255)
	string_append_bytes(out, msg, len)


# Parses a unary body: exactly one length-prefixed message. Returns
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
	*out = hpack_copy_bytes(body + 5, n)
	*out_len = n
	return grpc_status_ok()


/* grpc-message percent-encoding */

int grpc_hex_digit(int v):
	if (v < 10):
		return '0' + v
	return 'A' + v - 10


int grpc_hex_value(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	return (-1)


# Bytes outside printable ASCII (0x20-0x7E), and '%' itself, become %XX.
char* grpc_percent_encode(char* s):
	string_builder* out = string_new()
	int i = 0
	while (s[i] != 0):
		int c = s[i] & 255
		if ((c < 32) || (c > 126) || (c == '%')):
			string_append_char(out, '%')
			string_append_char(out, grpc_hex_digit(c >> 4))
			string_append_char(out, grpc_hex_digit(c & 15))
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
				int hi = grpc_hex_value(s[i + 1] & 255)
				int lo = grpc_hex_value(s[i + 2] & 255)
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


/* Client */

struct grpc_channel:
	h2_conn* conn
	char* authority
	char* scheme
	int owns_conn
	int max_message


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
	ch.owns_conn = 0
	ch.max_message = grpc_default_max_message()
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


void grpc_channel_close(grpc_channel* ch):
	if (ch == 0):
		return
	if (ch.owns_conn != 0):
		h2_close(ch.conn)
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


# Turns a finished (END_STREAM received) response stream into r.
void grpc_client_finish(grpc_channel* ch, h2_stream* s, grpc_result* r):
	r.http_status = s.status
	r.headers = s.headers
	s.headers = 0
	r.trailers = s.trailers
	s.trailers = 0
	if (r.http_status != 200):
		string_builder* m = string_new()
		string_append(m, c"HTTP status ")
		string_append_int(m, r.http_status)
		grpc_result_set(r, grpc_status_from_http(r.http_status), m.data)
		string_free(m)
		return
	if (grpc_is_grpc_content_type(hpack_headers_get(r.headers, c"content-type")) == 0):
		grpc_result_set(r, grpc_status_unknown(), c"response is not application/grpc")
		return
	# Trailers-only responses carry the status in the headers.
	list[hpack_header*] status_block = r.trailers
	if (status_block == 0):
		status_block = r.headers
	char* st = hpack_headers_get(status_block, c"grpc-status")
	if (st == 0):
		grpc_result_set(r, grpc_status_internal(), c"missing grpc-status")
		return
	int status = grpc_parse_status(st)
	char* raw = hpack_headers_get(status_block, c"grpc-message")
	if (raw != 0):
		char* decoded = grpc_percent_decode(raw)
		grpc_result_set(r, status, decoded)
		free(decoded)
	else:
		grpc_result_set(r, status, c"")
	if (status != grpc_status_ok()):
		return
	char* msg = 0
	int msg_len = 0
	int rc = grpc_unframe_message(h2_stream_body(s), h2_stream_body_len(s), ch.max_message, &msg, &msg_len)
	if (rc != grpc_status_ok()):
		grpc_result_set(r, rc, c"invalid response message")
		return
	r.response = msg
	r.response_len = msg_len


# One unary call. method is the :path ("/pkg.Service/Method"); metadata
# may be 0; timeout_ms <= 0 means no deadline. Never returns 0.
grpc_result* grpc_unary_call(grpc_channel* ch, char* method, char* req, int req_len, list[hpack_header*] metadata, int timeout_ms):
	h2_conn* c = ch.conn
	list[hpack_header*] hdrs = hpack_headers_new()
	hpack_headers_add(hdrs, c"content-type", c"application/grpc")
	hpack_headers_add(hdrs, c"te", c"trailers")
	hpack_headers_add(hdrs, c"user-agent", c"grpc-w/0.1")
	if (timeout_ms > 0):
		char* t = grpc_timeout_format(timeout_ms)
		hpack_headers_add(hdrs, c"grpc-timeout", t)
		free(t)
		h2_set_deadline(c, time_monotonic_ms() + timeout_ms)
	h2_append_extra(hdrs, metadata)
	h2_stream* s = h2_request_start(c, c"POST", ch.scheme, ch.authority, method, hdrs, 0)
	hpack_headers_free(hdrs)
	if (s == 0):
		h2_set_deadline(c, 0)
		return grpc_result_new(grpc_status_unavailable(), c"connection unavailable")
	string_builder* body = string_new()
	grpc_frame_message(body, req, req_len)
	int rc = h2_send_data(c, s, body.data, body.length, 1)
	string_free(body)
	if (rc == 0):
		rc = h2_await_end(c, s)
	h2_set_deadline(c, 0)
	grpc_result* r = grpc_result_new(grpc_status_ok(), c"")
	if (rc == (-2)):
		h2_send_rst(c, s, h2_error_cancel())
		grpc_result_set(r, grpc_status_deadline_exceeded(), c"deadline exceeded")
	else if (rc != 0):
		if (s.refused != 0):
			grpc_result_set(r, grpc_status_unavailable(), c"stream refused by server")
		else if (s.reset_code >= 0):
			grpc_result_set(r, grpc_status_from_h2_error(s.reset_code), c"stream reset")
		else:
			grpc_result_set(r, grpc_status_unavailable(), c"connection lost")
	else:
		grpc_client_finish(ch, s, r)
	h2_stream_free(c, s)
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


type grpc_unary_handler_fn = fn(grpc_call*, void*) -> void


struct grpc_method:
	char* path
	grpc_unary_handler_fn* handler
	void* user_data


struct grpc_server:
	list[grpc_method*] methods
	int max_message


grpc_server* grpc_server_new():
	grpc_server* s = new grpc_server()
	s.methods = new list[grpc_method*]
	s.max_message = grpc_default_max_message()
	return s


void grpc_server_register(grpc_server* s, char* path, grpc_unary_handler_fn* handler, void* user_data):
	grpc_method* m = new grpc_method()
	m.path = strclone(path)
	m.handler = handler
	m.user_data = user_data
	s.methods.push(m)


void grpc_server_free(grpc_server* s):
	int i = 0
	while (i < s.methods.length):
		grpc_method* m = s.methods[i]
		free(m.path)
		free(m)
		i = i + 1
	list_free[grpc_method*](s.methods)
	free(s)


void grpc_call_reply(grpc_call* call, char* msg, int len):
	if (call.response != 0):
		free(call.response)
	call.response = hpack_copy_bytes(msg, len)
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


grpc_call* grpc_call_new(h2_stream* st):
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
	return call


void grpc_call_free(grpc_call* call):
	if (call.request != 0):
		free(call.request)
	if (call.response != 0):
		free(call.response)
	if (call.status_message != 0):
		free(call.status_message)
	hpack_headers_free(call.response_headers)
	hpack_headers_free(call.response_trailers)
	free(call)


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


int grpc_send_response(h2_conn* c, h2_stream* st, grpc_call* call):
	list[hpack_header*] head = hpack_headers_new()
	hpack_headers_add(head, c"content-type", c"application/grpc")
	h2_append_extra(head, call.response_headers)
	int rc = 0
	if ((call.status == grpc_status_ok()) || (call.headers_first != 0)):
		rc = h2_respond_headers(c, st, 200, head, 0)
		if ((rc == 0) && (call.status == grpc_status_ok())):
			string_builder* body = string_new()
			grpc_frame_message(body, call.response, call.response_len)
			rc = h2_send_data(c, st, body.data, body.length, 0)
			string_free(body)
		if (rc == 0):
			list[hpack_header*] trailers = hpack_headers_new()
			grpc_append_status(trailers, call)
			rc = h2_send_trailers(c, st, trailers)
			hpack_headers_free(trailers)
	else:
		# Trailers-only: one HEADERS frame with END_STREAM.
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


# Runs one request stream to completion.
void grpc_server_handle(grpc_server* srv, h2_conn* c, h2_stream* st):
	char* method = h2_stream_header(st, c":method")
	if (strcmp(method, c"POST") != 0):
		h2_respond(c, st, 405, 0, 0, 0)
		return
	if (grpc_is_grpc_content_type(h2_stream_header(st, c"content-type")) == 0):
		h2_respond(c, st, 415, 0, 0, 0)
		return
	grpc_call* call = grpc_call_new(st)
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
	else:
		int rc = grpc_unframe_message(h2_stream_body(st), h2_stream_body_len(st), srv.max_message, &call.request, &call.request_len)
		if (rc != grpc_status_ok()):
			grpc_call_fail(call, rc, c"invalid request message")
		else:
			m.handler(call, m.user_data)
			if ((call.deadline_ms != 0) && (time_monotonic_ms() >= call.deadline_ms)):
				grpc_call_fail(call, grpc_status_deadline_exceeded(), c"deadline exceeded")
				call.headers_first = 0
			else if ((call.status == grpc_status_ok()) && (call.has_response == 0)):
				grpc_call_fail(call, grpc_status_unknown(), c"handler produced no response")
	grpc_send_response(c, st, call)
	grpc_call_free(call)


int grpc_server_serve_conn(grpc_server* srv, int fd):
	h2_conn* c = h2_server_new(fd)
	if (c == 0):
		return h2_error_protocol()
	while (1):
		h2_stream* st = h2_server_next_request(c)
		if (st == 0):
			break
		grpc_server_handle(srv, c, st)
		h2_stream_free(c, st)
	int err = c.error
	h2_close(c)
	return err
