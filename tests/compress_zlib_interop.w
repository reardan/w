/*
zlib/gzip cross-validation against a real python3 (issue #252,
docs/projects/compress.md §8's "cross-validation without a build-time
system-zlib dependency"). Optional / manual target: NOT part of the
tests umbrella. Run it with `./wbuild compress_zlib_interop_test`.

This binary drives both directions itself (no shell runner script; ported
from the former tools/compress_zlib_interop_test.sh, mirroring
tests/openssl_tls_interop.w's shape of an argv-free harness that spawns
the real system tool via lib.process):

  1. compress: write <dir>/w.zlib and <dir>/w.gz, this package's own
     zlib_compress/gzip_compress output over
     compress_zlib_interop_payload(), plus <dir>/payload.bin (the raw
     payload bytes, so the python3 side never needs the payload
     interpolated into source text).
  2. spawn python3 -c <fixed script> <dir> (argv-only -- no /bin/sh, no
     string interpolation of the directory or payload into the script
     text): it reads payload.bin/w.zlib/w.gz, checks its stdlib zlib/gzip
     modules decode our output correctly, then writes <dir>/py.zlib and
     <dir>/py.gz with its own zlib.compress/gzip.compress.
  3. decompress: read py.zlib/py.gz back and check this package's
     zlib_decompress/gzip_decompress recovers the exact payload.

Gated on python3 being on PATH: without it, prints the same "zlib
interop OK (skipped: ...)" message the shell runner used to, and exits 0,
so the manifest entry stays safe on minimal machines (precedent:
tests/openssl_tls_interop.w, which folded its own former shell wrapper,
tools/openssl_interop_test.sh, into the harness the same way in task 4e).
*/
import lib.lib
import lib.env
import lib.process
import lib.path
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


# First PATH entry where name opens for read (mirrors tools/wexec.w's
# wexec_resolve_program: an existence check, not a strict executable-bit
# check -- accepted there too, see docs/projects/ai_tooling_next_steps.md).
# Returns a malloc'd absolute path, or 0 when name is nowhere on PATH.
char* czi_find_on_path(char* name):
	char* path = env_get(c"PATH")
	int win = os_windows()
	char path_sep = ':'
	if (win):
		path_sep = ';'
	if (path == 0):
		if (win):
			path = c"C:/Windows/System32"
		else:
			path = c"/usr/bin:/bin"
	string_builder* candidate = string_new()
	int p = 0
	int at_end = 0
	char* found = 0
	while ((at_end == 0) && (found == 0)):
		string_clear(candidate)
		while ((path[p] != path_sep) && (path[p] != 0)):
			string_append_char(candidate, path[p])
			p = p + 1
		if (path[p] == 0):
			at_end = 1
		else:
			p = p + 1
		if (candidate.length > 0):
			string_append_char(candidate, '/')
			string_append(candidate, name)
			int fd = open(candidate.data, 0, 0)
			if (fd >= 0):
				close(fd)
				found = strclone(candidate.data)
	string_free(candidate)
	return found


void czi_compress(char* dir):
	char* payload = compress_zlib_interop_payload()
	int len = strlen(payload)

	zlib_result* z = zlib_compress(payload, len, DEFLATE_LEVEL_STORED())
	char* zpath = path_join(dir, c"w.zlib")
	czi_write_file(zpath, z.data, z.length)
	free(zpath)
	zlib_result_free(z)

	gzip_result* g = gzip_compress(payload, len, DEFLATE_LEVEL_STORED())
	char* gpath = path_join(dir, c"w.gz")
	czi_write_file(gpath, g.data, g.length)
	free(gpath)
	gzip_result_free(g)

	char* payload_path = path_join(dir, c"payload.bin")
	czi_write_file(payload_path, payload, len)
	free(payload_path)


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


# Reads <dir>/py.zlib and <dir>/py.gz (written by the python3 script) and
# checks this package's zlib_decompress/gzip_decompress recover the exact
# payload. Returns 1 on success, 0 on the first mismatch or read failure
# (never exits -- the caller decides when to clean up and exit).
int czi_decompress(char* dir):
	char* payload = compress_zlib_interop_payload()
	int len = strlen(payload)
	int ok = 1

	char* zpath = path_join(dir, c"py.zlib")
	int zlen = 0
	char* zdata = czi_read_file(zpath, &zlen)
	free(zpath)
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

	char* gpath = path_join(dir, c"py.gz")
	int glen = 0
	char* gdata = czi_read_file(gpath, &glen)
	free(gpath)
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

	return ok


# Fixed python3 -c script, argv-driven (sys.argv[1] is the scratch dir) --
# no interpolation of the directory or the payload into this text, so
# there is nothing here for a directory name or payload byte to escape
# out of.
char* czi_python_script():
	string_builder* s = string_new()
	string_append(s, c"import zlib, gzip, sys\n")
	string_append(s, c"d = sys.argv[1]\n")
	string_append(s, c"with open(d + '/payload.bin', 'rb') as f:\n")
	string_append(s, c"\tpayload = f.read()\n")
	string_append(s, c"with open(d + '/w.zlib', 'rb') as f:\n")
	string_append(s, c"\tz = f.read()\n")
	string_append(s, c"with open(d + '/w.gz', 'rb') as f:\n")
	string_append(s, c"\tg = f.read()\n")
	string_append(s, c"if zlib.decompress(z) != payload:\n")
	string_append(s, c"\tsys.exit('python3 could not decode w.zlib produced by this package')\n")
	string_append(s, c"if gzip.decompress(g) != payload:\n")
	string_append(s, c"\tsys.exit('python3 could not decode w.gz produced by this package')\n")
	string_append(s, c"with open(d + '/py.zlib', 'wb') as f:\n")
	string_append(s, c"\tf.write(zlib.compress(payload, 6))\n")
	string_append(s, c"with open(d + '/py.gz', 'wb') as f:\n")
	string_append(s, c"\tf.write(gzip.compress(payload, compresslevel=6))\n")
	char* text = s.data
	free(s)
	return text


# Best-effort recursive delete via the real /bin/rm -- mirrors the
# pid-scoped scratch-dir cleanup tests/wvc_e2e_test.w already uses.
void czi_rm_rf(char* dir):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, dir)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 10000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))


int main():
	char* python3 = czi_find_on_path(c"python3")
	if (python3 == 0):
		println(c"zlib interop OK (skipped: no python3 on PATH)")
		return 0

	string_builder* dirb = string_new()
	string_append(dirb, c"bin/compress_zlib_interop_test_")
	string_append_int(dirb, getpid())
	char* dir = dirb.data
	free(dirb)

	# Best-effort cleanup from a previous failed run.
	czi_rm_rf(dir)
	if (mkdir(dir, 493) != 0):
		print2(c"cannot create scratch dir: ")
		println2(dir)
		free(python3)
		return 1

	czi_compress(dir)

	char* script = czi_python_script()
	char** argv = strv_new(4)
	strv_set(argv, 0, c"python3")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, script)
	strv_set(argv, 3, dir)
	process_result* pr = process_run(python3, argv, 0, 0, 30000)
	free(cast(void*, argv))
	free(script)
	free(python3)

	if (pr == 0):
		println2(c"python3 spawn failed")
		czi_rm_rf(dir)
		free(dir)
		return 1
	if (pr.status != 0):
		print2(c"python3 check failed: ")
		println2(pr.stderr_text)
		process_result_free(pr)
		czi_rm_rf(dir)
		free(dir)
		return 1
	process_result_free(pr)

	int ok = czi_decompress(dir)
	czi_rm_rf(dir)
	free(dir)
	if (ok == 0):
		return 1

	println(c"zlib interop OK")
	return 0
