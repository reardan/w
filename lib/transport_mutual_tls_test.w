# wbuild: x64
# Mutual TLS uses offline checked-in public test keys; no external TLS tools.
import lib.testing
import lib.transport_tls
import lib.task


tls_config* mt_client_config():
	tls_config* cfg = tls_config_new()
	cfg.trust_store_path = c"libs/standard/distributed/raft_tls_fixtures/ca.pem"
	cfg.has_now_unix = 1
	cfg.now_unix = 1782864000
	cfg.client_cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/client.pem"
	cfg.client_key_path = c"libs/standard/net/tls_mutual_fixtures/client_key.pem"
	return cfg


tls_server_config* mt_server_config():
	tls_server_config* cfg = tls_server_config_new()
	cfg.cert_chain_path = c"libs/standard/distributed/raft_tls_fixtures/server.pem"
	cfg.key_path = c"libs/standard/distributed/raft_tls_fixtures/server_key.pem"
	cfg.client_trust_store_path = c"libs/standard/net/tls_mutual_fixtures/ca.pem"
	cfg.has_now_unix = 1
	cfg.now_unix = 1782864000
	cfg.client_auth = TLS_CLIENT_AUTH_REQUIRED
	return cfg


# 0 trusted required, 1 missing, 2 untrusted, 3 expired, 4 server-only EKU,
# 5 wrong signing key, 6 optional empty, 7 optional trusted, 8 optional bad,
# 9 client requires request, 10 non-signing KU, 11 unavailable credentials,
# 12 insecure client must remain unauthenticated, 13 no client trust config.
void mt_exchange(int mode):
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	int succeeds = mode == 0 || mode == 6 || mode == 7 || mode == 12
	int pid = fork()
	assert1(pid >= 0)
	if (pid == 0):
		close(fds[0])
		tls_server_config* cfg = mt_server_config()
		if (mode == 2): cfg.client_trust_store_path = c"libs/standard/distributed/raft_tls_fixtures/ca.pem"
		if (mode == 6 || mode == 7 || mode == 8): cfg.client_auth = TLS_CLIENT_AUTH_OPTIONAL
		if (mode == 9): cfg.client_auth = TLS_CLIENT_AUTH_NONE
		if (mode == 13): cfg.client_trust_store_path = 0
		if (mode == 14): cfg.client_trust_store_path = c"libs/standard/net/tls_mutual_fixtures/restricted_ca.pem"
		io_result r
		transport* t = transport_tls_accept(fds[1], c"untrusted-label", cfg, 10000, &r)
		if (succeeds == 0):
			assert1(t == 0)
			assert_equal(IO_IO_ERROR, r.status)
			assert1(tls_server_last_error(cfg) != 0)
			char* buf = cast(char*, malloc(1))
			assert_equal(0 - TRANSPORT_EBADF, socket_recv(fds[1], buf, 1, 0))
			free(buf)
			tls_server_config_free(cfg)
			exit(0)
		tls_server_config_free(cfg)
		assert1(t != 0)
		assert_equal(mode != 6, transport_authenticated(t))
		if (mode != 6):
			assert_equal(IO_OK, transport_require_authenticated(t, &r))
			# Fingerprint must be derived from the verified DER, not the
			# caller's socket label or an unvalidated certificate subject.
			char* pem = file_read_text(c"libs/standard/net/tls_mutual_fixtures/client.pem")
			list[pem_block*] blocks = pem_decode_blocks(pem, strlen(pem), c"CERTIFICATE")
			char* digest = cast(char*, malloc(32))
			whash_oneshot(WHASH_SHA256, blocks[0].data, blocks[0].len, digest)
			char* encoded = hex_encode(digest, 32)
			char* identity = strjoin(c"tls-client-sha256:", encoded)
			assert_strings_equal(identity, transport_peer(t))
			free(identity)
			free(encoded)
			free(digest)
			pem_blocks_free(blocks)
			free(pem)
		else:
			assert_equal(IO_UNSUPPORTED, transport_require_authenticated(t, &r))
			assert_strings_equal(c"untrusted-label", transport_peer(t))
		transport_set_timeout(t, 4000)
		assert_equal(IO_OK, transport_write_all(t, c"accepted", 8, &r))
		char* buf = cast(char*, malloc(8))
		assert_equal(IO_OK, transport_read_exact(t, buf, 4, &r))
		assert_bytes_equal(c"ping", buf, 4)
		assert_equal(IO_EOF, transport_read_some(t, buf, 8, &r))
		transport_free(t)
		free(buf)
		exit(0)
	close(fds[1])
	tls_config* cfg = mt_client_config()
	if (mode == 1 || mode == 6):
		cfg.client_cert_chain_path = 0
		cfg.client_key_path = 0
	if (mode == 3): cfg.client_cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/expired.pem"
	if (mode == 4 || mode == 8): cfg.client_cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/server_only.pem"
	if (mode == 5): cfg.client_key_path = c"libs/standard/net/tls_mutual_fixtures/wrong_key.pem"
	if (mode == 9 || mode == 0): cfg.require_client_auth = 1
	if (mode == 10): cfg.client_cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/no_signing.pem"
	if (mode == 11): cfg.client_key_path = c"/missing-mutual-tls-key.pem"
	if (mode == 12): cfg.insecure_skip_verify = 1
	if (mode == 15): cfg.client_cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/restricted_chain.pem"
	io_result r
	transport* t = transport_tls_connect(fds[0], c"test.w.example", cfg, 10000, &r)
	tls_config_free(cfg)
	char* buf = cast(char*, malloc(8))
	if (succeeds):
		assert1(t != 0)
		assert_equal(mode != 12, transport_authenticated(t))
		transport_set_timeout(t, 4000)
		assert_equal(IO_OK, transport_read_exact(t, buf, 8, &r))
		assert_bytes_equal(c"accepted", buf, 8)
		assert_equal(IO_OK, transport_write_all(t, c"ping", 4, &r))
		assert_equal(IO_OK, transport_close(t, &r))
		transport_free(t)
	else:
		# TLS 1.3 has no server Finished after the client proof: rejection
		# can surface on the first read, depending on socket scheduling.
		if (t != 0):
			transport_set_timeout(t, 4000)
			assert_equal(IO_IO_ERROR, transport_read_some(t, buf, 8, &r))
			assert1(transport_tls_last_error(t) != 0)
			transport_free(t)
		else: assert_equal(IO_IO_ERROR, r.status)
	assert_equal(0 - TRANSPORT_EBADF, socket_recv(fds[0], buf, 1, 0))
	free(buf)
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	free(fds)


void test_mutual_tls_required_and_optional_authenticated_identity():
	mt_exchange(0)
	mt_exchange(6)
	mt_exchange(7)


void test_mutual_tls_rejects_missing_untrusted_expired_and_wrong_purpose():
	for mode in range(1, 5): mt_exchange(mode)
	mt_exchange(8)
	mt_exchange(10)


void test_mutual_tls_rejects_wrong_key_omission_and_missing_configuration():
	mt_exchange(5)
	mt_exchange(9)
	mt_exchange(11)
	mt_exchange(13)


void test_mutual_tls_insecure_client_does_not_authenticate_server():
	mt_exchange(12)


void test_mutual_tls_request_framing_and_required_signature_algorithms():
	char* valid = c"\x0d\x00\x00\x0b\x00\x00\x08\x00\x0d\x00\x04\x00\x02\x04\x03"
	for mode in range(7):
		tls_conn* c = tls_conn_new(-1, 1, 0)
		char* msg = mem_dup(valid, 15)
		int len = 15
		if (mode == 1): msg[4] = 1
		if (mode == 2): msg[6] = 9
		if (mode == 3): msg[8] = 99
		if (mode == 4): msg[12] = 1
		if (mode == 5): len = 14
		if (mode == 6): msg[14] = 1
		int ok = tls_parse_certificate_request(c, msg, len)
		assert_equal(mode == 0 || mode == 6, ok)
		assert_equal(mode == 0, c.client_auth_p256)
		assert_equal(0, c.peer_verified)
		free(msg)
		tls_conn_free(c)


void test_mutual_tls_client_certificate_omission_and_malformed_empty_fail_closed():
	for mode in range(4):
		tls_server_config* cfg = mt_server_config()
		cfg.client_auth = TLS_CLIENT_AUTH_OPTIONAL
		tls_conn* c = tls_conn_new(-1, 1, 0)
		c.is_server = 1
		c.scfg = cfg
		char* msg = mem_dup(c"\x0b\x00\x00\x04\x00\x00\x00\x00", 8)
		if (mode == 0): msg[0] = TLS_HS_FINISHED
		if (mode == 1): msg[4] = 1
		if (mode == 2): msg[7] = 1
		if (mode == 3): cfg.client_auth = TLS_CLIENT_AUTH_REQUIRED
		# Feed the actual handshake reader a plaintext framed message.
		tls_conn* writer = tls_conn_new(-1, 1, 0)
		assert_equal(1, tls_send_record(writer, TLS_CT_HANDSHAKE, msg, 8, 0))
		string_append_bytes(c.mem_in, writer.mem_out.data, writer.mem_out.length)
		assert_equal(0, tls_server_read_client_auth(c))
		assert_equal(0, c.peer_verified)
		assert1(tls_peer_certificate_sha256(c) == 0)
		free(msg)
		tls_conn_free(writer)
		tls_conn_free(c)
		tls_server_config_free(cfg)


# Leave the server waiting for the requested client Certificate after its
# encrypted flight. Cancellation and deadlines must close that owned fd.
void mt_send_client_hello(int fd):
	char* random = cast(char*, malloc(32))
	char* priv = cast(char*, malloc(32))
	char* pub = cast(char*, malloc(32))
	mem_fill(random, 42, 32)
	mem_fill(priv, 17, 32)
	x25519_scalarmult_base(pub, priv)
	int len = 0
	char* msg = tls_build_client_hello(c"test.w.example", random, random, pub, &len)
	tls_conn* c = tls_conn_new(fd, 0, 0)
	assert_equal(1, tls_send_record(c, TLS_CT_HANDSHAKE, msg, len, 0))
	tls_conn_free(c)
	free(msg)
	free(random)
	free(priv)
	free(pub)


struct mt_cancel_state:
	int fd
	int status
	task* acceptor


generator int mt_accept_waiting(mt_cancel_state* state):
	tls_server_config* cfg = mt_server_config()
	io_result r
	assert1(transport_tls_accept(state.fd, c"pending-client", cfg, 10000, &r) == 0)
	state.status = r.status
	assert_equal(IO_ERRNO_ECANCELED, r.native_error)
	tls_server_config_free(cfg)


generator int mt_cancel_accept(mt_cancel_state* state):
	task_sleep_ms(10)
	assert_equal(1, task_cancel(state.acceptor))


void test_mutual_tls_waiting_for_client_proof_deadline_and_cancellation():
	int* fds = cast(int*, malloc(2 * __word_size__))
	assert_equal(0, socket_pair(fds))
	mt_send_client_hello(fds[0])
	tls_server_config* cfg = mt_server_config()
	io_result r
	assert1(transport_tls_accept(fds[1], c"pending-client", cfg, 40, &r) == 0)
	assert_equal(IO_TIMED_OUT, r.status)
	tls_server_config_free(cfg)
	char* buf = cast(char*, malloc(1))
	assert_equal(0 - TRANSPORT_EBADF, socket_recv(fds[1], buf, 1, 0))
	close(fds[0])
	assert_equal(0, socket_pair(fds))
	mt_send_client_hello(fds[0])
	mt_cancel_state state
	state.fd = fds[1]
	state.status = -1
	task_scheduler* scheduler = task_scheduler_new()
	state.acceptor = task_spawn(scheduler, mt_accept_waiting(&state))
	task_spawn(scheduler, mt_cancel_accept(&state))
	assert_equal(0, task_run(scheduler))
	assert_equal(IO_CANCELLED, state.status)
	assert_equal(0 - TRANSPORT_EBADF, socket_recv(fds[1], buf, 1, 0))
	task_scheduler_free(scheduler)
	close(fds[0])
	free(buf)
	free(fds)


void test_mutual_tls_certificate_verify_binds_role_and_transcript():
	char* pem = file_read_text(c"libs/standard/net/tls_mutual_fixtures/client.pem")
	list[pem_block*] blocks = pem_decode_blocks(pem, strlen(pem), c"CERTIFICATE")
	x509_cert* cert = x509_parse(blocks[0].data, blocks[0].len)
	assert1(cert != 0)
	char* key_pem = file_read_text(c"libs/standard/net/tls_mutual_fixtures/client_key.pem")
	char* key = cast(char*, malloc(32))
	assert_equal(1, x509_load_ec_private_key(key_pem, strlen(key_pem), key))
	char* th = cast(char*, malloc(32))
	mem_fill(th, 97, 32)
	for role in range(2):
		int len = 0
		char* proof = tls_build_certverify_role(key, th, 32, role, &len)
		assert1(proof != 0)
		assert_equal(1, tls_verify_certverify_role(cert, TLS_SIG_ECDSA_SECP256R1_SHA256, proof + 8, len - 8, th, 32, role))
		assert_equal(0, tls_verify_certverify_role(cert, TLS_SIG_ECDSA_SECP256R1_SHA256, proof + 8, len - 8, th, 32, 1 - role))
		th[0] = th[0] ^ 1
		assert_equal(0, tls_verify_certverify_role(cert, TLS_SIG_ECDSA_SECP256R1_SHA256, proof + 8, len - 8, th, 32, role))
		th[0] = th[0] ^ 1
		free(proof)
	tls_wipe(key, 32)
	free(key)
	tls_wipe(key_pem, strlen(key_pem))
	free(key_pem)
	free(th)
	x509_cert_free(cert)
	pem_blocks_free(blocks)
	free(pem)


void test_mutual_tls_rejects_malformed_tail_after_valid_certificate():
	char* pem = file_read_text(c"libs/standard/net/tls_mutual_fixtures/client.pem")
	list[pem_block*] blocks = pem_decode_blocks(pem, strlen(pem), c"CERTIFICATE")
	int len = 0
	char* msg = tls_build_certificate(blocks, &len)
	list[x509_cert*] parsed = tls_parse_certificate(msg, len)
	assert_equal(1, parsed.length)
	tls_free_cert_list(parsed)
	# A well-formed leaf must not hide a truncated second entry.
	char* bad = cast(char*, malloc(len + 1))
	mem_copy(bad, msg, len)
	bad[len] = 0
	store_be24(bad + 1, len - 3)
	store_be24(bad + 5, len - 7)
	parsed = tls_parse_certificate(bad, len + 1)
	assert_equal(0, parsed.length)
	tls_free_cert_list(parsed)
	free(bad)
	free(msg)
	pem_blocks_free(blocks)
	free(pem)


void test_mutual_tls_rejects_duplicate_request_extension_at_end():
	# The second signature_algorithms extension has an empty body. Its
	# header reaches the message end; a parser must not mistake that for
	# successfully consuming every extension.
	char* request = c"\x0d\x00\x00\x0f\x00\x00\x0c\x00\x0d\x00\x04\x00\x02\x04\x03\x00\x0d\x00\x00"
	tls_conn* c = tls_conn_new(-1, 1, 0)
	assert_equal(0, tls_parse_certificate_request(c, request, 19))
	assert_equal(0, c.client_auth_requested)
	assert_equal(0, c.peer_verified)
	tls_conn_free(c)



void test_mutual_tls_rejects_server_only_issuer_and_trust_anchor():
	mt_exchange(14)
	mt_exchange(15)


void test_mutual_tls_identity_requires_valid_finished_after_client_proof():
	for mode in range(4):
		tls_server_config* cfg = mt_server_config()
		tls_conn* server = tls_conn_new(-1, 1, 0)
		server.is_server = 1
		server.scfg = cfg
		tls_conn* writer = tls_conn_new(-1, 1, 0)
		tls_server_config* credentials = tls_server_config_new()
		credentials.cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/client.pem"
		credentials.key_path = c"libs/standard/net/tls_mutual_fixtures/client_key.pem"
		list[pem_block*] blocks = tls_server_cert_blocks(credentials)
		char* key = cast(char*, malloc(32))
		assert_equal(1, tls_server_load_key(credentials, key))
		int len = 0
		char* msg = tls_build_certificate(blocks, &len)
		pem_blocks_free(blocks)
		whash_update(writer.transcript, msg, len)
		assert_equal(1, tls_send_record(writer, TLS_CT_HANDSHAKE, msg, len, 0))
		free(msg)
		char* th = cast(char*, malloc(32))
		whash_final(writer.transcript, th)
		msg = tls_build_certverify_role(key, th, 32, 1, &len)
		assert1(msg != 0)
		if (mode != 3):
			whash_update(writer.transcript, msg, len)
			assert_equal(1, tls_send_record(writer, TLS_CT_HANDSHAKE, msg, len, 0))
		free(msg)
		tls_wipe(key, 32)
		free(key)
		tls_server_config_free(credentials)
		if (mode != 0):
			char* fin = cast(char*, malloc(36))
			fin[0] = TLS_HS_FINISHED
			store_be24(fin + 1, 32)
			whash_final(writer.transcript, th)
			char* fkey = cast(char*, malloc(32))
			tls_finished_key(writer.hash_alg, writer.c_hs_secret, fkey)
			hmac_compute(writer.hash_alg, fkey, 32, th, 32, fin + 4)
			if (mode == 1): fin[4] = fin[4] ^ 1
			assert_equal(1, tls_send_record(writer, TLS_CT_HANDSHAKE, fin, 36, 0))
			free(fkey)
			free(fin)
		free(th)
		string_append_bytes(server.mem_in, writer.mem_out.data, writer.mem_out.length)
		assert_equal(mode != 3, tls_server_read_client_auth(server))
		assert_equal(0, server.peer_verified)
		assert1(tls_peer_certificate_sha256(server) == 0)
		if (mode != 3):
			assert_equal(mode == 2, tls_server_read_client_finished(server))
			assert_equal(mode == 2, server.peer_verified)
			assert_equal(mode == 2, tls_peer_certificate_sha256(server) != 0)
		tls_conn_free(server)
		tls_conn_free(writer)
		tls_server_config_free(cfg)


void test_mutual_tls_certificate_signature_constraints_are_independent():
	# P-256 handshake signatures with a certificate-signature list which
	# allows only RSA: our ECDSA-signed client chain must not be selected.
	char* request = c"\x0d\x00\x00\x13\x00\x00\x10\x00\x0d\x00\x04\x00\x02\x04\x03\x00\x32\x00\x04\x00\x02\x04\x01"
	tls_conn* c = tls_conn_new(-1, 1, 0)
	assert_equal(1, tls_parse_certificate_request(c, request, 23))
	assert_equal(1, c.client_auth_p256)
	assert_equal(1 << X509_SIGALG_RSA_SHA256, c.client_auth_cert_schemes)
	tls_server_config* credentials = tls_server_config_new()
	credentials.cert_chain_path = c"libs/standard/net/tls_mutual_fixtures/client.pem"
	list[pem_block*] blocks = tls_server_cert_blocks(credentials)
	assert_equal(0, tls_client_chain_compatible(blocks, c.client_auth_cert_schemes))
	assert_equal(1, tls_client_chain_compatible(blocks, 1 << X509_SIGALG_ECDSA_SHA256))
	pem_blocks_free(blocks)
	tls_server_config_free(credentials)
	tls_conn_free(c)
