/*
TLS 1.3 client and server (RFC 8446) for the pure-W HTTPS stack: plan 11
(libs/standard/plans/11_native_http_tls.md) phase 7, issue #201, part of
#155. Both roles share the record layer, transcript and key schedule.

Scope (matches the plan's "keep the surface minimal"):
  - TLS 1.3: ChaCha20-Poly1305/SHA-256, AES-128-GCM/SHA-256 and
    AES-256-GCM/SHA-384; X25519 and P-256 ECDH with HelloRetryRequest.
    No PSK/0-RTT/resumption;
    optional/required client certificates (ECDSA P-256). ALPN (RFC 7301)
    is optional: see below. Server signature verification supports RSA
    SHA-256/SHA-384 and ECDSA P-256/SHA-256 or P-384/SHA-384.
  - Record layer: TLSPlaintext / TLSCiphertext framing with the TLS 1.3
    AEAD nonce (per-record 64-bit sequence number XORed into write_iv),
    additional_data = the 5-byte record header,
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
secret-dependent checks (Finished and AEAD tags). The P-256 bignum
backend retains its documented variable-time arithmetic limitation.
Certificate validation is on by default; tls_config's
insecure_skip_verify (loud name, tests only) skips ONLY chain building and
hostname matching -- the CertificateVerify handshake signature and the
Finished MAC are always checked.

Public API:
  tls_config* tls_config_new()
  void        tls_config_free(tls_config* cfg)
  char*       tls_last_error(tls_config* cfg)
  tls_conn*   tls_connect(int sockfd, char* server_name, tls_config* cfg)
  tls_conn*   tls_connect_timeout(int sockfd, char* server_name, tls_config* cfg, int io_timeout_ms)
  int         tls_read(tls_conn* c, char* buf, int len)   0=EOF, -1=error
  int         tls_write(tls_conn* c, char* buf, int len)  -1=error
  void        tls_close(tls_conn* c)
  int         tls_config_set_alpn(tls_config* cfg, char* protos)
                                   offer "h2,http/1.1" (comma-separated)
  char*       tls_alpn_selected(tls_conn* c)  negotiated protocol or 0
  int         tls_server_config_set_alpn(tls_server_config* cfg,
                                         char* protos, int required)

ALPN (RFC 7301): a client with ALPN configured offers the list in its
ClientHello and validates the server's EncryptedExtensions selection (exactly
one name, one we offered; an unsolicited ALPN extension is
unsupported_extension). The client does not itself require a selection --
callers that need one (HTTP/2 "h2") check tls_alpn_selected. A server with
ALPN configured picks the first protocol of ITS preference list the client
offered and echoes it in EncryptedExtensions; when required and there is no
match it sends no_application_protocol (120). Without ALPN configured on
either side nothing changes on the wire.

tls_connect returns 0 on failure; the reason is retrievable via
tls_last_error(cfg). server_name is required (SNI + hostname verification):
a null or empty one fails cleanly before any I/O with "tls: no server name
to verify", unless insecure_skip_verify is set (then no SNI is sent). On success it returns an owned tls_conn* that
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
import lib.poll
import lib.io_wait
import lib.io
import lib.file
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac
import libs.standard.crypto.hkdf
import libs.standard.crypto.chacha20poly1305
import libs.standard.crypto.aes_gcm
import libs.standard.crypto.ecdh_p256
import libs.standard.crypto.x25519
import libs.standard.crypto.random
import libs.standard.crypto.rsa_verify
import libs.standard.crypto.ecdsa_p256
import libs.standard.net.x509
import lib.bytes
import lib.hex
import structures.string
import lib.mem


# ---- protocol constants -------------------------------------------------------

# ContentType (RFC 8446 5.1).
const int TLS_CT_CHANGE_CIPHER_SPEC = 20
const int TLS_CT_ALERT = 21
const int TLS_CT_HANDSHAKE = 22
const int TLS_CT_APPLICATION_DATA = 23


# HandshakeType (RFC 8446 4).
const int TLS_HS_CLIENT_HELLO = 1
const int TLS_HS_SERVER_HELLO = 2
const int TLS_HS_NEW_SESSION_TICKET = 4
const int TLS_HS_ENCRYPTED_EXTENSIONS = 8
const int TLS_HS_CERTIFICATE_REQUEST = 13
const int TLS_HS_CERTIFICATE = 11
const int TLS_HS_CERTIFICATE_VERIFY = 15
const int TLS_HS_FINISHED = 20
const int TLS_HS_KEY_UPDATE = 24


# AlertLevel / AlertDescription (RFC 8446 6).
const int TLS_ALERT_WARNING = 1
const int TLS_ALERT_FATAL = 2
const int TLS_ALERT_CLOSE_NOTIFY = 0
const int TLS_ALERT_UNEXPECTED_MESSAGE = 10
const int TLS_ALERT_BAD_RECORD_MAC = 20
const int TLS_ALERT_HANDSHAKE_FAILURE = 40
const int TLS_ALERT_DECODE_ERROR = 50
const int TLS_ALERT_DECRYPT_ERROR = 51
const int TLS_ALERT_PROTOCOL_VERSION = 70
const int TLS_ALERT_INTERNAL_ERROR = 80
const int TLS_ALERT_ILLEGAL_PARAMETER = 47
const int TLS_ALERT_UNSUPPORTED_EXTENSION = 110


# RFC 7301 section 3.2: the server supports none of the client's protocols.
const int TLS_ALERT_NO_APPLICATION_PROTOCOL = 120


# Supported TLS 1.3 cipher suites and named groups.
const int TLS_SUITE_CHACHA20_POLY1305_SHA256 = 0x1303
const int TLS_SUITE_AES_128_GCM_SHA256 = 0x1301
const int TLS_SUITE_AES_256_GCM_SHA384 = 0x1302
const int TLS_GROUP_SECP256R1 = 0x0017
const int TLS_GROUP_X25519 = 0x001d


# SignatureScheme values we offer / accept for CertificateVerify.
const int TLS_SIG_RSA_PKCS1_SHA256 = 0x0401
const int TLS_SIG_RSA_PKCS1_SHA384 = 0x0501
const int TLS_SIG_ECDSA_SECP256R1_SHA256 = 0x0403
const int TLS_SIG_ECDSA_SECP384R1_SHA384 = 0x0503
const int TLS_SIG_RSA_PSS_RSAE_SHA256 = 0x0804
const int TLS_SIG_RSA_PSS_RSAE_SHA384 = 0x0805


# Extension types.
const int TLS_EXT_SERVER_NAME = 0x0000
const int TLS_EXT_SUPPORTED_GROUPS = 0x000a
const int TLS_EXT_SIGNATURE_ALGORITHMS = 0x000d
const int TLS_EXT_SIGNATURE_ALGORITHMS_CERT = 0x0032
const int TLS_EXT_SUPPORTED_VERSIONS = 0x002b
const int TLS_EXT_COOKIE = 0x002c
const int TLS_EXT_KEY_SHARE = 0x0033


# application_layer_protocol_negotiation (RFC 7301).
const int TLS_EXT_ALPN = 0x0010


# Record length caps (RFC 8446 5.1/5.2): plaintext content <= 2^14,
# ciphertext record fragment <= 2^14 + 256.
const int TLS_MAX_PLAINTEXT = 16384
const int TLS_MAX_CIPHERTEXT = 16640


# Absolute cap on a single reassembled handshake message (#203 hardening).
# TLS 1.3 permits up to 2^24-1, but our flights (ClientHello, ServerHello,
# a small Certificate chain, CertificateVerify, Finished) are far smaller;
# 64 KiB bounds hs_buf growth against a hostile peer without rejecting any
# legitimate handshake. Enforced in the shared reassembler for both roles.
const int TLS_MAX_HANDSHAKE = 65536


# Maximum key capacity and common AEAD IV/tag lengths.
const int TLS_AEAD_KEY_LEN = 32
const int TLS_AEAD_IV_LEN = 12
const int TLS_AEAD_TAG_LEN = 16


# ---- little byte helpers ------------------------------------------------------

void tls_wipe(char* p, int len):
	if (p == 0): return
	mem_fill(p, 0, len)


# ---- AEAD nonce (reusable by #203) --------------------------------------------

# TLS 1.3 per-record nonce (RFC 8446 5.3): the 64-bit record sequence number,
# left-padded to iv_length, XORed into write_iv. iv is 12 bytes; the sequence
# occupies the low 8 bytes. seq is carried as a hi/lo 32-bit pair.
void tls_nonce(char* iv, int seq_hi, int seq_lo, char* out):
	int i = 0
	while (i < TLS_AEAD_IV_LEN):
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

# Legacy ChaCha20 record-protection key (32 bytes) and iv (12 bytes) from a traffic
# secret: HKDF-Expand-Label(secret, "key"/"iv", "", length). ChaCha20 uses a
# 32-byte key.
void tls_derive_traffic_keys(int alg, char* secret, char* out_key, char* out_iv):
	tls13_hkdf_expand_label(alg, secret, c"key", 3, c"", 0, out_key, TLS_AEAD_KEY_LEN)
	tls13_hkdf_expand_label(alg, secret, c"iv", 2, c"", 0, out_iv, TLS_AEAD_IV_LEN)


# finished_key = HKDF-Expand-Label(secret, "finished", "", digest_size).
void tls_finished_key(int alg, char* secret, char* out):
	tls13_hkdf_expand_label(alg, secret, c"finished", 8, c"", 0, out, whash_digest_size(alg))


# Client authentication policy; optional still rejects an invalid supplied cert.
const int TLS_CLIENT_AUTH_NONE = 0
const int TLS_CLIENT_AUTH_OPTIONAL = 1
const int TLS_CLIENT_AUTH_REQUIRED = 2


# ---- configuration ------------------------------------------------------------

struct tls_config:
	char* client_cert_chain_path # borrowed leaf-first PEM chain, optional
	char* client_key_path        # borrowed ECDSA P-256 PKCS#8/SEC1 PEM path
	int require_client_auth      # fail if server omits CertificateRequest
	char* trust_store_path      # override CA bundle path, 0 = system default
	int insecure_skip_verify    # tests only: skip chain + hostname checks
	int has_now_unix            # 1 => use now_unix instead of the clock
	int now_unix
	char* last_error            # static string, set on failure; never freed
	int key_share_group         # 0/X25519 or P-256: initial client share
	# Deterministic-test injection (mirrors now_unix injection):
	char* test_priv             # 32-byte selected-group private key, or 0 for random
	char* test_client_hello     # raw ClientHello handshake message to send
	int test_client_hello_len   # verbatim, for the RFC 8448 replay test
	char* alpn                  # ALPN ProtocolNameList body (length-prefixed
	int alpn_len                # names, no outer length), or 0 = no ALPN;
	                            # set via tls_config_set_alpn


tls_config* tls_config_new():
	tls_config* c = new tls_config()
	c.client_cert_chain_path = 0
	c.client_key_path = 0
	c.require_client_auth = 0
	c.trust_store_path = 0
	c.insecure_skip_verify = 0
	c.has_now_unix = 0
	c.now_unix = 0
	c.last_error = 0
	c.test_priv = 0
	c.test_client_hello = 0
	c.key_share_group = 0
	c.test_client_hello_len = 0
	c.alpn = 0
	c.alpn_len = 0
	return c


void tls_config_free(tls_config* c):
	if (c == 0): return
	if (c.alpn != 0): free(c.alpn)
	free(cast(char*, c))


char* tls_last_error(tls_config* c):
	if (c == 0): return 0
	return c.last_error


# ---- ALPN (RFC 7301) helpers --------------------------------------------------

# Encode a comma-separated protocol list ("h2,http/1.1") as a ProtocolNameList
# body: each name as a 1-byte length + bytes, no outer 2-byte length. Returns
# a malloc'd buffer (*out_len its length), or 0 for an empty list, an empty
# name, or a name longer than 255 bytes.
char* tls_alpn_encode(char* protos, int* out_len):
	*out_len = 0
	if (protos == 0): return 0
	int n = strlen(protos)
	if (n == 0): return 0
	string_builder* b = string_new_sized(n + 1)
	int start = 0
	int i = 0
	while (i <= n):
		if ((i == n) || (protos[i] == ',')):
			int nl = i - start
			if ((nl <= 0) || (nl > 255)):
				string_free(b)
				return 0
			string_append_char(b, nl)
			string_append_bytes(b, protos + start, nl)
			start = i + 1
		i = i + 1
	char* out = cast(char*, malloc(b.length))
	mem_copy(out, b.data, b.length)
	*out_len = b.length
	string_free(b)
	return out


# 1 if the ProtocolNameList body (names, list_len) holds the name (name, nlen)
# exactly. The list must already be well-formed (tls_alpn_list_valid).
int tls_alpn_list_contains(char* names, int list_len, char* name, int nlen):
	int pos = 0
	while (pos < list_len):
		int l = names[pos] & 255
		if (l == nlen):
			int i = 0
			int same = 1
			while (i < l):
				if (names[pos + 1 + i] != name[i]): same = 0
				i = i + 1
			if (same != 0): return 1
		pos = pos + 1 + l
	return 0


# 1 if list_len bytes at names form a non-empty sequence of non-empty
# length-prefixed names that ends exactly at list_len.
int tls_alpn_list_valid(char* names, int list_len):
	if (list_len <= 0): return 0
	int pos = 0
	while (pos < list_len):
		int l = names[pos] & 255
		if (l == 0): return 0
		if (pos + 1 + l > list_len): return 0
		pos = pos + 1 + l
	return 1


# Client: offer ALPN protocols in preference order, comma-separated
# ("h2,http/1.1"); 0 or "" clears the offer. Returns 1 on success, 0 for a
# malformed list (the previous setting is then cleared too).
int tls_config_set_alpn(tls_config* c, char* protos):
	if (c.alpn != 0): free(c.alpn)
	c.alpn = 0
	c.alpn_len = 0
	if (protos == 0): return 1
	if (strlen(protos) == 0): return 1
	int n = 0
	char* enc = tls_alpn_encode(protos, &n)
	if (enc == 0): return 0
	c.alpn = enc
	c.alpn_len = n
	return 1


# ---- server configuration (#203) ----------------------------------------------

# Credentials for the server role. The certificate chain is leaf-first PEM
# (as served in the TLS Certificate message) and the private key is an ECDSA
# P-256 key in PKCS#8 or SEC1 PEM (loaded via x509_load_ec_private_key).
# ECDSA P-256 keys ONLY -- no RSA server keys. The test_* fields inject cert
# and key bytes directly (mirroring the client's test_* knobs) so tests need
# no filesystem; test_priv/test_random pin the server ephemeral X25519 key
# and ServerHello random for deterministic traces.
struct tls_server_config:
	int cipher_suite           # 0 = any supported suite, otherwise require this suite
	int key_exchange_group     # 0 = any supported group, otherwise require this group
	int client_auth              # TLS_CLIENT_AUTH_NONE/OPTIONAL/REQUIRED
	char* client_trust_store_path # explicit PEM CA bundle required for auth
	int has_now_unix             # deterministic client certificate checks
	int now_unix
	char* cert_chain_path       # leaf-first cert-chain PEM file, or 0
	char* key_path              # ECDSA P-256 private-key PEM file, or 0
	char* last_error            # static string, set on failure; never freed
	char* test_cert_pem         # inject cert-chain PEM bytes instead of a file
	int test_cert_pem_len
	char* test_key_pem          # inject private-key PEM bytes instead of a file
	int test_key_pem_len
	char* test_priv             # 32-byte server selected-group private key, or 0
	char* test_random           # 32-byte ServerHello random, or 0
	char* alpn                  # ALPN preference list body, or 0 = ignore ALPN
	int alpn_len
	int alpn_required           # 1 => no_application_protocol when no match


tls_server_config* tls_server_config_new():
	tls_server_config* c = new tls_server_config()
	c.cipher_suite = 0
	c.key_exchange_group = 0
	c.client_auth = TLS_CLIENT_AUTH_NONE
	c.client_trust_store_path = 0
	c.has_now_unix = 0
	c.now_unix = 0
	c.cert_chain_path = 0
	c.key_path = 0
	c.last_error = 0
	c.test_cert_pem = 0
	c.test_cert_pem_len = 0
	c.test_key_pem = 0
	c.test_key_pem_len = 0
	c.test_priv = 0
	c.test_random = 0
	c.alpn = 0
	c.alpn_len = 0
	c.alpn_required = 0
	return c


void tls_server_config_free(tls_server_config* c):
	if (c == 0): return
	if (c.alpn != 0): free(c.alpn)
	free(cast(char*, c))


# Server: the ALPN protocols we accept, in OUR preference order
# (comma-separated). The first of ours the client also offered is selected
# and echoed in EncryptedExtensions. required = 1 fails the handshake with a
# fatal no_application_protocol alert when the client offered no ALPN or none
# of its protocols match; required = 0 then proceeds without ALPN. 0 or ""
# clears the setting (ALPN is ignored entirely). Returns 1 on success, 0 for a
# malformed list (the setting is cleared).
int tls_server_config_set_alpn(tls_server_config* c, char* protos, int required):
	if (c.alpn != 0): free(c.alpn)
	c.alpn = 0
	c.alpn_len = 0
	c.alpn_required = 0
	if (protos == 0): return 1
	if (strlen(protos) == 0): return 1
	int n = 0
	char* enc = tls_alpn_encode(protos, &n)
	if (enc == 0): return 0
	c.alpn = enc
	c.alpn_len = n
	c.alpn_required = required
	return 1


char* tls_server_last_error(tls_server_config* c):
	if (c == 0): return 0
	return c.last_error


# ---- connection ---------------------------------------------------------------

struct tls_conn:
	int fd                # socket fd, or -1 for the in-memory harness
	int use_mem
	string_builder* mem_in          # in-memory input (server bytes), for tests
	int mem_in_pos
	string_builder* mem_out         # captured client output, for tests
	int cipher_suite
	int key_len
	int key_group
	int retry_seen
	int retry_group
	string_builder* retry_cookie
	string_builder* hello
	aes_gcm_key* r_aes
	aes_gcm_key* w_aes
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
	string_builder* hs_buf
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
	# Negotiated ALPN protocol (malloc'd NUL-terminated copy), 0 when none.
	char* alpn
	# Per-wait timeout for a non-blocking fd inside a task (lib/io_wait.w),
	# -1 for none (the task's deadline still applies). Blocking fds keep
	# using SO_RCVTIMEO/SO_SNDTIMEO.
	int io_timeout_ms
	# Optional absolute deadline also bounds continuously-ready hostile peers.
	int has_io_deadline
	int io_deadline_ms
	# Checked transport mode: nonblocking syscalls + task-aware poll everywhere.
	int checked_io
	int peer_verified               # complete handshake and chain verified
	char* peer_certificate_sha256    # owned hex DER fingerprint, or 0
	int client_auth_requested
	int client_auth_p256
	int client_auth_cert_schemes      # bitset of X509_SIGALG_* values
	int last_io_status
	int last_native_error
	char* last_error                 # per-connection static diagnostic


int tls_auth_fail(tls_conn* c, int alert, char* message);
int tls_group_size(int group);
int tls_hello_has_group(char* msg, int len, int group);
void tls_set_peer_certificate(tls_conn* c, x509_cert* leaf);
int tls_parse_certificate_request(tls_conn* c, char* msg, int len);
int tls_client_send_auth(tls_conn* c);
int tls_send_certificate_request(tls_conn* c);
int tls_server_read_client_auth(tls_conn* c);
int tls_server_read_client_finished(tls_conn* c);
void tls_free_cert_list(list[x509_cert*] certs);


tls_conn* tls_conn_new(int fd, int use_mem, tls_config* cfg):
	tls_conn* c = new tls_conn()
	c.fd = fd
	c.use_mem = use_mem
	c.io_timeout_ms = 0 - 1
	c.has_io_deadline = 0
	c.io_deadline_ms = 0
	c.checked_io = 0
	c.peer_verified = 0
	c.peer_certificate_sha256 = 0
	c.client_auth_requested = 0
	c.client_auth_p256 = 0
	c.client_auth_cert_schemes = 0
	c.last_io_status = IO_OK
	c.last_native_error = 0
	c.last_error = 0
	c.mem_in = 0
	c.mem_in_pos = 0
	c.mem_out = 0
	if (use_mem != 0):
		c.mem_in = string_new_sized(256)
		c.mem_out = string_new_sized(256)
	c.cipher_suite = TLS_SUITE_CHACHA20_POLY1305_SHA256
	c.key_len = 32
	c.key_group = TLS_GROUP_X25519
	c.retry_seen = 0
	c.retry_group = 0
	c.retry_cookie = string_new()
	c.hello = string_new()
	c.r_aes = 0
	c.w_aes = 0
	c.hash_alg = WHASH_SHA256
	c.digest_size = whash_digest_size(c.hash_alg)
	c.transcript = whash_new(c.hash_alg)
	c.r_active = 0
	c.r_key = cast(char*, malloc(TLS_AEAD_KEY_LEN))
	c.r_iv = cast(char*, malloc(TLS_AEAD_IV_LEN))
	c.r_seq_hi = 0
	c.r_seq_lo = 0
	c.w_active = 0
	c.w_key = cast(char*, malloc(TLS_AEAD_KEY_LEN))
	c.w_iv = cast(char*, malloc(TLS_AEAD_IV_LEN))
	c.w_seq_hi = 0
	c.w_seq_lo = 0
	c.c_hs_secret = cast(char*, malloc(48))
	c.s_hs_secret = cast(char*, malloc(48))
	c.c_ap_secret = cast(char*, malloc(48))
	c.s_ap_secret = cast(char*, malloc(48))
	tls_wipe(c.r_key, TLS_AEAD_KEY_LEN)
	tls_wipe(c.r_iv, TLS_AEAD_IV_LEN)
	tls_wipe(c.w_key, TLS_AEAD_KEY_LEN)
	tls_wipe(c.w_iv, TLS_AEAD_IV_LEN)
	tls_wipe(c.c_hs_secret, 48)
	tls_wipe(c.s_hs_secret, 48)
	tls_wipe(c.c_ap_secret, 48)
	tls_wipe(c.s_ap_secret, 48)
	c.hs_buf = string_new_sized(512)
	c.hs_pos = 0
	c.app_buf = 0
	c.app_len = 0
	c.app_pos = 0
	c.at_eof = 0
	c.broken = 0
	c.cfg = cfg
	c.is_server = 0
	c.scfg = 0
	c.alpn = 0
	return c


# Wipe every key/secret buffer and release the connection. Safe on 0.
void tls_conn_free(tls_conn* c):
	if (c == 0): return
	aes_gcm_key_free(c.r_aes)
	aes_gcm_key_free(c.w_aes)
	string_free(c.hello)
	string_free(c.retry_cookie)
	tls_wipe(c.r_key, TLS_AEAD_KEY_LEN)
	tls_wipe(c.r_iv, TLS_AEAD_IV_LEN)
	tls_wipe(c.w_key, TLS_AEAD_KEY_LEN)
	tls_wipe(c.w_iv, TLS_AEAD_IV_LEN)
	tls_wipe(c.c_hs_secret, 48)
	tls_wipe(c.s_hs_secret, 48)
	tls_wipe(c.c_ap_secret, 48)
	tls_wipe(c.s_ap_secret, 48)
	free(c.r_key)
	free(c.r_iv)
	free(c.w_key)
	free(c.w_iv)
	free(c.c_hs_secret)
	free(c.s_hs_secret)
	free(c.c_ap_secret)
	free(c.s_ap_secret)
	if (c.peer_certificate_sha256 != 0): free(c.peer_certificate_sha256)
	if (c.transcript != 0): whash_free(c.transcript)
	if (c.hs_buf != 0): string_free(c.hs_buf)
	if (c.mem_in != 0): string_free(c.mem_in)
	if (c.mem_out != 0): string_free(c.mem_out)
	if (c.app_buf != 0):
		tls_wipe(c.app_buf, c.app_len)
		free(c.app_buf)
	if (c.alpn != 0): free(c.alpn)
	free(cast(char*, c))


# The ALPN protocol negotiated on this connection ("h2"), or 0 when none was
# (ALPN not configured, or the peer did not select one). Owned by c.
char* tls_alpn_selected(tls_conn* c):
	if (c == 0): return 0
	return c.alpn


# Store a copy of the n-byte protocol name as c.alpn.
void tls_set_alpn_selected(tls_conn* c, char* name, int n):
	if (c.alpn != 0): free(c.alpn)
	c.alpn = mem_dup(name, n)


void tls_fail(tls_conn* c, char* msg):
	c.broken = 1
	c.peer_verified = 0
	c.last_error = msg
	if (c.last_io_status == IO_OK): c.last_io_status = IO_IO_ERROR
	if (c.cfg != 0): c.cfg.last_error = msg
	if (c.scfg != 0): c.scfg.last_error = msg


# ---- raw I/O ------------------------------------------------------------------

# Keep the first I/O failure, even if sending a fatal alert also fails.
int tls_io_error(tls_conn* c, int status, int native_error, char* message):
	if (c.last_io_status == IO_OK):
		c.last_io_status = status
		c.last_native_error = native_error
		c.last_error = message
	return 0


int tls_io_remaining(tls_conn* c):
	int left = c.io_timeout_ms
	if (c.has_io_deadline):
		int deadline_left = c.io_deadline_ms - time_monotonic_ms()
		if (deadline_left <= 0): return 0
		if (left < 0 || deadline_left < left): left = deadline_left
	return left


int tls_io_wait_ready(tls_conn* c, int events):
	while (1):
		if (c.checked_io):
			int interrupted = io_check()
			if (interrupted < 0):
				return tls_io_error(c, io_status_from_errno(0 - interrupted), 0 - interrupted, c"tls: operation interrupted")
		int left = tls_io_remaining(c)
		int ready = 0
		if (c.checked_io):
			ready = io_poll(c.fd, events, left)
			if (ready == 0): return tls_io_error(c, IO_TIMED_OUT, 0, c"tls: I/O deadline expired")
		else: ready = io_wait(c.fd, events, left)
		if (ready == -4): continue
		if (ready < 0):
			io_result waited
			net_wait_result_from_syscall(&waited, ready)
			return tls_io_error(c, waited.status, waited.native_error, c"tls: readiness wait failed")
		return 1
	return 0


# Read exactly n bytes into buf. Returns 1 on success, 0 on EOF/error.
# A failed record is not resumable; the checked adapter poisons the stream.
int tls_io_recv_full(tls_conn* c, char* buf, int n):
	if (n <= 0): return 1
	if (c.use_mem != 0):
		if (c.mem_in_pos + n > c.mem_in.length): return 0
		mem_copy(buf, c.mem_in.data + c.mem_in_pos, n)
		c.mem_in_pos = c.mem_in_pos + n
		return 1
	int flags = 0
	if (c.checked_io):
		flags = 64
		if (msg_nosignal() == 0): flags = 128
	int got = 0
	while (got < n):
		if (c.checked_io):
			int interrupted = io_check()
			if (interrupted < 0):
				return tls_io_error(c, io_status_from_errno(0 - interrupted), 0 - interrupted, c"tls: operation interrupted")
		if (c.has_io_deadline && tls_io_remaining(c) == 0):
			return tls_io_error(c, IO_TIMED_OUT, 0, c"tls: I/O deadline expired")
		int r = socket_recv(c.fd, buf + got, n - got, flags)
		if (r > 0): got = got + r
		else if (r == 0): return tls_io_error(c, IO_IO_ERROR, 0, c"tls: truncated stream")
		else if (r == 0 - net_eagain()):
			if (tls_io_wait_ready(c, poll_in) == 0): return 0
		else if (r != 0 - 4):
			return tls_io_error(c, io_status_from_errno(0 - r), 0 - r, c"tls: receive failed")
	return 1


# Write all n bytes. Returns 1 on success, 0 on error.
int tls_io_send_all(tls_conn* c, char* buf, int n):
	if (n <= 0): return 1
	if (c.use_mem != 0):
		string_append_bytes(c.mem_out, buf, n)
		return 1
	int flags = msg_nosignal()
	if (c.checked_io):
		if (msg_nosignal() == 0): flags = flags | 128
		else: flags = flags | 64
	int sent = 0
	while (sent < n):
		if (c.checked_io):
			int interrupted = io_check()
			if (interrupted < 0):
				return tls_io_error(c, io_status_from_errno(0 - interrupted), 0 - interrupted, c"tls: operation interrupted")
		if (c.has_io_deadline && tls_io_remaining(c) == 0):
			return tls_io_error(c, IO_TIMED_OUT, 0, c"tls: I/O deadline expired")
		int r = socket_send(c.fd, buf + sent, n - sent, flags)
		if (r > 0): sent = sent + r
		else if (r == 0 - net_eagain()):
			if (tls_io_wait_ready(c, poll_out) == 0): return 0
		else if (r != 0 - 4):
			return tls_io_error(c, io_status_from_errno(0 - r), 0 - r, c"tls: send failed")
	return 1


# ---- record write (reusable by #203) ------------------------------------------

# Advance a hi/lo 64-bit sequence number by one.
void tls_seq_inc(int* hi, int* lo):
	if (*lo == 0x7fffffff):
		*lo = 0
		*hi = *hi + 1
	else: *lo = *lo + 1


# Send one record. When encrypted==0 the payload is written as a
# TLSPlaintext of content type `ct`. When encrypted==1 the payload plus a
# content-type trailer is sealed with the write keys into a TLSCiphertext
# whose outer type is application_data. Returns 1 on success.
int tls_send_record(tls_conn* c, int ct, char* payload, int len, int encrypted):
	if (encrypted == 0):
		if (len > TLS_MAX_PLAINTEXT): return 0
		char* phdr = cast(char*, malloc(5))
		phdr[0] = ct & 255
		phdr[1] = 3
		phdr[2] = 3
		store_be16(phdr + 3, len)
		int pok = tls_io_send_all(c, phdr, 5)
		free(phdr)
		if (pok == 0): return 0
		return tls_io_send_all(c, payload, len)

	# TLSCiphertext: inner = payload || content_type, then AEAD-sealed.
	int inner_len = len + 1
	int rec_len = inner_len + TLS_AEAD_TAG_LEN
	if (rec_len > TLS_MAX_CIPHERTEXT): return 0
	char* hdr = cast(char*, malloc(5))
	hdr[0] = TLS_CT_APPLICATION_DATA
	hdr[1] = 3
	hdr[2] = 3
	store_be16(hdr + 3, rec_len)

	char* inner = cast(char*, malloc(inner_len))
	mem_copy(inner, payload, len)
	inner[len] = ct & 255

	char* nonce = cast(char*, malloc(TLS_AEAD_IV_LEN))
	tls_nonce(c.w_iv, c.w_seq_hi, c.w_seq_lo, nonce)

	char* ctbuf = cast(char*, malloc(inner_len))
	char* tag = cast(char*, malloc(TLS_AEAD_TAG_LEN))
	int sealed = 1
	if (c.cipher_suite == TLS_SUITE_CHACHA20_POLY1305_SHA256):
		chacha20poly1305_seal(c.w_key, nonce, hdr, 5, inner, inner_len, ctbuf, tag)
	else: sealed = aes_gcm_seal(c.w_aes, nonce, hdr, 5, inner, inner_len, ctbuf, tag)
	tls_seq_inc(&c.w_seq_hi, &c.w_seq_lo)

	int ok = sealed
	if (ok != 0): ok = tls_io_send_all(c, hdr, 5)
	if (ok != 0): ok = tls_io_send_all(c, ctbuf, inner_len)
	if (ok != 0): ok = tls_io_send_all(c, tag, TLS_AEAD_TAG_LEN)

	tls_wipe(inner, inner_len)
	tls_wipe(nonce, TLS_AEAD_IV_LEN)
	free(inner)
	free(nonce)
	free(ctbuf)
	free(tag)
	free(hdr)
	return ok


# Send a 2-byte alert. Encrypted once write keys are active, else plaintext.
# Best effort during teardown; the return value is ignored by callers.
int tls_send_alert(tls_conn* c, int level, int desc):
	char* a = cast(char*, malloc(2))
	a[0] = level & 255
	a[1] = desc & 255
	int ok = tls_send_record(c, TLS_CT_ALERT, a, 2, c.w_active)
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
		char* hdr = cast(char*, malloc(5))
		if (tls_io_recv_full(c, hdr, 5) == 0):
			free(hdr)
			return 0
		int rtype = hdr[0] & 255
		int rlen = load_be16(hdr + 3)
		if (rlen > TLS_MAX_CIPHERTEXT):
			free(hdr)
			tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
			tls_fail(c, c"tls: record too long")
			return 0
		char* body = cast(char*, malloc(rlen + 1))
		if (tls_io_recv_full(c, body, rlen) == 0):
			free(hdr)
			free(body)
			return 0

		if (rtype == TLS_CT_CHANGE_CIPHER_SPEC):
			# Ignored middlebox-compat record; must be exactly {0x01}.
			free(hdr)
			free(body)
			# loop and read the next record

		else if ((c.r_active != 0) && (rtype == TLS_CT_APPLICATION_DATA)):
			if (rlen < TLS_AEAD_TAG_LEN + 1):
				free(hdr)
				free(body)
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_BAD_RECORD_MAC)
				tls_fail(c, c"tls: short ciphertext")
				return 0
			int ct_len = rlen - TLS_AEAD_TAG_LEN
			char* nonce = cast(char*, malloc(TLS_AEAD_IV_LEN))
			tls_nonce(c.r_iv, c.r_seq_hi, c.r_seq_lo, nonce)
			char* plain = cast(char*, malloc(ct_len))
			int ok = 0
			if (c.cipher_suite == TLS_SUITE_CHACHA20_POLY1305_SHA256):
				ok = chacha20poly1305_open(c.r_key, nonce, hdr, 5, body, ct_len, body + ct_len, plain)
			else: ok = aes_gcm_open(c.r_aes, nonce, hdr, 5, body, ct_len, body + ct_len, plain)
			tls_wipe(nonce, TLS_AEAD_IV_LEN)
			free(nonce)
			free(hdr)
			free(body)
			if (ok == 0):
				tls_wipe(plain, ct_len)
				free(plain)
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_BAD_RECORD_MAC)
				tls_fail(c, c"tls: bad record mac")
				return 0
			tls_seq_inc(&c.r_seq_hi, &c.r_seq_lo)
			# Strip zero padding and the content-type trailer.
			int p = ct_len - 1
			while ((p >= 0) && (plain[p] == 0)): p = p - 1
			if (p < 0):
				tls_wipe(plain, ct_len)
				free(plain)
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
				tls_fail(c, c"tls: all-padding record")
				return 0
			int inner_type = plain[p] & 255
			int data_len = p
			if (data_len > TLS_MAX_PLAINTEXT):
				tls_wipe(plain, ct_len)
				free(plain)
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
				tls_fail(c, c"tls: plaintext too long")
				return 0
			char* out = cast(char*, malloc(data_len + 1))
			mem_copy(out, plain, data_len)
			tls_wipe(plain, ct_len)
			free(plain)
			*out_type = inner_type
			*out_data = out
			*out_len = data_len
			return 1

		else:
			# Plaintext record (ServerHello, or an early alert).
			if (rtype == TLS_CT_APPLICATION_DATA):
				free(hdr)
				free(body)
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
				tls_fail(c, c"tls: application_data before keys")
				return 0
			char* out = cast(char*, malloc(rlen + 1))
			mem_copy(out, body, rlen)
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
	if (desc == TLS_ALERT_CLOSE_NOTIFY):
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
			int rem = c.hs_buf.length - c.hs_pos
			mem_copy(c.hs_buf.data, c.hs_buf.data + c.hs_pos, rem)
			c.hs_buf.length = rem
			c.hs_pos = 0
		int avail = c.hs_buf.length - c.hs_pos
		if (avail >= 4):
			int mlen = load_be24(c.hs_buf.data + c.hs_pos + 1)
			if (mlen > TLS_MAX_HANDSHAKE):
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
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
		if (tls_recv_record(c, &rtype, &data, &dlen) == 0): return 0
		if (rtype == TLS_CT_HANDSHAKE):
			string_append_bytes(c.hs_buf, data, dlen)
			free(data)
		else if (rtype == TLS_CT_ALERT):
			tls_handle_alert(c, data, dlen)
			free(data)
			return 0
		else:
			free(data)
			tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
			tls_fail(c, c"tls: unexpected record during handshake")
			return 0
	return 0


# ---- ClientHello --------------------------------------------------------------

# Build a ClientHello handshake message (type + 3-byte length + body).
# random and session_id are 32 bytes each; pubkey is the 32-byte X25519 share.
# A null or empty server_name omits the SNI extension.
# Returns a malloc'd buffer; *out_len gets its length. Reusable shape for the
# construction test.
char* tls_build_client_hello_alpn(char* server_name, char* random, char* session_id, char* pubkey, char* alpn, int alpn_len, int* out_len);


char* tls_build_client_hello(char* server_name, char* random, char* session_id, char* pubkey, int* out_len):
	return tls_build_client_hello_alpn(server_name, random, session_id, pubkey, 0, 0, out_len)


# Same, additionally offering the ALPN ProtocolNameList body (alpn, alpn_len)
# when alpn != 0 (RFC 7301 section 3.1).
char* tls_build_client_hello_group(char* server_name, char* random, char* session_id, char* pubkey, char* alpn, int alpn_len, int group, int* out_len):
	string_builder* b = string_new_sized(256)
	string_append_char(b, TLS_HS_CLIENT_HELLO)
	int lenpos = b.length
	string_append_be24(b, 0)                       # body length placeholder
	int body_start = b.length

	string_append_be16(b, 0x0303)                  # legacy_version
	string_append_bytes(b, random, 32)            # random
	string_append_char(b, 32)                       # legacy_session_id length
	string_append_bytes(b, session_id, 32)        # legacy_session_id
	string_append_be16(b, 6)                       # cipher_suites length
	string_append_be16(b, TLS_SUITE_CHACHA20_POLY1305_SHA256)
	string_append_be16(b, TLS_SUITE_AES_128_GCM_SHA256)
	string_append_be16(b, TLS_SUITE_AES_256_GCM_SHA384)
	string_append_char(b, 1)                        # legacy_compression_methods length
	string_append_char(b, 0)                        # null compression

	int extpos = b.length
	string_append_be16(b, 0)                       # extensions length placeholder
	int ext_start = b.length

	# server_name (SNI); omitted when there is no name (null or empty).
	int nlen = 0
	if (server_name != 0): nlen = strlen(server_name)
	if (nlen > 0):
		string_append_be16(b, TLS_EXT_SERVER_NAME)
		string_append_be16(b, nlen + 5)            # ext_data length
		string_append_be16(b, nlen + 3)            # ServerNameList length
		string_append_char(b, 0)                    # name_type = host_name
		string_append_be16(b, nlen)                # HostName length
		string_append_bytes(b, server_name, nlen)

	# supported_versions = TLS 1.3
	string_append_be16(b, TLS_EXT_SUPPORTED_VERSIONS)
	string_append_be16(b, 3)
	string_append_char(b, 2)                        # list length (bytes)
	string_append_be16(b, 0x0304)

	# supported_groups = X25519, secp256r1
	string_append_be16(b, TLS_EXT_SUPPORTED_GROUPS)
	string_append_be16(b, 6)
	string_append_be16(b, 4)
	string_append_be16(b, TLS_GROUP_X25519)
	string_append_be16(b, TLS_GROUP_SECP256R1)

	# signature_algorithms
	string_append_be16(b, TLS_EXT_SIGNATURE_ALGORITHMS)
	string_append_be16(b, 14)
	string_append_be16(b, 12)                      # list length
	string_append_be16(b, TLS_SIG_ECDSA_SECP256R1_SHA256)
	string_append_be16(b, TLS_SIG_ECDSA_SECP384R1_SHA384)
	string_append_be16(b, TLS_SIG_RSA_PSS_RSAE_SHA256)
	string_append_be16(b, TLS_SIG_RSA_PSS_RSAE_SHA384)
	string_append_be16(b, TLS_SIG_RSA_PKCS1_SHA256)
	string_append_be16(b, TLS_SIG_RSA_PKCS1_SHA384)

	# key_share: selected group, or only the group for HelloRetryRequest
	string_append_be16(b, TLS_EXT_KEY_SHARE)
	int share_len = tls_group_size(group)
	string_append_be16(b, share_len + 6)
	string_append_be16(b, share_len + 4)
	string_append_be16(b, group)
	string_append_be16(b, share_len)
	string_append_bytes(b, pubkey, share_len)

	# application_layer_protocol_negotiation
	if ((alpn != 0) && (alpn_len > 0)):
		string_append_be16(b, TLS_EXT_ALPN)
		string_append_be16(b, alpn_len + 2)
		string_append_be16(b, alpn_len)
		string_append_bytes(b, alpn, alpn_len)

	int ext_len = b.length - ext_start
	store_be16(b.data + extpos, ext_len)
	int body_len = b.length - body_start
	store_be24(b.data + lenpos, body_len)

	char* out = cast(char*, malloc(b.length))
	mem_copy(out, b.data, b.length)
	*out_len = b.length
	string_free(b)
	return out


# ---- ServerHello --------------------------------------------------------------

char* tls_build_client_hello_alpn(char* server_name, char* random, char* session_id, char* pubkey, char* alpn, int alpn_len, int* out_len):
	return tls_build_client_hello_group(server_name, random, session_id, pubkey, alpn, alpn_len, TLS_GROUP_X25519, out_len)


# The HelloRetryRequest sentinel random (RFC 8446 4.1.3).
char* tls_hrr_random():
	return c"\xcf\x21\xad\x74\xe5\x9a\x61\x11\xbe\x1d\x8c\x02\x1e\x65\xb8\x91\xc2\xa2\x11\x16\x7a\xbb\x8c\x5e\x07\x9e\x09\xe2\xc8\xa8\x33\x9c"


int tls_is_hrr(char* random):
	char* hrr = tls_hrr_random()
	int i = 0
	int diff = 0
	while (i < 32):
		diff = diff | ((random[i] & 255) ^ (hrr[i] & 255))
		i = i + 1
	return diff == 0


# Cipher suite controls both transcript hash and record key size.
int tls_suite_supported(int suite):
	return suite == TLS_SUITE_CHACHA20_POLY1305_SHA256 || suite == TLS_SUITE_AES_128_GCM_SHA256 || suite == TLS_SUITE_AES_256_GCM_SHA384


int tls_hello_offers_suite(char* hello, int len, int suite):
	if (len < 39): return 0
	int pos = 39 + (hello[38] & 255)
	if (pos + 2 > len): return 0
	int n = load_be16(hello + pos)
	pos += 2
	if (n < 2 || (n & 1) || n > len - pos): return 0
	for i in range(0, n, 2):
		if (load_be16(hello + pos + i) == suite): return 1
	return 0


void tls_set_suite(tls_conn* c, int suite):
	c.cipher_suite = suite
	c.key_len = 32
	if (suite == TLS_SUITE_AES_128_GCM_SHA256): c.key_len = 16
	int alg = WHASH_SHA256
	if (suite == TLS_SUITE_AES_256_GCM_SHA384): alg = WHASH_SHA384
	if (alg != c.hash_alg):
		whash_free(c.transcript)
		c.hash_alg = alg
		c.digest_size = whash_digest_size(alg)
		c.transcript = whash_new(alg)
		whash_update(c.transcript, c.hello.data, c.hello.length)


# Returns 1 for ServerHello, 2 for HelloRetryRequest, 0 on invalid input.
# Validate the entire message before committing negotiation state.
int tls_parse_server_hello(tls_conn* c, char* msg, int len, char* out_pub):
	if (len < 44 || msg[0] != TLS_HS_SERVER_HELLO || load_be24(msg + 1) != len - 4): return 0
	if (load_be16(msg + 4) != 0x0303): return 0
	int retry = tls_is_hrr(msg + 6)
	if (retry && c.retry_seen): return 0
	int sid_len = msg[38] & 255
	if (sid_len > 32 || 39 + sid_len + 5 > len): return 0
	if (c.hello.length < 39 + sid_len || sid_len != (c.hello.data[38] & 255)): return 0
	if (mem_eq(msg + 39, c.hello.data + 39, sid_len) == 0): return 0
	int pos = 39 + sid_len
	int suite = load_be16(msg + pos)
	if (tls_suite_supported(suite) == 0 || tls_hello_offers_suite(c.hello.data, c.hello.length, suite) == 0): return 0
	if (c.retry_seen && suite != c.cipher_suite): return 0
	if (msg[pos + 2] != 0): return 0
	pos += 3
	int ext_len = load_be16(msg + pos)
	pos += 2
	if (ext_len != len - pos): return 0
	int version = 0
	int group = 0
	int cookie_start = 0
	int cookie_len = 0
	while (pos < len):
		if (len - pos < 4): return 0
		int kind = load_be16(msg + pos)
		int n = load_be16(msg + pos + 2)
		pos += 4
		if (n > len - pos): return 0
		if (kind == TLS_EXT_SUPPORTED_VERSIONS):
			if (version || n != 2 || load_be16(msg + pos) != 0x0304): return 0
			version = 1
		else if (kind == TLS_EXT_KEY_SHARE):
			if (group || n < 2): return 0
			group = load_be16(msg + pos)
			int size = tls_group_size(group)
			if (size == 0): return 0
			if (retry):
				if (n != 2 || group == c.key_group): return 0
				if (tls_hello_has_group(c.hello.data, c.hello.length, group) == 0): return 0
			else:
				if (group != c.key_group || n != size + 4 || load_be16(msg + pos + 2) != size): return 0
				mem_copy(out_pub, msg + pos + 4, size)
		else if (kind == TLS_EXT_COOKIE && retry):
			if (cookie_start || n < 3 || load_be16(msg + pos) != n - 2): return 0
			cookie_start = pos
			cookie_len = n
		else: return 0
		pos += n
	if (version == 0): return 0
	if (retry):
		# A cookie-only retry is legal; an empty retry cannot change CH2.
		if (group == 0 && cookie_start == 0): return 0
		c.retry_group = group
		c.retry_cookie.length = 0
		if (cookie_start): string_append_bytes(c.retry_cookie, msg + cookie_start, cookie_len)
	else if (group == 0): return 0
	tls_set_suite(c, suite)
	if (retry): return 2
	return 1


# ---- CertificateVerify signature over the RFC 8446 4.4.3 content --------------

# Build 0x20*64 || "TLS 1.3, server CertificateVerify" || 0x00 || transcript.
# Returns a malloc'd buffer; *out_len gets its length.
char* tls_certverify_content_role(char* transcript_hash, int th_len, int client_role, int* out_len):
	char* ctx = c"TLS 1.3, server CertificateVerify"
	if (client_role): ctx = c"TLS 1.3, client CertificateVerify"
	int clen = strlen(ctx)
	int total = 64 + clen + 1 + th_len
	char* out = cast(char*, malloc(total))
	mem_fill(out, 0x20, 64)
	for i in range(clen): out[64 + i] = ctx[i]
	out[64 + clen] = 0
	mem_copy(out + 64 + clen + 1, transcript_hash, th_len)
	*out_len = total
	return out


char* tls_certverify_content(char* transcript_hash, int th_len, int* out_len):
	return tls_certverify_content_role(transcript_hash, th_len, 0, out_len)


# Verify a server CertificateVerify signature (scheme sig_scheme, raw sig
# bytes) against the leaf certificate's public key over the transcript hash.
# Returns 1 on success.
int tls_verify_certverify_role(x509_cert* leaf, int sig_scheme, char* sig, int siglen, char* transcript_hash, int th_len, int client_role):
	int clen = 0
	char* content = tls_certverify_content_role(transcript_hash, th_len, client_role, &clen)

	# Hash the signed content with the scheme's hash.
	int use_sha384 = 0
	if (sig_scheme == TLS_SIG_RSA_PSS_RSAE_SHA384): use_sha384 = 1
	if (sig_scheme == TLS_SIG_RSA_PKCS1_SHA384): use_sha384 = 1
	if (sig_scheme == TLS_SIG_ECDSA_SECP384R1_SHA384): use_sha384 = 1
	int hlen = 32
	if (use_sha384 != 0): hlen = 48
	char* digest = cast(char*, malloc(hlen))
	if (use_sha384 != 0): whash_oneshot(WHASH_SHA384, content, clen, digest)
	else: whash_oneshot(WHASH_SHA256, content, clen, digest)
	free(content)

	int ok = 0
	if (leaf.key_type == X509_KEY_RSA):
		char* n = leaf.der + leaf.rsa_n_start
		char* e = leaf.der + leaf.rsa_e_start
		if (sig_scheme == TLS_SIG_RSA_PSS_RSAE_SHA256):
			ok = rsa_pss_verify_sha256(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
		else if (sig_scheme == TLS_SIG_RSA_PSS_RSAE_SHA384):
			ok = rsa_pss_verify_sha384(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
		else if (sig_scheme == TLS_SIG_RSA_PKCS1_SHA256):
			ok = rsa_pkcs1v15_verify_sha256(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
		else if (sig_scheme == TLS_SIG_RSA_PKCS1_SHA384):
			ok = rsa_pkcs1v15_verify_sha384(n, leaf.rsa_n_len, e, leaf.rsa_e_len, sig, siglen, digest)
	else if (leaf.key_type == X509_KEY_EC_P256):
		if (sig_scheme == TLS_SIG_ECDSA_SECP256R1_SHA256):
			char* r = cast(char*, malloc(32))
			char* s = cast(char*, malloc(32))
			if (x509_ecdsa_sig_to_raw(sig, siglen, r, s) != 0):
				ok = ecdsa_p256_verify(leaf.ec_qx, leaf.ec_qy, digest, 32, r, s)
			free(r)
			free(s)

	else if (leaf.key_type == X509_KEY_EC_P384):
		if (sig_scheme == TLS_SIG_ECDSA_SECP384R1_SHA384):
			char* r = cast(char*, malloc(48))
			char* s = cast(char*, malloc(48))
			if (x509_ecdsa_sig_to_raw_width(sig, siglen, r, s, 48) != 0):
				ok = ecdsa_p384_verify(leaf.ec_qx, leaf.ec_qy, digest, hlen, r, s)
			free(r)
			free(s)

	tls_wipe(digest, hlen)
	free(digest)
	return ok


int tls_verify_certverify(x509_cert* leaf, int sig_scheme, char* sig, int siglen, char* transcript_hash, int th_len):
	return tls_verify_certverify_role(leaf, sig_scheme, sig, siglen, transcript_hash, th_len, 0)


# ---- key schedule (client handshake) ------------------------------------------

# Populate c's handshake secrets from the shared secret and the CH..SH
# transcript hash, also returning the handshake secret at out_hs (digest_size
# bytes) for the later master-secret derivation.
void tls_derive_handshake(tls_conn* c, char* ecdhe, char* th_ch_sh, char* out_hs):
	int alg = c.hash_alg
	int ds = c.digest_size
	char* zeros = cast(char*, malloc(ds))
	tls_wipe(zeros, ds)

	char* early = cast(char*, malloc(ds))
	hkdf_extract(alg, c"", 0, zeros, ds, early)

	char* derived1 = cast(char*, malloc(ds))
	tls13_derive_secret(alg, early, c"derived", 7, c"", 0, derived1)

	hkdf_extract(alg, derived1, ds, ecdhe, 32, out_hs)

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
	char* zeros = cast(char*, malloc(ds))
	tls_wipe(zeros, ds)
	char* derived2 = cast(char*, malloc(ds))
	tls13_derive_secret(alg, hs_secret, c"derived", 7, c"", 0, derived2)
	char* master = cast(char*, malloc(ds))
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
	# Initial handshakes always have an empty request context. Validate the
	# entire structure before accepting any certificate, including the tail.
	if (len < 8): return certs
	if ((msg[0] & 255) != TLS_HS_CERTIFICATE || load_be24(msg + 1) != len - 4): return certs
	if (msg[4] != 0 || load_be24(msg + 5) != len - 8): return certs
	int pos = 8
	int valid = 1
	while (pos < len):
		if (pos + 3 > len):
			valid = 0
			break
		int clen = load_be24(msg + pos)
		pos = pos + 3
		if (clen == 0 || pos + clen + 2 > len):
			valid = 0
			break
		x509_cert* cert = x509_parse(msg + pos, clen)
		if (cert == 0):
			valid = 0
			break
		certs.push(cert)
		pos = pos + clen
		int ext_len = load_be16(msg + pos)
		pos = pos + 2
		# No per-certificate extensions are negotiated by this implementation.
		if (ext_len != 0):
			valid = 0
			break
	if (valid == 0):
		tls_free_cert_list(certs)
		return new list[x509_cert*]
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
	if (have_now == 0): now_unix = tls_now_unix()
	char* store_path = 0
	if (c.cfg != 0): store_path = c.cfg.trust_store_path
	x509_trust_store* store = x509_load_trust_store(store_path)
	if (store == 0):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_INTERNAL_ERROR)
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
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_HANDSHAKE_FAILURE)
		tls_fail(c, verr)
		return 0
	return 1


# Read the encrypted server flight (EncryptedExtensions, Certificate,
# CertificateVerify, Finished), verify the signature, chain and Finished MAC,
# and stash the CH..serverFinished transcript hash into th_ch_sf. Returns 1 on
# success. Assumes read keys (server handshake) are already installed.
# Parse EncryptedExtensions (msg = handshake header + body, len total): the
# extension block must span the body exactly. An ALPN extension is accepted
# only if we offered ALPN, must name exactly one protocol, and that protocol
# must be one we offered (RFC 7301 section 3.1); the selection is stored in
# c.alpn. Other extensions are ignored. Returns 1 on success; on failure
# sends the fatal alert, marks the connection and returns 0.
int tls_client_parse_ee(tls_conn* c, char* msg, int len):
	if (len < 6):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: malformed EncryptedExtensions")
		return 0
	int ext_total = load_be16(msg + 4)
	if (6 + ext_total != len):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: malformed EncryptedExtensions")
		return 0
	int pos = 6
	int seen_alpn = 0
	while (pos < len):
		if (pos + 4 > len):
			tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
			tls_fail(c, c"tls: malformed EncryptedExtensions")
			return 0
		int etype = load_be16(msg + pos)
		int elen = load_be16(msg + pos + 2)
		pos = pos + 4
		if (pos + elen > len):
			tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
			tls_fail(c, c"tls: malformed EncryptedExtensions")
			return 0
		if (etype == TLS_EXT_ALPN):
			char* offered = 0
			int offered_len = 0
			if (c.cfg != 0):
				offered = c.cfg.alpn
				offered_len = c.cfg.alpn_len
			if (offered == 0):
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNSUPPORTED_EXTENSION)
				tls_fail(c, c"tls: unsolicited ALPN extension")
				return 0
			if (seen_alpn != 0):
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_ILLEGAL_PARAMETER)
				tls_fail(c, c"tls: duplicate ALPN extension")
				return 0
			seen_alpn = 1
			# ProtocolNameList with exactly one non-empty name.
			if (elen < 4):
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
				tls_fail(c, c"tls: malformed ALPN selection")
				return 0
			int list_len = load_be16(msg + pos)
			int nlen = msg[pos + 2] & 255
			if ((list_len != elen - 2) || (nlen == 0) || (1 + nlen != list_len)):
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
				tls_fail(c, c"tls: malformed ALPN selection")
				return 0
			if (tls_alpn_list_contains(offered, offered_len, msg + pos + 3, nlen) == 0):
				tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_ILLEGAL_PARAMETER)
				tls_fail(c, c"tls: server selected an ALPN protocol we did not offer")
				return 0
			tls_set_alpn_selected(c, msg + pos + 3, nlen)
		pos = pos + elen
	return 1


int tls_read_server_flight(tls_conn* c, char* server_name, char* th_ch_sf):
	int ds = c.digest_size
	int htype = 0
	char* msg = 0
	int mlen = 0

	# EncryptedExtensions
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0): return 0
	if (htype != TLS_HS_ENCRYPTED_EXTENSIONS):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
		tls_fail(c, c"tls: expected EncryptedExtensions")
		return 0
	if (tls_client_parse_ee(c, msg, mlen) == 0): return 0
	whash_update(c.transcript, msg, mlen)

	# Optional CertificateRequest precedes the server Certificate.
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0): return 0
	if (htype == TLS_HS_CERTIFICATE_REQUEST):
		if (tls_parse_certificate_request(c, msg, mlen) == 0): return 0
		whash_update(c.transcript, msg, mlen)
		if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0): return 0
	if (c.cfg != 0):
		if (c.cfg.require_client_auth && c.client_auth_requested == 0):
			return tls_auth_fail(c, TLS_ALERT_HANDSHAKE_FAILURE, c"tls: server omitted CertificateRequest")
	if (htype != TLS_HS_CERTIFICATE):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
		tls_fail(c, c"tls: expected Certificate")
		return 0
	list[x509_cert*] certs = tls_parse_certificate(msg, mlen)
	whash_update(c.transcript, msg, mlen)
	if (certs.length == 0):
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: no certificate")
		return 0
	char* th_cert = cast(char*, malloc(ds))
	whash_final(c.transcript, th_cert)

	# CertificateVerify
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		free(th_cert)
		tls_free_cert_list(certs)
		return 0
	if (htype != TLS_HS_CERTIFICATE_VERIFY):
		free(th_cert)
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
		tls_fail(c, c"tls: expected CertificateVerify")
		return 0
	if (mlen < 8):
		free(th_cert)
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: short CertificateVerify")
		return 0
	int sig_scheme = load_be16(msg + 4)
	int sig_len = load_be16(msg + 6)
	if (8 + sig_len != mlen):
		free(th_cert)
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: bad CertificateVerify length")
		return 0
	# Copy the signature out before hs_buf can move.
	char* sig = cast(char*, malloc(sig_len))
	mem_copy(sig, msg + 8, sig_len)
	int cvok = tls_verify_certverify(certs[0], sig_scheme, sig, sig_len, th_cert, ds)
	free(sig)
	free(th_cert)
	if (cvok == 0):
		tls_free_cert_list(certs)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECRYPT_ERROR)
		tls_fail(c, c"tls: CertificateVerify failed")
		return 0
	whash_update(c.transcript, msg, mlen)
	char* th_cv = cast(char*, malloc(ds))
	whash_final(c.transcript, th_cv)

	# Certificate chain + hostname, unless explicitly skipped.
	int skip = 0
	if (c.cfg != 0): skip = c.cfg.insecure_skip_verify
	if (skip == 0):
		if (tls_check_chain(c, certs, server_name) == 0):
			free(th_cv)
			tls_free_cert_list(certs)
			return 0
		tls_set_peer_certificate(c, certs[0])

	tls_free_cert_list(certs)

	# server Finished: HMAC(server_finished_key, TH(CH..CertificateVerify)).
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		free(th_cv)
		return 0
	if (htype != TLS_HS_FINISHED):
		free(th_cv)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
		tls_fail(c, c"tls: expected Finished")
		return 0
	int vd_len = mlen - 4
	if (vd_len != ds):
		free(th_cv)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: bad Finished length")
		return 0
	char* fkey = cast(char*, malloc(ds))
	tls_finished_key(c.hash_alg, c.s_hs_secret, fkey)
	char* expected = cast(char*, malloc(ds))
	hmac_compute(c.hash_alg, fkey, ds, th_cv, ds, expected)
	char* got = cast(char*, malloc(ds))
	mem_copy(got, msg + 4, ds)
	int fin_ok = hmac_equal(expected, got, ds)
	tls_wipe(fkey, ds)
	free(fkey)
	free(expected)
	free(got)
	free(th_cv)
	if (fin_ok == 0):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECRYPT_ERROR)
		tls_fail(c, c"tls: server Finished verify failed")
		return 0
	whash_update(c.transcript, msg, mlen)
	# Snapshot CH..serverFinished for the application secrets + client Finished.
	whash_final(c.transcript, th_ch_sf)
	if (skip == 0): c.peer_verified = 1
	return 1


# Install the read protection derived from a traffic secret.
void tls_install_read_keys(tls_conn* c, char* secret):
	tls13_hkdf_expand_label(c.hash_alg, secret, c"key", 3, c"", 0, c.r_key, c.key_len)
	tls13_hkdf_expand_label(c.hash_alg, secret, c"iv", 2, c"", 0, c.r_iv, 12)
	aes_gcm_key_free(c.r_aes)
	c.r_aes = 0
	if (c.cipher_suite != TLS_SUITE_CHACHA20_POLY1305_SHA256): c.r_aes = aes_gcm_key_new(c.r_key, c.key_len)
	c.r_seq_hi = 0
	c.r_seq_lo = 0
	c.r_active = 1


void tls_install_write_keys(tls_conn* c, char* secret):
	tls13_hkdf_expand_label(c.hash_alg, secret, c"key", 3, c"", 0, c.w_key, c.key_len)
	tls13_hkdf_expand_label(c.hash_alg, secret, c"iv", 2, c"", 0, c.w_iv, 12)
	aes_gcm_key_free(c.w_aes)
	c.w_aes = 0
	if (c.cipher_suite != TLS_SUITE_CHACHA20_POLY1305_SHA256): c.w_aes = aes_gcm_key_new(c.w_key, c.key_len)
	c.w_seq_hi = 0
	c.w_seq_lo = 0
	c.w_active = 1


# Generate the ephemeral private key (or use the injected one). Returns 1 on
# success writing 32 bytes to priv.
int tls_gen_priv(tls_conn* c, char* priv):
	if (c.cfg != 0):
		if (c.cfg.test_priv != 0):
			mem_copy(priv, c.cfg.test_priv, 32)
			return 1
	return random_bytes(priv, 32)


int tls_group_size(int group):
	if (group == TLS_GROUP_X25519): return 32
	if (group == TLS_GROUP_SECP256R1): return 65
	return 0


# Return the extension-vector length offset, validating the variable prefix.
int tls_hello_extensions(char* msg, int len):
	if (len < 39 || msg[0] != TLS_HS_CLIENT_HELLO || load_be24(msg + 1) != len - 4): return -1
	if (load_be16(msg + 4) != 0x0303 || (msg[38] & 255) > 32): return -1
	int pos = 39 + (msg[38] & 255)
	if (pos + 2 > len): return -1
	int n = load_be16(msg + pos)
	pos += 2
	if (n < 2 || (n & 1) || n > len - pos): return -1
	pos += n
	if (pos + 2 > len || msg[pos] != 1 || msg[pos + 1] != 0): return -1
	pos += 2
	if (pos + 2 > len || load_be16(msg + pos) != len - pos - 2): return -1
	return pos


int tls_hello_has_group(char* msg, int len, int group):
	int start = tls_hello_extensions(msg, len)
	if (start < 0): return 0
	int pos = start + 2
	int found = 0
	int seen = 0
	while (pos < len):
		if (len - pos < 4): return 0
		int kind = load_be16(msg + pos)
		int n = load_be16(msg + pos + 2)
		pos += 4
		if (n > len - pos): return 0
		if (kind == TLS_EXT_SUPPORTED_GROUPS):
			if (seen || n < 4 || (n & 1) || load_be16(msg + pos) != n - 2): return 0
			seen = 1
			for i in range(2, n, 2):
				if (load_be16(msg + pos + i) == group): found = 1
		pos += n
	return found


int tls_make_key_share(tls_conn* c, int group, char* priv, char* pub, int server):
	char* injected = 0
	if (server):
		if (c.scfg != 0): injected = c.scfg.test_priv
	else:
		if (c.cfg != 0): injected = c.cfg.test_priv
	int ok = 0
	if (injected != 0):
		mem_copy(priv, injected, 32)
		ok = 1
	else if (group == TLS_GROUP_SECP256R1): ok = ecdh_p256_generate(priv)
	else: ok = random_bytes(priv, 32)
	if (ok == 0): return 0
	if (group == TLS_GROUP_SECP256R1): return ecdh_p256_public_key(priv, pub)
	if (group != TLS_GROUP_X25519): return 0
	x25519_scalarmult_base(pub, priv)
	return 1


int tls_shared_secret(int group, char* priv, char* pub, char* out):
	if (group == TLS_GROUP_SECP256R1): return ecdh_p256_shared_secret(priv, pub, 65, out)
	if (group != TLS_GROUP_X25519): return 0
	return x25519_scalarmult(out, priv, pub) == 0


# RFC 8446 4.4.1 replaces ClientHello1 with message_hash(Hash(CH1)).
void tls_retry_transcript(tls_conn* c, char* hrr, int len):
	char* synthetic = cast(char*, malloc(4 + c.digest_size))
	synthetic[0] = 254
	store_be24(synthetic + 1, c.digest_size)
	whash_final(c.transcript, synthetic + 4)
	whash_free(c.transcript)
	c.transcript = whash_new(c.hash_alg)
	whash_update(c.transcript, synthetic, 4 + c.digest_size)
	whash_update(c.transcript, hrr, len)
	free(synthetic)
	c.retry_seen = 1


# Preserve CH1 byte-for-byte except for the requested key share and cookie.
# In particular random, session ID, SNI, ALPN, suites and groups stay fixed.
char* tls_retry_client_hello(char* first, int len, int group, char* pub, string_builder* cookie, int* out_len):
	int ext = tls_hello_extensions(first, len)
	if (ext < 0): return 0
	string_builder* b = string_new()
	string_append_bytes(b, first, ext + 2)
	int pos = ext + 2
	while (pos < len):
		if (len - pos < 4):
			string_free(b)
			return 0
		int kind = load_be16(first + pos)
		int n = load_be16(first + pos + 2)
		if (n > len - pos - 4):
			string_free(b)
			return 0
		if (kind == TLS_EXT_KEY_SHARE && group != 0):
			int size = tls_group_size(group)
			string_append_be16(b, kind)
			string_append_be16(b, size + 6)
			string_append_be16(b, size + 4)
			string_append_be16(b, group)
			string_append_be16(b, size)
			string_append_bytes(b, pub, size)
		else if (kind != TLS_EXT_COOKIE): string_append_bytes(b, first + pos, n + 4)
		pos += n + 4
	if (cookie.length):
		string_append_be16(b, TLS_EXT_COOKIE)
		string_append_be16(b, cookie.length)
		string_append_bytes(b, cookie.data, cookie.length)
	store_be16(b.data + ext, b.length - ext - 2)
	store_be24(b.data + 1, b.length - 4)
	*out_len = b.length
	char* result = b.data
	free(b)
	return result


int tls_client_key_exchange(tls_conn* c, char* server_name, char* shared):
	int group = TLS_GROUP_X25519
	if (c.cfg != 0 && c.cfg.key_share_group != 0): group = c.cfg.key_share_group
	if (tls_group_size(group) == 0):
		tls_fail(c, c"tls: unsupported initial key share group")
		return 0
	c.key_group = group
	char* priv = cast(char*, malloc(32))
	char* pub = cast(char*, malloc(65))
	char* peer = cast(char*, malloc(65))
	char* ch = 0
	int ch_len = 0
	int ok = 0
	while (1):
		if (tls_make_key_share(c, group, priv, pub, 0) == 0):
			tls_fail(c, c"tls: RNG or private key failure")
			break
		if (c.cfg != 0 && c.cfg.test_client_hello != 0):
			ch_len = c.cfg.test_client_hello_len
			ch = mem_dup(c.cfg.test_client_hello, ch_len)
		else:
			char* rnd = cast(char*, malloc(32))
			char* sid = cast(char*, malloc(32))
			int random_ok = random_bytes(rnd, 32) && random_bytes(sid, 32)
			if (random_ok):
				char* alpn = 0
				int alpn_len = 0
				if (c.cfg != 0):
					alpn = c.cfg.alpn
					alpn_len = c.cfg.alpn_len
				ch = tls_build_client_hello_group(server_name, rnd, sid, pub, alpn, alpn_len, group, &ch_len)
			free(rnd)
			free(sid)
			if (random_ok == 0):
				tls_fail(c, c"tls: RNG failure")
				break
		string_append_bytes(c.hello, ch, ch_len)
		whash_update(c.transcript, ch, ch_len)
		if (tls_send_record(c, TLS_CT_HANDSHAKE, ch, ch_len, 0) == 0):
			tls_fail(c, c"tls: send ClientHello failed")
			break
		int kind = 0
		char* msg = 0
		int len = 0
		if (tls_next_hs_msg(c, &kind, &msg, &len) == 0): break
		int parsed = tls_parse_server_hello(c, msg, len, peer)
		if (kind != TLS_HS_SERVER_HELLO): parsed = 0
		if (parsed == 2):
			tls_retry_transcript(c, msg, len)
			if (c.retry_group != 0):
				c.key_group = c.retry_group
				tls_wipe(priv, 32)
				if (tls_make_key_share(c, c.key_group, priv, pub, 0) == 0):
					tls_fail(c, c"tls: RNG or private key failure")
					break
			free(ch)
			ch = tls_retry_client_hello(c.hello.data, c.hello.length, c.retry_group, pub, c.retry_cookie, &ch_len)
			if (ch == 0):
				tls_auth_fail(c, TLS_ALERT_ILLEGAL_PARAMETER, c"tls: cannot construct second ClientHello")
				break
			c.hello.length = 0
			string_append_bytes(c.hello, ch, ch_len)
			whash_update(c.transcript, ch, ch_len)
			if (tls_send_record(c, TLS_CT_HANDSHAKE, ch, ch_len, 0) == 0):
				tls_fail(c, c"tls: send second ClientHello failed")
				break
			if (tls_next_hs_msg(c, &kind, &msg, &len) == 0): break
			parsed = tls_parse_server_hello(c, msg, len, peer)
			if (kind != TLS_HS_SERVER_HELLO): parsed = 0
		if (parsed != 1):
			tls_auth_fail(c, TLS_ALERT_ILLEGAL_PARAMETER, c"tls: bad ServerHello or HelloRetryRequest")
			break
		whash_update(c.transcript, msg, len)
		if (tls_shared_secret(c.key_group, priv, peer, shared) == 0):
			tls_auth_fail(c, TLS_ALERT_ILLEGAL_PARAMETER, c"tls: bad key share")
			break
		ok = 1
		break
	if (ch != 0): free(ch)
	tls_wipe(priv, 32)
	free(priv)
	free(pub)
	free(peer)
	return ok


# Drive the full client handshake on connection c. server_name is the SNI /
# hostname to verify; a null or empty one fails ("tls: no server name to
# verify") before anything is sent, unless cfg.insecure_skip_verify is set,
# in which case the ClientHello carries no SNI. Returns 1 on success (keys switched to application), 0
# on any failure (connection marked broken, alert already sent).
int tls_do_handshake(tls_conn* c, char* server_name):
	tls_config* cfg = c.cfg
	int ds = c.digest_size

	# No server name means no identity to verify: fail before any I/O
	# unless verification was explicitly skipped (then SNI is omitted).
	int has_name = 0
	if (server_name != 0):
		if (server_name[0] != 0): has_name = 1
	if (has_name == 0):
		int skip_verify = 0
		if (cfg != 0): skip_verify = cfg.insecure_skip_verify
		if (skip_verify == 0):
			tls_fail(c, c"tls: no server name to verify")
			return 0

	char* ecdhe = cast(char*, malloc(32))
	if (tls_client_key_exchange(c, server_name, ecdhe) == 0):
		tls_wipe(ecdhe, 32)
		free(ecdhe)
		return 0
	ds = c.digest_size
	# Handshake key schedule over CH..SH.
	char* th_ch_sh = cast(char*, malloc(ds))
	whash_final(c.transcript, th_ch_sh)
	char* hs_secret = cast(char*, malloc(ds))
	tls_derive_handshake(c, ecdhe, th_ch_sh, hs_secret)
	tls_wipe(ecdhe, 32)
	free(ecdhe)
	free(th_ch_sh)

	# Install server handshake read keys and read the encrypted flight.
	tls_install_read_keys(c, c.s_hs_secret)
	char* th_ch_sf = cast(char*, malloc(ds))
	if (tls_read_server_flight(c, server_name, th_ch_sf) == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		free(th_ch_sf)
		return 0

	# Client Finished: HMAC(client_finished_key, TH(CH..serverFinished)),
	# sent under the client handshake write keys.
	tls_install_write_keys(c, c.c_hs_secret)
	if (c.client_auth_requested):
		if (tls_client_send_auth(c) == 0):
			tls_wipe(hs_secret, ds)
			free(hs_secret)
			free(th_ch_sf)
			return 0
	char* th_client = cast(char*, malloc(ds))
	whash_final(c.transcript, th_client)
	char* cfkey = cast(char*, malloc(ds))
	tls_finished_key(c.hash_alg, c.c_hs_secret, cfkey)
	char* cvd = cast(char*, malloc(ds))
	hmac_compute(c.hash_alg, cfkey, ds, th_client, ds, cvd)
	free(th_client)
	tls_wipe(cfkey, ds)
	free(cfkey)
	char* fin = cast(char*, malloc(4 + ds))
	fin[0] = TLS_HS_FINISHED
	fin[1] = 0
	fin[2] = 0
	fin[3] = ds
	mem_copy(fin + 4, cvd, ds)
	free(cvd)
	int fsent = tls_send_record(c, TLS_CT_HANDSHAKE, fin, 4 + ds, 1)
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

# tls_connect with a per-wait bound for a non-blocking socket inside a task
# (lib/io_wait.w): every wait during the handshake and afterwards is
# bounded by io_timeout_ms (-1: only the task's deadline).
tls_conn* tls_connect_timeout(int sockfd, char* server_name, tls_config* cfg, int io_timeout_ms):
	tls_conn* c = tls_conn_new(sockfd, 0, cfg)
	c.io_timeout_ms = io_timeout_ms
	if (tls_do_handshake(c, server_name) == 0):
		tls_conn_free(c)
		return 0
	return c


# Handshake over an already-connected TCP socket. Returns an owned tls_conn*
# on success, 0 on failure (reason in tls_last_error(cfg)).
tls_conn* tls_connect(int sockfd, char* server_name, tls_config* cfg):
	return tls_connect_timeout(sockfd, server_name, cfg, 0 - 1)


# In-memory handshake harness (tests): server bytes preloaded, client output
# captured. Not part of the public API.
tls_conn* tls_connect_mem(char* server_flight, int flen, char* server_name, tls_config* cfg):
	tls_conn* c = tls_conn_new(0 - 1, 1, cfg)
	string_append_bytes(c.mem_in, server_flight, flen)
	if (tls_do_handshake(c, server_name) == 0):
		tls_conn_free(c)
		return 0
	return c


# Append more server bytes to an in-memory connection (tests).
void tls_mem_feed(tls_conn* c, char* data, int len):
	string_append_bytes(c.mem_in, data, len)


# Take the captured client output, clearing the buffer (tests). Returns a
# malloc'd copy; *out_len gets its length.
char* tls_mem_take_output(tls_conn* c, int* out_len):
	int n = c.mem_out.length
	char* out = cast(char*, malloc(n + 1))
	mem_copy(out, c.mem_out.data, n)
	c.mem_out.length = 0
	*out_len = n
	return out


# Re-key one direction after a KeyUpdate (RFC 8446 7.2): the traffic secret
# advances by HKDF-Expand-Label(secret, "traffic upd", "", Hash.length).
void tls_update_secret(int alg, char* secret, int ds):
	char* next = cast(char*, malloc(ds))
	tls13_hkdf_expand_label(alg, secret, c"traffic upd", 11, c"", 0, next, ds)
	mem_copy(secret, next, ds)
	tls_wipe(next, ds)
	free(next)


# Handle a post-handshake handshake message (NewSessionTicket ignored,
# KeyUpdate re-keys the read side and answers when requested). Symmetric
# across roles: the read side re-keys the PEER's application secret and, when
# update_requested, our own write side re-keys OUR application secret. For a
# client our write secret is c_ap and read is s_ap; for a server it is the
# mirror image (is_server flips them).
void tls_post_handshake(tls_conn* c, char* data, int dlen):
	if (dlen < 4): return
	int mt = data[0] & 255
	if (mt == TLS_HS_KEY_UPDATE):
		int req = 0
		if (dlen >= 5): req = data[4] & 255
		char* read_secret = c.s_ap_secret
		char* write_secret = c.c_ap_secret
		if (c.is_server != 0):
			read_secret = c.c_ap_secret
			write_secret = c.s_ap_secret
		tls_update_secret(c.hash_alg, read_secret, c.digest_size)
		tls_install_read_keys(c, read_secret)
		if (req == 1):
			char* ku = cast(char*, malloc(5))
			ku[0] = TLS_HS_KEY_UPDATE
			ku[1] = 0
			ku[2] = 0
			ku[3] = 1
			ku[4] = 0
			tls_send_record(c, TLS_CT_HANDSHAKE, ku, 5, 1)
			free(ku)
			tls_update_secret(c.hash_alg, write_secret, c.digest_size)
			tls_install_write_keys(c, write_secret)


# Read up to len application-data bytes. Returns the number read (>0), 0 at
# clean EOF (close_notify), or -1 on error.
int tls_read(tls_conn* c, char* buf, int len):
	if (c.broken != 0): return 0 - 1
	if (len <= 0): return 0
	# Drain any buffered plaintext first.
	if (c.app_pos < c.app_len):
		int avail = c.app_len - c.app_pos
		int n = len
		if (n > avail): n = avail
		mem_copy(buf, c.app_buf + c.app_pos, n)
		c.app_pos = c.app_pos + n
		if (c.app_pos >= c.app_len):
			tls_wipe(c.app_buf, c.app_len)
			free(c.app_buf)
			c.app_buf = 0
			c.app_len = 0
			c.app_pos = 0
		return n
	if (c.at_eof != 0): return 0

	while (1 == 1):
		int rtype = 0
		char* data = 0
		int dlen = 0
		if (tls_recv_record(c, &rtype, &data, &dlen) == 0):
			if (c.at_eof != 0): return 0
			return 0 - 1
		if (rtype == TLS_CT_APPLICATION_DATA):
			if (dlen == 0):
				free(data)
				# empty record: keep reading
			else:
				c.app_buf = data
				c.app_len = dlen
				c.app_pos = 0
				int n = len
				if (n > dlen): n = dlen
				mem_copy(buf, c.app_buf, n)
				c.app_pos = n
				if (c.app_pos >= c.app_len):
					tls_wipe(c.app_buf, c.app_len)
					free(c.app_buf)
					c.app_buf = 0
					c.app_len = 0
					c.app_pos = 0
				return n
		else if (rtype == TLS_CT_ALERT):
			int cn = tls_handle_alert(c, data, dlen)
			free(data)
			if (cn != 0): return 0
			return 0 - 1
		else if (rtype == TLS_CT_HANDSHAKE):
			tls_post_handshake(c, data, dlen)
			free(data)
		else: free(data)
	return 0 - 1


# Write len bytes as one or more application_data records. Returns len on
# success, -1 on error. Fragments to the plaintext cap.
int tls_write(tls_conn* c, char* buf, int len):
	if (c.broken != 0): return 0 - 1
	if (len <= 0): return 0
	int sent = 0
	while (sent < len):
		int chunk = len - sent
		if (chunk > TLS_MAX_PLAINTEXT): chunk = TLS_MAX_PLAINTEXT
		if (tls_send_record(c, TLS_CT_APPLICATION_DATA, buf + sent, chunk, 1) == 0):
			tls_fail(c, c"tls: write failed")
			return 0 - 1
		sent = sent + chunk
	return len


# Send close_notify (best effort) and free the connection, wiping all keys.
void tls_close(tls_conn* c):
	if (c == 0): return
	if (c.broken == 0): tls_send_alert(c, TLS_ALERT_WARNING, TLS_ALERT_CLOSE_NOTIFY)
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

# Validate extension framing and reject duplicate extension types.
int tls_extensions_valid(char* msg, int len, int start):
	char* seen = cast(char*, malloc(8192))
	mem_fill(seen, 0, 8192)
	int pos = start
	int ok = 1
	while (pos < len):
		if (len - pos < 4):
			ok = 0
			break
		int kind = load_be16(msg + pos)
		int n = load_be16(msg + pos + 2)
		int mask = 1 << (kind & 7)
		if (n > len - pos - 4 || (seen[kind >> 3] & mask)):
			ok = 0
			break
		seen[kind >> 3] |= mask
		pos += n + 4
	free(seen)
	return ok


# Validate every KeyShareEntry, including unknown groups, in linear time.
# In CH2 the vector must contain exactly the single requested share.
int tls_key_shares_valid(char* msg, int len, int pos, int n):
	if (n < 2 || load_be16(msg + pos) != n - 2): return 0
	char* seen = cast(char*, malloc(8192))
	mem_fill(seen, 0, 8192)
	int kp = pos + 2
	int ok = 1
	while (kp < pos + n):
		if (pos + n - kp < 4):
			ok = 0
			break
		int group = load_be16(msg + kp)
		int size = load_be16(msg + kp + 2)
		int mask = 1 << (group & 7)
		if (size == 0 || size > pos + n - kp - 4 || (seen[group >> 3] & mask) || tls_hello_has_group(msg, len, group) == 0):
			ok = 0
			break
		seen[group >> 3] |= mask
		kp += size + 4
	free(seen)
	return ok


int tls_retry_single_share(char* msg, int len, int group):
	int ext = tls_hello_extensions(msg, len)
	if (ext < 0 || tls_extensions_valid(msg, len, ext + 2) == 0): return 0
	int pos = ext + 2
	while (pos < len):
		int kind = load_be16(msg + pos)
		int n = load_be16(msg + pos + 2)
		if (kind == TLS_EXT_KEY_SHARE):
			if (n != tls_group_size(group) + 6): return 0
			return load_be16(msg + pos + 6) == group
		pos += n + 4
	return 0


# A positive selected_group has a key share; negative requests a retry.
int tls_parse_client_hello_options(char* msg, int len, char* out_random, char* out_sid, int* out_sid_len, char* out_pub, int* selected_suite, int* selected_group, int* have_tls13, int* have_ecdsa, int preferred_suite, int preferred_group):
	*selected_suite = 0
	*selected_group = 0
	*have_tls13 = 0
	*have_ecdsa = 0
	int ext = tls_hello_extensions(msg, len)
	if (ext < 0 || tls_extensions_valid(msg, len, ext + 2) == 0): return 0
	mem_copy(out_random, msg + 6, 32)
	*out_sid_len = msg[38] & 255
	mem_copy(out_sid, msg + 39, *out_sid_len)
	if (preferred_suite != 0):
		if (tls_hello_offers_suite(msg, len, preferred_suite)): *selected_suite = preferred_suite
	else if (tls_hello_offers_suite(msg, len, TLS_SUITE_CHACHA20_POLY1305_SHA256)): *selected_suite = TLS_SUITE_CHACHA20_POLY1305_SHA256
	else if (tls_hello_offers_suite(msg, len, TLS_SUITE_AES_128_GCM_SHA256)): *selected_suite = TLS_SUITE_AES_128_GCM_SHA256
	else if (tls_hello_offers_suite(msg, len, TLS_SUITE_AES_256_GCM_SHA384)): *selected_suite = TLS_SUITE_AES_256_GCM_SHA384
	int pos = ext + 2
	while (pos < len):
		int kind = load_be16(msg + pos)
		int n = load_be16(msg + pos + 2)
		pos += 4
		if (kind == TLS_EXT_SUPPORTED_VERSIONS):
			if (n < 3 || (msg[pos] & 255) != n - 1 || ((n - 1) & 1)): return 0
			for i in range(1, n, 2):
				if (load_be16(msg + pos + i) == 0x0304): *have_tls13 = 1
		else if (kind == TLS_EXT_SIGNATURE_ALGORITHMS):
			if (n < 4 || load_be16(msg + pos) != n - 2 || (n & 1)): return 0
			for i in range(2, n, 2):
				if (load_be16(msg + pos + i) == TLS_SIG_ECDSA_SECP256R1_SHA256): *have_ecdsa = 1
		else if (kind == TLS_EXT_KEY_SHARE):
			if (tls_key_shares_valid(msg, len, pos, n) == 0): return 0
			int kp = pos + 2
			while (kp < pos + n):
				if (pos + n - kp < 4): return 0
				int group = load_be16(msg + kp)
				int size = load_be16(msg + kp + 2)
				kp += 4
				if (size == 0 || size > pos + n - kp): return 0
				if (tls_group_size(group) != 0):
					if (size != tls_group_size(group) || tls_hello_has_group(msg, len, group) == 0): return 0
					if (preferred_group == 0 || preferred_group == group):
						if (*selected_group == 0 || group == TLS_GROUP_X25519):
							*selected_group = group
							mem_copy(out_pub, msg + kp, size)
				kp += size
		pos += n
	if (*selected_group == 0):
		int wanted = preferred_group
		if (wanted == 0):
			if (tls_hello_has_group(msg, len, TLS_GROUP_X25519)): wanted = TLS_GROUP_X25519
			else: wanted = TLS_GROUP_SECP256R1
		if (tls_hello_has_group(msg, len, wanted)): *selected_group = 0 - wanted
	return 1


int tls_parse_client_hello(char* msg, int len, char* out_random, char* out_sid, int* out_sid_len, char* out_pub, int* suite, int* group, int* have_tls13, int* have_ecdsa):
	return tls_parse_client_hello_options(msg, len, out_random, out_sid, out_sid_len, out_pub, suite, group, have_tls13, have_ecdsa, 0, 0)


# ---- server flight builders ---------------------------------------------------

# Build ServerHello or, when server_pub is null, HelloRetryRequest.
# The caller supplies the negotiated suite/group and echoed session ID.
char* tls_build_server_hello_group(char* random, char* sid, int sid_len, char* server_pub, int suite, int group, int* out_len):
	string_builder* b = string_new_sized(128)
	string_append_char(b, TLS_HS_SERVER_HELLO)
	int lenpos = b.length
	string_append_be24(b, 0)                        # body length placeholder
	int body_start = b.length
	string_append_be16(b, 0x0303)                   # legacy_version
	string_append_bytes(b, random, 32)             # random
	string_append_char(b, sid_len)                   # legacy_session_id_echo length
	if (sid_len > 0): string_append_bytes(b, sid, sid_len)
	string_append_be16(b, suite)
	string_append_char(b, 0)                         # legacy_compression_method = null
	int extpos = b.length
	string_append_be16(b, 0)                        # extensions length placeholder
	int ext_start = b.length
	# supported_versions = TLS 1.3
	string_append_be16(b, TLS_EXT_SUPPORTED_VERSIONS)
	string_append_be16(b, 2)
	string_append_be16(b, 0x0304)
	# key_share: selected group, or only the group for HelloRetryRequest
	string_append_be16(b, TLS_EXT_KEY_SHARE)
	int size = tls_group_size(group)
	if (server_pub == 0):
		string_append_be16(b, 2)
		string_append_be16(b, group)
	else:
		string_append_be16(b, size + 4)
		string_append_be16(b, group)
		string_append_be16(b, size)
		string_append_bytes(b, server_pub, size)
	int ext_len = b.length - ext_start
	store_be16(b.data + extpos, ext_len)
	int body_len = b.length - body_start
	store_be24(b.data + lenpos, body_len)
	char* out = cast(char*, malloc(b.length))
	mem_copy(out, b.data, b.length)
	*out_len = b.length
	string_free(b)
	return out


char* tls_build_server_hello(char* random, char* sid, int sid_len, char* server_pub, int* out_len):
	return tls_build_server_hello_group(random, sid, sid_len, server_pub, TLS_SUITE_CHACHA20_POLY1305_SHA256, TLS_GROUP_X25519, out_len)


# Build an empty EncryptedExtensions (no extensions negotiated: no ALPN, no
# early data, no server_name ack). type(1)+len(3)+extensions_length(2)=0.
char* tls_build_encrypted_extensions(int* out_len):
	char* m = cast(char*, malloc(6))
	m[0] = TLS_HS_ENCRYPTED_EXTENSIONS
	m[1] = 0
	m[2] = 0
	m[3] = 2
	m[4] = 0
	m[5] = 0
	*out_len = 6
	return m


# Build EncryptedExtensions carrying the selected ALPN protocol (RFC 7301
# section 3.1: a ProtocolNameList with exactly one name), or the empty form
# when proto is 0.
char* tls_build_encrypted_extensions_alpn(char* proto, int* out_len):
	if (proto == 0): return tls_build_encrypted_extensions(out_len)
	int n = strlen(proto)
	string_builder* b = string_new_sized(16 + n)
	string_append_char(b, TLS_HS_ENCRYPTED_EXTENSIONS)
	string_append_be24(b, 2 + 4 + 2 + 1 + n)       # body length
	string_append_be16(b, 4 + 2 + 1 + n)           # extensions length
	string_append_be16(b, TLS_EXT_ALPN)
	string_append_be16(b, 2 + 1 + n)               # ext_data length
	string_append_be16(b, 1 + n)                   # ProtocolNameList length
	string_append_char(b, n)
	string_append_bytes(b, proto, n)
	char* out = cast(char*, malloc(b.length))
	mem_copy(out, b.data, b.length)
	*out_len = b.length
	string_free(b)
	return out


# Build a Certificate message (RFC 8446 4.4.2) from the raw DER blocks
# (leaf-first): empty request context, then each cert as a 3-byte-length entry
# with empty per-cert extensions. Returns a malloc'd message; *out_len its len.
char* tls_build_certificate(list[pem_block*] certs, int* out_len):
	string_builder* b = string_new_sized(512)
	string_append_char(b, TLS_HS_CERTIFICATE)
	int lenpos = b.length
	string_append_be24(b, 0)                        # body length placeholder
	int body_start = b.length
	string_append_char(b, 0)                         # certificate_request_context length = 0
	int listpos = b.length
	string_append_be24(b, 0)                        # certificate_list length placeholder
	int list_start = b.length
	for i in range(certs.length):
		pem_block* blk = certs[i]
		string_append_be24(b, blk.len)              # cert_data length
		string_append_bytes(b, blk.data, blk.len)
		string_append_be16(b, 0)                    # per-certificate extensions length = 0
	store_be24(b.data + listpos, b.length - list_start)
	store_be24(b.data + lenpos, b.length - body_start)
	char* out = cast(char*, malloc(b.length))
	mem_copy(out, b.data, b.length)
	*out_len = b.length
	string_free(b)
	return out


# Build a CertificateVerify (RFC 8446 4.4.3): deterministic ECDSA (RFC 6979)
# over SHA-256 of the server signed-content (64 spaces || context string ||
# 0x00 || transcript hash at CH..Certificate), emitted as a DER signature with
# scheme ecdsa_secp256r1_sha256. Returns a malloc'd handshake message and its
# length, or 0 if signing failed (bad key). The private key stays in server_d.
char* tls_build_certverify_role(char* server_d, char* th_cert, int th_len, int client_role, int* out_len):
	int clen = 0
	char* content = tls_certverify_content_role(th_cert, th_len, client_role, &clen)
	char* digest = cast(char*, malloc(32))
	whash_oneshot(WHASH_SHA256, content, clen, digest)
	free(content)
	char* r = cast(char*, malloc(32))
	char* s = cast(char*, malloc(32))
	int sok = ecdsa_p256_sign(server_d, digest, 32, r, s)
	tls_wipe(digest, 32)
	free(digest)
	if (sok == 0):
		free(r)
		free(s)
		return 0
	char* der = cast(char*, malloc(80))
	int der_len = 0
	x509_ecdsa_sig_raw_to_der(r, s, der, &der_len)
	free(r)
	free(s)
	string_builder* b = string_new_sized(96)
	string_append_char(b, TLS_HS_CERTIFICATE_VERIFY)
	int lenpos = b.length
	string_append_be24(b, 0)                        # body length placeholder
	int body_start = b.length
	string_append_be16(b, TLS_SIG_ECDSA_SECP256R1_SHA256)
	string_append_be16(b, der_len)
	string_append_bytes(b, der, der_len)
	free(der)
	store_be24(b.data + lenpos, b.length - body_start)
	char* out = cast(char*, malloc(b.length))
	mem_copy(out, b.data, b.length)
	*out_len = b.length
	string_free(b)
	return out


char* tls_build_certverify(char* server_d, char* th_cert, int th_len, int* out_len):
	return tls_build_certverify_role(server_d, th_cert, th_len, 0, out_len)


# ---- credential loading -------------------------------------------------------

# The server ephemeral X25519 private key: injected test key, else 32 fresh
# random bytes. Returns 1 on success.
int tls_server_gen_priv(tls_conn* c, char* priv):
	if (c.scfg != 0):
		if (c.scfg.test_priv != 0):
			mem_copy(priv, c.scfg.test_priv, 32)
			return 1
	return random_bytes(priv, 32)


# The ServerHello random: injected test value, else 32 fresh random bytes.
int tls_server_gen_random(tls_conn* c, char* rnd):
	if (c.scfg != 0):
		if (c.scfg.test_random != 0):
			mem_copy(rnd, c.scfg.test_random, 32)
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
	if (pem == 0): return new list[pem_block*]
	list[pem_block*] blocks = pem_decode_blocks(pem, plen, c"CERTIFICATE")
	if (owned != 0): free(owned)
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
	if (pem == 0): return 0
	int ok = x509_load_ec_private_key(pem, plen, out_d32)
	if (owned != 0):
		tls_wipe(owned, plen)
		free(owned)
	return ok


# ---- server ALPN selection ------------------------------------------------------

# Server-side ALPN (RFC 7301 section 3.2) over a ClientHello already accepted
# by tls_parse_client_hello (msg = handshake header + body, len total). With
# no server ALPN configured this is a no-op. Otherwise the first protocol in
# OUR preference list that the client offered is stored in c.alpn. A
# malformed client list is a decode_error; no overlap (or no ALPN offered)
# with scfg.alpn_required set is a fatal no_application_protocol. Returns 1
# to continue the handshake, 0 after failing the connection.
int tls_server_select_alpn(tls_conn* c, char* msg, int len):
	tls_server_config* scfg = c.scfg
	if (scfg == 0): return 1
	if (scfg.alpn == 0): return 1
	# Skip legacy_version, random, session_id, cipher_suites, compression.
	int pos = 4 + 2 + 32
	if (pos + 1 > len): return 1
	pos = pos + 1 + (msg[pos] & 255)
	if (pos + 2 > len): return 1
	pos = pos + 2 + load_be16(msg + pos)
	if (pos + 1 > len): return 1
	pos = pos + 1 + (msg[pos] & 255)
	char* offered = 0
	int offered_len = 0
	if (pos + 2 <= len):
		int ext_end = pos + 2 + load_be16(msg + pos)
		pos = pos + 2
		if (ext_end > len): ext_end = len
		int scanning = 1
		while ((scanning != 0) && (pos + 4 <= ext_end)):
			int etype = load_be16(msg + pos)
			int elen = load_be16(msg + pos + 2)
			pos = pos + 4
			if (pos + elen > ext_end): scanning = 0
			else:
				if (etype == TLS_EXT_ALPN):
					int ll = 0
					if (elen >= 2): ll = load_be16(msg + pos)
					if ((elen < 2) || (ll != elen - 2) || (tls_alpn_list_valid(msg + pos + 2, ll) == 0)):
						tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
						tls_fail(c, c"tls: malformed ALPN extension")
						return 0
					offered = msg + pos + 2
					offered_len = ll
				pos = pos + elen
	if (offered != 0):
		int sp = 0
		while (sp < scfg.alpn_len):
			int sl = scfg.alpn[sp] & 255
			if (tls_alpn_list_contains(offered, offered_len, scfg.alpn + sp + 1, sl) != 0):
				tls_set_alpn_selected(c, scfg.alpn + sp + 1, sl)
				return 1
			sp = sp + 1 + sl
	if (scfg.alpn_required != 0):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_NO_APPLICATION_PROTOCOL)
		tls_fail(c, c"tls: no common ALPN protocol")
		return 0
	return 1


# ---- server handshake state machine -------------------------------------------

# Normalize a retried hello for comparison: key_share is the only extension
# our server asks to change; padding may also change per RFC 8446 4.1.2.
# PSK/early_data are outside this implementation's retry contract.
char* tls_retry_invariant(char* msg, int len, int* out_len):
	int ext = tls_hello_extensions(msg, len)
	if (ext < 0 || tls_extensions_valid(msg, len, ext + 2) == 0): return 0
	string_builder* b = string_new()
	string_append_bytes(b, msg + 4, ext - 4)
	int pos = ext + 2
	while (pos < len):
		int kind = load_be16(msg + pos)
		int n = load_be16(msg + pos + 2)
		if (kind == 41 || kind == 42 || kind == TLS_EXT_COOKIE):
			string_free(b)
			return 0
		if (kind != TLS_EXT_KEY_SHARE && kind != 21): string_append_bytes(b, msg + pos, n + 4)
		pos += n + 4
	*out_len = b.length
	char* out = b.data
	free(b)
	return out


int tls_server_read_client_hello(tls_conn* c, char* out_sid, int* out_sid_len, char* out_pub):
	int htype = 0
	char* msg = 0
	int mlen = 0
	int preferred_suite = c.scfg.cipher_suite
	int preferred_group = c.scfg.key_exchange_group
	if (preferred_suite != 0 && tls_suite_supported(preferred_suite) == 0): return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: unsupported configured suite")
	if (preferred_group != 0 && tls_group_size(preferred_group) == 0): return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: unsupported configured group")
	for attempt in range(2):
		if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0): return 0
		if (htype != TLS_HS_CLIENT_HELLO): return tls_auth_fail(c, TLS_ALERT_UNEXPECTED_MESSAGE, c"tls: expected ClientHello")
		char[32] crandom
		int suite = 0
		int group = 0
		int have_tls13 = 0
		int have_ecdsa = 0
		if (tls_parse_client_hello_options(msg, mlen, crandom, out_sid, out_sid_len, out_pub, &suite, &group, &have_tls13, &have_ecdsa, preferred_suite, preferred_group) == 0):
			return tls_auth_fail(c, TLS_ALERT_DECODE_ERROR, c"tls: malformed ClientHello")
		if (have_tls13 == 0): return tls_auth_fail(c, TLS_ALERT_PROTOCOL_VERSION, c"tls: client does not offer TLS 1.3")
		if (suite == 0): return tls_auth_fail(c, TLS_ALERT_HANDSHAKE_FAILURE, c"tls: no supported cipher suite")
		if (group == 0): return tls_auth_fail(c, TLS_ALERT_HANDSHAKE_FAILURE, c"tls: no supported key exchange group")
		if (have_ecdsa == 0): return tls_auth_fail(c, TLS_ALERT_HANDSHAKE_FAILURE, c"tls: client does not accept ecdsa_secp256r1_sha256")
		if (attempt == 0):
			string_append_bytes(c.hello, msg, mlen)
			whash_update(c.transcript, msg, mlen)
			tls_set_suite(c, suite)
		else:
			int old_len = 0
			int new_len = 0
			char* old = tls_retry_invariant(c.hello.data, c.hello.length, &old_len)
			char* next = tls_retry_invariant(msg, mlen, &new_len)
			int same = old != 0 && next != 0 && old_len == new_len
			if (same): same = mem_eq(old, next, old_len)
			if (old != 0): free(old)
			if (next != 0): free(next)
			if (same == 0 || group != c.key_group || suite != c.cipher_suite || tls_retry_single_share(msg, mlen, c.key_group) == 0):
				return tls_auth_fail(c, TLS_ALERT_ILLEGAL_PARAMETER, c"tls: invalid second ClientHello")
			whash_update(c.transcript, msg, mlen)
		if (group > 0):
			c.key_group = group
			return tls_server_select_alpn(c, msg, mlen)
		# Only one retry. The selected group was advertised without a share.
		if (attempt != 0): return tls_auth_fail(c, TLS_ALERT_ILLEGAL_PARAMETER, c"tls: repeated retry")
		c.key_group = 0 - group
		preferred_group = c.key_group
		preferred_suite = c.cipher_suite
		int hrr_len = 0
		char* hrr = tls_build_server_hello_group(tls_hrr_random(), out_sid, *out_sid_len, 0, c.cipher_suite, c.key_group, &hrr_len)
		tls_retry_transcript(c, hrr, hrr_len)
		int sent = tls_send_record(c, TLS_CT_HANDSHAKE, hrr, hrr_len, 0)
		free(hrr)
		if (sent == 0): return 0
	return 0


# Drive the full server handshake on connection c (c.scfg holds credentials).
# Returns 1 on success (keys switched to application data), 0 on any failure
# (connection marked broken, alert already sent, key material wiped).
int tls_server_do_handshake(tls_conn* c):
	tls_server_config* scfg = c.scfg
	int ds = c.digest_size
	if (scfg.client_auth < TLS_CLIENT_AUTH_NONE || scfg.client_auth > TLS_CLIENT_AUTH_REQUIRED):
		return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: invalid client authentication policy")
	if (scfg.client_auth != TLS_CLIENT_AUTH_NONE && scfg.client_trust_store_path == 0):
		return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: explicit client trust store required")

	# Load credentials up front: fail before engaging the client if we cannot
	# serve. The private key lives in server_d until CertificateVerify.
	list[pem_block*] certs = tls_server_cert_blocks(scfg)
	if (certs.length == 0):
		pem_blocks_free(certs)
		tls_fail(c, c"tls: server certificate unavailable")
		return 0
	char* server_d = cast(char*, malloc(32))
	tls_wipe(server_d, 32)
	if (tls_server_load_key(scfg, server_d) == 0):
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: server private key unavailable")
		return 0

	# ClientHello.
	char* csid = cast(char*, malloc(32))
	int csid_len = 0
	char* cpub = cast(char*, malloc(65))
	if (tls_server_read_client_hello(c, csid, &csid_len, cpub) == 0):
		free(csid)
		free(cpub)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		return 0

	ds = c.digest_size
	# ServerHello with a fresh (or injected) ephemeral key and random.
	char* spriv = cast(char*, malloc(32))
	char* spub = cast(char*, malloc(65))
	if (tls_make_key_share(c, c.key_group, spriv, spub, 1) == 0):
		free(spub)
		tls_wipe(spriv, 32)
		free(spriv)
		free(csid)
		free(cpub)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: RNG failure")
		return 0
	char* srandom = cast(char*, malloc(32))
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
	char* sh = tls_build_server_hello_group(srandom, csid, csid_len, spub, c.cipher_suite, c.key_group, &sh_len)
	free(srandom)
	free(spub)
	free(csid)
	whash_update(c.transcript, sh, sh_len)
	int shsent = tls_send_record(c, TLS_CT_HANDSHAKE, sh, sh_len, 0)
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
	char* ecdhe = cast(char*, malloc(32))
	int xr = tls_shared_secret(c.key_group, spriv, cpub, ecdhe)
	tls_wipe(spriv, 32)
	free(spriv)
	free(cpub)
	if (xr == 0):
		tls_wipe(ecdhe, 32)
		free(ecdhe)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_HANDSHAKE_FAILURE)
		tls_fail(c, c"tls: bad client key share")
		return 0

	# Handshake key schedule over CH..SH; install directional keys (we write
	# with the server handshake secret and read with the client one).
	char* th_ch_sh = cast(char*, malloc(ds))
	whash_final(c.transcript, th_ch_sh)
	char* hs_secret = cast(char*, malloc(ds))
	tls_derive_handshake(c, ecdhe, th_ch_sh, hs_secret)
	tls_wipe(ecdhe, 32)
	free(ecdhe)
	free(th_ch_sh)
	tls_install_write_keys(c, c.s_hs_secret)
	tls_install_read_keys(c, c.c_hs_secret)

	# EncryptedExtensions (the selected ALPN protocol, if any; else empty).
	int ee_len = 0
	char* ee = tls_build_encrypted_extensions_alpn(c.alpn, &ee_len)
	whash_update(c.transcript, ee, ee_len)
	int eesent = tls_send_record(c, TLS_CT_HANDSHAKE, ee, ee_len, 1)
	free(ee)
	if (eesent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_wipe(server_d, 32)
		free(server_d)
		pem_blocks_free(certs)
		tls_fail(c, c"tls: send EncryptedExtensions failed")
		return 0

	if (scfg.client_auth != TLS_CLIENT_AUTH_NONE):
		if (tls_send_certificate_request(c) == 0):
			tls_wipe(hs_secret, ds)
			free(hs_secret)
			tls_wipe(server_d, 32)
			free(server_d)
			pem_blocks_free(certs)
			return 0

	# Certificate (the configured chain, leaf-first). DER is copied into the
	# message, so the blocks are released immediately after.
	int cert_len = 0
	char* certmsg = tls_build_certificate(certs, &cert_len)
	pem_blocks_free(certs)
	whash_update(c.transcript, certmsg, cert_len)
	int csent = tls_send_record(c, TLS_CT_HANDSHAKE, certmsg, cert_len, 1)
	free(certmsg)
	if (csent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_wipe(server_d, 32)
		free(server_d)
		tls_fail(c, c"tls: send Certificate failed")
		return 0
	char* th_cert = cast(char*, malloc(ds))
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
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_INTERNAL_ERROR)
		tls_fail(c, c"tls: CertificateVerify signing failed")
		return 0
	whash_update(c.transcript, cv, cv_len)
	int cvsent = tls_send_record(c, TLS_CT_HANDSHAKE, cv, cv_len, 1)
	free(cv)
	if (cvsent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_fail(c, c"tls: send CertificateVerify failed")
		return 0
	char* th_cv = cast(char*, malloc(ds))
	whash_final(c.transcript, th_cv)

	# server Finished over TH(CH..CertificateVerify).
	char* sfkey = cast(char*, malloc(ds))
	tls_finished_key(c.hash_alg, c.s_hs_secret, sfkey)
	char* svd = cast(char*, malloc(ds))
	hmac_compute(c.hash_alg, sfkey, ds, th_cv, ds, svd)
	tls_wipe(sfkey, ds)
	free(sfkey)
	free(th_cv)
	char* fin = cast(char*, malloc(4 + ds))
	fin[0] = TLS_HS_FINISHED
	fin[1] = 0
	fin[2] = 0
	fin[3] = ds
	mem_copy(fin + 4, svd, ds)
	free(svd)
	whash_update(c.transcript, fin, 4 + ds)
	int fsent = tls_send_record(c, TLS_CT_HANDSHAKE, fin, 4 + ds, 1)
	free(fin)
	if (fsent == 0):
		tls_wipe(hs_secret, ds)
		free(hs_secret)
		tls_fail(c, c"tls: send Finished failed")
		return 0

	# Application secrets over CH..serverFinished; switch our WRITE to the
	# server application keys. READ stays on the client handshake keys so we
	# can read the client's Finished, then advances to the client app keys.
	char* th_ch_sf = cast(char*, malloc(ds))
	whash_final(c.transcript, th_ch_sf)
	tls_derive_application(c, hs_secret, th_ch_sf)
	tls_wipe(hs_secret, ds)
	free(hs_secret)
	tls_install_write_keys(c, c.s_ap_secret)

	# Client authentication extends only the client Finished transcript;
	# application secrets retain the CH..serverFinished snapshot above.
	if (scfg.client_auth != TLS_CLIENT_AUTH_NONE):
		if (tls_server_read_client_auth(c) == 0):
			free(th_ch_sf)
			return 0
	free(th_ch_sf)
	return tls_server_read_client_finished(c)


# Authentication is not published until Finished proves the complete
# transcript, including the client Certificate and CertificateVerify.
int tls_server_read_client_finished(tls_conn* c):
	int ds = c.digest_size
	char* th_client = cast(char*, malloc(ds))
	whash_final(c.transcript, th_client)
	# client Finished = HMAC(client_finished_key, current transcript).
	char* cfkey = cast(char*, malloc(ds))
	tls_finished_key(c.hash_alg, c.c_hs_secret, cfkey)
	char* expected = cast(char*, malloc(ds))
	hmac_compute(c.hash_alg, cfkey, ds, th_client, ds, expected)
	tls_wipe(cfkey, ds)
	free(cfkey)
	free(th_client)
	int htype = 0
	char* msg = 0
	int mlen = 0
	if (tls_next_hs_msg(c, &htype, &msg, &mlen) == 0):
		free(expected)
		return 0
	if (htype != TLS_HS_FINISHED):
		free(expected)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_UNEXPECTED_MESSAGE)
		tls_fail(c, c"tls: expected client Finished")
		return 0
	int vd_len = mlen - 4
	if (vd_len != ds):
		free(expected)
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECODE_ERROR)
		tls_fail(c, c"tls: bad client Finished length")
		return 0
	char* got = cast(char*, malloc(ds))
	mem_copy(got, msg + 4, ds)
	int finok = hmac_equal(expected, got, ds)
	free(expected)
	free(got)
	if (finok == 0):
		tls_send_alert(c, TLS_ALERT_FATAL, TLS_ALERT_DECRYPT_ERROR)
		tls_fail(c, c"tls: client Finished verify failed")
		return 0
	tls_install_read_keys(c, c.c_ap_secret)
	if (c.peer_certificate_sha256 != 0): c.peer_verified = 1
	return 1


# ---- public server API --------------------------------------------------------

# Server handshake over an already-accepted TCP socket. Returns an owned
# tls_conn* on success (the same tls_read/tls_write/tls_close then apply), or 0
# on failure with the reason in tls_server_last_error(cfg).
tls_conn* tls_accept(int sockfd, tls_server_config* cfg):
	if (cfg == 0): return 0
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
	if (cfg == 0): return 0
	tls_conn* c = tls_conn_new(0 - 1, 1, 0)
	c.is_server = 1
	c.scfg = cfg
	string_append_bytes(c.mem_in, client_flight, flen)
	if (tls_server_do_handshake(c) == 0):
		tls_conn_free(c)
		return 0
	return c


# ---- mutual certificate authentication (RFC 8446 4.3.2, 4.4) ------------------

int tls_auth_fail(tls_conn* c, int alert, char* message):
	tls_send_alert(c, TLS_ALERT_FATAL, alert)
	tls_fail(c, message)
	return 0


void tls_set_peer_certificate(tls_conn* c, x509_cert* leaf):
	char* digest = cast(char*, malloc(32))
	whash_oneshot(WHASH_SHA256, leaf.der, leaf.der_len, digest)
	if (c.peer_certificate_sha256 != 0): free(c.peer_certificate_sha256)
	c.peer_certificate_sha256 = hex_encode(digest, 32)
	free(digest)


# Returns a borrowed fingerprint only after the peer's proof and Finished
# have verified. This is certificate identity, not application authorization.
char* tls_peer_certificate_sha256(tls_conn* c):
	if (c == 0): return 0
	if (c.peer_verified == 0 || c.broken): return 0
	return c.peer_certificate_sha256


int tls_send_certificate_request(tls_conn* c):
	# Empty request context, one signature_algorithms extension offering
	# exactly the scheme our client credentials and server verifier support.
	char* request = c"\x0d\x00\x00\x1b\x00\x00\x18\x00\x0d\x00\x04\x00\x02\x04\x03\x00\x32\x00\x0c\x00\x0a\x04\x03\x04\x01\x05\x01\x08\x04\x08\x05"
	whash_update(c.transcript, request, 31)
	if (tls_send_record(c, TLS_CT_HANDSHAKE, request, 31, 1) == 0):
		tls_fail(c, c"tls: send CertificateRequest failed")
		return 0
	return 1


# Map the CertificateRequest certificate-signature schemes to X.509's
# verified signature algorithms. Handshake signatures remain P-256 only.
int tls_certificate_scheme_bit(int scheme):
	if (scheme == TLS_SIG_ECDSA_SECP256R1_SHA256): return 1 << X509_SIGALG_ECDSA_SHA256
	if (scheme == TLS_SIG_ECDSA_SECP384R1_SHA384): return 1 << X509_SIGALG_ECDSA_SHA384
	if (scheme == TLS_SIG_RSA_PKCS1_SHA256): return 1 << X509_SIGALG_RSA_SHA256
	if (scheme == TLS_SIG_RSA_PKCS1_SHA384): return 1 << X509_SIGALG_RSA_SHA384
	if (scheme == TLS_SIG_RSA_PSS_RSAE_SHA256): return 1 << X509_SIGALG_RSA_PSS_SHA256
	if (scheme == TLS_SIG_RSA_PSS_RSAE_SHA384): return 1 << X509_SIGALG_RSA_PSS_SHA384
	return 0


int tls_parse_certificate_request(tls_conn* c, char* msg, int len):
	if (len < 7): return tls_auth_fail(c, TLS_ALERT_DECODE_ERROR, c"tls: malformed CertificateRequest")
	if ((msg[0] & 255) != TLS_HS_CERTIFICATE_REQUEST || msg[4] != 0 || load_be24(msg + 1) != len - 4 || load_be16(msg + 5) != len - 7):
		return tls_auth_fail(c, TLS_ALERT_DECODE_ERROR, c"tls: malformed CertificateRequest")
	int valid = 1
	int pos = 7
	int have_sigalgs = 0
	int p256 = 0
	int proof_schemes = 0
	int cert_schemes = 0
	int have_cert_schemes = 0
	int constrained = 0
	list[int] seen = new list[int]
	while (pos < len):
		if (pos + 4 > len):
			valid = 0
			break
		int kind = load_be16(msg + pos)
		int size = load_be16(msg + pos + 2)
		pos = pos + 4
		if (pos + size > len):
			valid = 0
			break
		int duplicate = 0
		for i in range(seen.length):
			if (seen[i] == kind): duplicate = 1
		if (duplicate):
			valid = 0
			break
		seen.push(kind)
		if (kind == TLS_EXT_SIGNATURE_ALGORITHMS || kind == TLS_EXT_SIGNATURE_ALGORITHMS_CERT):
			if (size < 4):
				valid = 0
				break
			int n = load_be16(msg + pos)
			if (n != size - 2 || (n % 2) != 0):
				valid = 0
				break
			int schemes = 0
			int at = pos + 2
			while (at < pos + size):
				int scheme = load_be16(msg + at)
				schemes = schemes | tls_certificate_scheme_bit(scheme)
				if (kind == TLS_EXT_SIGNATURE_ALGORITHMS && scheme == TLS_SIG_ECDSA_SECP256R1_SHA256): p256 = 1
				at = at + 2
			if (kind == TLS_EXT_SIGNATURE_ALGORITHMS):
				have_sigalgs = 1
				proof_schemes = schemes
			else:
				have_cert_schemes = 1
				cert_schemes = schemes
		# No automatic selection for OID filters: decline instead of
		# sending a certificate which might violate an unknown constraint.
		if (kind == 48): constrained = 1
		pos = pos + size
	list_free[int](seen)
	if (valid == 0 || pos != len || have_sigalgs == 0):
		return tls_auth_fail(c, TLS_ALERT_DECODE_ERROR, c"tls: malformed CertificateRequest")
	c.client_auth_requested = 1
	c.client_auth_p256 = p256 && constrained == 0
	if (have_cert_schemes == 0): cert_schemes = proof_schemes
	c.client_auth_cert_schemes = cert_schemes
	return 1


# RFC 8446 4.4.2.3: client certificate signatures must satisfy
# signature_algorithms_cert, falling back to signature_algorithms. Validate
# every supplied certificate; unsupported/malformed chains are never sent.
int tls_client_chain_compatible(list[pem_block*] blocks, int schemes):
	int ok = 1
	for i in range(blocks.length):
		x509_cert* cert = x509_parse(blocks[i].data, blocks[i].len)
		if (cert == 0): return 0
		if ((schemes & (1 << cert.sig_alg)) == 0): ok = 0
		x509_cert_free(cert)
	return ok


# Send an empty Certificate when no compatible credential was configured;
# a required server rejects it. Configured but unreadable credentials fail.
int tls_client_send_auth(tls_conn* c):
	tls_config* cfg = c.cfg
	tls_server_config* credentials = tls_server_config_new()
	int configured = 0
	if (cfg != 0):
		credentials.cert_chain_path = cfg.client_cert_chain_path
		credentials.key_path = cfg.client_key_path
		configured = cfg.client_cert_chain_path != 0 || cfg.client_key_path != 0
	list[pem_block*] certs = new list[pem_block*]
	char* key = cast(char*, malloc(32))
	tls_wipe(key, 32)
	if (configured && c.client_auth_p256):
		pem_blocks_free(certs)
		certs = tls_server_cert_blocks(credentials)
		if (certs.length == 0 || tls_server_load_key(credentials, key) == 0):
			pem_blocks_free(certs)
			tls_wipe(key, 32)
			free(key)
			tls_server_config_free(credentials)
			return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: client credential unavailable")
	tls_server_config_free(credentials)
	if (tls_client_chain_compatible(certs, c.client_auth_cert_schemes) == 0):
		pem_blocks_free(certs)
		certs = new list[pem_block*]
	if (cfg != 0):
		if (cfg.require_client_auth && certs.length == 0):
			pem_blocks_free(certs)
			tls_wipe(key, 32)
			free(key)
			return tls_auth_fail(c, TLS_ALERT_HANDSHAKE_FAILURE, c"tls: no compatible client credential")
	int have_cert = certs.length != 0
	int len = 0
	char* msg = tls_build_certificate(certs, &len)
	pem_blocks_free(certs)
	whash_update(c.transcript, msg, len)
	int sent = tls_send_record(c, TLS_CT_HANDSHAKE, msg, len, 1)
	free(msg)
	if (sent == 0):
		tls_wipe(key, 32)
		free(key)
		tls_fail(c, c"tls: send client Certificate failed")
		return 0
	if (have_cert == 0):
		tls_wipe(key, 32)
		free(key)
		return 1
	char* th = cast(char*, malloc(48))
	whash_final(c.transcript, th)
	msg = tls_build_certverify_role(key, th, c.digest_size, 1, &len)
	free(th)
	tls_wipe(key, 32)
	free(key)
	if (msg == 0): return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: client CertificateVerify signing failed")
	whash_update(c.transcript, msg, len)
	sent = tls_send_record(c, TLS_CT_HANDSHAKE, msg, len, 1)
	free(msg)
	if (sent == 0):
		tls_fail(c, c"tls: send client CertificateVerify failed")
		return 0
	return 1


int tls_check_client_chain(tls_conn* c, list[x509_cert*] certs):
	x509_trust_store* store = x509_load_trust_store(c.scfg.client_trust_store_path)
	if (store == 0): return tls_auth_fail(c, TLS_ALERT_INTERNAL_ERROR, c"tls: cannot load client trust store")
	int now = tls_now_unix()
	if (c.scfg.has_now_unix): now = c.scfg.now_unix
	list[x509_cert*] extra = new list[x509_cert*]
	for i in range(1, certs.length): extra.push(certs[i])
	char* reason = 0
	int ok = x509_verify_client_chain(certs[0], extra, store, now, &reason)
	list_free[x509_cert*](extra)
	x509_store_free(store)
	if (ok == 0): return tls_auth_fail(c, TLS_ALERT_HANDSHAKE_FAILURE, c"tls: client certificate verification failed")
	return 1


int tls_server_read_client_auth(tls_conn* c):
	int kind = 0
	int len = 0
	char* msg = 0
	if (tls_next_hs_msg(c, &kind, &msg, &len) == 0): return 0
	if (kind != TLS_HS_CERTIFICATE): return tls_auth_fail(c, TLS_ALERT_UNEXPECTED_MESSAGE, c"tls: expected client Certificate")
	# Only the exact empty Certificate is an optional unauthenticated peer.
	if (len == 8 && load_be24(msg + 1) == 4 && msg[4] == 0 && load_be24(msg + 5) == 0):
		whash_update(c.transcript, msg, len)
		if (c.scfg.client_auth == TLS_CLIENT_AUTH_REQUIRED):
			return tls_auth_fail(c, 116, c"tls: client certificate required")
		return 1
	list[x509_cert*] certs = tls_parse_certificate(msg, len)
	if (certs.length == 0):
		tls_free_cert_list(certs)
		return tls_auth_fail(c, TLS_ALERT_DECODE_ERROR, c"tls: malformed client Certificate")
	whash_update(c.transcript, msg, len)
	if (tls_check_client_chain(c, certs) == 0):
		tls_free_cert_list(certs)
		return 0
	char* th = cast(char*, malloc(48))
	whash_final(c.transcript, th)
	if (tls_next_hs_msg(c, &kind, &msg, &len) == 0):
		free(th)
		tls_free_cert_list(certs)
		return 0
	int ok = 0
	if (kind == TLS_HS_CERTIFICATE_VERIFY && len >= 8):
		int scheme = load_be16(msg + 4)
		int siglen = load_be16(msg + 6)
		# Must be the scheme we actually requested. Never accept legacy
		# RSA PKCS#1 or signatures using the server's role context here.
		if (scheme == TLS_SIG_ECDSA_SECP256R1_SHA256 && siglen == len - 8):
			ok = tls_verify_certverify_role(certs[0], scheme, msg + 8, siglen, th, c.digest_size, 1)
	free(th)
	if (ok): tls_set_peer_certificate(c, certs[0])
	tls_free_cert_list(certs)
	if (ok == 0): return tls_auth_fail(c, TLS_ALERT_DECRYPT_ERROR, c"tls: client CertificateVerify failed")
	whash_update(c.transcript, msg, len)
	return 1
