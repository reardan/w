# AES-128/256-GCM for TLS: 96-bit nonces and full 128-bit tags only.
# FIPS 197 and SP 800-38D. Pure W, portable to 32-bit words.
# No secret-indexed tables: SubBytes computes inversion in GF(2^8), and
# GHASH uses a fixed bit schedule. Public lengths/key sizes control loops.
# This is a portable baseline; no hardware AES acceleration is used.
import lib.memory
import lib.mem
import lib.bytes


struct aes_gcm_key:
	char* rounds
	int count
	char* h


int aes_xtime(int x):
	return ((x << 1) ^ (27 & (0 - (x >> 7)))) & 255


int aes_mul(int a, int b):
	int out = 0
	for i in range(8):
		out = out ^ (a & (0 - (b & 1)))
		a = aes_xtime(a)
		b = b >> 1
	return out


int aes_sbox(int x):
	# x^-1 = x^254, including 0 -> 0, followed by the affine transform.
	int x2 = aes_mul(x, x)
	int x3 = aes_mul(x2, x)
	int x6 = aes_mul(x3, x3)
	int x12 = aes_mul(x6, x6)
	int x15 = aes_mul(x12, x3)
	int x30 = aes_mul(x15, x15)
	int x60 = aes_mul(x30, x30)
	int x120 = aes_mul(x60, x60)
	int x240 = aes_mul(x120, x120)
	int y = aes_mul(aes_mul(x240, x12), x2)
	return (y ^ ((y << 1) | (y >> 7)) ^ ((y << 2) | (y >> 6)) ^ ((y << 3) | (y >> 5)) ^ ((y << 4) | (y >> 4)) ^ 99) & 255


# Encrypt one block; input/output may alias. State is column-major.
void aes_encrypt_block(aes_gcm_key* key, char* input, char* out):
	char[16] s
	char[16] t
	for i in range(16): s[i] = input[i] ^ key.rounds[i]
	for round in range(1, key.count + 1):
		for row in range(4):
			for col in range(4): t[4 * col + row] = aes_sbox(s[4 * ((col + row) % 4) + row] & 255)
		if (round != key.count):
			for col in range(4):
				int j = col * 4
				int a = t[j] & 255
				int b = t[j + 1] & 255
				int c = t[j + 2] & 255
				int d = t[j + 3] & 255
				int sum = a ^ b ^ c ^ d
				t[j] = a ^ sum ^ aes_xtime(a ^ b)
				t[j + 1] = b ^ sum ^ aes_xtime(b ^ c)
				t[j + 2] = c ^ sum ^ aes_xtime(c ^ d)
				t[j + 3] = d ^ sum ^ aes_xtime(d ^ a)
		for i in range(16): s[i] = t[i] ^ key.rounds[16 * round + i]
	mem_copy(out, cast(char*, s), 16)
	mem_fill(cast(char*, s), 0, 16)
	mem_fill(cast(char*, t), 0, 16)


aes_gcm_key* aes_gcm_key_new(char* raw, int len):
	if (raw == 0 || (len != 16 && len != 32)): return 0
	aes_gcm_key* key = new aes_gcm_key(malloc(240), len / 4 + 6, malloc(16))
	mem_fill(key.rounds, 0, 240)
	mem_copy(key.rounds, raw, len)
	char[4] t
	int rc = 1
	int pos = len
	while (pos < 16 * (key.count + 1)):
		mem_copy(cast(char*, t), key.rounds + pos - 4, 4)
		if (pos % len == 0):
			int first = t[0] & 255
			for i in range(3): t[i] = aes_sbox(t[i + 1] & 255)
			t[3] = aes_sbox(first)
			t[0] ^= rc
			rc = aes_xtime(rc)
		else if (len == 32 && pos % len == 16):
			for i in range(4): t[i] = aes_sbox(t[i] & 255)
		for i in range(4): key.rounds[pos + i] = key.rounds[pos - len + i] ^ t[i]
		pos += 4
	mem_fill(cast(char*, t), 0, 4)
	mem_fill(key.h, 0, 16)
	aes_encrypt_block(key, key.h, key.h)
	return key


void aes_gcm_key_free(aes_gcm_key* key):
	if (key == 0): return
	mem_fill(key.rounds, 0, 240)
	mem_fill(key.h, 0, 16)
	free(key.rounds)
	free(key.h)
	free(key)


# SP 800-38D Algorithm 1: multiply in GF(2^128), MSB first.
void aes_gcm_multiply(char* x, char* h):
	char[16] z
	char[16] v
	mem_fill(cast(char*, z), 0, 16)
	mem_copy(cast(char*, v), h, 16)
	for bit in range(128):
		int mask = 0 - ((x[bit / 8] >> (7 - bit % 8)) & 1)
		for j in range(16): z[j] ^= v[j] & mask
		int reduction = 225 & (0 - (v[15] & 1))
		int carry = 0
		for j in range(16):
			int value = v[j] & 255
			v[j] = (value >> 1) | carry
			carry = (value & 1) << 7
		v[0] ^= reduction
	mem_copy(x, cast(char*, z), 16)
	mem_fill(cast(char*, z), 0, 16)
	mem_fill(cast(char*, v), 0, 16)


void aes_gcm_hash_bytes(char* state, char* h, char* bytes, int len):
	int pos = 0
	while (pos < len):
		int n = len - pos
		if (n > 16): n = 16
		for i in range(n): state[i] ^= bytes[pos + i]
		aes_gcm_multiply(state, h)
		pos += n


# Input lengths are bounded to signed 31-bit byte counts on every arch.
# Their bit lengths fit 64 bits; write high/low halves explicitly.
void aes_gcm_tag(aes_gcm_key* key, char* nonce, char* aad, int aad_len, char* ct, int len, char* tag):
	char[16] state
	char[16] block
	mem_fill(cast(char*, state), 0, 16)
	aes_gcm_hash_bytes(state, key.h, aad, aad_len)
	aes_gcm_hash_bytes(state, key.h, ct, len)
	store_be32(block, aad_len >> 29)
	store_be32(cast(char*, block) + 4, aad_len << 3)
	store_be32(cast(char*, block) + 8, len >> 29)
	store_be32(cast(char*, block) + 12, len << 3)
	for i in range(16): state[i] ^= block[i]
	aes_gcm_multiply(state, key.h)
	mem_copy(cast(char*, block), nonce, 12)
	store_be32(cast(char*, block) + 12, 1)
	aes_encrypt_block(key, block, block)
	for i in range(16): tag[i] = state[i] ^ block[i]
	mem_fill(cast(char*, state), 0, 16)
	mem_fill(cast(char*, block), 0, 16)


void aes_gcm_xor(aes_gcm_key* key, char* nonce, char* input, int len, char* out):
	char[16] counter
	char[16] stream
	mem_copy(cast(char*, counter), nonce, 12)
	int block = 2
	int pos = 0
	while (pos < len):
		store_be32(cast(char*, counter) + 12, block)
		aes_encrypt_block(key, counter, stream)
		int n = len - pos
		if (n > 16): n = 16
		for i in range(n): out[pos + i] = input[pos + i] ^ stream[i]
		pos += n
		block += 1
	mem_fill(cast(char*, counter), 0, 16)
	mem_fill(cast(char*, stream), 0, 16)


int aes_gcm_valid_lengths(int aad_len, int len):
	return aad_len >= 0 && len >= 0 && aad_len <= 2147483647 && len <= 2147483647


# Nonces MUST be unique for each key. Exact in-place encryption is allowed.
int aes_gcm_seal(aes_gcm_key* key, char* nonce, char* aad, int aad_len, char* plain, int len, char* ct, char* tag):
	if (key == 0 || aes_gcm_valid_lengths(aad_len, len) == 0): return 0
	aes_gcm_xor(key, nonce, plain, len, ct)
	aes_gcm_tag(key, nonce, aad, aad_len, ct, len, tag)
	return 1


# Authenticate before decrypting. A failure leaves the output untouched.
int aes_gcm_open(aes_gcm_key* key, char* nonce, char* aad, int aad_len, char* ct, int len, char* tag, char* plain):
	if (key == 0 || aes_gcm_valid_lengths(aad_len, len) == 0): return 0
	char[16] expected
	aes_gcm_tag(key, nonce, aad, aad_len, ct, len, expected)
	int diff = 0
	for i in range(16): diff |= (expected[i] ^ tag[i]) & 255
	mem_fill(cast(char*, expected), 0, 16)
	if (diff != 0): return 0
	aes_gcm_xor(key, nonce, ct, len, plain)
	return 1
