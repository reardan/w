# wbuild: name=net_tls_resumption_adversarial_test x64
# Independent policy and hostile ServerHello regressions for PSK resumption.
import lib.testing
import libs.standard.net.tls


tls_conn* ta_client(int offered):
	tls_conn* c = tls_conn_new(-1, 1, 0)
	char[32] data
	mem_fill(cast(char*, data), 0x31, 32)
	int len = 0
	char* hello = tls_build_client_hello(c"localhost", data, data, data, &len)
	string_append_bytes(c.hello, hello, len)
	free(hello)
	if (offered):
		c.offered_session = new tls_session()
		c.offered_session.hash_alg = WHASH_SHA256
	return c


char* ta_server_hello(tls_conn* c, int suite, int mutation, int* len):
	char[65] data
	mem_fill(cast(char*, data), 0x42, 65)
	char* random = cast(char*, data)
	char* pub = cast(char*, data)
	int group = TLS_GROUP_X25519
	if (mutation == 4):
		random = tls_hrr_random()
		pub = 0
		group = TLS_GROUP_SECP256R1
	int n = 0
	char* base = tls_build_server_hello_group(random, c.hello.data + 39, 32, pub, suite, group, &n)
	# Drop key_share completely to test forbidden PSK-only key exchange.
	if (mutation == 5): n -= 40
	string_builder* b = string_new()
	string_append_bytes(b, base, n)
	free(base)
	int copies = 1
	if (mutation == 2): copies = 2
	for i in range(copies):
		string_append_be16(b, TLS_EXT_PRE_SHARED_KEY)
		if (mutation == 3):
			string_append_be16(b, 1)
			string_append_char(b, 0)
		else:
			string_append_be16(b, 2)
			string_append_be16(b, cast(int, mutation == 1))
	store_be16(b.data + 74, b.length - 76)
	store_be24(b.data + 1, b.length - 4)
	*len = b.length
	char* result = b.data
	free(b)
	return result


void test_resumption_rejects_invalid_server_selection():
	# Out-of-range identity, duplicate/malformed extension, PSK in HRR,
	# missing DHE share, incompatible hash, and unsolicited acceptance.
	for mode in range(1, 8):
		tls_conn* c = ta_client(mode != 7)
		int suite = TLS_SUITE_AES_128_GCM_SHA256
		if (mode == 6): suite = TLS_SUITE_AES_256_GCM_SHA384
		int len = 0
		char* hello = ta_server_hello(c, suite, mode, &len)
		char[65] peer
		assert_equal(0, tls_parse_server_hello(c, hello, len, peer))
		assert_equal(0, c.resumed)
		free(hello)
		tls_conn_free(c)
	# A different cipher suite with the same hash remains compatible.
	tls_conn* c = ta_client(1)
	int len = 0
	char* hello = ta_server_hello(c, TLS_SUITE_AES_128_GCM_SHA256, 0, &len)
	char[65] peer
	assert_equal(1, tls_parse_server_hello(c, hello, len, peer))
	assert_equal(1, c.resumed)
	free(hello)
	tls_conn_free(c)


void test_resumption_same_path_trust_replacement():
	char* path = c"bin/tls_resumption_trust32.pem"
	if (__word_size__ == 8): path = c"bin/tls_resumption_trust64.pem"
	char* original = file_read_text(c"libs/standard/net/x509_fixtures/ca_ec.pem")
	char* replacement = file_read_text(c"libs/standard/net/x509_fixtures/ca_rsa.pem")
	asserts(c"trust fixtures readable", original != 0 && replacement != 0)
	assert_equal(1, file_write_text(path, original))
	tls_session_cache* cache = tls_session_cache_new()
	tls_config* cfg = tls_config_new()
	cfg.session_cache = cache
	cfg.server_port = 443
	cfg.trust_store_path = path
	tls_conn* issuer = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(issuer, c"localhost")
	asserts(c"initial trust snapshot exists", issuer.session_context != 0)
	tls_session* session = new tls_session()
	session.server_name = strclone(c"localhost")
	session.port = 443
	session.context = mem_dup(issuer.session_context, 32)
	session.lifetime = 60
	session.received_unix = time_now()
	session.received_ms = time_monotonic_ms()
	cache.entries.push(session)
	assert_equal(1, file_write_text(path, replacement))
	tls_conn* changed = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(changed, c"localhost")
	assert_equal(0, cast(int, changed.offered_session))
	assert_equal(1, cache.entries.length)
	assert_equal(0, mem_eq(issuer.session_context, changed.session_context, 32))
	tls_conn_free(changed)
	# Restoring the exact trust policy permits the still-live session.
	assert_equal(1, file_write_text(path, original))
	tls_conn* restored = tls_conn_new(-1, 1, cfg)
	tls_session_prepare(restored, c"localhost")
	asserts(c"original policy may resume", restored.offered_session != 0)
	assert_equal(0, cache.entries.length)
	tls_conn_free(restored)
	tls_conn_free(issuer)
	tls_config_free(cfg)
	tls_session_cache_free(cache)
	free(original)
	free(replacement)
	assert_equal(0, unlink(path))


void test_resumption_cache_capacity_and_replacement():
	tls_session_cache* cache = tls_session_cache_new()
	tls_conn* issuer = tls_conn_new(-1, 1, 0)
	issuer.session_cache = cache
	issuer.session_port = 443
	issuer.session_context = cast(char*, malloc(32))
	mem_fill(issuer.session_context, 0, 32)
	issuer.resumption_ready = 1
	issuer.peer_verified = 1
	# One-byte ticket, empty nonce and extension vector, 60-second lifetime.
	char* ticket = c"\x04\x00\x00\x0e\x00\x00\x00\x3c\x00\x00\x00\x00\x00\x00\x01x\x00\x00"
	for i in range(24):
		if (issuer.session_server_name != 0): free(issuer.session_server_name)
		issuer.session_server_name = itoa(i)
		assert_equal(1, tls_session_ticket(issuer, ticket, 18))
		asserts(c"ticket cache bounded", cache.entries.length <= 16)
	assert_equal(16, cache.entries.length)
	assert_equal(1, tls_session_ticket(issuer, ticket, 18))
	assert_equal(16, cache.entries.length)
	tls_session_cache_clear(cache)
	assert_equal(0, cache.entries.length)
	tls_conn_free(issuer)
	tls_session_cache_free(cache)
