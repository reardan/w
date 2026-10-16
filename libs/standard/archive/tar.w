/*
libs/standard/archive/tar.w: tar archives (POSIX ustar + pax, GNU
longname/longlink read), modelled on CPython's Lib/tarfile.py.

Reading. tar_reader_new(data, length) walks an in-memory archive; a
gzip stream (magic 1f 8b) is decompressed first via
libs/extras/compress/gzip.w, so `.tar.gz` needs no separate call.
tar_open_read(path) reads a file the same way. tar_next returns each
entry in archive order (caller-owned, free with tar_entry_free) and 0
at the end or on error; tar_reader_error tells them apart (0 = clean
end). Every header is bounds-checked and its checksum verified (the
unsigned and the historical signed sum are both accepted). Numeric
fields are octal or GNU base-256. Supported header kinds: regular file
('0', '\0', '7'), hard link ('1'), symlink ('2'), directory ('5'); char
/ block devices and FIFOs ('3' '4' '6') and unknown types come back as
TAR_KIND_OTHER (data skipped). pax extended headers ('x', and global 'g'
headers applied to every later entry) override path, linkpath, size,
mtime (fraction truncated), uid, gid, uname, gname; GNU 'L'/'K' supply
long names and link targets. A number that does not fit in a word (a
size of 2 GiB or more, or a post-2038 mtime, on 32-bit x86) is parsed
exactly and reported as TAR_ERR_TOO_LARGE rather than wrapped. An entry's
`data` points into the reader's buffer: it stays valid until
tar_reader_free.

Writing. tar_writer_new + tar_add_* / tar_writer_add, then
tar_writer_finish (bytes), tar_writer_finish_gz or tar_write_file. Headers
are ustar; a name longer than 100 bytes is split into the ustar prefix
when it can be, and otherwise (like a long link target, a uname/gname
over 32 bytes, an id over 07777777, a negative mtime or a size over
077777777777) goes into a pax 'x' header as Python's PAX_FORMAT does.
The archive ends with two zero blocks, padded to a 10240-byte record.

Extraction. tar_extract_all_safe(archive, dest) follows Python's
filter='data' policy, stricter where noted: it refuses absolute member
names and any `..` component (Python strips a leading '/' instead),
symlinks with an absolute target or one that resolves outside dest
(path_is_within), a symlink target with `..` after a normal component
(a symlink earlier in the target could make `..` climb elsewhere), hard
links to anything but another in-archive path, writes through a symlink
in an entry's parent directories, and devices/FIFOs/unknown types. Every
member is checked before anything is written, so a lexically unsafe
archive writes nothing. Modes are filtered as Python does (no setuid/
setgid/sticky, no group/other write, owner rw always; directory modes
ignored); ownership is never applied; file and directory mtimes are set.
dest is created when missing; pre-existing symlinks inside dest are
trusted, so extract into a fresh directory.

Error codes are TAR_ERR_* (301-310); gzip failures pass their own codes
(GZIP_ERR_* 201-206, INFLATE_ERR_* 1-6) through unchanged.
tar_error_string covers all of them.
*/
import lib.lib
import lib.mem
import lib.io
import lib.file
import lib.container
import lib.path
import lib.stat
import lib.stream
import lib.__arch__.hardlink
import structures.string
import libs.extras.compress.gzip


const int TAR_ERR_TRUNCATED = 301
const int TAR_ERR_BAD_CHECKSUM = 302
const int TAR_ERR_BAD_HEADER = 303
const int TAR_ERR_BAD_PAX = 304
const int TAR_ERR_TOO_LARGE = 305
const int TAR_ERR_IO = 306
const int TAR_ERR_UNSAFE_PATH = 307
const int TAR_ERR_UNSAFE_LINK = 308
const int TAR_ERR_SPECIAL_FILE = 309
const int TAR_ERR_INVALID_ARG = 310

const int TAR_KIND_FILE = 0
const int TAR_KIND_DIR = 1
const int TAR_KIND_SYMLINK = 2
const int TAR_KIND_HARDLINK = 3
const int TAR_KIND_OTHER = 4

const int TAR_BLOCK = 512
const int TAR_RECORD = 10240


char* tar_error_string(int code):
	if (code == 0): return c"tar: ok"
	if (code == TAR_ERR_TRUNCATED): return c"tar: truncated archive"
	if (code == TAR_ERR_BAD_CHECKSUM): return c"tar: header checksum mismatch"
	if (code == TAR_ERR_BAD_HEADER): return c"tar: invalid header field"
	if (code == TAR_ERR_BAD_PAX): return c"tar: malformed pax extended header"
	if (code == TAR_ERR_TOO_LARGE): return c"tar: numeric field too large for this platform"
	if (code == TAR_ERR_IO): return c"tar: file system operation failed"
	if (code == TAR_ERR_UNSAFE_PATH): return c"tar: member path is absolute or contains '..'"
	if (code == TAR_ERR_UNSAFE_LINK): return c"tar: link points outside the destination"
	if (code == TAR_ERR_SPECIAL_FILE): return c"tar: refusing to extract a special file"
	if (code == TAR_ERR_INVALID_ARG): return c"tar: invalid entry"
	return gzip_error_string(code)


struct tar_entry:
	char* name       # owned; directories carry no trailing '/'
	char* linkname   # owned; "" unless a link
	int kind         # TAR_KIND_*
	int typeflag     # the raw header type byte
	int mode
	int uid
	int gid
	int mtime        # seconds since the epoch (may be negative)
	int size
	char* uname      # owned
	char* gname      # owned
	char* data       # borrowed: size bytes of a regular file, else 0


int tar_default_mode(int kind):
	if (kind == TAR_KIND_DIR): return 493      # 0755
	if (kind == TAR_KIND_SYMLINK): return 511  # 0777
	return 420                                # 0644


int tar_kind_typeflag(int kind):
	if (kind == TAR_KIND_DIR): return '5'
	if (kind == TAR_KIND_SYMLINK): return '2'
	if (kind == TAR_KIND_HARDLINK): return '1'
	return '0'


# A fresh entry: name cloned, default mode for the kind, everything else
# zero/empty. Free with tar_entry_free.
tar_entry* tar_entry_new(char* name, int kind):
	tar_entry* e = new tar_entry
	e.name = strclone(name)
	e.linkname = strclone(c"")
	e.kind = kind
	e.typeflag = tar_kind_typeflag(kind)
	e.mode = tar_default_mode(kind)
	e.uid = 0
	e.gid = 0
	e.mtime = 0
	e.size = 0
	e.uname = strclone(c"")
	e.gname = strclone(c"")
	e.data = 0
	return e


void tar_entry_set_string(char** slot, char* value):
	free(*slot)
	*slot = strclone(value)


void tar_entry_free(tar_entry* e):
	if (e == 0): return
	free(e.name)
	free(e.linkname)
	free(e.uname)
	free(e.gname)
	free(e)


# ---------------------------------------------------------------------------
# Numbers


int tar_word_max():
	int m = 1 << (__word_size__ * 8 - 1)
	return m - 1


int tar_word_min():
	return 1 << (__word_size__ * 8 - 1)


# 8^digits - 1, or the word maximum when that does not fit.
int tar_octal_limit(int digits):
	int limit = 1
	int max = tar_word_max()
	int i = 0
	while (i < digits):
		if (limit > max / 8): return max
		limit = limit * 8
		i = i + 1
	return limit - 1


# A NUL-terminated copy of the first width bytes, stopping at a NUL.
char* tar_nts(char* field, int width):
	int n = 0
	while ((n < width) && (field[n] != 0)): n = n + 1
	char* s = cast(char*, malloc(n + 1))
	mem_copy(s, field, n)
	s[n] = 0
	return s


# A header number: GNU base-256 (first byte 0x80 positive, 0xff
# negative) or octal digits, optionally space-padded and NUL/space
# terminated; an empty field is 0. Returns 0, TAR_ERR_BAD_HEADER or
# TAR_ERR_TOO_LARGE (the value does not fit in a word).
int tar_parse_number(char* field, int width, int* out):
	*out = 0
	int first = field[0] & 255
	int max = tar_word_max()
	int v = 0
	int i = 0
	if ((first == 128) || (first == 255)):
		if (first == 255): v = -1
		int min = tar_word_min()
		i = 1
		while (i < width):
			int b = field[i] & 255
			if (v >= 0):
				if (v > (max - b) / 256): return TAR_ERR_TOO_LARGE
			else if (v < min / 256): return TAR_ERR_TOO_LARGE
			v = v * 256 + b
			i = i + 1
		*out = v
		return 0
	int end = 0
	while ((end < width) && (field[end] != 0)): end = end + 1
	while ((i < end) && (field[i] == ' ')): i = i + 1
	while ((end > i) && (field[end - 1] == ' ')): end = end - 1
	while (i < end):
		int d = (field[i] & 255) - '0'
		if ((d < 0) || (d > 7)): return TAR_ERR_BAD_HEADER
		if (v > (max - d) / 8): return TAR_ERR_TOO_LARGE
		v = v * 8 + d
		i = i + 1
	*out = v
	return 0


# Decimal digits of a pax value; allow_signed_fraction accepts a leading
# '-' and a '.fraction' tail (truncated), as pax mtime values use.
int tar_parse_decimal(char* s, int length, int allow_signed_fraction, int* out):
	*out = 0
	int i = 0
	int negative = 0
	if (allow_signed_fraction && (length > 0) && (s[0] == '-')):
		negative = 1
		i = 1
	int digits = 0
	int v = 0
	int max = tar_word_max()
	while ((i < length) && (s[i] >= '0') && (s[i] <= '9')):
		int d = s[i] - '0'
		if (v > (max - d) / 10): return TAR_ERR_TOO_LARGE
		v = v * 10 + d
		digits = digits + 1
		i = i + 1
	if (digits == 0): return TAR_ERR_BAD_PAX
	if (allow_signed_fraction && (i < length) && (s[i] == '.')):
		i = i + 1
		while ((i < length) && (s[i] >= '0') && (s[i] <= '9')): i = i + 1
	if (i != length): return TAR_ERR_BAD_PAX
	if (negative): v = 0 - v
	*out = v
	return 0


# ---------------------------------------------------------------------------
# pax extended headers


struct tar_pax:
	char* path
	char* linkpath
	char* uname
	char* gname
	int has_size
	int size
	int has_mtime
	int mtime
	int has_uid
	int uid
	int has_gid
	int gid


void tar_pax_clear(tar_pax* p):
	free(p.path)
	free(p.linkpath)
	free(p.uname)
	free(p.gname)
	p.path = 0
	p.linkpath = 0
	p.uname = 0
	p.gname = 0
	p.has_size = 0
	p.size = 0
	p.has_mtime = 0
	p.mtime = 0
	p.has_uid = 0
	p.uid = 0
	p.has_gid = 0
	p.gid = 0


tar_pax* tar_pax_new():
	tar_pax* p = new tar_pax
	p.path = 0
	p.linkpath = 0
	p.uname = 0
	p.gname = 0
	tar_pax_clear(p)
	return p


void tar_pax_free(tar_pax* p):
	tar_pax_clear(p)
	free(p)


int tar_key_is(char* key, int length, char* name):
	if (strlen(name) != length): return 0
	return mem_eq(key, name, length)


# Sets *slot to a copy of value, or clears it for an empty value (pax
# deletes a keyword that way).
void tar_pax_set_text(char** slot, char* value, int length):
	free(*slot)
	*slot = 0
	if (length > 0):
		char* s = cast(char*, malloc(length + 1))
		mem_copy(s, value, length)
		s[length] = 0
		*slot = s


int tar_pax_set_number(int* has, int* slot, char* value, int length, int allow_signed_fraction):
	*has = 0
	if (length == 0): return 0
	int status = tar_parse_decimal(value, length, allow_signed_fraction, slot)
	if (status != 0): return status
	*has = 1
	return 0


int tar_pax_apply(tar_pax* p, char* key, int key_length, char* value, int length):
	if (tar_key_is(key, key_length, c"path")): tar_pax_set_text(&p.path, value, length)
	else if (tar_key_is(key, key_length, c"linkpath")): tar_pax_set_text(&p.linkpath, value, length)
	else if (tar_key_is(key, key_length, c"uname")): tar_pax_set_text(&p.uname, value, length)
	else if (tar_key_is(key, key_length, c"gname")): tar_pax_set_text(&p.gname, value, length)
	else if (tar_key_is(key, key_length, c"size")): return tar_pax_set_number(&p.has_size, &p.size, value, length, 0)
	else if (tar_key_is(key, key_length, c"mtime")): return tar_pax_set_number(&p.has_mtime, &p.mtime, value, length, 1)
	else if (tar_key_is(key, key_length, c"uid")): return tar_pax_set_number(&p.has_uid, &p.uid, value, length, 0)
	else if (tar_key_is(key, key_length, c"gid")): return tar_pax_set_number(&p.has_gid, &p.gid, value, length, 0)
	return 0


# Records are "LEN KEY=VALUE\n" with LEN counting the whole record; a
# NUL ends the list early (as tarfile.py allows).
int tar_pax_parse(tar_pax* p, char* data, int length):
	int pos = 0
	while ((pos < length) && (data[pos] != 0)):
		int start = pos
		int n = 0
		int digits = 0
		while ((pos < length) && (data[pos] >= '0') && (data[pos] <= '9')):
			n = n * 10 + (data[pos] - '0')
			if (n > length): return TAR_ERR_BAD_PAX
			digits = digits + 1
			pos = pos + 1
		if ((digits == 0) || (pos >= length) || (data[pos] != ' ')): return TAR_ERR_BAD_PAX
		int end = start + n
		if ((n < digits + 4) || (end > length)): return TAR_ERR_BAD_PAX
		if (data[end - 1] != '\n'): return TAR_ERR_BAD_PAX
		int key = pos + 1
		int eq = key
		while ((eq < end - 1) && (data[eq] != '=')): eq = eq + 1
		if ((eq >= end - 1) || (eq == key)): return TAR_ERR_BAD_PAX
		int status = tar_pax_apply(p, data + key, eq - key, data + eq + 1, end - 1 - (eq + 1))
		if (status != 0): return status
		pos = end
	return 0


# ---------------------------------------------------------------------------
# Reader


struct tar_reader:
	char* data
	int length
	int owns_data
	int pos
	int error
	int done
	tar_pax* global_pax


tar_reader* tar_reader_alloc():
	tar_reader* r = new tar_reader
	r.data = 0
	r.length = 0
	r.owns_data = 0
	r.pos = 0
	r.error = 0
	r.done = 0
	r.global_pax = tar_pax_new()
	return r


# Borrows data (keep it alive until tar_reader_free) unless it is gzip,
# which is decompressed into a buffer the reader owns. A gzip failure is
# reported by tar_reader_error, and tar_next then returns 0.
tar_reader* tar_reader_new(char* data, int length):
	tar_reader* r = tar_reader_alloc()
	if ((length >= 2) && ((data[0] & 255) == 0x1f) && ((data[1] & 255) == 0x8b)):
		wresult[gzip_result*]* res = gzip_decompress(data, length, 0)
		if (result_is_error[gzip_result*](res)):
			r.error = result_code[gzip_result*](res)
		else:
			gzip_result* g = result_value[gzip_result*](res)
			r.data = g.data
			r.length = g.length
			r.owns_data = 1
			free(g)
		result_free[gzip_result*](res)
		return r
	r.data = data
	r.length = length
	if (length < 0): r.error = TAR_ERR_INVALID_ARG
	return r


# Reads the whole file at path into *out (malloc'd) / *length.
# Returns 0 or TAR_ERR_IO.
int tar_read_file(char* path, char** out, int* length):
	*out = 0
	*length = 0
	wstream* in = stream_open_read(path)
	if (in == 0): return TAR_ERR_IO
	string_builder* contents = string_new()
	io_result r
	int status = stream_read_all_checked(in, contents, &r)
	stream_close(in)
	if (status != IO_OK):
		string_free(contents)
		return TAR_ERR_IO
	*out = contents.data
	*length = contents.length
	free(contents)
	return 0


# Opens a .tar or .tar.gz file. Always returns a reader; an unreadable
# file or bad gzip stream shows up as tar_reader_error.
tar_reader* tar_open_read(char* path):
	char* data = 0
	int length = 0
	int status = tar_read_file(path, &data, &length)
	if (status != 0):
		tar_reader* failed = tar_reader_alloc()
		failed.error = status
		return failed
	tar_reader* r = tar_reader_new(data, length)
	if (r.owns_data): free(data)
	else:
		r.owns_data = 1
		if (r.error != 0): free(data)
	return r


int tar_reader_error(tar_reader* r):
	return r.error


void tar_reader_free(tar_reader* r):
	if (r == 0): return
	if (r.owns_data && (r.data != 0)): free(r.data)
	tar_pax_free(r.global_pax)
	free(r)


int tar_block_is_zero(char* h):
	int i = 0
	while (i < TAR_BLOCK):
		if (h[i] != 0): return 0
		i = i + 1
	return 1


int tar_checksum_ok(char* h):
	int stored = 0
	if (tar_parse_number(h + 148, 8, &stored) != 0): return 0
	int unsigned_sum = 0
	int signed_sum = 0
	int i = 0
	while (i < TAR_BLOCK):
		int b = h[i] & 255
		if ((i >= 148) && (i < 156)): b = ' '
		unsigned_sum = unsigned_sum + b
		if (b >= 128): signed_sum = signed_sum + b - 256
		else: signed_sum = signed_sum + b
		i = i + 1
	return (stored == unsigned_sum) || (stored == signed_sum)


# Rounds a non-negative size up to whole blocks.
int tar_padded(int size):
	int rem = size % TAR_BLOCK
	if (rem == 0): return size
	return size + (TAR_BLOCK - rem)


int tar_fail(tar_reader* r, int code):
	r.error = code
	r.done = 1
	return code


char* tar_join_prefix(char* prefix, char* name):
	if (prefix[0] == 0): return strclone(name)
	string_builder* b = string_new()
	string_append(b, prefix)
	string_append_char(b, '/')
	string_append(b, name)
	char* s = b.data
	free(b)
	return s


# The value for a header string: local pax, then global pax, then a GNU
# long record, then the header's own text (taken, so not freed here).
char* tar_pick(char* local, char* global, char* gnu_long, char* header):
	if (local != 0):
		free(header)
		return strclone(local)
	if (global != 0):
		free(header)
		return strclone(global)
	if (gnu_long != 0):
		free(header)
		return strclone(gnu_long)
	return header


int tar_pick_number(int has_local, int local, int has_global, int global, int header):
	if (has_local): return local
	if (has_global): return global
	return header


# Builds the entry for the header block at r.pos (no meta types).
int tar_build_entry(tar_reader* r, char* h, int size, tar_pax* local, char* longname, char* longlink, tar_entry** out):
	*out = 0
	int mode = 0
	int uid = 0
	int gid = 0
	int mtime = 0
	int status = tar_parse_number(h + 100, 8, &mode)
	if (status == 0): status = tar_parse_number(h + 108, 8, &uid)
	if (status == 0): status = tar_parse_number(h + 116, 8, &gid)
	if (status == 0): status = tar_parse_number(h + 136, 12, &mtime)
	if (status != 0): return status
	tar_pax* g = r.global_pax
	int posix = mem_eq(h + 257, c"ustar", 6)
	int any_ustar = mem_eq(h + 257, c"ustar", 5)

	char* raw_name = tar_nts(h, 100)
	if (posix):
		char* prefix = tar_nts(h + 345, 155)
		char* joined = tar_join_prefix(prefix, raw_name)
		free(prefix)
		free(raw_name)
		raw_name = joined
	tar_entry* e = new tar_entry
	e.name = tar_pick(local.path, g.path, longname, raw_name)
	e.linkname = tar_pick(local.linkpath, g.linkpath, longlink, tar_nts(h + 157, 100))
	char* uname = strclone(c"")
	char* gname = strclone(c"")
	if (any_ustar):
		free(uname)
		free(gname)
		uname = tar_nts(h + 265, 32)
		gname = tar_nts(h + 297, 32)
	e.uname = tar_pick(local.uname, g.uname, 0, uname)
	e.gname = tar_pick(local.gname, g.gname, 0, gname)
	e.mode = mode & 4095
	e.uid = tar_pick_number(local.has_uid, local.uid, g.has_uid, g.uid, uid)
	e.gid = tar_pick_number(local.has_gid, local.gid, g.has_gid, g.gid, gid)
	e.mtime = tar_pick_number(local.has_mtime, local.mtime, g.has_mtime, g.mtime, mtime)
	e.size = size
	e.data = 0
	int t = h[156] & 255
	e.typeflag = t
	int skips_data = 1
	if ((t == '0') || (t == 0) || (t == '7')): e.kind = TAR_KIND_FILE
	else if (t == '1'): e.kind = TAR_KIND_HARDLINK
	else if (t == '2'): e.kind = TAR_KIND_SYMLINK
	else if (t == '5'): e.kind = TAR_KIND_DIR
	else: e.kind = TAR_KIND_OTHER
	if ((e.kind == TAR_KIND_HARDLINK) || (e.kind == TAR_KIND_SYMLINK) || (e.kind == TAR_KIND_DIR) || (t == '3') || (t == '4') || (t == '6')):
		skips_data = 0
	# Old V7 archives mark directories with a regular type and a '/'.
	int name_length = strlen(e.name)
	if ((t == 0) && (name_length > 0) && (e.name[name_length - 1] == '/')): e.kind = TAR_KIND_DIR
	if (e.kind == TAR_KIND_DIR):
		while ((name_length > 1) && (e.name[name_length - 1] == '/')):
			name_length = name_length - 1
			e.name[name_length] = 0
	int data_start = r.pos + TAR_BLOCK
	if (skips_data):
		if (size > r.length - data_start):
			tar_entry_free(e)
			return TAR_ERR_TRUNCATED
		if (e.kind == TAR_KIND_FILE): e.data = r.data + data_start
		r.pos = data_start + tar_padded(size)
	else: r.pos = data_start
	*out = e
	return 0


# The next entry (caller-owned; free with tar_entry_free), or 0 at the
# end of the archive or on error (see tar_reader_error).
tar_entry* tar_next(tar_reader* r):
	if ((r.error != 0) || r.done): return 0
	tar_pax* local = tar_pax_new()
	char* longname = 0
	char* longlink = 0
	int pending = 0
	tar_entry* result = 0
	while (result == 0):
		if (r.pos >= r.length):
			if (pending): tar_fail(r, TAR_ERR_TRUNCATED)
			r.done = 1
			break
		if (r.pos + TAR_BLOCK > r.length):
			tar_fail(r, TAR_ERR_TRUNCATED)
			break
		char* h = r.data + r.pos
		if (tar_block_is_zero(h)):
			if (pending): tar_fail(r, TAR_ERR_TRUNCATED)
			r.done = 1
			break
		if (tar_checksum_ok(h) == 0):
			tar_fail(r, TAR_ERR_BAD_CHECKSUM)
			break
		int size = 0
		int status = tar_parse_number(h + 124, 12, &size)
		if ((status == 0) && (size < 0)): status = TAR_ERR_BAD_HEADER
		int t = h[156] & 255
		int is_meta = (t == 'x') || (t == 'g') || (t == 'L') || (t == 'K')
		if ((status == 0) && (is_meta == 0) && local.has_size): size = local.size
		else if ((status == 0) && (is_meta == 0) && r.global_pax.has_size): size = r.global_pax.size
		if (status != 0):
			tar_fail(r, status)
			break
		if (is_meta):
			int data_start = r.pos + TAR_BLOCK
			if (size > r.length - data_start):
				tar_fail(r, TAR_ERR_TRUNCATED)
				break
			char* body = r.data + data_start
			if (t == 'x'): status = tar_pax_parse(local, body, size)
			else if (t == 'g'): status = tar_pax_parse(r.global_pax, body, size)
			else if (t == 'L'):
				free(longname)
				longname = tar_nts(body, size)
			else:
				free(longlink)
				longlink = tar_nts(body, size)
			if (status != 0):
				tar_fail(r, status)
				break
			if (t != 'g'): pending = 1
			r.pos = data_start + tar_padded(size)
		else:
			status = tar_build_entry(r, h, size, local, longname, longlink, &result)
			if (status != 0):
				tar_fail(r, status)
				break
	tar_pax_free(local)
	free(longname)
	free(longlink)
	return result


# ---------------------------------------------------------------------------
# Writer


struct tar_writer:
	string_builder* out
	int error


tar_writer* tar_writer_new():
	tar_writer* w = new tar_writer
	w.out = string_new()
	w.error = 0
	return w


void tar_writer_free(tar_writer* w):
	if (w == 0): return
	string_free(w.out)
	free(w)


void tar_put_bytes(char* h, int offset, char* text, int width):
	int n = strlen(text)
	if (n > width): n = width
	mem_copy(h + offset, text, n)


# width - 1 zero-padded octal digits and a NUL; v must fit.
void tar_put_octal(char* h, int offset, int width, int v):
	int i = width - 2
	while (i >= 0):
		h[offset + i] = '0' + (v % 8)
		v = v / 8
		i = i - 1
	h[offset + width - 1] = 0


void tar_append_decimal(string_builder* b, int v):
	char* s = itoa(v)
	string_append(b, s)
	free(s)


int tar_decimal_digits(int v):
	int n = 1
	while (v >= 10):
		v = v / 10
		n = n + 1
	return n


# One "LEN key=value\n" record; LEN counts its own digits.
void tar_pax_record(string_builder* b, char* key, char* value, int value_length):
	int payload = 1 + strlen(key) + 1 + value_length + 1
	int total = payload + 1
	while (payload + tar_decimal_digits(total) != total): total = payload + tar_decimal_digits(total)
	tar_append_decimal(b, total)
	string_append_char(b, ' ')
	string_append(b, key)
	string_append_char(b, '=')
	string_append_bytes(b, value, value_length)
	string_append_char(b, '\n')


void tar_pax_number(string_builder* b, char* key, int v):
	char* s = itoa(v)
	tar_pax_record(b, key, s, strlen(s))
	free(s)


void tar_finish_header(char* h):
	int i = 148
	while (i < 156):
		h[i] = ' '
		i = i + 1
	int sum = 0
	i = 0
	while (i < TAR_BLOCK):
		sum = sum + (h[i] & 255)
		i = i + 1
	tar_put_octal(h, 148, 7, sum)


# A ustar header with the given name/size/type; the numeric fields not
# given are zero.
char* tar_new_header(char* name, int typeflag, int mode, int size, int mtime):
	char* h = cast(char*, malloc(TAR_BLOCK))
	mem_fill(h, 0, TAR_BLOCK)
	tar_put_bytes(h, 0, name, 100)
	tar_put_octal(h, 100, 8, mode)
	tar_put_octal(h, 108, 8, 0)
	tar_put_octal(h, 116, 8, 0)
	tar_put_octal(h, 124, 12, size)
	tar_put_octal(h, 136, 12, mtime)
	h[156] = typeflag
	mem_copy(h + 257, c"ustar", 6)
	h[263] = '0'
	h[264] = '0'
	tar_put_octal(h, 329, 8, 0)
	tar_put_octal(h, 337, 8, 0)
	return h


void tar_append_padded(string_builder* b, char* data, int length):
	if (length > 0): string_append_bytes(b, data, length)
	int pad = tar_padded(length) - length
	while (pad > 0):
		string_append_char(b, 0)
		pad = pad - 1


# Python's _posix_split_name: the longest prefix of at most 155 bytes
# ending before a '/', leaving a non-empty name of at most 100 bytes.
# Returns the split index (the '/'), or -1.
int tar_split_name(char* name):
	int n = strlen(name)
	int i = n - 1
	if (i > 155): i = 155
	while (i > 0):
		if ((name[i] == '/') && (n - i - 1 <= 100) && (n - i - 1 > 0)): return i
		i = i - 1
	return -1


# Appends one member. Uses name, linkname, kind, mode, uid, gid, mtime,
# uname, gname, and for a regular file size + data. Returns 0 or
# TAR_ERR_INVALID_ARG (the writer is left unchanged).
int tar_writer_add(tar_writer* w, tar_entry* e):
	if ((e.name == 0) || (e.name[0] == 0)): return TAR_ERR_INVALID_ARG
	if ((e.kind < TAR_KIND_FILE) || (e.kind > TAR_KIND_HARDLINK)): return TAR_ERR_INVALID_ARG
	int size = 0
	if (e.kind == TAR_KIND_FILE):
		size = e.size
		if ((size < 0) || ((size > 0) && (e.data == 0))): return TAR_ERR_INVALID_ARG
	char* linkname = e.linkname
	if (linkname == 0): linkname = c""
	if (((e.kind == TAR_KIND_SYMLINK) || (e.kind == TAR_KIND_HARDLINK)) && (linkname[0] == 0)): return TAR_ERR_INVALID_ARG
	char* uname = e.uname
	if (uname == 0): uname = c""
	char* gname = e.gname
	if (gname == 0): gname = c""

	char* name = strclone(e.name)
	int name_length = strlen(name)
	if ((e.kind == TAR_KIND_DIR) && (name[name_length - 1] != '/')):
		char* slashed = tar_join_prefix(name, c"")
		free(name)
		name = slashed
		name_length = name_length + 1

	string_builder* pax = string_new()
	int id_limit = tar_octal_limit(7)
	int big_limit = tar_octal_limit(11)
	char* h = tar_new_header(c"", tar_kind_typeflag(e.kind), e.mode & 4095, 0, 0)
	if (name_length <= 100): tar_put_bytes(h, 0, name, 100)
	else:
		int split = tar_split_name(name)
		if (split > 0):
			mem_copy(h + 345, name, split)
			tar_put_bytes(h, 0, name + split + 1, 100)
		else:
			tar_pax_record(pax, c"path", name, name_length)
			tar_put_bytes(h, 0, name, 100)
	int link_length = strlen(linkname)
	if (link_length > 100): tar_pax_record(pax, c"linkpath", linkname, link_length)
	tar_put_bytes(h, 157, linkname, 100)
	if ((e.uid >= 0) && (e.uid <= id_limit)): tar_put_octal(h, 108, 8, e.uid)
	else: tar_pax_number(pax, c"uid", e.uid)
	if ((e.gid >= 0) && (e.gid <= id_limit)): tar_put_octal(h, 116, 8, e.gid)
	else: tar_pax_number(pax, c"gid", e.gid)
	if (size <= big_limit): tar_put_octal(h, 124, 12, size)
	else: tar_pax_number(pax, c"size", size)
	if ((e.mtime >= 0) && (e.mtime <= big_limit)): tar_put_octal(h, 136, 12, e.mtime)
	else: tar_pax_number(pax, c"mtime", e.mtime)
	if (strlen(uname) > 32): tar_pax_record(pax, c"uname", uname, strlen(uname))
	tar_put_bytes(h, 265, uname, 32)
	if (strlen(gname) > 32): tar_pax_record(pax, c"gname", gname, strlen(gname))
	tar_put_bytes(h, 297, gname, 32)
	tar_finish_header(h)

	if (pax.length > 0):
		char* ph = tar_new_header(c"././@PaxHeader", 'x', 420, pax.length, 0)
		tar_finish_header(ph)
		string_append_bytes(w.out, ph, TAR_BLOCK)
		tar_append_padded(w.out, pax.data, pax.length)
		free(ph)
	string_append_bytes(w.out, h, TAR_BLOCK)
	if (e.kind == TAR_KIND_FILE): tar_append_padded(w.out, e.data, size)
	free(h)
	string_free(pax)
	free(name)
	return 0


int tar_add_simple(tar_writer* w, char* name, int kind, char* linkname, char* data, int length, int mode, int mtime):
	tar_entry* e = tar_entry_new(name, kind)
	if (linkname != 0): tar_entry_set_string(&e.linkname, linkname)
	if (mode >= 0): e.mode = mode
	e.mtime = mtime
	e.size = length
	e.data = data
	int status = tar_writer_add(w, e)
	tar_entry_free(e)
	return status


# Convenience adders; mode < 0 picks the kind's default (0644 / 0755).
int tar_add_file(tar_writer* w, char* name, char* data, int length, int mode, int mtime):
	return tar_add_simple(w, name, TAR_KIND_FILE, 0, data, length, mode, mtime)


int tar_add_dir(tar_writer* w, char* name, int mode, int mtime):
	return tar_add_simple(w, name, TAR_KIND_DIR, 0, 0, 0, mode, mtime)


int tar_add_symlink(tar_writer* w, char* name, char* target, int mtime):
	return tar_add_simple(w, name, TAR_KIND_SYMLINK, target, 0, 0, -1, mtime)


# target is another member's archive path.
int tar_add_hardlink(tar_writer* w, char* name, char* target, int mtime):
	return tar_add_simple(w, name, TAR_KIND_HARDLINK, target, 0, 0, -1, mtime)


# Ends the archive (two zero blocks, padded to a 10240-byte record),
# frees the writer and returns the malloc'd archive bytes.
char* tar_writer_finish(tar_writer* w, int* length):
	string_builder* out = w.out
	int total = out.length + 2 * TAR_BLOCK
	int rem = total % TAR_RECORD
	if (rem != 0): total = total + (TAR_RECORD - rem)
	while (out.length < total): string_append_char(out, 0)
	char* data = out.data
	*length = out.length
	free(out)
	free(w)
	return data


# Like tar_writer_finish, gzip-compressed at the given DEFLATE_LEVEL_*.
char* tar_writer_finish_gz(tar_writer* w, int level, int* length):
	int raw_length = 0
	char* raw = tar_writer_finish(w, &raw_length)
	gzip_result* g = gzip_compress(raw, raw_length, level)
	free(raw)
	char* data = g.data
	*length = g.length
	free(g)
	return data


# Finishes the writer (freeing it) and writes the archive to path,
# gzip-compressed when gz is set. Returns 0 or TAR_ERR_IO.
int tar_write_file(tar_writer* w, char* path, int gz):
	int length = 0
	char* data = 0
	if (gz): data = tar_writer_finish_gz(w, DEFLATE_LEVEL_BEST(), &length)
	else: data = tar_writer_finish(w, &length)
	io_result r
	int status = file_write_text_checked(path, data, length, &r)
	free(data)
	if (status != IO_OK): return TAR_ERR_IO
	return 0


# ---------------------------------------------------------------------------
# Safe extraction


const int TAR_ENOENT = -2


# A relative member path with no '..' component (and not empty).
int tar_member_name_safe(char* name):
	if ((name == 0) || (name[0] == 0) || (name[0] == '/')): return 0
	int i = 0
	while (name[i] != 0):
		int start = i
		while ((name[i] != 0) && (name[i] != '/')): i = i + 1
		if ((i - start == 2) && (name[start] == '.') && (name[start + 1] == '.')): return 0
		if (name[i] == '/'): i = i + 1
	return 1


# A symlink target, relative to the link's directory, that stays inside
# the extraction root: not absolute, '..' only as leading components,
# and lexically within the root (path_is_within on ".").
int tar_symlink_target_safe(char* name, char* target):
	if ((target == 0) || (target[0] == 0) || (target[0] == '/')): return 0
	int seen_normal = 0
	int i = 0
	while (target[i] != 0):
		int start = i
		while ((target[i] != 0) && (target[i] != '/')): i = i + 1
		int length = i - start
		int dotdot = (length == 2) && (target[start] == '.') && (target[start + 1] == '.')
		int dot = (length == 1) && (target[start] == '.')
		if (dotdot && seen_normal): return 0
		if ((dotdot == 0) && (dot == 0) && (length > 0)): seen_normal = 1
		if (target[i] == '/'): i = i + 1
	char* dir = path_dirname(name)
	char* resolved = path_join(dir, target)
	int inside = path_is_within(c".", resolved)
	free(dir)
	free(resolved)
	return inside


int tar_check_member(tar_entry* e):
	if (tar_member_name_safe(e.name) == 0): return TAR_ERR_UNSAFE_PATH
	if (e.kind == TAR_KIND_OTHER): return TAR_ERR_SPECIAL_FILE
	if (e.kind == TAR_KIND_SYMLINK):
		if (tar_symlink_target_safe(e.name, e.linkname) == 0): return TAR_ERR_UNSAFE_LINK
	if (e.kind == TAR_KIND_HARDLINK):
		if (tar_member_name_safe(e.linkname) == 0): return TAR_ERR_UNSAFE_LINK
	return 0


# Python's data filter: drop setuid/setgid/sticky and group/other write;
# owner read/write always; no execute bits unless the owner has one.
int tar_filter_mode(int mode):
	int m = mode & 493
	if ((m & 64) == 0): m = m & (4095 - 73)
	return m | 384


# lstat kind of path: 0 missing, 1 directory, 2 symlink, 3 other, -1 error.
int tar_path_kind(char* path):
	file_stat st
	int err = file_lstat_path(path, &st)
	if ((err == TAR_ENOENT) || (err == -20)): return 0
	if (err != 0): return -1
	if (file_is_dir(&st)): return 1
	if (file_is_lnk(&st)): return 2
	return 3


# Creates the parent directories of rel under dest, refusing to pass
# through a symlink.
int tar_make_parents(char* dest, char* rel):
	int i = 0
	int status = 0
	while ((status == 0) && (rel[i] != 0)):
		while ((rel[i] != 0) && (rel[i] != '/')): i = i + 1
		if (rel[i] == 0): break
		char* prefix = cast(char*, malloc(i + 1))
		mem_copy(prefix, rel, i)
		prefix[i] = 0
		char* full = path_join(dest, prefix)
		int kind = tar_path_kind(full)
		if (kind == 0):
			if ((mkdir(full, 511) != 0) && (tar_path_kind(full) != 1)): status = TAR_ERR_IO
		else if (kind == 2): status = TAR_ERR_UNSAFE_LINK
		else if (kind != 1): status = TAR_ERR_IO
		free(full)
		free(prefix)
		while (rel[i] == '/'): i = i + 1
	return status


# Removes a non-directory at full so a new member can take its place.
int tar_clear_target(char* full):
	int kind = tar_path_kind(full)
	if (kind == 0): return 0
	if ((kind == 1) || (kind < 0)): return TAR_ERR_IO
	if (unlink(full) != 0): return TAR_ERR_IO
	return 0


int tar_write_member_file(char* full, char* data, int length, int mode):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 384 = 0600 until chmod below.
	int fd = open(full, 577, 384)
	if (fd < 0): return TAR_ERR_IO
	io_result r
	io_result closed
	int status = io_write_all(fd, data, length, &r)
	io_close(fd, &closed)
	if ((status != IO_OK) || (closed.status != IO_OK)): return TAR_ERR_IO
	if (chmod(full, mode) != 0): return TAR_ERR_IO
	return 0


int tar_extract_hardlink(char* dest, char* full, tar_entry* e):
	char* source = path_join(dest, e.linkname)
	int status = 0
	file_stat st
	if ((file_lstat_path(source, &st) != 0) || file_is_dir(&st)): status = TAR_ERR_IO
	if ((status == 0) && (shell_hardlink(source, full) != 0)):
		# No link(2) here (or it failed): copy the already-extracted file.
		if (file_is_reg(&st) == 0): status = TAR_ERR_IO
		else:
			char* data = 0
			int length = 0
			status = tar_read_file(source, &data, &length)
			if (status == 0): status = tar_write_member_file(full, data, length, file_mode_perm(&st))
			free(data)
	free(source)
	return status


int tar_extract_one(char* dest, tar_entry* e, list[char*] dir_paths, list[int] dir_mtimes):
	int status = tar_make_parents(dest, e.name)
	if (status != 0): return status
	char* full = path_join(dest, e.name)
	if (e.kind == TAR_KIND_DIR):
		int kind = tar_path_kind(full)
		if (kind == 0):
			if (mkdir(full, 511) != 0): status = TAR_ERR_IO
		else if (kind == 2): status = TAR_ERR_UNSAFE_LINK
		else if (kind != 1): status = TAR_ERR_IO
		if (status == 0):
			dir_paths.push(full)
			dir_mtimes.push(e.mtime)
			return 0
		free(full)
		return status
	status = tar_clear_target(full)
	if (status == 0):
		if (e.kind == TAR_KIND_FILE):
			status = tar_write_member_file(full, e.data, e.size, tar_filter_mode(e.mode))
			if (status == 0): file_utimens(full, e.mtime, e.mtime, 0)
		else if (e.kind == TAR_KIND_SYMLINK):
			if (symlink(e.linkname, full) != 0): status = TAR_ERR_IO
		else: status = tar_extract_hardlink(dest, full, e)
	free(full)
	return status


void tar_entries_free(list[tar_entry*] entries):
	for tar_entry* e in entries: tar_entry_free(e)
	list_free[tar_entry*](entries)


# Extracts every member of r under dest (created if missing) with the
# policy in the header comment. Returns 0 or the first error; on a
# read error or an unsafe member nothing is written.
int tar_extract_reader(tar_reader* r, char* dest):
	list[tar_entry*] entries = new list[tar_entry*]
	tar_entry* e = tar_next(r)
	while (e != 0):
		entries.push(e)
		e = tar_next(r)
	int status = tar_reader_error(r)
	for tar_entry* m in entries:
		if (status == 0): status = tar_check_member(m)
	if ((status == 0) && (tar_path_kind(dest) == 0)):
		if (mkdir(dest, 511) != 0): status = TAR_ERR_IO
	list[char*] dir_paths = new list[char*]
	list[int] dir_mtimes = new list[int]
	for tar_entry* m in entries:
		if (status == 0): status = tar_extract_one(dest, m, dir_paths, dir_mtimes)
	# Directory mtimes last (children change them), deepest first.
	int i = dir_paths.length - 1
	while (i >= 0):
		if (status == 0): file_utimens(dir_paths[i], dir_mtimes[i], dir_mtimes[i], 0)
		free(dir_paths[i])
		i = i - 1
	list_free[char*](dir_paths)
	list_free[int](dir_mtimes)
	tar_entries_free(entries)
	return status


# Extracts an in-memory .tar or .tar.gz under dest.
int tar_extract_bytes(char* data, int length, char* dest):
	tar_reader* r = tar_reader_new(data, length)
	int status = tar_extract_reader(r, dest)
	tar_reader_free(r)
	return status


# Extracts the .tar or .tar.gz file at archive under dest.
int tar_extract_all_safe(char* archive, char* dest):
	tar_reader* r = tar_open_read(archive)
	int status = tar_extract_reader(r, dest)
	tar_reader_free(r)
	return status
