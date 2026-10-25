import lib.lib
import lib.linux
import lib.memory
import lib.__arch__.socket_abi
import lib.__arch__.socket_identity
import lib.poll
import lib.io_wait
import lib.io
import lib.time

const int SOCKADDR_UN_SIZE = 110


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


const int af_unix = 1
const int af_inet = 2
const int sock_stream = 1
const int sock_dgram = 2


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


const int sockaddr_in_size = 16


int net_htons(int value):
	return ((value & 255) << 8) | ((value >> 8) & 255)


int net_htonl(int value):
	int b1 = (value & 255) << 24
	int b2 = (value & 65280) << 8
	int b3 = (value >> 8) & 65280
	int b4 = (value >> 24) & 255
	return b1 | b2 | b3 | b4


void sockaddr_in_init(sockaddr_in* addr, int ip_address, int port):
	addr.family = socket_abi_family_word(af_inet)
	addr.port = net_htons(port)
	addr.ip_address = net_htonl(ip_address)
	addr.zero1 = 0
	addr.zero2 = 0


# Address family of a sockaddr_in filled by the kernel or by
# sockaddr_in_init, independent of the target's leading-field layout.
int sockaddr_in_family(sockaddr_in* addr):
	return socket_abi_family_from_word(addr.family & 65535)


int socket_ipv4(int socket_type):
	return sys_socket(af_inet, socket_type, 0)


int socket_tcp_ipv4():
	return socket_ipv4(sock_stream)


int socket_udp_ipv4():
	return socket_ipv4(sock_dgram)


int socket_bind_ipv4(int sockfd, int ip_address, int port):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip_address, port)
	return sys_bind(sockfd, &addr, sockaddr_in_size)


int socket_connect_ipv4(int sockfd, int ip_address, int port):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip_address, port)
	return sys_connect(sockfd, &addr, sockaddr_in_size)


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
	int addrlen = sockaddr_in_size
	return sys_accept(sockfd, cast(int, addr), &addrlen)


int socket_getsockname_ipv4(int sockfd, sockaddr_in* addr):
	int addrlen = sockaddr_in_size
	return sys_getsockname(sockfd, cast(int, addr), &addrlen)


int socket_set_reuseaddr(int sockfd):
	int enabled = 1
	return sys_setsockopt(sockfd, sol_socket(), so_reuseaddr(), &enabled, 4)


int socket_pair(int* fds):
	char* kernel_fds = cast(char*, malloc(8))
	int err = sys_socketpair(af_unix, sock_stream, 0, cast(int, kernel_fds))
	if (err < 0):
		free(kernel_fds)
		return err
	fds[0] = load_int32(kernel_fds)
	fds[1] = load_int32(kernel_fds + 4)
	free(kernel_fds)
	return err


/* AF_UNIX (unix-domain) stream sockets: the wbuildd stage-1
prerequisite from issue #231 (docs/projects/wbuildd.md par. 2.3).

Linux sockaddr_un is a 16-bit family word followed by a 108-byte
NUL-padded sun_path (110 bytes total); Darwin prefixes a length byte
but keeps sun_path at the same offset 2, and xnu overwrites sun_len
from the syscall's addrlen argument on input, so writing the leading
word with socket_abi_family_word keeps the family byte right on both
layouts. W structs carry no fixed-size array fields (the lib/ndarray.w
note), so the address is built in a raw SOCKADDR_UN_SIZE buffer
instead of a struct, and bind/connect pass the exact used length
(2 + path + NUL) -- valid on every target. The helpers below wrap the
buffer handling completely, so callers only ever pass a path; listen
and accept need no unix variants (socket_listen /
socket_accept_connection are address-family-agnostic already).

A bound socket file is NOT removed by close(); servers should
unlink(path) when shutting down, and socket_bind_unix_replacing_stale
handles the crashed-predecessor case at startup. */


# Longest usable path (excluding its NUL): the tightest sun_path across
# supported targets (Darwin's 104 bytes; Linux would allow 107).
const int SOCKADDR_UN_PATH_MAX = 103


# Fills the SOCKADDR_UN_SIZE()-byte buffer at addr with an AF_UNIX
# address for path. Returns the exact addrlen to pass to bind/connect
# (family word + path + NUL), or -22 (-EINVAL) when path is too long.
int sockaddr_un_init(char* addr, char* path):
	int path_length = strlen(path)
	if (path_length > SOCKADDR_UN_PATH_MAX): return 0 - 22
	int i = 0
	while (i < SOCKADDR_UN_SIZE):
		addr[i] = 0
		i = i + 1
	save_int16(addr, socket_abi_family_word(af_unix))
	i = 0
	while (i < path_length):
		addr[2 + i] = path[i]
		i = i + 1
	return 2 + path_length + 1


int socket_unix_stream():
	return sys_socket(af_unix, sock_stream, 0)


int socket_bind_unix(int sockfd, char* path):
	char* addr = cast(char*, malloc(SOCKADDR_UN_SIZE))
	int addrlen = sockaddr_un_init(addr, path)
	if (addrlen < 0):
		free(addr)
		return addrlen
	int err = sys_bind(sockfd, cast(int, addr), addrlen)
	free(addr)
	return err


int socket_connect_unix(int sockfd, char* path):
	char* addr = cast(char*, malloc(SOCKADDR_UN_SIZE))
	int addrlen = sockaddr_un_init(addr, path)
	if (addrlen < 0):
		free(addr)
		return addrlen
	int err = sys_connect(sockfd, cast(int, addr), addrlen)
	free(addr)
	return err


# bind that survives a crashed predecessor's leftover socket file:
# when the plain bind fails, a probe connect() decides whether a live
# server still answers on path. If one does, its address is left alone
# and the original bind error comes back; if nothing answers, the path
# is treated as stale, unlinked, and claimed with one retry. Callers
# own the path either way -- a non-socket file squatting on it is
# removed too (errno values never need inspecting, so this stays free
# of per-target errno tables).
int socket_bind_unix_replacing_stale(int sockfd, char* path):
	int err = socket_bind_unix(sockfd, path)
	if (err >= 0):
		return err
	int probe = socket_unix_stream()
	if (probe < 0):
		return err
	int connected = socket_connect_unix(probe, path)
	close(probe)
	if (connected >= 0):
		return err
	unlink(path)
	return socket_bind_unix(sockfd, path)


# Creates, binds (replacing a stale socket file), and listens a unix
# stream socket at path. Returns the listening fd, or a negative
# errno; accept clients with socket_accept_connection.
int socket_listen_unix_path(char* path, int backlog):
	int sockfd = socket_unix_stream()
	if (sockfd < 0):
		return sockfd
	int err = socket_bind_unix_replacing_stale(sockfd, path)
	if (err < 0):
		close(sockfd)
		return err
	err = socket_listen(sockfd, backlog)
	if (err < 0):
		close(sockfd)
		return err
	return sockfd


# Creates and connects a unix stream socket to the server listening at
# path. Returns the connected fd, or a negative errno.
int socket_connect_unix_path(char* path):
	int sockfd = socket_unix_stream()
	if (sockfd < 0):
		return sockfd
	int err = socket_connect_unix(sockfd, path)
	if (err < 0):
		close(sockfd)
		return err
	return sockfd


int socket_send_to_ipv4(int sockfd, char* buf, int len, int flags, int ip_address, int port):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip_address, port)
	return sys_sendto(sockfd, buf, len, flags, &addr, sockaddr_in_size)


# send(2) on a connected socket (sendto with no address).
int socket_send(int sockfd, char* buf, int len, int flags):
	return sys_sendto(sockfd, buf, len, flags, 0, 0)


int socket_recv(int sockfd, char* buf, int len, int flags):
	return sys_recv(sockfd, buf, len, flags)


# Receives one datagram and fills addr with the sender address.
# Returns the number of bytes received or a negative errno.
int socket_recv_from_ipv4(int sockfd, char* buf, int len, int flags, sockaddr_in* addr):
	int addrlen = sockaddr_in_size
	return sys_recvfrom(sockfd, buf, len, flags, cast(int, addr), cast(int, &addrlen))


const int f_getfl = 3
const int f_setfl = 4


int o_nonblock():
	return socket_abi_o_nonblock()


# After this, read/recv on an empty descriptor returns -EAGAIN
# (-net_eagain()) instead of blocking.
int socket_set_nonblocking(int sockfd):
	int flags = sys_fcntl(sockfd, f_getfl, 0)
	if (flags < 0):
		return flags
	return sys_fcntl(sockfd, f_setfl, flags | o_nonblock())


# Disables SIGPIPE for the whole socket on targets that support it
# (Darwin SO_NOSIGPIPE). A no-op returning 0 on Linux, where callers
# pass msg_nosignal() to socket_send instead.
int socket_set_nosigpipe(int sockfd):
	if (socket_abi_so_nosigpipe() == 0): return 0
	int enabled = 1
	return sys_setsockopt(sockfd, sol_socket(), socket_abi_so_nosigpipe(), &enabled, 4)


# Clears O_NONBLOCK so read/recv/send block again. The TLS transport in
# web/http_client.w pairs a blocking socket with SO_RCVTIMEO/SO_SNDTIMEO:
# net/tls.w does blocking socket_recv/socket_send internally, and the
# timeouts keep every handshake/read/write wait bounded.
int socket_set_blocking(int sockfd):
	int flags = sys_fcntl(sockfd, f_getfl, 0)
	if (flags < 0):
		return flags
	return sys_fcntl(sockfd, f_setfl, flags & ~o_nonblock())


# Sets a SO_RCVTIMEO/SO_SNDTIMEO option from a millisecond timeout. The
# struct timeval is two word-sized fields, matching the native long-sized
# timeval on every supported target (8 bytes on 32-bit, 16 on 64-bit).
int socket_set_timeout_opt(int sockfd, int optname, int timeout_ms):
	int* tv = cast(int*, malloc(__word_size__ * 2))
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


# SO_ERROR is a native C int and its length a native socklen_t, both
# four bytes even when W int is eight. Returns zero or negative errno.
int socket_pending_error(int fd):
	int32 pending = 0
	int32 length = 4
	int rc = sys_getsockopt(fd, sol_socket(), socket_abi_so_error(), &pending, &length)
	if (rc < 0): return rc
	return 0 - cast(int, pending)


# Socket errors retain native errno while mapping platform categories.
int net_result_from_syscall(io_result* r, int rc):
	if (rc >= 0): return io_result_set(r, rc, IO_OK, 0)
	int err = 0 - rc
	return io_result_set(r, 0, io_status_from_errno(err), err)


# io_poll and io_check use the platform errno constants, just like native
# socket syscalls. Preserve that value alongside its portable category.
int net_wait_status_from_errno(int err):
	return io_status_from_errno(err)


int net_wait_result_from_syscall(io_result* r, int rc):
	if (rc >= 0): return io_result_set(r, rc, IO_OK, 0)
	return io_result_set(r, 0, net_wait_status_from_errno(0 - rc), 0 - rc)


# Nonblocking TCP connect to a prepared sockaddr (family af_inet with a
# sockaddr_in, or net_af_inet6() with a sockaddr_in6) with an explicit
# error result. Returns the connected fd (still nonblocking), or -1
# with r holding the native errno/category. Readiness is only a hint:
# SO_ERROR obtains the actual asynchronous connection outcome. EINTR
# restarts the wait against the original deadline.
int net_connect_sockaddr_timeout_checked(int family, char* addr, int addrlen, int timeout_ms, io_result* r):
	int cancelled = io_check()
	if (cancelled < 0):
		io_result_from_syscall(r, cancelled)
		return -1
	int fd = sys_socket(family, sock_stream, 0)
	if (fd < 0):
		net_result_from_syscall(r, fd)
		return -1
	int wait_error = 0
	int rc = socket_set_nonblocking(fd)
	if (rc >= 0): rc = socket_set_nosigpipe(fd)
	if (rc >= 0): rc = sys_connect(fd, cast(int, addr), addrlen)
	if (rc == (0 - net_einprogress())):
		int start = time_monotonic_ms()
		while (1):
			rc = io_check()
			if (rc < 0):
				wait_error = 1
				break
			int remaining = timeout_ms
			if (timeout_ms >= 0):
				remaining = timeout_ms - (time_monotonic_ms() - start)
				if (remaining < 0): remaining = 0
			int ready = io_poll(fd, poll_out, remaining)
			if (ready == -4): continue
			if (ready == 0):
				rc = 0 - IO_ERRNO_ETIMEDOUT
				wait_error = 1
			else if (ready < 0):
				rc = ready
				wait_error = 1
			else if ((ready & poll_nval) != 0): rc = -9
			else:
				rc = io_check()
				if (rc < 0): wait_error = 1
				else: rc = socket_pending_error(fd)
			break
	if (rc < 0):
		close(fd)
		if (wait_error): net_wait_result_from_syscall(r, rc)
		else: net_result_from_syscall(r, rc)
		return -1
	io_result_set(r, 0, IO_OK, 0)
	return fd


# IPv4 form of net_connect_sockaddr_timeout_checked (host-order ip).
int net_connect_timeout_checked(int ip, int port, int timeout_ms, io_result* r):
	sockaddr_in addr
	sockaddr_in_init(&addr, ip, port)
	return net_connect_sockaddr_timeout_checked(af_inet, cast(char*, &addr), sockaddr_in_size, timeout_ms, r)


# Compatibility wrapper: -2 on timeout, -1 on other errors.
int net_connect_timeout(int ip, int port, int timeout_ms):
	io_result r
	int fd = net_connect_timeout_checked(ip, port, timeout_ms, &r)
	if ((fd < 0) && (r.status == IO_TIMED_OUT)): return -2
	return fd


# Caller-owned, kernel-filled sockaddr bytes. length includes the family;
# Unix paths may be unnamed or contain NUL bytes (Linux abstract names).
# No string conversion, allocation, or caller-provided label is involved.
struct net_peer_address:
	int family
	int length
	char[128] data


struct net_peer_credentials:
	int pid                  # -1 when the OS supplies no process id
	int uid                  # native 32-bit ID bit pattern
	int gid                  # native 32-bit ID bit pattern


const int NET_SHUT_READ = 0
const int NET_SHUT_WRITE = 1
const int NET_SHUT_BOTH = 2


void net_peer_address_clear(net_peer_address* out):
	out.family = 0
	out.length = 0
	char* raw = cast(char*, &out.data[0])
	int i = 0
	while (i < 128):
		raw[i] = 0
		i = i + 1


void net_peer_credentials_clear(net_peer_credentials* out):
	out.pid = -1
	out.uid = -1
	out.gid = -1


# Nonblocking metadata query. A failure leaves an empty result, never
# stale identity. io_result.transferred is always zero for control calls.
int socket_peer_address_checked(int fd, net_peer_address* out, io_result* r):
	net_peer_address_clear(out)
	if (socket_identity_supported() == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	int32 length = 128
	int rc = socket_identity_getpeername(fd, cast(char*, &out.data[0]), &length)
	if (rc < 0):
		net_peer_address_clear(out)
		return net_result_from_syscall(r, rc)
	if ((length < 2) || (length > 128)):
		net_peer_address_clear(out)
		return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	out.length = cast(int, length)
	out.family = socket_abi_family_from_word(load_int16(cast(char*, &out.data[0])))
	return io_result_set(r, 0, IO_OK, 0)


# Only AF_UNIX has local OS credentials. In particular, Linux's dummy
# SO_PEERCRED result on TCP must never be mistaken for a valid identity.
# These are connection-time OS credentials, not cryptographic authentication.
int socket_peer_credentials_checked(int fd, net_peer_credentials* out, io_result* r):
	net_peer_credentials_clear(out)
	net_peer_address address
	int status = socket_peer_address_checked(fd, &address, r)
	if (status != IO_OK): return status
	if (address.family != af_unix): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	int rc = socket_identity_credentials(fd, &out.pid, &out.uid, &out.gid)
	if (rc < 0): net_peer_credentials_clear(out)
	# Linux connected datagrams can return success with no credentials.
	# Never expose the kernel's (0, -1, -1) sentinel as a peer identity.
	int unavailable_id = 65535
	unavailable_id = (unavailable_id << 16) | 65535
	if (rc == 0 && out.pid <= 0 && out.uid == unavailable_id && out.gid == unavailable_id):
		net_peer_credentials_clear(out)
		return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	return net_result_from_syscall(r, rc)


# Raw checked shutdown retains the kernel's repeated-call and errno
# behavior. Direction uses NET_SHUT_* (identical on Linux and Darwin).
int socket_shutdown_checked(int fd, int direction, io_result* r):
	if (socket_identity_supported() == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	return net_result_from_syscall(r, socket_identity_shutdown(fd, direction))


/* IPv6 (stdlib parity P3.10). Addresses cross this API as 16 bytes in
network order (the packed form of libs/standard/net/ipaddress.w's
ip_address_packed), so lib/ stays free of text parsing.

W structs do not use C field layout (int16/int32 fields are padded),
so sockaddr_in6 wraps a raw 28-byte buffer (declare it as a local or
with new: a T[N] field has a runtime header that raw malloc'd memory
lacks). Layout: family word at 0 (sin6_len +
family on Darwin), port at 2 (network order), flowinfo at 4, address
at 8, scope_id at 24 (native order). The syscalls take the same
pointer on every target: x86 goes through socketcall, x64/arm64/Darwin
call socket/bind/connect directly, and none of them care about the
address family. */

const int sockaddr_in6_size = 28


struct sockaddr_in6:
	char[28] raw


int net_af_inet6():
	return socket_abi_af_inet6()


# Positive errno values meaning "no IPv6 on this host/network" (the
# family is compiled out, ::1 is not configured, or no route).
int net_eafnosupport():
	return socket_abi_eafnosupport()


int net_eaddrnotavail():
	return socket_abi_eaddrnotavail()


int net_enetunreach():
	return socket_abi_enetunreach()


# 1 when a negated errno from an IPv6 socket/bind/connect means the
# host has no usable IPv6 rather than a peer-specific failure.
int net_ipv6_unavailable_error(int rc):
	int err = 0 - rc
	return (err == net_eafnosupport()) || (err == net_eaddrnotavail()) || (err == net_enetunreach())


char* sockaddr_in6_bytes(sockaddr_in6* addr):
	return cast(char*, &addr.raw[0])


# ip16 is 16 network-order bytes (0 means the unspecified address ::).
# scope_id is the interface index for link-local addresses, else 0.
void sockaddr_in6_init(sockaddr_in6* addr, char* ip16, int port, int scope_id):
	char* raw = sockaddr_in6_bytes(addr)
	for i in range(sockaddr_in6_size): raw[i] = 0
	save_int16(raw, socket_abi_family_word_sized(net_af_inet6(), sockaddr_in6_size))
	raw[2] = (port >> 8) & 255
	raw[3] = port & 255
	if (ip16 != 0):
		for i in range(16): raw[8 + i] = ip16[i]
	save_int32(raw + 24, scope_id)


int sockaddr_in6_family(sockaddr_in6* addr):
	return socket_abi_family_from_word(load_int16(sockaddr_in6_bytes(addr)))


# Host-order port.
int sockaddr_in6_port(sockaddr_in6* addr):
	char* raw = sockaddr_in6_bytes(addr)
	return ((raw[2] & 255) << 8) | (raw[3] & 255)


# Copies the 16 network-order address bytes into out.
void sockaddr_in6_address(sockaddr_in6* addr, char* out):
	char* raw = sockaddr_in6_bytes(addr)
	for i in range(16): out[i] = raw[8 + i]


int sockaddr_in6_scope_id(sockaddr_in6* addr):
	return load_int32(sockaddr_in6_bytes(addr) + 24)


# Fills out (16 bytes) with ::1.
void net_ipv6_loopback(char* out):
	for i in range(15): out[i] = 0
	out[15] = 1


int socket_ipv6(int socket_type):
	return sys_socket(net_af_inet6(), socket_type, 0)


int socket_tcp_ipv6():
	return socket_ipv6(sock_stream)


int socket_udp_ipv6():
	return socket_ipv6(sock_dgram)


# IPV6_V6ONLY: 1 restricts an AF_INET6 socket to IPv6 peers, 0 also
# accepts IPv4-mapped peers (::ffff:a.b.c.d) on a dual-stack listener.
int socket_set_ipv6_only(int sockfd, int enabled):
	int32 value = enabled != 0
	return sys_setsockopt(sockfd, socket_abi_ipproto_ipv6(), socket_abi_ipv6_v6only(), cast(int, &value), 4)


int socket_bind_ipv6(int sockfd, char* ip16, int port):
	sockaddr_in6 addr
	sockaddr_in6_init(&addr, ip16, port, 0)
	return sys_bind(sockfd, cast(int, sockaddr_in6_bytes(&addr)), sockaddr_in6_size)


int socket_connect_ipv6(int sockfd, char* ip16, int port):
	sockaddr_in6 addr
	sockaddr_in6_init(&addr, ip16, port, 0)
	return sys_connect(sockfd, cast(int, sockaddr_in6_bytes(&addr)), sockaddr_in6_size)


int socket_accept_connection_from_ipv6(int sockfd, sockaddr_in6* addr):
	int32 addrlen = sockaddr_in6_size
	return sys_accept(sockfd, cast(int, sockaddr_in6_bytes(addr)), cast(int, &addrlen))


int socket_getsockname_ipv6(int sockfd, sockaddr_in6* addr):
	int32 addrlen = sockaddr_in6_size
	return sys_getsockname(sockfd, cast(int, sockaddr_in6_bytes(addr)), cast(int, &addrlen))


int socket_send_to_ipv6(int sockfd, char* buf, int len, int flags, char* ip16, int port):
	sockaddr_in6 addr
	sockaddr_in6_init(&addr, ip16, port, 0)
	return sys_sendto(sockfd, buf, len, flags, cast(int, sockaddr_in6_bytes(&addr)), sockaddr_in6_size)


int socket_recv_from_ipv6(int sockfd, char* buf, int len, int flags, sockaddr_in6* addr):
	int32 addrlen = sockaddr_in6_size
	return sys_recvfrom(sockfd, buf, len, flags, cast(int, sockaddr_in6_bytes(addr)), cast(int, &addrlen))


# IPv6 form of net_connect_timeout_checked.
int net_connect6_timeout_checked(char* ip16, int port, int scope_id, int timeout_ms, io_result* r):
	sockaddr_in6 addr
	sockaddr_in6_init(&addr, ip16, port, scope_id)
	return net_connect_sockaddr_timeout_checked(net_af_inet6(), sockaddr_in6_bytes(&addr), sockaddr_in6_size, timeout_ms, r)


/* Family-tagged addresses and Happy-Eyeballs-lite connects (RFC 8305
section 4 ordering, sequential attempts). A resolver fills an array of
net_address; net_addresses_interleave alternates the families
starting with IPv6; net_connect_addresses_timeout_checked tries each
in turn. */

# No T[N] fields: those carry a hidden runtime header that raw malloc'd
# arrays of the struct would leave uninitialized, and resolvers hand
# out malloc'd net_address arrays. The IPv6 bytes are packed big-endian
# four to an int instead; use net_address_ipv6_bytes to read them.
struct net_address:
	int family          # af_inet or net_af_inet6()
	int ipv4            # host order, when family == af_inet
	int ipv6_0          # IPv6 bytes 0..3, big-endian packed
	int ipv6_1
	int ipv6_2
	int ipv6_3
	int scope_id        # IPv6 interface index, else 0


int net_pack_be32(char* p):
	return ((p[0] & 255) << 24) | ((p[1] & 255) << 16) | ((p[2] & 255) << 8) | (p[3] & 255)


void net_unpack_be32(int value, char* p):
	p[0] = (value >> 24) & 255
	p[1] = (value >> 16) & 255
	p[2] = (value >> 8) & 255
	p[3] = value & 255


void net_address_set_ipv4(net_address* a, int ip):
	a.family = af_inet
	a.ipv4 = ip
	a.ipv6_0 = 0
	a.ipv6_1 = 0
	a.ipv6_2 = 0
	a.ipv6_3 = 0
	a.scope_id = 0


# ip16: 16 network-order bytes.
void net_address_set_ipv6(net_address* a, char* ip16, int scope_id):
	a.family = net_af_inet6()
	a.ipv4 = 0
	a.ipv6_0 = net_pack_be32(ip16)
	a.ipv6_1 = net_pack_be32(&ip16[4])
	a.ipv6_2 = net_pack_be32(&ip16[8])
	a.ipv6_3 = net_pack_be32(&ip16[12])
	a.scope_id = scope_id


# Writes the 16 network-order IPv6 bytes of a into out (zeros for IPv4).
void net_address_ipv6_bytes(net_address* a, char* out):
	net_unpack_be32(a.ipv6_0, out)
	net_unpack_be32(a.ipv6_1, &out[4])
	net_unpack_be32(a.ipv6_2, &out[8])
	net_unpack_be32(a.ipv6_3, &out[12])


int net_address_is_ipv6(net_address* a):
	return a.family == net_af_inet6()


int net_address_equal(net_address* a, net_address* b):
	if (a.family != b.family): return 0
	if (a.family == af_inet): return a.ipv4 == b.ipv4
	if (a.scope_id != b.scope_id): return 0
	return (a.ipv6_0 == b.ipv6_0) && (a.ipv6_1 == b.ipv6_1) && (a.ipv6_2 == b.ipv6_2) && (a.ipv6_3 == b.ipv6_3)


void net_address_copy(net_address* from, net_address* to):
	to.family = from.family
	to.ipv4 = from.ipv4
	to.ipv6_0 = from.ipv6_0
	to.ipv6_1 = from.ipv6_1
	to.ipv6_2 = from.ipv6_2
	to.ipv6_3 = from.ipv6_3
	to.scope_id = from.scope_id


# Reorders addrs in place: IPv6, IPv4, IPv6, IPv4, ... keeping the
# resolver's order within each family; leftovers of the longer family
# go last. A list with one family is unchanged.
void net_addresses_interleave(net_address* addrs, int count):
	if (count <= 1): return
	net_address* sorted = cast(net_address*, malloc(sizeof(net_address) * count))
	int next6 = 0
	int next4 = 0
	int want6 = 1
	for out in range(count):
		while ((next6 < count) && (net_address_is_ipv6(&addrs[next6]) == 0)): next6 += 1
		while ((next4 < count) && net_address_is_ipv6(&addrs[next4])): next4 += 1
		int take6 = want6
		if (next6 >= count): take6 = 0
		if (next4 >= count): take6 = 1
		if (take6):
			net_address_copy(&addrs[next6], &sorted[out])
			next6 += 1
		else:
			net_address_copy(&addrs[next4], &sorted[out])
			next4 += 1
		want6 = take6 == 0
	for i in range(count): net_address_copy(&sorted[i], &addrs[i])
	free(sorted)


int net_connect_address_timeout_checked(net_address* a, int port, int timeout_ms, io_result* r):
	if (net_address_is_ipv6(a)):
		char* ip16 = cast(char*, malloc(16))
		net_address_ipv6_bytes(a, ip16)
		int fd = net_connect6_timeout_checked(ip16, port, a.scope_id, timeout_ms, r)
		free(ip16)
		return fd
	return net_connect_timeout_checked(a.ipv4, port, timeout_ms, r)


# Tries addrs[0..count) in order until one connects. Every attempt but
# the last is capped at an even share of the remaining budget, so a
# black-holed first address cannot starve the fallback; fast failures
# (no IPv6, refused, unreachable) move on immediately. timeout_ms < 0
# means unbounded attempts. Cancellation stops the walk. Returns the
# connected nonblocking fd, or -1 with r from the last attempt.
int net_connect_addresses_timeout_checked(net_address* addrs, int count, int port, int timeout_ms, io_result* r):
	if (count <= 0):
		io_result_set(r, 0, IO_UNSUPPORTED, 0)
		return -1
	int start = time_monotonic_ms()
	for i in range(count):
		int budget = timeout_ms
		if (timeout_ms >= 0):
			budget = timeout_ms - (time_monotonic_ms() - start)
			if (budget <= 0):
				io_result_set(r, 0, IO_TIMED_OUT, IO_ERRNO_ETIMEDOUT)
				return -1
			budget = budget / (count - i)
			if (budget <= 0): budget = 1
		int fd = net_connect_address_timeout_checked(&addrs[i], port, budget, r)
		if (fd >= 0): return fd
		if (r.status == IO_CANCELLED): return -1
	return -1
