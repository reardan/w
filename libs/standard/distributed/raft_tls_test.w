# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_tls


char* rtt_cert():
	return c"libs/standard/distributed/raft_tls_fixtures/server.pem"


char* rtt_key():
	return c"libs/standard/distributed/raft_tls_fixtures/server_key.pem"


raft* rtt_node(int self_id, int peer_id):
	list[int] peers = new list[int]
	peers.push(peer_id)
	raft* r = raft_new(self_id, peers, 100, 200, 30, 42)
	peers.free()
	return r


raft_tls_config* rtt_config(raft* r):
	return raft_tls_config_new(r, c"01234567890123456789012345678901", c"libs/standard/distributed/raft_tls_fixtures/ca.pem", rtt_cert(), rtt_key(), 4000, 2)


char* rtt_secret():
	return c"test-only-pairwise-secret-32bytes!"


struct rtt_pair:
	raft_tls_config* a
	raft_tls_config* b
	int client_fd
	int server_fd
	int mode
	int sent
	int received


generator int rtt_client(rtt_pair* pair):
	raft_tls_session* s = raft_tls_connect(pair.a, pair.client_fd, 2)
	if ((pair.mode >= 1 && pair.mode <= 5) || pair.mode == 10 || pair.mode == 11 || pair.mode == 13):
		assert1(s == 0)
		task_finish(0)
		return
	asserts(pair.a.last_error, s != 0)
	u64* term = u64_new_int(7)
	raft_msg* m = raft_msg_new(raft_msg_append, 1, 2, term)
	u64_free(term)
	if (pair.mode == 6):
		# A compromised authorized client can lie inside the wire payload;
		# bypass the send guard to prove the receiver binds the identity.
		m.from = 99
		assert_equal(0, raft_tls_send(s, m))
		int len = raft_wire_size(m)
		char* frame = cast(char*, malloc(len + 4))
		store_le32(frame, len)
		raft_wire_encode(m, frame + 4)
		assert_equal(len + 4, tls_write(s.tls, frame, len + 4))
		free(frame)
	else if (pair.mode == 7):
		char* header = cast(char*, malloc(4))
		store_le32(header, (1 << 20) + 1)
		assert_equal(4, tls_write(s.tls, header, 4))
		free(header)
	else:
		assert_equal(1, raft_tls_send(s, m))
		pair.sent = 1
		if (pair.mode == 8):
			# Rotation invalidates the already authenticated connection.
			assert_equal(1, raft_tls_set_peer(pair.a, 2, c"test.w.example", c"rotated-pairwise-secret-32bytes!!", rtt_secret()))
			assert_equal(0, raft_tls_send(s, m))
		if (pair.mode == 12):
			pair.a.node.config_version = pair.a.node.config_version + 2
			assert_equal(0, raft_tls_send(s, m))
		if (pair.mode == 9):
			# Even a valid provisioned credential cannot outlive membership.
			pair.a.node.peers.clear()
			assert_equal(0, raft_tls_send(s, m))
	raft_msg_free(m)
	raft_tls_close(s)
	task_finish(0)


generator int rtt_server(rtt_pair* pair):
	raft_tls_session* s = raft_tls_accept(pair.b, pair.server_fd)
	if ((pair.mode >= 1 && pair.mode <= 5) || pair.mode == 10 || pair.mode == 11):
		assert1(s == 0)
		task_finish(0)
		return
	if (pair.mode == 13):
		if (s != 0):
			assert1(raft_tls_recv(s) == 0)
			raft_tls_close(s)
		task_finish(0)
		return
	assert1(s != 0)
	raft_msg* m = raft_tls_recv(s)
	if (pair.mode == 6 || pair.mode == 7):
		assert1(m == 0)
		assert_equal(1, s.tls.broken)
	else:
		assert1(m != 0)
		assert_equal(1, m.from)
		assert_equal(2, m.to)
		assert_equal(7, raft_u64_as_int(m.term))
		pair.received = 1
		raft_msg_free(m)
	raft_tls_close(s)
	task_finish(0)


generator int rtt_rotate_during_handshake(rtt_pair* pair):
	assert_equal(1, raft_tls_set_peer(pair.a, 2, c"test.w.example", rtt_secret(), 0))
	task_finish(0)


void rtt_exchange(raft_tls_config* a, raft_tls_config* b, int mode):
	int* fds = cast(int*, malloc(2 * __word_size__))
	# Bind an ephemeral TCP port; exercise actual remote transport sockets.
	int listener = socket_tcp_ipv4()
	assert1(listener >= 0)
	int ip = ip4_from_string(c"127.0.0.1")
	assert_equal(0, socket_bind_ipv4(listener, ip, 0))
	assert_equal(0, socket_listen(listener, 4))
	sockaddr_in address
	assert_equal(0, socket_getsockname_ipv4(listener, &address))
	fds[0] = net_connect_timeout(ip, net_htons(address.port & 65535), 1000)
	assert1(fds[0] >= 0)
	fds[1] = socket_accept_connection(listener)
	assert1(fds[1] >= 0)
	close(listener)
	rtt_pair pair
	pair.a = a
	pair.b = b
	pair.client_fd = fds[0]
	pair.server_fd = fds[1]
	pair.mode = mode
	pair.sent = 0
	pair.received = 0
	task_scheduler* scheduler = task_scheduler_new()
	task_spawn(scheduler, rtt_server(&pair))
	task_spawn(scheduler, rtt_client(&pair))
	if (mode == 13): task_spawn(scheduler, rtt_rotate_during_handshake(&pair))
	assert_equal(0, task_run(scheduler))
	if (mode == 0 || mode == 8 || mode == 9 || mode == 12):
		assert_equal(1, pair.sent)
		assert_equal(1, pair.received)
	assert_equal(0, a.active_sessions)
	assert_equal(0, b.active_sessions)
	task_scheduler_free(scheduler)
	free(fds)


void rtt_scenario(int mode):
	raft* a = rtt_node(1, 2)
	raft* b = rtt_node(2, 1)
	raft_tls_config* ca = rtt_config(a)
	raft_tls_config* cb = rtt_config(b)
	assert_equal(1, raft_tls_set_peer(ca, 2, c"test.w.example", rtt_secret(), 0))
	assert_equal(1, raft_tls_set_peer(cb, 1, c"test.w.example", rtt_secret(), 0))
	if (mode == 1): raft_tls_set_peer(cb, 1, c"test.w.example", c"wrong-test-only-secret-32bytes!!!", 0)
	if (mode == 2): raft_tls_set_peer(ca, 2, c"wrong.w.example", rtt_secret(), 0)
	if (mode == 3): b.peers.clear()
	if (mode == 4): cb.cluster[0] = 88
	if (mode == 5):
		free(ca.trust_path)
		ca.trust_path = rts_copy(c"/nonexistent/raft-test-ca.pem", strlen(c"/nonexistent/raft-test-ca.pem") + 1)
	if (mode == 10):
		free(cb.server.cert_chain_path)
		char* path = c"libs/standard/distributed/raft_tls_fixtures/expired.pem"
		cb.server.cert_chain_path = rts_copy(path, strlen(path) + 1)
	if (mode == 11): b.self_id = 3
	rtt_exchange(ca, cb, mode)
	# Successful peers reconnect using a fresh TLS handshake and credentials.
	if (mode == 0): rtt_exchange(ca, cb, mode)
	if (mode == 8):
		# Overlap: receiver accepts old sender credential while switching.
		raft_tls_set_peer(cb, 1, c"test.w.example", c"rotated-pairwise-secret-32bytes!!", rtt_secret())
		rtt_exchange(ca, cb, 0)
		raft_tls_set_peer(ca, 2, c"test.w.example", rtt_secret(), 0)
		rtt_exchange(ca, cb, 0)
		# Finish rotation: old credential is refused on a fresh connection.
		raft_tls_set_peer(cb, 1, c"test.w.example", c"rotated-pairwise-secret-32bytes!!", 0)
		rtt_exchange(ca, cb, 1)
	raft_tls_config_free(ca)
	raft_tls_config_free(cb)
	raft_free(a)
	raft_free(b)


void test_authenticated_exchange_and_reconnect(): rtt_scenario(0)
void test_wrong_credential_rejected(): rtt_scenario(1)
void test_wrong_hostname_rejected(): rtt_scenario(2)
void test_valid_credential_unknown_member_rejected(): rtt_scenario(3)
void test_wrong_cluster_rejected(): rtt_scenario(4)
void test_untrusted_server_rejected(): rtt_scenario(5)
void test_forged_message_source_rejected(): rtt_scenario(6)
void test_oversize_frame_rejected(): rtt_scenario(7)
void test_credential_rotation_and_reconnect(): rtt_scenario(8)
void test_removed_member_revokes_session(): rtt_scenario(9)
void test_expired_server_certificate_rejected(): rtt_scenario(10)
void test_wrong_destination_rejected(): rtt_scenario(11)
void test_remove_readd_never_revives_session(): rtt_scenario(12)
void test_rotation_during_handshake(): rtt_scenario(13)


generator int rtt_stalled(raft_tls_config* cfg, int fd):
	assert1(raft_tls_accept(cfg, fd) == 0)
	task_finish(0)


void test_deadline_and_admission_bounds():
	raft* node = rtt_node(2, 1)
	raft_tls_config* cfg = rtt_config(node)
	cfg.timeout_ms = 10
	cfg.max_sessions = 1
	int* first = cast(int*, malloc(2 * __word_size__))
	int* second = cast(int*, malloc(2 * __word_size__))
	assert1(socket_pair(first) >= 0)
	assert1(socket_pair(second) >= 0)
	task_scheduler* scheduler = task_scheduler_new()
	task_spawn(scheduler, rtt_stalled(cfg, first[0]))
	task_spawn(scheduler, rtt_stalled(cfg, second[0]))
	assert_equal(0, task_run(scheduler))
	assert_equal(0, cfg.active_sessions)
	close(first[1])
	close(second[1])
	free(first)
	free(second)
	task_scheduler_free(scheduler)
	raft_tls_config_free(cfg)
	raft_free(node)


void test_absolute_deadline_on_ready_socket():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert1(socket_pair(fds) >= 0)
	assert_equal(4, socket_send(fds[0], c"data", 4, msg_nosignal()))
	tls_conn* c = tls_conn_new(fds[1], 0, 0)
	c.has_io_deadline = 1
	c.io_deadline_ms = time_monotonic_ms() - 1
	char* buf = cast(char*, malloc(4))
	assert_equal(0, tls_io_recv_full(c, buf, 4))
	assert_equal(0, tls_io_send_all(c, c"data", 4))
	# The readable bytes were not consumed after the deadline.
	assert_equal(4, socket_recv(fds[1], buf, 4, 0))
	free(buf)
	tls_conn_free(c)
	close(fds[0])
	close(fds[1])
	free(fds)
