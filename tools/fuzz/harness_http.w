# wbuild: target=wfuzz_http_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/http/ data=tools/fuzz/dicts/http.dict
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_http.w -o bin/wfuzz_http_harness"
# wbuild: step="rm -rf bin/wfuzz_http_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_http_harness --ext .http --dict tools/fuzz/dicts/http.dict --corpus tools/fuzz/seeds/http --out bin/wfuzz_http_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_http tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_http.w -o bin/wfuzz_http_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_http_harness --ext .http --dict tools/fuzz/dicts/http.dict --corpus tools/fuzz/seeds/http --out bin/wfuzz_http" timeout=3600000
# Fuzz harness for HTTP/1.1 message parsing (issue #842). The input is
# written into one end of a socketpair and read back through
# libs/standard/web/connection.w's ConnectionContext, exactly as the
# server and client read a peer:
#   - an input starting "HTTP/" is a response: http_client.w's head
#     parser, body framing (Content-Length, chunked, close-delimited)
#     and Content-Encoding decoding (gzip/deflate through
#     libs/extras/compress);
#   - anything else is a stream of pipelined requests for
#     http_server.w's server_read_request, with each target run through
#     urlparse.w (url_parse, url_unquote, url_query_param,
#     url_remove_dot_segments).
import tools.fuzz.harness
import lib.net
import libs.standard.web.connection
import libs.standard.web.http_client
import libs.standard.web.http_server
import libs.standard.web.urlparse
import libs.standard.web.content_decode
import libs.extras.compress.codecs


# A connected socket whose peer has sent data and closed.
int fh_http_socket(char* data, int length):
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
	close(fds[1])
	return fds[0]


void fh_http_target(ServerRequest* req):
	if (req.target[0] != '/'):
		URL* u = url_parse(req.target)
		if (u != 0):
			char* back = url_unparse(u)
			free(back)
			url_free(u)
	char* path = url_unquote(req.path)
	if (path != 0):
		char* clean = url_remove_dot_segments(path)
		if (clean != 0): free(clean)
		free(path)
	char* value = url_query_param(req.query, c"a")
	if (value != 0): free(value)


int fh_http_requests(int fd):
	ConnectionContext* c = connection_context_new(fd, 2000, 0)
	int parsed = 0
	int rounds = 0
	while (rounds < 64):
		ServerRequest* req = server_read_request(c)
		if (req == 0): rounds = 64
		else:
			if (req.error == 0):
				parsed = parsed + 1
				fh_http_target(req)
			else: rounds = 64
			server_request_free(req)
		rounds = rounds + 1
	connection_context_destroy(c)
	if (parsed > 0): return 0
	return 1


int fh_http_response(int fd):
	compress_codecs_register()
	http_stream* s = http_stream_new()
	s.conn = connection_context_client(fd, 2000, http_error_recv, http_error_send, http_error_timeout)
	int minor = 1
	if (http_read_head(s.conn, s.resp, &minor) != 1):
		http_stream_close(s)
		return 1
	http_response_keep_alive(s.resp, minor)
	if (http_stream_set_framing(s, c"GET") == 0):
		http_stream_close(s)
		return 1
	content_decoder* d = http_content_collect(s, 1 << 20, 1 << 22)
	int ok = d.status == content_decode_done
	content_decoder_free(d)
	http_stream_close(s)
	if (ok): return 0
	return 1


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	int fd = fh_http_socket(data, length)
	if ((length >= 5) && fh_bytes_equal(data, c"HTTP/", 5)): return fh_http_response(fd)
	return fh_http_requests(fd)
