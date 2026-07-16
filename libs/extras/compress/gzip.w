/*
libs/extras/compress/gzip.w: the RFC 1952 gzip wrapper -- a 10-byte
fixed header (magic 1f 8b, method, flag byte, mtime, extra flags, OS id)
plus optional FEXTRA/FNAME/FCOMMENT/FHCRC fields gated by the flag byte,
one DEFLATE stream, and an 8-byte trailer (CRC-32 of the uncompressed
data, little-endian, then uncompressed size mod 2^32, little-endian).
The intended consumer is HTTP `Content-Encoding: gzip`
(docs/projects/compress.md §1, §7.2) -- the only content-coding besides
`identity` any real HTTP peer sends in practice.

gzip_compress emits a minimal single-member header (MTIME=0, XFL=0,
OS=255 "unknown", no FNAME/FCOMMENT/FEXTRA) so output is deterministic
byte-for-byte for the same input and level -- matters for the build
cache (content-addressed by hash of the blob) and matches `gzip -n`'s
reproducible-build convention (design doc §5.4).

gzip_decompress parses and skips FEXTRA/FNAME/FCOMMENT/FHCRC (real gzip
files from gzip(1)/git/browsers routinely set FNAME) but only reads a
single member; a concatenated multi-member stream (`cat a.gz b.gz`,
which gzip(1) explicitly supports) is out of scope for v1 -- flagged as
an open question in the design doc §10 point 3. Any bytes after the
first member's trailer are silently ignored, not rejected.

See zlib.w's header comment for the error-code-range and passthrough
conventions this file shares with it (GZIP_ERR_* codes are 201-205,
distinct from INFLATE_ERR_*'s 1-6 and ZLIB_ERR_*'s 101-103; a failure
from the wrapped inflate() call passes its INFLATE_ERR_* code through
unchanged rather than being remapped to a gzip-specific bucket).
*/
import lib.memory
import lib.result
import structures.string
import libs.extras.compress.crc32
import libs.extras.compress.deflate
import libs.extras.compress.inflate


int GZIP_ERR_BAD_MAGIC():
	return 201


int GZIP_ERR_UNSUPPORTED_METHOD():
	return 202


int GZIP_ERR_BAD_CRC():
	return 203


int GZIP_ERR_BAD_SIZE():
	return 204


int GZIP_ERR_TRUNCATED():
	return 205


char* gzip_error_string(int code):
	if (code == GZIP_ERR_BAD_MAGIC()):
		return c"gzip: bad magic bytes (not a gzip stream)"
	if (code == GZIP_ERR_UNSUPPORTED_METHOD()):
		return c"gzip: unsupported compression method"
	if (code == GZIP_ERR_BAD_CRC()):
		return c"gzip: CRC-32 checksum mismatch"
	if (code == GZIP_ERR_BAD_SIZE()):
		return c"gzip: decompressed size does not match the ISIZE trailer"
	if (code == GZIP_ERR_TRUNCATED()):
		return c"gzip: truncated stream"
	return inflate_error_string(code)


struct gzip_result:
	char* data
	int length


void gzip_result_free(gzip_result* r):
	free(r.data)
	free(r)


# Encoding trusted, caller-owned bytes cannot fail (docs/projects/
# compress.md §5.5), so this returns a plain value, never a wresult[T]*.
gzip_result* gzip_compress(char* data, int length, int level):
	if (length < 0):
		length = 0
	deflate_result* body = deflate(data, length, level)
	string_builder* out = string_new()
	string_append_char(out, 0x1f)
	string_append_char(out, 0x8b)
	string_append_char(out, 8)    # CM: deflate
	string_append_char(out, 0)    # FLG: no optional fields
	string_append_char(out, 0)    # MTIME (4 bytes), fixed at 0 for reproducibility
	string_append_char(out, 0)
	string_append_char(out, 0)
	string_append_char(out, 0)
	string_append_char(out, 0)    # XFL
	string_append_char(out, 255)  # OS: unknown
	string_append_bytes(out, body.data, body.length)
	int crc = crc32_of(data, length)
	string_append_char(out, crc & 255)
	string_append_char(out, shr(crc, 8) & 255)
	string_append_char(out, shr(crc, 16) & 255)
	string_append_char(out, shr(crc, 24) & 255)
	# ISIZE is defined as "input size mod 2^32" (RFC 1952 §2.3.1), so a
	# multi-gigabyte input wraps by spec, not by bug; crc32_mask32() folds
	# `length` to its low 32 bits the same way it folds a CRC accumulator.
	int isize = length & crc32_mask32()
	string_append_char(out, isize & 255)
	string_append_char(out, shr(isize, 8) & 255)
	string_append_char(out, shr(isize, 16) & 255)
	string_append_char(out, shr(isize, 24) & 255)
	deflate_result_free(body)
	char* out_data = out.data
	int out_length = out.length
	free(out)
	gzip_result* r = new gzip_result
	r.data = out_data
	r.length = out_length
	return r


# max_output <= 0 means unbounded (docs/projects/compress.md §5.2/§6.3) --
# only appropriate for trusted input; untrusted input (an HTTP response
# body) should always pass a real cap.
wresult[gzip_result*]* gzip_decompress(char* data, int length, int max_output):
	if (length < 10):
		return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
	int id1 = data[0] & 255
	int id2 = data[1] & 255
	if ((id1 != 0x1f) || (id2 != 0x8b)):
		return result_new_error[gzip_result*](GZIP_ERR_BAD_MAGIC())
	int cm = data[2] & 255
	if (cm != 8):
		return result_new_error[gzip_result*](GZIP_ERR_UNSUPPORTED_METHOD())
	int flg = data[3] & 255
	int f_hcrc = (flg >> 1) & 1
	int f_extra = (flg >> 2) & 1
	int f_name = (flg >> 3) & 1
	int f_comment = (flg >> 4) & 1

	int pos = 10
	if (f_extra):
		if (pos + 2 > length):
			return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
		int xlen = (data[pos] & 255) | ((data[pos + 1] & 255) << 8)
		pos = pos + 2 + xlen
		if (pos > length):
			return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
	if (f_name):
		while ((pos < length) && ((data[pos] & 255) != 0)):
			pos = pos + 1
		if (pos >= length):
			return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
		pos = pos + 1
	if (f_comment):
		while ((pos < length) && ((data[pos] & 255) != 0)):
			pos = pos + 1
		if (pos >= length):
			return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
		pos = pos + 1
	if (f_hcrc):
		if (pos + 2 > length):
			return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
		pos = pos + 2
	if (pos + 8 > length):
		# Not even room for the 8-byte trailer after a (possibly empty)
		# deflate stream.
		return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())

	int consumed = 0
	wresult[inflate_result*]* ir = inflate_ex(data + pos, length - pos, max_output, &consumed)
	if (result_is_error[inflate_result*](ir)):
		int code = result_code[inflate_result*](ir)
		result_free[inflate_result*](ir)
		return result_new_error[gzip_result*](code)
	inflate_result* body = result_value[inflate_result*](ir)
	result_free[inflate_result*](ir)

	int trailer_start = pos + consumed
	if (trailer_start + 8 > length):
		inflate_result_free(body)
		return result_new_error[gzip_result*](GZIP_ERR_TRUNCATED())
	int crc = (data[trailer_start] & 255) | ((data[trailer_start + 1] & 255) << 8) | ((data[trailer_start + 2] & 255) << 16) | ((data[trailer_start + 3] & 255) << 24)
	int isize = (data[trailer_start + 4] & 255) | ((data[trailer_start + 5] & 255) << 8) | ((data[trailer_start + 6] & 255) << 16) | ((data[trailer_start + 7] & 255) << 24)
	int actual_crc = crc32_of(body.data, body.length)
	if (actual_crc != crc):
		inflate_result_free(body)
		return result_new_error[gzip_result*](GZIP_ERR_BAD_CRC())
	int actual_size = body.length & crc32_mask32()
	if (actual_size != isize):
		inflate_result_free(body)
		return result_new_error[gzip_result*](GZIP_ERR_BAD_SIZE())

	gzip_result* r = new gzip_result
	r.data = body.data
	r.length = body.length
	free(body)
	return result_new_ok[gzip_result*](r)
