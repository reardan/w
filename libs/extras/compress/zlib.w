/*
libs/extras/compress/zlib.w: the RFC 1950 zlib wrapper -- a 2-byte
CMF/FLG header (compression method + window size + a 5-bit FCHECK making
the 16-bit header a multiple of 31), one DEFLATE stream, and a 4-byte
big-endian Adler-32 trailer of the *uncompressed* data. This is git's
loose-object envelope (docs/projects/compress.md §0, §1) and the "gateway
to git-format interop" this package exists for.

Error code ranges (this file, gzip.w, inflate.w) are disjoint on purpose
-- INFLATE_ERR_* occupy 1-6, ZLIB_ERR_* 101-103, GZIP_ERR_* 201-205 --
so a caller that only inspects the raw int code (rather than going
through zlib_error_string/gzip_error_string) never confuses a wrapper-
level failure with an inner-DEFLATE-stream failure.

Passthrough convention: the design doc §5.4 enumerates exactly three
zlib-specific error codes (bad header, unsupported method, bad checksum)
covering violations of *this file's own* framing. A failure from the
wrapped inflate() call (bad block type, truncated input, corrupt Huffman
table, ...) is a DEFLATE-stream problem, not a zlib-wrapper problem, so
zlib_decompress propagates the original INFLATE_ERR_* code unchanged
rather than inventing a fourth zlib-specific bucket for it -- the same
"pass syscall errno through unchanged" shape docs/error_results.txt
prescribes and libs/extras/vcs/cas.w already follows, just with inflate()
standing in for the syscall layer. zlib_error_string() falls through to
inflate_error_string() for any code it does not own, so callers get a
readable message either way without needing to know which layer failed.
*/
import lib.memory
import lib.result
import structures.string
import libs.extras.compress.adler32
import libs.extras.compress.deflate
import libs.extras.compress.inflate


int ZLIB_ERR_BAD_HEADER():
	return 101


int ZLIB_ERR_UNSUPPORTED_METHOD():
	return 102


int ZLIB_ERR_BAD_CHECKSUM():
	return 103


char* zlib_error_string(int code):
	if (code == ZLIB_ERR_BAD_HEADER()):
		return c"zlib: bad header (CMF/FLG fails the mod-31 check, or input is too short)"
	if (code == ZLIB_ERR_UNSUPPORTED_METHOD()):
		return c"zlib: unsupported compression method, or a preset dictionary is set"
	if (code == ZLIB_ERR_BAD_CHECKSUM()):
		return c"zlib: Adler-32 checksum mismatch"
	return inflate_error_string(code)


struct zlib_result:
	char* data
	int length


void zlib_result_free(zlib_result* r):
	free(r.data)
	free(r)


# Encoding trusted, caller-owned bytes cannot fail (docs/projects/
# compress.md §5.5), so this returns a plain value, never a wresult[T]*.
# CMF=0x78 (CM=8 deflate, CINFO=7 for a 32K window) matches what zlib
# itself emits; FLEVEL is fixed at 0 ("fastest") since deflate.w does not
# yet vary its output by level (deflate.w's DEFLATE_LEVEL_FAST comment),
# so a non-varying hint is the honest one. FCHECK is the 5-bit value
# making (CMF*256 + FLG) a multiple of 31, RFC 1950 §2.2.
zlib_result* zlib_compress(char* data, int length, int level):
	if (length < 0):
		length = 0
	deflate_result* body = deflate(data, length, level)
	string_builder* out = string_new()
	int cmf = 0x78
	int flevel = 0
	int flg_partial = flevel << 6
	int remainder = (cmf * 256 + flg_partial) % 31
	int fcheck = (31 - remainder) % 31
	int flg = flg_partial | fcheck
	string_append_char(out, cmf)
	string_append_char(out, flg)
	string_append_bytes(out, body.data, body.length)
	int adler = adler32_of(data, length)
	string_append_char(out, shr(adler, 24) & 255)
	string_append_char(out, shr(adler, 16) & 255)
	string_append_char(out, shr(adler, 8) & 255)
	string_append_char(out, adler & 255)
	deflate_result_free(body)
	char* out_data = out.data
	int out_length = out.length
	free(out)
	zlib_result* r = new zlib_result
	r.data = out_data
	r.length = out_length
	return r


# max_output <= 0 means unbounded (docs/projects/compress.md §5.2/§6.3) --
# only appropriate for trusted input whose length is already bounded some
# other way; untrusted input (e.g. an HTTP response body) should always
# pass a real cap.
wresult[zlib_result*]* zlib_decompress(char* data, int length, int max_output):
	if (length < 6):
		return result_new_error[zlib_result*](ZLIB_ERR_BAD_HEADER())
	int cmf = data[0] & 255
	int flg = data[1] & 255
	if (((cmf * 256 + flg) % 31) != 0):
		return result_new_error[zlib_result*](ZLIB_ERR_BAD_HEADER())
	int cm = cmf & 15
	int fdict = (flg >> 5) & 1
	if ((cm != 8) || (fdict != 0)):
		return result_new_error[zlib_result*](ZLIB_ERR_UNSUPPORTED_METHOD())

	int consumed = 0
	wresult[inflate_result*]* ir = inflate_ex(data + 2, length - 2, max_output, &consumed)
	if (result_is_error[inflate_result*](ir)):
		int code = result_code[inflate_result*](ir)
		result_free[inflate_result*](ir)
		return result_new_error[zlib_result*](code)
	inflate_result* body = result_value[inflate_result*](ir)
	result_free[inflate_result*](ir)

	int trailer_start = 2 + consumed
	if (length < trailer_start + 4):
		inflate_result_free(body)
		return result_new_error[zlib_result*](ZLIB_ERR_BAD_HEADER())
	int adler = ((data[trailer_start] & 255) << 24) | ((data[trailer_start + 1] & 255) << 16) | ((data[trailer_start + 2] & 255) << 8) | (data[trailer_start + 3] & 255)
	int actual = adler32_of(body.data, body.length)
	if (actual != adler):
		inflate_result_free(body)
		return result_new_error[zlib_result*](ZLIB_ERR_BAD_CHECKSUM())

	zlib_result* r = new zlib_result
	r.data = body.data
	r.length = body.length
	free(body)
	return result_new_ok[zlib_result*](r)
