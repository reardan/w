/*
libs/x/unsafe: RC4 stream cipher (plain RC4 keystream, no drop-N
variants).

*** BROKEN FOR SECURITY PURPOSES — INTEROP/LEGACY USE ONLY. ***
RC4's keystream is biased enough that plaintext can be recovered from
enough ciphertexts; it is prohibited in TLS (RFC 7465) and must not
protect anything. This module exists solely to interoperate with legacy
formats that still use it (old PDF and office-document encryption,
legacy protocols). No side-channel or constant-time guarantees are
made — the permutation is indexed by key- and keystream-dependent
values by construction.

	rc4* r = rc4_new(key, key_len)      # key_len 1..256 bytes
	rc4_keystream(r, out, len)          # raw keystream bytes
	rc4_process(r, data, out, len)      # xor: encrypt == decrypt
	rc4_reset(r, key, key_len)          # rekey, reusing the allocation
	rc4_free(r)                         # zeroes the state first
*/
import lib.memory


struct rc4:
	char* s   # the 256-byte permutation
	int i     # PRGA indices
	int j


# Key-scheduling algorithm: (re)build the permutation from key (1..256
# bytes) and rewind the generator.
void rc4_reset(rc4* r, char* key, int key_len):
	int i = 0
	while (i < 256):
		r.s[i] = i
		i = i + 1
	int j = 0
	i = 0
	while (i < 256):
		j = (j + (r.s[i] & 255) + (key[i % key_len] & 255)) & 255
		int tmp = r.s[i] & 255
		r.s[i] = r.s[j]
		r.s[j] = tmp
		i = i + 1
	r.i = 0
	r.j = 0


rc4* rc4_new(char* key, int key_len):
	rc4* r = new rc4
	r.s = malloc(256)
	rc4_reset(r, key, key_len)
	return r


# Next keystream byte (PRGA), 0..255.
int rc4_next(rc4* r):
	r.i = (r.i + 1) & 255
	r.j = (r.j + (r.s[r.i] & 255)) & 255
	int tmp = r.s[r.i] & 255
	r.s[r.i] = r.s[r.j]
	r.s[r.j] = tmp
	return r.s[((r.s[r.i] & 255) + (r.s[r.j] & 255)) & 255] & 255


# Write len raw keystream bytes to out.
void rc4_keystream(rc4* r, char* out, int len):
	int i = 0
	while (i < len):
		out[i] = rc4_next(r)
		i = i + 1


# XOR len bytes at data with the keystream into out (data == out is
# fine); RC4 encryption and decryption are the same operation.
void rc4_process(rc4* r, char* data, char* out, int len):
	int i = 0
	while (i < len):
		out[i] = (data[i] & 255) ^ rc4_next(r)
		i = i + 1


# Zero the key-derived permutation before releasing it.
void rc4_free(rc4* r):
	int i = 0
	while (i < 256):
		r.s[i] = 0
		i = i + 1
	r.i = 0
	r.j = 0
	free(r.s)
	free(r)
