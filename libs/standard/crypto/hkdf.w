/*
HKDF (RFC 5869) extract/expand over HMAC, plus the TLS 1.3 key-schedule
helpers HKDF-Expand-Label and Derive-Secret (RFC 8446 §7.1) — plan 11,
issue #195. Works with any whash algorithm; TLS 1.3 uses SHA-256 for the
ChaCha20-Poly1305 suite and SHA-384 for the AES-256 one.

The HkdfLabel encoding is exact per RFC 8446:

	uint16 length            # output length in bytes, big-endian
	opaque label<7..255>     # 1-byte length, then "tls13 " + Label
	opaque context<0..255>   # 1-byte length, then the transcript hash

Derive-Secret(Secret, Label, Messages) hashes Messages itself; callers
that already hold a transcript digest (a whash_final snapshot) call
tls13_hkdf_expand_label directly with the digest as context.
*/
import lib.memory
import libs.standard.crypto.sha2
import libs.standard.crypto.hmac


# HKDF-Extract(salt, IKM) -> PRK (digest_size bytes at out_prk). A zero
# salt_len means "no salt": RFC 5869 substitutes digest_size zero bytes,
# which is exactly what the TLS 1.3 key schedule feeds the first extract.
void hkdf_extract(int alg, char* salt, int salt_len, char* ikm, int ikm_len, char* out_prk):
	if (salt_len > 0):
		hmac_compute(alg, salt, salt_len, ikm, ikm_len, out_prk)
		return
	int ds = whash_digest_size(alg)
	char* zeros = malloc(ds)
	int i = 0
	while (i < ds):
		zeros[i] = 0
		i = i + 1
	hmac_compute(alg, zeros, ds, ikm, ikm_len, out_prk)
	free(zeros)


# HKDF-Expand(PRK, info, L) -> okm_len bytes at okm. Returns 1 on
# success, 0 when okm_len is out of range (L > 255 * digest_size or
# negative). The PRK is keyed once; each round re-MACs T(n-1) || info ||
# counter under the same key via hmac_reset.
int hkdf_expand(int alg, char* prk, int prk_len, char* info, int info_len, char* okm, int okm_len):
	int ds = whash_digest_size(alg)
	if ((okm_len < 0) || (okm_len > 255 * ds)):
		return 0
	if (okm_len == 0):
		return 1
	whmac* m = hmac_new(alg, prk, prk_len)
	char* t = malloc(ds)
	char* counter = malloc(1)
	int produced = 0
	int round = 1
	while (produced < okm_len):
		hmac_reset(m)
		if (round > 1):
			hmac_update(m, t, ds)
		hmac_update(m, info, info_len)
		counter[0] = round
		hmac_update(m, counter, 1)
		hmac_final(m, t)
		int take = okm_len - produced
		if (take > ds):
			take = ds
		int i = 0
		while (i < take):
			okm[produced + i] = t[i]
			i = i + 1
		produced = produced + take
		round = round + 1
	int j = 0
	while (j < ds):
		t[j] = 0
		j = j + 1
	free(counter)
	free(t)
	hmac_free(m)
	return 1


# HKDF-Expand-Label(Secret, Label, Context, Length) per RFC 8446 §7.1.
# secret is a PRK of digest_size bytes; label is the bare label (e.g.
# "derived", "c hs traffic") without the "tls13 " prefix, which is added
# here; context is usually a transcript hash (may be empty). Returns 1 on
# success, 0 on out-of-range lengths (label > 249 bytes after prefixing,
# context > 255, or out_len out of HKDF range).
int tls13_hkdf_expand_label(int alg, char* secret, char* label, int label_len, char* context, int context_len, char* out, int out_len):
	if ((label_len < 0) || (label_len > 249)):
		return 0
	if ((context_len < 0) || (context_len > 255)):
		return 0
	char* prefix = c"tls13 "
	int prefixed_len = label_len + 6
	int info_len = 2 + 1 + prefixed_len + 1 + context_len
	char* info = malloc(info_len)
	info[0] = (out_len >> 8) & 255
	info[1] = out_len & 255
	info[2] = prefixed_len
	int pos = 3
	int i = 0
	while (i < 6):
		info[pos] = prefix[i]
		pos = pos + 1
		i = i + 1
	i = 0
	while (i < label_len):
		info[pos] = label[i]
		pos = pos + 1
		i = i + 1
	info[pos] = context_len
	pos = pos + 1
	i = 0
	while (i < context_len):
		info[pos] = context[i]
		pos = pos + 1
		i = i + 1
	int ok = hkdf_expand(alg, secret, whash_digest_size(alg), info, info_len, out, out_len)
	free(info)
	return ok


# Derive-Secret(Secret, Label, Messages) per RFC 8446 §7.1: the context
# is Transcript-Hash(Messages) and the output length is the digest size.
# messages is the raw concatenated handshake data ("" for the early and
# master derivation steps). Writes digest_size bytes to out; returns 1 on
# success, 0 on a bad label length.
int tls13_derive_secret(int alg, char* secret, char* label, int label_len, char* messages, int messages_len, char* out):
	int ds = whash_digest_size(alg)
	char* transcript = malloc(ds)
	whash_oneshot(alg, messages, messages_len, transcript)
	int ok = tls13_hkdf_expand_label(alg, secret, label, label_len, transcript, ds, out, ds)
	free(transcript)
	return ok
