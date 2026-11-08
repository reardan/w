# wbuild: target=wfuzz_inflate_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/inflate/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_inflate.w -o bin/wfuzz_inflate_harness"
# wbuild: step="rm -rf bin/wfuzz_inflate_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_inflate_harness --bytes --ext .z --corpus tools/fuzz/seeds/inflate --out bin/wfuzz_inflate_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_inflate tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_inflate.w -o bin/wfuzz_inflate_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_inflate_harness --bytes --ext .z --corpus tools/fuzz/seeds/inflate --out bin/wfuzz_inflate" timeout=3600000
# Fuzz harness for libs/extras/compress (issue #842). Every input goes
# through each decoder -- raw DEFLATE (inflate, and inflate_window with
# a preset window), zlib and gzip -- with a 4 MiB output cap; the
# input's own bytes then go through each encoder (zlib, gzip and
# deflate_window at the level the first byte picks), and the decoded
# result must give the input back.
import tools.fuzz.harness
import libs.extras.compress.inflate
import libs.extras.compress.deflate
import libs.extras.compress.zlib
import libs.extras.compress.gzip


const int fh_cap = 4194304


int fh_inflate_decoders(char* data, int length):
	int accepted = 0
	wresult[inflate_result*]* raw = inflate(data, length, fh_cap)
	if (result_is_error[inflate_result*](raw) == 0):
		accepted = 1
		inflate_result* r = result_value[inflate_result*](raw)
		fh_check(r.length <= fh_cap, c"inflate exceeded max_output")
		inflate_result_free(r)
	result_free[inflate_result*](raw)
	char* window = c"preset window: the quick brown fox jumps over the lazy dog"
	int out_len = 0
	int out_error = 0
	char* piece = inflate_window(data, length, window, strlen(window), fh_cap, &out_len, &out_error)
	if (piece != 0):
		accepted = 1
		fh_check(out_len <= fh_cap, c"inflate_window exceeded max_output")
		free(piece)
	wresult[zlib_result*]* z = zlib_decompress(data, length, fh_cap)
	if (result_is_error[zlib_result*](z) == 0):
		accepted = 1
		zlib_result_free(result_value[zlib_result*](z))
	result_free[zlib_result*](z)
	wresult[gzip_result*]* g = gzip_decompress(data, length, fh_cap)
	if (result_is_error[gzip_result*](g) == 0):
		accepted = 1
		gzip_result_free(result_value[gzip_result*](g))
	result_free[gzip_result*](g)
	return accepted


void fh_inflate_round_trips(char* data, int length):
	int level = 6
	if (length > 0): level = (data[0] & 255) % 10
	zlib_result* packed = zlib_compress(data, length, level)
	wresult[zlib_result*]* back = zlib_decompress(packed.data, packed.length, length + 1)
	fh_check(result_is_error[zlib_result*](back) == 0, c"zlib_compress output does not decompress")
	zlib_result* plain = result_value[zlib_result*](back)
	fh_check((plain.length == length) && fh_bytes_equal(plain.data, data, length), c"zlib round trip changed the bytes")
	zlib_result_free(plain)
	result_free[zlib_result*](back)
	zlib_result_free(packed)
	gzip_result* gz = gzip_compress(data, length, level)
	wresult[gzip_result*]* gback = gzip_decompress(gz.data, gz.length, length + 1)
	fh_check(result_is_error[gzip_result*](gback) == 0, c"gzip_compress output does not decompress")
	gzip_result* gplain = result_value[gzip_result*](gback)
	fh_check((gplain.length == length) && fh_bytes_equal(gplain.data, data, length), c"gzip round trip changed the bytes")
	gzip_result_free(gplain)
	result_free[gzip_result*](gback)
	gzip_result_free(gz)
	# One flushed piece against a window made of the input's tail.
	int half = length / 2
	int piece_len = 0
	char* piece = deflate_window(data + half, length - half, data, half, 15, level % 3, &piece_len)
	int out_len = 0
	int out_error = 0
	char* out = inflate_window(piece, piece_len, data, half, length + 1, &out_len, &out_error)
	fh_check(out != 0, c"deflate_window output does not inflate")
	fh_check((out_len == length - half) && fh_bytes_equal(out, data + half, out_len), c"deflate_window round trip changed the bytes")
	free(out)
	free(piece)


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	int accepted = fh_inflate_decoders(data, length)
	fh_inflate_round_trips(data, length)
	if (accepted): return 0
	return 1
