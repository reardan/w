/*
Sorted in-memory write buffer with tombstones — the mutable tier of
the LSM tree (docs/projects/distributed.md, phase 4; Bigtable §5.3).

Writes land here first (after the WAL); reads consult the memtable
before any on-disk table, so deletes must be first-class: a delete
stores a TOMBSTONE that shadows older on-disk values until compaction
drops it. That forces the three-way get contract every LSM layer
above this one relies on:

  0  key unknown here — fall through to the sstables
  1  found — value_out/len_out set (borrowed pointer, valid until the
     next mutation of this key or clear/free)
  2  tombstone — the key is definitively deleted; do NOT fall through

Storage is four parallel lists kept sorted by key (strcmp), binary
search for lookup and insertion — right-sized for the flush-threshold
scale a memtable lives at. Keys and values are malloc'd copies owned
by the memtable; values may be binary (length carried separately, a
convenience NUL appended). Iteration by sorted index (memtable_key_at
et al.) is the flush/merge interface: ascending key order, exactly
what sstable writers require.

bytes accounting approximates memory footprint as key_len + value_len
per live record (tombstones count their key only) — the flush
threshold trigger, not an allocator audit.
*/
import lib.lib
import lib.memory
import lib.assert


struct memtable:
	list[char*] keys        # sorted ascending by strcmp; owned copies
	list[char*] values      # owned copies (0 for tombstones)
	list[int] value_lens    # binary-safe value lengths (0 for tombstones)
	list[int] tombstones    # 1 = delete marker
	int bytes


memtable* memtable_new():
	memtable* m = new memtable()
	m.keys = new list[char*]
	m.values = new list[char*]
	m.value_lens = new list[int]
	m.tombstones = new list[int]
	m.bytes = 0
	return m


void memtable_clear(memtable* m):
	int i = 0
	while (i < m.keys.length):
		free(m.keys[i])
		if (cast(int, m.values[i]) != 0):
			free(m.values[i])
		i = i + 1
	m.keys = new list[char*]
	m.values = new list[char*]
	m.value_lens = new list[int]
	m.tombstones = new list[int]
	m.bytes = 0


void memtable_free(memtable* m):
	int i = 0
	while (i < m.keys.length):
		free(m.keys[i])
		if (cast(int, m.values[i]) != 0):
			free(m.values[i])
		i = i + 1
	free(m)


int memtable_count(memtable* m):
	return m.keys.length


int memtable_bytes(memtable* m):
	return m.bytes


# Index of key, or the insertion point encoded as -(pos) - 1 when
# absent (classic binary-search convention, kept int-only).
int memtable_find(memtable* m, char* key):
	int lo = 0
	int hi = m.keys.length
	while (lo < hi):
		int mid = (lo + hi) / 2
		int c = strcmp(m.keys[mid], key)
		if (c == 0):
			return mid
		if (c < 0):
			lo = mid + 1
		else:
			hi = mid
	return 0 - lo - 1


char* memtable_copy_bytes(char* src, int len):
	char* dst = malloc(len + 1)
	int i = 0
	while (i < len):
		dst[i] = src[i]
		i = i + 1
	dst[len] = 0
	return dst


void memtable_store(memtable* m, char* key, char* value, int value_len, int tombstone):
	assert1(value_len >= 0)
	int idx = memtable_find(m, key)
	if (idx >= 0):
		# replace in place
		m.bytes = m.bytes - m.value_lens[idx]
		if (cast(int, m.values[idx]) != 0):
			free(m.values[idx])
		if (tombstone):
			m.values[idx] = cast(char*, 0)
			m.value_lens[idx] = 0
		else:
			m.values[idx] = memtable_copy_bytes(value, value_len)
			m.value_lens[idx] = value_len
			m.bytes = m.bytes + value_len
		m.tombstones[idx] = tombstone
		return
	int pos = 0 - idx - 1
	m.keys.insert(pos, memtable_copy_bytes(key, strlen(key)))
	if (tombstone):
		m.values.insert(pos, cast(char*, 0))
		m.value_lens.insert(pos, 0)
	else:
		m.values.insert(pos, memtable_copy_bytes(value, value_len))
		m.value_lens.insert(pos, value_len)
	m.tombstones.insert(pos, tombstone)
	m.bytes = m.bytes + strlen(key) + value_len


# Insert or replace. Copies key and value; value may be binary.
void memtable_put(memtable* m, char* key, char* value, int value_len):
	memtable_store(m, key, value, value_len, 0)


# Upsert a tombstone: shadows any older value for key, here and in
# every table below, until compaction drops it.
void memtable_delete(memtable* m, char* key):
	memtable_store(m, key, cast(char*, 0), 0, 1)


# Three-way lookup; see header. value_out/len_out are written only on
# return 1; the value pointer is borrowed.
int memtable_get(memtable* m, char* key, char** value_out, int* len_out):
	int idx = memtable_find(m, key)
	if (idx < 0):
		return 0
	if (m.tombstones[idx]):
		return 2
	value_out[0] = m.values[idx]
	len_out[0] = m.value_lens[idx]
	return 1


# ---- sorted iteration (the flush/merge interface) ---------------------------

char* memtable_key_at(memtable* m, int i):
	assert1(i >= 0 && i < m.keys.length)
	return m.keys[i]


int memtable_is_tombstone_at(memtable* m, int i):
	assert1(i >= 0 && i < m.keys.length)
	return m.tombstones[i]


# Borrowed pointer; len via len_out. Tombstones return 0 with len 0.
char* memtable_value_at(memtable* m, int i, int* len_out):
	assert1(i >= 0 && i < m.keys.length)
	len_out[0] = m.value_lens[i]
	return m.values[i]
