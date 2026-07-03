import lib.linux
import lib.memory


struct sockaddr_in:
	int16 family
	uint16 port
	int ip_address
	int zero1
	int zero2


int af_unix():
	return 1


int af_inet():
	return 2


int sock_stream():
	return 1


int sock_dgram():
	return 2


int sol_socket():
	return 1


int so_reuseaddr():
	return 2


int sockaddr_in_size():
	return 16


int net_htons(int value):
	return ((value & 255) << 8) | ((value >> 8) & 255)


int net_htonl(int value):
	int b1 = (value & 255) << 24
	int b2 = (value & 65280) << 8
	int b3 = (value >> 8) & 65280
	int b4 = (value >> 24) & 255
	return b1 | b2 | b3 | b4


void sockaddr_in_init(sockaddr_in* addr, int ip_address, int port):
	addr.family = af_inet()
	addr.port = net_htons(port)
	addr.ip_address = net_htonl(ip_address)
	addr.zero1 = 0
	addr.zero2 = 0


int socket_ipv4(int socket_type):
	return sys_socket(af_inet(), socket_type, 0)


int socket_tcp_ipv4():
	return socket_ipv4(sock_stream())


int socket_udp_ipv4():
	return socket_ipv4(sock_dgram())


int socket_bind_ipv4(int sockfd, int ip_address, int port):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip_address, port)
	return sys_bind(sockfd, &addr, sockaddr_in_size())


int socket_connect_ipv4(int sockfd, int ip_address, int port):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip_address, port)
	return sys_connect(sockfd, &addr, sockaddr_in_size())


int socket_listen(int sockfd, int backlog):
	return sys_listen(sockfd, backlog)


int socket_accept_connection(int sockfd):
	return sys_accept(sockfd, 0, 0)


int socket_getsockname_ipv4(int sockfd, sockaddr_in* addr):
	int addrlen = sockaddr_in_size()
	return sys_getsockname(sockfd, addr, &addrlen)


int socket_set_reuseaddr(int sockfd):
	int enabled = 1
	return sys_setsockopt(sockfd, sol_socket(), so_reuseaddr(), &enabled, 4)


int socket_pair(int* fds):
	char* kernel_fds = malloc(8)
	int err = sys_socketpair(af_unix(), sock_stream(), 0, kernel_fds)
	if (err < 0):
		free(kernel_fds)
		return err
	fds[0] = load_int32(kernel_fds)
	fds[1] = load_int32(kernel_fds + 4)
	free(kernel_fds)
	return err


int socket_send_to_ipv4(int sockfd, char* buf, int len, int flags, int ip_address, int port):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip_address, port)
	return sys_sendto(sockfd, buf, len, flags, &addr, sockaddr_in_size())
