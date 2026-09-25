/*
libs/extras/compress/codecs.w: plugs this package's gzip (RFC 1952) and
zlib-wrapped deflate (RFC 1950, the HTTP/gRPC "deflate" coding) into the
content-coding registry of libs/standard/web/codec.w, so protocol modules
under libs/standard (libs/standard/web/grpc.w today) can negotiate and
use them without importing libs/extras themselves. An application opts
in once:

	import libs.extras.compress.codecs
	compress_codecs_register()

Compression uses DEFLATE_LEVEL_FAST (real LZ77 + Huffman). Decompression
passes the caller's cap straight to inflate's max_output, so an
over-expanding stream fails with codec_err_too_large() the moment it
crosses the cap -- the output is never materialized past it. Every other
decode failure (bad header, checksum, truncated or corrupt stream) is
codec_err_corrupt().
*/
import lib.memory
import lib.result
import libs.extras.compress.inflate
import libs.extras.compress.deflate
import libs.extras.compress.zlib
import libs.extras.compress.gzip
import libs.standard.web.codec


int compress_codec_status(int code):
	if (code == INFLATE_ERR_TOO_LARGE()):
		return codec_err_too_large()
	return codec_err_corrupt()


int compress_codec_gzip_encode(char* in, int len, char** out, int* out_len):
	gzip_result* r = gzip_compress(in, len, DEFLATE_LEVEL_FAST())
	*out = r.data
	*out_len = r.length
	free(r)
	return codec_ok()


int compress_codec_gzip_decode(char* in, int len, int max, char** out, int* out_len):
	*out = 0
	*out_len = 0
	wresult[gzip_result*]* res = gzip_decompress(in, len, max)
	if (result_is_error[gzip_result*](res)):
		int code = result_code[gzip_result*](res)
		result_free[gzip_result*](res)
		return compress_codec_status(code)
	gzip_result* r = result_value[gzip_result*](res)
	result_free[gzip_result*](res)
	*out = r.data
	*out_len = r.length
	free(r)
	return codec_ok()


int compress_codec_deflate_encode(char* in, int len, char** out, int* out_len):
	zlib_result* r = zlib_compress(in, len, DEFLATE_LEVEL_FAST())
	*out = r.data
	*out_len = r.length
	free(r)
	return codec_ok()


int compress_codec_deflate_decode(char* in, int len, int max, char** out, int* out_len):
	*out = 0
	*out_len = 0
	wresult[zlib_result*]* res = zlib_decompress(in, len, max)
	if (result_is_error[zlib_result*](res)):
		int code = result_code[zlib_result*](res)
		result_free[zlib_result*](res)
		return compress_codec_status(code)
	zlib_result* r = result_value[zlib_result*](res)
	result_free[zlib_result*](res)
	*out = r.data
	*out_len = r.length
	free(r)
	return codec_ok()


# Registers "gzip" then "deflate" (that order is the advertised
# preference). Idempotent.
void compress_codecs_register():
	codec_register(c"gzip", compress_codec_gzip_encode, compress_codec_gzip_decode)
	codec_register(c"deflate", compress_codec_deflate_encode, compress_codec_deflate_decode)
