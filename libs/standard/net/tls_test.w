/*
Tests for the TLS 1.3 client (libs/standard/net/tls.w), issue #201.

Everything runs offline against checked-in fixtures -- no network, no
openssl. The core correctness test replays the RFC 8448 section 3 "Simple
1-RTT Handshake" trace through the real client state machine.

Note on the cipher suite: RFC 8448 section 3 negotiates TLS_AES_128_GCM_
SHA256, but this client implements TLS_CHACHA20_POLY1305_SHA256 only. Every
value the trace pins down that MATTERS -- the traffic secrets, the transcript
hashes, the server CertificateVerify RSA-PSS signature and both Finished MACs
-- is derived from the SHA-256 key schedule and the handshake transcript and
is therefore *independent of the record cipher*. So the replay injects the
RFC's real ClientHello and client private key, feeds the RFC's real
ServerHello (its AES suite id accepted via the loud test_accept_any_cipher
knob) and the RFC's real server-flight PLAINTEXT re-sealed with ChaCha20 keys
derived from the RFC's server handshake secret, and asserts:
  - the derived client/server handshake + application traffic secrets equal
    the RFC values,
  - the handshake completes -- meaning the real RFC CertificateVerify
    signature verified over our transcript and the real RFC server Finished
    MAC (9b9b1...) matched,
  - the client Finished the state machine emits carries the RFC's recorded
    verify_data (a8ec4...).
The ChaCha20 record layer itself is covered by its own module's RFC 8439 /
Wycheproof vectors plus the round-trip and framing units below.

Record-layer units: AEAD nonce construction vs a known vector, an AEAD round
trip through the record framing, fragmented-handshake reassembly and
max-length enforcement. Negative/fail-closed tests: a bad server Finished
MAC, a tampered ciphertext byte (bad_record_mac), a CertificateVerify
signature mismatch, a chain that fails x509_verify_chain, a fatal alert, and
that a non-ChaCha ServerHello is rejected by default.
*/
import lib.testing
import lib.memory
import libs.standard.crypto.sha2
import libs.standard.crypto.chacha20poly1305
import libs.standard.net.tls


# ---- hex helpers --------------------------------------------------------------

int tlst_nibble(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	return c - 'a' + 10


char* tlst_unhex(char* hex, int* out_len):
	int n = strlen(hex) / 2
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = (tlst_nibble(hex[i * 2] & 255) << 4) | tlst_nibble(hex[i * 2 + 1] & 255)
		i = i + 1
	out[n] = 0
	*out_len = n
	return out


char* tlst_hex(char* data, int len):
	char* out = malloc(len * 2 + 1)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < len):
		int b = data[i] & 255
		out[i * 2] = digits[(b >> 4) & 15]
		out[i * 2 + 1] = digits[b & 15]
		i = i + 1
	out[len * 2] = 0
	return out


void tlst_assert_hex(char* want_hex, char* got, int got_len):
	char* got_hex = tlst_hex(got, got_len)
	assert_strings_equal(want_hex, got_hex)
	free(got_hex)


char* tlst_concat(char* a, int alen, char* b, int blen, int* out_len):
	char* out = malloc(alen + blen)
	int i = 0
	while (i < alen):
		out[i] = a[i]
		i = i + 1
	i = 0
	while (i < blen):
		out[alen + i] = b[i]
		i = i + 1
	*out_len = alen + blen
	return out


# Derive the ChaCha20 record key (32) + iv (12) for a traffic secret (hex).
void tlst_keys_from_secret(char* secret_hex, char* out_key, char* out_iv):
	int slen = 0
	char* secret = tlst_unhex(secret_hex, &slen)
	tls_derive_traffic_keys(WHASH_SHA256(), secret, out_key, out_iv)
	free(secret)


# Build a full encrypted TLSCiphertext record (header || ciphertext || tag):
# inner = plain || inner_ct, sealed under key/iv/seq with the record header as
# additional_data -- exactly what tls_send_record produces.
char* tlst_enc_record(char* key, char* iv, int seq_hi, int seq_lo, char* plain, int plain_len, int inner_ct, int* out_len):
	int inner_len = plain_len + 1
	int rec_len = inner_len + 16
	char* rec = malloc(5 + rec_len)
	rec[0] = 23
	rec[1] = 3
	rec[2] = 3
	rec[3] = (rec_len >> 8) & 255
	rec[4] = rec_len & 255
	char* inner = malloc(inner_len)
	int i = 0
	while (i < plain_len):
		inner[i] = plain[i]
		i = i + 1
	inner[plain_len] = inner_ct & 255
	char* nonce = malloc(12)
	tls_nonce(iv, seq_hi, seq_lo, nonce)
	char* ct = malloc(inner_len)
	char* tag = malloc(16)
	chacha20poly1305_seal(key, nonce, rec, 5, inner, inner_len, ct, tag)
	i = 0
	while (i < inner_len):
		rec[5 + i] = ct[i]
		i = i + 1
	i = 0
	while (i < 16):
		rec[5 + inner_len + i] = tag[i]
		i = i + 1
	free(inner)
	free(nonce)
	free(ct)
	free(tag)
	*out_len = 5 + rec_len
	return rec


# Decrypt an encrypted record. Returns the inner content type; *out_len gets
# the content length and out_plain (>= rec_len) receives the content bytes.
int tlst_dec_record(char* key, char* iv, int seq_hi, int seq_lo, char* rec, int rec_len, char* out_plain, int* out_len):
	int rlen = ((rec[3] & 255) << 8) | (rec[4] & 255)
	int ct_len = rlen - 16
	char* nonce = malloc(12)
	tls_nonce(iv, seq_hi, seq_lo, nonce)
	char* plain = malloc(ct_len)
	int ok = chacha20poly1305_open(key, nonce, rec, 5, rec + 5, ct_len, rec + 5 + ct_len, plain)
	asserts(c"tlst_dec_record: open failed", ok != 0)
	int p = ct_len - 1
	while ((p >= 0) && (plain[p] == 0)):
		p = p - 1
	int inner_type = plain[p] & 255
	int i = 0
	while (i < p):
		out_plain[i] = plain[i]
		i = i + 1
	*out_len = p
	free(nonce)
	free(plain)
	return inner_type


# ---- RFC 8448 section 3 constants ---------------------------------------------

char* rfc_client_hello_hex():
	return c"010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001"


char* rfc_server_hello_hex():
	return c"020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304"


char* rfc_client_priv_hex():
	return c"49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005"


char* rfc_flight_plain_hex():
	return c"080000240022000a00140012001d00170018001901000101010201030104001c00024001000000000b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de100000f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718"


char* rfc_shts_hex():
	return c"b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38"


char* rfc_chts_hex():
	return c"b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21"


char* rfc_c_ap_hex():
	return c"9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5"


char* rfc_s_ap_hex():
	return c"a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643"


char* rfc_client_finished_vd_hex():
	return c"a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61"


char* rfc_app_plain_hex():
	return c"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031"


# Assemble the on-the-wire server flight: the plaintext ServerHello record
# followed by the server's handshake flight re-sealed with ChaCha20 keys
# derived from the RFC server handshake secret (sequence 0). tamper_off flips
# one plaintext byte before sealing; ct_tamper_off flips one ciphertext byte
# after sealing (pass -1 for none).
char* tlst_build_server_bytes(int tamper_off, int tamper_val, int ct_tamper_off, int* out_len):
	int sh_len = 0
	char* sh = tlst_unhex(rfc_server_hello_hex(), &sh_len)
	char* sh_rec = malloc(5 + sh_len)
	sh_rec[0] = 22
	sh_rec[1] = 3
	sh_rec[2] = 3
	sh_rec[3] = (sh_len >> 8) & 255
	sh_rec[4] = sh_len & 255
	int i = 0
	while (i < sh_len):
		sh_rec[5 + i] = sh[i]
		i = i + 1
	int sh_rec_len = 5 + sh_len

	int flen = 0
	char* flight = tlst_unhex(rfc_flight_plain_hex(), &flen)
	if (tamper_off >= 0):
		flight[tamper_off] = tamper_val & 255
	char* key = malloc(32)
	char* iv = malloc(12)
	tlst_keys_from_secret(rfc_shts_hex(), key, iv)
	int frec_len = 0
	char* frec = tlst_enc_record(key, iv, 0, 0, flight, flen, 22, &frec_len)
	if (ct_tamper_off >= 0):
		frec[ct_tamper_off] = frec[ct_tamper_off] ^ 0xff

	int total = 0
	char* out = tlst_concat(sh_rec, sh_rec_len, frec, frec_len, &total)
	free(sh)
	free(sh_rec)
	free(flight)
	free(key)
	free(iv)
	free(frec)
	*out_len = total
	return out


# Set the standard RFC-replay knobs on a config: skip chain build (the RFC
# test cert is self-signed), accept the trace's AES suite id, inject the
# recorded ClientHello and client private key.
tls_config* tlst_replay_config(char* ch, int ch_len, char* priv):
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	cfg.test_accept_any_cipher = 1
	cfg.test_priv = priv
	cfg.test_client_hello = ch
	cfg.test_client_hello_len = ch_len
	return cfg


# ---- core: RFC 8448 section 3 trace -------------------------------------------

void test_rfc8448_full_handshake():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tlst_replay_config(ch, ch_len, priv)

	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(0 - 1, 0, 0 - 1, &sb_len)

	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"server", cfg)
	# A non-null connection means: ServerHello parsed, ECDHE derived, the RFC
	# CertificateVerify RSA-PSS signature verified over our transcript, and the
	# RFC server Finished MAC matched -- the whole flight is authentic.
	asserts(c"tls: RFC 8448 handshake must succeed", c != 0)

	# Derived traffic secrets match the RFC trace exactly.
	tlst_assert_hex(rfc_chts_hex(), c.c_hs_secret, 32)
	tlst_assert_hex(rfc_shts_hex(), c.s_hs_secret, 32)
	tlst_assert_hex(rfc_c_ap_hex(), c.c_ap_secret, 32)
	tlst_assert_hex(rfc_s_ap_hex(), c.s_ap_secret, 32)

	# The client output = ClientHello plaintext record + client Finished record.
	# Decrypt the Finished record (client handshake keys from CHTS) and check
	# its verify_data equals the RFC's recorded value.
	int out_len = 0
	char* out = tls_mem_take_output(c, &out_len)
	int ch_rec_len = 5 + (((out[3] & 255) << 8) | (out[4] & 255))
	char* c_hs_key = malloc(32)
	char* c_hs_iv = malloc(12)
	tlst_keys_from_secret(rfc_chts_hex(), c_hs_key, c_hs_iv)
	char* fin_plain = malloc(out_len)
	int fin_plain_len = 0
	int fin_type = tlst_dec_record(c_hs_key, c_hs_iv, 0, 0, out + ch_rec_len, out_len - ch_rec_len, fin_plain, &fin_plain_len)
	# Inner record content type is handshake; the message is a Finished.
	assert_equal(TLS_CT_HANDSHAKE(), fin_type)
	assert_equal(TLS_HS_FINISHED(), fin_plain[0] & 255)
	# Finished message = type(1) + len(3) + verify_data(32).
	assert_equal(36, fin_plain_len)
	tlst_assert_hex(rfc_client_finished_vd_hex(), fin_plain + 4, 32)

	free(fin_plain)
	free(c_hs_key)
	free(c_hs_iv)
	free(out)
	tls_conn_free(c)
	tls_config_free(cfg)
	free(server_bytes)
	free(ch)
	free(priv)


# Post-handshake data path: read/write/close through the real record layer,
# keyed from the RFC application traffic secrets (round-trip plaintext).
void test_rfc8448_application_data():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tlst_replay_config(ch, ch_len, priv)
	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(0 - 1, 0, 0 - 1, &sb_len)
	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"server", cfg)
	asserts(c"tls: handshake for appdata test", c != 0)

	int junk_len = 0
	char* junk = tls_mem_take_output(c, &junk_len)
	free(junk)

	int app_len = 0
	char* app_plain = tlst_unhex(rfc_app_plain_hex(), &app_len)
	char* s_ap_key = malloc(32)
	char* s_ap_iv = malloc(12)
	tlst_keys_from_secret(rfc_s_ap_hex(), s_ap_key, s_ap_iv)
	char* c_ap_key = malloc(32)
	char* c_ap_iv = malloc(12)
	tlst_keys_from_secret(rfc_c_ap_hex(), c_ap_key, c_ap_iv)

	# Read: feed a server application_data record (server app seq 0).
	int srec_len = 0
	char* srec = tlst_enc_record(s_ap_key, s_ap_iv, 0, 0, app_plain, app_len, 23, &srec_len)
	tls_mem_feed(c, srec, srec_len)
	char* rbuf = malloc(256)
	int got = tls_read(c, rbuf, 256)
	assert_equal(app_len, got)
	tlst_assert_hex(rfc_app_plain_hex(), rbuf, got)

	# Write: decrypt our emitted record (client app seq 0) and check plaintext.
	assert_equal(app_len, tls_write(c, app_plain, app_len))
	int wlen = 0
	char* wout = tls_mem_take_output(c, &wlen)
	char* wplain = malloc(wlen)
	int wplain_len = 0
	int wtype = tlst_dec_record(c_ap_key, c_ap_iv, 0, 0, wout, wlen, wplain, &wplain_len)
	assert_equal(TLS_CT_APPLICATION_DATA(), wtype)
	assert_equal(app_len, wplain_len)
	tlst_assert_hex(rfc_app_plain_hex(), wplain, wplain_len)
	free(wout)
	free(wplain)

	# close_notify from tls_close-style path (client app seq 1 after one record).
	tls_send_alert(c, TLS_ALERT_WARNING(), TLS_ALERT_CLOSE_NOTIFY())
	int clen = 0
	char* cout = tls_mem_take_output(c, &clen)
	char* cplain = malloc(clen)
	int cplain_len = 0
	int ctype = tlst_dec_record(c_ap_key, c_ap_iv, 0, 1, cout, clen, cplain, &cplain_len)
	assert_equal(TLS_CT_ALERT(), ctype)
	assert_equal(2, cplain_len)
	assert_equal(TLS_ALERT_CLOSE_NOTIFY(), cplain[1] & 255)
	free(cout)
	free(cplain)

	# A server close_notify (server app seq 1) is a clean EOF.
	char* alert = malloc(2)
	alert[0] = 1
	alert[1] = 0
	int carec_len = 0
	char* carec = tlst_enc_record(s_ap_key, s_ap_iv, 0, 1, alert, 2, 21, &carec_len)
	tls_mem_feed(c, carec, carec_len)
	assert_equal(0, tls_read(c, rbuf, 256))
	free(alert)
	free(carec)

	free(rbuf)
	free(srec)
	free(app_plain)
	free(s_ap_key)
	free(s_ap_iv)
	free(c_ap_key)
	free(c_ap_iv)
	tls_conn_free(c)
	tls_config_free(cfg)
	free(server_bytes)
	free(ch)
	free(priv)


# ---- record-layer units -------------------------------------------------------

void test_nonce_construction():
	int iv_len = 0
	char* iv = tlst_unhex(c"5d313eb2671276ee13000b30", &iv_len)
	char* out = malloc(12)
	# seq 0 => nonce == iv.
	tls_nonce(iv, 0, 0, out)
	tlst_assert_hex(c"5d313eb2671276ee13000b30", out, 12)
	# Sequence touching all 8 low bytes: iv XOR 01 02 03 04 05 06 07 08.
	tls_nonce(iv, 0x01020304, 0x05060708, out)
	tlst_assert_hex(c"5d313eb2661075ea16060c38", out, 12)
	free(iv)
	free(out)


# Seal a record through the framing with tls_send_record, then read it back
# with tls_recv_record using matching keys; the payload and type must survive.
void test_record_roundtrip():
	tls_config* cfg = tls_config_new()
	tls_conn* c = tls_conn_new(0 - 1, 1, cfg)
	int i = 0
	while (i < 32):
		c.w_key[i] = i + 1
		c.r_key[i] = i + 1
		i = i + 1
	i = 0
	while (i < 12):
		c.w_iv[i] = i + 100
		c.r_iv[i] = i + 100
		i = i + 1
	c.w_active = 1
	c.r_active = 1

	char* msg = c"hello record layer"
	int mlen = strlen(msg)
	asserts(c"tls: send record", tls_send_record(c, TLS_CT_APPLICATION_DATA(), msg, mlen, 1) != 0)
	int reclen = 0
	char* rec = tls_mem_take_output(c, &reclen)
	tls_mem_feed(c, rec, reclen)
	int rtype = 0
	char* data = 0
	int dlen = 0
	asserts(c"tls: recv record", tls_recv_record(c, &rtype, &data, &dlen) != 0)
	assert_equal(TLS_CT_APPLICATION_DATA(), rtype)
	assert_equal(mlen, dlen)
	char* want = tlst_hex(msg, mlen)
	tlst_assert_hex(want, data, dlen)
	free(want)
	free(data)
	free(rec)
	tls_conn_free(c)
	tls_config_free(cfg)


# A handshake message split across two records must reassemble.
void test_fragmented_handshake():
	tls_config* cfg = tls_config_new()
	tls_conn* c = tls_conn_new(0 - 1, 1, cfg)
	# Message: EncryptedExtensions header (08 00 00 10) + 16 body bytes.
	char* m = malloc(20)
	m[0] = 8
	m[1] = 0
	m[2] = 0
	m[3] = 16
	int i = 0
	while (i < 16):
		m[4 + i] = i
		i = i + 1
	char* r1 = malloc(13)
	r1[0] = 22
	r1[1] = 3
	r1[2] = 3
	r1[3] = 0
	r1[4] = 8
	i = 0
	while (i < 8):
		r1[5 + i] = m[i]
		i = i + 1
	char* r2 = malloc(17)
	r2[0] = 22
	r2[1] = 3
	r2[2] = 3
	r2[3] = 0
	r2[4] = 12
	i = 0
	while (i < 12):
		r2[5 + i] = m[8 + i]
		i = i + 1
	tls_mem_feed(c, r1, 13)
	tls_mem_feed(c, r2, 17)

	int htype = 0
	char* hmsg = 0
	int hlen = 0
	asserts(c"tls: reassemble", tls_next_hs_msg(c, &htype, &hmsg, &hlen) != 0)
	assert_equal(8, htype)
	assert_equal(20, hlen)
	char* want = tlst_hex(m, 20)
	tlst_assert_hex(want, hmsg, hlen)
	free(want)

	free(m)
	free(r1)
	free(r2)
	tls_conn_free(c)
	tls_config_free(cfg)


# A record whose length field exceeds the ciphertext cap is rejected.
void test_max_length_enforced():
	tls_config* cfg = tls_config_new()
	tls_conn* c = tls_conn_new(0 - 1, 1, cfg)
	# Header advertising 0x4200 = 16896 > 16640 bytes.
	char* hdr = malloc(5)
	hdr[0] = 23
	hdr[1] = 3
	hdr[2] = 3
	hdr[3] = 0x42
	hdr[4] = 0x00
	tls_mem_feed(c, hdr, 5)
	int rtype = 0
	char* data = 0
	int dlen = 0
	assert_equal(0, tls_recv_record(c, &rtype, &data, &dlen))
	assert_equal(1, c.broken)
	free(hdr)
	tls_conn_free(c)
	tls_config_free(cfg)


# ---- negative / fail-closed ---------------------------------------------------

# A single flipped byte in the server Finished verify_data must fail closed.
void test_bad_server_finished():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tlst_replay_config(ch, ch_len, priv)
	# The server Finished verify_data is the last 32 bytes of the flight
	# plaintext; flip its last byte.
	int flen = 0
	char* flight = tlst_unhex(rfc_flight_plain_hex(), &flen)
	int off = flen - 1
	free(flight)
	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(off, 0x99, 0 - 1, &sb_len)
	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"server", cfg)
	asserts(c"tls: bad Finished must fail", c == 0)
	free(server_bytes)
	free(ch)
	free(priv)
	tls_config_free(cfg)


# Flipping a ciphertext byte in the flight record must trip bad_record_mac.
void test_tampered_record():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tlst_replay_config(ch, ch_len, priv)
	# frec index 25 is inside the ciphertext (past the 5-byte header).
	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(0 - 1, 0, 25, &sb_len)
	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"server", cfg)
	asserts(c"tls: tampered record must fail", c == 0)
	free(server_bytes)
	free(ch)
	free(priv)
	tls_config_free(cfg)


# Corrupting the CertificateVerify signature must fail even with
# insecure_skip_verify (the signature is checked independently of the chain).
void test_bad_certverify():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tlst_replay_config(ch, ch_len, priv)
	# EE (4 + 0x24 = 40) + Certificate (4 + 0x1b9 = 445) + CertVerify header (4)
	# + scheme (2) + siglen (2) = 493; +10 lands inside the signature.
	int cv_sig_off = 40 + 445 + 8 + 10
	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(cv_sig_off, 0x00, 0 - 1, &sb_len)
	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"server", cfg)
	asserts(c"tls: bad CertificateVerify must fail", c == 0)
	free(server_bytes)
	free(ch)
	free(priv)
	tls_config_free(cfg)


# With verification ON (default), the self-signed RFC test certificate does
# not chain to any system trust anchor, so the handshake fails closed.
void test_chain_verification_fails():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 0        # verification ON
	cfg.test_accept_any_cipher = 1
	cfg.has_now_unix = 1
	cfg.now_unix = 1500000000           # 2017, inside the cert's validity
	cfg.test_priv = priv
	cfg.test_client_hello = ch
	cfg.test_client_hello_len = ch_len
	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(0 - 1, 0, 0 - 1, &sb_len)
	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"rsa", cfg)
	asserts(c"tls: untrusted chain must fail", c == 0)
	free(server_bytes)
	free(ch)
	free(priv)
	tls_config_free(cfg)


# A fatal alert in place of the ServerHello tears the handshake down cleanly.
void test_fatal_alert():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tlst_replay_config(ch, ch_len, priv)
	# Plaintext alert record: level fatal (2), description handshake_failure (40).
	char* alert = malloc(7)
	alert[0] = 21
	alert[1] = 3
	alert[2] = 3
	alert[3] = 0
	alert[4] = 2
	alert[5] = 2
	alert[6] = 40
	tls_conn* c = tls_connect_mem(alert, 7, c"server", cfg)
	asserts(c"tls: fatal alert must fail", c == 0)
	asserts(c"tls: alert error surfaced", tls_last_error(cfg) != 0)
	free(alert)
	free(ch)
	free(priv)
	tls_config_free(cfg)


# A ServerHello negotiating a non-ChaCha suite is rejected by default (no
# test_accept_any_cipher): our client offers only TLS_CHACHA20_POLY1305_SHA256.
void test_non_chacha_suite_rejected():
	int ch_len = 0
	char* ch = tlst_unhex(rfc_client_hello_hex(), &ch_len)
	int priv_len = 0
	char* priv = tlst_unhex(rfc_client_priv_hex(), &priv_len)
	tls_config* cfg = tls_config_new()
	cfg.insecure_skip_verify = 1
	cfg.test_priv = priv
	cfg.test_client_hello = ch
	cfg.test_client_hello_len = ch_len
	# RFC 8448 ServerHello negotiates TLS_AES_128_GCM_SHA256 (0x1301).
	int sb_len = 0
	char* server_bytes = tlst_build_server_bytes(0 - 1, 0, 0 - 1, &sb_len)
	tls_conn* c = tls_connect_mem(server_bytes, sb_len, c"server", cfg)
	asserts(c"tls: non-ChaCha suite must be rejected", c == 0)
	free(server_bytes)
	free(ch)
	free(priv)
	tls_config_free(cfg)


# ---- ClientHello construction -------------------------------------------------

# The builder must produce a well-formed ClientHello: right handshake header,
# TLS 1.3 version, our single cipher suite, and an x25519 key_share carrying
# exactly the supplied public key.
void test_client_hello_build():
	char* rnd = malloc(32)
	char* sid = malloc(32)
	char* pub = malloc(32)
	int i = 0
	while (i < 32):
		rnd[i] = i
		sid[i] = 0x40 + i
		pub[i] = 0x80 + i
		i = i + 1
	int len = 0
	char* ch = tls_build_client_hello(c"example.com", rnd, sid, pub, &len)

	assert_equal(TLS_HS_CLIENT_HELLO(), ch[0] & 255)
	int body = ((ch[1] & 255) << 16) | ((ch[2] & 255) << 8) | (ch[3] & 255)
	assert_equal(len - 4, body)
	# legacy_version 0x0303 at offset 4.
	assert_equal(0x0303, ((ch[4] & 255) << 8) | (ch[5] & 255))
	# The 32-byte pubkey is the last extension's key_exchange -> last 32 bytes.
	char* want = tlst_hex(pub, 32)
	tlst_assert_hex(want, ch + len - 32, 32)
	free(want)
	# cipher_suites: length at 71..72, the single suite 0x1303 at 73..74.
	assert_equal(TLS_SUITE_CHACHA20_POLY1305_SHA256(), ((ch[73] & 255) << 8) | (ch[74] & 255))

	free(ch)
	free(rnd)
	free(sid)
	free(pub)
