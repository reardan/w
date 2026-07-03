import examples.web.common
import structures.json


void http_client_usage():
	println("usage: http_client [--ip=127.0.0.1] [--port=8080] [--host=127.0.0.1] [--path=/]")


void http_client_print_json_summary(char* body):
	json_value* root = json_parse(body)
	if (root == 0):
		println("body is not JSON")
		return

	println("parsed JSON body:")
	if (root.type == json_type_object()):
		json_value* message = json_object_get(root, "message")
		if (message != 0):
			if (message.type == json_type_string()):
				print_string("message: ", message.string_value)

		json_value* status = json_object_get(root, "status")
		if (status != 0):
			if (status.type == json_type_string()):
				print_string("status: ", status.string_value)

		json_value* request_bytes = json_object_get(root, "request_bytes")
		if (request_bytes != 0):
			if (request_bytes.type == json_type_int()):
				print_int("request_bytes: ", request_bytes.int_value)
	json_free(root)


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag("help")):
		http_client_usage()
		return 0

	char* ip = web_arg_or("ip", "127.0.0.1")
	int port = web_arg_port("port", 8080)
	char* host = web_arg_or("host", ip)
	char* path = web_arg_or("path", "/")

	int sock = web_connect_ipv4(ip, port)
	web_write_get_request(sock, host, path)
	char* response = web_read_all(sock, web_default_buffer_size())
	close(sock)

	println("raw response:")
	println(response)
	http_client_print_json_summary(web_response_body(response))
	free(response)
	return 0
