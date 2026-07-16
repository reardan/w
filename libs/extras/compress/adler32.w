/*
libs/extras/compress/adler32.w: Adler-32, the checksum zlib.w's trailer
needs (RFC 1950 §9; docs/projects/compress.md §5.1). Two 16-bit sums mod
65521 (the largest prime below 2^16), combined as (s2 << 16) | s1.

No bit-31 hazard here (contrast crc32.w): s1 and s2 are each bounded by
65520, so s2 << 16 only ever sets bits 16-31 and never overflows a 32-bit
word, and nothing here is a literal token with bit 31 set in the first
place. The combined result can still have bit 31 set (whenever s2 >=
32768), which is fine -- it is a runtime value, not a literal, so it is
simply "the low 32 bits are what matter" like every other checksum in
this package (docs/projects/compress.md §6.1): compare it, XOR it, or
byte-extract it, but never decimal-format it, since that would print
differently on a 32- vs 64-bit host.
*/


int adler32_mod():
	return 65521


# Continues a checksum: adler=1 starts a fresh one -- the algorithm's true
# neutral element (not 0; s1 begins at 1 per RFC 1950), mirroring zlib's
# adler32() convention exactly, so adler32_update(adler32_update(1, a,
# na), b, nb) equals the digest of a+b concatenated. A negative length is
# treated as zero, matching libs/standard/crypto/base64.w's convention.
int adler32_update(int adler, char* data, int length):
	if (length < 0):
		length = 0
	int mod = adler32_mod()
	int s1 = adler & 65535
	int s2 = shr(adler, 16) & 65535
	int i = 0
	while (i < length):
		s1 = (s1 + (data[i] & 255)) % mod
		s2 = (s2 + s1) % mod
		i = i + 1
	return (s2 << 16) | s1


int adler32_of(char* data, int length):
	return adler32_update(1, data, length)
