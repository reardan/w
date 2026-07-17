/*
Optional zlib/gzip cross-validation against a real python3 (issue #252,
docs/projects/compress.md §8's "cross-validation without a build-time
system-zlib dependency"). NOT part of the tests umbrella -- run with
`./wbuild compress_zlib_interop_test`; tools/compress_zlib_interop_test.sh
gates on `command -v python3` and drives both directions:

  compress <dir>    write <dir>/w.zlib and <dir>/w.gz, this package's own
                     zlib_compress/gzip_compress output over
                     compress_zlib_interop_payload() -- the runner script
                     then feeds both to python3's zlib/gzip modules and
                     checks the decompressed bytes match.
  decompress <dir>   read <dir>/py.zlib and <dir>/py.gz (written by the
                     runner script via python3's zlib.compress/
                     gzip.compress over the same payload) and check this
                     package's zlib_decompress/gzip_decompress recovers
                     the exact payload.

Mirrors tests/openssl_tls_interop.w's shape (an argv-driven harness the
shell runner wraps under `command -v`/timeout), but needs no sockets or
subprocess spawning of its own -- the runner script drives both
directions with two separate invocations instead.
*/
import lib.lib
import lib.args
import lib.stream
import structures.string
import libs.extras.compress.deflate
import libs.extras.compress.zlib
import libs.extras.compress.gzip


char* compress_zlib_interop_payload():
	return c"zlib/gzip python3 interop payload, issue #252, docs/projects/compress.md"


void czi_write_file(char* path, char* data, int length):
	wstream* out = stream_open_write(path)
	if (cast(int, out) == 0):
		print2(c"cannot open for write: ")
		println2(path)
		exit(1)
	stream_write(out, data, length)
	stream_close(out)


char* czi_read_file(char* path, int* out_len):
	wstream* in = stream_open_read(path)
	if (cast(int, in) == 0):
		print2(c"cannot open for read: ")
		println2(path)
		exit(1)
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	stream_close(in)
	*out_len = contents.length
	char* data = contents.data
	free(contents)
	return data


void czi_compress(char* dir):
	char* payload = compress_zlib_interop_payload()
	int len = strlen(payload)

	zlib_result* z = zlib_compress(payload, len, DEFLATE_LEVEL_STORED())
	string_builder* zpath = string_new()
	string_append(zpath, dir)
	string_append(zpath, c"/w.zlib")
	czi_write_file(zpath.data, z.data, z.length)
	string_free(zpath)
	zlib_result_free(z)

	gzip_result* g = gzip_compress(payload, len, DEFLATE_LEVEL_STORED())
	string_builder* gpath = string_new()
	string_append(gpath, dir)
	string_append(gpath, c"/w.gz")
	czi_write_file(gpath.data, g.data, g.length)
	string_free(gpath)
	gzip_result_free(g)

	println(c"wrote w.zlib and w.gz")


int czi_check(char* label, char* got, int got_len, char* want, int want_len):
	if (got_len != want_len):
		print2(label)
		println2(c": length mismatch")
		return 0
	int i = 0
	while (i < want_len):
		if ((got[i] & 255) != (want[i] & 255)):
			print2(label)
			println2(c": byte mismatch")
			return 0
		i = i + 1
	print2(label)
	println2(c": OK")
	return 1


void czi_decompress(char* dir):
	char* payload = compress_zlib_interop_payload()
	int len = strlen(payload)
	int ok = 1

	string_builder* zpath = string_new()
	string_append(zpath, dir)
	string_append(zpath, c"/py.zlib")
	int zlen = 0
	char* zdata = czi_read_file(zpath.data, &zlen)
	string_free(zpath)
	wresult[zlib_result*]* zr = zlib_decompress(zdata, zlen, 0)
	if (result_is_error[zlib_result*](zr)):
		print2(c"py.zlib decompress failed: ")
		println2(zlib_error_string(result_code[zlib_result*](zr)))
		ok = 0
	else:
		zlib_result* zo = result_value[zlib_result*](zr)
		ok = czi_check(c"py.zlib -> zlib_decompress", zo.data, zo.length, payload, len) && ok
		zlib_result_free(zo)
	result_free[zlib_result*](zr)
	free(zdata)

	string_builder* gpath = string_new()
	string_append(gpath, dir)
	string_append(gpath, c"/py.gz")
	int glen = 0
	char* gdata = czi_read_file(gpath.data, &glen)
	string_free(gpath)
	wresult[gzip_result*]* gr = gzip_decompress(gdata, glen, 0)
	if (result_is_error[gzip_result*](gr)):
		print2(c"py.gz decompress failed: ")
		println2(gzip_error_string(result_code[gzip_result*](gr)))
		ok = 0
	else:
		gzip_result* go = result_value[gzip_result*](gr)
		ok = czi_check(c"py.gz -> gzip_decompress", go.data, go.length, payload, len) && ok
		gzip_result_free(go)
	result_free[gzip_result*](gr)
	free(gdata)

	if (ok == 0):
		exit(1)


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_count() < 3):
		println2(c"usage: compress_zlib_interop <compress|decompress> <dir>")
		return 2
	char* mode = args_get(1)
	char* dir = args_get(2)
	if (strcmp(mode, c"compress") == 0):
		czi_compress(dir)
		return 0
	if (strcmp(mode, c"decompress") == 0):
		czi_decompress(dir)
		return 0
	println2(c"usage: compress_zlib_interop <compress|decompress> <dir>")
	return 2
