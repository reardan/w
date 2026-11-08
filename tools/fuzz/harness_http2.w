# wbuild: target=wfuzz_http2_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/http2/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_http2.w -o bin/wfuzz_http2_harness"
# wbuild: step="rm -rf bin/wfuzz_http2_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_http2_harness --bytes --ext .h2 --corpus tools/fuzz/seeds/http2 --out bin/wfuzz_http2_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_http2 tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_http2.w -o bin/wfuzz_http2_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_http2_harness --bytes --ext .h2 --corpus tools/fuzz/seeds/http2 --out bin/wfuzz_http2" timeout=3600000
# Fuzz harness for HTTP/2 frame decoding (issue #909): the input is the
# byte stream a peer sends, written into one end of a socketpair whose
# write side is then shut down, and libs/standard/web/http2.w reads it
# through h2_pump exactly as on a real connection:
#   - an input starting with the client connection preface is a client
#     talking to h2_server_new: each complete request
#     h2_server_next_request hands out is answered with a short body
#     (HEADERS + DATA through the send-side flow control) and released;
#   - anything else is a server answering a client that sent its
#     preface, SETTINGS and one GET on stream 1 (h2_request_start), with
#     frames pumped until the connection ends.
# The library's replies go to the harness's end of the socketpair,
# which is never read; responses are kept small so they fit the socket
# buffer. Seeds are hand-built frame sequences mirroring
# libs/standard/web/http2_test.w's cases (SETTINGS, PING, padded and
# CONTINUATION header blocks, DATA with flow control, trailers, RST,
# GOAWAY, WINDOW_UPDATE).
#
# Invariants checked after every frame: the read buffer cursors stay in
# bounds; the connection receive window stays in [0, 2^31-1] and the
# connection send window at most 2^31-1; every stream's receive window
# is in [0, 2^31-1], its send window at most 2^31-1, and its buffered
# body within max_body; the pending CONTINUATION block within
# max_block; the stream count within max_streams. A request the server
# delivers has valid pseudo-headers (h2_valid_request) and, when it
# carries content-length, a matching body.
import tools.fuzz.harness
import lib.net
import libs.standard.web.http2


const int fh_h2_max_requests = 32


int fh_h2_socket(char* data, int length):
	int[2] fds
	if (socket_pair(&fds[0]) < 0):
		println2(c"harness: socketpair failed")
		exit(2)
	int sent = 0
	while (sent < length):
		int n = write(fds[1], data + sent, length - sent)
		if (n <= 0):
			println2(c"harness: socket write failed")
			exit(2)
		sent = sent + n
	# Shut down only our write side: the library's replies still land in
	# the socket buffer instead of failing with EPIPE.
	io_result r
	socket_shutdown_checked(fds[1], 1, &r)
	return fds[0]


void fh_h2_check(h2_conn* c):
	fh_check((c.rstart >= 0) && (c.rstart <= c.rend) && (c.rend <= c.rcap), c"read buffer cursors out of bounds")
	fh_check((c.conn_recv_window >= 0) && (c.conn_recv_window <= h2_max_window), c"connection receive window out of range")
	fh_check(c.conn_send_window <= h2_max_window, c"connection send window above 2^31-1")
	fh_check(c.cont_block.length <= c.max_block, c"pending header block above max_block")
	fh_check(c.streams.length <= c.max_streams, c"more streams than max_streams")
	for i in range(c.streams.length):
		h2_stream* s = c.streams[i]
		fh_check((s.recv_window >= 0) && (s.recv_window <= h2_max_window), c"stream receive window out of range")
		fh_check(s.send_window <= h2_max_window, c"stream send window above 2^31-1")
		fh_check(s.body.length <= c.max_body, c"stream body above max_body")


void fh_h2_check_request(h2_stream* s):
	fh_check(s.headers_received != 0, c"request delivered without headers")
	fh_check(h2_valid_request(s.headers) != 0, c"request delivered with invalid pseudo-headers")
	char* cl = hpack_headers_get(s.headers, c"content-length")
	if (cl != 0): fh_check(atoi(cl) == s.body.length, c"request body does not match content-length")


int fh_h2_server(int fd):
	h2_conn* c = h2_server_new(fd)
	if (c == 0): return 1
	int served = 0
	int done = 0
	while ((done == 0) && (served < fh_h2_max_requests)):
		h2_stream* s = h2_server_next_request(c)
		fh_h2_check(c)
		if (s == 0): done = 1
		else:
			fh_h2_check_request(s)
			h2_respond(c, s, 200, 0, c"fuzz harness response body", 26)
			fh_h2_check(c)
			h2_stream_free(c, s)
			served = served + 1
	h2_close(c)
	if (served > 0): return 0
	return 1


int fh_h2_client(int fd):
	h2_conn* c = h2_conn_new(fd, 0)
	h2_client_start(c)
	h2_stream* s = h2_request_start(c, c"GET", c"http", c"example.com", c"/", 0, 1)
	int frames = 0
	if (s != 0):
		while (h2_pump(c) == 0):
			fh_h2_check(c)
			frames = frames + 1
		fh_h2_check(c)
		if (s.headers_received != 0): fh_check(s.status >= 200, c"final response status below 200")
	int ok = (s != 0) && (h2_stream_ok(s) != 0)
	h2_close(c)
	if (ok): return 0
	return 1


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	int fd = fh_h2_socket(data, length)
	if ((length >= h2_preface_len) && fh_bytes_equal(data, h2_preface(), h2_preface_len)): return fh_h2_server(fd)
	return fh_h2_client(fd)
