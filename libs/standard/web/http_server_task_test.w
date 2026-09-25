# wbuild: x64
# Concurrency tests for libs/standard/web/http_server.w's task-based
# server (server_context_serve_tasks / server_accept_task,
# docs/projects/async.md). Each forked test stalls one connection
# mid-request (or mid-handshake) and proves another connection is
# served meanwhile -- the sequential accept loop would wedge on the
# stalled peer until its timeout. The last test runs the server and
# its clients as tasks in one process and cancels the server at the
# end.
import lib.testing
import lib.net
import lib.task
import lib.task_io
import structures.string
import libs.standard.web.connection
import libs.standard.web.http_server
import libs.standard.web.http_client
import libs.standard.net.tls


int htt_contains(char* hay, char* needle):
	int i = 0
	while (hay[i] != 0):
		int j = 0
		while ((needle[j] != 0) && (hay[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		i = i + 1
	return 0


char* htt_url(char* scheme, int port, char* path):
	string_builder* out = string_new()
	string_append(out, scheme)
	string_append(out, c"://127.0.0.1:")
	string_append_int(out, port)
	string_append(out, path)
	char* text = out.data
	free(out)
	return text


ServerResponse* htt_handler_path(ServerRequest* req, void* context):
	ServerResponse* resp = server_response_new(200)
	server_response_set_text(resp, req.path)
	return resp


# Wedge guard only (see http_server_test.w's hst_new_server note).
ServerContext* htt_new_server():
	ServerContext* s = server_context_new(c"127.0.0.1", 0, htt_handler_path, 0)
	s.timeout_ms = 60000
	return s


void htt_finish(int pid):
	http_client_close_idle()
	int status = 0
	wait4(pid, &status, 0, 0)
	asserts(c"server child exited cleanly", status == 0)


int htt_connect(int port):
	int fd = socket_tcp_ipv4()
	asserts(c"raw socket", fd >= 0)
	asserts(c"raw connect", socket_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port) == 0)
	socket_set_recv_timeout(fd, 60000)
	socket_set_send_timeout(fd, 60000)
	return fd


# Reads until EOF into a malloc'd NUL-terminated string.
char* htt_read_all(int fd):
	string_builder* out = string_new()
	char* buf = malloc(4096)
	while (1):
		int n = socket_recv(fd, buf, 4096, 0)
		if (n <= 0):
			break
		string_append_bytes(out, buf, n)
	free(buf)
	char* text = out.data
	free(out)
	return text


char* htt_get(char* url):
	http_req* req = http_req_new(c"GET", url)
	http_req_add_header(req, c"Connection", c"close")
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 60000
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	string_builder* copy = string_new()
	string_append(copy, resp.body)
	char* body = copy.data
	free(copy)
	http_response_free(resp)
	http_req_free(req)
	return body


# A peer stalled halfway through its request line does not hold up a
# second connection.
void test_stalled_request_does_not_block_others():
	ServerContext* s = htt_new_server()
	asserts(c"server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		assert_equal(3, server_context_serve_tasks(s, 3))
		exit(0)
	server_context_close(s)
	server_context_free(s)

	int stalled = htt_connect(port)
	char* partial = c"GET /slow HTTP/1.1\x0d\x0aHost: 127.0.0.1\x0d\x0a"
	socket_send(stalled, partial, strlen(partial), msg_nosignal())

	char* url = htt_url(c"http", port, c"/fast")
	char* body = htt_get(url)
	assert_strings_equal(c"/fast", body)
	free(body)
	free(url)

	char* rest = c"Connection: close\x0d\x0a\x0d\x0a"
	socket_send(stalled, rest, strlen(rest), msg_nosignal())
	char* text = htt_read_all(stalled)
	asserts(c"stalled request answered", htt_contains(text, c"200"))
	asserts(c"stalled request body", htt_contains(text, c"/slow"))
	free(text)
	close(stalled)

	url = htt_url(c"http", port, c"/third")
	body = htt_get(url)
	assert_strings_equal(c"/third", body)
	free(body)
	free(url)
	htt_finish(pid)


# HTTPS: a peer that connects and never starts its handshake does not
# hold up a full TLS request on another connection.
void test_stalled_handshake_does_not_block_https():
	ServerContext* s = htt_new_server()
	server_context_set_tls(s, c"libs/standard/net/tls_fixtures/server_p256_cert.pem", c"libs/standard/net/tls_fixtures/server_p256_key.pem")
	asserts(c"server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		assert_equal(2, server_context_serve_tasks(s, 2))
		exit(0)
	server_context_close(s)
	server_context_free(s)

	int stalled = htt_connect(port)
	char* url = htt_url(c"https", port, c"/secure")
	char* body = htt_get(url)
	assert_strings_equal(c"/secure", body)
	free(body)
	free(url)
	# Hanging up mid-handshake ends that connection's task.
	close(stalled)
	htt_finish(pid)


/* In-process: the server and its clients are tasks on one scheduler. */

generator int htt_client(int port, char* path, list[int] ok):
	int fd = socket_tcp_ipv4()
	assert_equal(0, task_connect_ipv4(fd, ip4_from_string(c"127.0.0.1"), port))
	string_builder* req = string_new()
	string_append(req, c"GET ")
	string_append(req, path)
	string_append(req, c" HTTP/1.1\x0d\x0aHost: x\x0d\x0aConnection: close\x0d\x0a\x0d\x0a")
	assert_equal(req.length, task_write_all(fd, req.data, req.length))
	string_free(req)
	string_builder* resp = string_new()
	char* buf = malloc(1024)
	while (1):
		int n = task_read(fd, buf, 1024)
		if (n <= 0):
			break
		string_append_bytes(resp, buf, n)
	free(buf)
	close(fd)
	if (htt_contains(resp.data, path) && htt_contains(resp.data, c"200 OK")):
		ok.push(1)
	string_free(resp)


generator int htt_stop_when_done(task* server, list[int] ok, int want):
	while (ok.length < want):
		task_sleep_ms(1)
	task_cancel(server)


void test_server_and_clients_share_a_scheduler():
	ServerContext* s = htt_new_server()
	asserts(c"server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	list[int] ok = new list[int]
	task_scheduler* sched = task_scheduler_new()
	task* server = task_spawn(sched, server_accept_task(s, 0))
	int i = 0
	while (i < 8):
		task_spawn(sched, htt_client(port, c"/in-process", ok))
		i = i + 1
	task_spawn(sched, htt_stop_when_done(server, ok, 8))
	assert_equal(0, task_run(sched))
	assert_equal(8, ok.length)
	assert_equal(8, task_result(server))
	task_scheduler_free(sched)
	list_free[int](ok)
	server_context_free(s)


/* http_client.w inside tasks: requests from several tasks run against
   an in-process server on the same scheduler. A client that blocked
   the thread would starve the server and never get its answer. */

generator int htt_http_request_task(char* url, list[int] ok):
	http_req* req = http_req_new(c"GET", url)
	http_req_add_header(req, c"Connection", c"close")
	req.tls_insecure_skip_verify = 1
	req.tls_handshake_timeout_ms = 60000
	req.timeout_ms = 60000
	http_response* resp = http_request(req)
	if ((resp.error == 0) && (resp.status == 200)):
		if (htt_contains(resp.body, c"/client")):
			ok.push(1)
	http_response_free(resp)
	http_req_free(req)


void htt_clients_in_tasks(char* scheme, int with_tls, int clients):
	ServerContext* s = htt_new_server()
	if (with_tls):
		server_context_set_tls(s, c"libs/standard/net/tls_fixtures/server_p256_cert.pem", c"libs/standard/net/tls_fixtures/server_p256_key.pem")
	asserts(c"server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	char* url = htt_url(scheme, port, c"/client")
	list[int] ok = new list[int]
	task_scheduler* sched = task_scheduler_new()
	task* server = task_spawn(sched, server_accept_task(s, 0))
	int i = 0
	while (i < clients):
		task_spawn_sized(sched, htt_http_request_task(url, ok), server_task_stack_bytes())
		i = i + 1
	task_spawn(sched, htt_stop_when_done(server, ok, clients))
	assert_equal(0, task_run(sched))
	assert_equal(clients, ok.length)
	task_scheduler_free(sched)
	list_free[int](ok)
	free(url)
	server_context_free(s)


void test_http_client_in_tasks():
	htt_clients_in_tasks(c"http", 0, 4)


void test_https_client_in_tasks():
	htt_clients_in_tasks(c"https", 1, 2)
