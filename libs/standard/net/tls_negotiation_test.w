# wbuild: name=net_tls_negotiation_test x64
# Offline negotiation, retry validation, SHA-384 transcripts and KeyUpdate.
import lib.testing
import libs.standard.net.tls


tls_conn* tn_client():
	tls_conn* c = tls_conn_new(0 - 1, 1, 0)
	char[32] data
	mem_fill(cast(char*, data), 0x31, 32)
	int n = 0
	char* ch = tls_build_client_hello(c"localhost", data, data, data, &n)
	string_append_bytes(c.hello, ch, n)
	whash_update(c.transcript, ch, n)
	free(ch)
	return c


char* tn_hello(tls_conn* c, int suite, int group, int retry, int* len):
	char[65] data
	mem_fill(cast(char*, data), 0x42, 65)
	char* random = cast(char*, data)
	char* pub = cast(char*, data)
	if (retry):
		random = tls_hrr_random()
		pub = 0
	return tls_build_server_hello_group(random, c.hello.data + 39, 32, pub, suite, group, len)


void test_server_hello_validation():
	tls_conn* c = tn_client()
	char[65] peer
	int n = 0
	char* sh = tn_hello(c, TLS_SUITE_AES_128_GCM_SHA256, TLS_GROUP_X25519, 0, &n)
	for cut in range(n): assert_equal(0, tls_parse_server_hello(c, sh, cut, peer))
	assert_equal(1, tls_parse_server_hello(c, sh, n, peer))
	assert_equal(16, c.key_len)
	sh[39] ^= 1
	assert_equal(0, tls_parse_server_hello(c, sh, n, peer))
	sh[39] ^= 1
	sh[72] = 4
	assert_equal(0, tls_parse_server_hello(c, sh, n, peer))
	free(sh)
	# An already supplied group cannot be requested again.
	sh = tn_hello(c, TLS_SUITE_AES_128_GCM_SHA256, TLS_GROUP_X25519, 1, &n)
	assert_equal(0, tls_parse_server_hello(c, sh, n, peer))
	free(sh)
	sh = tn_hello(c, TLS_SUITE_AES_256_GCM_SHA384, TLS_GROUP_SECP256R1, 1, &n)
	assert_equal(2, tls_parse_server_hello(c, sh, n, peer))
	assert_equal(48, c.digest_size)
	# Independently assemble RFC 8446 section 4.4.1's message_hash transcript.
	char[52] synthetic
	synthetic[0] = 254
	store_be24(cast(char*, synthetic) + 1, 48)
	whash_oneshot(WHASH_SHA384, c.hello.data, c.hello.length, cast(char*, synthetic) + 4)
	whash* expected = whash_new(WHASH_SHA384)
	whash_update(expected, synthetic, 52)
	whash_update(expected, sh, n)
	tls_retry_transcript(c, sh, n)
	char[48] a
	char[48] b
	whash_final(expected, a)
	whash_final(c.transcript, b)
	assert_bytes_equal(a, b, 48)
	whash_free(expected)
	assert_equal(0, tls_parse_server_hello(c, sh, n, peer))
	free(sh)
	c.key_group = TLS_GROUP_SECP256R1
	sh = tn_hello(c, TLS_SUITE_AES_128_GCM_SHA256, TLS_GROUP_SECP256R1, 0, &n)
	assert_equal(0, tls_parse_server_hello(c, sh, n, peer))
	free(sh)
	sh = tn_hello(c, TLS_SUITE_AES_256_GCM_SHA384, TLS_GROUP_SECP256R1, 0, &n)
	assert_equal(1, tls_parse_server_hello(c, sh, n, peer))
	free(sh)
	tls_conn_free(c)


void test_cookie_only_retry():
	tls_conn* c = tn_client()
	char[65] peer
	int n = 0
	char* hrr = tn_hello(c, TLS_SUITE_AES_128_GCM_SHA256, TLS_GROUP_SECP256R1, 1, &n)
	# Replace the 6-byte key_share extension with an 8-byte cookie extension.
	char* msg = cast(char*, malloc(n + 2))
	mem_copy(msg, hrr, n - 6)
	store_be16(msg + n - 6, TLS_EXT_COOKIE)
	store_be16(msg + n - 4, 4)
	store_be16(msg + n - 2, 2)
	msg[n] = 0x31
	msg[n + 1] = 0x32
	store_be16(msg + 74, load_be16(hrr + 74) + 2)
	store_be24(msg + 1, n - 2)
	assert_equal(2, tls_parse_server_hello(c, msg, n + 2, peer))
	assert_equal(0, c.retry_group)
	assert_equal(4, c.retry_cookie.length)
	int cn = 0
	char* ch = tls_retry_client_hello(c.hello.data, c.hello.length, 0, 0, c.retry_cookie, &cn)
	assert_bytes_equal(c.hello.data + 4, ch + 4, tls_hello_extensions(ch, cn) - 4)
	assert_bytes_equal(msg + n - 6, ch + cn - 8, 8)
	# Duplicate cookies and malformed cookie vectors fail closed.
	char* duplicate = cast(char*, malloc(n + 10))
	mem_copy(duplicate, msg, n + 2)
	mem_copy(duplicate + n + 2, msg + n - 6, 8)
	store_be16(duplicate + 74, load_be16(msg + 74) + 8)
	store_be24(duplicate + 1, n + 6)
	assert_equal(0, tls_parse_server_hello(c, duplicate, n + 10, peer))
	msg[n - 1] = 3
	assert_equal(0, tls_parse_server_hello(c, msg, n + 2, peer))
	free(duplicate)
	free(ch)
	free(msg)
	free(hrr)
	tls_conn_free(c)


void test_server_retry_second_hello():
	for mutation in range(4):
		tls_conn* client = tn_client()
		tls_server_config* scfg = tls_server_config_new()
		scfg.cipher_suite = TLS_SUITE_AES_256_GCM_SHA384
		scfg.key_exchange_group = TLS_GROUP_SECP256R1
		tls_conn* server = tls_conn_new(0 - 1, 1, 0)
		server.scfg = scfg
		server.is_server = 1
		char[65] pub
		char[32] sid
		mem_fill(cast(char*, pub), 0x42, 65)
		int n = 0
		char* ch = tls_retry_client_hello(client.hello.data, client.hello.length, TLS_GROUP_SECP256R1, pub, client.retry_cookie, &n)
		if (mutation == 1): ch[6] ^= 1   # changed random
		if (mutation == 2): ch[74] ^= 1  # changed cipher list
		if (mutation == 3): ch[n - 68] = 0x1d  # wrong group's share
		assert_equal(1, tls_send_record(client, TLS_CT_HANDSHAKE, client.hello.data, client.hello.length, 0))
		assert_equal(1, tls_send_record(client, TLS_CT_HANDSHAKE, ch, n, 0))
		tls_mem_feed(server, client.mem_out.data, client.mem_out.length)
		int sid_len = 0
		int ok = tls_server_read_client_hello(server, sid, &sid_len, pub)
		assert_equal(cast(int, mutation == 0), ok)
		assert_equal(1, server.retry_seen)
		assert_equal(48, server.digest_size)
		free(ch)
		tls_conn_free(client)
		tls_conn_free(server)
		tls_server_config_free(scfg)


void tn_transfer(tls_conn* sender, tls_conn* receiver, int expected_type, char* expected, int expected_len):
	tls_mem_feed(receiver, sender.mem_out.data, sender.mem_out.length)
	sender.mem_out.length = 0
	int kind = 0
	int n = 0
	char* data = 0
	assert_equal(1, tls_recv_record(receiver, &kind, &data, &n))
	assert_equal(expected_type, kind)
	assert_equal(expected_len, n)
	assert_bytes_equal(expected, data, n)
	if (kind == TLS_CT_HANDSHAKE): tls_post_handshake(receiver, data, n)
	free(data)


void test_all_suites_key_update():
	for suite in range(0x1301, 0x1304):
		tls_conn* a = tls_conn_new(0 - 1, 1, 0)
		tls_conn* b = tls_conn_new(0 - 1, 1, 0)
		b.is_server = 1
		tls_set_suite(a, suite)
		tls_set_suite(b, suite)
		mem_fill(a.c_ap_secret, 0x31, a.digest_size)
		mem_fill(b.c_ap_secret, 0x31, b.digest_size)
		mem_fill(a.s_ap_secret, 0x42, a.digest_size)
		mem_fill(b.s_ap_secret, 0x42, b.digest_size)
		tls_install_write_keys(a, a.c_ap_secret)
		tls_install_read_keys(b, b.c_ap_secret)
		tls_install_read_keys(a, a.s_ap_secret)
		tls_install_write_keys(b, b.s_ap_secret)
		for iteration in range(3):
			assert_equal(1, tls_send_record(a, TLS_CT_APPLICATION_DATA, c"before", 6, 1))
			tn_transfer(a, b, TLS_CT_APPLICATION_DATA, c"before", 6)
			char* request = c"\x18\x00\x00\x01\x01"
			assert_equal(1, tls_send_record(a, TLS_CT_HANDSHAKE, request, 5, 1))
			tls_update_secret(a.hash_alg, a.c_ap_secret, a.digest_size)
			tls_install_write_keys(a, a.c_ap_secret)
			tn_transfer(a, b, TLS_CT_HANDSHAKE, request, 5)
			tn_transfer(b, a, TLS_CT_HANDSHAKE, c"\x18\x00\x00\x01\x00", 5)
			assert_equal(0, a.w_seq_lo)
			assert_equal(0, b.w_seq_lo)
			assert_equal(1, tls_send_record(b, TLS_CT_APPLICATION_DATA, c"after", 5, 1))
			tn_transfer(b, a, TLS_CT_APPLICATION_DATA, c"after", 5)
		tls_conn_free(a)
		tls_conn_free(b)
