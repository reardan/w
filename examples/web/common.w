import lib.lib
import lib.args
import lib.net


int web_default_buffer_size():
	return 32768


void web_check_syscall(char* name, int result):
	if (result < 0):
		print_string(name, c" failed")
		translate_syscall_failure(result)


char* web_arg_or(char* name, char* fallback):
	char* value = args_value(name)
	if (value == 0):
		return fallback
	return value


int web_arg_port(char* name, int fallback):
	char* value = args_value(name)
	if (value == 0):
		return fallback
	int port = atoi(value)
	if (port <= 0):
		print_string(c"bad port for --", name)
		exit(1)
	return port


int web_connect_ipv4(char* ip, int port):
	int sock = socket_tcp_ipv4()
	web_check_syscall(c"socket", sock)
	web_check_syscall(c"connect", socket_connect_ipv4(sock, ip4_from_string(ip), port))
	return sock


int web_listen_ipv4(char* ip, int port):
	int sock = socket_tcp_ipv4()
	web_check_syscall(c"socket", sock)
	web_check_syscall(c"setsockopt", socket_set_reuseaddr(sock))
	web_check_syscall(c"bind", socket_bind_ipv4(sock, ip4_from_string(ip), port))
	web_check_syscall(c"listen", socket_listen(sock, 8))
	return sock


void web_write_get_request(int sock, char* host, char* path):
	write_string(sock, c"GET ")
	write_string(sock, path)
	write_string(sock, c" HTTP/1.1\x0d\x0a")
	write_string(sock, c"Host: ")
	write_string(sock, host)
	write_string(sock, c"\x0d\x0a")
	write_string(sock, c"Accept: application/json\x0d\x0a")
	write_string(sock, c"Connection: close\x0d\x0a")
	write_string(sock, c"\x0d\x0a")


char* web_read_all(int file, int capacity):
	char* buf = malloc(capacity + 1)
	int total = 0
	int done = 0
	while (done == 0):
		int remaining = capacity - total
		if (remaining <= 0):
			done = 1
		else:
			int count = read(file, buf + total, remaining)
			web_check_syscall(c"read", count)
			if (count == 0):
				done = 1
			else:
				total = total + count
	buf[total] = 0
	return buf


int web_header_end(char* text):
	int i = 0
	while (text[i] != 0):
		if ((text[i] == 13) && (text[i + 1] == 10) && (text[i + 2] == 13) && (text[i + 3] == 10)):
			return i + 4
		i = i + 1
	return -1


char* web_response_body(char* response):
	int body_index = web_header_end(response)
	if (body_index < 0):
		return response
	return response + body_index


int web_stream_until_close(int from_file, int to_file, int capacity):
	char* buf = malloc(capacity)
	int total = 0
	int done = 0
	while (done == 0):
		int count = read(from_file, buf, capacity)
		web_check_syscall(c"read", count)
		if (count == 0):
			done = 1
		else:
			web_check_syscall(c"write", write(to_file, buf, count))
			total = total + count
	free(buf)
	return total
