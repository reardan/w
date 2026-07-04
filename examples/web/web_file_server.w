import examples.web.common
import lib.http


void web_file_server_usage():
	println(c"usage: web_file_server [--ip=127.0.0.1] [--port=8082]")


char* web_file_content_type(char* path):
	if (ends_with(path, c".html")):
		return c"text/html"
	if (ends_with(path, c".css")):
		return c"text/css"
	if (ends_with(path, c".js")):
		return c"application/javascript"
	if (ends_with(path, c".json")):
		return c"application/json"
	if (ends_with(path, c".txt")):
		return c"text/plain"
	if (ends_with(path, c".md")):
		return c"text/markdown"
	return c"application/octet-stream"


void web_file_write_text_response(int client, int status_code, char* reason, char* body):
	http_write_response_headers(client, status_code, reason, c"text/plain", strlen(body), c"close")
	write_string(client, body)


char* web_file_request_path(char* request):
	if (starts_with(request, c"GET ") == 0):
		return 0

	char* path = request + 4
	int i = 0
	while ((path[i] != 0) & (path[i] != ' ')):
		if ((path[i] == '?') | (path[i] == '#')):
			path[i] = 0
			return path
		i = i + 1
	path[i] = 0
	return path


int web_file_path_is_safe(char* path):
	if (path == 0):
		return 0
	int i = 0
	while (path[i] != 0):
		if ((path[i] == '.') & (path[i + 1] == '.')):
			return 0
		i = i + 1
	return 1


char* web_file_local_path(char* request_path):
	while (request_path[0] == '/'):
		request_path = request_path + 1
	if (request_path[0] == 0):
		return c"index.html"
	return request_path


void web_file_stream_file(int client, char* path):
	int file = open(path, 0, 0)
	if (file < 0):
		web_file_write_text_response(client, 404, c"Not Found", c"not found\n")
		return

	int size = file_size(file)
	if (size < 0):
		close(file)
		web_file_write_text_response(client, 404, c"Not Found", c"not found\n")
		return

	http_write_response_headers(client, 200, c"OK", web_file_content_type(path), size, c"close")

	char* buf = malloc(web_default_buffer_size())
	int remaining = size
	while (remaining > 0):
		int chunk_size = web_default_buffer_size()
		if (remaining < chunk_size):
			chunk_size = remaining
		int read_count = read(file, buf, chunk_size)
		web_check_syscall(c"read", read_count)
		if (read_count == 0):
			remaining = 0
		else:
			web_check_syscall(c"write", write(client, buf, read_count))
			remaining = remaining - read_count

	free(buf)
	close(file)


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_has_flag(c"help")):
		web_file_server_usage()
		return 0

	char* ip = web_arg_or(c"ip", c"127.0.0.1")
	int port = web_arg_port(c"port", 8082)
	int server = web_listen_ipv4(ip, port)
	print_error(c"file server listening on http://")
	print_error(ip)
	print_int(c":", port)

	int client = socket_accept_connection(server)
	web_check_syscall(c"accept", client)

	char* request = malloc(web_default_buffer_size() + 1)
	int request_bytes = read(client, request, web_default_buffer_size())
	web_check_syscall(c"read", request_bytes)
	request[request_bytes] = 0

	char* request_path = web_file_request_path(request)
	if (request_path == 0):
		web_file_write_text_response(client, 405, c"Method Not Allowed", c"method not allowed\n")
	else if (web_file_path_is_safe(request_path) == 0):
		web_file_write_text_response(client, 403, c"Forbidden", c"parent directories are not allowed\n")
	else:
		char* local_path = web_file_local_path(request_path)
		print_string(c"serving ", local_path)
		web_file_stream_file(client, local_path)

	free(request)
	close(client)
	close(server)
	return 0
