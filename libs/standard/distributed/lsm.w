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
     a later flush cannot bury it in non-last position, the dangling
     table file (if the crash left one) is unlinked once that rewrite
     succeeded, and the dangling seq still advances next_seq so its
     file path is never reused.
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
this phase targets. Only after the manifest rewrite has succeeded
are the superseded table files unlinked — manifest first, so a crash
between the two can only leak unreferenced files, never lose data.

Single-writer assumption throughout: one lsm owns its prefix.

Full-scan export/import (issue #314, KV/LSM snapshot integration): a
merged, newest-wins, tombstone-free scan across the memtable and every
sstable — the source raft snapshots compact the log around. lsm_export
runs the same oldest-to-newest k-way merge lsm_compact uses across the
tables, with the memtable folded in as one extra, always-newest source
(so it shadows every table, matching lsm_get's own read order), and
serializes the survivors; tombstones are dropped entirely, same as a
full compaction — an export is a point-in-time snapshot of live keys,
not a change log. lsm_import validates a whole blob before touching
l (a malformed inbound snapshot must not corrupt a good tree), then
lsm_clears l and replays every record through lsm_put.

Chosen over an iterator (the T_iter_begin/next/done cursor protocol
containers use) because the only consumer is "hand raft_take_snapshot
one buffer": every caller would just drain an iterator into a byte
buffer anyway, so lsm_export does that once, inside the tree's own
internals, instead of exposing live cursor state across two storage
tiers (memtable + open sstable file descriptors) to every caller.

Export blob format ("LSMX", little-endian; unrelated to the wal/
manifest/sstable on-disk formats above — this one never touches disk
itself, it is just the bytes handed to raft_take_snapshot):
  offset 0: 4-byte magic "LSMX", 4-byte format version (1)
  4-byte record count
  then records, each: key_len u32, key bytes, value_len u32, value bytes
Values are opaque and binary-safe (embedded NUL legal, issue #315);
keys are the usual NUL-terminated TEXT every lsm/memtable/sstable key
already is, length-prefixed here too rather than relying on strlen.
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
	# so the next recovery never sees it in non-last position, then
	# reclaim the dangling table file itself. Manifest FIRST, unlink
	# SECOND, same discipline as lsm_compact: a crash between the two
	# at worst leaks one unreferenced file. (Here either order would
	# be crash-safe — the dangling entry's data is by construction
	# still in the data wal — but keeping the one ordering invariant
	# everywhere is cheaper than reasoning per-site.) The unlink
	# result is ignored: the crash may have happened before the table
	# file ever existed, and a leaked orphan is harmless.
	if (fail == 0 && dropped == 1):
		if (wal_reset(mlog) == 0):
			fail = 1
		i = 0
		while (i < tables.length && fail == 0):
			if (lsm_manifest_append_table(mlog, seqs[i]) == 0):
				fail = 1
			i = i + 1
		if (fail == 0):
			char* dangling = lsm_table_path(own_prefix, seqs[seqs.length - 1])
			unlink(dangling)
			free(dangling)
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
# newest table, tombstones are dropped entirely. The superseded table
# files are unlinked only AFTER the manifest rewrite succeeds (see
# the ORDERING comment below and the header's crash-window notes).
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
	# swap in the merged table, KEEPING the superseded paths: they may
	# only be unlinked after the manifest rewrite below has succeeded
	list[char*] old_paths = new list[char*]
	i = 0
	while (i < l.tables.length):
		sstable* old = l.tables[i]
		sstable_close(old)
		old_paths.push(l.table_paths[i])
		i = i + 1
	l.tables = new list[sstable*]
	l.table_paths = new list[char*]
	l.tables.push(merged)
	l.table_paths.push(path)
	# ORDERING: manifest FIRST, unlink SECOND. Until the rewritten
	# manifest references only the merged table, the old files are the
	# durable copy of their data — unlinking them earlier would lose
	# data if we crashed before the rewrite landed. This way a crash
	# (or a failed rewrite, ok == 0 below) can at worst LEAK files the
	# manifest no longer references, never lose data; failed unlinks
	# are ignored for the same reason.
	int ok = 1
	if (wal_reset(l.manifest) == 0):
		ok = 0
	if (ok == 1 && lsm_manifest_append_table(l.manifest, seq) == 0):
		ok = 0
	i = 0
	while (i < old_paths.length):
		if (ok == 1):
			unlink(old_paths[i])
		free(old_paths[i])
		i = i + 1
	return ok


# ---- export / import (full-scan snapshot surface, issue #314) ---------------

int lsm_export_version():
	return 1


# Merge-source count: every table plus the memtable, which is always
# the LAST (newest) source — see the header's tie-break note.
int lsm_export_sources(lsm* l):
	return l.tables.length + 1


int lsm_export_count_at(lsm* l, int src):
	if (src < l.tables.length):
		return sstable_count(l.tables[src])
	return memtable_count(l.mem)


char* lsm_export_key_at(lsm* l, int src, int i):
	if (src < l.tables.length):
		return sstable_key_at(l.tables[src], i)
	return memtable_key_at(l.mem, i)


int lsm_export_tombstone_at(lsm* l, int src, int i):
	if (src < l.tables.length):
		return sstable_is_tombstone_at(l.tables[src], i)
	return memtable_is_tombstone_at(l.mem, i)


# Malloc'd copy either way: sstable_value_at already reads a fresh
# malloc'd copy from disk; memtable_value_at's pointer is borrowed, so
# it is copied here too, letting the merge loop below free every
# collected value uniformly.
char* lsm_export_value_at(lsm* l, int src, int i, int* len_out):
	if (src < l.tables.length):
		return sstable_value_at(l.tables[src], i, len_out)
	char* borrowed = memtable_value_at(l.mem, i, len_out)
	return lsm_copy_bytes(borrowed, len_out[0])


# Full-scan export: the same k-way merge lsm_compact runs across every
# table, with the memtable folded in as the newest source, tombstones
# DROPPED entirely (see the header). Returns a malloc'd "LSMX" blob
# (len_out gets its length; byte format in the header) — an empty tree
# exports a valid 12-byte header-only blob with a zero record count.
char* lsm_export(lsm* l, int* len_out):
	int n = lsm_export_sources(l)
	list[int] cursors = new list[int]
	int i = 0
	while (i < n):
		cursors.push(0)
		i = i + 1
	list[char*] keys = new list[char*]
	list[char*] vals = new list[char*]
	list[int] vlens = new list[int]
	int* vl = cast(int*, malloc(__word_size__))
	int merging = 1
	while (merging):
		# smallest key among the cursors; scanning oldest->newest with
		# <= means an equal key from a newer source (a later index —
		# the memtable, index n - 1, sorts last) displaces the older
		int best = 0 - 1
		char* best_key = 0
		i = 0
		while (i < n):
			if (cursors[i] < lsm_export_count_at(l, i)):
				char* k = lsm_export_key_at(l, i, cursors[i])
				if (best < 0 || strcmp(k, best_key) <= 0):
					best = i
					best_key = k
			i = i + 1
		if (best < 0):
			merging = 0
		else:
			if (lsm_export_tombstone_at(l, best, cursors[best]) == 0):
				char* val = lsm_export_value_at(l, best, cursors[best], vl)
				keys.push(lsm_copy_bytes(best_key, strlen(best_key)))
				vals.push(val)
				vlens.push(vl[0])
			# advance every cursor sitting on this key: the winner and
			# every older shadowed version of it
			i = 0
			while (i < n):
				if (cursors[i] < lsm_export_count_at(l, i)):
					if (strcmp(lsm_export_key_at(l, i, cursors[i]), best_key) == 0):
						cursors[i] = cursors[i] + 1
				i = i + 1
	free(cast(char*, vl))
	int total = 12
	i = 0
	while (i < keys.length):
		total = total + 4 + strlen(keys[i]) + 4 + vlens[i]
		i = i + 1
	char* buf = malloc(total)
	buf[0] = 76   # L
	buf[1] = 83   # S
	buf[2] = 77   # M
	buf[3] = 88   # X
	wal_put_le32(buf + 4, lsm_export_version())
	wal_put_le32(buf + 8, keys.length)
	int off = 12
	i = 0
	while (i < keys.length):
		char* k = keys[i]
		int klen = strlen(k)
		wal_put_le32(buf + off, klen)
		off = off + 4
		int j = 0
		while (j < klen):
			buf[off + j] = k[j]
			j = j + 1
		off = off + klen
		wal_put_le32(buf + off, vlens[i])
		off = off + 4
		char* v = vals[i]
		j = 0
		while (j < vlens[i]):
			buf[off + j] = v[j]
			j = j + 1
		off = off + vlens[i]
		free(k)
		free(v)
		i = i + 1
	len_out[0] = total
	return buf


# Wipes l back to an empty tree: manifest reset FIRST (so the rewrite
# is the durable truth before any table file disappears — the same
# ordering discipline as lsm_compact/lsm_open), every table file
# unlinked, the memtable cleared, and the data wal reset. next_seq is
# left untouched so a table path is never reused (lsm_open's dangling-
# entry rule). Returns 0 on any I/O failure; lsm_import only calls
# this after fully validating the incoming blob, so a failure here is
# a bare-disk problem, not a bad snapshot.
int lsm_clear(lsm* l):
	if (wal_reset(l.manifest) == 0):
		return 0
	int i = 0
	while (i < l.tables.length):
		sstable_close(l.tables[i])
		i = i + 1
	i = 0
	while (i < l.table_paths.length):
		unlink(l.table_paths[i])
		free(l.table_paths[i])
		i = i + 1
	l.tables = new list[sstable*]
	l.table_paths = new list[char*]
	if (wal_reset(l.log) == 0):
		return 0
	memtable_clear(l.mem)
	return 1


# Rebuilds l from an lsm_export blob: validates the ENTIRE buffer
# first (magic, version, every record's lengths in bounds) so a
# malformed blob leaves l untouched, only then lsm_clear(l)s and
# replays each record through lsm_put. Returns 0 on a malformed blob
# (l untouched) or an lsm_clear/lsm_put I/O failure once the clear has
# already started (l may then be partially imported — see lsm_clear's
# header). This is the receiver-side half of the raft snapshot
# handoff: kv_state.w's kv_install_snapshot calls this with the blob
# raft_take_pending_snapshot hands the state machine.
int lsm_import(lsm* l, char* blob, int len):
	if (len < 12):
		return 0
	if ((blob[0] & 255) != 76 || (blob[1] & 255) != 83 || (blob[2] & 255) != 77 || (blob[3] & 255) != 88):
		return 0
	if (wal_get_le32(blob + 4) != lsm_export_version()):
		return 0
	int count = wal_get_le32(blob + 8)
	if (count < 0):
		return 0
	list[int] key_off = new list[int]
	list[int] key_len = new list[int]
	list[int] val_off = new list[int]
	list[int] val_len = new list[int]
	int off = 12
	int i = 0
	while (i < count):
		if (len - off < 4):
			return 0
		int klen = wal_get_le32(blob + off)
		if (klen < 0 || klen > len - off - 4):
			return 0
		key_off.push(off + 4)
		key_len.push(klen)
		off = off + 4 + klen
		if (len - off < 4):
			return 0
		int vlen = wal_get_le32(blob + off)
		if (vlen < 0 || vlen > len - off - 4):
			return 0
		val_off.push(off + 4)
		val_len.push(vlen)
		off = off + 4 + vlen
		i = i + 1
	if (off != len):
		return 0
	if (lsm_clear(l) == 0):
		return 0
	i = 0
	while (i < count):
		char* key = lsm_copy_bytes(blob + key_off[i], key_len[i])
		int ok = lsm_put(l, key, blob + val_off[i], val_len[i])
		free(key)
		if (ok == 0):
			return 0
		i = i + 1
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
