/*
HMAC (RFC 2104 / FIPS 198-1) over the whash interface, so the same code
serves HMAC-SHA-256 and HMAC-SHA-384 — the two MACs the TLS 1.3 key
schedule (plan 11, issue #195) needs.

	whmac* m = hmac_new(WHASH_SHA256(), key, key_len)
	hmac_update(m, data, len)         # any number of times
	hmac_final(m, out)                # digest_size bytes; non-destructive
	hmac_reset(m)                     # restart with the same key
	hmac_free(m)                      # zeroes the key pads before freeing

hmac_compute is the one-shot form; hmac_equal compares two MACs in
constant time (every byte is always inspected, no early exit).
*/
import lib.memory
import libs.standard.crypto.sha2


struct whmac:
	int alg
	int digest_size
	int block_size
	whash* inner     # running hash of ipad-key || message
	char* ipad_key   # block-size key xor 0x36, kept for hmac_reset
	char* opad_key   # block-size key xor 0x5c, kept for hmac_final


# Key a new HMAC context. Keys longer than the hash block size are hashed
# first (RFC 2104); all keys are then zero-padded to the block size.
whmac* hmac_new(int alg, char* key, int key_len):
	whmac* m = new whmac
	m.alg = alg
	m.digest_size = whash_digest_size(alg)
	m.block_size = whash_block_size(alg)
	m.ipad_key = malloc(m.block_size)
	m.opad_key = malloc(m.block_size)

	char* block_key = malloc(m.block_size)
	int i = 0
	while (i < m.block_size):
		block_key[i] = 0
		i = i + 1
	if (key_len > m.block_size):
		whash_oneshot(alg, key, key_len, block_key)
	else:
		i = 0
		while (i < key_len):
			block_key[i] = key[i]
			i = i + 1

	i = 0
	while (i < m.block_size):
		m.ipad_key[i] = (block_key[i] & 255) ^ 54 /* 0x36 */
		m.opad_key[i] = (block_key[i] & 255) ^ 92 /* 0x5c */
		block_key[i] = 0
		i = i + 1
	free(block_key)

	m.inner = whash_new(alg)
	whash_update(m.inner, m.ipad_key, m.block_size)
	return m


void hmac_update(whmac* m, char* data, int len):
	whash_update(m.inner, data, len)


# Write the MAC of everything absorbed so far to out (digest_size bytes).
# Non-destructive like whash_final: more data may follow.
void hmac_final(whmac* m, char* out):
	char* inner_digest = malloc(m.digest_size)
	whash_final(m.inner, inner_digest)
	whash* outer = whash_new(m.alg)
	whash_update(outer, m.opad_key, m.block_size)
	whash_update(outer, inner_digest, m.digest_size)
	whash_final(outer, out)
	whash_free(outer)
	int i = 0
	while (i < m.digest_size):
		inner_digest[i] = 0
		i = i + 1
	free(inner_digest)


# Restart the MAC with the same key (fresh empty message).
void hmac_reset(whmac* m):
	whash_reset(m.inner)
	whash_update(m.inner, m.ipad_key, m.block_size)


# Zero the key material before releasing it.
void hmac_free(whmac* m):
	int i = 0
	while (i < m.block_size):
		m.ipad_key[i] = 0
		m.opad_key[i] = 0
		i = i + 1
	free(m.ipad_key)
	free(m.opad_key)
	whash_free(m.inner)
	free(m)


# One-shot HMAC: MAC of data under key, written to out (digest_size bytes).
void hmac_compute(int alg, char* key, int key_len, char* data, int data_len, char* out):
	whmac* m = hmac_new(alg, key, key_len)
	hmac_update(m, data, data_len)
	hmac_final(m, out)
	hmac_free(m)


# Constant-time comparison of two len-byte MACs: 1 when equal, 0 when
# not. Accumulates the OR of all byte differences so timing does not
# depend on where (or whether) the inputs differ.
int hmac_equal(char* a, char* b, int len):
	int diff = 0
	int i = 0
	while (i < len):
		diff = diff | ((a[i] & 255) ^ (b[i] & 255))
		i = i + 1
	if (diff == 0):
		return 1
	return 0
