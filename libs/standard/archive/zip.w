/*
libs/standard/archive/zip.w: ZIP archive reader and writer (PKWARE
APPNOTE.TXT 6.3), the W counterpart of Python's zipfile
(docs/projects/stdlib_python_parity.md P3.1, plan
libs/standard/plans/07_compression_crypto.md phase 6).

Reader. zip_open_bytes() parses an in-memory archive (borrowed bytes);
zip_open_read() reads a whole file and owns the bytes. Like CPython's
_RealGetContents it finds the end-of-central-directory record (EOCD)
by scanning back over an archive comment of up to 65535 bytes, follows a
zip64 EOCD locator when one precedes it, tolerates bytes prepended to the
archive (self-extractor stubs: offsets are rebased by the same "concat"
delta Python computes), and walks the central directory by its declared
size. Each zip_entry carries the name (raw bytes, NUL-terminated; the
UTF-8 flag 0x800 is reported by zip_entry_is_utf8 -- names without the
flag are returned as raw bytes, not translated from cp437 as Python
does), the method, CRC-32, the DOS date/time words, both attribute words
and the three sizes/offsets. zip64 extra fields (header id 0x0001) are
decoded in APPNOTE order (uncompressed size, compressed size, local
header offset), each present only when its 32-bit field is 0xFFFFFFFF.

Large values. Every 64-bit quantity is kept as masked 32-bit halves
(*_hi/*_lo) so records parse on both word widths; the word-sized field
(compressed_size, file_size, header_offset) is -1 and entry.too_large is
1 when the value does not fit a non-negative word (only possible on the
32-bit target, or for absurd values on x64). Listing such an entry works;
reading it fails with ZIP_ERR_TOO_LARGE. Archive-level counts/offsets
that do not fit fail the open with ZIP_ERR_TOO_LARGE.

Extraction. zip_read() / zip_read_entry() support method 0 (stored) and
8 (deflate, via libs/extras/compress/inflate.w with the output capped at
the declared size, so a lying header cannot balloon memory), check the
local header (signature, name equal to the central one) and verify the
CRC-32 and size. Encrypted entries (flag bit 0) and other methods fail
with distinct codes.

Safety. Every read is bounds-checked against the buffer length with
overflow-safe comparisons, so a truncated or corrupted archive fails with
an error code, never a crash. zip_extract_all_safe() is the only
extraction-to-disk helper: before writing anything it refuses (the whole
archive, ZIP_ERR_UNSAFE_PATH) any member that is absolute ('/' or '\'
prefix, "C:" drive), has a ".." component (either separator), contains
an embedded NUL, or whose joined path is not path_is_within() the
destination. Unlike Python, which silently sanitises such names, W
refuses. Symlink/device entries are written as plain files (as Python
does); a destination that already contains symlinks is not defended.

Writer. zip_writer_new() builds an archive in memory: zip_writer_add()
(stored or deflated), zip_writer_add_dir(), optional archive comment,
then zip_writer_finish() returns the bytes and frees the writer. Local
headers carry the CRC and sizes directly (no data descriptors). zip64
extras / EOCD64 + locator are emitted when a size, offset or the entry
count needs them, or always with force_zip64 (zip_writer_force_zip64;
like Python's force_zip64 but applied to the central directory and end
records too). Entries default to 1980-01-01 00:00:00 (deterministic
output, Python's minimum DOS timestamp) and mode 0600, Python's
writestr() default; zip_writer_add_ex() sets both. Names with non-ASCII
bytes get the UTF-8 flag, as in Python.

Errors: ZIP_ERR_* codes are 301-315; failures from inflate pass their
INFLATE_ERR_* code (1-6) through, except INFLATE_ERR_TOO_LARGE, which
means the stream exceeded the declared size and becomes ZIP_ERR_BAD_SIZE.
zip_error_string() covers both ranges.
*/
import lib.memory
import lib.result
import lib.bytes
import lib.path
import lib.io
import lib.stream
import structures.string
import libs.extras.compress.crc32
import libs.extras.compress.deflate
import libs.extras.compress.inflate


const int ZIP_STORED = 0
const int ZIP_DEFLATED = 8

const int ZIP_ERR_NO_EOCD = 301
const int ZIP_ERR_TRUNCATED = 302
const int ZIP_ERR_BAD_CENTRAL_DIR = 303
const int ZIP_ERR_BAD_LOCAL_HEADER = 304
const int ZIP_ERR_MULTI_DISK = 305
const int ZIP_ERR_UNSUPPORTED_METHOD = 306
const int ZIP_ERR_ENCRYPTED = 307
const int ZIP_ERR_BAD_CRC = 308
const int ZIP_ERR_BAD_SIZE = 309
const int ZIP_ERR_TOO_LARGE = 310
const int ZIP_ERR_NOT_FOUND = 311
const int ZIP_ERR_UNSAFE_PATH = 312
const int ZIP_ERR_IO = 313
const int ZIP_ERR_BAD_ZIP64 = 314
const int ZIP_ERR_BAD_NAME = 315

const int ZIP_SIG_LOCAL = 0x04034b50
const int ZIP_SIG_CENTRAL = 0x02014b50
const int ZIP_SIG_EOCD = 0x06054b50
const int ZIP_SIG_EOCD64 = 0x06064b50
const int ZIP_SIG_LOCATOR64 = 0x07064b50

const int ZIP_FLAG_ENCRYPTED = 1
const int ZIP_FLAG_UTF8 = 0x800


char* zip_error_string(int code):
	if (code == ZIP_ERR_NO_EOCD): return c"zip: not a zip file (end of central directory record not found)"
	if (code == ZIP_ERR_TRUNCATED): return c"zip: truncated archive"
	if (code == ZIP_ERR_BAD_CENTRAL_DIR): return c"zip: corrupt central directory"
	if (code == ZIP_ERR_BAD_LOCAL_HEADER): return c"zip: corrupt local file header"
	if (code == ZIP_ERR_MULTI_DISK): return c"zip: archives spanning multiple disks are not supported"
	if (code == ZIP_ERR_UNSUPPORTED_METHOD): return c"zip: unsupported compression method"
	if (code == ZIP_ERR_ENCRYPTED): return c"zip: encrypted entries are not supported"
	if (code == ZIP_ERR_BAD_CRC): return c"zip: CRC-32 mismatch"
	if (code == ZIP_ERR_BAD_SIZE): return c"zip: entry size does not match its header"
	if (code == ZIP_ERR_TOO_LARGE): return c"zip: value does not fit a machine word on this target"
	if (code == ZIP_ERR_NOT_FOUND): return c"zip: no such entry"
	if (code == ZIP_ERR_UNSAFE_PATH): return c"zip: entry path escapes the destination (absolute or ..)"
	if (code == ZIP_ERR_IO): return c"zip: I/O error"
	if (code == ZIP_ERR_BAD_ZIP64): return c"zip: corrupt zip64 record or extra field"
	if (code == ZIP_ERR_BAD_NAME): return c"zip: invalid entry name"
	return inflate_error_string(code)


struct zip_data:
	char* data
	int length


void zip_data_free(zip_data* d):
	free(d.data)
	free(d)


struct zip_entry:
	char* name
	int name_length
	char* comment
	int comment_length
	int version_made
	int version_needed
	int flags
	int method
	int dos_time
	int dos_date
	int crc
	int internal_attr
	int external_attr
	int compressed_size
	int file_size
	int header_offset
	int compressed_size_hi
	int compressed_size_lo
	int file_size_hi
	int file_size_lo
	int header_offset_hi
	int header_offset_lo
	int too_large
	int has_zip64


struct zip_reader:
	char* data
	int length
	int owns_data
	list[zip_entry*] entries
	char* comment
	int comment_length
	int zip64


# ---- small helpers -----------------------------------------------------------

# Whether [off, off+n) lies inside a buffer of length bytes, with no
# overflow for any non-negative inputs.
int zip_range_ok(int off, int n, int length):
	if ((off < 0) || (n < 0)): return 0
	if (off > length): return 0
	return n <= length - off


char* zip_copy_bytes(char* src, int n):
	char* out = cast(char*, malloc(n + 1))
	for i in range(n): out[i] = src[i]
	out[n] = 0
	return out


# Joins masked halves into a non-negative word; 0 when it does not fit.
int zip_join(int hi, int lo, int* out):
	int mask = bytes_mask32()
	if (__word_size__ == 8):
		int v = ((hi & mask) << 32) | (lo & mask)
		if (v < 0):
			out[0] = -1
			return 0
		out[0] = v
		return 1
	if ((hi != 0) || (lo < 0)):
		out[0] = -1
		return 0
	out[0] = lo
	return 1


int zip_is_ff32(int v):
	int mask = bytes_mask32()
	return (v & mask) == mask


int zip_entry_is_dir(zip_entry* e):
	return (e.name_length > 0) && (e.name[e.name_length - 1] == '/')


int zip_entry_is_utf8(zip_entry* e):
	return (e.flags & ZIP_FLAG_UTF8) != 0


int zip_entry_is_encrypted(zip_entry* e):
	return (e.flags & ZIP_FLAG_ENCRYPTED) != 0


# Unix st_mode stored in the high half of external_attr (0 when the
# archive was not made on a Unix-like host).
int zip_entry_mode(zip_entry* e):
	return shr(e.external_attr, 16) & 65535


void zip_entry_date_time(zip_entry* e, int* year, int* month, int* day, int* hour, int* minute, int* second):
	year[0] = 1980 + ((e.dos_date >> 9) & 127)
	month[0] = (e.dos_date >> 5) & 15
	day[0] = e.dos_date & 31
	hour[0] = (e.dos_time >> 11) & 31
	minute[0] = (e.dos_time >> 5) & 63
	second[0] = (e.dos_time & 31) * 2


# DOS date word for year 1980..2107; out-of-range years clamp like
# Python's ZipInfo (which refuses years before 1980).
int zip_dos_date(int year, int month, int day):
	if (year < 1980): year = 1980
	if (year > 2107): year = 2107
	return ((year - 1980) << 9) | ((month & 15) << 5) | (day & 31)


int zip_dos_time(int hour, int minute, int second):
	return ((hour & 31) << 11) | ((minute & 63) << 5) | ((second / 2) & 31)


void zip_entry_free(zip_entry* e):
	free(e.name)
	free(e.comment)
	free(e)


void zip_close(zip_reader* r):
	for zip_entry* e in r.entries: zip_entry_free(e)
	r.entries.free()
	free(r.comment)
	if (r.owns_data): free(r.data)
	free(r)


# ---- reader ------------------------------------------------------------------

# Offset of the EOCD record, or -1. Searches backwards so the last
# signature whose comment fits the buffer wins (CPython's rfind).
int zip_find_eocd(char* d, int length):
	if (length < 22): return -1
	int i = length - 22
	int stop = i - 65535
	if (stop < 0): stop = 0
	while (i >= stop):
		if (load_le32(d + i) == ZIP_SIG_EOCD):
			int clen = load_le16(d + i + 20)
			if (clen <= length - i - 22): return i
		i = i - 1
	return -1


# Applies one zip64 extra field (header id 1) body to e. Returns 0 or an
# error code.
int zip_apply_zip64_extra(zip_entry* e, char* p, int n):
	int pos = 0
	e.has_zip64 = 1
	if (zip_is_ff32(e.file_size_lo)):
		if (pos + 8 > n): return ZIP_ERR_BAD_ZIP64
		load_le64_parts(p + pos, &e.file_size_hi, &e.file_size_lo)
		pos = pos + 8
	if (zip_is_ff32(e.compressed_size_lo)):
		if (pos + 8 > n): return ZIP_ERR_BAD_ZIP64
		load_le64_parts(p + pos, &e.compressed_size_hi, &e.compressed_size_lo)
		pos = pos + 8
	if (zip_is_ff32(e.header_offset_lo)):
		if (pos + 8 > n): return ZIP_ERR_BAD_ZIP64
		load_le64_parts(p + pos, &e.header_offset_hi, &e.header_offset_lo)
		pos = pos + 8
	return 0


int zip_parse_extra(zip_entry* e, char* p, int n):
	int pos = 0
	while (pos + 4 <= n):
		int id = load_le16(p + pos)
		int size = load_le16(p + pos + 2)
		if (size > n - pos - 4): return ZIP_ERR_BAD_CENTRAL_DIR
		if (id == 1):
			int err = zip_apply_zip64_extra(e, p + pos + 4, size)
			if (err != 0): return err
		pos = pos + 4 + size
	return 0


# Parses one central directory record at d+pos (cd_end bounds it).
# Stores the record length in *used. Returns 0 or an error code; on
# error *out is 0.
int zip_parse_central(char* d, int pos, int cd_end, int concat, zip_entry** out, int* used):
	out[0] = 0
	if (zip_range_ok(pos, 46, cd_end) == 0): return ZIP_ERR_BAD_CENTRAL_DIR
	if (load_le32(d + pos) != ZIP_SIG_CENTRAL): return ZIP_ERR_BAD_CENTRAL_DIR
	int name_len = load_le16(d + pos + 28)
	int extra_len = load_le16(d + pos + 30)
	int comment_len = load_le16(d + pos + 32)
	int total = 46 + name_len + extra_len + comment_len
	if (zip_range_ok(pos, total, cd_end) == 0): return ZIP_ERR_BAD_CENTRAL_DIR
	zip_entry* e = new zip_entry
	e.version_made = load_le16(d + pos + 4)
	e.version_needed = load_le16(d + pos + 6)
	e.flags = load_le16(d + pos + 8)
	e.method = load_le16(d + pos + 10)
	e.dos_time = load_le16(d + pos + 12)
	e.dos_date = load_le16(d + pos + 14)
	e.crc = load_le32(d + pos + 16)
	e.compressed_size_lo = load_le32(d + pos + 20)
	e.file_size_lo = load_le32(d + pos + 24)
	int disk_start = load_le16(d + pos + 34)
	e.internal_attr = load_le16(d + pos + 36)
	e.external_attr = load_le32(d + pos + 38)
	e.header_offset_lo = load_le32(d + pos + 42)
	e.name_length = name_len
	e.name = zip_copy_bytes(d + pos + 46, name_len)
	e.comment_length = comment_len
	e.comment = zip_copy_bytes(d + pos + 46 + name_len + extra_len, comment_len)
	int err = zip_parse_extra(e, d + pos + 46 + name_len, extra_len)
	if ((err == 0) && (disk_start != 0) && (disk_start != 65535)): err = ZIP_ERR_MULTI_DISK
	if (err != 0):
		zip_entry_free(e)
		return err
	int fits = zip_join(e.compressed_size_hi, e.compressed_size_lo, &e.compressed_size)
	fits = zip_join(e.file_size_hi, e.file_size_lo, &e.file_size) && fits
	int off_fits = zip_join(e.header_offset_hi, e.header_offset_lo, &e.header_offset)
	if (off_fits):
		if (e.header_offset > __w_word_max() - concat):
			e.header_offset = -1
			off_fits = 0
		else:
			e.header_offset = e.header_offset + concat
	e.too_large = (fits && off_fits) == 0
	out[0] = e
	used[0] = total
	return 0


wresult[zip_reader*]* zip_open_fail(zip_reader* r, int code):
	zip_close(r)
	return result_new_error[zip_reader*](code)


# Parses the archive in data[0..length). The bytes are borrowed: keep
# them alive (and unchanged) until zip_close().
wresult[zip_reader*]* zip_open_bytes(char* data, int length):
	if (length < 0): length = 0
	int eocd = zip_find_eocd(data, length)
	if (eocd < 0): return result_new_error[zip_reader*](ZIP_ERR_NO_EOCD)
	zip_reader* r = new zip_reader
	r.data = data
	r.length = length
	r.entries = new list[zip_entry*]
	r.comment_length = load_le16(data + eocd + 20)
	r.comment = zip_copy_bytes(data + eocd + 22, r.comment_length)
	int disk = load_le16(data + eocd + 4)
	int disk_cd = load_le16(data + eocd + 6)
	# The classic fields may be saturated (0xFFFFFFFF) when a zip64 end
	# record follows, so they are only converted when they are used.
	int cd_size_hi = 0
	int cd_size_lo = load_le32(data + eocd + 12)
	int cd_off_hi = 0
	int cd_off_lo = load_le32(data + eocd + 16)
	int location = eocd
	if ((eocd >= 20) && (load_le32(data + eocd - 20) == ZIP_SIG_LOCATOR64)):
		int loc = eocd - 20
		int z64_disk = load_le32(data + loc + 4)
		int total_disks = load_le32(data + loc + 16)
		if ((z64_disk != 0) || (total_disks > 1)): return zip_open_fail(r, ZIP_ERR_MULTI_DISK)
		# Like CPython, assume no zip64 extensible data: the record sits
		# immediately before its locator.
		int rec = loc - 56
		if (rec < 0): return zip_open_fail(r, ZIP_ERR_BAD_ZIP64)
		if (load_le32(data + rec) != ZIP_SIG_EOCD64): return zip_open_fail(r, ZIP_ERR_BAD_ZIP64)
		disk = load_le32(data + rec + 16)
		disk_cd = load_le32(data + rec + 20)
		load_le64_parts(data + rec + 40, &cd_size_hi, &cd_size_lo)
		load_le64_parts(data + rec + 48, &cd_off_hi, &cd_off_lo)
		location = rec
		r.zip64 = 1
	int cd_size = 0
	int cd_off = 0
	if (zip_join(cd_size_hi, cd_size_lo, &cd_size) == 0): return zip_open_fail(r, ZIP_ERR_TOO_LARGE)
	if (zip_join(cd_off_hi, cd_off_lo, &cd_off) == 0): return zip_open_fail(r, ZIP_ERR_TOO_LARGE)
	if ((disk != 0) || (disk_cd != 0)): return zip_open_fail(r, ZIP_ERR_MULTI_DISK)
	# Where the central directory really starts (just before the end
	# records) versus where the archive says it starts: the difference
	# is data prepended to the archive, and rebases every offset.
	if (cd_size > location): return zip_open_fail(r, ZIP_ERR_BAD_CENTRAL_DIR)
	int cd_start = location - cd_size
	int concat = cd_start - cd_off
	if (concat < 0): return zip_open_fail(r, ZIP_ERR_BAD_CENTRAL_DIR)
	int pos = cd_start
	while (pos < location):
		zip_entry* e = 0
		int used = 0
		int err = zip_parse_central(data, pos, location, concat, &e, &used)
		if (err != 0): return zip_open_fail(r, err)
		r.entries.push(e)
		pos = pos + used
	return result_new_ok[zip_reader*](r)


# Reads a whole file into memory and parses it; the reader owns the bytes.
# Fails with ZIP_ERR_IO when the file cannot be read.
wresult[zip_reader*]* zip_open_read(char* path):
	wstream* in = stream_open_read(path)
	if (in == 0): return result_new_error[zip_reader*](ZIP_ERR_IO)
	string_builder* buf = string_new()
	io_result ior
	int status = stream_read_all_checked(in, buf, &ior)
	stream_close(in)
	if (status != IO_OK):
		string_free(buf)
		return result_new_error[zip_reader*](ZIP_ERR_IO)
	char* data = buf.data
	int length = buf.length
	free(buf)
	wresult[zip_reader*]* res = zip_open_bytes(data, length)
	if (result_is_error[zip_reader*](res)):
		free(data)
		return res
	zip_reader* r = result_value[zip_reader*](res)
	r.owns_data = 1
	return res


int zip_count(zip_reader* r):
	return r.entries.length


zip_entry* zip_entry_at(zip_reader* r, int index):
	if ((index < 0) || (index >= r.entries.length)): return 0
	return r.entries[index]


# The last entry with this name (Python's getinfo: a later duplicate
# shadows an earlier one), or 0.
zip_entry* zip_getinfo(zip_reader* r, char* name):
	int i = r.entries.length - 1
	while (i >= 0):
		zip_entry* e = r.entries[i]
		if (strcmp(e.name, name) == 0): return e
		i = i - 1
	return 0


# Names in archive order. The strings belong to the reader; free only the
# list (names.free()).
list[char*] zip_namelist(zip_reader* r):
	list[char*] names = new list[char*]
	for zip_entry* e in r.entries: names.push(e.name)
	return names


wresult[zip_data*]* zip_read_entry(zip_reader* r, zip_entry* e):
	if (e.too_large): return result_new_error[zip_data*](ZIP_ERR_TOO_LARGE)
	if (zip_entry_is_encrypted(e)): return result_new_error[zip_data*](ZIP_ERR_ENCRYPTED)
	if ((e.method != ZIP_STORED) && (e.method != ZIP_DEFLATED)):
		return result_new_error[zip_data*](ZIP_ERR_UNSUPPORTED_METHOD)
	char* d = r.data
	int off = e.header_offset
	if (zip_range_ok(off, 30, r.length) == 0): return result_new_error[zip_data*](ZIP_ERR_TRUNCATED)
	if (load_le32(d + off) != ZIP_SIG_LOCAL): return result_new_error[zip_data*](ZIP_ERR_BAD_LOCAL_HEADER)
	int lname = load_le16(d + off + 26)
	int lextra = load_le16(d + off + 28)
	if (zip_range_ok(off + 30, lname + lextra, r.length) == 0):
		return result_new_error[zip_data*](ZIP_ERR_TRUNCATED)
	if (bytes_equal(d + off + 30, lname, e.name, e.name_length) == 0):
		return result_new_error[zip_data*](ZIP_ERR_BAD_LOCAL_HEADER)
	int data_off = off + 30 + lname + lextra
	if (zip_range_ok(data_off, e.compressed_size, r.length) == 0):
		return result_new_error[zip_data*](ZIP_ERR_TRUNCATED)
	char* out = 0
	int out_len = 0
	if (e.method == ZIP_STORED):
		if (e.compressed_size != e.file_size): return result_new_error[zip_data*](ZIP_ERR_BAD_SIZE)
		out = zip_copy_bytes(d + data_off, e.file_size)
		out_len = e.file_size
	else:
		int consumed = 0
		wresult[inflate_result*]* ir = inflate_ex_limit(d + data_off, e.compressed_size, e.file_size, &consumed)
		if (result_is_error[inflate_result*](ir)):
			int code = result_code[inflate_result*](ir)
			result_free[inflate_result*](ir)
			if (code == INFLATE_ERR_TOO_LARGE): code = ZIP_ERR_BAD_SIZE
			return result_new_error[zip_data*](code)
		inflate_result* body = result_value[inflate_result*](ir)
		result_free[inflate_result*](ir)
		out = body.data
		out_len = body.length
		free(body)
		if (out_len != e.file_size):
			free(out)
			return result_new_error[zip_data*](ZIP_ERR_BAD_SIZE)
	if (crc32_of(out, out_len) != e.crc):
		free(out)
		return result_new_error[zip_data*](ZIP_ERR_BAD_CRC)
	zip_data* res = new zip_data(out, out_len)
	return result_new_ok[zip_data*](res)


wresult[zip_data*]* zip_read(zip_reader* r, char* name):
	zip_entry* e = zip_getinfo(r, name)
	if (e == 0): return result_new_error[zip_data*](ZIP_ERR_NOT_FOUND)
	return zip_read_entry(r, e)


# Reads every entry and checks its CRC (Python's testzip). Returns the
# index of the first bad entry, or -1 when all are good; *code receives
# that entry's error code (0 when all are good).
int zip_testzip(zip_reader* r, int* code):
	code[0] = 0
	for i in range(r.entries.length):
		wresult[zip_data*]* res = zip_read_entry(r, r.entries[i])
		if (result_is_error[zip_data*](res)):
			code[0] = result_code[zip_data*](res)
			result_free[zip_data*](res)
			return i
		zip_data_free(result_value[zip_data*](res))
		result_free[zip_data*](res)
	return -1


# ---- safe extraction ---------------------------------------------------------

# Whether a member name may be extracted: relative, no ".." component
# ('/' or '\' separated), no drive prefix, no embedded NUL, not empty.
int zip_member_name_is_safe(char* name, int name_length):
	if (name_length <= 0): return 0
	if (strlen(name) != name_length): return 0
	if ((name[0] == '/') || (name[0] == '\\')): return 0
	if ((name_length >= 2) && (name[1] == ':')): return 0
	int start = 0
	int i = 0
	while (i <= name_length):
		if ((i == name_length) || (name[i] == '/') || (name[i] == '\\')):
			if ((i - start == 2) && (name[start] == '.') && (name[start + 1] == '.')): return 0
			start = i + 1
		i = i + 1
	return 1


# mkdir -p; tolerates existing directories. Returns 0 or ZIP_ERR_IO.
int zip_mkdirs(char* path):
	if ((strlen(path) == 0) || (strcmp(path, c"/") == 0) || (strcmp(path, c".") == 0)): return 0
	if (path_exists(path)): return 0
	char* parent = path_dirname(path)
	int err = zip_mkdirs(parent)
	free(parent)
	if (err != 0): return err
	int rc = mkdir(path, 493)
	if ((rc != 0) && (rc != (0 - 17))): return ZIP_ERR_IO
	return 0


# Creates or truncates path (mode 0644) with length bytes. 0 or ZIP_ERR_IO.
int zip_write_file(char* path, char* data, int length):
	# 577 = O_WRONLY | O_CREAT | O_TRUNC, 420 = rw-r--r--
	int fd = open(path, 577, 420)
	if (fd < 0): return ZIP_ERR_IO
	io_result wr
	io_result closed
	int status = io_write_all(fd, data, length, &wr)
	io_close(fd, &closed)
	if ((status != IO_OK) || (closed.status != IO_OK)): return ZIP_ERR_IO
	return 0


# The destination path for e under dest, or 0 when it is unsafe.
char* zip_safe_target(char* dest, zip_entry* e):
	if (zip_member_name_is_safe(e.name, e.name_length) == 0): return 0
	char* joined = path_join(dest, e.name)
	if (path_is_within(dest, joined) == 0):
		free(joined)
		return 0
	return joined


int zip_extract_entry_to(zip_reader* r, zip_entry* e, char* target):
	if (zip_entry_is_dir(e)): return zip_mkdirs(target)
	char* parent = path_dirname(target)
	int err = zip_mkdirs(parent)
	free(parent)
	if (err != 0): return err
	wresult[zip_data*]* res = zip_read_entry(r, e)
	if (result_is_error[zip_data*](res)):
		int code = result_code[zip_data*](res)
		result_free[zip_data*](res)
		return code
	zip_data* body = result_value[zip_data*](res)
	result_free[zip_data*](res)
	err = zip_write_file(target, body.data, body.length)
	zip_data_free(body)
	return err


# Extracts one entry beneath dest. Returns 0 or an error code.
int zip_extract_safe(zip_reader* r, zip_entry* e, char* dest):
	char* target = zip_safe_target(dest, e)
	if (target == 0): return ZIP_ERR_UNSAFE_PATH
	int err = zip_extract_entry_to(r, e, target)
	free(target)
	return err


# Extracts every entry beneath dest (created if missing). Every name is
# validated before anything is written, so an unsafe archive writes
# nothing. Returns 0 or the first error code.
int zip_extract_all_safe(zip_reader* r, char* dest):
	for zip_entry* e in r.entries:
		char* target = zip_safe_target(dest, e)
		if (target == 0): return ZIP_ERR_UNSAFE_PATH
		free(target)
	int err = zip_mkdirs(dest)
	if (err != 0): return err
	for zip_entry* e in r.entries:
		err = zip_extract_safe(r, e, dest)
		if (err != 0): return err
	return 0


# ---- writer ------------------------------------------------------------------

struct zip_writer:
	string_builder* out
	string_builder* central
	int count
	int force_zip64
	int level
	char* comment
	int comment_length


zip_writer* zip_writer_new():
	zip_writer* w = new zip_writer
	w.out = string_new()
	w.central = string_new()
	w.level = DEFLATE_LEVEL_FAST()
	return w


# Always write zip64 extras and end records (Python's force_zip64, which
# it applies to local headers only).
void zip_writer_force_zip64(zip_writer* w, int on):
	w.force_zip64 = on


# DEFLATE_LEVEL_FAST() (default) or DEFLATE_LEVEL_BEST().
void zip_writer_set_level(zip_writer* w, int level):
	w.level = level


# Archive comment, truncated to 65535 bytes (Python raises; W truncates
# because the field cannot hold more).
void zip_writer_set_comment(zip_writer* w, char* comment, int length):
	if (length < 0): length = 0
	if (length > 65535): length = 65535
	free(w.comment)
	w.comment = zip_copy_bytes(comment, length)
	w.comment_length = length


void zip_writer_free(zip_writer* w):
	string_free(w.out)
	string_free(w.central)
	free(w.comment)
	free(w)


void zip_put16(string_builder* b, int v):
	string_append_char(b, v & 255)
	string_append_char(b, shr(v, 8) & 255)


void zip_put32(string_builder* b, int v):
	string_append_char(b, v & 255)
	string_append_char(b, shr(v, 8) & 255)
	string_append_char(b, shr(v, 16) & 255)
	string_append_char(b, shr(v, 24) & 255)


void zip_put64(string_builder* b, int v):
	int hi = 0
	int lo = 0
	bytes_split64(v, &hi, &lo)
	zip_put32(b, lo)
	zip_put32(b, hi)


# Whether a non-negative word needs a zip64 field (>= 0xFFFFFFFF). Never
# on the 32-bit target, where words stay below 2^31.
int zip_needs64(int v):
	if (__word_size__ == 8): return v >= bytes_mask32()
	return 0


# Adds one entry. method is ZIP_STORED or ZIP_DEFLATED; dos_date/dos_time
# from zip_dos_date/zip_dos_time; external_attr as in the central
# directory (mode << 16 for Unix modes). Returns 0 or an error code.
int zip_writer_add_ex(zip_writer* w, char* name, char* data, int length, int method, int dos_date, int dos_time, int external_attr):
	int name_len = strlen(name)
	if ((name_len == 0) || (name_len > 65535)): return ZIP_ERR_BAD_NAME
	if ((method != ZIP_STORED) && (method != ZIP_DEFLATED)): return ZIP_ERR_UNSUPPORTED_METHOD
	if (length < 0): length = 0
	int flags = 0
	for i in range(name_len):
		if ((name[i] & 128) != 0): flags = ZIP_FLAG_UTF8
	int crc = crc32_of(data, length)
	deflate_result* packed = 0
	char* body = data
	int csize = length
	if (method == ZIP_DEFLATED):
		packed = deflate(data, length, w.level)
		body = packed.data
		csize = packed.length
	int offset = w.out.length
	int z64 = w.force_zip64 || zip_needs64(length) || zip_needs64(csize) || zip_needs64(offset)
	int version = 20
	if (z64): version = 45
	int ff = bytes_mask32()

	string_builder* o = w.out
	zip_put32(o, ZIP_SIG_LOCAL)
	zip_put16(o, version)
	zip_put16(o, flags)
	zip_put16(o, method)
	zip_put16(o, dos_time)
	zip_put16(o, dos_date)
	zip_put32(o, crc)
	if (z64):
		zip_put32(o, ff)
		zip_put32(o, ff)
	else:
		zip_put32(o, csize)
		zip_put32(o, length)
	zip_put16(o, name_len)
	if (z64): zip_put16(o, 20)
	else: zip_put16(o, 0)
	string_append_bytes(o, name, name_len)
	if (z64):
		zip_put16(o, 1)
		zip_put16(o, 16)
		zip_put64(o, length)
		zip_put64(o, csize)
	string_append_bytes(o, body, csize)
	if (packed != 0): deflate_result_free(packed)

	string_builder* c = w.central
	zip_put32(c, ZIP_SIG_CENTRAL)
	zip_put16(c, (3 << 8) | version)
	zip_put16(c, version)
	zip_put16(c, flags)
	zip_put16(c, method)
	zip_put16(c, dos_time)
	zip_put16(c, dos_date)
	zip_put32(c, crc)
	if (z64):
		zip_put32(c, ff)
		zip_put32(c, ff)
	else:
		zip_put32(c, csize)
		zip_put32(c, length)
	zip_put16(c, name_len)
	if (z64): zip_put16(c, 28)
	else: zip_put16(c, 0)
	zip_put16(c, 0)   # comment length
	zip_put16(c, 0)   # disk number start
	zip_put16(c, 0)   # internal attributes
	zip_put32(c, external_attr)
	if (z64): zip_put32(c, ff)
	else: zip_put32(c, offset)
	string_append_bytes(c, name, name_len)
	if (z64):
		zip_put16(c, 1)
		zip_put16(c, 24)
		zip_put64(c, length)
		zip_put64(c, csize)
		zip_put64(c, offset)
	w.count = w.count + 1
	return 0


# Adds a file entry dated 1980-01-01 00:00:00 with mode 0600 (Python's
# writestr defaults, minus the clock).
int zip_writer_add(zip_writer* w, char* name, char* data, int length, int method):
	return zip_writer_add_ex(w, name, data, length, method, zip_dos_date(1980, 1, 1), 0, 384 << 16)


# Adds a directory entry (a trailing '/' is appended when missing), mode
# 0755 plus the MS-DOS directory bit, as Python's mkdir() writes it.
int zip_writer_add_dir(zip_writer* w, char* name):
	int n = strlen(name)
	if (n == 0): return ZIP_ERR_BAD_NAME
	string_builder* b = string_new()
	string_append_bytes(b, name, n)
	if (name[n - 1] != '/'): string_append_char(b, '/')
	int err = zip_writer_add_ex(w, b.data, c"", 0, ZIP_STORED, zip_dos_date(1980, 1, 1), 0, (16877 << 16) | 16)
	string_free(b)
	return err


# Writes the central directory and end records, frees the writer and
# returns the archive bytes (caller frees with zip_data_free).
zip_data* zip_writer_finish(zip_writer* w):
	string_builder* o = w.out
	int cd_off = o.length
	int cd_size = w.central.length
	string_append_bytes(o, w.central.data, cd_size)
	int count = w.count
	int ff = bytes_mask32()
	int z64 = w.force_zip64 || (count >= 65535) || zip_needs64(cd_off) || zip_needs64(cd_size)
	if (z64):
		int rec = o.length
		zip_put32(o, ZIP_SIG_EOCD64)
		zip_put64(o, 44)
		zip_put16(o, (3 << 8) | 45)
		zip_put16(o, 45)
		zip_put32(o, 0)
		zip_put32(o, 0)
		zip_put64(o, count)
		zip_put64(o, count)
		zip_put64(o, cd_size)
		zip_put64(o, cd_off)
		zip_put32(o, ZIP_SIG_LOCATOR64)
		zip_put32(o, 0)
		zip_put64(o, rec)
		zip_put32(o, 1)
	int short_count = count
	if (short_count > 65535): short_count = 65535
	zip_put32(o, ZIP_SIG_EOCD)
	zip_put16(o, 0)
	zip_put16(o, 0)
	zip_put16(o, short_count)
	zip_put16(o, short_count)
	if (zip_needs64(cd_size)): zip_put32(o, ff)
	else: zip_put32(o, cd_size)
	if (zip_needs64(cd_off)): zip_put32(o, ff)
	else: zip_put32(o, cd_off)
	zip_put16(o, w.comment_length)
	if (w.comment_length > 0): string_append_bytes(o, w.comment, w.comment_length)
	zip_data* res = new zip_data(o.data, o.length)
	free(o)
	string_free(w.central)
	free(w.comment)
	free(w)
	return res
