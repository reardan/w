import lib.linux
import lib.memory
import lib.__arch__.socket_abi


# 16 bytes on the wire. The leading 16-bit field is sin_family on
# Linux and sin_len + sin_family bytes on Darwin; always write it with
# socket_abi_family_word and read it with sockaddr_in_family so both
# layouts work (issue #200 darwin socket audit).
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
	return socket_abi_sol_socket()


int so_reuseaddr():
	return socket_abi_so_reuseaddr()


# send/sendto flag suppressing SIGPIPE on a closed peer; 0 on targets
# without one (Darwin uses socket_set_nosigpipe instead).
int msg_nosignal():
	return socket_abi_msg_nosignal()


# EAGAIN/EINPROGRESS as positive numbers for the current target
# (Linux 11/115, Darwin 35/36); syscalls return them negated.
int net_eagain():
	return socket_abi_eagain()


int net_einprogress():
	return socket_abi_einprogress()


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
	addr.family = socket_abi_family_word(af_inet())
	addr.port = net_htons(port)
	addr.ip_address = net_htonl(ip_address)
	addr.zero1 = 0
	addr.zero2 = 0


# Address family of a sockaddr_in filled by the kernel or by
# sockaddr_in_init, independent of the target's leading-field layout.
int sockaddr_in_family(sockaddr_in* addr):
	return socket_abi_family_from_word(addr.family & 65535)


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


# Same as socket_accept_connection but also fills addr with the peer's
# address (network byte order, like a kernel-filled socket_getsockname_ipv4
# result: un-net_htonl/net_htons it for a human/ip4_from_string-shaped
# value). Used by the HTTP server framework (libs/standard/web/connection.w,
# issue #235) to record ConnectionContext's peer address without a
# separate getpeername(2) call.
int socket_accept_connection_from(int sockfd, sockaddr_in* addr):
	int addrlen = sockaddr_in_size()
	return sys_accept(sockfd, cast(int, addr), &addrlen)


int socket_getsockname_ipv4(int sockfd, sockaddr_in* addr):
	int addrlen = sockaddr_in_size()
	return sys_getsockname(sockfd, cast(int, addr), &addrlen)


int socket_set_reuseaddr(int sockfd):
	int enabled = 1
	return sys_setsockopt(sockfd, sol_socket(), so_reuseaddr(), &enabled, 4)


int socket_pair(int* fds):
	char* kernel_fds = malloc(8)
	int err = sys_socketpair(af_unix(), sock_stream(), 0, cast(int, kernel_fds))
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


# send(2) on a connected socket (sendto with no address).
int socket_send(int sockfd, char* buf, int len, int flags):
	return sys_sendto(sockfd, buf, len, flags, 0, 0)


int socket_recv(int sockfd, char* buf, int len, int flags):
	return sys_recv(sockfd, buf, len, flags)


# Receives one datagram and fills addr with the sender address.
# Returns the number of bytes received or a negative errno.
int socket_recv_from_ipv4(int sockfd, char* buf, int len, int flags, sockaddr_in* addr):
	int addrlen = sockaddr_in_size()
	return sys_recvfrom(sockfd, buf, len, flags, cast(int, addr), cast(int, &addrlen))


int f_getfl():
	return 3


int f_setfl():
	return 4


int o_nonblock():
	return socket_abi_o_nonblock()


# After this, read/recv on an empty descriptor returns -EAGAIN
# (-net_eagain()) instead of blocking.
int socket_set_nonblocking(int sockfd):
	int flags = sys_fcntl(sockfd, f_getfl(), 0)
	if (flags < 0):
		return flags
	return sys_fcntl(sockfd, f_setfl(), flags | o_nonblock())


# Disables SIGPIPE for the whole socket on targets that support it
# (Darwin SO_NOSIGPIPE). A no-op returning 0 on Linux, where callers
# pass msg_nosignal() to socket_send instead.
int socket_set_nosigpipe(int sockfd):
	if (socket_abi_so_nosigpipe() == 0):
		return 0
	int enabled = 1
	return sys_setsockopt(sockfd, sol_socket(), socket_abi_so_nosigpipe(), &enabled, 4)


# Clears O_NONBLOCK so read/recv/send block again. The TLS transport in
# web/http_client.w pairs a blocking socket with SO_RCVTIMEO/SO_SNDTIMEO:
# net/tls.w does blocking socket_recv/socket_send internally, and the
# timeouts keep every handshake/read/write wait bounded.
int socket_set_blocking(int sockfd):
	int flags = sys_fcntl(sockfd, f_getfl(), 0)
	if (flags < 0):
		return flags
	return sys_fcntl(sockfd, f_setfl(), flags & ~o_nonblock())


# Sets a SO_RCVTIMEO/SO_SNDTIMEO option from a millisecond timeout. The
# struct timeval is two word-sized fields, matching the native long-sized
# timeval on every supported target (8 bytes on 32-bit, 16 on 64-bit).
int socket_set_timeout_opt(int sockfd, int optname, int timeout_ms):
	int* tv = malloc(__word_size__ * 2)
	tv[0] = timeout_ms / 1000
	tv[1] = (timeout_ms % 1000) * 1000
	int rc = sys_setsockopt(sockfd, sol_socket(), optname, cast(int, tv), __word_size__ * 2)
	free(tv)
	return rc


# Bounds a blocking recv on this socket to timeout_ms (0 disables it).
int socket_set_recv_timeout(int sockfd, int timeout_ms):
	return socket_set_timeout_opt(sockfd, socket_abi_so_rcvtimeo(), timeout_ms)


# Bounds a blocking send on this socket to timeout_ms (0 disables it).
int socket_set_send_timeout(int sockfd, int timeout_ms):
	return socket_set_timeout_opt(sockfd, socket_abi_so_sndtimeo(), timeout_ms)
