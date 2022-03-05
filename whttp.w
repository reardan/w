import lib
import assert

void response_headers(int file, int size):
	write_string(file, "HTTP/1.1 200 OK\x0a")
	write_string(file, "Server: whttp\x0a")
	write_string(file, "Date: Thu, 03 Mar 2022 12:14:21 GMT\x0a")
	write_string(file, "Content-Type: text/html\x0a")
	write_string(file, "Content-Length: ")
	write_string(file, itoa(size))
	write_string(file, "\x0aLast-Modified: Thu, 03 Mar 2022 11:01:26 GMT\x0a")
	write_string(file, "Connection: keep-alive\x0a")
	write_string(file, "Accept-Ranges: bytes\x0a\x0a")
	# "ETag: "6220a006-264""


int http_server():
	int server_socket = socket(2, 1, 0)
	asserts("server socket: ", server_socket > 0)
	int err
	err = setsockopt(server_socket)  /*re-use*/
	assert_equal(0, err)
	println("bind()")
	int port = 8080
	err = bind(server_socket, port)
	assert_equal(0, err)
	int queue_length = 0
	int listen_result = listen(server_socket)
	asserts("listen failed: ", listen_result > 0)
	print_int("now listening on port: ", port)
	int n = 16000
	char* buf = malloc(n)

	int file = open("/home/w/git/w/w.html", 0, 511)
	asserts("Could not open file w.html", file > 0)
	print_int("file: ", file)
	int size = file_size(file)
	print_int("size: ", size)
	char* html = malloc(size)
	int read_count = read(file, html, size)
	print_int("read_count: ", read_count)

	while (1):
		int client_socket = socket_accept(server_socket)
		print_int("client accepted, file: ", client_socket)
		# todo: gethostbyaddr
		err = read(client_socket, buf, n)
		print_int("client request length: ", err)
		# println(buf)
		# parse_headers(buf)
        # add gethostbyaddr (lookup peer)
		println("responding to client")
		response_headers(client_socket, size)
		write(client_socket, html, size)
		print_int("closing client file: ", client_socket)
		close(client_socket)

	close(server_socket)
	return 0


int main(int argc, int argv):
	http_server()


	exit(0)
