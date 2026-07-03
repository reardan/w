import examples.web.common


void http_proxy_usage():
	println("usage: http_proxy [--ip=127.0.0.1] [--port=8081] [--upstream-ip=127.0.0.1] [--upstream-port=8080]")


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag("help")):
		http_proxy_usage()
		return 0

	char* ip = web_arg_or("ip", "127.0.0.1")
	int port = web_arg_port("port", 8081)
	char* upstream_ip = web_arg_or("upstream-ip", "127.0.0.1")
	int upstream_port = web_arg_port("upstream-port", 8080)

	int server = web_listen_ipv4(ip, port)
	print_string("proxy listening on ", ip)
	print_int(":", port)

	int client = socket_accept_connection(server)
	web_check_syscall("accept", client)

	char* request = malloc(web_default_buffer_size() + 1)
	int request_bytes = read(client, request, web_default_buffer_size())
	web_check_syscall("read", request_bytes)
	request[request_bytes] = 0
	print_int("proxy received request bytes: ", request_bytes)

	int upstream = web_connect_ipv4(upstream_ip, upstream_port)
	web_check_syscall("write", write(upstream, request, request_bytes))
	int response_bytes = web_stream_until_close(upstream, client, web_default_buffer_size())
	print_int("proxy forwarded response bytes: ", response_bytes)

	free(request)
	close(upstream)
	close(client)
	close(server)
	return 0
