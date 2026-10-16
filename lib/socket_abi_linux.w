# Linux socket ABI values for lib/net.w: the per-target
# lib/__arch__/<target>/socket_abi.w modules of every Linux-shaped target
# (x86, x64, arm64, and the wasm/win64 placeholders) import this one;
# arm64_darwin keeps its own Darwin values.


# Value of sockaddr_in's leading 16-bit field for an address family.
# Linux lays sockaddr_in out with a 16-bit sin_family first.
int socket_abi_family_word(int family):
	return family


# Address family carried in sockaddr_in's leading 16-bit field.
int socket_abi_family_from_word(int word):
	return word & 65535


int socket_abi_sol_socket():
	return 1


int socket_abi_so_reuseaddr():
	return 2


# setsockopt option disabling SIGPIPE for the whole socket; 0 when the
# target has none (Linux callers pass MSG_NOSIGNAL per send instead).
int socket_abi_so_nosigpipe():
	return 0


# O_NONBLOCK for fcntl(F_SETFL).
int socket_abi_o_nonblock():
	return 2048


# send/sendto flag suppressing SIGPIPE on a closed peer (MSG_NOSIGNAL);
# 0 when the target has no such flag.
int socket_abi_msg_nosignal():
	return 16384


# errno values the socket helpers branch on (as positive numbers; the
# syscall wrappers return them negated).
int socket_abi_eagain():
	return 11


int socket_abi_einprogress():
	return 115


# SO_RCVTIMEO / SO_SNDTIMEO for setsockopt(SOL_SOCKET, ...): bound a
# blocking recv/send with a struct timeval so a stalled peer cannot
# wedge the caller (the TLS transport path in web/http_client.w).
int socket_abi_so_rcvtimeo():
	return 20


int socket_abi_so_sndtimeo():
	return 21


# Pending asynchronous socket error (read-and-clear).
int socket_abi_so_error():
	return 4


# Normalize only for portable status classification; retain raw errno.
int socket_abi_status_errno(int err):
	return err


# IPv6 (stdlib parity P3.10). AF_INET6 differs between Linux (10) and
# Darwin (30); IPPROTO_IPV6 is 41 on both, IPV6_V6ONLY is not.
int socket_abi_af_inet6():
	return 10


# Leading 16-bit field of a sockaddr of size bytes (sockaddr_in6 is 28).
# Linux has no length byte, so the size is unused.
int socket_abi_family_word_sized(int family, int size):
	return family


int socket_abi_ipproto_ipv6():
	return 41


int socket_abi_ipv6_v6only():
	return 26


# errno values for "this host has no IPv6" (socket or bind/connect).
int socket_abi_eafnosupport():
	return 97


int socket_abi_eaddrnotavail():
	return 99


int socket_abi_enetunreach():
	return 101
