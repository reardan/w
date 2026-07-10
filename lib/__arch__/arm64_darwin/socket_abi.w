# Per-target socket ABI values for lib/net.w (plan 11 phase 2 darwin
# socket audit, issue #200): the parts of the BSD socket interface that
# Linux and Darwin define differently. lib/net.w imports this module
# through the reserved __arch__ path segment, so one import line binds
# the right values for whichever target is being compiled.
#
# Darwin values from xnu bsd/sys/socket.h and bsd/sys/fcntl.h. The
# address families, socket types, F_GETFL/F_SETFL, and the pollfd
# layout and POLLIN/POLLOUT bits all match Linux, so only the values
# below need per-target treatment.


# Value of sockaddr_in's leading 16-bit field for an address family.
# Darwin splits the leading 16 bits into sin_len then sin_family bytes;
# stores are little-endian, so sin_len is the low byte. sin_len is the
# full size of sockaddr_in (16).
int socket_abi_family_word(int family):
	return ((family & 255) << 8) | 16


# Address family carried in sockaddr_in's leading 16-bit field
# (the second byte on Darwin).
int socket_abi_family_from_word(int word):
	return (word >> 8) & 255


# SOL_SOCKET is 0xffff on Darwin, not Linux's 1.
int socket_abi_sol_socket():
	return 65535


int socket_abi_so_reuseaddr():
	return 4


# SO_NOSIGPIPE (0x1022): Darwin has no MSG_NOSIGNAL send flag, so
# SIGPIPE suppression is a per-socket option instead.
int socket_abi_so_nosigpipe():
	return 4130


# O_NONBLOCK for fcntl(F_SETFL) is 0x4 on Darwin (Linux's 2048 is
# O_EXCL there, which F_SETFL silently ignores).
int socket_abi_o_nonblock():
	return 4


# No MSG_NOSIGNAL on Darwin; see socket_abi_so_nosigpipe.
int socket_abi_msg_nosignal():
	return 0


# errno values the socket helpers branch on (as positive numbers; the
# syscall wrappers return them negated).
int socket_abi_eagain():
	return 35


int socket_abi_einprogress():
	return 36


# SO_RCVTIMEO (0x1006) / SO_SNDTIMEO (0x1005) for setsockopt: bound a
# blocking recv/send with a struct timeval so a stalled peer cannot
# wedge the caller (the TLS transport path in web/http_client.w).
int socket_abi_so_rcvtimeo():
	return 4102


int socket_abi_so_sndtimeo():
	return 4101
