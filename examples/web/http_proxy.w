import examples.web.common


void http_proxy_usage():
	println(c"usage: http_proxy [--ip=127.0.0.1] [--port=8081] [--upstream-ip=127.0.0.1] [--upstream-port=8080]")


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag(c"help")):
		http_proxy_usage()
		return 0

	char* ip = web_arg_or(c"ip", c"127.0.0.1")
	int port = web_arg_port(c"port", 8081)
	char* upstream_ip = web_arg_or(c"upstream-ip", c"127.0.0.1")
	int upstream_port = web_arg_port(c"upstream-port", 8080)

	int server = web_listen_ipv4(ip, port)
	print_error(c"proxy listening on http://")
	print_error(ip)
	print_int(c":", port)

	int client = socket_accept_connection(server)
	web_check_syscall(c"accept", client)

	char* request = malloc(web_default_buffer_size() + 1)
	int request_bytes = read(client, request, web_default_buffer_size())
	web_check_syscall(c"read", request_bytes)
	request[request_bytes] = 0
	print_int(c"proxy received request bytes: ", request_bytes)

	int upstream = web_connect_ipv4(upstream_ip, upstream_port)
	web_check_syscall(c"write", write(upstream, request, request_bytes))
	int response_bytes = web_stream_until_close(upstream, client, web_default_buffer_size())
	print_int(c"proxy forwarded response bytes: ", response_bytes)

	free(request)
	close(upstream)
	close(client)
	close(server)
	return 0
