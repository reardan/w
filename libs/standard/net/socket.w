import lib.lib
import lib.linux
import libs.standard.net.ipaddress


struct std_socket_sockaddr_in:
	int16 family
	uint16 port
	int ip_address
	int zero1
	int zero2


struct socket:
	int fd
	int closed


int std_socket_af_inet():
	return 2


int std_socket_sock_stream():
	return 1


int std_socket_sockaddr_in_size():
	return 16


int std_socket_htons(int value):
	return ((value & 255) << 8) | ((value >> 8) & 255)


int std_socket_htonl(int value):
	int b1 = (value & 255) << 24
	int b2 = (value & 65280) << 8
	int b3 = (value >> 8) & 65280
	int b4 = (value >> 24) & 255
	return b1 | b2 | b3 | b4


void std_socket_sockaddr_in_init(std_socket_sockaddr_in* addr, int ip_address, int port):
	addr.family = std_socket_af_inet()
	addr.port = std_socket_htons(port)
	addr.ip_address = std_socket_htonl(ip_address)
	addr.zero1 = 0
	addr.zero2 = 0


socket* std_socket_from_fd(int fd):
	socket* s = new socket
	s.fd = fd
	s.closed = 0
	return s


socket* std_socket_create_tcp4():
	int fd = sys_socket(std_socket_af_inet(), std_socket_sock_stream(), 0)
	if (fd < 0):
		return 0
	return std_socket_from_fd(fd)


int std_socket_bind(socket* s, char* host, int port):
	if ((s == 0) | (s.closed)):
		return -1
	int address = 0
	if (ipv4_parse(host, &address) == 0):
		return -1
	std_socket_sockaddr_in addr
	std_socket_sockaddr_in_init(&addr, address, port)
	return sys_bind(s.fd, cast(int, &addr), std_socket_sockaddr_in_size())


int std_socket_listen(socket* s, int backlog):
	if ((s == 0) | (s.closed)):
		return -1
	return sys_listen(s.fd, backlog)


socket* std_socket_accept(socket* s):
	if ((s == 0) | (s.closed)):
		return 0
	int fd = sys_accept(s.fd, 0, 0)
	if (fd < 0):
		return 0
	return std_socket_from_fd(fd)


int std_socket_connect(socket* s, char* host, int port):
	if ((s == 0) | (s.closed)):
		return -1
	int address = 0
	if (ipv4_parse(host, &address) == 0):
		return -1
	std_socket_sockaddr_in addr
	std_socket_sockaddr_in_init(&addr, address, port)
	return sys_connect(s.fd, cast(int, &addr), std_socket_sockaddr_in_size())


int std_socket_send(socket* s, char* data, int length):
	if ((s == 0) | (s.closed)):
		return -1
	return write(s.fd, data, length)


int std_socket_recv(socket* s, char* buf, int length):
	if ((s == 0) | (s.closed)):
		return -1
	return sys_recv(s.fd, buf, length, 0)


void std_socket_close(socket* s):
	if (s == 0):
		return
	if (s.closed == 0):
		close(s.fd)
		s.closed = 1
