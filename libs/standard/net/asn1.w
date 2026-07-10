# Strict, bounded ASN.1 DER reader for the pure-W HTTPS stack (issue #199,
# part of #155). This is the parsing substrate for net/x509.w; it never
# allocates for element access and never reads past the window it was given.
#
# Strictness rules (DER, definite-length only):
#  - single-byte tags only (X.509 never needs multi-byte tags),
#  - lengths in short form, or minimal long form of at most 4 bytes with the
#    top bit of a 4-byte length clear (so every length fits a 32-bit int),
#  - indefinite length (0x80) rejected,
#  - every element must lie entirely inside the reader's window,
#  - asn1_done() lets callers reject trailing garbage,
#  - INTEGERs must be minimally encoded, BOOLEANs one byte.
#
# A reader is a cheap value over someone else's buffer:
#   asn1 r
#   asn1_init(&r, data, start, end)
#   asn1_expect(&r, ASN1_SEQUENCE(), &start, &len)   # content window
# Element positions come back as (start, len) offsets into the same buffer,
# so nested structures are parsed by pointing a new reader at the content.
import lib.lib


# ---- universal tags (and the X.509 context tags built from them) -------------

int ASN1_BOOLEAN():
	return 1


int ASN1_INTEGER():
	return 2


int ASN1_BIT_STRING():
	return 3


int ASN1_OCTET_STRING():
	return 4


int ASN1_NULL():
	return 5


int ASN1_OID():
	return 6


int ASN1_UTF8STRING():
	return 12


int ASN1_SEQUENCE():
	return 48    # 0x30: SEQUENCE, constructed


int ASN1_SET():
	return 49    # 0x31: SET, constructed


int ASN1_PRINTABLESTRING():
	return 19


int ASN1_IA5STRING():
	return 22


int ASN1_UTCTIME():
	return 23


int ASN1_GENERALIZEDTIME():
	return 24


# Context-specific tag [n], constructed (0xa0 | n).
int ASN1_CONTEXT(int n):
	return 160 | n


# Context-specific tag [n], primitive (0x80 | n).
int ASN1_CONTEXT_PRIMITIVE(int n):
	return 128 | n


# ---- reader -------------------------------------------------------------------

struct asn1:
	char* data
	int pos      # next unread byte (absolute offset into data)
	int end      # one past the last readable byte


void asn1_init(asn1* r, char* data, int start, int end):
	r.data = data
	r.pos = start
	r.end = end


# 1 when every byte of the window has been consumed (no trailing garbage).
int asn1_done(asn1* r):
	if (r.pos == r.end):
		return 1
	return 0


# The tag byte of the next element without consuming it, or -1 at the end.
int asn1_peek(asn1* r):
	if (r.pos >= r.end):
		return -1
	return r.data[r.pos] & 255


# Read the next TLV: stores the tag, the content offset, and the content
# length, then advances past the element. Returns 1 on success, 0 on any
# malformed or out-of-bounds header (the reader is left unchanged on error).
int asn1_next(asn1* r, int* out_tag, int* out_start, int* out_len):
	if (r.pos >= r.end):
		return 0
	int tag = r.data[r.pos] & 255
	if ((tag & 31) == 31):
		return 0    # multi-byte tag: not used by X.509, reject
	int p = r.pos + 1
	if (p >= r.end):
		return 0
	int first = r.data[p] & 255
	p = p + 1
	int len = 0
	if (first < 128):
		len = first
	else if (first == 128):
		return 0    # indefinite length: never valid in DER
	else:
		int nbytes = first - 128
		if (nbytes > 4):
			return 0
		if (nbytes > r.end - p):
			return 0
		int i = 0
		while (i < nbytes):
			int d = r.data[p] & 255
			if (i == 0):
				if (d == 0):
					return 0    # non-minimal: leading zero length byte
				if (nbytes == 4):
					if (d >= 128):
						return 0    # length would not fit a 32-bit int
			len = (len << 8) | d
			p = p + 1
			i = i + 1
		if (len < 128):
			return 0    # non-minimal: long form used for a short length
	if (len > r.end - p):
		return 0    # content would run past the window
	*out_tag = tag
	*out_start = p
	*out_len = len
	r.pos = p + len
	return 1


# Read the next TLV and require its tag. Returns 1/0.
int asn1_expect(asn1* r, int tag, int* out_start, int* out_len):
	int got = 0
	int start = 0
	int len = 0
	if (asn1_next(r, &got, &start, &len) == 0):
		return 0
	if (got != tag):
		return 0
	*out_start = start
	*out_len = len
	return 1


# Skip the next element regardless of tag. Returns 1/0.
int asn1_skip(asn1* r):
	int tag = 0
	int start = 0
	int len = 0
	return asn1_next(r, &tag, &start, &len)


# ---- typed helpers -------------------------------------------------------------

# Is the INTEGER content at (start, len) minimally encoded per DER?
int asn1_integer_minimal(char* data, int start, int len):
	if (len <= 0):
		return 0
	if (len == 1):
		return 1
	int b0 = data[start] & 255
	int b1 = data[start + 1] & 255
	if (b0 == 0):
		if (b1 < 128):
			return 0    # 00 followed by a low byte: redundant leading zero
	if (b0 == 255):
		if (b1 >= 128):
			return 0    # ff followed by a high byte: redundant leading ff
	return 1


# Read an INTEGER, returning its raw content bytes (minimal-encoding
# enforced; the value may be negative — callers that need positivity check
# the first byte). Returns 1/0.
int asn1_read_integer(asn1* r, int* out_start, int* out_len):
	int start = 0
	int len = 0
	if (asn1_expect(r, ASN1_INTEGER(), &start, &len) == 0):
		return 0
	if (asn1_integer_minimal(r.data, start, len) == 0):
		return 0
	*out_start = start
	*out_len = len
	return 1


# Read a non-negative INTEGER small enough for a 32-bit int (used for
# version numbers and pathLenConstraint). Returns 1/0.
int asn1_read_small_int(asn1* r, int* out_value):
	int start = 0
	int len = 0
	if (asn1_read_integer(r, &start, &len) == 0):
		return 0
	int first = r.data[start] & 255
	if (first >= 128):
		return 0    # negative
	# Strip the sign-clearing leading zero if present.
	if (first == 0):
		start = start + 1
		len = len - 1
	if (len > 4):
		return 0
	if (len == 4):
		if ((r.data[start] & 255) >= 128):
			return 0    # would not fit a signed 32-bit int
	int v = 0
	int i = 0
	while (i < len):
		v = (v << 8) | (r.data[start + i] & 255)
		i = i + 1
	*out_value = v
	return 1


# Read a positive INTEGER as big-endian magnitude bytes with the
# sign-clearing leading zero stripped (RSA moduli/exponents, ECDSA r/s).
# Zero and negative values are rejected. Returns 1/0.
int asn1_read_positive_integer(asn1* r, int* out_start, int* out_len):
	int start = 0
	int len = 0
	if (asn1_read_integer(r, &start, &len) == 0):
		return 0
	int first = r.data[start] & 255
	if (first >= 128):
		return 0    # negative
	if (first == 0):
		start = start + 1
		len = len - 1
	if (len == 0):
		return 0    # the value zero
	*out_start = start
	*out_len = len
	return 1


# Read a BOOLEAN (DER: exactly one content byte, 0x00 or 0xff). Returns 1/0.
int asn1_read_boolean(asn1* r, int* out_value):
	int start = 0
	int len = 0
	if (asn1_expect(r, ASN1_BOOLEAN(), &start, &len) == 0):
		return 0
	if (len != 1):
		return 0
	int b = r.data[start] & 255
	if (b == 0):
		*out_value = 0
		return 1
	if (b == 255):
		*out_value = 1
		return 1
	return 0


# Read a BIT STRING that carries whole bytes (unused-bits count must be 0:
# X.509 signatures and public keys are always octet-aligned). The returned
# window excludes the unused-bits prefix byte. Returns 1/0.
int asn1_read_bitstring_bytes(asn1* r, int* out_start, int* out_len):
	int start = 0
	int len = 0
	if (asn1_expect(r, ASN1_BIT_STRING(), &start, &len) == 0):
		return 0
	if (len < 1):
		return 0
	if ((r.data[start] & 255) != 0):
		return 0
	*out_start = start + 1
	*out_len = len - 1
	return 1


# Do the element bytes at (start, len) equal the len2 bytes at want?
int asn1_bytes_equal(char* data, int start, int len, char* want, int len2):
	if (len != len2):
		return 0
	int i = 0
	while (i < len):
		if ((data[start + i] & 255) != (want[i] & 255)):
			return 0
		i = i + 1
	return 1
