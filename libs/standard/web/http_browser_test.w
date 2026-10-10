# wbuild: x64
import lib.testing
import lib.task
import libs.standard.web.http_client
import libs.standard.net.testing


int browser_serve_once(int listener, char* response):
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		int fd = socket_accept_connection(listener)
		net_test_read_head(fd)
		net_test_send_text(fd, response)
		close(fd)
		exit(0)
	return pid


void test_http_owned_clients_and_shutdown():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = browser_serve_once(listener, c"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbody")
	char* url = net_test_url(c"http", port, c"/a#fragment")
	http_client* a = http_client_new()
	http_client* b = http_client_new()
	http_req* req = http_req_new(c"GET", url)
	req.client = a
	http_stream* first = http_open(req)
	assert_equal(0, first.error)
	assert_strings_equal(url, first.resp.final_url)
	http_stream* busy = http_open(req)
	assert_equal(http_error_client_busy, busy.error)
	http_stream_close(busy)
	net_test_finish(pid, listener)
	listener = net_test_listen(&port)
	pid = browser_serve_once(listener, c"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnext")
	char* other = net_test_url(c"http", port, c"/")
	req.url = other
	req.client = b
	http_stream* second = http_open(req)
	assert_equal(0, second.error)
	http_client_free(a)
	assert_equal(http_error_cancelled, first.error)
	char[8] buf
	assert_equal(4, http_stream_read(second, buf, 8))
	assert_bytes_equal(c"next", buf, 4)
	http_stream_close(first)
	http_stream_close(second)
	http_client_close(b)
	http_stream* closed = http_open(req)
	assert_equal(http_error_client_closed, closed.error)
	http_stream_close(closed)
	http_client_free(b)
	http_req_free(req)
	free(url)
	free(other)
	net_test_finish(pid, listener)


void test_http_total_deadline_stops_trickle():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		int fd = socket_accept_connection(listener)
		net_test_read_head(fd)
		net_test_send_text(fd, c"HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n")
		for i in range(50):
			if (socket_send(fd, c"x", 1, msg_nosignal()) <= 0): break
			sleep_ms(10)
		close(fd)
		exit(0)
	char* url = net_test_url(c"http", port, c"/")
	http_req* req = http_req_new(c"GET", url)
	req.total_timeout_ms = 150
	req.timeout_ms = 1000
	int start = time_monotonic_ms()
	http_response* resp = http_request(req)
	assert_equal(http_error_timeout, resp.error)
	asserts(c"partial body", resp.body_len > 0 && resp.body_len < 50)
	asserts(c"deadline", time_monotonic_ms() - start < 2000)
	http_response_free(resp)
	http_req_free(req)
	free(url)
	net_test_finish(pid, listener)


void test_http_streaming_limit_and_partial_body():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = browser_serve_once(listener, c"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nabcdef\r\n0\r\n\r\n")
	char* url = net_test_url(c"http", port, c"/")
	http_req* req = http_req_new(c"GET", url)
	req.total_timeout_ms = 1000
	req.max_stream_bytes = 3
	http_response* resp = http_request(req)
	assert_equal(http_error_body_too_large, resp.error)
	assert_equal(3, resp.body_len)
	assert_strings_equal(c"abc", resp.body)
	http_response_free(resp)
	http_req_free(req)
	free(url)
	net_test_finish(pid, listener)
	listener = net_test_listen(&port)
	pid = browser_serve_once(listener, c"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc")
	url = net_test_url(c"http", port, c"/")
	req = http_req_new(c"GET", url)
	req.total_timeout_ms = 1000
	resp = http_request(req)
	assert_equal(http_error_truncated_body, resp.error)
	assert_equal(3, resp.body_len)
	http_response_free(resp)
	http_req_free(req)
	free(url)
	net_test_finish(pid, listener)


int browser_deny_redirect(void* context, URL* from, URL* to, int status):
	int* calls = cast(int*, context)
	*calls = *calls + 1
	assert_equal(302, status)
	assert_strings_equal(c"/a", from.path)
	assert_strings_equal(c"/a", to.path)
	assert_strings_equal(c"next", to.query)
	return 0


void test_http_redirect_approval_and_reference():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = browser_serve_once(listener, c"HTTP/1.1 302 Found\r\nLocation: ?next#part\r\nContent-Length: 0\r\n\r\n")
	char* url = net_test_url(c"http", port, c"/a?old")
	http_req* req = http_req_new(c"GET", url)
	req.total_timeout_ms = 1000
	int calls = 0
	req.redirect_context = cast(void*, &calls)
	req.approve_redirect = browser_deny_redirect
	http_response* resp = http_request(req)
	assert_equal(1, calls)
	assert_equal(302, resp.status)
	assert_equal(0, resp.error)
	assert_equal(0, resp.redirect_count)
	assert_strings_equal(url, resp.final_url)
	http_response_free(resp)
	http_req_free(req)
	free(url)
	net_test_finish(pid, listener)


int browser_cancel_now():
	return 0 - IO_ERRNO_ECANCELED


void test_http_cancel_before_connect():
	io_check_fn* old = io_check_hook
	io_check_hook = browser_cancel_now
	http_req* req = http_req_new(c"GET", c"http://127.0.0.1:1/")
	req.total_timeout_ms = 1000
	http_response* resp = http_request(req)
	assert_equal(http_error_cancelled, resp.error)
	http_response_free(resp)
	http_req_free(req)
	io_check_hook = old


void test_http_tls_failure_details():
	for checked in range(2):
		int port = 0
		int listener = net_test_listen(&port)
		int pid = fork()
		asserts(c"fork", pid >= 0)
		if (pid == 0):
			int fd = socket_accept_connection(listener)
			char[8192] buf
			read(fd, buf, 8192)
			net_test_send_text(fd, c"\x16\x03\x03\xff\xff")
			close(fd)
			exit(0)
		char* url = net_test_url(c"https", port, c"/")
		http_req* req = http_req_new(c"GET", url)
		if (checked): req.total_timeout_ms = 3000
		http_response* resp = http_request(req)
		assert_equal(http_error_tls, resp.error)
		assert_strings_equal(c"tls: record too long", resp.error_message)
		http_response_free(resp)
		http_req_free(req)
		free(url)
		net_test_finish(pid, listener)


generator int browser_cancel_request(http_req* req, int* error):
	http_response* resp = http_request(req)
	*error = resp.error
	http_response_free(resp)


generator int browser_cancel_after_wait(task* pending):
	task_sleep_ms(30)
	task_cancel(pending)


void test_http_task_cancellation_header_body_and_tls():
	for phase in range(3):
		int port = 0
		int listener = net_test_listen(&port)
		int pid = fork()
		asserts(c"fork", pid >= 0)
		if (pid == 0):
			int fd = socket_accept_connection(listener)
			if (phase == 2):
				char[8192] buf
				read(fd, buf, 8192)
			else:
				net_test_read_head(fd)
				if (phase == 1): net_test_send_text(fd, c"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n")
			sleep_ms(500)
			close(fd)
			exit(0)
		char* scheme = c"http"
		if (phase == 2): scheme = c"https"
		char* url = net_test_url(scheme, port, c"/")
		http_req* req = http_req_new(c"GET", url)
		req.total_timeout_ms = 3000
		int error = 0
		task_scheduler* scheduler = task_scheduler_new()
		task* pending = task_spawn_sized(scheduler, browser_cancel_request(req, &error), 1048576)
		task_spawn(scheduler, browser_cancel_after_wait(pending))
		assert_equal(0, task_run(scheduler))
		assert_equal(http_error_cancelled, error)
		task_scheduler_free(scheduler)
		http_req_free(req)
		free(url)
		net_test_finish(pid, listener)


int browser_allow_redirect(void* context, URL* from, URL* to, int status):
	int* calls = cast(int*, context)
	*calls = *calls + 1
	assert_equal(302, status)
	assert_equal(1, url_same_origin(from, to))
	return 1


void test_http_redirect_final_url_loop_and_separate_body_limits():
	for looping in range(2):
		int port = 0
		int listener = net_test_listen(&port)
		int pid = fork()
		asserts(c"fork", pid >= 0)
		if (pid == 0):
			for i in range(2):
				int fd = socket_accept_connection(listener)
				net_test_read_head(fd)
				if (i == 0 || looping): net_test_send_text(fd, c"HTTP/1.1 302 Found\r\nLocation: ?\r\nContent-Length: 4\r\n\r\nskip")
				else: net_test_send_text(fd, c"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nend")
				close(fd)
			exit(0)
		char* url = net_test_url(c"http", port, c"/a?old")
		http_req* req = http_req_new(c"GET", url)
		req.total_timeout_ms = 3000
		req.max_redirects = 1
		req.max_stream_bytes = 3
		int calls = 0
		req.approve_redirect = browser_allow_redirect
		req.redirect_context = cast(void*, &calls)
		http_response* resp = http_request(req)
		if (looping): assert_equal(http_error_too_many_redirects, resp.error)
		else:
			assert_equal(0, resp.error)
			assert_strings_equal(c"end", resp.body)
			char* final = net_test_url(c"http", port, c"/a?")
			assert_strings_equal(final, resp.final_url)
			free(final)
		assert_equal(1, calls)
		assert_equal(1, resp.redirect_count)
		http_response_free(resp)
		http_req_free(req)
		free(url)
		net_test_finish(pid, listener)


generator int browser_owned_parallel(char* url, int* count):
	http_client* client = http_client_new()
	http_req* req = http_req_new(c"GET", url)
	req.client = client
	req.total_timeout_ms = 3000
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_strings_equal(c"ok", resp.body)
	*count = *count + 1
	http_response_free(resp)
	http_req_free(req)
	http_client_free(client)


void test_http_owned_clients_run_simultaneously():
	int port = 0
	int listener = net_test_listen(&port)
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		int first = socket_accept_connection(listener)
		socket_set_recv_timeout(first, 3000)
		net_test_read_head(first)
		int second = socket_accept_connection(listener)
		socket_set_recv_timeout(second, 3000)
		net_test_read_head(second)
		# Neither request can complete until both have arrived.
		net_test_send_text(second, c"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
		net_test_send_text(first, c"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
		close(first)
		close(second)
		exit(0)
	char* url = net_test_url(c"http", port, c"/")
	int count = 0
	task_scheduler* scheduler = task_scheduler_new()
	task_spawn(scheduler, browser_owned_parallel(url, &count))
	task_spawn(scheduler, browser_owned_parallel(url, &count))
	assert_equal(0, task_run(scheduler))
	assert_equal(2, count)
	task_scheduler_free(scheduler)
	free(url)
	net_test_finish(pid, listener)
