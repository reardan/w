import lib.lib
import lib.assert
import lib.net
import lib.http


int http_server():
	int server_socket = socket_tcp_ipv4()
	asserts(c"server socket: ", server_socket > 0)
	int err
	err = socket_set_reuseaddr(server_socket)
	assert_equal(0, err)
	println(c"bind()")
	int port = 8080
	err = socket_bind_ipv4(server_socket, ip4_from_string(c"127.0.0.1"), port)
	assert_equal(0, err)
	int queue_length = 0
	int listen_result = socket_listen(server_socket, queue_length)
	asserts(c"listen failed: ", listen_result == 0)
	print_int(c"now listening: http://127.0.0.1:", port)
	int n = 16000
	char* buf = malloc(n)

	int file = open(c"tests/w.html", 0, 511)
	asserts(c"Could not open file w.html", file > 0)
	print_int(c"file: ", file)
	int size = file_size(file)
	print_int(c"size: ", size)
	char* html = malloc(size)
	int read_count = read(file, html, size)
	print_int(c"read_count: ", read_count)
	asserts(c"file read failed: ", read_count >= 0)
	int body_size = read_count

	while (1):
		int client_socket = socket_accept_connection(server_socket)
		asserts(c"accept failed: ", client_socket >= 0)
		print_int(c"client accepted, file: ", client_socket)
		# todo: gethostbyaddr
		err = read(client_socket, buf, n)
		asserts(c"client read failed: ", err >= 0)
		print_int(c"client request length: ", err)
		# println(buf)
		# parse_headers(buf)
		# add gethostbyaddr (lookup peer)
		println(c"responding to client")
		http_write_ok_headers(client_socket, c"text/html", body_size)
		write(client_socket, html, body_size)
		print_int(c"closing client file: ", client_socket)
		close(client_socket)

	close(server_socket)
	return 0


int main(int argc, int argv):
	http_server()


	exit(0)
