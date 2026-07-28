/*
zlib/gzip cross-validation against a real python3 (issue #252,
docs/projects/compress.md §8's "cross-validation without a build-time
system-zlib dependency"). Optional / manual target: NOT part of the
tests umbrella. Run it with `./wbuild compress_zlib_interop_test`.

This binary drives both directions itself (no shell runner script; ported
from the former tools/compress_zlib_interop_test.sh, mirroring
tests/openssl_tls_interop.w's shape of an argv-free harness that spawns
the real system tool via lib.process):

  1. compress: for every payload in the torture set (empty, one byte,
     an all-same-byte run, a repetitive cycle, PRNG-random
     incompressible bytes, a short sentence, and a real source file
     from the tree -- compiler/tokenizer.w) and every deflate level
     (STORED/FAST/BEST, file tags _s/_f/_b), write
     <dir>/w_<name>_<tag>.zlib and .gz with this package's own
     zlib_compress/gzip_compress, plus <dir>/payload_<name>.bin (the
     raw payload bytes, so the python3 side never needs any payload
     interpolated into source text).
  2. spawn python3 -c <fixed script> <dir> (argv-only -- no /bin/sh, no
     string interpolation of the directory or payloads into the script
     text): it discovers the payload_*.bin files, checks its stdlib
     zlib/gzip modules decode every w_* file byte-exactly, then writes
     <dir>/py_<name>.zlib and .gz with its own zlib.compress/
     gzip.compress at level 6.
  3. decompress: read every py_* file back and check this package's
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
import lib.rand
import lib.file
import structures.string
import libs.extras.compress.deflate
import libs.extras.compress.zlib
import libs.extras.compress.gzip


char* compress_zlib_interop_payload():
	return c"zlib/gzip python3 interop payload, issue #252, docs/projects/compress.md"


int czi_max_payloads():
	return 8


# Fills the parallel name/data/length arrays with the torture payload
# set (each array czi_max_payloads() slots); returns how many were
# generated. The "src" payload is skipped gracefully when the harness
# is not run from the repo root (every wbuild target is, so in practice
# it is always present).
int czi_gen_payloads(char** names, char** datas, int* lens):
	int n = 0
	names[n] = c"empty"
	datas[n] = c""
	lens[n] = 0
	n = n + 1
	names[n] = c"one"
	datas[n] = c"A"
	lens[n] = 1
	n = n + 1
	names[n] = c"text"
	datas[n] = compress_zlib_interop_payload()
	lens[n] = strlen(datas[n])
	n = n + 1
	char* run = malloc(8192)
	int i = 0
	while (i < 8192):
		run[i] = 'r'
		i = i + 1
	names[n] = c"run"
	datas[n] = run
	lens[n] = 8192
	n = n + 1
	char* rep = malloc(30000)
	i = 0
	while (i < 30000):
		rep[i] = 'a' + (i % 7)
		i = i + 1
	names[n] = c"rep"
	datas[n] = rep
	lens[n] = 30000
	n = n + 1
	char* rnd = malloc(16384)
	rand_state rs
	rand_init(&rs, 20260728)
	i = 0
	while (i < 16384):
		rnd[i] = rand_next31(&rs) & 255
		i = i + 1
	names[n] = c"rand"
	datas[n] = rnd
	lens[n] = 16384
	n = n + 1
	char* src = file_read_text(c"compiler/tokenizer.w")
	if (cast(int, src) != 0):
		names[n] = c"src"
		datas[n] = src
		lens[n] = strlen(src)
		n = n + 1
	return n


int czi_level_count():
	return 3


int czi_level(int idx):
	if (idx == 0):
		return DEFLATE_LEVEL_STORED()
	if (idx == 1):
		return DEFLATE_LEVEL_FAST()
	return DEFLATE_LEVEL_BEST()


char* czi_level_tag(int idx):
	if (idx == 0):
		return c"s"
	if (idx == 1):
		return c"f"
	return c"b"


# <dir>/<prefix><name><suffix>, malloc'd.
char* czi_path3(char* dir, char* prefix, char* name, char* suffix):
	string_builder* s = string_new()
	string_append(s, dir)
	string_append(s, c"/")
	string_append(s, prefix)
	string_append(s, name)
	string_append(s, suffix)
	char* text = s.data
	free(s)
	return text


# <dir>/w_<name>_<tag><ext>, malloc'd.
char* czi_wfile_path(char* dir, char* name, char* tag, char* ext):
	string_builder* s = string_new()
	string_append(s, dir)
	string_append(s, c"/w_")
	string_append(s, name)
	string_append(s, c"_")
	string_append(s, tag)
	string_append(s, ext)
	char* text = s.data
	free(s)
	return text


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


# Writes payload_<name>.bin plus w_<name>_<tag>.zlib/.gz for every
# payload at every level.
void czi_compress(char* dir, int count, char** names, char** datas, int* lens):
	int p = 0
	while (p < count):
		char* payload_path = czi_path3(dir, c"payload_", names[p], c".bin")
		czi_write_file(payload_path, datas[p], lens[p])
		free(payload_path)
		int li = 0
		while (li < czi_level_count()):
			int level = czi_level(li)
			char* tag = czi_level_tag(li)
			zlib_result* z = zlib_compress(datas[p], lens[p], level)
			char* zpath = czi_wfile_path(dir, names[p], tag, c".zlib")
			czi_write_file(zpath, z.data, z.length)
			free(zpath)
			zlib_result_free(z)
			gzip_result* g = gzip_compress(datas[p], lens[p], level)
			char* gpath = czi_wfile_path(dir, names[p], tag, c".gz")
			czi_write_file(gpath, g.data, g.length)
			free(gpath)
			gzip_result_free(g)
			li = li + 1
		p = p + 1


int czi_check(char* kind, char* name, char* got, int got_len, char* want, int want_len):
	print2(kind)
	print2(name)
	if (got_len != want_len):
		println2(c": length mismatch")
		return 0
	int i = 0
	while (i < want_len):
		if ((got[i] & 255) != (want[i] & 255)):
			println2(c": byte mismatch")
			return 0
		i = i + 1
	println2(c": OK")
	return 1


# Reads every <dir>/py_<name>.zlib and .gz (written by the python3
# script) and checks this package's zlib_decompress/gzip_decompress
# recover the exact payload. Returns 1 on success, 0 on any mismatch or
# read failure (never exits -- the caller decides when to clean up and
# exit).
int czi_decompress(char* dir, int count, char** names, char** datas, int* lens):
	int ok = 1
	int p = 0
	while (p < count):
		char* zpath = czi_path3(dir, c"py_", names[p], c".zlib")
		int zlen = 0
		char* zdata = czi_read_file(zpath, &zlen)
		free(zpath)
		wresult[zlib_result*]* zr = zlib_decompress(zdata, zlen, 0)
		if (result_is_error[zlib_result*](zr)):
			print2(c"py zlib decompress failed: ")
			print2(names[p])
			print2(c": ")
			println2(zlib_error_string(result_code[zlib_result*](zr)))
			ok = 0
		else:
			zlib_result* zo = result_value[zlib_result*](zr)
			ok = czi_check(c"py.zlib -> zlib_decompress: ", names[p], zo.data, zo.length, datas[p], lens[p]) && ok
			zlib_result_free(zo)
		result_free[zlib_result*](zr)
		free(zdata)

		char* gpath = czi_path3(dir, c"py_", names[p], c".gz")
		int glen = 0
		char* gdata = czi_read_file(gpath, &glen)
		free(gpath)
		wresult[gzip_result*]* gr = gzip_decompress(gdata, glen, 0)
		if (result_is_error[gzip_result*](gr)):
			print2(c"py gzip decompress failed: ")
			print2(names[p])
			print2(c": ")
			println2(gzip_error_string(result_code[gzip_result*](gr)))
			ok = 0
		else:
			gzip_result* go = result_value[gzip_result*](gr)
			ok = czi_check(c"py.gz -> gzip_decompress: ", names[p], go.data, go.length, datas[p], lens[p]) && ok
			gzip_result_free(go)
		result_free[gzip_result*](gr)
		free(gdata)
		p = p + 1

	return ok


# Fixed python3 -c script, argv-driven (sys.argv[1] is the scratch dir) --
# no interpolation of the directory or the payload into this text, so
# there is nothing here for a directory name or payload byte to escape
# out of.
char* czi_python_script():
	string_builder* s = string_new()
	string_append(s, c"import zlib, gzip, sys, os\n")
	string_append(s, c"d = sys.argv[1]\n")
	string_append(s, c"names = []\n")
	string_append(s, c"for fn in sorted(os.listdir(d)):\n")
	string_append(s, c"\tif fn.startswith('payload_') and fn.endswith('.bin'):\n")
	string_append(s, c"\t\tnames.append(fn[8:-4])\n")
	string_append(s, c"if not names:\n")
	string_append(s, c"\tsys.exit('no payload_*.bin files found')\n")
	string_append(s, c"for n in names:\n")
	string_append(s, c"\twith open(d + '/payload_' + n + '.bin', 'rb') as f:\n")
	string_append(s, c"\t\tpayload = f.read()\n")
	string_append(s, c"\tfor tag in ['s', 'f', 'b']:\n")
	string_append(s, c"\t\tbase = d + '/w_' + n + '_' + tag\n")
	string_append(s, c"\t\twith open(base + '.zlib', 'rb') as f:\n")
	string_append(s, c"\t\t\tz = f.read()\n")
	string_append(s, c"\t\tif zlib.decompress(z) != payload:\n")
	string_append(s, c"\t\t\tsys.exit('python3 could not decode ' + base + '.zlib')\n")
	string_append(s, c"\t\twith open(base + '.gz', 'rb') as f:\n")
	string_append(s, c"\t\t\tg = f.read()\n")
	string_append(s, c"\t\tif gzip.decompress(g) != payload:\n")
	string_append(s, c"\t\t\tsys.exit('python3 could not decode ' + base + '.gz')\n")
	string_append(s, c"\twith open(d + '/py_' + n + '.zlib', 'wb') as f:\n")
	string_append(s, c"\t\tf.write(zlib.compress(payload, 6))\n")
	string_append(s, c"\twith open(d + '/py_' + n + '.gz', 'wb') as f:\n")
	string_append(s, c"\t\tf.write(gzip.compress(payload, compresslevel=6))\n")
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

	char** names = strv_new(czi_max_payloads())
	char** datas = strv_new(czi_max_payloads())
	int* lens = cast(int*, malloc(czi_max_payloads() * __word_size__))
	int count = czi_gen_payloads(names, datas, lens)
	czi_compress(dir, count, names, datas, lens)

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

	int ok = czi_decompress(dir, count, names, datas, lens)
	czi_rm_rf(dir)
	free(dir)
	if (ok == 0):
		return 1

	println(c"zlib interop OK")
	return 0
