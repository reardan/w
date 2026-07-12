/*
TCP transport for raft messages (docs/projects/distributed.md): frames
the frozen raft_wire encoding over real loopback sockets between the
nodes of a single-process cluster. No threads and no blocking calls —
every socket is O_NONBLOCK (socket_set_nonblocking, the repo's fcntl
F_SETFL wrapper in lib/net.w) and raft_tcp_pump makes one bounded
progress pass, gated by the lib/poll.w wrapper on the outbound side,
so it can be interleaved with raft ticks in a plain loop.

Wire format per frame: 4-byte little-endian payload length (the same
u32 layout as raft_wire_u32), then exactly that many raft_wire_encode
bytes. Frames longer than rt_max_frame() (1 MiB) are a protocol error:
oversize sends are refused and an oversize or undecodable inbound
frame closes that connection and drops its partial data.

Topology: one raft_tcp endpoint serves one node id. It listens on its
own 127.0.0.1 port and lazily dials a registered peer the first time a
message is sent to it. Inbound and outbound connections are kept
separate — two nodes talking both ways hold two sockets, which removes
any need for an identification handshake: every decoded message
carries m.from.

Delivery semantics (the pre-listen-send contract): raft_tcp_send only
appends the frame to the peer's outbound buffer; the buffer SURVIVES
connection failures. While a peer has buffered bytes and no live
socket, every raft_tcp_pump re-dials it, so a frame sent before the
peer starts listening is still delivered once the peer appears. Bytes
are dropped only when the receiver closes mid-frame or rejects a
malformed frame; raft's own retransmission covers those cases, so the
transport never guarantees more than best-effort per frame.

Ownership: raft_tcp_send does NOT take ownership of the message (the
caller still frees it — the frame is encoded immediately). Messages
returned by raft_tcp_recv are owned by the caller (raft_msg_free);
undelivered inbox messages are freed by raft_tcp_free.
*/
import lib.lib
import lib.memory
import lib.assert
import lib.container
import lib.net
import lib.poll
import libs.standard.distributed.raft_wire


# Largest accepted frame payload: 1 MiB.
int rt_max_frame():
	return 1 << 20


int rt_scratch_size():
	return 4096


int rt_loopback():
	return ip4_from_string(c"127.0.0.1")


# ---- growable byte buffer -----------------------------------------------------

struct rt_buf:
	char* data
	int cap
	int len


rt_buf* rt_buf_new():
	rt_buf* b = new rt_buf()
	b.cap = 256
	b.data = malloc(b.cap)
	b.len = 0
	return b


void rt_buf_free(rt_buf* b):
	free(b.data)
	free(b)


void rt_buf_append(rt_buf* b, char* src, int n):
	if (b.len + n > b.cap):
		int newcap = b.cap
		while (b.len + n > newcap):
			newcap = newcap * 2
		b.data = realloc(b.data, b.len, newcap)
		b.cap = newcap
	int i = 0
	while (i < n):
		b.data[b.len + i] = src[i]
		i = i + 1
	b.len = b.len + n


# Drops the first n bytes, sliding the rest to the front.
void rt_buf_consume(rt_buf* b, int n):
	int i = 0
	while (n + i < b.len):
		b.data[i] = b.data[n + i]
		i = i + 1
	b.len = b.len - n


# ---- connection records --------------------------------------------------------

# A registered peer and its (lazily dialed) outbound connection.
# fd is -1 while disconnected; out holds encoded frames not yet written.
struct rt_peer:
	int id
	int port
	int fd
	rt_buf* out


# One accepted inbound connection; acc accumulates bytes until whole
# frames can be split off.
struct rt_conn:
	int fd
	rt_buf* acc


struct raft_tcp:
	int self_id
	int listen_fd
	list[rt_peer*] peers
	list[rt_conn*] conns
	list[raft_msg*] inbox
	char* scratch


# ---- lifecycle -----------------------------------------------------------------

# Binds and listens on 127.0.0.1:port (SO_REUSEADDR, nonblocking).
# Returns 0 when any socket setup step fails.
raft_tcp* raft_tcp_new(int self_id, int port):
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return 0
	int ok = 1
	if (socket_set_reuseaddr(fd) < 0):
		ok = 0
	if (ok && socket_set_nonblocking(fd) < 0):
		ok = 0
	if (ok && socket_bind_ipv4(fd, rt_loopback(), port) < 0):
		ok = 0
	if (ok && socket_listen(fd, 16) < 0):
		ok = 0
	if (ok == 0):
		close(fd)
		return 0
	raft_tcp* t = new raft_tcp()
	t.self_id = self_id
	t.listen_fd = fd
	t.peers = new list[rt_peer*]
	t.conns = new list[rt_conn*]
	t.inbox = new list[raft_msg*]
	t.scratch = malloc(rt_scratch_size())
	return t


# Closes every socket and frees all buffers and undelivered messages.
void raft_tcp_free(raft_tcp* t):
	close(t.listen_fd)
	int i = 0
	while (i < t.peers.length):
		rt_peer* p = t.peers[i]
		if (p.fd >= 0):
			close(p.fd)
		rt_buf_free(p.out)
		free(p)
		i = i + 1
	i = 0
	while (i < t.conns.length):
		rt_conn* c = t.conns[i]
		close(c.fd)
		rt_buf_free(c.acc)
		free(c)
		i = i + 1
	i = 0
	while (i < t.inbox.length):
		raft_msg_free(t.inbox[i])
		i = i + 1
	list_free[rt_peer*](t.peers)
	list_free[rt_conn*](t.conns)
	list_free[raft_msg*](t.inbox)
	free(t.scratch)
	free(t)


rt_peer* rt_find_peer(raft_tcp* t, int id):
	int i = 0
	while (i < t.peers.length):
		rt_peer* p = t.peers[i]
		if (p.id == id):
			return p
		i = i + 1
	return 0


# Registers (or re-addresses) a peer on 127.0.0.1:port. No connection
# is made until the first send to it.
void raft_tcp_add_peer(raft_tcp* t, int peer_id, int port):
	rt_peer* p = rt_find_peer(t, peer_id)
	if (cast(int, p) != 0):
		p.port = port
		return
	p = new rt_peer()
	p.id = peer_id
	p.port = port
	p.fd = 0 - 1
	p.out = rt_buf_new()
	t.peers.push(p)


# ---- outbound ------------------------------------------------------------------

# Starts a nonblocking connect to p. Leaves p.fd at -1 on immediate
# failure; the next pump retries while p.out has pending bytes.
void rt_peer_dial(rt_peer* p):
	int fd = socket_tcp_ipv4()
	if (fd < 0):
		return
	if (socket_set_nonblocking(fd) < 0):
		close(fd)
		return
	int rc = socket_connect_ipv4(fd, rt_loopback(), p.port)
	# 0 = connected already (possible on loopback); -EINPROGRESS and
	# -EINTR both mean the connect continues asynchronously.
	if (rc < 0 && rc != 0 - net_einprogress() && rc != 0 - 4):
		close(fd)
		return
	p.fd = fd


# Drops the peer's connection but keeps its buffered frames, so the
# next pump re-dials and retries delivery.
void rt_peer_disconnect(rt_peer* p):
	close(p.fd)
	p.fd = 0 - 1


# Writes as much pending data as the socket accepts right now.
void rt_peer_flush(rt_peer* p):
	int r = poll_single(p.fd, poll_out(), 0)
	if (r <= 0):
		# 0: still connecting or kernel buffer full; <0: transient
		# poll failure. Either way retry on a later pump.
		return
	if ((r & (poll_err() | poll_hup() | poll_nval())) != 0):
		rt_peer_disconnect(p)
		return
	int n = socket_send(p.fd, p.out.data, p.out.len, msg_nosignal())
	if (n > 0):
		rt_buf_consume(p.out, n)
		return
	if (n == 0 - net_eagain() || n == 0 - 4):
		return
	rt_peer_disconnect(p)


# Frames and queues m for peer m.to, dialing lazily. Does NOT take
# ownership of m. Returns 1 when queued, 0 for an unknown peer or an
# oversize message.
int raft_tcp_send(raft_tcp* t, raft_msg* m):
	rt_peer* p = rt_find_peer(t, m.to)
	if (cast(int, p) == 0):
		return 0
	int size = raft_wire_size(m)
	if (size > rt_max_frame()):
		return 0
	char* tmp = malloc(size + 4)
	raft_wire_u32(tmp, size)
	raft_wire_encode(m, tmp + 4)
	rt_buf_append(p.out, tmp, size + 4)
	free(tmp)
	if (p.fd < 0):
		rt_peer_dial(p)
	return 1


# ---- inbound -------------------------------------------------------------------

# Accepts every connection currently pending on the listen socket.
void rt_pump_accept(raft_tcp* t):
	while (1):
		int fd = socket_accept_connection(t.listen_fd)
		if (fd < 0):
			return
		if (socket_set_nonblocking(fd) < 0):
			close(fd)
			return
		rt_conn* c = new rt_conn()
		c.fd = fd
		c.acc = rt_buf_new()
		t.conns.push(c)


# Splits complete frames out of c.acc into the inbox. Returns 1 on a
# protocol error (oversize length or undecodable payload).
int rt_conn_extract(raft_tcp* t, rt_conn* c):
	while (c.acc.len >= 4):
		int plen = raft_wire_read_u32(c.acc.data)
		if (plen < 0 || plen > rt_max_frame()):
			return 1
		if (c.acc.len < plen + 4):
			return 0
		raft_msg* m = raft_wire_decode(c.acc.data + 4, plen)
		if (cast(int, m) == 0):
			return 1
		t.inbox.push(m)
		rt_buf_consume(c.acc, plen + 4)
	return 0


# Drains whatever bytes are available and extracts frames. Returns 1
# when the connection should be closed (EOF, error, protocol error).
int rt_conn_read(raft_tcp* t, rt_conn* c):
	while (1):
		int n = socket_recv(c.fd, t.scratch, rt_scratch_size(), 0)
		if (n > 0):
			rt_buf_append(c.acc, t.scratch, n)
		else:
			if (n == 0):
				# EOF: partial data, if any, is dropped.
				return 1
			if (n == 0 - net_eagain() || n == 0 - 4):
				break
			return 1
	return rt_conn_extract(t, c)


void rt_pump_inbound(raft_tcp* t):
	int i = 0
	while (i < t.conns.length):
		rt_conn* c = t.conns[i]
		if (rt_conn_read(t, c)):
			close(c.fd)
			rt_buf_free(c.acc)
			free(c)
			list_remove_at[rt_conn*](t.conns, i)
		else:
			i = i + 1


void rt_pump_outbound(raft_tcp* t):
	int i = 0
	while (i < t.peers.length):
		rt_peer* p = t.peers[i]
		if (p.out.len > 0):
			if (p.fd < 0):
				rt_peer_dial(p)
			if (p.fd >= 0):
				rt_peer_flush(p)
		i = i + 1


# One nonblocking progress pass: accept pending connections, flush (or
# re-dial) outbound buffers, read available bytes, and queue every
# complete decoded frame on the inbox. Never blocks.
void raft_tcp_pump(raft_tcp* t):
	rt_pump_accept(t)
	rt_pump_outbound(t)
	rt_pump_inbound(t)


# ---- delivery ------------------------------------------------------------------

# Pops the next received message (caller frees with raft_msg_free) or
# returns 0 when the inbox is empty.
raft_msg* raft_tcp_recv(raft_tcp* t):
	if (t.inbox.length == 0):
		return 0
	raft_msg* m = t.inbox[0]
	list_remove_at[raft_msg*](t.inbox, 0)
	return m


int raft_tcp_inbox_count(raft_tcp* t):
	return t.inbox.length
