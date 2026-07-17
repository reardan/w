/*
Immutable sorted string table — the on-disk tier of the LSM tree
(docs/projects/distributed.md, phase 4; Bigtable §4).

A memtable flush writes its sorted records through sstable_writer into
one immutable file; readers open the file once, build an in-memory
index (sorted key array plus per-record value offset/length/flag) with
a full sequential scan, and afterwards serve point reads with a bloom
probe, a binary search, and at most one seek+read for the value bytes.
Tombstones are first-class (Bigtable §5.3): a deleted key is stored
with flag 1 and no value, so a get answers the same three-way contract
as the memtable above it:

  0  key unknown here — fall through to older sstables
  1  found — *value_out is a malloc'd NUL-terminated copy read from
     disk (length via len_out); the caller frees it
  2  tombstone — the key is definitively deleted; do NOT fall through

File layout, format v1, all little-endian:
  offset 0: 4-byte magic "WSST", 4-byte format version (1)
  4-byte bloom_len, then bloom_len bytes: bloom_serialize output over
  ALL record keys (tombstones included — a tombstone must still be
  found so it can shadow older tables)
  4-byte record count
  count records, each:
    1-byte flag (0 = value, 1 = tombstone)
    4-byte key_len, 4-byte val_len (0 for tombstones)
    key bytes, value bytes
Records are sorted strictly ascending by key (strcmp), no duplicates —
the writer asserts it, the reader rejects files that violate it.

Bloom sizing at write time: m = count * 10 clamped to [64, 1 << 20]
bits, k = 5 probes (~1% theoretical false-positive rate at 10 bits per
key). An empty table still writes the (all-zero) 64-bit filter, so the
reader never special-cases a missing bloom.

sstable_open validates everything it later trusts: magic, version, the
bloom's own m/k header against bloom_new's accepted ranges and
bloom_len against the implied serialized size (so a corrupt file
returns 0 instead of tripping asserts inside bloom_deserialize), and
every record's lengths against the remaining file bytes (a file
truncated mid-record is rejected). Values are NOT held in memory: the
index keeps their file offsets and lengths, and reads fetch bytes on
demand from the still-open descriptor.
*/
import lib.lib
import lib.memory
import lib.assert
import lib.framing
import libs.standard.distributed.bloom


int sstable_version():
	return 1


# ---- little-endian + buffer helpers -----------------------------------------

void sstable_put_le32(char* p, int v):
	p[0] = v & 255
	p[1] = (v >> 8) & 255
	p[2] = (v >> 16) & 255
	p[3] = (v >> 24) & 255


int sstable_get_le32(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)


# Malloc'd copy of len bytes with a convenience NUL appended.
char* sstable_copy_bytes(char* src, int len):
	char* dst = malloc(len + 1)
	int i = 0
	while (i < len):
		dst[i] = src[i]
		i = i + 1
	dst[len] = 0
	return dst


# Bloom bit count for a table of `count` records: count * 10 clamped
# to [64, 1 << 20]; probes are always k = 5.
int sstable_bloom_bits(int count):
	int m = count * 10
	if (m < 64):
		m = 64
	if (m > (1 << 20)):
		m = 1 << 20
	return m


int sstable_bloom_probes():
	return 5


# ---- writer ------------------------------------------------------------------

# Buffers records in memory (sorted order enforced on add) and writes
# the whole file once in sstable_writer_finish.
struct sstable_writer:
	char* path              # owned copy of the destination path
	list[char*] keys        # owned copies, strictly ascending
	list[char*] values      # owned copies (0 for tombstones)
	list[int] value_lens    # binary-safe lengths (0 for tombstones)
	list[int] flags         # 1 = tombstone


# Creates (truncating) the file at path so open failures surface here,
# then buffers records until finish rewrites the whole file. Returns 0
# when the path cannot be created.
sstable_writer* sstable_writer_new(char* path):
	int fd = create_file(path, 420)
	if (fd < 0):
		return 0
	close(fd)
	sstable_writer* w = new sstable_writer()
	w.path = sstable_copy_bytes(path, strlen(path))
	w.keys = new list[char*]
	w.values = new list[char*]
	w.value_lens = new list[int]
	w.flags = new list[int]
	return w


# Frees everything the writer owns, including w itself.
void sstable_writer_release(sstable_writer* w):
	int i = 0
	while (i < w.keys.length):
		free(w.keys[i])
		if (cast(int, w.values[i]) != 0):
			free(w.values[i])
		i = i + 1
	free(w.path)
	free(w)


# Buffers one record. Keys must arrive strictly ascending by strcmp
# (asserted). Key and value bytes are copied; the value may be binary.
# A tombstone ignores value/value_len entirely (val_len forced 0).
# Returns 1.
int sstable_writer_add(sstable_writer* w, char* key, char* value, int value_len, int tombstone):
	if (w.keys.length > 0):
		assert1(strcmp(w.keys[w.keys.length - 1], key) < 0)
	w.keys.push(sstable_copy_bytes(key, strlen(key)))
	if (tombstone):
		w.values.push(cast(char*, 0))
		w.value_lens.push(0)
		w.flags.push(1)
	else:
		assert1(value_len >= 0)
		w.values.push(sstable_copy_bytes(value, value_len))
		w.value_lens.push(value_len)
		w.flags.push(0)
	return 1


# Builds the bloom filter over all buffered keys, writes the complete
# file, and frees the writer (on failure too — the writer is consumed
# either way). Returns 1 on success, 0 on an I/O failure.
int sstable_writer_finish(sstable_writer* w):
	int count = w.keys.length
	bloom_filter* b = bloom_new(sstable_bloom_bits(count), sstable_bloom_probes())
	int i = 0
	while (i < count):
		bloom_add(b, w.keys[i])
		i = i + 1
	int bloom_len = bloom_serialized_size(b)
	int total = 8 + 4 + bloom_len + 4
	i = 0
	while (i < count):
		total = total + 9 + strlen(w.keys[i]) + w.value_lens[i]
		i = i + 1
	char* buf = malloc(total)
	buf[0] = 87    # W
	buf[1] = 83    # S
	buf[2] = 83    # S
	buf[3] = 84    # T
	sstable_put_le32(buf + 4, sstable_version())
	sstable_put_le32(buf + 8, bloom_len)
	bloom_serialize(b, buf + 12)
	sstable_put_le32(buf + 12 + bloom_len, count)
	bloom_free(b)
	int off = 16 + bloom_len
	i = 0
	while (i < count):
		char* key = w.keys[i]
		int key_len = strlen(key)
		int val_len = w.value_lens[i]
		buf[off] = w.flags[i]
		sstable_put_le32(buf + off + 1, key_len)
		sstable_put_le32(buf + off + 5, val_len)
		int j = 0
		while (j < key_len):
			buf[off + 9 + j] = key[j]
			j = j + 1
		char* value = w.values[i]
		j = 0
		while (j < val_len):
			buf[off + 9 + key_len + j] = value[j]
			j = j + 1
		off = off + 9 + key_len + val_len
		i = i + 1
	int ok = 0
	int fd = create_file(w.path, 420)
	if (fd >= 0):
		if (write_all(fd, buf, total) == total):
			ok = 1
		close(fd)
	free(buf)
	sstable_writer_release(w)
	return ok


# ---- reader ------------------------------------------------------------------

struct sstable:
	int fd                  # stays open for on-demand value reads
	int count
	list[char*] keys        # owned copies, sorted ascending
	list[int] value_offs    # absolute file offset of each value's bytes
	list[int] value_lens    # value byte length (0 for tombstones)
	list[int] flags         # 1 = tombstone
	bloom_filter* bloom     # deserialized filter over all keys


# Closes the descriptor and frees the index, the bloom filter, and s.
void sstable_close(sstable* s):
	int i = 0
	while (i < s.keys.length):
		free(s.keys[i])
		i = i + 1
	bloom_free(s.bloom)
	close(s.fd)
	free(s)


# Opens the table at path and builds the in-memory index with one
# sequential scan. Returns 0 on open failure, bad magic/version, or a
# malformed structure (bad bloom geometry, out-of-order keys, or a
# file truncated mid-record).
sstable* sstable_open(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	int size = file_size(fd)
	char* hdr = malloc(12)
	seek(fd, 0, 0)
	int got = read_exact(fd, hdr, 12)
	int ok = 0
	if (got == 12 && (hdr[0] & 255) == 87 && (hdr[1] & 255) == 83 && (hdr[2] & 255) == 83 && (hdr[3] & 255) == 84):
		if (sstable_get_le32(hdr + 4) == sstable_version()):
			ok = 1
	int bloom_len = sstable_get_le32(hdr + 8)
	free(hdr)
	if (ok == 0):
		close(fd)
		return 0
	# The bloom region must fit (with the count word after it) and
	# carry m/k the bloom module itself would accept, and bloom_len
	# must equal the serialized size that m implies — otherwise
	# bloom_deserialize's asserts could kill the process on a corrupt
	# file instead of this returning 0.
	if (bloom_len < 16 || bloom_len > size - 16):
		close(fd)
		return 0
	char* bbuf = malloc(bloom_len)
	if (read_exact(fd, bbuf, bloom_len) != bloom_len):
		free(bbuf)
		close(fd)
		return 0
	int bm = sstable_get_le32(bbuf)
	int bk = sstable_get_le32(bbuf + 4)
	ok = 1
	if (bm < 8 || bm > (1 << 24) || bk < 1 || bk > 16):
		ok = 0
	else:
		if (bloom_len != 12 + ((bm + 31) >> 5) * 4 || sstable_get_le32(bbuf + 8) != bm):
			ok = 0
	if (ok == 0):
		free(bbuf)
		close(fd)
		return 0
	bloom_filter* bl = bloom_deserialize(bbuf)
	free(bbuf)
	char* cbuf = malloc(4)
	got = read_exact(fd, cbuf, 4)
	int count = sstable_get_le32(cbuf)
	free(cbuf)
	if (got != 4 || count < 0):
		bloom_free(bl)
		close(fd)
		return 0
	sstable* s = new sstable()
	s.fd = fd
	s.count = count
	s.keys = new list[char*]
	s.value_offs = new list[int]
	s.value_lens = new list[int]
	s.flags = new list[int]
	s.bloom = bl
	int off = 16 + bloom_len
	int i = 0
	while (i < count):
		# All length checks subtract from the remaining byte budget so
		# a huge corrupt length cannot overflow past the bound.
		int remaining = size - off
		if (remaining < 9):
			sstable_close(s)
			return 0
		char* rhdr = malloc(9)
		seek(fd, off, 0)
		got = read_exact(fd, rhdr, 9)
		int flag = rhdr[0] & 255
		int key_len = sstable_get_le32(rhdr + 1)
		int val_len = sstable_get_le32(rhdr + 5)
		free(rhdr)
		ok = 1
		if (got != 9 || flag > 1):
			ok = 0
		if (key_len < 0 || key_len > remaining - 9):
			ok = 0
		# Only checked once key_len is known sane, so the subtraction
		# cannot underflow.
		if (ok == 1 && (val_len < 0 || val_len > remaining - 9 - key_len)):
			ok = 0
		if (flag == 1 && val_len != 0):
			ok = 0
		if (ok == 0):
			sstable_close(s)
			return 0
		char* key = malloc(key_len + 1)
		if (read_exact(fd, key, key_len) != key_len):
			free(key)
			sstable_close(s)
			return 0
		key[key_len] = 0
		s.keys.push(key)
		s.value_offs.push(off + 9 + key_len)
		s.value_lens.push(val_len)
		s.flags.push(flag)
		if (i > 0 && strcmp(s.keys[i - 1], s.keys[i]) >= 0):
			sstable_close(s)
			return 0
		off = off + 9 + key_len + val_len
		i = i + 1
	return s


int sstable_count(sstable* s):
	return s.count


# Index of key in the sorted key array, or the insertion point encoded
# as -(pos) - 1 when absent (the memtable_find convention).
int sstable_find(sstable* s, char* key):
	int lo = 0
	int hi = s.count
	while (lo < hi):
		int mid = (lo + hi) / 2
		int c = strcmp(s.keys[mid], key)
		if (c == 0):
			return mid
		if (c < 0):
			lo = mid + 1
		else:
			hi = mid
	return 0 - lo - 1


# Reads record idx's value bytes from disk: malloc'd, NUL-terminated,
# length s.value_lens[idx].
char* sstable_read_value(sstable* s, int idx):
	int len = s.value_lens[idx]
	char* buf = malloc(len + 1)
	seek(s.fd, s.value_offs[idx], 0)
	assert1(read_exact(s.fd, buf, len) == len)
	buf[len] = 0
	return buf


# Three-way lookup; see the header comment. On return 1 the value is a
# malloc'd NUL-terminated copy read from disk (caller frees); on 0 and
# 2 the out-params are untouched.
int sstable_get(sstable* s, char* key, char** value_out, int* len_out):
	if (bloom_maybe_contains(s.bloom, key) == 0):
		return 0
	int idx = sstable_find(s, key)
	if (idx < 0):
		return 0
	if (s.flags[idx]):
		return 2
	value_out[0] = sstable_read_value(s, idx)
	len_out[0] = s.value_lens[idx]
	return 1


# Bloom probe only (no index search): 0 = definitely absent, 1 =
# possibly present. Exposed for tests and read-path telemetry.
int sstable_maybe_contains(sstable* s, char* key):
	return bloom_maybe_contains(s.bloom, key)


# ---- sorted iteration (the compaction/merge interface) -----------------------

# Borrowed pointer, valid until sstable_close; ascending by strcmp.
char* sstable_key_at(sstable* s, int i):
	assert1(i >= 0 && i < s.count)
	return s.keys[i]


int sstable_is_tombstone_at(sstable* s, int i):
	assert1(i >= 0 && i < s.count)
	return s.flags[i]


# Malloc'd NUL-terminated copy read from disk (caller frees); length
# via len_out. Tombstones return 0 with len 0.
char* sstable_value_at(sstable* s, int i, int* len_out):
	assert1(i >= 0 && i < s.count)
	if (s.flags[i]):
		len_out[0] = 0
		return 0
	len_out[0] = s.value_lens[i]
	return sstable_read_value(s, i)
