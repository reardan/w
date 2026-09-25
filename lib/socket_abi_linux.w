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
