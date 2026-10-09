/*
Checked byte transport (docs/projects/budgets_transport.md, issue #514
stage W5): one interface that protocol adapters build on, with read,
write, close, a deadline and the peer's identity. Every operation fills
a caller-owned io_result (lib/io.w) and returns its IO_* status, so a
transport failure reads exactly like a descriptor failure.

	io_result r
	transport* t = transport_tcp_connect(ip, port, 1000, &r)
	if (t == 0): ... r.status / r.native_error say why
	transport_set_timeout(t, 5000)           # deadline: now + 5 s
	if (transport_write_all(t, req, n, &r) != IO_OK): ...
	if (transport_read_some(t, buf, cap, &r) == IO_EOF): ...
	transport_close(t, &r)                   # reports close(2)
	transport_free(t)                        # frees the descriptor

Contracts:
- read_some moves at least one byte or reports why not: IO_EOF when the
  peer finished sending, IO_TIMED_OUT once the deadline has passed,
  IO_CANCELLED when the calling task was cancelled, IO_IO_ERROR (with
  the errno) otherwise. write_all writes everything or stops at the
  first failure with the confirmed prefix in transferred.
- The deadline is absolute (time_monotonic_ms based) and covers every
  wait of every later operation until it is changed; an operation that
  starts after it passed fails with IO_TIMED_OUT without touching the
  descriptor. transport_set_timeout(t, -1) clears it.
- Waits go through io_poll (lib/io_wait.w): inside a task they park only
  the task, elsewhere they block the thread in poll(2). The socket
  adapter sends and receives with MSG_DONTWAIT, so it works on blocking
  and non-blocking sockets alike and never blocks past the deadline.
  Writes use MSG_NOSIGNAL (SO_NOSIGPIPE on Darwin): a closed peer is
  IO_IO_ERROR with EPIPE or ECONNRESET, never a SIGPIPE.
- After transport_close the descriptor is never touched again: reads
  and writes report IO_IO_ERROR with EBADF and a second close is IO_OK.
- transport_peer_address reads a kernel address; transport_peer_credentials
  reads local Unix OS credentials. Neither sets authenticated. Optional
  adapters return IO_UNSUPPORTED. See docs/projects/socket_identity.md.
- transport_shutdown performs directional shutdown without releasing the fd.
- Identity: peer is a description (for example "tcp:127.0.0.1:8080",
  "unix:/run/app.sock") of the address the socket was connected to or
  accepted from. It is NOT authenticated: authenticated is 1 only for an
  adapter that cryptographically verified the peer. Socket adapters do
  not. import lib.transport_tls for verified TLS server identities.
  transport_require_authenticated refuses an unverified peer (IO_UNSUPPORTED).

Adapters implement three functions over their own context:
	read_some(ctx, buf, len, timeout_ms, r)   timeout_ms: -1 = no limit
	write_some(ctx, buf, len, timeout_ms, r)
	close(ctx, r)
read_some/write_some attempt the operation, and if it would block wait up
to timeout_ms for readiness and attempt once more. They return
IO_WOULD_BLOCK or IO_INTERRUPTED to have the generic layer retry with a
recomputed deadline, IO_TIMED_OUT when their wait expired.
*/
import lib.lib
import lib.memory
import lib.io
import lib.net
import lib.poll
import lib.io_wait
import lib.time
import lib.metrics


type transport_io_fn = fn(void*, char*, int, int, io_result*) -> int
type transport_close_fn = fn(void*, io_result*) -> int
type transport_peer_address_fn = fn(void*, net_peer_address*, io_result*) -> int
type transport_peer_credentials_fn = fn(void*, net_peer_credentials*, io_result*) -> int
type transport_shutdown_fn = fn(void*, int, io_result*) -> int


struct transport:
	void* context                    # adapter state, owned by the transport
	transport_io_fn* read_fn
	transport_io_fn* write_fn
	transport_close_fn* close_fn
	transport_peer_address_fn* peer_address_fn
	transport_peer_credentials_fn* peer_credentials_fn
	transport_shutdown_fn* shutdown_fn
	int shutdown_mask               # completed directions: read 1, write 2
	char* peer                       # owned description of the peer
	int authenticated                # 1 only when the adapter verified the peer
	int closed
	int has_deadline
	int deadline_ms                  # absolute time_monotonic_ms
	metrics* stats                   # optional: latency histogram + counters


const int TRANSPORT_EBADF = 9


# Wraps adapter functions. peer is copied; context is freed by
# transport_free after close.
transport* transport_new(void* context, transport_io_fn* rd, transport_io_fn* wr, transport_close_fn* cl, char* peer):
	transport* t = cast(transport*, malloc(sizeof(transport)))
	t.context = context
	t.read_fn = rd
	t.write_fn = wr
	t.close_fn = cl
	t.peer_address_fn = 0
	t.peer_credentials_fn = 0
	t.shutdown_fn = 0
	t.shutdown_mask = 0
	if (cast(int, peer) == 0): peer = c"unknown"
	t.peer = strclone(peer)
	t.authenticated = 0
	t.closed = 0
	t.has_deadline = 0
	t.deadline_ms = 0
	t.stats = 0
	return t


char* transport_peer(transport* t):
	return t.peer


int transport_authenticated(transport* t):
	return t.authenticated


# IO_OK only when the adapter authenticated the peer; plain sockets get
# IO_UNSUPPORTED, so a protocol that requires an authenticated peer fails
# closed instead of trusting an address.
int transport_require_authenticated(transport* t, io_result* r):
	if (t.authenticated == 1): return io_result_set(r, 0, IO_OK, 0)
	return io_result_set(r, 0, IO_UNSUPPORTED, 0)


# Records the latency (microseconds) of every read_some/write_all into
# m's histogram (metrics_enable_latency) and each failure other than
# EOF as an event (metrics_enable_events). 0 detaches.
void transport_set_metrics(transport* t, metrics* m):
	t.stats = m


# Absolute deadline in time_monotonic_ms units.
void transport_set_deadline(transport* t, int deadline_ms):
	t.has_deadline = 1
	t.deadline_ms = deadline_ms


# Deadline timeout_ms from now; a negative timeout clears the deadline.
void transport_set_timeout(transport* t, int timeout_ms):
	if (timeout_ms < 0):
		t.has_deadline = 0
		return
	transport_set_deadline(t, time_monotonic_ms() + timeout_ms)


# Milliseconds left before the deadline: -1 without one, 0 once passed.
int transport_remaining_ms(transport* t):
	if (t.has_deadline == 0): return -1
	int left = t.deadline_ms - time_monotonic_ms()
	if (left < 0): return 0
	return left


int transport_closed_result(io_result* r):
	return io_result_set(r, 0, IO_IO_ERROR, TRANSPORT_EBADF)


void transport_record(transport* t, int start_us, int status, int native_error):
	if (cast(int, t.stats) == 0): return
	metrics_observe_since(t.stats, start_us)
	if ((status != IO_OK) && (status != IO_EOF)):
		metrics_event(t.stats, status, native_error, t.peer)


# One adapter call, retried on IO_WOULD_BLOCK / IO_INTERRUPTED with the
# remaining time recomputed each round.
int transport_op(transport* t, int writing, char* buf, int len, io_result* r):
	while (1):
		int interrupted = io_check()
		if (interrupted < 0): return io_result_from_syscall(r, interrupted)
		int left = transport_remaining_ms(t)
		if (left == 0): return io_result_set(r, 0, IO_TIMED_OUT, 0)
		int status = 0
		if (writing): status = t.write_fn(t.context, buf, len, left, r)
		else: status = t.read_fn(t.context, buf, len, left, r)
		if (r.transferred > 0): return status
		if ((status != IO_WOULD_BLOCK) && (status != IO_INTERRUPTED)): return status
	return IO_IO_ERROR


# Reads 1..len bytes. See the file header for the statuses.
int transport_read_some(transport* t, char* buf, int len, io_result* r):
	if (t.closed): return transport_closed_result(r)
	if (len <= 0): return io_result_set(r, 0, IO_OK, 0)
	int start = 0
	if (cast(int, t.stats) != 0): start = metrics_now_us()
	int status = transport_op(t, 0, buf, len, r)
	transport_record(t, start, status, r.native_error)
	return status


# Writes all len bytes, or stops at the first failure with the confirmed
# prefix in r.transferred. Zero progress without an error is IO_IO_ERROR.
int transport_write_all(transport* t, char* buf, int len, io_result* r):
	if (t.closed): return transport_closed_result(r)
	int start = 0
	if (cast(int, t.stats) != 0): start = metrics_now_us()
	int total = 0
	int status = IO_OK
	io_result step
	step.native_error = 0
	while ((total < len) && (status == IO_OK)):
		status = transport_op(t, 1, buf + total, len - total, &step)
		if (step.transferred > 0): total = total + step.transferred
		if ((status == IO_OK) && (step.transferred <= 0)): status = IO_IO_ERROR
	int native_error = 0
	if (status != IO_OK): native_error = step.native_error
	io_result_set(r, total, status, native_error)
	transport_record(t, start, status, native_error)
	return status


# Reads exactly len bytes; IO_EOF with transferred < len when the peer
# finished early (a short record is never mistaken for a full one).
int transport_read_exact(transport* t, char* buf, int len, io_result* r):
	int total = 0
	io_result step
	while (total < len):
		int status = transport_read_some(t, buf + total, len - total, &step)
		if (step.transferred > 0): total = total + step.transferred
		if (status != IO_OK): return io_result_set(r, total, status, step.native_error)
		if (step.transferred <= 0): return io_result_set(r, total, IO_IO_ERROR, 0)
	return io_result_set(r, total, IO_OK, 0)


# Closes the underlying connection once and reports the result; later
# calls are IO_OK no-ops. The descriptor (this struct) stays valid until
# transport_free.
int transport_close(transport* t, io_result* r):
	if (t.closed): return io_result_set(r, 0, IO_OK, 0)
	t.closed = 1
	return t.close_fn(t.context, r)


# Closes if still open (ignoring that result), then frees the adapter
# context and the descriptor.
void transport_free(transport* t):
	if (cast(int, t) == 0): return
	io_result r
	transport_close(t, &r)
	free(cast(char*, t.context))
	free(t.peer)
	free(cast(char*, t))


/* Socket adapter (TCP and Unix stream sockets, Linux; Darwin flags noted). */

struct transport_socket:
	int fd
	int owns_fd    # close(2) the fd on transport_close


# MSG_DONTWAIT: 0x40 on Linux, 0x80 on Darwin (the only target whose
# socket ABI has no MSG_NOSIGNAL).
int transport_msg_dontwait():
	if (msg_nosignal() == 0): return 128
	return 64


# Waits up to timeout_ms for events on fd: IO_WOULD_BLOCK when ready
# (the caller attempts again), IO_TIMED_OUT, or the wait's error.
int transport_socket_wait(int fd, int events, int timeout_ms, io_result* r):
	int ready = io_poll(fd, events, timeout_ms)
	if (ready == 0): return io_result_set(r, 0, IO_TIMED_OUT, 0)
	if (ready < 0): return net_wait_result_from_syscall(r, ready)
	return io_result_set(r, 0, IO_WOULD_BLOCK, 0)


int transport_socket_read(void* context, char* buf, int len, int timeout_ms, io_result* r):
	transport_socket* s = cast(transport_socket*, context)
	int n = socket_recv(s.fd, buf, len, transport_msg_dontwait())
	if (n == (0 - net_eagain())):
		int waited = transport_socket_wait(s.fd, poll_in, timeout_ms, r)
		if (waited != IO_WOULD_BLOCK): return waited
		n = socket_recv(s.fd, buf, len, transport_msg_dontwait())
	if (n == 0): return io_result_set(r, 0, IO_EOF, 0)
	if (n == (0 - net_eagain())): return io_result_set(r, 0, IO_WOULD_BLOCK, net_eagain())
	return net_result_from_syscall(r, n)


int transport_socket_write(void* context, char* buf, int len, int timeout_ms, io_result* r):
	transport_socket* s = cast(transport_socket*, context)
	int flags = transport_msg_dontwait() | msg_nosignal()
	int n = socket_send(s.fd, buf, len, flags)
	if (n == (0 - net_eagain())):
		int waited = transport_socket_wait(s.fd, poll_out, timeout_ms, r)
		if (waited != IO_WOULD_BLOCK): return waited
		n = socket_send(s.fd, buf, len, flags)
	if (n == (0 - net_eagain())): return io_result_set(r, 0, IO_WOULD_BLOCK, net_eagain())
	return net_result_from_syscall(r, n)


int transport_socket_close(void* context, io_result* r):
	transport_socket* s = cast(transport_socket*, context)
	if (s.owns_fd == 0): return io_result_set(r, 0, IO_OK, 0)
	return net_result_from_syscall(r, close(s.fd))


int transport_socket_peer_address(void* context, net_peer_address* out, io_result* r):
	transport_socket* s = cast(transport_socket*, context)
	return socket_peer_address_checked(s.fd, out, r)


int transport_socket_peer_credentials(void* context, net_peer_credentials* out, io_result* r):
	transport_socket* s = cast(transport_socket*, context)
	return socket_peer_credentials_checked(s.fd, out, r)


int transport_socket_shutdown(void* context, int direction, io_result* r):
	transport_socket* s = cast(transport_socket*, context)
	return socket_shutdown_checked(s.fd, direction, r)


# Wraps a connected stream socket. owns_fd: transport_close closes it.
# peer describes the remote end (copied; 0 = "unknown").
transport* transport_from_socket(int fd, char* peer, int owns_fd):
	socket_set_nosigpipe(fd)
	transport_socket* s = cast(transport_socket*, malloc(sizeof(transport_socket)))
	s.fd = fd
	s.owns_fd = owns_fd
	transport* t = transport_new(cast(void*, s), transport_socket_read, transport_socket_write, transport_socket_close, peer)
	t.peer_address_fn = transport_socket_peer_address
	t.peer_credentials_fn = transport_socket_peer_credentials
	t.shutdown_fn = transport_socket_shutdown
	return t


# The socket under a socket transport (for setsockopt and the like; do
# not close it behind the transport's back).
int transport_socket_fd(transport* t):
	transport_socket* s = cast(transport_socket*, t.context)
	return s.fd


# "tcp:a.b.c.d:port" from a host-order IPv4 address and port.
char* transport_format_tcp_peer(int ip, int port):
	char* out = cast(char*, malloc(40))
	strcpy(out, c"tcp:")
	int shift = 24
	while (shift >= 0):
		char* part = itoa((ip >> shift) & 255)
		strappend(out, part)
		free(part)
		if (shift > 0): strappend(out, c".")
		shift = shift - 8
	strappend(out, c":")
	char* port_text = itoa(port & 65535)
	strappend(out, port_text)
	free(port_text)
	return out


# The same from a kernel-filled sockaddr_in (network byte order).
char* transport_format_sockaddr_peer(sockaddr_in* addr):
	char* raw = cast(char*, addr)
	int port = ((raw[2] & 255) << 8) | (raw[3] & 255)
	int ip = ((raw[4] & 255) << 24) | ((raw[5] & 255) << 16) | ((raw[6] & 255) << 8) | (raw[7] & 255)
	return transport_format_tcp_peer(ip, port)


transport* transport_from_socket_owned_peer(int fd, char* peer):
	transport* t = transport_from_socket(fd, peer, 1)
	free(peer)
	return t


# TCP connect to a host-order IPv4 address within timeout_ms (-1: no
# limit). 0 on failure, preserving the checked connect status and errno.
transport* transport_tcp_connect(int ip, int port, int timeout_ms, io_result* r):
	int fd = net_connect_timeout_checked(ip, port, timeout_ms, r)
	if (fd < 0): return 0
	return transport_from_socket_owned_peer(fd, transport_format_tcp_peer(ip, port))


# Accepts one connection on a listening TCP socket, waiting up to
# timeout_ms (-1: no limit). 0 on failure with r set.
transport* transport_tcp_accept(int listen_fd, int timeout_ms, io_result* r):
	if (timeout_ms >= 0):
		int ready = io_poll(listen_fd, poll_in, timeout_ms)
		if (ready == 0):
			io_result_set(r, 0, IO_TIMED_OUT, 0)
			return 0
		if (ready < 0):
			net_wait_result_from_syscall(r, ready)
			return 0
	sockaddr_in addr
	int fd = socket_accept_connection_from(listen_fd, &addr)
	if (fd < 0):
		net_result_from_syscall(r, fd)
		return 0
	io_result_set(r, 0, IO_OK, 0)
	return transport_from_socket_owned_peer(fd, transport_format_sockaddr_peer(&addr))


char* transport_format_unix_peer(char* path):
	return strjoin(c"unix:", path)


# Connects to a Unix stream socket at path. 0 on failure with r set (the
# errno is preserved: ENOENT, ECONNREFUSED, ...).
transport* transport_unix_connect(char* path, io_result* r):
	int fd = socket_connect_unix_path(path)
	if (fd < 0):
		net_result_from_syscall(r, fd)
		return 0
	io_result_set(r, 0, IO_OK, 0)
	return transport_from_socket_owned_peer(fd, transport_format_unix_peer(path))


# Accepts one connection on a listening Unix socket bound at path (used
# only for the peer description: Unix clients are normally unnamed).
transport* transport_unix_accept(int listen_fd, char* path, int timeout_ms, io_result* r):
	if (timeout_ms >= 0):
		int ready = io_poll(listen_fd, poll_in, timeout_ms)
		if (ready == 0):
			io_result_set(r, 0, IO_TIMED_OUT, 0)
			return 0
		if (ready < 0):
			net_wait_result_from_syscall(r, ready)
			return 0
	int fd = socket_accept_connection(listen_fd)
	if (fd < 0):
		net_result_from_syscall(r, fd)
		return 0
	io_result_set(r, 0, IO_OK, 0)
	return transport_from_socket_owned_peer(fd, strjoin(c"unix-client@", path))


# Metadata and shutdown never wait. They honor cancellation/deadlines
# before touching the adapter; close remains unconditional cleanup.
int transport_control_ready(transport* t, io_result* r):
	if (t.closed): return transport_closed_result(r)
	int interrupted = io_check()
	if (interrupted < 0): return io_result_from_syscall(r, interrupted)
	if (transport_remaining_ms(t) == 0): return io_result_set(r, 0, IO_TIMED_OUT, 0)
	return IO_OK


# These queries borrow the transport and fill caller-owned records.
# They do not change peer (a display label) or authenticated (TLS proof).
int transport_peer_address(transport* t, net_peer_address* out, io_result* r):
	net_peer_address_clear(out)
	int status = transport_control_ready(t, r)
	if (status != IO_OK): return status
	if (cast(int, t.peer_address_fn) == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	return t.peer_address_fn(t.context, out, r)


int transport_peer_credentials(transport* t, net_peer_credentials* out, io_result* r):
	net_peer_credentials_clear(out)
	int status = transport_control_ready(t, r)
	if (status != IO_OK): return status
	if (cast(int, t.peer_credentials_fn) == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	return t.peer_credentials_fn(t.context, out, r)


# Shutdown does not release the fd, even for a borrowed socket. Success
# is remembered so repeating completed directions is an IO_OK no-op.
# Deadline/cancellation/closed checks still apply to repeated calls.
# Remaining-direction reads/writes retain normal kernel behavior.
int transport_shutdown(transport* t, int direction, io_result* r):
	int status = transport_control_ready(t, r)
	if (status != IO_OK): return status
	if (cast(int, t.shutdown_fn) == 0): return io_result_set(r, 0, IO_UNSUPPORTED, 0)
	int mask = 0
	if (direction == NET_SHUT_READ): mask = 1
	else if (direction == NET_SHUT_WRITE): mask = 2
	else if (direction == NET_SHUT_BOTH): mask = 3
	if ((mask != 0) && ((t.shutdown_mask & mask) == mask)): return io_result_set(r, 0, IO_OK, 0)
	status = t.shutdown_fn(t.context, direction, r)
	if (status == IO_OK): t.shutdown_mask = t.shutdown_mask | mask
	return status
