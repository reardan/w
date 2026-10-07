/*
Authenticated remote Raft sessions over the existing TLS 1.3 stack.
See docs/projects/raft_authenticated_transport.md for provisioning and ownership.
Server certificates authenticate the destination; a pairwise 32-byte secret
inside TLS authenticates the source. Never accepts plaintext or skip-verify.
Calls run in lib/task workers, with a whole-operation deadline. Every socket
is nonblocking. The caller owns scheduling and reconnect/retransmission.
*/
import libs.standard.distributed.raft_wire
import libs.standard.net.tls
import lib.task
import lib.bytes


struct raft_tls_peer:
	int id
	char* hostname
	char* current
	char* previous
	int generation


struct raft_tls_config:
	raft* node
	char* cluster
	char* trust_path
	tls_server_config* server
	list[raft_tls_peer*] peers
	int timeout_ms
	int max_sessions
	int active_sessions
	char* last_error


struct raft_tls_session:
	raft_tls_config* config
	raft_tls_peer* peer
	int generation
	int config_version
	tls_conn* tls
	tls_config* client
	int busy


int rts_member(raft_tls_config* cfg, int id):
	for i in range(raft_peer_count(cfg.node)):
		if (raft_peer_at(cfg.node, i) == id): return 1
	return 0


raft_tls_peer* rts_peer(raft_tls_config* cfg, int id):
	for i in range(cfg.peers.length):
		raft_tls_peer* p = cfg.peers[i]
		if (p.id == id): return p
	return 0


char* rts_copy(char* data, int len):
	char* out = malloc(len)
	mem_copy(out, data, len)
	return out


# cluster is exactly 32 public namespace bytes. All strings/bytes are copied.
# Config must outlive its sessions. Use one scheduler/thread per config.
raft_tls_config* raft_tls_config_new(raft* node, char* cluster, char* trust_path, char* cert_path, char* key_path, int timeout_ms, int max_sessions):
	if (node == 0 || cluster == 0 || trust_path == 0 || cert_path == 0 || key_path == 0): return 0
	if (timeout_ms <= 0 || timeout_ms > 60000 || max_sessions <= 0 || max_sessions > 64): return 0
	raft_tls_config* cfg = new raft_tls_config()
	cfg.node = node
	cfg.cluster = rts_copy(cluster, 32)
	cfg.trust_path = rts_copy(trust_path, strlen(trust_path) + 1)
	cfg.server = tls_server_config_new()
	cfg.server.cert_chain_path = rts_copy(cert_path, strlen(cert_path) + 1)
	cfg.server.key_path = rts_copy(key_path, strlen(key_path) + 1)
	tls_server_config_set_alpn(cfg.server, c"w-raft/1", 1)
	cfg.peers = new list[raft_tls_peer*]
	cfg.timeout_ms = timeout_ms
	cfg.max_sessions = max_sessions
	cfg.active_sessions = 0
	cfg.last_error = 0
	return cfg


# Configure a pairwise secret shared only by this node and id. previous may
# be 0, or the old 32-byte secret during rotation. Reconfiguration revokes
# existing sessions at their next operation. Live membership is still required.
int raft_tls_set_peer(raft_tls_config* cfg, int id, char* hostname, char* current, char* previous):
	if (id < 0 || id == cfg.node.self_id || hostname == 0 || current == 0): return 0
	if (strlen(hostname) == 0 || strlen(hostname) > 253): return 0
	raft_tls_peer* p = rts_peer(cfg, id)
	if (p == 0):
		if (cfg.peers.length >= 64): return 0
		p = new raft_tls_peer(id, 0, 0, 0, 0)
		cfg.peers.push(p)
	char* next_name = rts_copy(hostname, strlen(hostname) + 1)
	char* next = rts_copy(current, 32)
	char* old = 0
	if (previous != 0): old = rts_copy(previous, 32)
	if (p.current != 0):
		tls_wipe(p.current, 32)
		free(p.current)
	if (p.previous != 0):
		tls_wipe(p.previous, 32)
		free(p.previous)
	if (p.hostname != 0): free(p.hostname)
	p.hostname = next_name
	p.current = next
	p.previous = old
	p.generation = p.generation + 1
	return 1


void raft_tls_config_free(raft_tls_config* cfg):
	assert1(cfg.active_sessions == 0)
	for i in range(cfg.peers.length):
		raft_tls_peer* p = cfg.peers[i]
		tls_wipe(p.current, 32)
		free(p.current)
		if (p.previous != 0):
			tls_wipe(p.previous, 32)
			free(p.previous)
		free(p.hostname)
		free(p)
	list_free[raft_tls_peer*](cfg.peers)
	free(cfg.server.cert_chain_path)
	free(cfg.server.key_path)
	tls_server_config_free(cfg.server)
	free(cfg.cluster)
	free(cfg.trust_path)
	free(cfg)


# Immediate shutdown: no blocking close_notify on a revoked/broken session.
void raft_tls_close(raft_tls_session* s):
	if (s == 0): return
	assert1(s.busy == 0)
	close(s.tls.fd)
	tls_conn_free(s.tls)
	if (s.client != 0): tls_config_free(s.client)
	s.config.active_sessions = s.config.active_sessions - 1
	free(s)


int rts_equal(char* a, char* b, int len):
	int diff = 0
	for i in range(len): diff = diff | ((a[i] & 255) ^ (b[i] & 255))
	return diff == 0


int rts_read_full(tls_conn* c, char* out, int len):
	int got = 0
	while (got < len):
		if (task_deadline_remaining() == 0): return 0
		int n = tls_read(c, out + got, len - got)
		if (n <= 0): return 0
		got = got + n
	return 1


# Call before TLS allocation, counting in-flight handshakes in the cap.
int rts_admit(raft_tls_config* cfg, int fd):
	if (io_wait_available() == 0 || cfg.active_sessions >= cfg.max_sessions): return 0
	if (socket_set_nonblocking(fd) < 0): return 0
	socket_set_nosigpipe(fd)
	cfg.active_sessions = cfg.active_sessions + 1
	return 1


# Takes ownership of an already connected socket on every path. peer_id
# selects BOTH the expected server hostname and the pairwise credential.
raft_tls_session* raft_tls_connect(raft_tls_config* cfg, int fd, int peer_id):
	raft_tls_peer* p = rts_peer(cfg, peer_id)
	if (p == 0 || rts_member(cfg, peer_id) == 0):
		close(fd)
		return 0
	if (rts_admit(cfg, fd) == 0):
		close(fd)
		return 0
	int generation = p.generation
	int config_version = cfg.node.config_version
	char* hostname = rts_copy(p.hostname, strlen(p.hostname) + 1)
	task_deadline_scope scope
	task_deadline_enter(&scope, cfg.timeout_ms)
	tls_config* client = tls_config_new()
	client.trust_store_path = cfg.trust_path
	tls_config_set_alpn(client, c"w-raft/1")
	tls_conn* c = tls_conn_new(fd, 0, client)
	c.io_timeout_ms = cfg.timeout_ms
	c.has_io_deadline = 1
	c.io_deadline_ms = task_current().deadline_ms
	if (tls_do_handshake(c, hostname) == 0):
		tls_conn_free(c)
		c = 0
	free(hostname)
	int ok = 0
	if (c != 0):
		char* alpn = tls_alpn_selected(c)
		if (alpn != 0 && strcmp(alpn, c"w-raft/1") == 0):
			char* auth = malloc(76)
			store_le32(auth, 0x31545257)
			mem_copy(auth + 4, cfg.cluster, 32)
			store_le32(auth + 36, cfg.node.self_id)
			store_le32(auth + 40, peer_id)
			mem_copy(auth + 44, p.current, 32)
			if (tls_write(c, auth, 76) == 76):
				ok = rts_read_full(c, auth, 4)
				if (ok): ok = load_le32(auth) == 0x31545257
			tls_wipe(auth, 76)
			free(auth)
	if (generation != p.generation || config_version != cfg.node.config_version || rts_member(cfg, peer_id) == 0): ok = 0
	task_deadline_exit(&scope)
	if (ok): return new raft_tls_session(cfg, p, generation, config_version, c, client, 0)
	cfg.last_error = tls_last_error(client)
	if (cfg.last_error == 0): cfg.last_error = c"Raft peer authentication failed"
	if (c != 0): tls_conn_free(c)
	tls_config_free(client)
	close(fd)
	cfg.active_sessions = cfg.active_sessions - 1
	return 0


# Takes ownership of an accepted socket, rejects unauthorized peers before
# decoding ANY raft_wire payload. Admission happens before the TLS handshake.
raft_tls_session* raft_tls_accept(raft_tls_config* cfg, int fd):
	if (rts_admit(cfg, fd) == 0):
		close(fd)
		return 0
	task_deadline_scope scope
	task_deadline_enter(&scope, cfg.timeout_ms)
	tls_conn* c = tls_conn_new(fd, 0, 0)
	c.is_server = 1
	c.scfg = cfg.server
	c.io_timeout_ms = cfg.timeout_ms
	c.has_io_deadline = 1
	c.io_deadline_ms = task_current().deadline_ms
	raft_tls_peer* p = 0
	int generation = 0
	int config_version = cfg.node.config_version
	int ok = tls_server_do_handshake(c)
	char* auth = malloc(76)
	if (ok): ok = rts_read_full(c, auth, 76)
	if (ok):
		ok = load_le32(auth) == 0x31545257 && rts_equal(auth + 4, cfg.cluster, 32) && load_le32(auth + 40) == cfg.node.self_id
		int id = load_le32(auth + 36)
		p = rts_peer(cfg, id)
		if (p == 0 || rts_member(cfg, id) == 0): ok = 0
		if (ok):
			int valid = rts_equal(auth + 44, p.current, 32)
			if (p.previous != 0): valid = valid | rts_equal(auth + 44, p.previous, 32)
			ok = valid
			generation = p.generation
		if (ok): ok = tls_write(c, auth, 4) == 4
	tls_wipe(auth, 76)
	free(auth)
	if (ok && (generation != p.generation || config_version != cfg.node.config_version || rts_member(cfg, p.id) == 0)): ok = 0
	task_deadline_exit(&scope)
	if (ok): return new raft_tls_session(cfg, p, generation, config_version, c, 0, 0)
	tls_conn_free(c)
	close(fd)
	cfg.active_sessions = cfg.active_sessions - 1
	return 0


int rts_live(raft_tls_session* s):
	return io_wait_available() && s.tls.broken == 0 && s.generation == s.peer.generation && s.config_version == s.config.node.config_version && rts_member(s.config, s.peer.id)


# No queue: caller retains m. Failed operations poison the session; close
# and reconnect. Raft supplies retries. Each payload is capped at 1 MiB.
int raft_tls_send(raft_tls_session* s, raft_msg* m):
	if (s.busy || rts_live(s) == 0): return 0
	if (m.from != s.config.node.self_id || m.to != s.peer.id): return 0
	int len = raft_wire_size(m)
	if (len < 0 || len > (1 << 20)): return 0
	s.busy = 1
	char* frame = malloc(len + 4)
	store_le32(frame, len)
	raft_wire_encode(m, frame + 4)
	task_deadline_scope scope
	task_deadline_enter(&scope, s.config.timeout_ms)
	s.tls.io_deadline_ms = task_current().deadline_ms
	int ok = tls_write(s.tls, frame, len + 4) == len + 4
	free(frame)
	task_deadline_exit(&scope)
	if (rts_live(s) == 0): ok = 0
	if (ok == 0): s.tls.broken = 1
	s.busy = 0
	return ok


# Returns caller-owned message, or 0 on timeout/EOF/invalid identity/frame.
# Recheck authorization after suspension so membership/rotation can revoke
# a session while an operation is awaiting bytes.
raft_msg* raft_tls_recv(raft_tls_session* s):
	if (s.busy || rts_live(s) == 0): return 0
	s.busy = 1
	task_deadline_scope scope
	task_deadline_enter(&scope, s.config.timeout_ms)
	s.tls.io_deadline_ms = task_current().deadline_ms
	char* header = malloc(4)
	int ok = rts_read_full(s.tls, header, 4)
	int len = 0
	if (ok): len = load_le32(header)
	free(header)
	raft_msg* m = 0
	if (ok && len > 0 && len <= (1 << 20)):
		char* data = malloc(len)
		ok = rts_read_full(s.tls, data, len)
		if (ok && rts_live(s)): m = raft_wire_decode(data, len)
		free(data)
	task_deadline_exit(&scope)
	s.busy = 0
	if (m != 0):
		if (m.from == s.peer.id && m.to == s.config.node.self_id): return m
		raft_msg_free(m)
	s.tls.broken = 1
	return 0
