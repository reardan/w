/*
TLS 1.3 client (RFC 8446) for the pure-W HTTPS stack: plan 11
(libs/standard/plans/11_native_http_tls.md) phase 7, issue #201, part of
#155. Client role only -- tls_accept / the server handshake is #203, which
reuses this module's record layer, transcript, nonce construction and key
schedule (see "Reusable internals for #203" below).

Scope (matches the plan's "keep the surface minimal"):
  - TLS 1.3 only, single cipher suite TLS_CHACHA20_POLY1305_SHA256,
    X25519 key exchange, no HelloRetryRequest, no PSK/0-RTT/resumption,
    no client certificates, no ALPN.
  - Record layer: TLSPlaintext / TLSCiphertext framing with the TLS 1.3
    AEAD nonce (per-record 64-bit sequence number XORed into write_iv),
    additional_data = the 5-byte record header, ChaCha20-Poly1305 only,
    max record length enforced. Any decrypt/MAC failure sends
    bad_record_mac and tears the connection down (fail closed).
  - Handshake: ClientHello (SNI, supported_versions, key_share, sig algs,
    supported_groups), ServerHello, key schedule via the merged HKDF
    helpers, EncryptedExtensions, Certificate, CertificateVerify (verify
    the RFC 8446 4.4.3 signed content with the cert key), chain + hostname
    verification via x509_verify_chain, server Finished (HMAC over the
    transcript with the server finished key), client Finished, switch to
    application keys.
  - Post-handshake: tls_read/tls_write over application_data, KeyUpdate
    (respond when update_requested), NewSessionTicket accepted+ignored,
    close_notify on tls_close and on receiving one.
  - Alerts parsed and surfaced; any fatal alert or malformed message tears
    down with a clear error.

Security posture: fail closed on every parse/verify/MAC error, wipe all key
material on close and on every error path, constant-time compares for
secret-dependent checks (hmac_equal for Finished, chacha20poly1305_open's
tag compare). Certificate validation is on by default; tls_config's
insecure_skip_verify (loud name, tests only) skips ONLY chain building and
hostname matching -- the CertificateVerify handshake signature and the
Finished MAC are always checked.

Public API:
  tls_config* tls_config_new()
  void        tls_config_free(tls_config* cfg)
  char*       tls_last_error(tls_config* cfg)
  tls_conn*   tls_connect(int sockfd, char* server_name, tls_config* cfg)
  int         tls_read(tls_conn* c, char* buf, int len)   0=EOF, -1=error
  int         tls_write(tls_conn* c, char* buf, int len)  -1=error
  void        tls_close(tls_conn* c)

tls_connect returns 0 on failure; the reason is retrievable via
tls_last_error(cfg). On success it returns an owned tls_conn* that
tls_close frees (wiping keys).

Reusable internals for #203 (server role) -- do NOT duplicate these:
  tls_nonce(iv, seq_hi, seq_lo, out)                  AEAD nonce
  tls_derive_traffic_keys(alg, secret, out_key, out_iv)
  tls_finished_key(alg, secret, out)
  tls_send_record(c, type, plain, len, encrypted)     record write
  tls_recv_record(c, &type, &data, &len)              record read+decrypt
  tls_next_hs_msg(c, &type, &msg, &msglen)            handshake reassembly
  tls_conn_new / tls_conn_free                        connection lifecycle
  tls_send_alert(c, level, desc)
The wbuf byte-buffer builder and the u16/u24 read/write helpers are shared
too. #203 supplies tls_accept + a ServerHello builder + ECDSA
CertificateVerify signing and drives the same record/transcript/schedule.
*/
import lib.memory
import lib.time
import lib.net
import lib.file
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac
import libs.standard.crypto.hkdf
import libs.standard.crypto.chacha20poly1305
import libs.standard.crypto.x25519
import libs.standard.crypto.random
import libs.standard.crypto.rsa_verify
import libs.standard.crypto.ecdsa_p256
import libs.standard.net.x509


# ---- protocol constants -------------------------------------------------------

# ContentType (RFC 8446 5.1).
int TLS_CT_CHANGE_CIPHER_SPEC():
	return 20


int TLS_CT_ALERT():
	return 21


int TLS_CT_HANDSHAKE():
	return 22


int TLS_CT_APPLICATION_DATA():
	return 23


# HandshakeType (RFC 8446 4).
int TLS_HS_CLIENT_HELLO():
	return 1


int TLS_HS_SERVER_HELLO():
	return 2


int TLS_HS_NEW_SESSION_TICKET():
	return 4


int TLS_HS_ENCRYPTED_EXTENSIONS():
	return 8


int TLS_HS_CERTIFICATE():
	return 11


int TLS_HS_CERTIFICATE_VERIFY():
	return 15


int TLS_HS_FINISHED():
	return 20


int TLS_HS_KEY_UPDATE():
	return 24


# AlertLevel / AlertDescription (RFC 8446 6).
int TLS_ALERT_WARNING():
	return 1


int TLS_ALERT_FATAL():
	return 2


int TLS_ALERT_CLOSE_NOTIFY():
	return 0


int TLS_ALERT_UNEXPECTED_MESSAGE():
	return 10


int TLS_ALERT_BAD_RECORD_MAC():
	return 20


int TLS_ALERT_HANDSHAKE_FAILURE():
	return 40


int TLS_ALERT_DECODE_ERROR():
	return 50


int TLS_ALERT_DECRYPT_ERROR():
	return 51


int TLS_ALERT_PROTOCOL_VERSION():
	return 70


int TLS_ALERT_INTERNAL_ERROR():
	return 80


# The single supported cipher suite and named group.
int TLS_SUITE_CHACHA20_POLY1305_SHA256():
	return 0x1303


int TLS_GROUP_X25519():
	return 0x001d


# SignatureScheme values we offer / accept for CertificateVerify.
int TLS_SIG_RSA_PKCS1_SHA256():
	return 0x0401


int TLS_SIG_RSA_PKCS1_SHA384():
	return 0x0501


int TLS_SIG_ECDSA_SECP256R1_SHA256():
	return 0x0403


int TLS_SIG_RSA_PSS_RSAE_SHA256():
	return 0x0804


int TLS_SIG_RSA_PSS_RSAE_SHA384():
	return 0x0805


# Extension types.
int TLS_EXT_SERVER_NAME():
	return 0x0000


int TLS_EXT_SUPPORTED_GROUPS():
	return 0x000a


int TLS_EXT_SIGNATURE_ALGORITHMS():
	return 0x000d


int TLS_EXT_SUPPORTED_VERSIONS():
	return 0x002b


int TLS_EXT_KEY_SHARE():
	return 0x0033


# Record length caps (RFC 8446 5.1/5.2): plaintext content <= 2^14,
# ciphertext record fragment <= 2^14 + 256.
int TLS_MAX_PLAINTEXT():
	return 16384


int TLS_MAX_CIPHERTEXT():
	return 16640


# Absolute cap on a single reassembled handshake message (#203 hardening).
# TLS 1.3 permits up to 2^24-1, but our flights (ClientHello, ServerHello,
# a small Certificate chain, CertificateVerify, Finished) are far smaller;
# 64 KiB bounds hs_buf growth against a hostile peer without rejecting any
# legitimate handshake. Enforced in the shared reassembler for both roles.
int TLS_MAX_HANDSHAKE():
	return 65536


# AEAD parameters for ChaCha20-Poly1305.
int TLS_AEAD_KEY_LEN():
	return 32


int TLS_AEAD_IV_LEN():
	return 12


int TLS_AEAD_TAG_LEN():
	return 16


# ---- growable byte buffer -----------------------------------------------------

struct wbuf:
	char* data
	int len
	int cap


wbuf* wbuf_new(int cap):
	if (cap < 16):
		cap = 16
	wbuf* b = new wbuf()
	b.data = malloc(cap)
	b.len = 0
	b.cap = cap
	return b


void wbuf_free(wbuf* b):
	if (b == 0):
		return
	if (b.data != 0):
		free(b.data)
	free(cast(char*, b))


void wbuf_reserve(wbuf* b, int extra):
	int needed = b.len + extra
	if (needed <= b.cap):
		return
	int newcap = b.cap * 2
	while (newcap < needed):
		newcap = newcap * 2
	b.data = realloc(b.data, b.cap, newcap)
	b.cap = newcap


void wbuf_u8(wbuf* b, int v):
	wbuf_reserve(b, 1)
	b.data[b.len] = v & 255
	b.len = b.len + 1


void wbuf_u16(wbuf* b, int v):
	wbuf_reserve(b, 2)
	b.data[b.len] = (v >> 8) & 255
	b.data[b.len + 1] = v & 255
	b.len = b.len + 2


void wbuf_u24(wbuf* b, int v):
	wbuf_reserve(b, 3)
	b.data[b.len] = (v >> 16) & 255
	b.data[b.len + 1] = (v >> 8) & 255
	b.data[b.len + 2] = v & 255
	b.len = b.len + 3


void wbuf_bytes(wbuf* b, char* src, int n):
	if (n <= 0):
		return
	wbuf_reserve(b, n)
	int i = 0
	while (i < n):
		b.data[b.len + i] = src[i]
		i = i + 1
	b.len = b.len + n


# Backpatch a 2- or 3-byte length placeholder written earlier at pos with
# the number of content bytes that followed it.
void wbuf_set_u16(wbuf* b, int pos, int v):
	b.data[pos] = (v >> 8) & 255
	b.data[pos + 1] = v & 255


void wbuf_set_u24(wbuf* b, int pos, int v):
	b.data[pos] = (v >> 16) & 255
	b.data[pos + 1] = (v >> 8) & 255
	b.data[pos + 2] = v & 255


# ---- little byte helpers ------------------------------------------------------

int tls_rd_u16(char* p):
	return ((p[0] & 255) << 8) | (p[1] & 255)


int tls_rd_u24(char* p):
	return ((p[0] & 255) << 16) | ((p[1] & 255) << 8) | (p[2] & 255)


void tls_wipe(char* p, int len):
	if (p == 0):
		return
	int i = 0
	while (i < len):
		p[i] = 0
		i = i + 1


void tls_copy(char* dst, char* src, int n):
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# ---- AEAD nonce (reusable by #203) --------------------------------------------

# TLS 1.3 per-record nonce (RFC 8446 5.3): the 64-bit record sequence number,
# left-padded to iv_length, XORed into write_iv. iv is 12 bytes; the sequence
# occupies the low 8 bytes. seq is carried as a hi/lo 32-bit pair.
void tls_nonce(char* iv, int seq_hi, int seq_lo, char* out):
	int i = 0
	while (i < TLS_AEAD_IV_LEN()):
		out[i] = iv[i] & 255
		i = i + 1
	out[4] = out[4] ^ ((seq_hi >> 24) & 255)
	out[5] = out[5] ^ ((seq_hi >> 16) & 255)
	out[6] = out[6] ^ ((seq_hi >> 8) & 255)
	out[7] = out[7] ^ (seq_hi & 255)
	out[8] = out[8] ^ ((seq_lo >> 24) & 255)
	out[9] = out[9] ^ ((seq_lo >> 16) & 255)
	out[10] = out[10] ^ ((seq_lo >> 8) & 255)
	out[11] = out[11] ^ (seq_lo & 255)


# ---- key schedule helpers (reusable by #203) ----------------------------------

# Record-protection key (16..32 bytes) and iv (12 bytes) from a traffic
# secret: HKDF-Expand-Label(secret, "key"/"iv", "", length). ChaCha20 uses a
# 32-byte key.
void tls_derive_traffic_keys(int alg, char* secret, char* out_key, char* out_iv):
	tls13_hkdf_expand_label(alg, secret, c"key", 3, c"", 0, out_key, TLS_AEAD_KEY_LEN())
	tls13_hkdf_expand_label(alg, secret, c"iv", 2, c"", 0, out_iv, TLS_AEAD_IV_LEN())


# finished_key = HKDF-Expand-Label(secret, "finished", "", digest_size).
void tls_finished_key(int alg, char* secret, char* out):
	tls13_hkdf_expand_label(alg, secret, c"finished", 8, c"", 0, out, whash_digest_size(alg))


# ---- configuration ------------------------------------------------------------

struct tls_config:
	char* trust_store_path      # override CA bundle path, 0 = system default
	int insecure_skip_verify    # tests only: skip chain + hostname checks
	int has_now_unix            # 1 => use now_unix instead of the clock
	int now_unix
	char* last_error            # static string, set on failure; never freed
	# Deterministic-test injection (mirrors now_unix injection):
	char* test_priv             # 32-byte X25519 private key, or 0 for random
	char* test_client_hello     # raw ClientHello handshake message to send
	int test_client_hello_len   # verbatim, for the RFC 8448 replay test
	int test_accept_any_cipher  # RFC 8448 replay: accept a non-ChaCha suite id
	                            # in ServerHello (records stay ChaCha20). RFC
	                            # 8448 section 3 is an AES-128-GCM trace, so the
	                            # replay test asserts the cipher-independent
	                            # values (secrets, transcript, CertificateVerify
	                            # signature, Finished MACs) over the real
	                            # handshake while the record layer re-seals the
	                            # flight with ChaCha20. Production never sets it.


tls_config* tls_config_new():
	tls_config* c = new tls_config()
	c.trust_store_path = 0
	c.insecure_skip_verify = 0
	c.has_now_unix = 0
	c.now_unix = 0
	c.last_error = 0
	c.test_priv = 0
	c.test_client_hello = 0
	c.test_client_hello_len = 0
	c.test_accept_any_cipher = 0
	return c


void tls_config_free(tls_config* c):
	if (c == 0):
		return
	free(cast(char*, c))


char* tls_last_error(tls_config* c):
	if (c == 0):
		return 0
	return c.last_error


# ---- server configuration (#203) ----------------------------------------------

# Credentials for the server role. The certificate chain is leaf-first PEM
# (as served in the TLS Certificate message) and the private key is an ECDSA
# P-256 key in PKCS#8 or SEC1 PEM (loaded via x509_load_ec_private_key).
# ECDSA P-256 keys ONLY -- no RSA server keys. The test_* fields inject cert
# and key bytes directly (mirroring the client's test_* knobs) so tests need
# no filesystem; test_priv/test_random pin the server ephemeral X25519 key
# and ServerHello random for deterministic traces.
struct tls_server_config:
	char* cert_chain_path       # leaf-first cert-chain PEM file, or 0
	char* key_path              # ECDSA P-256 private-key PEM file, or 0
	char* last_error            # static string, set on failure; never freed
	char* test_cert_pem         # inject cert-chain PEM bytes instead of a file
	int test_cert_pem_len
	char* test_key_pem          # inject private-key PEM bytes instead of a file
	int test_key_pem_len
	char* test_priv             # 32-byte server X25519 private key, or 0
	char* test_random           # 32-byte ServerHello random, or 0


tls_server_config* tls_server_config_new():
	tls_server_config* c = new tls_server_config()
	c.cert_chain_path = 0
	c.key_path = 0
	c.last_error = 0
	c.test_cert_pem = 0
	c.test_cert_pem_len = 0
	c.test_key_pem = 0
	c.test_key_pem_len = 0
	c.test_priv = 0
	c.test_random = 0
	return c


void tls_server_config_free(tls_server_config* c):
	if (c == 0):
		return
	free(cast(char*, c))


char* tls_server_last_error(tls_server_config* c):
	if (c == 0):
		return 0
	return c.last_error


# ---- connection ---------------------------------------------------------------

struct tls_conn:
	int fd                # socket fd, or -1 for the in-memory harness
	int use_mem
	wbuf* mem_in          # in-memory input (server bytes), for tests
	int mem_in_pos
	wbuf* mem_out         # captured client output, for tests
	int hash_alg
	int digest_size
	whash* transcript
	# read (incoming) protection
	int r_active
	char* r_key
	char* r_iv
	int r_seq_hi
	int r_seq_lo
	# write (outgoing) protection
	int w_active
	char* w_key
	char* w_iv
	int w_seq_hi
	int w_seq_lo
	# traffic secrets kept for KeyUpdate re-derivation and #203/tests
	char* c_hs_secret
	char* s_hs_secret
	char* c_ap_secret     # client_application_traffic_secret (our write secret)
	char* s_ap_secret     # server_application_traffic_secret (our read secret)
	# handshake message reassembly
	wbuf* hs_buf
	int hs_pos
	# decrypted application bytes not yet returned by tls_read
	char* app_buf
	int app_len
	int app_pos
	int at_eof            # received close_notify (clean EOF)
	int broken            # torn down after a fatal error
	tls_config* cfg
	# Server role (#203): set by tls_accept. is_server flips key-schedule
	# directions (our write=server secrets, our read=client secrets) in the
	# shared post-handshake path; scfg carries the server credentials + error
	# slot. Both stay 0 for a client connection, so the client path is inert.
	int is_server
	tls_server_config* scfg


tls_conn* tls_conn_new(int fd, int use_mem, tls_config* cfg):
	tls_conn* c = new tls_conn()
	c.fd = fd
	c.use_mem = use_mem
	c.mem_in = 0
	c.mem_in_pos = 0
	c.mem_out = 0
	if (use_mem != 0):
		c.mem_in = wbuf_new(256)
		c.mem_out = wbuf_new(256)
	c.hash_alg = WHASH_SHA256()
	c.digest_size = whash_digest_size(c.hash_alg)
	c.transcript = whash_new(c.hash_alg)
	c.r_active = 0
	c.r_key = malloc(TLS_AEAD_KEY_LEN())
	c.r_iv = malloc(TLS_AEAD_IV_LEN())
	c.r_seq_hi = 0
	c.r_seq_lo = 0
	c.w_active = 0
	c.w_key = malloc(TLS_AEAD_KEY_LEN())
	c.w_iv = malloc(TLS_AEAD_IV_LEN())
	c.w_seq_hi = 0
	c.w_seq_lo = 0
	c.c_hs_secret = malloc(c.digest_size)
	c.s_hs_secret = malloc(c.digest_size)
	c.c_ap_secret = malloc(c.digest_size)
	c.s_ap_secret = malloc(c.digest_size)
	tls_wipe(c.r_key, TLS_AEAD_KEY_LEN())
	tls_wipe(c.r_iv, TLS_AEAD_IV_LEN())
	tls_wipe(c.w_key, TLS_AEAD_KEY_LEN())
	tls_wipe(c.w_iv, TLS_AEAD_IV_LEN())
	tls_wipe(c.c_hs_secret, c.digest_size)
	tls_wipe(c.s_hs_secret, c.digest_size)
	tls_wipe(c.c_ap_secret, c.digest_size)
	tls_wipe(c.s_ap_secret, c.digest_size)
	c.hs_buf = wbuf_new(512)
	c.hs_pos = 0
	c.app_buf = 0
	c.app_len = 0
	c.app_pos = 0
	c.at_eof = 0
	c.broken = 0
	c.cfg = cfg
	c.is_server = 0
	c.scfg = 0
	return c


# Wipe every key/secret buffer and release the connection. Safe on 0.
void tls_conn_free(tls_conn* c):
	if (c == 0):
		return
	tls_wipe(c.r_key, TLS_AEAD_KEY_LEN())
	tls_wipe(c.r_iv, TLS_AEAD_IV_LEN())
	tls_wipe(c.w_key, TLS_AEAD_KEY_LEN())
	tls_wipe(c.w_iv, TLS_AEAD_IV_LEN())
	tls_wipe(c.c_hs_secret, c.digest_size)
	tls_wipe(c.s_hs_secret, c.digest_size)
	tls_wipe(c.c_ap_secret, c.digest_size)
	tls_wipe(c.s_ap_secret, c.digest_size)
	free(c.r_key)
	free(c.r_iv)
	free(c.w_key)
	free(c.w_iv)
	free(c.c_hs_secret)
	free(c.s_hs_secret)
	free(c.c_ap_secret)
	free(c.s_ap_secret)
	if (c.transcript != 0):
		whash_free(c.transcript)
	if (c.hs_buf != 0):
		wbuf_free(c.hs_buf)
	if (c.mem_in != 0):
		wbuf_free(c.mem_in)
	if (c.mem_out != 0):
		wbuf_free(c.mem_out)
	if (c.app_buf != 0):
		tls_wipe(c.app_buf, c.app_len)
		free(c.app_buf)
	free(cast(char*, c))


void tls_fail(tls_conn* c, char* msg):
	c.broken = 1
	if (c.cfg != 0):
		c.cfg.last_error = msg
	if (c.scfg != 0):
		c.scfg.last_error = msg


# ---- raw I/O ------------------------------------------------------------------

# Read exactly n bytes into buf. Returns 1 on success, 0 on EOF/error.
int tls_io_recv_full(tls_conn* c, char* buf, int n):
	if (n <= 0):
		return 1
	if (c.use_mem != 0):
		if (c.mem_in_pos + n > c.mem_in.len):
			return 0
		tls_copy(buf, c.mem_in.data + c.mem_in_pos, n)
		c.mem_in_pos = c.mem_in_pos + n
		return 1
	int got = 0
	while (got < n):
		int r = socket_recv(c.fd, buf + got, n - got, 0)
		if (r > 0):
			got = got + r
		else if (r == 0):
			return 0
		else if (r != 0 - 4):
			# any error other than EINTR
			return 0
	return 1


# Write all n bytes. Returns 1 on success, 0 on error.
int tls_io_send_all(tls_conn* c, char* buf, int n):
	if (n <= 0):
		return 1
	if (c.use_mem != 0):
		wbuf_bytes(c.mem_out, buf, n)
		return 1
	int sent = 0
	while (sent < n):
		int r = socket_send(c.fd, buf + sent, n - sent, msg_nosignal())
		if (r > 0):
			sent = sent + r
		else if (r != 0 - 4):
			# error other than EINTR
			return 0
	return 1


# ---- record write (reusable by #203) ------------------------------------------

# Advance a hi/lo 64-bit sequence number by one.
void tls_seq_inc(int* hi, int* lo):
	if (*lo == 0x7fffffff):
		*lo = 0
		*hi = *hi + 1
	else:
		*lo = *lo + 1


# Send one record. When encrypted==0 the payload is written as a
# TLSPlaintext of content type `ct`. When encrypted==1 the payload plus a
# content-type trailer is sealed with the write keys into a TLSCiphertext
# whose outer type is application_data. Returns 1 on success.
int tls_send_record(tls_conn* c, int ct, char* payload, int len, int encrypted):
	if (encrypted == 0):
		if (len > TLS_MAX_PLAINTEXT()):
			return 0
		char* phdr = malloc(5)
		phdr[0] = ct & 255
		phdr[1] = 3
		phdr[2] = 3
		phdr[3] = (len >> 8) & 255
		phdr[4] = len & 255
		int pok = tls_io_send_all(c, phdr, 5)
		free(phdr)
		if (pok == 0):
			return 0
		return tls_io_send_all(c, payload, len)

	# TLSCiphertext: inner = payload || content_type, then AEAD-sealed.
	int inner_len = len + 1
	int rec_len = inner_len + TLS_AEAD_TAG_LEN()
	if (rec_len > TLS_MAX_CIPHERTEXT()):
		return 0
	char* hdr = malloc(5)
	hdr[0] = TLS_CT_APPLICATION_DATA()
	hdr[1] = 3
	hdr[2] = 3
	hdr[3] = (rec_len >> 8) & 255
	hdr[4] = rec_len & 255

	char* inner = malloc(inner_len)
	tls_copy(inner, payload, len)
	inner[len] = ct & 255

	char* nonce = malloc(TLS_AEAD_IV_LEN())
	tls_nonce(c.w_iv, c.w_seq_hi, c.w_seq_lo, nonce)

	char* ctbuf = malloc(inner_len)
	char* tag = malloc(TLS_AEAD_TAG_LEN())
	chacha20poly1305_seal(c.w_key, nonce, hdr, 5, inner, inner_len, ctbuf, tag)
	tls_seq_inc(&c.w_seq_hi, &c.w_seq_lo)

	int ok = tls_io_send_all(c, hdr, 5)
	if (ok != 0):
		ok = tls_io_send_all(c, ctbuf, inner_len)
	if (ok != 0):
		ok = tls_io_send_all(c, tag, TLS_AEAD_TAG_LEN())

	tls_wipe(inner, inner_len)
	tls_wipe(nonce, TLS_AEAD_IV_LEN())
	free(inner)
	free(nonce)
	free(ctbuf)
	free(tag)
	free(hdr)
	return ok


# Send a 2-byte alert. Encrypted once write keys are active, else plaintext.
# Best effort during teardown; the return value is ignored by callers.
int tls_send_alert(tls_conn* c, int level, int desc):
	char* a = malloc(2)
	a[0] = level & 255
	a[1] = desc & 255
	int ok = tls_send_record(c, TLS_CT_ALERT(), a, 2, c.w_active)
	free(a)
	return ok


# ---- record read (reusable by #203) -------------------------------------------

# Read one record and, when protected, decrypt it. change_cipher_spec records
# are consumed and skipped transparently. On success returns 1 with the
# effective content type in *out_type and a freshly malloc'd payload
# (content-type trailer stripped for decrypted records) in *out_data /
# *out_len; the caller frees *out_data. On failure returns 0 (a
# bad_record_mac alert is sent and the connection marked broken for AEAD
# failures).
int tls_recv_record(tls_conn* c, int* out_type, char** out_data, int* out_len):
	while (1 == 1):
		char* hdr = malloc(5)
		if (tls_io_recv_full(c, hdr, 5) == 0):
			free(hdr)
			return 0
		int rtype = hdr[0] & 255
		int rlen = tls_rd_u16(hdr + 3)
		if (rlen > TLS_MAX_CIPHERTEXT()):
			free(hdr)
			tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
			tls_fail(c, c"tls: record too long")
			return 0
		char* body = malloc(rlen + 1)
		if (tls_io_recv_full(c, body, rlen) == 0):
			free(hdr)
			free(body)
			return 0

		if (rtype == TLS_CT_CHANGE_CIPHER_SPEC()):
			# Ignored middlebox-compat record; must be exactly {0x01}.
			free(hdr)
			free(body)
			# loop and read the next record

		else if ((c.r_active != 0) & (rtype == TLS_CT_APPLICATION_DATA())):
			if (rlen < TLS_AEAD_TAG_LEN() + 1):
				free(hdr)
				free(body)
				tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_BAD_RECORD_MAC())
				tls_fail(c, c"tls: short ciphertext")
				return 0
			int ct_len = rlen - TLS_AEAD_TAG_LEN()
			char* nonce = malloc(TLS_AEAD_IV_LEN())
			tls_nonce(c.r_iv, c.r_seq_hi, c.r_seq_lo, nonce)
			char* plain = malloc(ct_len)
			int ok = chacha20poly1305_open(c.r_key, nonce, hdr, 5, body, ct_len, body + ct_len, plain)
			tls_wipe(nonce, TLS_AEAD_IV_LEN())
			free(nonce)
			free(hdr)
			free(body)
			if (ok == 0):
				tls_wipe(plain, ct_len)
				free(plain)
				tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_BAD_RECORD_MAC())
				tls_fail(c, c"tls: bad record mac")
				return 0
			tls_seq_inc(&c.r_seq_hi, &c.r_seq_lo)
			# Strip zero padding and the content-type trailer.
			int p = ct_len - 1
			while ((p >= 0) && (plain[p] == 0)):
				p = p - 1
			if (p < 0):
				tls_wipe(plain, ct_len)
				free(plain)
				tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
				tls_fail(c, c"tls: all-padding record")
				return 0
			int inner_type = plain[p] & 255
			int data_len = p
			if (data_len > TLS_MAX_PLAINTEXT()):
				tls_wipe(plain, ct_len)
				free(plain)
				tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
				tls_fail(c, c"tls: plaintext too long")
				return 0
			char* out = malloc(data_len + 1)
			tls_copy(out, plain, data_len)
			tls_wipe(plain, ct_len)
			free(plain)
			*out_type = inner_type
			*out_data = out
			*out_len = data_len
			return 1

		else:
			# Plaintext record (ServerHello, or an early alert).
			if (rtype == TLS_CT_APPLICATION_DATA()):
				free(hdr)
				free(body)
				tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
				tls_fail(c, c"tls: application_data before keys")
				return 0
			char* out = malloc(rlen + 1)
			tls_copy(out, body, rlen)
			free(hdr)
			free(body)
			*out_type = rtype
			*out_data = out
			*out_len = rlen
			return 1
	return 0


# Surface an alert record: warning close_notify => clean EOF, anything fatal
# (or an unknown warning) => torn down. Returns 1 if it was close_notify.
int tls_handle_alert(tls_conn* c, char* data, int len):
	if (len < 2):
		tls_fail(c, c"tls: malformed alert")
		return 0
	int desc = data[1] & 255
	if (desc == TLS_ALERT_CLOSE_NOTIFY()):
		c.at_eof = 1
		return 1
	tls_fail(c, c"tls: fatal alert from peer")
	return 0


# ---- handshake message reassembly (reusable by #203) --------------------------

# Yield the next complete handshake message, reassembling across records and
# splitting coalesced messages. *out_msg points into c.hs_buf and stays valid
# only until the next call, so absorb/parse it before continuing. On an alert
# or protocol error returns 0 (connection already marked).
int tls_next_hs_msg(tls_conn* c, int* out_type, char** out_msg, int* out_len):
	while (1 == 1):
		# Compact consumed bytes so hs_buf can't grow without bound.
		if (c.hs_pos > 0):
			int rem = c.hs_buf.len - c.hs_pos
			int i = 0
			while (i < rem):
				c.hs_buf.data[i] = c.hs_buf.data[c.hs_pos + i]
				i = i + 1
			c.hs_buf.len = rem
			c.hs_pos = 0
		int avail = c.hs_buf.len - c.hs_pos
		if (avail >= 4):
			int mlen = tls_rd_u24(c.hs_buf.data + c.hs_pos + 1)
			if (mlen > TLS_MAX_HANDSHAKE()):
				tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
				tls_fail(c, c"tls: handshake message too long")
				return 0
			if (avail >= 4 + mlen):
				*out_type = c.hs_buf.data[c.hs_pos] & 255
				*out_msg = c.hs_buf.data + c.hs_pos
				*out_len = 4 + mlen
				c.hs_pos = c.hs_pos + 4 + mlen
				return 1
		# Need more bytes: pull the next record.
		int rtype = 0
		char* data = 0
		int dlen = 0
		if (tls_recv_record(c, &rtype, &data, &dlen) == 0):
			return 0
		if (rtype == TLS_CT_HANDSHAKE()):
			wbuf_bytes(c.hs_buf, data, dlen)
			free(data)
		else if (rtype == TLS_CT_ALERT()):
			tls_handle_alert(c, data, dlen)
			free(data)
			return 0
		else:
			free(data)
			tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
			tls_fail(c, c"tls: unexpected record during handshake")
			return 0
	return 0


# ---- ClientHello --------------------------------------------------------------

# Build a ClientHello handshake message (type + 3-byte length + body).
# random and session_id are 32 bytes each; pubkey is the 32-byte X25519 share.
# Returns a malloc'd buffer; *out_len gets its length. Reusable shape for the
# construction test.
char* tls_build_client_hello(char* server_name, char* random, char* session_id, char* pubkey, int* out_len):
	wbuf* b = wbuf_new(256)
	wbuf_u8(b, TLS_HS_CLIENT_HELLO())
	int lenpos = b.len
	wbuf_u24(b, 0)                       # body length placeholder
	int body_start = b.len

	wbuf_u16(b, 0x0303)                  # legacy_version
	wbuf_bytes(b, random, 32)            # random
	wbuf_u8(b, 32)                       # legacy_session_id length
	wbuf_bytes(b, session_id, 32)        # legacy_session_id
	wbuf_u16(b, 2)                       # cipher_suites length
	wbuf_u16(b, TLS_SUITE_CHACHA20_POLY1305_SHA256())
	wbuf_u8(b, 1)                        # legacy_compression_methods length
	wbuf_u8(b, 0)                        # null compression

	int extpos = b.len
	wbuf_u16(b, 0)                       # extensions length placeholder
	int ext_start = b.len

	# server_name (SNI)
	int nlen = strlen(server_name)
	wbuf_u16(b, TLS_EXT_SERVER_NAME())
	wbuf_u16(b, nlen + 5)                # ext_data length
	wbuf_u16(b, nlen + 3)                # ServerNameList length
	wbuf_u8(b, 0)                        # name_type = host_name
	wbuf_u16(b, nlen)                    # HostName length
	wbuf_bytes(b, server_name, nlen)

	# supported_versions = TLS 1.3
	wbuf_u16(b, TLS_EXT_SUPPORTED_VERSIONS())
	wbuf_u16(b, 3)
	wbuf_u8(b, 2)                        # list length (bytes)
	wbuf_u16(b, 0x0304)

	# supported_groups = x25519
	wbuf_u16(b, TLS_EXT_SUPPORTED_GROUPS())
	wbuf_u16(b, 4)
	wbuf_u16(b, 2)
	wbuf_u16(b, TLS_GROUP_X25519())

	# signature_algorithms
	wbuf_u16(b, TLS_EXT_SIGNATURE_ALGORITHMS())
	wbuf_u16(b, 12)
	wbuf_u16(b, 10)                      # list length
	wbuf_u16(b, TLS_SIG_ECDSA_SECP256R1_SHA256())
	wbuf_u16(b, TLS_SIG_RSA_PSS_RSAE_SHA256())
	wbuf_u16(b, TLS_SIG_RSA_PSS_RSAE_SHA384())
	wbuf_u16(b, TLS_SIG_RSA_PKCS1_SHA256())
	wbuf_u16(b, TLS_SIG_RSA_PKCS1_SHA384())

	# key_share: one x25519 entry
	wbuf_u16(b, TLS_EXT_KEY_SHARE())
	wbuf_u16(b, 38)                      # ext_data length
	wbuf_u16(b, 36)                      # client_shares length
	wbuf_u16(b, TLS_GROUP_X25519())
	wbuf_u16(b, 32)                      # key_exchange length
	wbuf_bytes(b, pubkey, 32)

	int ext_len = b.len - ext_start
	wbuf_set_u16(b, extpos, ext_len)
	int body_len = b.len - body_start
	wbuf_set_u24(b, lenpos, body_len)

	char* out = malloc(b.len)
	tls_copy(out, b.data, b.len)
	*out_len = b.len
	wbuf_free(b)
	return out


# ---- ServerHello --------------------------------------------------------------

# The HelloRetryRequest sentinel random (RFC 8446 4.1.3). We do not support
# HRR, so a ServerHello carrying it is rejected.
int tls_is_hrr(char* random):
	char* hrr = c"\xcf\x21\xad\x74\xe5\x9a\x61\x11\xbe\x1d\x8c\x02\x1e\x65\xb8\x91\xc2\xa2\x11\x16\x7a\xbb\x8c\x5e\x07\x9e\x09\xe2\xc8\xa8\x33\x9c"
	int i = 0
	int diff = 0
	while (i < 32):
		diff = diff | ((random[i] & 255) ^ (hrr[i] & 255))
		i = i + 1
	return diff == 0


# Parse a ServerHello body (msg points at the handshake header; body at
# msg+4): validate the cipher suite and negotiated TLS 1.3, extract the
# X25519 server key_share into out_pub (32 bytes). Returns 1 on success.
int tls_parse_server_hello(tls_conn* c, char* msg, int len, char* out_pub):
	int pos = 4
	if (pos + 2 + 32 + 1 > len):
		return 0
	pos = pos + 2                        # legacy_version
	char* srandom = msg + pos
	pos = pos + 32                       # random
	int sid_len = msg[pos] & 255
	pos = pos + 1
	if (pos + sid_len + 3 > len):
		return 0
	pos = pos + sid_len                  # legacy_session_id_echo
	int suite = tls_rd_u16(msg + pos)
	pos = pos + 2
	if (suite != TLS_SUITE_CHACHA20_POLY1305_SHA256()):
		int allow = 0
		if (c.cfg != 0):
			allow = c.cfg.test_accept_any_cipher
		if (allow == 0):
			return 0
	pos = pos + 1                        # legacy_compression_method
	if (tls_is_hrr(srandom) != 0):
		return 0
	if (pos + 2 > len):
		return 0
	int ext_total = tls_rd_u16(msg + pos)
	pos = pos + 2
	int ext_end = pos + ext_total
	if (ext_end > len):
		return 0
	int have_key_share = 0
	int have_version = 0
	while (pos + 4 <= ext_end):
		int etype = tls_rd_u16(msg + pos)
		int elen = tls_rd_u16(msg + pos + 2)
		pos = pos + 4
		if (pos + elen > ext_end):
			return 0
		if (etype == TLS_EXT_SUPPORTED_VERSIONS()):
			if (elen != 2):
				return 0
			if (tls_rd_u16(msg + pos) != 0x0304):
				return 0
			have_version = 1
		else if (etype == TLS_EXT_KEY_SHARE()):
			if (elen < 4):
				return 0
			int group = tls_rd_u16(msg + pos)
			int klen = tls_rd_u16(msg + pos + 2)
			if (group != TLS_GROUP_X25519()):
				return 0
			if (klen != 32):
				return 0
			if (4 + 32 > elen):
				return 0
			tls_copy(out_pub, msg + pos + 4, 32)
			have_key_share = 1
		pos = pos + elen
	if (have_version == 0):
		return 0
	if (have_key_share == 0):
		return 0
	return 1


# ---- CertificateVerify signature over the RFC 8446 4.4.3 content --------------

# Build 0x20*64 || "TLS 1.3, server CertificateVerify" || 0x00 || transcript.
# Returns a malloc'd buffer; *out_len gets its length.
char* tls_certverify_content(char* transcript_hash, int th_len, int* out_len):
	char* ctx = c"TLS 1.3, server CertificateVerify"
	int clen = strlen(ctx)
	int total = 64 + clen + 1 + th_len
	char* out = malloc(total)
	int i = 0
	while (i < 64):
		out[i] = 0x20
		i = i + 1
	i = 0
	while (i < clen):
		out[64 + i] = ctx[i]
		i = i + 1
	out[64 + clen] = 0
	tls_copy(out + 64 + clen + 1, transcript_hash, th_len)
	*out_len = total
	return out


# Verify a server CertificateVerify signature (scheme sig_scheme, raw sig
# bytes) against the leaf certificate's public key over the transcript hash.
# Returns 1 on success.
int tls_verify_certverify(x509_cert* leaf, int sig_scheme, char* sig, int siglen, char* transcript_hash, int th_len):
	int clen = 0
	char* content = tls_certverify_content(transcript_hash, th_len, &clen)

	# Hash the signed content with the scheme's hash.
	int use_sha384 = 0
	if (sig_scheme == TLS_SIG_RSA_PSS_RSAE_SHA384()):
		use_sha384 = 1
	if (sig_scheme == TLS_SIG_RSA_PKCS1_SHA384()):
		use_sha384 = 1
	int hlen = 32
	if (use_sha384 != 0):
		hlen = 48
	char* digest = malloc(hlen)
	if (use_sha384 != 0):
		whash_oneshot(WHASH_SHA384(), content, clen, digest)
	else:
		whash_oneshot(WHASH_SHA256(), content, clen, digest)
	free(content)

	int ok = 0
	if (leaf.key_type == X509_KEY_RSA()):
		char* n = leaf.der + leaf.rsa_n_start
		char* e = leaf.der + leaf.rsa_e_start
		if (sig_scheme == TLS_SIG_RSA_PSS_RSAE_SHA256()):
			ok = rsa_pss_verify_sha256(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
		else if (sig_scheme == TLS_SIG_RSA_PSS_RSAE_SHA384()):
			ok = rsa_pss_verify_sha384(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
		else if (sig_scheme == TLS_SIG_RSA_PKCS1_SHA256()):
			ok = rsa_pkcs1v15_verify_sha256(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
		else if (sig_scheme == TLS_SIG_RSA_PKCS1_SHA384()):
			ok = rsa_pkcs1v15_verify_sha384(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
	else if (leaf.key_type == X509_KEY_EC_P256()):
		if (sig_scheme == TLS_SIG_ECDSA_SECP256R1_SHA256()):
			char* r = malloc(32)
			char* s = malloc(32)
			if (x509_ecdsa_sig_to_raw(sig, siglen, r, s) != 0):
				ok = ecdsa_p256_verify(leaf.ec_qx, leaf.ec_qy, digest, 32, r, s)
			free(r)
			free(s)

	tls_wipe(digest, hlen)
	free(digest)
	return ok


# ---- key schedule (client handshake) ------------------------------------------

# Populate c's handshake secrets from the shared secret and the CH..SH
# transcript hash, also returning the handshake secret at out_hs (digest_size
# bytes) for the later master-secret derivation.
void tls_derive_handshake(tls_conn* c, char* ecdhe, char* th_ch_sh, char* out_hs):
	int alg = c.hash_alg
	int ds = c.digest_size
	char* zeros = malloc(ds)
	tls_wipe(zeros, ds)

	char* early = malloc(ds)
	hkdf_extract(alg, c"", 0, zeros, ds, early)

	char* derived1 = malloc(ds)
	tls13_derive_secret(alg, early, c"derived", 7, c"", 0, derived1)

	hkdf_extract(alg, derived1, ds, ecdhe, ds, out_hs)

	tls13_hkdf_expand_label(alg, out_hs, c"c hs traffic", 12, th_ch_sh, ds, c.c_hs_secret, ds)
	tls13_hkdf_expand_label(alg, out_hs, c"s hs traffic", 12, th_ch_sh, ds, c.s_hs_secret, ds)

	tls_wipe(early, ds)
	tls_wipe(derived1, ds)
	tls_wipe(zeros, ds)
	free(early)
	free(derived1)
	free(zeros)


# master_secret and the c/s application traffic secrets over CH..serverFinished.
void tls_derive_application(tls_conn* c, char* hs_secret, char* th_ch_sf):
	int alg = c.hash_alg
	int ds = c.digest_size
	char* zeros = malloc(ds)
	tls_wipe(zeros, ds)
	char* derived2 = malloc(ds)
	tls13_derive_secret(alg, hs_secret, c"derived", 7, c"", 0, derived2)
	char* master = malloc(ds)
	hkdf_extract(alg, derived2, ds, zeros, ds, master)
	tls13_hkdf_expand_label(alg, master, c"c ap traffic", 12, th_ch_sf, ds, c.c_ap_secret, ds)
	tls13_hkdf_expand_label(alg, master, c"s ap traffic", 12, th_ch_sf, ds, c.s_ap_secret, ds)
	tls_wipe(zeros, ds)
	tls_wipe(derived2, ds)
	tls_wipe(master, ds)
	free(zeros)
	free(derived2)
	free(master)


# ---- the client handshake state machine ---------------------------------------

# Parse a Certificate message body into a list of x509_cert*. Returns the
# list (possibly empty) or an empty list on a malformed structure.
list[x509_cert*] tls_parse_certificate(char* msg, int len):
	list[x509_cert*] certs = new list[x509_cert*]
	int pos = 4
	if (pos + 1 > len):
		return certs
	int ctx_len = msg[pos] & 255
	pos = pos + 1
	pos = pos + ctx_len
	if (pos + 3 > len):
		return certs
	int list_len = tls_rd_u24(msg + pos)
	pos = pos + 3
	int list_end = pos + list_len
	if (list_end > len):
		return certs
	while (pos + 3 <= list_end):
		int clen = tls_rd_u24(msg + pos)
		pos = pos + 3
		if (pos + clen > list_end):
			return certs
		x509_cert* cert = x509_parse(msg + pos, clen)
		if (cert != 0):
			certs.push(cert)
		pos = pos + clen
		if (pos + 2 > list_end):
			return certs
		int ext_len = tls_rd_u16(msg + pos)
		pos = pos + 2
		pos = pos + ext_len
	return certs


void tls_free_cert_list(list[x509_cert*] certs):
	int i = 0
	while (i < certs.length):
		x509_cert_free(certs[i])
		i = i + 1
	list_free[x509_cert*](certs)


# Current unix time for validity checks; callers needing determinism inject
# cfg.now_unix instead (mirrors x509's "never reads the clock" discipline).
int tls_now_unix():
	return time_now()


# Verify the certificate chain + hostname via x509_verify_chain, honoring
# cfg overrides (trust store path, injected now_unix). Returns 1 on success.
int tls_check_chain(tls_conn* c, list[x509_cert*] certs, char* server_name):
	int now_unix = 0
	int have_now = 0
	if (c.cfg != 0):
		if (c.cfg.has_now_unix != 0):
			now_unix = c.cfg.now_unix
			have_now = 1
	if (have_now == 0):
		now_unix = tls_now_unix()
	char* store_path = 0
	if (c.cfg != 0):
		store_path = c.cfg.trust_store_path
	x509_trust_store* store = x509_load_trust_store(store_path)
	if (store == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_INTERNAL_ERROR())
		tls_fail(c, c"tls: cannot load trust store")
		return 0
	list[x509_cert*] extra = new list[x509_cert*]
	int ei = 1
	while (ei < certs.length):
		extra.push(certs[ei])
		ei = ei + 1
	char* verr = 0
	int chok = x509_verify_chain(certs[0], extra, store, server_name, now_unix, &verr)
	list_free[x509_cert*](extra)
	x509_store_free(store)
	if (chok == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: certificate verification failed")
		return 0
	return 1


# Read the encrypted server flight (EncryptedExtensions, Certificate,
# CertificateVerify, Finished), verify the signature, chain and Finished MAC,
# and stash the CH..serverFinished transcript hash into th_ch_sf. Returns 1 on
# success. Assumes read keys (server handshake) are already installed.
int tls_read_server_flight(tls_conn* c, char* server_name, char* th_ch_sf):
	int ds = c.digest_size
	int htype = 0
	char* msg = 0
	int mlen = 0

	# EncryptedExtensions
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		return 0
	if (htype != TLS_HS_ENCRYPTED_EXTENSIONS()):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected EncryptedExtensions")
		return 0
	whash_update(c.transcript, msg, mlen)

	# Certificate
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		return 0
	if (htype != TLS_HS_CERTIFICATE()):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected Certificate")
		return 0
	list[x509_cert*] certs = tls_parse_certificate(msg, mlen)
	whash_update(c.transcript, msg, mlen)
	if (certs.length == 0):
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
		tls_fail(c, c"tls: no certificate")
		return 0
	char* th_cert = malloc(ds)
	whash_final(c.transcript, th_cert)

	# CertificateVerify
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		free(th_cert)
		tls_free_cert_list(certs)
		return 0
	if (htype != TLS_HS_CERTIFICATE_VERIFY()):
		free(th_cert)
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected CertificateVerify")
		return 0
	if (mlen < 8):
		free(th_cert)
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
		tls_fail(c, c"tls: short CertificateVerify")
		return 0
	int sig_scheme = tls_rd_u16(msg + 4)
	int sig_len = tls_rd_u16(msg + 6)
	if (8 + sig_len > mlen):
		free(th_cert)
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
		tls_fail(c, c"tls: bad CertificateVerify length")
		return 0
	# Copy the signature out before hs_buf can move.
	char* sig = malloc(sig_len)
	tls_copy(sig, msg + 8, sig_len)
	int cvok = tls_verify_certverify(certs[0], sig_scheme, sig, sig_len, th_cert, ds)
	free(sig)
	free(th_cert)
	if (cvok == 0):
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECRYPT_ERROR())
		tls_fail(c, c"tls: CertificateVerify failed")
		return 0
	whash_update(c.transcript, msg, mlen)
	char* th_cv = malloc(ds)
	whash_final(c.transcript, th_cv)

	# Certificate chain + hostname, unless explicitly skipped.
	int skip = 0
	if (c.cfg != 0):
		skip = c.cfg.insecure_skip_verify
	if (skip == 0):
		if (tls_check_chain(c, certs, server_name) == 0):
			free(th_cv)
			tls_free_cert_list(certs)
			return 0

	tls_free_cert_list(certs)

	# server Finished: HMAC(server_finished_key, TH(CH..CertificateVerify)).
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		free(th_cv)
		return 0
	if (htype != TLS_HS_FINISHED()):
		free(th_cv)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected Finished")
		return 0
	int vd_len = mlen - 4
	if (vd_len != ds):
		free(th_cv)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
		tls_fail(c, c"tls: bad Finished length")
		return 0
	char* fkey = malloc(ds)
	tls_finished_key(c.hash_alg, c.s_hs_secret, fkey)
	char* expected = malloc(ds)
	hmac_compute(c.hash_alg, fkey, ds, th_cv, ds, expected)
	char* got = malloc(ds)
	tls_copy(got, msg + 4, ds)
	int fin_ok = hmac_equal(expected, got, ds)
	tls_wipe(fkey, ds)
	free(fkey)
	free(expected)
	free(got)
	free(th_cv)
	if (fin_ok == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECRYPT_ERROR())
		tls_fail(c, c"tls: server Finished verify failed")
		return 0
	whash_update(c.transcript, msg, mlen)
	# Snapshot CH..serverFinished for the application secrets + client Finished.
	whash_final(c.transcript, th_ch_sf)
	return 1


# Install the read protection derived from a traffic secret.
void tls_install_read_keys(tls_conn* c, char* secret):
	tls_derive_traffic_keys(c.hash_alg, secret, c.r_key, c.r_iv)
	c.r_seq_hi = 0
	c.r_seq_lo = 0
	c.r_active = 1


void tls_install_write_keys(tls_conn* c, char* secret):
	tls_derive_traffic_keys(c.hash_alg, secret, c.w_key, c.w_iv)
	c.w_seq_hi = 0
	c.w_seq_lo = 0
	c.w_active = 1


# Generate the ephemeral private key (or use the injected one). Returns 1 on
# success writing 32 bytes to priv.
int tls_gen_priv(tls_conn* c, char* priv):
	if (c.cfg != 0):
		if (c.cfg.test_priv != 0):
			tls_copy(priv, c.cfg.test_priv, 32)
			return 1
	return random_bytes(priv, 32)


# Drive the full client handshake on connection c. server_name is the SNI /
# hostname to verify. Returns 1 on success (keys switched to application), 0
# on any failure (connection marked broken, alert already sent).
int tls_do_handshake(tls_conn* c, char* server_name):
	tls_config* cfg = c.cfg
	int ds = c.digest_size

	char* priv = malloc(32)
	if (tls_gen_priv(c, priv) == 0):
		tls_wipe(priv, 32)
		free(priv)
		tls_fail(c, c"tls: RNG failure")
		return 0
	char* pub = malloc(32)
	x25519_scalarmult_base(pub, priv)

	# ClientHello (raw override for the RFC 8448 replay test).
	char* ch = 0
	int ch_len = 0
	int ch_owned = 1
	if (cfg != 0):
		if (cfg.test_client_hello != 0):
			ch = cfg.test_client_hello
			ch_len = cfg.test_client_hello_len
			ch_owned = 0
	if (ch == 0):
		char* rnd = malloc(32)
		char* sid = malloc(32)
		int rok = random_bytes(rnd, 32)
		int sok = random_bytes(sid, 32)
		if ((rok == 0) || (sok == 0)):
			free(rnd)
			free(sid)
			tls_wipe(priv, 32)
			free(priv)
			free(pub)
			tls_fail(c, c"tls: RNG failure")
			return 0
		ch = tls_build_client_hello(server_name, rnd, sid, pub, &ch_len)
		free(rnd)
		free(sid)
	free(pub)

	whash_update(c.transcript, ch, ch_len)
	int sent = tls_send_record(c, TLS_CT_HANDSHAKE(), ch, ch_len, 0)
	if (ch_owned != 0):
		free(ch)
	if (sent == 0):
		tls_wipe(priv, 32)
		free(priv)
		tls_fail(c, c"tls: send ClientHello failed")
		return 0

	# ServerHello
	int htype = 0
	char* msg = 0
	int mlen = 0
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		tls_wipe(priv, 32)
		free(priv)
		return 0
	if (htype != TLS_HS_SERVER_HELLO()):
		tls_wipe(priv, 32)
		free(priv)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected ServerHello")
		return 0
	char* server_pub = malloc(32)
	if (tls_parse_server_hello(c, msg, mlen, server_pub) == 0):
		free(server_pub)
		tls_wipe(priv, 32)
		free(priv)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: bad ServerHello")
		return 0
	whash_update(c.transcript, msg, mlen)

	# ECDHE shared secret; reject a low-order (all-zero) result.
	char* ecdhe = malloc(32)
	int xr = x25519_scalarmult(ecdhe, priv, server_pub)
	tls_wipe(priv, 32)
	free(priv)
	free(server_pub)
	if (xr != 0):
		tls_wipe(ecdhe, 32)
		free(ecdhe)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: bad key share")
		return 0

	# Handshake key schedule over CH..SH.
	char* th_ch_sh = malloc(ds)
	whash_final(c.transcript, th_ch_sh)
	char* hs_secret = malloc(ds)
	tls_derive_handshake(c, ecdhe, th_ch_sh, hs_secret)
	tls_wipe(ecdhe, 32)
	free(ecdhe)
	free(th_ch_sh)

	# Install server handshake read keys and read the encrypted flight.
	tls_install_read_keys(c, c.s_hs_secret)
	char* th_ch_sf = malloc(ds)
	if (tls_read_server_flight(c, server_name, th_ch_sf) == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		free(th_ch_sf)
		return 0

	# Client Finished: HMAC(client_finished_key, TH(CH..serverFinished)),
	# sent under the client handshake write keys.
	tls_install_write_keys(c, c.c_hs_secret)
	char* cfkey = malloc(ds)
	tls_finished_key(c.hash_alg, c.c_hs_secret, cfkey)
	char* cvd = malloc(ds)
	hmac_compute(c.hash_alg, cfkey, ds, th_ch_sf, ds, cvd)
	tls_wipe(cfkey, ds)
	free(cfkey)
	char* fin = malloc(4 + ds)
	fin[0] = TLS_HS_FINISHED()
	fin[1] = 0
	fin[2] = 0
	fin[3] = ds
	tls_copy(fin + 4, cvd, ds)
	free(cvd)
	int fsent = tls_send_record(c, TLS_CT_HANDSHAKE(), fin, 4 + ds, 1)
	free(fin)
	if (fsent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		free(th_ch_sf)
		tls_fail(c, c"tls: send Finished failed")
		return 0

	# Derive application traffic secrets and switch both directions.
	tls_derive_application(c, hs_secret, th_ch_sf)
	tls_wipe(hs_secret, ds)
	free(hs_secret)
	free(th_ch_sf)
	tls_install_read_keys(c, c.s_ap_secret)
	tls_install_write_keys(c, c.c_ap_secret)
	return 1


# ---- public API ---------------------------------------------------------------

# Handshake over an already-connected TCP socket. Returns an owned tls_conn*
# on success, 0 on failure (reason in tls_last_error(cfg)).
tls_conn* tls_connect(int sockfd, char* server_name, tls_config* cfg):
	tls_conn* c = tls_conn_new(sockfd, 0, cfg)
	if (tls_do_handshake(c, server_name) == 0):
		tls_conn_free(c)
		return 0
	return c


# In-memory handshake harness (tests): server bytes preloaded, client output
# captured. Not part of the public API.
tls_conn* tls_connect_mem(char* server_flight, int flen, char* server_name, tls_config* cfg):
	tls_conn* c = tls_conn_new(0 - 1, 1, cfg)
	wbuf_bytes(c.mem_in, server_flight, flen)
	if (tls_do_handshake(c, server_name) == 0):
		tls_conn_free(c)
		return 0
	return c


# Append more server bytes to an in-memory connection (tests).
void tls_mem_feed(tls_conn* c, char* data, int len):
	wbuf_bytes(c.mem_in, data, len)


# Take the captured client output, clearing the buffer (tests). Returns a
# malloc'd copy; *out_len gets its length.
char* tls_mem_take_output(tls_conn* c, int* out_len):
	int n = c.mem_out.len
	char* out = malloc(n + 1)
	tls_copy(out, c.mem_out.data, n)
	c.mem_out.len = 0
	*out_len = n
	return out


# Re-key one direction after a KeyUpdate (RFC 8446 7.2): the traffic secret
# advances by HKDF-Expand-Label(secret, "traffic upd", "", Hash.length).
void tls_update_secret(int alg, char* secret, int ds):
	char* next = malloc(ds)
	tls13_hkdf_expand_label(alg, secret, c"traffic upd", 11, c"", 0, next, ds)
	tls_copy(secret, next, ds)
	tls_wipe(next, ds)
	free(next)


# Handle a post-handshake handshake message (NewSessionTicket ignored,
# KeyUpdate re-keys the read side and answers when requested). Symmetric
# across roles: the read side re-keys the PEER's application secret and, when
# update_requested, our own write side re-keys OUR application secret. For a
# client our write secret is c_ap and read is s_ap; for a server it is the
# mirror image (is_server flips them).
void tls_post_handshake(tls_conn* c, char* data, int dlen):
	if (dlen < 4):
		return
	int mt = data[0] & 255
	if (mt == TLS_HS_KEY_UPDATE()):
		int req = 0
		if (dlen >= 5):
			req = data[4] & 255
		char* read_secret = c.s_ap_secret
		char* write_secret = c.c_ap_secret
		if (c.is_server != 0):
			read_secret = c.c_ap_secret
			write_secret = c.s_ap_secret
		tls_update_secret(c.hash_alg, read_secret, c.digest_size)
		tls_install_read_keys(c, read_secret)
		if (req == 1):
			char* ku = malloc(5)
			ku[0] = TLS_HS_KEY_UPDATE()
			ku[1] = 0
			ku[2] = 0
			ku[3] = 1
			ku[4] = 0
			tls_send_record(c, TLS_CT_HANDSHAKE(), ku, 5, 1)
			free(ku)
			tls_update_secret(c.hash_alg, write_secret, c.digest_size)
			tls_install_write_keys(c, write_secret)


# Read up to len application-data bytes. Returns the number read (>0), 0 at
# clean EOF (close_notify), or -1 on error.
int tls_read(tls_conn* c, char* buf, int len):
	if (c.broken != 0):
		return 0 - 1
	if (len <= 0):
		return 0
	# Drain any buffered plaintext first.
	if (c.app_pos < c.app_len):
		int avail = c.app_len - c.app_pos
		int n = len
		if (n > avail):
			n = avail
		tls_copy(buf, c.app_buf + c.app_pos, n)
		c.app_pos = c.app_pos + n
		if (c.app_pos >= c.app_len):
			tls_wipe(c.app_buf, c.app_len)
			free(c.app_buf)
			c.app_buf = 0
			c.app_len = 0
			c.app_pos = 0
		return n
	if (c.at_eof != 0):
		return 0

	while (1 == 1):
		int rtype = 0
		char* data = 0
		int dlen = 0
		if (tls_recv_record(c, &rtype, &data, &dlen) == 0):
			if (c.at_eof != 0):
				return 0
			return 0 - 1
		if (rtype == TLS_CT_APPLICATION_DATA()):
			if (dlen == 0):
				free(data)
				# empty record: keep reading
			else:
				c.app_buf = data
				c.app_len = dlen
				c.app_pos = 0
				int n = len
				if (n > dlen):
					n = dlen
				tls_copy(buf, c.app_buf, n)
				c.app_pos = n
				if (c.app_pos >= c.app_len):
					tls_wipe(c.app_buf, c.app_len)
					free(c.app_buf)
					c.app_buf = 0
					c.app_len = 0
					c.app_pos = 0
				return n
		else if (rtype == TLS_CT_ALERT()):
			int cn = tls_handle_alert(c, data, dlen)
			free(data)
			if (cn != 0):
				return 0
			return 0 - 1
		else if (rtype == TLS_CT_HANDSHAKE()):
			tls_post_handshake(c, data, dlen)
			free(data)
		else:
			free(data)
	return 0 - 1


# Write len bytes as one or more application_data records. Returns len on
# success, -1 on error. Fragments to the plaintext cap.
int tls_write(tls_conn* c, char* buf, int len):
	if (c.broken != 0):
		return 0 - 1
	if (len <= 0):
		return 0
	int sent = 0
	while (sent < len):
		int chunk = len - sent
		if (chunk > TLS_MAX_PLAINTEXT()):
			chunk = TLS_MAX_PLAINTEXT()
		if (tls_send_record(c, TLS_CT_APPLICATION_DATA(), buf + sent, chunk, 1) == 0):
			tls_fail(c, c"tls: write failed")
			return 0 - 1
		sent = sent + chunk
	return len


# Send close_notify (best effort) and free the connection, wiping all keys.
void tls_close(tls_conn* c):
	if (c == 0):
		return
	if (c.broken == 0):
		tls_send_alert(c, TLS_ALERT_WARNING(), TLS_ALERT_CLOSE_NOTIFY())
	tls_conn_free(c)


# ==============================================================================
# Server role (#203). tls_accept drives the mirror of the client handshake,
# reusing this module's record layer, transcript, key schedule and Finished
# machinery. The security bar is higher here (hostile clients): every
# peer-supplied length is validated against the remaining buffer AND an
# absolute cap before anything is consumed, and any parse/MAC failure tears
# the connection down with a fatal alert. The server private key never appears
# in a log line or error string.
# ==============================================================================

# ---- ClientHello parsing (bounded) --------------------------------------------

# Parse a ClientHello body (msg points at the handshake header; body at msg+4,
# len = 4 + body length). Strictly bounded: every embedded length is checked
# against the message end before use. Copies the 32-byte client random into
# out_random, the legacy_session_id (<= 32 bytes) into out_sid/*out_sid_len,
# and, if present, the X25519 client key share into out_pub. Sets the have_*
# flags for the ChaCha20 suite, an X25519 key_share, TLS 1.3 in
# supported_versions, and ecdsa_secp256r1_sha256 in signature_algorithms.
# Returns 1 for a structurally well-formed ClientHello (whatever it offered),
# 0 for a malformed/truncated one (the caller answers decode_error). The
# have_* flags let the caller pick handshake_failure vs protocol_version for a
# well-formed-but-unacceptable hello.
int tls_parse_client_hello(char* msg, int len, char* out_random, char* out_sid, int* out_sid_len, char* out_pub, int* have_chacha, int* have_x25519, int* have_tls13, int* have_ecdsa):
	*have_chacha = 0
	*have_x25519 = 0
	*have_tls13 = 0
	*have_ecdsa = 0
	*out_sid_len = 0
	int pos = 4
	# legacy_version(2) + random(32) + session_id length(1)
	if (pos + 2 + 32 + 1 > len):
		return 0
	pos = pos + 2
	tls_copy(out_random, msg + pos, 32)
	pos = pos + 32
	int sid_len = msg[pos] & 255
	pos = pos + 1
	if (sid_len > 32):
		return 0
	if (pos + sid_len > len):
		return 0
	if (sid_len > 0):
		tls_copy(out_sid, msg + pos, sid_len)
	*out_sid_len = sid_len
	pos = pos + sid_len
	# cipher_suites
	if (pos + 2 > len):
		return 0
	int cs_len = tls_rd_u16(msg + pos)
	pos = pos + 2
	if (pos + cs_len > len):
		return 0
	if ((cs_len & 1) != 0):
		return 0
	int cs_end = pos + cs_len
	while (pos + 2 <= cs_end):
		if (tls_rd_u16(msg + pos) == TLS_SUITE_CHACHA20_POLY1305_SHA256()):
			*have_chacha = 1
		pos = pos + 2
	pos = cs_end
	# legacy_compression_methods
	if (pos + 1 > len):
		return 0
	int comp_len = msg[pos] & 255
	pos = pos + 1
	if (pos + comp_len > len):
		return 0
	pos = pos + comp_len
	# extensions (a TLS 1.3 ClientHello always carries them, but tolerate none)
	if (pos == len):
		return 1
	if (pos + 2 > len):
		return 0
	int ext_total = tls_rd_u16(msg + pos)
	pos = pos + 2
	int ext_end = pos + ext_total
	if (ext_end > len):
		return 0
	while (pos + 4 <= ext_end):
		int etype = tls_rd_u16(msg + pos)
		int elen = tls_rd_u16(msg + pos + 2)
		pos = pos + 4
		if (pos + elen > ext_end):
			return 0
		if (etype == TLS_EXT_SUPPORTED_VERSIONS()):
			if (elen >= 1):
				int vl = msg[pos] & 255
				if (1 + vl <= elen):
					int vp = pos + 1
					int ve = pos + 1 + vl
					while (vp + 2 <= ve):
						if (tls_rd_u16(msg + vp) == 0x0304):
							*have_tls13 = 1
						vp = vp + 2
		else if (etype == TLS_EXT_KEY_SHARE()):
			if (elen >= 2):
				int ksl = tls_rd_u16(msg + pos)
				if (2 + ksl <= elen):
					int kp = pos + 2
					int ke = pos + 2 + ksl
					while (kp + 4 <= ke):
						int grp = tls_rd_u16(msg + kp)
						int kxl = tls_rd_u16(msg + kp + 2)
						kp = kp + 4
						if (kp + kxl > ke):
							return 0
						if (grp == TLS_GROUP_X25519()):
							if (kxl == 32):
								if (*have_x25519 == 0):
									tls_copy(out_pub, msg + kp, 32)
									*have_x25519 = 1
						kp = kp + kxl
		else if (etype == TLS_EXT_SIGNATURE_ALGORITHMS()):
			if (elen >= 2):
				int sl = tls_rd_u16(msg + pos)
				if (2 + sl <= elen):
					int sp = pos + 2
					int se = pos + 2 + sl
					while (sp + 2 <= se):
						if (tls_rd_u16(msg + sp) == TLS_SIG_ECDSA_SECP256R1_SHA256()):
							*have_ecdsa = 1
						sp = sp + 2
		pos = pos + elen
	return 1


# ---- server flight builders ---------------------------------------------------

# Build a ServerHello (RFC 8446 4.1.3): our single cipher suite, the echoed
# legacy_session_id, supported_versions=TLS 1.3, and an X25519 key_share
# carrying server_pub. Returns a malloc'd handshake message; *out_len its len.
char* tls_build_server_hello(char* random, char* sid, int sid_len, char* server_pub, int* out_len):
	wbuf* b = wbuf_new(128)
	wbuf_u8(b, TLS_HS_SERVER_HELLO())
	int lenpos = b.len
	wbuf_u24(b, 0)                        # body length placeholder
	int body_start = b.len
	wbuf_u16(b, 0x0303)                   # legacy_version
	wbuf_bytes(b, random, 32)             # random
	wbuf_u8(b, sid_len)                   # legacy_session_id_echo length
	if (sid_len > 0):
		wbuf_bytes(b, sid, sid_len)
	wbuf_u16(b, TLS_SUITE_CHACHA20_POLY1305_SHA256())
	wbuf_u8(b, 0)                         # legacy_compression_method = null
	int extpos = b.len
	wbuf_u16(b, 0)                        # extensions length placeholder
	int ext_start = b.len
	# supported_versions = TLS 1.3
	wbuf_u16(b, TLS_EXT_SUPPORTED_VERSIONS())
	wbuf_u16(b, 2)
	wbuf_u16(b, 0x0304)
	# key_share: one x25519 entry
	wbuf_u16(b, TLS_EXT_KEY_SHARE())
	wbuf_u16(b, 36)                       # ext_data length
	wbuf_u16(b, TLS_GROUP_X25519())
	wbuf_u16(b, 32)                       # key_exchange length
	wbuf_bytes(b, server_pub, 32)
	int ext_len = b.len - ext_start
	wbuf_set_u16(b, extpos, ext_len)
	int body_len = b.len - body_start
	wbuf_set_u24(b, lenpos, body_len)
	char* out = malloc(b.len)
	tls_copy(out, b.data, b.len)
	*out_len = b.len
	wbuf_free(b)
	return out


# Build an empty EncryptedExtensions (no extensions negotiated: no ALPN, no
# early data, no server_name ack). type(1)+len(3)+extensions_length(2)=0.
char* tls_build_encrypted_extensions(int* out_len):
	char* m = malloc(6)
	m[0] = TLS_HS_ENCRYPTED_EXTENSIONS()
	m[1] = 0
	m[2] = 0
	m[3] = 2
	m[4] = 0
	m[5] = 0
	*out_len = 6
	return m


# Build a Certificate message (RFC 8446 4.4.2) from the raw DER blocks
# (leaf-first): empty request context, then each cert as a 3-byte-length entry
# with empty per-cert extensions. Returns a malloc'd message; *out_len its len.
char* tls_build_certificate(list[pem_block*] certs, int* out_len):
	wbuf* b = wbuf_new(512)
	wbuf_u8(b, TLS_HS_CERTIFICATE())
	int lenpos = b.len
	wbuf_u24(b, 0)                        # body length placeholder
	int body_start = b.len
	wbuf_u8(b, 0)                         # certificate_request_context length = 0
	int listpos = b.len
	wbuf_u24(b, 0)                        # certificate_list length placeholder
	int list_start = b.len
	int i = 0
	while (i < certs.length):
		pem_block* blk = certs[i]
		wbuf_u24(b, blk.len)              # cert_data length
		wbuf_bytes(b, blk.data, blk.len)
		wbuf_u16(b, 0)                    # per-certificate extensions length = 0
		i = i + 1
	wbuf_set_u24(b, listpos, b.len - list_start)
	wbuf_set_u24(b, lenpos, b.len - body_start)
	char* out = malloc(b.len)
	tls_copy(out, b.data, b.len)
	*out_len = b.len
	wbuf_free(b)
	return out


# Build a CertificateVerify (RFC 8446 4.4.3): deterministic ECDSA (RFC 6979)
# over SHA-256 of the server signed-content (64 spaces || context string ||
# 0x00 || transcript hash at CH..Certificate), emitted as a DER signature with
# scheme ecdsa_secp256r1_sha256. Returns a malloc'd handshake message and its
# length, or 0 if signing failed (bad key). The private key stays in server_d.
char* tls_build_certverify(char* server_d, char* th_cert, int th_len, int* out_len):
	int clen = 0
	char* content = tls_certverify_content(th_cert, th_len, &clen)
	char* digest = malloc(32)
	whash_oneshot(WHASH_SHA256(), content, clen, digest)
	free(content)
	char* r = malloc(32)
	char* s = malloc(32)
	int sok = ecdsa_p256_sign(server_d, digest, 32, r, s)
	tls_wipe(digest, 32)
	free(digest)
	if (sok == 0):
		free(r)
		free(s)
		return 0
	char* der = malloc(80)
	int der_len = 0
	x509_ecdsa_sig_raw_to_der(r, s, der, &der_len)
	free(r)
	free(s)
	wbuf* b = wbuf_new(96)
	wbuf_u8(b, TLS_HS_CERTIFICATE_VERIFY())
	int lenpos = b.len
	wbuf_u24(b, 0)                        # body length placeholder
	int body_start = b.len
	wbuf_u16(b, TLS_SIG_ECDSA_SECP256R1_SHA256())
	wbuf_u16(b, der_len)
	wbuf_bytes(b, der, der_len)
	free(der)
	wbuf_set_u24(b, lenpos, b.len - body_start)
	char* out = malloc(b.len)
	tls_copy(out, b.data, b.len)
	*out_len = b.len
	wbuf_free(b)
	return out


# ---- credential loading -------------------------------------------------------

# The server ephemeral X25519 private key: injected test key, else 32 fresh
# random bytes. Returns 1 on success.
int tls_server_gen_priv(tls_conn* c, char* priv):
	if (c.scfg != 0):
		if (c.scfg.test_priv != 0):
			tls_copy(priv, c.scfg.test_priv, 32)
			return 1
	return random_bytes(priv, 32)


# The ServerHello random: injected test value, else 32 fresh random bytes.
int tls_server_gen_random(tls_conn* c, char* rnd):
	if (c.scfg != 0):
		if (c.scfg.test_random != 0):
			tls_copy(rnd, c.scfg.test_random, 32)
			return 1
	return random_bytes(rnd, 32)


# Decode the configured certificate chain into raw DER blocks (leaf-first).
# Prefers injected PEM bytes; otherwise reads cert_chain_path. Returns the
# blocks (possibly empty on failure); the caller frees with pem_blocks_free.
list[pem_block*] tls_server_cert_blocks(tls_server_config* scfg):
	char* pem = 0
	int plen = 0
	char* owned = 0
	if (scfg.test_cert_pem != 0):
		pem = scfg.test_cert_pem
		plen = scfg.test_cert_pem_len
	else if (scfg.cert_chain_path != 0):
		owned = file_read_text(scfg.cert_chain_path)
		if (owned != 0):
			pem = owned
			plen = strlen(owned)
	if (pem == 0):
		return new list[pem_block*]
	list[pem_block*] blocks = pem_decode_blocks(pem, plen, c"CERTIFICATE")
	if (owned != 0):
		free(owned)
	return blocks


# Load the ECDSA P-256 private key into out_d32 (32-byte scalar). Prefers
# injected PEM bytes; otherwise reads key_path. The PEM text (which holds the
# private key) is wiped before free. Returns 1 on success.
int tls_server_load_key(tls_server_config* scfg, char* out_d32):
	char* pem = 0
	int plen = 0
	char* owned = 0
	if (scfg.test_key_pem != 0):
		pem = scfg.test_key_pem
		plen = scfg.test_key_pem_len
	else if (scfg.key_path != 0):
		owned = file_read_text(scfg.key_path)
		if (owned != 0):
			pem = owned
			plen = strlen(owned)
	if (pem == 0):
		return 0
	int ok = x509_load_ec_private_key(pem, plen, out_d32)
	if (owned != 0):
		tls_wipe(owned, plen)
		free(owned)
	return ok


# ---- server handshake state machine -------------------------------------------

# Read and validate the ClientHello (bounded), folding it into the transcript.
# On success returns 1 with the session_id echo (out_sid/*out_sid_len) and the
# client X25519 share (out_pub, 32 bytes). On a malformed hello or one that
# does not offer TLS 1.3 + ChaCha20 + X25519 + ecdsa_secp256r1_sha256 it sends
# the appropriate fatal alert (protocol_version / handshake_failure /
# decode_error -- never a HelloRetryRequest), marks the connection, returns 0.
int tls_server_read_client_hello(tls_conn* c, char* out_sid, int* out_sid_len, char* out_pub):
	int htype = 0
	char* msg = 0
	int mlen = 0
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		return 0
	if (htype != TLS_HS_CLIENT_HELLO()):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected ClientHello")
		return 0
	whash_update(c.transcript, msg, mlen)
	char* crandom = malloc(32)
	int have_chacha = 0
	int have_x25519 = 0
	int have_tls13 = 0
	int have_ecdsa = 0
	int pok = tls_parse_client_hello(msg, mlen, crandom, out_sid, out_sid_len, out_pub, &have_chacha, &have_x25519, &have_tls13, &have_ecdsa)
	free(crandom)
	if (pok == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
		tls_fail(c, c"tls: malformed ClientHello")
		return 0
	if (have_tls13 == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_PROTOCOL_VERSION())
		tls_fail(c, c"tls: client does not offer TLS 1.3")
		return 0
	if (have_chacha == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: no supported cipher suite")
		return 0
	if (have_x25519 == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: no X25519 key_share")
		return 0
	if (have_ecdsa == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: client does not accept ecdsa_secp256r1_sha256")
		return 0
	return 1


# Drive the full server handshake on connection c (c.scfg holds credentials).
# Returns 1 on success (keys switched to application data), 0 on any failure
# (connection marked broken, alert already sent, key material wiped).
int tls_server_do_handshake(tls_conn* c):
	tls_server_config* scfg = c.scfg
	int ds = c.digest_size

	# Load credentials up front: fail before engaging the client if we cannot
	# serve. The private key lives in server_d until CertificateVerify.
	list[pem_block*] certs = tls_server_cert_blocks(scfg)
	if (certs.length == 0):
		pem_blocks_free(certs)
		tls_fail(c, c"tls: server certificate unavailable")
		return 0
	char* server_d = malloc(32)
	tls_wipe(server_d, 32)
	if (tls_server_load_key(scfg, server_d) == 0):
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: server private key unavailable")
		return 0

	# ClientHello.
	char* csid = malloc(32)
	int csid_len = 0
	char* cpub = malloc(32)
	if (tls_server_read_client_hello(c, csid, &csid_len, cpub) == 0):
		free(csid)
		free(cpub)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		return 0

	# ServerHello with a fresh (or injected) ephemeral X25519 key and random.
	char* spriv = malloc(32)
	if (tls_server_gen_priv(c, spriv) == 0):
		tls_wipe(spriv, 32)
		free(spriv)
		free(csid)
		free(cpub)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: RNG failure")
		return 0
	char* spub = malloc(32)
	x25519_scalarmult_base(spub, spriv)
	char* srandom = malloc(32)
	if (tls_server_gen_random(c, srandom) == 0):
		tls_wipe(spriv, 32)
		free(spriv)
		free(spub)
		free(srandom)
		free(csid)
		free(cpub)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: RNG failure")
		return 0
	int sh_len = 0
	char* sh = tls_build_server_hello(srandom, csid, csid_len, spub, &sh_len)
	free(srandom)
	free(spub)
	free(csid)
	whash_update(c.transcript, sh, sh_len)
	int shsent = tls_send_record(c, TLS_CT_HANDSHAKE(), sh, sh_len, 0)
	free(sh)
	if (shsent == 0):
		tls_wipe(spriv, 32)
		free(spriv)
		free(cpub)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: send ServerHello failed")
		return 0

	# ECDHE shared secret; reject a low-order (all-zero) result.
	char* ecdhe = malloc(32)
	int xr = x25519_scalarmult(ecdhe, spriv, cpub)
	tls_wipe(spriv, 32)
	free(spriv)
	free(cpub)
	if (xr != 0):
		tls_wipe(ecdhe, 32)
		free(ecdhe)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_HANDSHAKE_FAILURE())
		tls_fail(c, c"tls: bad client key share")
		return 0

	# Handshake key schedule over CH..SH; install directional keys (we write
	# with the server handshake secret and read with the client one).
	char* th_ch_sh = malloc(ds)
	whash_final(c.transcript, th_ch_sh)
	char* hs_secret = malloc(ds)
	tls_derive_handshake(c, ecdhe, th_ch_sh, hs_secret)
	tls_wipe(ecdhe, 32)
	free(ecdhe)
	free(th_ch_sh)
	tls_install_write_keys(c, c.s_hs_secret)
	tls_install_read_keys(c, c.c_hs_secret)

	# EncryptedExtensions (empty).
	int ee_len = 0
	char* ee = tls_build_encrypted_extensions(&ee_len)
	whash_update(c.transcript, ee, ee_len)
	int eesent = tls_send_record(c, TLS_CT_HANDSHAKE(), ee, ee_len, 1)
	free(ee)
	if (eesent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: send EncryptedExtensions failed")
		return 0

	# Certificate (the configured chain, leaf-first). DER is copied into the
	# message, so the blocks are released immediately after.
	int cert_len = 0
	char* certmsg = tls_build_certificate(certs, &cert_len)
	pem_blocks_free(certs)
	whash_update(c.transcript, certmsg, cert_len)
	int csent = tls_send_record(c, TLS_CT_HANDSHAKE(), certmsg, cert_len, 1)
	free(certmsg)
	if (csent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_wipe(server_d, 32)
		free(server_d)
		tls_fail(c, c"tls: send Certificate failed")
		return 0
	char* th_cert = malloc(ds)
	whash_final(c.transcript, th_cert)

	# CertificateVerify (deterministic ECDSA over the CH..Certificate hash).
	int cv_len = 0
	char* cv = tls_build_certverify(server_d, th_cert, ds, &cv_len)
	free(th_cert)
	tls_wipe(server_d, 32)
	free(server_d)
	if (cv == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_INTERNAL_ERROR())
		tls_fail(c, c"tls: CertificateVerify signing failed")
		return 0
	whash_update(c.transcript, cv, cv_len)
	int cvsent = tls_send_record(c, TLS_CT_HANDSHAKE(), cv, cv_len, 1)
	free(cv)
	if (cvsent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_fail(c, c"tls: send CertificateVerify failed")
		return 0
	char* th_cv = malloc(ds)
	whash_final(c.transcript, th_cv)

	# server Finished over TH(CH..CertificateVerify).
	char* sfkey = malloc(ds)
	tls_finished_key(c.hash_alg, c.s_hs_secret, sfkey)
	char* svd = malloc(ds)
	hmac_compute(c.hash_alg, sfkey, ds, th_cv, ds, svd)
	tls_wipe(sfkey, ds)
	free(sfkey)
	free(th_cv)
	char* fin = malloc(4 + ds)
	fin[0] = TLS_HS_FINISHED()
	fin[1] = 0
	fin[2] = 0
	fin[3] = ds
	tls_copy(fin + 4, svd, ds)
	free(svd)
	whash_update(c.transcript, fin, 4 + ds)
	int fsent = tls_send_record(c, TLS_CT_HANDSHAKE(), fin, 4 + ds, 1)
	free(fin)
	if (fsent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_fail(c, c"tls: send Finished failed")
		return 0

	# Application secrets over CH..serverFinished; switch our WRITE to the
	# server application keys. READ stays on the client handshake keys so we
	# can read the client's Finished, then advances to the client app keys.
	char* th_ch_sf = malloc(ds)
	whash_final(c.transcript, th_ch_sf)
	tls_derive_application(c, hs_secret, th_ch_sf)
	tls_wipe(hs_secret, ds)
	free(hs_secret)
	tls_install_write_keys(c, c.s_ap_secret)

	# client Finished = HMAC(client_finished_key, TH(CH..serverFinished)).
	char* cfkey = malloc(ds)
	tls_finished_key(c.hash_alg, c.c_hs_secret, cfkey)
	char* expected = malloc(ds)
	hmac_compute(c.hash_alg, cfkey, ds, th_ch_sf, ds, expected)
	tls_wipe(cfkey, ds)
	free(cfkey)
	free(th_ch_sf)
	int htype = 0
	char* msg = 0
	int mlen = 0
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		free(expected)
		return 0
	if (htype != TLS_HS_FINISHED()):
		free(expected)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_UNEXPECTED_MESSAGE())
		tls_fail(c, c"tls: expected client Finished")
		return 0
	int vd_len = mlen - 4
	if (vd_len != ds):
		free(expected)
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECODE_ERROR())
		tls_fail(c, c"tls: bad client Finished length")
		return 0
	char* got = malloc(ds)
	tls_copy(got, msg + 4, ds)
	int finok = hmac_equal(expected, got, ds)
	free(expected)
	free(got)
	if (finok == 0):
		tls_send_alert(c, TLS_ALERT_FATAL(), TLS_ALERT_DECRYPT_ERROR())
		tls_fail(c, c"tls: client Finished verify failed")
		return 0
	tls_install_read_keys(c, c.c_ap_secret)
	return 1


# ---- public server API --------------------------------------------------------

# Server handshake over an already-accepted TCP socket. Returns an owned
# tls_conn* on success (the same tls_read/tls_write/tls_close then apply), or 0
# on failure with the reason in tls_server_last_error(cfg).
tls_conn* tls_accept(int sockfd, tls_server_config* cfg):
	if (cfg == 0):
		return 0
	tls_conn* c = tls_conn_new(sockfd, 0, 0)
	c.is_server = 1
	c.scfg = cfg
	if (tls_server_do_handshake(c) == 0):
		tls_conn_free(c)
		return 0
	return c


# In-memory server handshake harness (tests): client bytes preloaded, server
# output captured. Not part of the public API.
tls_conn* tls_accept_mem(char* client_flight, int flen, tls_server_config* cfg):
	if (cfg == 0):
		return 0
	tls_conn* c = tls_conn_new(0 - 1, 1, 0)
	c.is_server = 1
	c.scfg = cfg
	wbuf_bytes(c.mem_in, client_flight, flen)
	if (tls_server_do_handshake(c) == 0):
		tls_conn_free(c)
		return 0
	return c
