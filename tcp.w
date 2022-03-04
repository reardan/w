import lib
import assert
import list


# add gethostbyaddr (lookup peer)


# https://datatracker.ietf.org/doc/html/rfc6455#section-5.2
# https://en.wikipedia.org/wiki/WebSocket
void websockets_request(int file):
	write_string(file, "GET /chat HTTP/1.1")
	write_string(file, "Host: server.example.com")
	write_string(file, "Upgrade: websocket")
	write_string(file, "Connection: Upgrade")
	write_string(file, "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==")
	write_string(file, "Sec-WebSocket-Protocol: chat, superchat")
	write_string(file, "Sec-WebSocket-Version: 13")
	write_string(file, "Origin: http://example.com")


void websockets_response(int file):
	write_string(file, "HTTP/1.1 101 Switching Protocols")
	write_string(file, "Upgrade: websocket")
	write_string(file, "Connection: Upgrade")
	write_string(file, "Sec-WebSocket-Accept: HSmrc0sMlYUkAGmm5OPpG2HaGWk=")
	write_string(file, "Sec-WebSocket-Protocol: chat")


void parse_headers(int message):
	die()
	println("parsing headers")
	println("")
	split_string(message, "\x0a")
	int i = 0
	while (i < length):
		char* str = get(i)
		print_string("line: ", str)
		i = i + 1


void respond(int file):
	write_string(file, "HTTP/1.1 200 OK\x0a")
	write_string(file, "Server: whttp\x0a")
	write_string(file, "Date: Thu, 03 Mar 2022 12:14:21 GMT\x0a")
	write_string(file, "Content-Type: text/html\x0a")
	write_string(file, "Content-Length: 612\x0a")
	write_string(file, "Last-Modified: Thu, 03 Mar 2022 11:01:26 GMT\x0a")
	write_string(file, "Connection: keep-alive\x0a")
	write_string(file, "Accept-Ranges: bytes\x0a\x0a")
	# "ETag: "6220a006-264""

	write_string(file, "<!DOCTYPE html>")
	write_string(file, "<html>")
	write_string(file, "<head>")
	write_string(file, "<title>Welcome to whttp!</title>")
	write_string(file, "<style>")
	write_string(file, "    body {")
	write_string(file, "        width: 35em;")
	write_string(file, "        margin: 0 auto;")
	write_string(file, "        font-family: Tahoma, Verdana, Arial, sans-serif;")
	write_string(file, "    }")
	write_string(file, "</style>")
	write_string(file, "</head>")
	write_string(file, "<body>")
	write_string(file, "<h1>Welcome to whttp!</h1>")
	write_string(file, "<p>If you see this page, the whttp web server is successfully installed and")
	write_string(file, "working. Further configuration is required.</p>")
	write_string(file, "<p><em>Thank you for using w.</em></p>")
	write_string(file, "</body>")
	write_string(file, "</html>")


void respond1(int client_sock):
	println("")
	println("writing data...")
	char message = "Hi there dude!\x0a"
	write_string(client_sock, message)


int http_server():
	int server_sock = socket(2, 1, 0)
	asserts("server socket: ", server_sock > 0)
	int err
	err = setsockopt(server_sock)  /*re-use*/
	assert_equal(0, err)
	println("bind()")
	int port = 7777
	err = bind(server_sock, port)
	assert_equal(0, err)
	int queue_length = 0
	int listen_result = listen(server_sock)
	asserts("listen failed: ", listen_result > 0)
	print_int("now listening on port: ", port)
	int n = 8000
	char* buf = malloc(n)
	# todo: loop
	while (1):
		println("")
		println("accept()")
		int client_sock = socket_accept(server_sock)
		print_int("client_sock: ", client_sock)
		# todo: gethostbyaddr
		err = read(client_sock, buf, n)
		print_int("read error", err)
		# println(buf)
		parse_headers(buf)
		respond(client_sock)
		close(client_sock)
	close(server_sock)
	return 0



int server():
	int server_sock = socket(2, 1, 0)
	print_int("server socket: ", server_sock)
	int err
	println("setsockopt()")
	err = setsockopt(server_sock)  /*re-use*/
	assert_equal(0, err)
	println("bind()")
	err = bind(server_sock, 7777)
	assert_equal(0, err)
	println("listen()")
	int queue_length = 0
	int listen_result = listen(server_sock)
	print_int("listen_result ", listen_result)
	asserts("listen failed: ", listen_result > 0)
	# todo: loop
	while (1):
		println("accept()")
		int client_sock = socket_accept(server_sock)
		print_int("client_sock: ", client_sock)
		write_string(client_sock, "yo yo yo\x0a")
		# gethostbyaddr
	close(server_sock)
	return 0


void read_socket(int file):
	char *buf = "0000000000000000000000000000000000000000"
	int read_result = read(file, buf, 40)
	buf[read_result] = 0
	print_int("read_result: ", read_result)
	print_string("received: ", buf)


void client():
	char* ip_string = "127.1.1.1"
	int ip = ip4_from_string(ip_string)
	print_hex("ip: ", ip)

	println("calling socket()")
	int file = socket(2, 1, 0)
	print_int("file: ", file)
	println("calling connect()")
	int port = 5555
	int connect_result = connect(file, ip, port)
	print_int("connect_result: ", connect_result)

	write_string(file, "How's it going?\x0a")
	# read_socket(file)
	close(file)


int main(int argc, int argv):
	http_server()


	exit(0)
