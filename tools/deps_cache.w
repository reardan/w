/*
The import-closure cache shared by bin/wexec (bin/.wexec_deps_cache:
deps-driven cache keys) and bin/wtest (bin/.wtest_deps_cache: closure
test selection): content hashing, 'bin/wv2 deps' runs, the on-disk
record format, loading, validation and saving. What to do about a
root that fails to compile -- whether to persist it, and what a cached
failure must still match -- is each tool's policy (wexec_deps_lookup,
wtest_closure_compute); this module only offers the pieces.

One record per root id "<arch> <root>" (arch "x86" for the default
target):

  R <arch> <root>        a closure
  X <arch> <root>        a root that did not compile
  H <digest>             R: over every closure file's (path, content
                         hash), in order; X: the root file's own hash
  V <bin/wv2 hash>       X: the compiler that failed, validated when
                         the tool asks; R: informational
  M <import path>        X only, optional: the import the compile
                         reported missing (validated with V)
  E <stderr line>        X only, informational: the first error line
  F <file>               R only, one per closure file in deps order

A record whose id has no arch column is dropped on load, and a line
with an unknown tag is skipped, so caches from older or newer builds
stay readable and simply recompute what they cannot use.

The process holds one cache (deps_cache_path), so the state is global:
bin/wbuildd, which runs wexec in-process, keeps deps_file_hashes warm
across builds.
*/
import lib.lib
import lib.file
import lib.path
import lib.process
import lib.sha256
import lib.str
import structures.string


/* Streaming content hash: SHA-256 (bin/wexec's cache keys and closure
digests, 64 hex chars) or a 64-bit pair of 32-bit rolling hashes
(bin/wtest's closure digests, 16 hex chars -- several times faster,
which matters because every wtest run re-hashes each closure file to
validate the cache). */

struct deps_hash:
	int sha              # 1: SHA-256; 0: the rolling hash
	int* state           # SHA-256: 8 running 32-bit words h[0..7]
	char* block          # SHA-256: 64-byte pending block
	int block_len        # SHA-256: bytes buffered in block, 0..63
	int total_len        # SHA-256: total bytes hashed so far
	int h1               # rolling: FNV-style word
	int h2               # rolling: second multiplier word
	int mask             # rolling: 32 low bits (not -1 on 64-bit targets)


# A 32-bit all-ones mask for the word size; 0xffffffff would
# sign-extend to -1 on x64.
int deps_mask32():
	if (__word_size__ == 8):
		int high = 1 << 16
		return high * high - 1
	return -1


# The SHA-256 variant streams lib/sha256.w's block compressor 64 bytes
# at a time (sha256()'s own tail handling, applied incrementally).
void deps_hash_init(deps_hash* h, int sha):
	h.sha = sha
	if (sha == 0):
		h.mask = deps_mask32()
		h.h1 = -2128831035 & h.mask
		h.h2 = 1000003
		return
	h.state = cast(int*, malloc(8 * __word_size__))
	char* h0 = sha256_h0_table()
	int i = 0
	while (i < 8):
		h.state[i] = sha256_be32(h0 + i * 4)
		i = i + 1
	h.block = malloc(64)
	h.block_len = 0
	h.total_len = 0


void deps_hash_bytes(deps_hash* h, char* data, int n):
	int i = 0
	if (h.sha == 0):
		int mask = h.mask
		int h1 = h.h1
		int h2 = h.h2
		while (i < n):
			int value = data[i] & 255
			h1 = (h1 * 16777619 + value) & mask
			h2 = (h2 * 1000003 + value) & mask
			i = i + 1
		h.h1 = h1
		h.h2 = h2
		return
	h.total_len = h.total_len + n
	while (i < n):
		h.block[h.block_len] = data[i]
		h.block_len = h.block_len + 1
		if (h.block_len == 64):
			sha256_block(h.state, h.block)
			h.block_len = 0
		i = i + 1


# Strings never contain NUL, so a trailing 0 byte keeps consecutive
# strings from colliding with their concatenation.
void deps_hash_cstr(deps_hash* h, char* text):
	deps_hash_bytes(h, text, strlen(text))
	char zero = 0
	deps_hash_bytes(h, &zero, 1)


void deps_append_hex(string_builder* s, int value, int digits):
	int shift = (digits - 1) * 4
	while (shift >= 0):
		int nibble = (value >> shift) & 15
		if (nibble < 10):
			string_append_char(s, '0' + nibble)
		else:
			string_append_char(s, 'a' + nibble - 10)
		shift = shift - 4


# Finalize into a fresh hex string (and release the SHA-256 buffers).
char* deps_hash_hex(deps_hash* h):
	string_builder* s = string_new()
	if (h.sha == 0):
		deps_append_hex(s, h.h1, 8)
		deps_append_hex(s, h.h2, 8)
		char* short_text = s.data
		free(s)
		return short_text
	# Pad the trailing partial block (0x80 terminator, zero pad, 64-bit
	# big-endian bit length) and compress it.
	char* tail = malloc(128)
	int j = 0
	while (j < 128):
		tail[j] = 0
		j = j + 1
	j = 0
	while (j < h.block_len):
		tail[j] = h.block[j]
		j = j + 1
	tail[h.block_len] = 128 /* 0x80 */
	int blocks = 1
	if (h.block_len >= 56):
		blocks = 2
	int bitlen_pos = blocks * 64 - 8
	sha256_put_be32(tail + bitlen_pos, (h.total_len >> 29) & sha256_mask32())
	sha256_put_be32(tail + bitlen_pos + 4, (h.total_len << 3) & sha256_mask32())
	sha256_block(h.state, tail)
	if (blocks == 2):
		sha256_block(h.state, tail + 64)
	free(tail)
	char* digest = malloc(32)
	int i = 0
	while (i < 8):
		sha256_put_be32(digest + i * 4, h.state[i])
		i = i + 1
	i = 0
	while (i < 32):
		deps_append_hex(s, digest[i] & 255, 2)
		i = i + 1
	free(digest)
	free(h.state)
	free(h.block)
	char* text = s.data
	free(s)
	return text


/* The cache. */

struct deps_entry:
	char* id        # "<arch> <root>"
	char* root      # the id's root part
	int failed      # an 'X' record
	int checked     # validated or computed during this run
	int keep        # written by deps_cache_save (0: a run-local memo)
	char* digest    # H
	char* vhash     # V, or 0
	char* missing   # M, or 0
	char* detail    # E, or 0
	char* blob      # "\n" + one closure file per line; 0 for a failure
	char* chunk     # the record's on-disk text as loaded, or 0


char* deps_cache_path                    # set by the tool before any other call
int deps_cache_sha                       # 1: SHA-256 digests; 0: rolling
list[deps_entry*] deps_entries           # 0 until deps_cache_load
map[char*, deps_entry*] deps_index       # id -> entry
map[char*, char*] deps_file_hashes       # path -> content hash memo
map[char*, char*] deps_loaded_chunks     # id -> record text as loaded
int deps_dirty                           # a record changed since the load


# Content hash of one file, memoized. A missing file hashes to a
# sentinel no digest matches, so a deletion invalidates its records.
char* deps_file_hash(char* path):
	if (deps_file_hashes == 0):
		deps_file_hashes = new map[char*, char*]
	char* cached = deps_file_hashes.get(path, 0)
	if (cached != 0):
		return cached
	char* digest = c"<missing>"
	int fd = open(path, 0, 0)
	if (fd >= 0):
		deps_hash h
		deps_hash_init(&h, deps_cache_sha)
		int buffer_size = 65536
		char* buffer = malloc(buffer_size)
		int n = read(fd, buffer, buffer_size)
		while (n > 0):
			deps_hash_bytes(&h, buffer, n)
			n = read(fd, buffer, buffer_size)
		free(buffer)
		close(fd)
		digest = deps_hash_hex(&h)
	deps_file_hashes[path] = digest
	return digest


# Combined digest over (path, content hash) of every file in a closure
# blob, in order.
char* deps_digest(char* blob):
	deps_hash h
	deps_hash_init(&h, deps_cache_sha)
	string_builder* line = string_new()
	int i = 0
	while (1):
		if ((blob[i] == 10) || (blob[i] == 0)):
			if (line.length > 0):
				deps_hash_cstr(&h, line.data)
				deps_hash_cstr(&h, deps_file_hash(line.data))
				string_clear(line)
			if (blob[i] == 0):
				break
		else:
			string_append_char(line, blob[i])
		i = i + 1
	string_free(line)
	return deps_hash_hex(&h)


char* deps_id(char* arch, char* root):
	string_builder* s = string_new()
	string_append(s, arch)
	string_append_char(s, ' ')
	string_append(s, root)
	char* id = s.data
	free(s)
	return id


# The root part of an id (a pointer into it), or 0 without an arch
# column.
char* deps_id_root(char* id):
	int i = 0
	while (id[i] != 0):
		if (id[i] == ' '):
			return id + i + 1
		i = i + 1
	return 0


# A blank entry for id (every field set: 'new' does not zero memory).
deps_entry* deps_entry_new(char* id, int failed):
	deps_entry* e = new deps_entry
	e.id = strclone(id)
	e.root = deps_id_root(e.id)
	e.failed = failed
	e.checked = 0
	e.keep = 1
	e.digest = 0
	e.vhash = 0
	e.missing = 0
	e.detail = 0
	e.blob = 0
	e.chunk = 0
	return e


# The records of cache text, in file order and unvalidated. A record
# without an arch column, or repeating an earlier id, is dropped.
list[deps_entry*] deps_cache_parse(char* text):
	list[deps_entry*] out = new list[deps_entry*]
	map[char*, int] seen = new map[char*, int]
	deps_entry* e = 0
	string_builder* blob = 0
	string_builder* chunk = 0
	string_builder* current = string_new()
	int i = 0
	int at_end = 0
	while (1):
		# The next line (0 past the end); lib/str.w's split is quadratic
		# on a cache-sized text.
		char* line = 0
		if (at_end == 0):
			string_clear(current)
			while ((text[i] != 0) && (text[i] != 10)):
				string_append_char(current, text[i])
				i = i + 1
			if (text[i] == 0):
				at_end = 1
			else:
				i = i + 1
			line = current.data
			if (at_end && (line[0] == 0)):
				line = 0
		int header = 0
		if (line != 0):
			header = (starts_with(line, c"R ") || starts_with(line, c"X "))
		if ((line == 0) || header):
			# Close the previous record.
			if ((e != 0) && (e.digest != 0) && (e.root != 0) && ((e.id in seen) == 0)):
				if (e.failed == 0):
					e.blob = blob.data
					free(blob)
				else:
					string_free(blob)
				e.chunk = chunk.data
				free(chunk)
				seen[e.id] = 1
				out.push(e)
			if (line == 0):
				break
			e = deps_entry_new(line + 2, line[0] == 'X')
			blob = string_new()
			string_append_char(blob, 10)
			chunk = string_new()
		if (e == 0):
			continue
		string_append(chunk, line)
		string_append_char(chunk, 10)
		if (starts_with(line, c"H ")):
			e.digest = strclone(line + 2)
		else if (starts_with(line, c"V ")):
			e.vhash = strclone(line + 2)
		else if (starts_with(line, c"M ")):
			e.missing = strclone(line + 2)
		else if (starts_with(line, c"E ")):
			e.detail = strclone(line + 2)
		else if (starts_with(line, c"F ")):
			string_append(blob, line + 2)
			string_append_char(blob, 10)
	return out


# Reads deps_cache_path once (a missing file is an empty cache).
# Records are not validated here: deps_entry_valid does that.
void deps_cache_load():
	if (deps_entries != 0):
		return
	deps_entries = new list[deps_entry*]
	deps_index = new map[char*, deps_entry*]
	deps_loaded_chunks = new map[char*, char*]
	char* text = file_read_text(deps_cache_path)
	if (text == 0):
		return
	for deps_entry* e in deps_cache_parse(text):
		e.keep = 1
		deps_entries.push(e)
		deps_index[e.id] = e
		deps_loaded_chunks[e.id] = e.chunk
	free(text)


# The loaded or recorded entry for id, validated or not, or 0.
deps_entry* deps_cache_find(char* id):
	deps_cache_load()
	return deps_index.get(id, 0)


# Whether e still describes the tree: a closure's digest is
# reproduced by re-hashing its files; a failure's root file is
# unchanged and -- with check_compiler -- so is bin/wv2 (its V line is
# required) and a recorded missing import is still absent. Marks e
# checked when valid.
int deps_entry_valid(deps_entry* e, int check_compiler):
	if (e.checked):
		return 1
	if (e.failed == 0):
		if (e.blob == 0):
			return 0
		if (strcmp(deps_digest(e.blob), e.digest) != 0):
			return 0
	else:
		if (strcmp(deps_file_hash(e.root), e.digest) != 0):
			return 0
		if (check_compiler):
			if (e.vhash == 0):
				return 0
			if (strcmp(deps_file_hash(c"bin/wv2"), e.vhash) != 0):
				return 0
			if ((e.missing != 0) && path_exists(e.missing)):
				return 0
	e.checked = 1
	return 1


# Validate every loaded record now, dropping the ones that fail, so
# deps_cache_find only ever returns valid entries.
void deps_cache_validate_all(int check_compiler):
	deps_cache_load()
	list[deps_entry*] valid = new list[deps_entry*]
	for deps_entry* e in deps_entries:
		if (deps_entry_valid(e, check_compiler)):
			valid.push(e)
		else:
			deps_index.remove(e.id)
	deps_entries = valid


# Record a freshly computed closure (blob) or failure (blob = 0) for
# id, replacing any loaded entry; persisted by the next save. The
# caller sets vhash/missing/detail and keep as its policy requires.
deps_entry* deps_cache_record(char* id, char* blob):
	deps_cache_load()
	deps_entry* e = deps_index.get(id, 0)
	if (e == 0):
		e = deps_entry_new(id, 0)
		deps_entries.push(e)
		deps_index[e.id] = e
	e.failed = blob == 0
	e.blob = blob
	e.checked = 1
	e.keep = 1
	e.vhash = 0
	e.missing = 0
	e.detail = 0
	e.chunk = 0
	if (blob == 0):
		e.digest = deps_file_hash(e.root)
	else:
		e.digest = deps_digest(blob)
	deps_dirty = 1
	return e


# Runs 'bin/wv2 deps [arch] <root>' for id; 0 when it could not spawn.
process_result* deps_run(char* id, int timeout_ms):
	char* root = deps_id_root(id)
	if (root == 0):
		return 0
	char* arch = substring(id, 0, strlen(id) - strlen(root) - 1)
	char** argv = strv_new(4)
	strv_set(argv, 0, c"bin/wv2")
	strv_set(argv, 1, c"deps")
	if (strcmp(arch, c"x86") == 0):
		strv_set(argv, 2, root)
	else:
		strv_set(argv, 2, arch)
		strv_set(argv, 3, root)
	process_result* r = process_run(c"bin/wv2", argv, 0, 0, timeout_ms)
	free(cast(char*, argv))
	free(arch)
	return r


# A successful deps run's stdout as a closure blob: "\n" + one path per
# line, each newline-terminated.
char* deps_blob(char* stdout_text):
	string_builder* blob = string_new()
	string_append_char(blob, 10)
	string_append(blob, stdout_text)
	if (blob.data[blob.length - 1] != 10):
		string_append_char(blob, 10)
	char* text = blob.data
	free(blob)
	return text


void deps_append_line(string_builder* out, char* tag, char* value):
	string_append(out, tag)
	string_append(out, value)
	string_append_char(out, 10)


# Writes every kept entry to deps_cache_path, then carries over the
# on-disk records other processes wrote since the load (an id this
# process holds no entry for, whose text differs from what it loaded:
# wbuildd and one-shot runs rewrite the cache concurrently). The file
# is replaced by rename, so a concurrent reader never sees a
# half-written cache.
void deps_cache_save():
	deps_cache_load()
	string_builder* out = string_new()
	for deps_entry* e in deps_entries:
		if (e.keep == 0):
			continue
		if (e.failed):
			deps_append_line(out, c"X ", e.id)
		else:
			deps_append_line(out, c"R ", e.id)
		deps_append_line(out, c"H ", e.digest)
		if (e.vhash != 0):
			deps_append_line(out, c"V ", e.vhash)
		if (e.missing != 0):
			deps_append_line(out, c"M ", e.missing)
		if (e.detail != 0):
			deps_append_line(out, c"E ", e.detail)
		if (e.blob != 0):
			# "F <path>" for each non-empty blob line.
			int j = 0
			while (e.blob[j] != 0):
				int line_start = (j == 0) || (e.blob[j - 1] == 10)
				if (line_start && (e.blob[j] != 10)):
					string_append(out, c"F ")
				if ((line_start == 0) || (e.blob[j] != 10)):
					string_append_char(out, e.blob[j])
				j = j + 1
	char* disk = file_read_text(deps_cache_path)
	if (disk != 0):
		for deps_entry* other in deps_cache_parse(disk):
			if (other.id in deps_index):
				continue
			char* seen = deps_loaded_chunks.get(other.id, 0)
			if ((seen != 0) && (strcmp(seen, other.chunk) == 0)):
				continue
			string_append(out, other.chunk)
		free(disk)
	mkdir(c"bin", 493)
	string_builder* tmp = string_new()
	string_append(tmp, deps_cache_path)
	string_append_char(tmp, '.')
	string_append_int(tmp, getpid())
	string_append(tmp, c".tmp")
	if (file_write_text(tmp.data, out.data)):
		if (rename(tmp.data, deps_cache_path) < 0):
			unlink(tmp.data)
	string_free(tmp)
	string_free(out)
	deps_dirty = 0
