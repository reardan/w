import examples.web.common
import lib.http
import structures.json


void http_server_usage():
	println("usage: http_server [--ip=127.0.0.1] [--port=8080]")


char* http_server_response_body(int request_bytes):
	json_value* body = json_object()
	json_object_set(body, "message", json_string("hello from W"))
	json_object_set(body, "status", json_string("ok"))
	json_object_set(body, "request_bytes", json_int(request_bytes))
	char* text = json_stringify(body)
	json_free(body)
	return text


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag("help")):
		http_server_usage()
		return 0

	char* ip = web_arg_or("ip", "127.0.0.1")
	int port = web_arg_port("port", 8080)
	int server = web_listen_ipv4(ip, port)
	print_string("listening on ", ip)
	print_int(":", port)

	int client = socket_accept_connection(server)
	web_check_syscall("accept", client)

	char* request = malloc(web_default_buffer_size() + 1)
	int request_bytes = read(client, request, web_default_buffer_size())
	web_check_syscall("read", request_bytes)
	request[request_bytes] = 0

	println("request:")
	println(request)

	char* body = http_server_response_body(request_bytes)
	http_write_ok_headers(client, "application/json", strlen(body))
	write_string(client, body)

	free(body)
	free(request)
	close(client)
	close(server)
	return 0
