# Task-based framed echo server (docs/projects/async.md): the
# straight-line counterpart to the callback-style connection handling
# in lib/json_rpc.w. One task accepts connections; each connection gets
# its own task that reads Content-Length framed messages (lib/framing.w)
# and echoes them back uppercased — sequential code, no per-connection
# state machine, while every connection still shares one thread.
#
# Build and try it:
#   ./bin/wv2 examples/web/task_echo_server.w -o ./bin/task_echo_server
#   ./bin/task_echo_server            # in-process demo: server + 2 clients
#   ./bin/task_echo_server --serve    # serve on 127.0.0.1:7777
import lib.lib
import lib.net
import lib.framing
import lib.task
import lib.task_io


int loopback_ip():
	return 2130706433 /* 127.0.0.1 */


# Reads one framed message without blocking the scheduler: waits for
# readability between fills. Returns a malloc'd body (length through
# length_out) or 0 on EOF / error / cancellation.
char* task_frame_read_message(frame_reader* r, int* length_out):
	char* body = frame_take_buffered_message(r, length_out)
	while (body == 0):
		if (r.error):
			return 0
		int revents = task_await_fd(r.fd, poll_in())
		if (revents < 0):
			return 0
		int count = frame_reader_fill(r)
		if (count == 0):
			# EOF: clean if nothing was buffered, truncated otherwise.
			if (r.offset < r.length):
				r.error = 1
			return 0
		if ((count < 0) & (count != -11)): /* EAGAIN just polls again */
			r.error = 1
			return 0
		body = frame_take_buffered_message(r, length_out)
	return body


# Writes "Content-Length: N\r\n\r\n" + body, suspending on backpressure.
int task_frame_write_message(int fd, char* body, int length):
	char* digits = itoa(length)
	char* header = strjoin(c"Content-Length: ", digits)
	char* full_header = strjoin(header, c"\x0d\x0a\x0d\x0a")
	free(digits)
	free(header)
	int header_length = strlen(full_header)
	int written = task_write_all(fd, full_header, header_length)
	free(full_header)
	if (written < 0):
		return written
	int body_written = task_write_all(fd, body, length)
	if (body_written < 0):
		return body_written
	return header_length + body_written


void uppercase_ascii(char* text, int length):
	int i = 0
	while (i < length):
		int b = text[i] & 255
		if ((b >= 'a') & (b <= 'z')):
			text[i] = b - 32
		i = i + 1


# One task per connection: read a frame, uppercase it, write it back,
# until the peer closes. Compare with jsonrpc_attach_connection /
# jsonrpc_connection_on_readable in lib/json_rpc.w, which spread the
# same loop across callbacks and a heap context struct.
generator int echo_connection(int fd):
	frame_reader* reader = frame_reader_new(fd)
	int handled = 0
	while (1):
		int length = 0
		char* body = task_frame_read_message(reader, &length)
		if (body == 0):
			break
		uppercase_ascii(body, length)
		int written = task_frame_write_message(fd, body, length)
		free(body)
		if (written < 0):
			break
		handled = handled + 1
	frame_reader_free(reader)
	close(fd)
	task_finish(handled)


# Accepts up to connection_count connections (forever when < 0).
generator int echo_acceptor(int listen_fd, int connection_count):
	int accepted = 0
	while ((connection_count < 0) | (accepted < connection_count)):
		int fd = task_accept(listen_fd)
		if (fd < 0):
			break
		task_go(echo_connection(fd))
		accepted = accepted + 1
	task_finish(accepted)


int listen_on(int ip_address, int port, int* port_out):
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return fd
	socket_set_reuseaddr(fd)
	int err = socket_bind_ipv4(fd, ip_address, port)
	if (err < 0):
		return err
	err = socket_listen(fd, 16)
	if (err < 0):
		return err
	sockaddr_in addr
	socket_getsockname_ipv4(fd, &addr)
	*port_out = net_htons(addr.port)
	socket_set_nonblocking(fd)
	return fd


/* Demo mode: the server plus two clients interleave in one process. */

generator int demo_client(int port, int id, char* message):
	int fd = socket_tcp_ipv4()
	if (task_connect_ipv4(fd, loopback_ip(), port) < 0):
		print(c"demo: connect failed\n")
		task_finish(1)
		return

	int failures = 0
	int length = strlen(message)
	frame_reader* reader = frame_reader_new(fd)
	int round = 0
	while (round < 2):
		if (task_frame_write_message(fd, message, length) < 0):
			failures = failures + 1
		int reply_length = 0
		char* reply = task_frame_read_message(reader, &reply_length)
		if (reply == 0):
			failures = failures + 1
		else:
			print(c"client ")
			print(itoa(id))
			print(c" got: ")
			print(reply)
			print(c"\n")
			free(reply)
		round = round + 1
	frame_reader_free(reader)
	close(fd)
	task_finish(failures)


int run_demo():
	int port = 0
	int listen_fd = listen_on(loopback_ip(), 0, &port)
	if (listen_fd < 0):
		print(c"demo: listen failed\n")
		return 1
	print_int(c"demo: serving on 127.0.0.1:", port)

	task_scheduler* s = task_scheduler_new()
	task_spawn(s, echo_acceptor(listen_fd, 2))
	task* c1 = task_spawn(s, demo_client(port, 1, c"hello from the first client"))
	task* c2 = task_spawn(s, demo_client(port, 2, c"and the second one"))
	int err = task_run(s)
	int failures = task_result(c1) + task_result(c2)
	task_scheduler_free(s)
	close(listen_fd)
	if ((err < 0) | (failures > 0)):
		print(c"demo: FAILED\n")
		return 1
	print(c"demo: OK\n")
	return 0


int run_server():
	int port = 0
	int listen_fd = listen_on(loopback_ip(), 7777, &port)
	if (listen_fd < 0):
		print(c"task_echo_server: listen failed\n")
		return 1
	print_int(c"task_echo_server: listening on 127.0.0.1:", port)
	task_scheduler* s = task_scheduler_new()
	task_spawn(s, echo_acceptor(listen_fd, -1))
	int err = task_run(s)
	task_scheduler_free(s)
	close(listen_fd)
	if (err < 0):
		return 1
	return 0


int main(int argc, int argv):
	if (argc > 1):
		char** arg = argv + __word_size__
		if (strcmp(*arg, c"--serve") == 0):
			return run_server()
	return run_demo()
