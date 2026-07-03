
import lib.lib
import lib.assert
import lib.net


# https://github.com/openbsd/src/blob/master/sys/sys/socket.h
int main(int argc, int argv):
	# https://www.programminglogic.com/sockets-programming-in-c-using-udp-datagrams/
	int file = socket_udp_ipv4()
	print_int("file: ", file)
	asserts("Could not open socket", file >= 0)
	char* msg = "yo yo yo!\x0a"
	int send_result = socket_send_to_ipv4(file, msg, strlen(msg), 0, ip4_from_string("127.0.0.1"), 9)
	print_int("send_result: ", send_result)
	assert_equal(strlen(msg), send_result)
	close(file)
	return 0
