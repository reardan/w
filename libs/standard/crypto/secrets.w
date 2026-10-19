/*
libs.standard.crypto.secrets: Python `secrets`-style helpers over the
kernel CSPRNG in libs/standard/crypto/random.w (getrandom(2), with the
/dev/urandom fallback that arm64_darwin always takes).

Use these, not libs/standard/numeric/random.w or lib/rand.w, for
anything an attacker must not predict: session tokens, password-reset
links, API keys, nonces. Those other modules are deterministic.

Failure: the CSPRNG can fail (no getrandom and no /dev/urandom). Every
entry point here fails closed: secrets_token_bytes returns 0, the string
builders return 0 (null), secrets_randbelow returns -1. Never fall back
to a predictable source on failure.

Strings are malloc'd, NUL-terminated and owned by the caller (free()).
nbytes is the amount of randomness, not the output length: hex doubles
it, urlsafe base64 makes it about 1.33x. secrets_default_nbytes (32) is
Python's default; prefer it unless a format dictates otherwise.
*/
import lib.lib
import lib.assert
import libs.standard.crypto.random
import libs.standard.crypto.base64


const int secrets_default_nbytes = 32


# Zeroes buf[0..n) so raw token bytes do not linger in freed heap memory.
void secrets_wipe(char* buf, int n):
	for i in range(n): buf[i] = 0


# Python token_bytes(n): fills buf[0..n) with CSPRNG bytes. Returns 1 on
# success, 0 on failure (buf contents then unspecified; do not use).
int secrets_token_bytes(char* buf, int n):
	return random_bytes(buf, n)


# Python token_hex(n): 2*n lowercase hex characters encoding n random
# bytes, or 0 when n < 0 or the CSPRNG fails.
char* secrets_token_hex(int nbytes):
	if (nbytes < 0): return 0
	char* raw = cast(char*, malloc(nbytes + 1))
	if (!random_bytes(raw, nbytes)):
		free(raw)
		return 0
	char* out = hex_encode(raw, nbytes)
	secrets_wipe(raw, nbytes)
	free(raw)
	return out


# Python token_urlsafe(n): n random bytes as RFC 4648 section 5 base64url
# ('-' and '_' in place of '+' and '/') with the '=' padding stripped,
# so the result is safe in URLs and file names. 0 when n < 0 or the
# CSPRNG fails.
char* secrets_token_urlsafe(int nbytes):
	if (nbytes < 0): return 0
	char* raw = cast(char*, malloc(nbytes + 1))
	if (!random_bytes(raw, nbytes)):
		free(raw)
		return 0
	char* out = base64_encode(raw, nbytes)
	secrets_wipe(raw, nbytes)
	free(raw)
	int i = 0
	while (out[i] != 0):
		if (out[i] == '+'): out[i] = '-'
		else if (out[i] == '/'): out[i] = '_'
		else if (out[i] == '='):
			out[i] = 0
			return out
		i = i + 1
	return out


# Python randbelow(n): uniform CSPRNG integer in [0, n), by rejection over
# 31-bit draws so no value is favoured. Fatal assert when n <= 0 (or,
# on a 64-bit host, n > 2^31 - 1). Returns -1 when the CSPRNG fails.
int secrets_randbelow(int n):
	asserts(c"secrets_randbelow: n must be positive", n > 0)
	int q = 1 << 30
	int mask31 = (q - 1) + q
	asserts(c"secrets_randbelow: n too large", n <= mask31)
	int rem = (mask31 % n + 1) % n
	char* buf = cast(char*, malloc(4))
	int v = -1
	while (v < 0):
		if (!random_bytes(buf, 4)):
			free(buf)
			return -1
		int w = ((buf[0] & 127) << 24) | ((buf[1] & 255) << 16) | ((buf[2] & 255) << 8) | (buf[3] & 255)
		if ((rem == 0) || (w <= mask31 - rem)): v = w % n
	free(buf)
	return v


# Python compare_digest(a, b) for byte strings: 1 when a[0..alen) and
# b[0..blen) are equal, else 0. The running time depends only on blen,
# never on the contents or on where the inputs differ: when the lengths
# differ, b is compared against itself (same work) and the length
# mismatch alone decides the result, exactly as CPython does. Pass the
# secret (expected) value as a and the attacker-supplied one as b.
int secrets_compare_digest(char* a, int alen, char* b, int blen):
	if ((alen < 0) || (blen < 0)): return 0
	int diff = alen ^ blen
	char* left = b
	if (alen == blen): left = a
	for i in range(blen): diff = diff | ((left[i] & 255) ^ (b[i] & 255))
	if (diff == 0): return 1
	return 0


# compare_digest over two NUL-terminated strings (ASCII tokens, hex
# digests). The length scan of each string is not constant-time with
# respect to its own length, which is not secret.
int secrets_compare_digest_str(char* a, char* b):
	return secrets_compare_digest(a, strlen(a), b, strlen(b))
