/*
PBKDF2-HMAC (RFC 8018 §5.2), the counterpart of Python's
hashlib.pbkdf2_hmac(hash_name, password, salt, iterations, dklen).

	char* dk = pbkdf2_hmac(c"sha256", pw, pw_len, salt, salt_len, 100000, 32)
	...                                    # dk is dklen malloc'd bytes
	free(dk)

	char* hex = pbkdf2_hmac_hex(c"sha512", pw, pw_len, salt, salt_len, 1000, 0)

	# by whash algorithm id, into a caller buffer; 1 on success, 0 on error
	pbkdf2_hmac_into(WHASH_SHA256, pw, pw_len, salt, salt_len, 4096, out, 32)

Hash names (ASCII case-insensitive): "sha256", "sha384", "sha512" from
libs/standard/crypto/sha2.w. "sha1" is accepted only once SHA-1 has been
registered with the whash dispatcher, i.e. the program imports
libs.x.unsafe.sha1 and calls WHASH_SHA1() (SHA-1 lives in the libs/x/unsafe
quarantine; nothing here imports it). pbkdf2_hmac_into takes any whash id,
including WHASH_SHA1() and other whash_register extensions.

dklen == 0 means the hash's digest size (Python's dklen=None). Errors
(unknown hash name, iterations < 1, dklen < 0) make pbkdf2_hmac and
pbkdf2_hmac_hex return 0 and pbkdf2_hmac_into return 0, where Python
raises ValueError.

Performance: the HMAC inner/outer pad blocks are compressed once per call.
Each further iteration is then exactly two compression-function calls on a
pre-padded single block, with no allocation, so iteration counts in the
100k range are practical.
*/
import lib.memory
import lib.sha256
import lib.bytes
import lib.hex
import lib.mem
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac


# whash id that libs/x/unsafe/sha1.w registers SHA-1 under (sha1_alg_id).
const int PBKDF2_SHA1_ALG = 101


int pbkdf2_lower(int c):
	if ((c >= 65) && (c <= 90)): return c + 32
	return c


int pbkdf2_name_is(char* name, char* want):
	int i = 0
	while (want[i] != 0):
		if (pbkdf2_lower(name[i] & 255) != want[i]): return 0
		i = i + 1
	if (name[i] != 0): return 0
	return 1


# whash algorithm id for a hashlib-style name, or 0 when unsupported.
int pbkdf2_hash_id(char* hash_name):
	if (hash_name == 0): return 0
	if (pbkdf2_name_is(hash_name, c"sha256")): return WHASH_SHA256
	if (pbkdf2_name_is(hash_name, c"sha384")): return WHASH_SHA384
	if (pbkdf2_name_is(hash_name, c"sha512")): return WHASH_SHA512
	if (pbkdf2_name_is(hash_name, c"sha1")):
		if (whash_ext_find(PBKDF2_SHA1_ALG) != 0): return PBKDF2_SHA1_ALG
	return 0


# Write the digest words of state h into out (digest_size bytes), in the
# algorithm's byte order (big-endian SHA family, little-endian MD5-style
# extensions).
void pbkdf2_emit(whash* h, int little_endian, char* out):
	int words = h.digest_size / 4
	for i in range(words):
		if (little_endian == 1): store_le32(out + i * 4, h.state[i])
		else: sha256_put_be32(out + i * 4, h.state[i])


# Derive dklen bytes into out with whash algorithm alg. Returns 1 on
# success, 0 on invalid arguments (iterations < 1, dklen < 1).
int pbkdf2_hmac_into(int alg, char* password, int password_len, char* salt, int salt_len, int iterations, char* out, int dklen):
	if ((iterations < 1) || (dklen < 1)): return 0
	if ((password_len < 0) || (salt_len < 0)): return 0

	whmac* m = hmac_new(alg, password, password_len)
	int ds = m.digest_size
	int bs = m.block_size
	int words = whash_state_words(alg)
	int little_endian = 0
	whash_ext* e = whash_ext_find(alg)
	if (e != 0): little_endian = e.little_endian

	# Keyed states: inner has absorbed ipad-key, outer opad-key — exactly
	# one block each, so nothing is left buffered.
	whash* outer = whash_new(alg)
	whash_update(outer, m.opad_key, bs)
	int* inner_state = cast(int*, malloc(words * __word_size__))
	mem_copy(inner_state, m.inner.state, words)
	int* outer_state = cast(int*, malloc(words * __word_size__))
	mem_copy(outer_state, outer.state, words)

	# One pre-padded block holding a digest_size-byte message after a
	# one-block key prefix: msg || 0x80 || zeros || bit length. Every
	# whash algorithm (SHA-1/2, MD5) leaves room: digest + 1 + the 8- or
	# 16-byte length field fits one block.
	char* pad = cast(char*, malloc(bs))
	mem_fill(pad, 0, bs)
	pad[ds] = 128 /* 0x80 */
	int bits = (bs + ds) * 8
	if (little_endian == 1): store_le32(pad + bs - 8, bits)
	else: sha256_put_be32(pad + bs - 4, bits)

	char* u = cast(char*, malloc(ds))
	char* t = cast(char*, malloc(ds))
	char* counter = cast(char*, malloc(4))
	int block_index = 1
	int done = 0
	while (done < dklen):
		# U1 = PRF(P, S || INT(i))
		hmac_reset(m)
		hmac_update(m, salt, salt_len)
		sha256_put_be32(counter, block_index)
		hmac_update(m, counter, 4)
		hmac_final(m, u)
		mem_copy(t, u, ds)
		int j = 1
		while (j < iterations):
			# inner = H(ipad-key || U); U = H(opad-key || inner)
			mem_copy(pad, u, ds)
			mem_copy(outer.state, inner_state, words)
			whash_compress(outer, pad)
			pbkdf2_emit(outer, little_endian, pad)
			mem_copy(outer.state, outer_state, words)
			whash_compress(outer, pad)
			pbkdf2_emit(outer, little_endian, u)
			for k in range(ds): t[k] = t[k] ^ u[k]
			j = j + 1
		int take = dklen - done
		if (take > ds): take = ds
		mem_copy(out + done, t, take)
		done = done + take
		block_index = block_index + 1

	mem_fill(pad, 0, bs)
	mem_fill(u, 0, ds)
	mem_fill(t, 0, ds)
	mem_fill(inner_state, 0, words)
	mem_fill(outer_state, 0, words)
	mem_fill(outer.state, 0, words)
	free(pad)
	free(u)
	free(t)
	free(counter)
	free(inner_state)
	free(outer_state)
	whash_free(outer)
	hmac_free(m)
	return 1


# hashlib.pbkdf2_hmac: dklen malloc'd bytes (digest size when dklen is 0),
# or 0 for an unsupported hash name or invalid arguments.
char* pbkdf2_hmac(char* hash_name, char* password, int password_len, char* salt, int salt_len, int iterations, int dklen):
	int alg = pbkdf2_hash_id(hash_name)
	if (alg == 0): return cast(char*, 0)
	if (dklen == 0): dklen = whash_digest_size(alg)
	if ((dklen < 1) || (iterations < 1)): return cast(char*, 0)
	char* out = cast(char*, malloc(dklen))
	pbkdf2_hmac_into(alg, password, password_len, salt, salt_len, iterations, out, dklen)
	return out


# pbkdf2_hmac as a malloc'd lowercase hex string (2 * dklen chars), or 0.
char* pbkdf2_hmac_hex(char* hash_name, char* password, int password_len, char* salt, int salt_len, int iterations, int dklen):
	int alg = pbkdf2_hash_id(hash_name)
	if (alg == 0): return cast(char*, 0)
	if (dklen == 0): dklen = whash_digest_size(alg)
	char* dk = pbkdf2_hmac(hash_name, password, password_len, salt, salt_len, iterations, dklen)
	if (dk == 0): return cast(char*, 0)
	char* hex = hex_encode(dk, dklen)
	mem_fill(dk, 0, dklen)
	free(dk)
	return hex
