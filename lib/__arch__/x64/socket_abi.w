# Per-target socket ABI values for lib/net.w (plan 11 phase 2 darwin
# socket audit, issue #200): the parts of the BSD socket interface that
# Linux and Darwin define differently. lib/net.w imports this module
# through the reserved __arch__ path segment, so one import line binds
# the right values for whichever target is being compiled.
#
# Linux x64 values; identical to the x86 and arm64 modules.


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
