/*
Log-structured merge tree tying the three storage tiers together
(docs/projects/distributed.md, phase 4; Bigtable §5.3):

  wal.w       durability — every mutation is appended to a data wal
              BEFORE it touches memory
  memtable.w  the mutable tier — sorted in-memory buffer, tombstones
  sstable.w   the immutable tier — flushed and compacted tables

All of an lsm's files live under one caller-supplied path prefix (lib
has no mkdir/readdir, so the prefix is a filename stem, not a
directory):

  <prefix>.wal        data wal (put/delete records since last flush)
  <prefix>.manifest   manifest wal (which sstables exist, in order)
  <prefix>.sst<seq>   one immutable sstable per flush/compaction

Data wal record encoding (little-endian, one record per mutation):
  tag u8 1 PUT:    key_len u32, val_len u32, key bytes, value bytes
  tag u8 2 DELETE: key_len u32, key bytes
Manifest record encoding:
  tag u8 1 ADD-TABLE: seq u32 — the table file "<prefix>.sst<seq>"

Write path: append the wal record first (a failed append fails the
whole operation and mutates nothing), then upsert the memtable. When
memtable_bytes exceeds the configured limit the memtable auto-flushes.

Read path: memtable first (its three-way contract decides: found
returns a MALLOC'D COPY so every lsm_get result is caller-freed
uniformly; tombstone stops the search), then the sstables NEWEST
FIRST (highest list index first). Tables are held oldest-first in
l.tables, parallel to l.table_paths.

Flush ordering (the crash windows are the point):
  1. write "<prefix>.sst<next_seq>" completely and sstable_open it
  2. append ADD-TABLE(seq) to the manifest
  3. wal_reset the data wal, memtable_clear
A crash between 1 and 2 leaves an orphan table file the manifest
never references — the data is still in the data wal and replays. A
crash between 2 and 3 replays the data wal INTO a state that already
has the table: harmless, memtable upserts are idempotent and the
memtable shadows the equal values below it.

Recovery (lsm_open):
  1. replay the manifest; sstable_open every referenced table. A
     missing/corrupt table is a hard failure (returns 0) EXCEPT when
     it is the LAST manifest entry: that is the flush crash window
     between table write and data-wal reset (or a torn table write),
     so the entry is DROPPED — its data is still in the data wal. The
     manifest is immediately rewritten without the dangling entry so
     a later flush cannot bury it in non-last position, and the
     dangling seq still advances next_seq so its (possibly partially
     written) file path is never reused.
  2. replay the data wal into a fresh memtable (torn tails were
     already truncated by wal_open's checksummed scan).
  3. next_seq = max(every seq the manifest referenced) + 1; 1 for a
     fresh tree.

Compaction (lsm_compact) is full: a k-way merge across ALL tables
(the memtable is NOT included — lsm_flush first to fold it in). The
newest table wins ties; tombstones are dropped entirely (nothing
older than a full compaction can be shadowed); the survivors become
the single table "<prefix>.sst<next_seq>" — written even when empty,
preserving the one-table-after-compact invariant. The manifest is
wal_reset and rewritten with the single ADD-TABLE record; the crash
window between that reset and the append is a documented v1 gap
(lib has no atomic rename), acceptable for the simulation/test tiers
this phase targets. Old table files stay on disk orphaned — lib has
no unlink; a recovery never reads them because the manifest no
longer references them.

Single-writer assumption throughout: one lsm owns its prefix.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.wal
import libs.standard.distributed.memtable
import libs.standard.distributed.sstable


struct lsm:
	char* prefix              # owned copy of the caller's path stem
	char* wal_path            # owned "<prefix>.wal" (wal.path borrows it)
	char* manifest_path       # owned "<prefix>.manifest"
	wal* log                  # data wal: mutations since the last flush
	wal* manifest             # manifest wal: the live table list
	memtable* mem             # mutable tier
	list[sstable*] tables     # oldest first; reads scan newest (highest index) first
	list[char*] table_paths   # parallel to tables; owned strings
	int next_seq              # seq of the next table file to write
	int memtable_limit_bytes  # auto-flush threshold for memtable_bytes


# ---- record tags ------------------------------------------------------------

int lsm_tag_put():
	return 1


int lsm_tag_delete():
	return 2


int lsm_tag_add_table():
	return 1


# ---- small helpers ----------------------------------------------------------

# Malloc'd copy of len bytes with a convenience NUL appended.
char* lsm_copy_bytes(char* src, int len):
	char* dst = malloc(len + 1)
	int i = 0
	while (i < len):
		dst[i] = src[i]
		i = i + 1
	dst[len] = 0
	return dst


# "<prefix>.sst<seq>", malloc'd; caller frees (or hands to table_paths).
char* lsm_table_path(char* prefix, int seq):
	char* num = itoa(seq)
	char* stem = strjoin(prefix, c".sst")
	char* path = strjoin(stem, num)
	free(stem)
	free(num)
	return path


# Appends one ADD-TABLE(seq) record to the manifest wal. Returns
# wal_append's result (1 ok, 0 short write).
int lsm_manifest_append_table(wal* mlog, int seq):
	char* rec = malloc(5)
	rec[0] = lsm_tag_add_table()
	wal_put_le32(rec + 1, seq)
	int ok = wal_append(mlog, rec, 5)
	free(rec)
	return ok


# Fold one data-wal record into the recovering memtable. The wal's
# checksum already rejected torn or corrupt records, so a malformed
# payload here means a foreign writer — asserted, not tolerated.
void lsm_replay_data_record(memtable* m, char* p, int len):
	int tag = p[0] & 255
	if (tag == lsm_tag_put()):
		assert1(len >= 9)
		int key_len = wal_get_le32(p + 1)
		int val_len = wal_get_le32(p + 5)
		assert1(key_len >= 0 && val_len >= 0 && len == 9 + key_len + val_len)
		char* key = lsm_copy_bytes(p + 9, key_len)
		memtable_put(m, key, p + 9 + key_len, val_len)
		free(key)
		return
	if (tag == lsm_tag_delete()):
		assert1(len >= 5)
		int dkey_len = wal_get_le32(p + 1)
		assert1(dkey_len >= 0 && len == 5 + dkey_len)
		char* dkey = lsm_copy_bytes(p + 5, dkey_len)
		memtable_delete(m, dkey)
		free(dkey)
		return
	assert1(0)


# ---- lifecycle ----------------------------------------------------------------

# Opens (creating if missing) the tree at prefix and recovers it: the
# manifest names the live tables, the data wal rebuilds the memtable.
# Recovery rules — including the dangling-last-manifest-entry drop —
# are documented in the header. Returns 0 on any unrecoverable
# failure (unopenable wal, foreign manifest record, or a missing/
# corrupt table that is not the last manifest entry), with everything
# that was opened closed again.
lsm* lsm_open(char* prefix, int memtable_limit_bytes):
	char* own_prefix = lsm_copy_bytes(prefix, strlen(prefix))
	char* wpath = strjoin(own_prefix, c".wal")
	char* mpath = strjoin(own_prefix, c".manifest")
	wal* mlog = wal_open(mpath)
	if (cast(int, mlog) == 0):
		free(mpath)
		free(wpath)
		free(own_prefix)
		return 0
	int* len_out = cast(int*, malloc(__word_size__))
	int fail = 0
	# 1. manifest replay: collect the referenced seqs in log order
	list[int] seqs = new list[int]
	wal_reader* mrd = wal_reader_open(mpath)
	assert1(cast(int, mrd) != 0)
	char* mp = wal_read_next(mrd, len_out)
	while (mp != 0):
		if (len_out[0] == 5 && (mp[0] & 255) == lsm_tag_add_table()):
			seqs.push(wal_get_le32(mp + 1))
		else:
			fail = 1
		free(mp)
		mp = wal_read_next(mrd, len_out)
	wal_reader_close(mrd)
	# 2. open every referenced table; only the LAST entry may dangle
	list[sstable*] tables = new list[sstable*]
	list[char*] table_paths = new list[char*]
	int dropped = 0
	int i = 0
	while (i < seqs.length && fail == 0):
		char* tpath = lsm_table_path(own_prefix, seqs[i])
		sstable* t = sstable_open(tpath)
		if (cast(int, t) == 0):
			free(tpath)
			if (i == seqs.length - 1):
				dropped = 1
			else:
				fail = 1
		else:
			tables.push(t)
			table_paths.push(tpath)
		i = i + 1
	# 3. dangling last entry dropped: rewrite the manifest without it
	# so the next recovery never sees it in non-last position
	if (fail == 0 && dropped == 1):
		if (wal_reset(mlog) == 0):
			fail = 1
		i = 0
		while (i < tables.length && fail == 0):
			if (lsm_manifest_append_table(mlog, seqs[i]) == 0):
				fail = 1
			i = i + 1
	# 4. next_seq: one past every seq ever referenced (the dangling
	# one included, so its file path is never reused)
	int next_seq = 1
	i = 0
	while (i < seqs.length):
		if (seqs[i] >= next_seq):
			next_seq = seqs[i] + 1
		i = i + 1
	# 5. data wal
	wal* dlog = 0
	if (fail == 0):
		dlog = wal_open(wpath)
		if (cast(int, dlog) == 0):
			fail = 1
	if (fail == 1):
		i = 0
		while (i < tables.length):
			sstable* opened = tables[i]
			sstable_close(opened)
			free(table_paths[i])
			i = i + 1
		wal_close(mlog)
		free(cast(char*, len_out))
		free(mpath)
		free(wpath)
		free(own_prefix)
		return 0
	# 6. replay the data wal into a fresh memtable
	memtable* mem = memtable_new()
	wal_reader* drd = wal_reader_open(wpath)
	assert1(cast(int, drd) != 0)
	char* dp = wal_read_next(drd, len_out)
	while (dp != 0):
		lsm_replay_data_record(mem, dp, len_out[0])
		free(dp)
		dp = wal_read_next(drd, len_out)
	wal_reader_close(drd)
	free(cast(char*, len_out))
	lsm* l = new lsm()
	l.prefix = own_prefix
	l.wal_path = wpath
	l.manifest_path = mpath
	l.log = dlog
	l.manifest = mlog
	l.mem = mem
	l.tables = tables
	l.table_paths = table_paths
	l.next_seq = next_seq
	l.memtable_limit_bytes = memtable_limit_bytes
	return l


# Closes both wals and every table, then frees everything the lsm
# owns (memtable, path strings, l itself). No implicit flush: data
# not flushed stays in the data wal and replays on the next open.
void lsm_close(lsm* l):
	wal_close(l.log)
	wal_close(l.manifest)
	int i = 0
	while (i < l.tables.length):
		sstable* t = l.tables[i]
		sstable_close(t)
		free(l.table_paths[i])
		i = i + 1
	memtable_free(l.mem)
	free(l.wal_path)
	free(l.manifest_path)
	free(l.prefix)
	free(l)


# ---- flush --------------------------------------------------------------------

# Writes the memtable — tombstones included, they must keep shadowing
# older tables — to "<prefix>.sst<next_seq>", registers it in the
# manifest, then resets the data wal and clears the memtable (in that
# order; see the header's crash-window notes). Empty memtable is a
# no-op returning 1. Returns 0 on any I/O failure.
int lsm_flush(lsm* l):
	int count = memtable_count(l.mem)
	if (count == 0):
		return 1
	char* path = lsm_table_path(l.prefix, l.next_seq)
	sstable_writer* w = sstable_writer_new(path)
	if (cast(int, w) == 0):
		free(path)
		return 0
	int* len_out = cast(int*, malloc(__word_size__))
	int i = 0
	while (i < count):
		char* key = memtable_key_at(l.mem, i)
		if (memtable_is_tombstone_at(l.mem, i)):
			sstable_writer_add(w, key, cast(char*, 0), 0, 1)
		else:
			char* val = memtable_value_at(l.mem, i, len_out)
			sstable_writer_add(w, key, val, len_out[0], 0)
		i = i + 1
	free(cast(char*, len_out))
	if (sstable_writer_finish(w) == 0):
		free(path)
		return 0
	sstable* t = sstable_open(path)
	if (cast(int, t) == 0):
		free(path)
		return 0
	l.tables.push(t)
	l.table_paths.push(path)
	if (lsm_manifest_append_table(l.manifest, l.next_seq) == 0):
		return 0
	l.next_seq = l.next_seq + 1
	if (wal_reset(l.log) == 0):
		return 0
	memtable_clear(l.mem)
	return 1


# ---- mutations ------------------------------------------------------------------

# Durable insert/overwrite: wal first, then memtable, then the
# auto-flush check. Returns 1, or 0 on a wal/flush I/O failure (on a
# wal failure nothing was mutated).
int lsm_put(lsm* l, char* key, char* value, int value_len):
	assert1(value_len >= 0)
	int key_len = strlen(key)
	char* rec = malloc(9 + key_len + value_len)
	rec[0] = lsm_tag_put()
	wal_put_le32(rec + 1, key_len)
	wal_put_le32(rec + 5, value_len)
	int i = 0
	while (i < key_len):
		rec[9 + i] = key[i]
		i = i + 1
	i = 0
	while (i < value_len):
		rec[9 + key_len + i] = value[i]
		i = i + 1
	int ok = wal_append(l.log, rec, 9 + key_len + value_len)
	free(rec)
	if (ok == 0):
		return 0
	memtable_put(l.mem, key, value, value_len)
	if (memtable_bytes(l.mem) > l.memtable_limit_bytes):
		return lsm_flush(l)
	return 1


# Durable delete: records a tombstone that shadows every older tier
# until a full compaction drops it. Same wal-first shape as lsm_put.
int lsm_delete(lsm* l, char* key):
	int key_len = strlen(key)
	char* rec = malloc(5 + key_len)
	rec[0] = lsm_tag_delete()
	wal_put_le32(rec + 1, key_len)
	int i = 0
	while (i < key_len):
		rec[5 + i] = key[i]
		i = i + 1
	int ok = wal_append(l.log, rec, 5 + key_len)
	free(rec)
	if (ok == 0):
		return 0
	memtable_delete(l.mem, key)
	if (memtable_bytes(l.mem) > l.memtable_limit_bytes):
		return lsm_flush(l)
	return 1


# ---- reads ----------------------------------------------------------------------

# Point lookup: memtable, then tables newest-first. Returns a
# MALLOC'D NUL-terminated copy (caller frees; length via len_out —
# values may be binary) or 0 with len_out 0 when the key is absent or
# tombstoned.
char* lsm_get(lsm* l, char* key, int* len_out):
	char** value_out = cast(char**, malloc(__word_size__))
	int* vlen = cast(int*, malloc(__word_size__))
	char* result = 0
	int decided = 0
	int state = memtable_get(l.mem, key, value_out, vlen)
	if (state == 1):
		# memtable values are borrowed; copy for the uniform contract
		result = lsm_copy_bytes(value_out[0], vlen[0])
		len_out[0] = vlen[0]
		decided = 1
	if (state == 2):
		decided = 1
	if (decided == 0):
		int i = l.tables.length - 1
		while (i >= 0 && decided == 0):
			sstable* t = l.tables[i]
			state = sstable_get(t, key, value_out, vlen)
			if (state == 1):
				result = value_out[0]
				len_out[0] = vlen[0]
				decided = 1
			if (state == 2):
				decided = 1
			i = i - 1
	if (result == 0):
		len_out[0] = 0
	free(cast(char*, value_out))
	free(cast(char*, vlen))
	return result


# ---- compaction -----------------------------------------------------------------

# Full compaction: k-way merge of ALL tables (not the memtable —
# lsm_flush first to include it) into one new table; ties go to the
# newest table, tombstones are dropped entirely. See the header for
# the manifest-rewrite crash window and the orphaned old files.
# Returns 1 (no-op when there are no tables), 0 on I/O failure.
int lsm_compact(lsm* l):
	int n = l.tables.length
	if (n == 0):
		return 1
	char* path = lsm_table_path(l.prefix, l.next_seq)
	sstable_writer* w = sstable_writer_new(path)
	if (cast(int, w) == 0):
		free(path)
		return 0
	list[int] cursors = new list[int]
	int i = 0
	while (i < n):
		cursors.push(0)
		i = i + 1
	int* len_out = cast(int*, malloc(__word_size__))
	int merging = 1
	while (merging):
		# smallest key among the cursors; scanning oldest→newest with
		# <= means an equal key from a newer table displaces the older
		int best = 0 - 1
		char* best_key = 0
		i = 0
		while (i < n):
			sstable* t = l.tables[i]
			if (cursors[i] < sstable_count(t)):
				char* k = sstable_key_at(t, cursors[i])
				if (best < 0 || strcmp(k, best_key) <= 0):
					best = i
					best_key = k
			i = i + 1
		if (best < 0):
			merging = 0
		else:
			sstable* winner = l.tables[best]
			if (sstable_is_tombstone_at(winner, cursors[best]) == 0):
				char* val = sstable_value_at(winner, cursors[best], len_out)
				sstable_writer_add(w, best_key, val, len_out[0], 0)
				free(val)
			# advance every cursor sitting on this key: the winner and
			# every older shadowed version of it
			i = 0
			while (i < n):
				sstable* older = l.tables[i]
				if (cursors[i] < sstable_count(older)):
					if (strcmp(sstable_key_at(older, cursors[i]), best_key) == 0):
						cursors[i] = cursors[i] + 1
				i = i + 1
	free(cast(char*, len_out))
	if (sstable_writer_finish(w) == 0):
		free(path)
		return 0
	sstable* merged = sstable_open(path)
	if (cast(int, merged) == 0):
		free(path)
		return 0
	int seq = l.next_seq
	l.next_seq = l.next_seq + 1
	# swap in the merged table; the old files stay on disk orphaned
	# (lib has no unlink) but the manifest no longer references them
	i = 0
	while (i < l.tables.length):
		sstable* old = l.tables[i]
		sstable_close(old)
		free(l.table_paths[i])
		i = i + 1
	l.tables = new list[sstable*]
	l.table_paths = new list[char*]
	l.tables.push(merged)
	l.table_paths.push(path)
	if (wal_reset(l.manifest) == 0):
		return 0
	if (lsm_manifest_append_table(l.manifest, seq) == 0):
		return 0
	return 1


# ---- stats ----------------------------------------------------------------------

int lsm_sstable_count(lsm* l):
	return l.tables.length


int lsm_memtable_count(lsm* l):
	return memtable_count(l.mem)


int lsm_memtable_bytes(lsm* l):
	return memtable_bytes(l.mem)


# Raw record total across every tier — shadowing and tombstones NOT
# resolved (compaction shrinks this; reads do not).
int lsm_total_entries(lsm* l):
	int total = memtable_count(l.mem)
	int i = 0
	while (i < l.tables.length):
		sstable* t = l.tables[i]
		total = total + sstable_count(t)
		i = i + 1
	return total
