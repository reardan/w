/*
Log-structured merge tree tying the three storage tiers together
(docs/projects/distributed.md, phase 4; Bigtable §5.3; durability
contracts: docs/projects/reliable_services.md, stage W1a):

  wal.w       durability — every mutation is appended to a data wal
              BEFORE it touches memory
  memtable.w  the mutable tier — sorted in-memory buffer, tombstones
  sstable.w   the immutable tier — flushed and compacted tables

All of an lsm's files live under one caller-supplied path prefix (a
filename stem, not a directory; the files share its directory):

  <prefix>.wal        data wal (mutations since the last flush)
  <prefix>.manifest   manifest wal (which sstables exist, in order)
  <prefix>.sst<seq>   one immutable sstable per flush/compaction/import
  <prefix>.wal.next, <prefix>.manifest.next
                      transient rewrite siblings (wal.w); a leftover
                      one is an uncommitted rewrite, deleted on open

Data wal record encoding (little-endian, one record per mutation):
  tag u8 1 PUT:    key_len u32, val_len u32, key bytes, value bytes
  tag u8 2 DELETE: key_len u32, key bytes
  tag u8 3 EPOCH:  epoch u32 — only ever the FIRST record (see below)
  tag u8 4 BATCH:  count u32, then count ops, each: op u8 (1 put,
                   2 delete), key_len u32, val_len u32 (0 for a
                   delete), key bytes, value bytes
Manifest record encoding:
  tag u8 1 ADD-TABLE: seq u32 — the table file "<prefix>.sst<seq>"
  tag u8 2 EPOCH:     epoch u32 — only ever the FIRST record
A tree that never installed a snapshot has epoch 0 and writes no EPOCH
records, so the format is unchanged for it.

Write path: append the wal record first (a failed append fails the
whole operation and mutates nothing), then upsert the memtable. When
memtable_bytes exceeds the configured limit the memtable auto-flushes.
lsm_put/lsm_delete survive a process crash once they return; lsm_sync
(fsync of the data wal) makes them survive a machine crash. A BATCH
record (lsm_apply_batch) is one checksummed wal record, so recovery
applies all of its operations or none of them.

Read path: memtable first (its three-way contract decides: found
returns a MALLOC'D COPY so every lsm_get result is caller-freed
uniformly; tombstone stops the search), then the sstables NEWEST
FIRST (highest list index first). Tables are held oldest-first in
l.tables, parallel to l.table_paths. lsm_get_status reports a failed
table read as LSM_GET_ERROR; lsm_get keeps its pointer contract and
treats that as fatal.

Flush ordering (the crash windows are the point):
  1. write "<prefix>.sst<next_seq>" completely; sstable_writer_finish
     fsyncs the file AND its directory entry before returning
  2. append ADD-TABLE(seq) to the manifest and wal_sync the manifest
  3. only then reset the data wal (a durable wal_rewrite_commit to an
     empty log carrying the current EPOCH) and clear the memtable
A crash before 2 is durable leaves an orphan table file the manifest
never references — the data is still in the data wal and replays. A
crash between 2 and 3 replays the data wal INTO a state that already
has the table: harmless, memtable upserts are idempotent and the
memtable shadows the equal values below it.

Manifest replacement (compaction, recovery's dangling-entry drop,
snapshot install) never resets the live manifest in place: the new
manifest is written to "<prefix>.manifest.next", fsynced, renamed
over the live one and the directory fsynced (wal.w's rewrite). A
crash at any stage leaves the complete old manifest or the complete
new one. Table files the old manifest named are unlinked only after
the new manifest is durable, so a crash can at worst leak files no
manifest references, never lose data.

Generations (snapshot install, lsm_import / lsm_clear): the
replacement is built completely before the live reference switches:
  1. write the snapshot's records into a new table (durable, step 1
     of a flush)
  2. publish a new manifest [EPOCH e+1, ADD-TABLE(new)] — THE switch
  3. reset the data wal to [EPOCH e+1], swap the in-memory tiers,
     unlink the old generation's tables
A failure or crash before 2 leaves the old generation (tables,
manifest, data wal) untouched and the new table is deleted (or leaks,
after a crash). After 2, the data wal still carries epoch e until 3
finishes: recovery sees its EPOCH (absent = 0) is older than the
manifest's, recognizes it as the superseded generation's log, and
discards it (resetting it to the new epoch) instead of replaying old
mutations on top of the snapshot.

Recovery (lsm_open):
  1. open both wals under the recovery policy (lsm_open: WAL_RECOVER_
     STRICT_TRUNCATE — a torn, never-synced tail is cut off, while
     corruption inside a log fails the open; lsm_open_policy chooses
     another and reports the scan). Replay the manifest; sstable_open
     every referenced table. A missing/corrupt table is a hard failure
     (returns 0) EXCEPT when it is the LAST manifest entry: that is the
     flush crash window between table write and manifest sync, so the
     entry is DROPPED — its data is still in the data wal. The
     manifest is republished without the dangling entry so a later
     flush cannot bury it in non-last position, the dangling table
     file (if the crash left one) is unlinked once that publish is
     durable, and the dangling seq still advances next_seq so its file
     path is never reused.
  2. replay the data wal into a fresh memtable — unless its EPOCH is
     older than the manifest's (see Generations).
  3. next_seq = max(every seq the manifest referenced) + 1; 1 for a
     fresh tree.

Failures are checked, never asserted: every mutating call returns 0 on
an I/O failure. A failure that leaves memory and disk possibly out of
step (a failed manifest sync, a replacement whose rename happened but
whose directory sync failed, a failed data-wal reset) also marks the
tree failed (lsm_failed): later mutations return 0 until it is closed
and reopened, which recovers from what is durably on disk. A failure
that provably changed nothing (a table write that never got
referenced, a replacement that failed before its rename) leaves the
tree usable.

Compaction (lsm_compact) is full: a k-way merge across ALL tables
(the memtable is NOT included — lsm_flush first to fold it in). The
newest table wins ties; tombstones are dropped entirely (nothing
older than a full compaction can be shadowed); the survivors become
the single table "<prefix>.sst<next_seq>" — written even when empty,
preserving the one-table-after-compact invariant — and the manifest
is replaced by [EPOCH, ADD-TABLE(new)] as described above.

Single-writer assumption throughout: one lsm owns its prefix.

Reading the whole tree: lsm_scan is a bounded, resumable ordered
iterator — at most max_entries live records and about max_bytes of
key+value bytes per page, from a start key, with a resume key for the
next page — so a consumer never has to hold the whole store in one
allocation. Pages see the live tree: writes between pages are visible
to later pages (a page itself is consistent).

Full-scan export/import (issue #314, KV/LSM snapshot integration): a
merged, newest-wins, tombstone-free scan across the memtable and every
sstable — the source raft snapshots compact the log around. lsm_export
runs the same oldest-to-newest k-way merge lsm_compact and lsm_scan
use across the tables, with the memtable folded in as one extra,
always-newest source (so it shadows every table, matching lsm_get's
own read order), and serializes the survivors; tombstones are dropped
entirely, same as a full compaction — an export is a point-in-time
snapshot of live keys, not a change log. lsm_import validates a whole
blob before touching l (a malformed inbound snapshot must not corrupt a
good tree), then installs it as a new generation (above).

Export blob format ("LSMX", little-endian; unrelated to the wal/
manifest/sstable on-disk formats above — this one never touches disk
itself, it is just the bytes handed to raft_take_snapshot):
  offset 0: 4-byte magic "LSMX", 4-byte format version (1)
  4-byte record count
  then records, each: key_len u32, key bytes, value_len u32, value bytes
Records are strictly ascending by key (lsm_import rejects any other
order). Values are opaque and binary-safe (embedded NUL legal, issue
#315); keys are the usual NUL-terminated TEXT every lsm/memtable/
sstable key already is, length-prefixed here too rather than relying
on strlen (a key containing NUL is rejected on import).
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.wal
import libs.standard.distributed.memtable
import libs.standard.distributed.sstable
import lib.bytes
import lib.mem
import lib.io
import lib.fs


struct lsm:
	file_ops* ops
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
	int epoch                 # generation (header); 0 until a snapshot install
	int failed                # sticky: memory and disk may disagree (header)


# ---- record tags ------------------------------------------------------------

const int lsm_tag_put = 1
const int lsm_tag_delete = 2
const int lsm_tag_data_epoch = 3
const int lsm_tag_batch = 4
const int lsm_tag_add_table = 1
const int lsm_tag_manifest_epoch = 2

# lsm_get_status results.
const int LSM_GET_ABSENT = 0
const int LSM_GET_FOUND = 1
const int LSM_GET_ERROR = -1


# ---- small helpers ----------------------------------------------------------

# "<prefix>.sst<seq>", malloc'd; caller frees (or hands to table_paths).
char* lsm_table_path(char* prefix, int seq):
	char* num = itoa(seq)
	char* stem = strjoin(prefix, c".sst")
	char* path = strjoin(stem, num)
	free(stem)
	free(num)
	return path


# Appends one 5-byte (tag, u32) record. Returns wal_append's result.
int lsm_append_tagged(wal* target, int tag, int value):
	char* rec = cast(char*, malloc(5))
	rec[0] = tag
	store_le32(rec + 1, value)
	int ok = wal_append(target, rec, 5)
	free(rec)
	return ok


# Appends one ADD-TABLE(seq) record to the manifest wal. Returns
# wal_append's result (1 ok, 0 short write).
int lsm_manifest_append_table(wal* mlog, int seq):
	return lsm_append_tagged(mlog, lsm_tag_add_table, seq)


void lsm_report_reset(fs_replace_report* rep):
	rep.status = IO_OK
	rep.native_error = 0
	rep.stage = FS_STAGE_NONE
	rep.renamed = 0
	rep.transferred = 0


# Durably replaces the manifest with [EPOCH epoch (when > 0), ADD-TABLE
# per seq] through a rewrite sibling (wal.w). Returns IO_OK or the
# failing status; rep.renamed says whether the live manifest already
# switched (header: "Manifest replacement").
int lsm_publish_manifest(wal* mlog, int epoch, list[int] seqs, fs_replace_report* rep):
	lsm_report_reset(rep)
	wal* next = wal_rewrite_begin(mlog)
	if (cast(int, next) == 0):
		rep.stage = FS_STAGE_OPEN_TEMP
		rep.status = IO_IO_ERROR
		return IO_IO_ERROR
	int ok = 1
	if (epoch > 0): ok = lsm_append_tagged(next, lsm_tag_manifest_epoch, epoch)
	int i = 0
	while (ok == 1 && i < seqs.length):
		ok = lsm_manifest_append_table(next, seqs[i])
		i = i + 1
	if (ok == 0):
		wal_rewrite_abort(next)
		rep.stage = FS_STAGE_WRITE
		rep.status = IO_IO_ERROR
		return IO_IO_ERROR
	return wal_rewrite_commit(mlog, next, rep)


# Durably resets the data wal to [EPOCH epoch] (empty when epoch is 0).
int lsm_publish_data_wal(wal* dlog, int epoch, fs_replace_report* rep):
	lsm_report_reset(rep)
	wal* next = wal_rewrite_begin(dlog)
	if (cast(int, next) == 0):
		rep.stage = FS_STAGE_OPEN_TEMP
		rep.status = IO_IO_ERROR
		return IO_IO_ERROR
	if (epoch > 0 && lsm_append_tagged(next, lsm_tag_data_epoch, epoch) == 0):
		wal_rewrite_abort(next)
		rep.stage = FS_STAGE_WRITE
		rep.status = IO_IO_ERROR
		return IO_IO_ERROR
	return wal_rewrite_commit(dlog, next, rep)


# Applies one decoded batch (already validated) to the memtable.
void lsm_apply_batch_payload(memtable* m, char* p):
	int count = load_le32(p + 1)
	int off = 5
	int i = 0
	while (i < count):
		int op = p[off] & 255
		int klen = load_le32(p + off + 1)
		int vlen = load_le32(p + off + 5)
		char* key = mem_dup(p + off + 9, klen)
		if (op == lsm_tag_put): memtable_put(m, key, p + off + 9 + klen, vlen)
		else: memtable_delete(m, key)
		free(key)
		off = off + 9 + klen + vlen
		i = i + 1


# 1 when p[0..len) is a well-formed BATCH payload.
int lsm_batch_payload_valid(char* p, int len):
	if (len < 5): return 0
	int count = load_le32(p + 1)
	if (count < 0): return 0
	int off = 5
	int i = 0
	while (i < count):
		if (len - off < 9): return 0
		int op = p[off] & 255
		int klen = load_le32(p + off + 1)
		int vlen = load_le32(p + off + 5)
		if (op != lsm_tag_put && op != lsm_tag_delete): return 0
		if (klen < 0 || klen > len - off - 9): return 0
		if (vlen < 0 || vlen > len - off - 9 - klen): return 0
		if (op == lsm_tag_delete && vlen != 0): return 0
		off = off + 9 + klen + vlen
		i = i + 1
	return off == len


# Fold one data-wal record into the recovering memtable. Returns 1, or
# 0 for a malformed payload: the wal's checksum already rejected torn
# or corrupt records, so a malformed payload means a foreign writer and
# lsm_open refuses the tree. (EPOCH is handled by the caller: it is
# only legal as the first record.)
int lsm_replay_data_record(memtable* m, char* p, int len):
	if (len < 1): return 0
	int tag = p[0] & 255
	if (tag == lsm_tag_put):
		if (len < 9): return 0
		int key_len = load_le32(p + 1)
		int val_len = load_le32(p + 5)
		if (key_len < 0 || val_len < 0 || key_len > len - 9 || len != 9 + key_len + val_len): return 0
		char* key = mem_dup(p + 9, key_len)
		memtable_put(m, key, p + 9 + key_len, val_len)
		free(key)
		return 1
	if (tag == lsm_tag_delete):
		if (len < 5): return 0
		int dkey_len = load_le32(p + 1)
		if (dkey_len < 0 || len != 5 + dkey_len): return 0
		char* dkey = mem_dup(p + 5, dkey_len)
		memtable_delete(m, dkey)
		free(dkey)
		return 1
	if (tag == lsm_tag_batch):
		if (lsm_batch_payload_valid(p, len) == 0): return 0
		lsm_apply_batch_payload(m, p)
		return 1
	return 0


# ---- lifecycle ----------------------------------------------------------------

void lsm_free_tables(list[sstable*] tables, list[char*] table_paths):
	int i = 0
	while (i < tables.length):
		sstable* t = tables[i]
		sstable_close(t)
		i = i + 1
	i = 0
	while (i < table_paths.length):
		free(table_paths[i])
		i = i + 1
	tables.free()
	table_paths.free()


# Opens (creating if missing) the tree at prefix and recovers it under
# the wal recovery policy (header): the manifest names the live tables,
# the data wal rebuilds the memtable. rep (may be 0) receives the scan
# report of the last log opened — the data wal's, or the manifest's
# when the manifest itself could not be opened. Returns 0 on any
# unrecoverable failure (unopenable or corrupt wal, foreign manifest or
# data record, a missing/corrupt table that is not the last manifest
# entry, a data wal from a NEWER epoch than the manifest), with
# everything that was opened closed again.
lsm* lsm_open_policy_with_ops(file_ops* ops, char* prefix, int memtable_limit_bytes, int policy, wal_recovery* rep):
	char* own_prefix = mem_dup(prefix, strlen(prefix))
	char* wpath = strjoin(own_prefix, c".wal")
	char* mpath = strjoin(own_prefix, c".manifest")
	wal* mlog = wal_open_policy_with_ops(ops, mpath, policy, rep)
	if (cast(int, mlog) == 0):
		free(mpath)
		free(wpath)
		free(own_prefix)
		return 0
	int len = 0
	int fail = 0
	# 1. manifest replay: an optional leading EPOCH, then the
	# referenced seqs in log order
	int epoch = 0
	int index = 0
	list[int] seqs = new list[int]
	wal_reader* mrd = wal_reader_open_with_ops(ops, mpath)
	if (cast(int, mrd) == 0): fail = 1
	else:
		char* mp = wal_read_next(mrd, &len)
		while (mp != 0):
			int tag = mp[0] & 255
			if (len == 5 && tag == lsm_tag_add_table): seqs.push(load_le32(mp + 1))
			else if (len == 5 && tag == lsm_tag_manifest_epoch && index == 0): epoch = load_le32(mp + 1)
			else: fail = 1
			free(mp)
			index = index + 1
			mp = wal_read_next(mrd, &len)
		if (mrd.failed): fail = 1
		wal_reader_close(mrd)
	# 2. open every referenced table; only the LAST entry may dangle
	list[sstable*] tables = new list[sstable*]
	list[char*] table_paths = new list[char*]
	int dropped = 0
	int i = 0
	while (i < seqs.length && fail == 0):
		char* tpath = lsm_table_path(own_prefix, seqs[i])
		int io_failed = 0
		sstable* t = sstable_open_report(ops, tpath, &io_failed)
		if (cast(int, t) == 0):
			free(tpath)
			if (i == seqs.length - 1 && io_failed == 0): dropped = 1
			else: fail = 1
		else:
			tables.push(t)
			table_paths.push(tpath)
		i = i + 1
	# 3. dangling last entry dropped: republish the manifest without it
	# so the next recovery never sees it in non-last position, then
	# reclaim the dangling table file itself. Manifest FIRST (durably),
	# unlink SECOND, same discipline as lsm_compact. The unlink result
	# is ignored: the crash may have happened before the table file
	# ever existed, and a leaked orphan is harmless.
	if (fail == 0 && dropped == 1):
		list[int] kept = new list[int]
		i = 0
		while (i < tables.length):
			kept.push(seqs[i])
			i = i + 1
		fs_replace_report prep
		if (lsm_publish_manifest(mlog, epoch, kept, &prep) != IO_OK): fail = 1
		else:
			char* dangling = lsm_table_path(own_prefix, seqs[seqs.length - 1])
			storage_unlink(ops, dangling)
			free(dangling)
	# 4. next_seq: one past every seq ever referenced (the dangling
	# one included, so its file path is never reused)
	int next_seq = 1
	i = 0
	while (i < seqs.length):
		if (seqs[i] >= next_seq): next_seq = seqs[i] + 1
		i = i + 1
	# 5. data wal, replayed into a fresh memtable unless it belongs to
	# a superseded generation (header: "Generations")
	wal* dlog = 0
	if (fail == 0):
		dlog = wal_open_policy_with_ops(ops, wpath, policy, rep)
		if (cast(int, dlog) == 0): fail = 1
	memtable* mem = memtable_new()
	int stale = 0
	if (fail == 0):
		wal_reader* drd = wal_reader_open_with_ops(ops, wpath)
		if (cast(int, drd) == 0): fail = 1
		else:
			index = 0
			char* dp = wal_read_next(drd, &len)
			while (dp != 0):
				int is_epoch = 0
				if (index == 0 && len == 5 && (dp[0] & 255) == lsm_tag_data_epoch): is_epoch = 1
				if (index == 0):
					int data_epoch = 0
					if (is_epoch): data_epoch = load_le32(dp + 1)
					if (data_epoch > epoch): fail = 1
					if (data_epoch < epoch): stale = 1
				if (fail == 0 && stale == 0 && is_epoch == 0):
					if (lsm_replay_data_record(mem, dp, len) == 0): fail = 1
				free(dp)
				index = index + 1
				dp = wal_read_next(drd, &len)
			if (drd.failed): fail = 1
			wal_reader_close(drd)
		if (index == 0 && epoch > 0): stale = 1
	if (fail == 0 && stale == 1):
		fs_replace_report drep
		if (lsm_publish_data_wal(dlog, epoch, &drep) != IO_OK): fail = 1
	if (fail == 1):
		lsm_free_tables(tables, table_paths)
		memtable_free(mem)
		if (cast(int, dlog) != 0): wal_close(dlog)
		wal_close(mlog)
		free(mpath)
		free(wpath)
		free(own_prefix)
		return 0
	lsm* l = new lsm()
	l.ops = ops
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
	l.epoch = epoch
	l.failed = 0
	return l


# Native convenience wrapper; injected constructors borrow their ops.
lsm* lsm_open_policy(char* prefix, int memtable_limit_bytes, int policy, wal_recovery* rep):
	return lsm_open_policy_with_ops(cast(file_ops*, 0), prefix, memtable_limit_bytes, policy, rep)


lsm* lsm_open(char* prefix, int memtable_limit_bytes):
	return lsm_open_policy(prefix, memtable_limit_bytes, WAL_RECOVER_STRICT_TRUNCATE, cast(wal_recovery*, 0))


# Closes both wals and every table, then frees everything the lsm
# owns (memtable, path strings, l itself). No implicit flush: data
# not flushed stays in the data wal and replays on the next open.
void lsm_close(lsm* l):
	wal_close(l.log)
	wal_close(l.manifest)
	lsm_free_tables(l.tables, l.table_paths)
	memtable_free(l.mem)
	free(l.wal_path)
	free(l.manifest_path)
	free(l.prefix)
	free(l)


# 1 once a failure left memory and disk possibly out of step (header);
# mutations then return 0 until the tree is reopened.
int lsm_failed(lsm* l):
	return l.failed


int lsm_fail(lsm* l):
	l.failed = 1
	return 0


# fsync the data wal: every lsm_put/lsm_delete/lsm_apply_batch that
# returned 1 before this call survives a machine crash once it returns
# 1. A failure marks the tree failed.
int lsm_sync(lsm* l):
	if (l.failed): return 0
	if (wal_sync(l.log) == 0): return lsm_fail(l)
	return 1


# ---- flush --------------------------------------------------------------------

# Writes the memtable — tombstones included, they must keep shadowing
# older tables — to "<prefix>.sst<next_seq>" (durable with its
# directory entry), appends ADD-TABLE to the manifest and syncs it,
# then durably resets the data wal and clears the memtable (in that
# order; see the header's crash-window notes). Empty memtable is a
# no-op returning 1. Returns 0 on any I/O failure.
int lsm_flush(lsm* l):
	if (l.failed): return 0
	int count = memtable_count(l.mem)
	if (count == 0): return 1
	char* path = lsm_table_path(l.prefix, l.next_seq)
	sstable_writer* w = sstable_writer_new_with_ops(l.ops, path)
	if (cast(int, w) == 0):
		free(path)
		return 0
	int vlen = 0
	for i in range(count):
		char* key = memtable_key_at(l.mem, i)
		if (memtable_is_tombstone_at(l.mem, i)): sstable_writer_add(w, key, cast(char*, 0), 0, 1)
		else:
			char* val = memtable_value_at(l.mem, i, &vlen)
			sstable_writer_add(w, key, val, vlen, 0)
	# 1. the table, durable with its directory entry; until the
	# manifest names it, a failure here changed nothing
	if (sstable_writer_finish(w) == 0):
		storage_unlink(l.ops, path)
		free(path)
		return 0
	sstable* t = sstable_open_with_ops(l.ops, path)
	if (cast(int, t) == 0):
		storage_unlink(l.ops, path)
		free(path)
		return 0
	# 2. the manifest record, synced. On failure the record may or may
	# not be durable, so the (durable) table file stays for recovery
	if (lsm_manifest_append_table(l.manifest, l.next_seq) == 0 || wal_sync(l.manifest) == 0):
		sstable_close(t)
		free(path)
		return lsm_fail(l)
	l.tables.push(t)
	l.table_paths.push(path)
	l.next_seq = l.next_seq + 1
	# 3. only now the data wal reset
	fs_replace_report rep
	int status = lsm_publish_data_wal(l.log, l.epoch, &rep)
	if (status == IO_OK || rep.renamed == 1): memtable_clear(l.mem)
	if (status != IO_OK): return lsm_fail(l)
	return 1


# ---- mutations ------------------------------------------------------------------

# Appends rec to the data wal: 1, or 0 (and the tree is marked failed
# when the wal itself failed, not merely refused an oversized record).
int lsm_log_record(lsm* l, char* rec, int len):
	if (wal_append(l.log, rec, len) == 1): return 1
	if (wal_failed(l.log)): l.failed = 1
	return 0


# Durable insert/overwrite: wal first, then memtable, then the
# auto-flush check. Returns 1, or 0 on a wal/flush I/O failure (on a
# wal failure nothing was mutated).
int lsm_put(lsm* l, char* key, char* value, int value_len):
	if (value_len < 0 || l.failed): return 0
	int key_len = strlen(key)
	char* rec = cast(char*, malloc(9 + key_len + value_len))
	rec[0] = lsm_tag_put
	store_le32(rec + 1, key_len)
	store_le32(rec + 5, value_len)
	int i = 0
	while (i < key_len):
		rec[9 + i] = key[i]
		i = i + 1
	i = 0
	while (i < value_len):
		rec[9 + key_len + i] = value[i]
		i = i + 1
	int ok = lsm_log_record(l, rec, 9 + key_len + value_len)
	free(rec)
	if (ok == 0): return 0
	memtable_put(l.mem, key, value, value_len)
	if (memtable_bytes(l.mem) > l.memtable_limit_bytes): return lsm_flush(l)
	return 1


# Durable delete: records a tombstone that shadows every older tier
# until a full compaction drops it. Same wal-first shape as lsm_put.
int lsm_delete(lsm* l, char* key):
	if (l.failed): return 0
	int key_len = strlen(key)
	char* rec = cast(char*, malloc(5 + key_len))
	rec[0] = lsm_tag_delete
	store_le32(rec + 1, key_len)
	for i in range(key_len): rec[5 + i] = key[i]
	int ok = lsm_log_record(l, rec, 5 + key_len)
	free(rec)
	if (ok == 0): return 0
	memtable_delete(l.mem, key)
	if (memtable_bytes(l.mem) > l.memtable_limit_bytes): return lsm_flush(l)
	return 1


# ---- atomic batches -------------------------------------------------------------

# An ordered group of puts/deletes applied all-or-nothing: one BATCH
# record in the data wal (header). Keys and values are copied in.
struct lsm_batch:
	list[int] ops           # lsm_tag_put / lsm_tag_delete
	list[char*] keys        # owned
	list[char*] values      # owned (0 for deletes)
	list[int] value_lens
	int encoded_len         # BATCH payload size so far


lsm_batch* lsm_batch_new():
	lsm_batch* b = new lsm_batch()
	b.ops = new list[int]
	b.keys = new list[char*]
	b.values = new list[char*]
	b.value_lens = new list[int]
	b.encoded_len = 5
	return b


void lsm_batch_free(lsm_batch* b):
	int i = 0
	while (i < b.keys.length):
		free(b.keys[i])
		if (cast(int, b.values[i]) != 0): free(b.values[i])
		i = i + 1
	b.keys.free()
	b.values.free()
	b.value_lens.free()
	b.ops.free()
	free(b)


int lsm_batch_count(lsm_batch* b):
	return b.ops.length


void lsm_batch_put(lsm_batch* b, char* key, char* value, int value_len):
	assert1(value_len >= 0)
	int klen = strlen(key)
	b.ops.push(lsm_tag_put)
	b.keys.push(mem_dup(key, klen))
	b.values.push(mem_dup(value, value_len))
	b.value_lens.push(value_len)
	b.encoded_len = b.encoded_len + 9 + klen + value_len


void lsm_batch_delete(lsm_batch* b, char* key):
	int klen = strlen(key)
	b.ops.push(lsm_tag_delete)
	b.keys.push(mem_dup(key, klen))
	b.values.push(cast(char*, 0))
	b.value_lens.push(0)
	b.encoded_len = b.encoded_len + 9 + klen


# Applies every operation in b, in order, as ONE wal record: after a
# crash recovery replays all of them or none. Returns 1 (an empty batch
# is a no-op), or 0 when the batch exceeds wal_max_record or the wal
# append fails — nothing is applied then.
int lsm_apply_batch(lsm* l, lsm_batch* b):
	if (l.failed): return 0
	int n = b.ops.length
	if (n == 0): return 1
	int total = b.encoded_len
	if (total > wal_max_record()): return 0
	char* rec = cast(char*, malloc(total))
	rec[0] = lsm_tag_batch
	store_le32(rec + 1, n)
	int off = 5
	int i = 0
	while (i < n):
		char* key = b.keys[i]
		int klen = strlen(key)
		int vlen = b.value_lens[i]
		rec[off] = b.ops[i]
		store_le32(rec + off + 1, klen)
		store_le32(rec + off + 5, vlen)
		mem_copy(rec + off + 9, key, klen)
		if (vlen > 0): mem_copy(rec + off + 9 + klen, b.values[i], vlen)
		off = off + 9 + klen + vlen
		i = i + 1
	int ok = lsm_log_record(l, rec, total)
	if (ok == 1): lsm_apply_batch_payload(l.mem, rec)
	free(rec)
	if (ok == 0): return 0
	if (memtable_bytes(l.mem) > l.memtable_limit_bytes): return lsm_flush(l)
	return 1


# ---- reads ----------------------------------------------------------------------

# Checked point lookup: memtable, then tables newest-first.
# LSM_GET_FOUND with value_out[0] a MALLOC'D NUL-terminated copy (caller
# frees; length via len_out — values may be binary); LSM_GET_ABSENT when
# the key is absent or tombstoned; LSM_GET_ERROR when a table read
# failed. The out-params are written only on LSM_GET_FOUND.
int lsm_get_status(lsm* l, char* key, char** value_out, int* len_out):
	char* borrowed = 0
	int vlen = 0
	int state = memtable_get(l.mem, key, &borrowed, &vlen)
	if (state == 1):
		# memtable values are borrowed; copy for the uniform contract
		value_out[0] = mem_dup(borrowed, vlen)
		len_out[0] = vlen
		return LSM_GET_FOUND
	if (state == 2): return LSM_GET_ABSENT
	int i = l.tables.length - 1
	while (i >= 0):
		sstable* t = l.tables[i]
		char* got = 0
		state = sstable_get(t, key, &got, &vlen)
		if (state == 1):
			value_out[0] = got
			len_out[0] = vlen
			return LSM_GET_FOUND
		if (state == 2): return LSM_GET_ABSENT
		if (state < 0): return LSM_GET_ERROR
		i = i - 1
	return LSM_GET_ABSENT


# Point lookup: memtable, then tables newest-first. Returns a
# MALLOC'D NUL-terminated copy (caller frees; length via len_out —
# values may be binary) or 0 with len_out 0 when the key is absent or
# tombstoned. A failed table read is fatal here (it cannot be told
# apart from "absent" through this signature); lsm_get_status reports
# it instead.
char* lsm_get(lsm* l, char* key, int* len_out):
	char* result = 0
	int status = lsm_get_status(l, key, &result, len_out)
	asserts(c"lsm_get: sstable read failed (use lsm_get_status to handle it)", status != LSM_GET_ERROR)
	if (status != LSM_GET_FOUND):
		len_out[0] = 0
		return 0
	return result


# ---- ordered merge across tiers (compaction, export, scan) -------------------

# A k-way merge cursor over the tables (oldest first) and, when
# with_mem is set, the memtable as the last, newest source.
struct lsm_merge:
	lsm* l
	int sources
	list[int] cursors


int lsm_merge_count_at(lsm* l, int src):
	if (src < l.tables.length): return sstable_count(l.tables[src])
	return memtable_count(l.mem)


char* lsm_merge_key_at(lsm* l, int src, int i):
	if (src < l.tables.length): return sstable_key_at(l.tables[src], i)
	return memtable_key_at(l.mem, i)


int lsm_merge_tombstone_at(lsm* l, int src, int i):
	if (src < l.tables.length): return sstable_is_tombstone_at(l.tables[src], i)
	return memtable_is_tombstone_at(l.mem, i)


# Malloc'd copy either way: sstable_value_at already reads a fresh
# malloc'd copy from disk; memtable_value_at's pointer is borrowed, so
# it is copied here too. A failed table read returns 0 with len -1.
char* lsm_merge_value_at(lsm* l, int src, int i, int* len_out):
	if (src < l.tables.length): return sstable_value_at(l.tables[src], i, len_out)
	char* borrowed = memtable_value_at(l.mem, i, len_out)
	return mem_dup(borrowed, len_out[0])


# First index in source src whose key is >= start (0 = from the start).
int lsm_merge_lower_bound(lsm* l, int src, char* start):
	if (start == 0): return 0
	int idx = 0
	if (src < l.tables.length): idx = sstable_find(l.tables[src], start)
	else: idx = memtable_find(l.mem, start)
	if (idx < 0): idx = 0 - idx - 1
	return idx


lsm_merge* lsm_merge_new(lsm* l, int with_mem, char* start):
	lsm_merge* m = new lsm_merge()
	m.l = l
	m.sources = l.tables.length
	if (with_mem): m.sources = m.sources + 1
	m.cursors = new list[int]
	int i = 0
	while (i < m.sources):
		m.cursors.push(lsm_merge_lower_bound(l, i, start))
		i = i + 1
	return m


# The source holding the smallest pending key (ties go to the NEWEST
# source: scanning oldest->newest with <= lets a later source displace
# an earlier one), or -1 when every source is exhausted.
int lsm_merge_best(lsm_merge* m):
	int best = 0 - 1
	char* best_key = 0
	int i = 0
	while (i < m.sources):
		if (m.cursors[i] < lsm_merge_count_at(m.l, i)):
			char* k = lsm_merge_key_at(m.l, i, m.cursors[i])
			if (best < 0 || strcmp(k, best_key) <= 0):
				best = i
				best_key = k
		i = i + 1
	return best


# Advances every cursor sitting on key: the winner and every older
# shadowed version of it.
void lsm_merge_advance(lsm_merge* m, char* key):
	int i = 0
	while (i < m.sources):
		if (m.cursors[i] < lsm_merge_count_at(m.l, i)):
			if (strcmp(lsm_merge_key_at(m.l, i, m.cursors[i]), key) == 0):
				m.cursors[i] = m.cursors[i] + 1
		i = i + 1


# ---- compaction -----------------------------------------------------------------

# Full compaction: k-way merge of ALL tables (not the memtable —
# lsm_flush first to include it) into one new table; ties go to the
# newest table, tombstones are dropped entirely. The manifest is then
# replaced through a durable sibling rewrite, and only after that
# replacement is durable are the superseded table files unlinked (see
# the header). Returns 1 (no-op when there are no tables), 0 on I/O
# failure: before the manifest switch the tree is unchanged and the
# merged table deleted; after it, the tree serves the merged table.
int lsm_compact(lsm* l):
	if (l.failed): return 0
	int n = l.tables.length
	if (n == 0): return 1
	char* path = lsm_table_path(l.prefix, l.next_seq)
	sstable_writer* w = sstable_writer_new_with_ops(l.ops, path)
	if (cast(int, w) == 0):
		free(path)
		return 0
	lsm_merge* m = lsm_merge_new(l, 0, cast(char*, 0))
	int vlen = 0
	int read_ok = 1
	int best = lsm_merge_best(m)
	while (best >= 0 && read_ok == 1):
		char* best_key = lsm_merge_key_at(l, best, m.cursors[best])
		if (lsm_merge_tombstone_at(l, best, m.cursors[best]) == 0):
			char* val = lsm_merge_value_at(l, best, m.cursors[best], &vlen)
			if (vlen < 0): read_ok = 0
			else:
				sstable_writer_add(w, best_key, val, vlen, 0)
				free(val)
		lsm_merge_advance(m, best_key)
		best = lsm_merge_best(m)
	m.cursors.free()
	free(m)
	if (read_ok == 0):
		sstable_writer_abort(w)
		free(path)
		return 0
	if (sstable_writer_finish(w) == 0):
		storage_unlink(l.ops, path)
		free(path)
		return 0
	sstable* merged = sstable_open_with_ops(l.ops, path)
	if (cast(int, merged) == 0):
		storage_unlink(l.ops, path)
		free(path)
		return 0
	int seq = l.next_seq
	l.next_seq = l.next_seq + 1
	list[int] seqs = new list[int]
	seqs.push(seq)
	fs_replace_report rep
	int status = lsm_publish_manifest(l.manifest, l.epoch, seqs, &rep)
	if (status != IO_OK && rep.renamed == 0):
		# the old manifest is still live: nothing changed
		sstable_close(merged)
		storage_unlink(l.ops, path)
		free(path)
		return 0
	# the manifest names only the merged table: swap it in. The old
	# files are unlinked only when that manifest is durable.
	list[sstable*] old_tables = l.tables
	list[char*] old_paths = l.table_paths
	l.tables = new list[sstable*]
	l.table_paths = new list[char*]
	l.tables.push(merged)
	l.table_paths.push(path)
	int i = 0
	while (i < old_paths.length):
		if (status == IO_OK): storage_unlink(l.ops, old_paths[i])
		i = i + 1
	lsm_free_tables(old_tables, old_paths)
	if (status != IO_OK): return lsm_fail(l)
	return 1


# ---- bounded scan -----------------------------------------------------------------

# One page of lsm_scan: live (non-tombstoned) records in ascending key
# order. keys/values are malloc'd copies owned by the page.
struct lsm_page:
	list[char*] keys
	list[char*] values
	list[int] value_lens
	int bytes          # sum of key + value lengths in the page
	char* resume       # owned start key for the next page; 0 when the scan is complete
	int ok             # 0 when a table read failed (the page is then partial)


void lsm_page_free(lsm_page* p):
	int i = 0
	while (i < p.keys.length):
		free(p.keys[i])
		free(p.values[i])
		i = i + 1
	if (p.resume != 0): free(p.resume)
	p.keys.free()
	p.values.free()
	p.value_lens.free()
	free(p)


int lsm_page_count(lsm_page* p):
	return p.keys.length


# Bounded ordered iterator: the live records with key >= start (0 =
# from the first key), merged newest-wins across the memtable and every
# table, at most max_entries of them and at most max_bytes of key +
# value bytes (but always at least one record, so a huge value cannot
# stall the scan). page.resume is the start key for the next call, or 0
# when nothing follows. Pages read the live tree (header).
lsm_page* lsm_scan(lsm* l, char* start, int max_entries, int max_bytes):
	lsm_page* page = new lsm_page()
	page.keys = new list[char*]
	page.values = new list[char*]
	page.value_lens = new list[int]
	page.bytes = 0
	page.resume = 0
	page.ok = 1
	lsm_merge* m = lsm_merge_new(l, 1, start)
	int vlen = 0
	int best = lsm_merge_best(m)
	while (best >= 0):
		char* key = lsm_merge_key_at(l, best, m.cursors[best])
		if (lsm_merge_tombstone_at(l, best, m.cursors[best]) == 0):
			if (page.keys.length >= max_entries):
				page.resume = mem_dup(key, strlen(key))
				best = 0 - 1
			else:
				char* val = lsm_merge_value_at(l, best, m.cursors[best], &vlen)
				if (vlen < 0):
					page.ok = 0
					page.resume = mem_dup(key, strlen(key))
					best = 0 - 1
				else:
					int klen = strlen(key)
					if (page.keys.length > 0 && page.bytes + klen + vlen > max_bytes):
						free(val)
						page.resume = mem_dup(key, klen)
						best = 0 - 1
					else:
						page.keys.push(mem_dup(key, klen))
						page.values.push(val)
						page.value_lens.push(vlen)
						page.bytes = page.bytes + klen + vlen
		if (best >= 0):
			lsm_merge_advance(m, key)
			best = lsm_merge_best(m)
	m.cursors.free()
	free(m)
	return page


# ---- export / import (full-scan snapshot surface, issue #314) ---------------

const int lsm_export_version = 1


# Full-scan export: the same k-way merge lsm_compact runs across every
# table, with the memtable folded in as the newest source, tombstones
# DROPPED entirely (see the header). Returns a malloc'd "LSMX" blob
# (len_out gets its length; byte format in the header) — an empty tree
# exports a valid 12-byte header-only blob with a zero record count —
# or 0 (len_out 0) when a table read failed.
char* lsm_export(lsm* l, int* len_out):
	list[char*] keys = new list[char*]
	list[char*] vals = new list[char*]
	list[int] vlens = new list[int]
	lsm_merge* m = lsm_merge_new(l, 1, cast(char*, 0))
	int vl = 0
	int read_ok = 1
	int best = lsm_merge_best(m)
	while (best >= 0 && read_ok == 1):
		char* best_key = lsm_merge_key_at(l, best, m.cursors[best])
		if (lsm_merge_tombstone_at(l, best, m.cursors[best]) == 0):
			char* val = lsm_merge_value_at(l, best, m.cursors[best], &vl)
			if (vl < 0): read_ok = 0
			else:
				keys.push(mem_dup(best_key, strlen(best_key)))
				vals.push(val)
				vlens.push(vl)
		lsm_merge_advance(m, best_key)
		best = lsm_merge_best(m)
	m.cursors.free()
	free(m)
	int total = 12
	int i = 0
	while (i < keys.length):
		total = total + 4 + strlen(keys[i]) + 4 + vlens[i]
		i = i + 1
	char* buf = 0
	if (read_ok == 1):
		buf = cast(char*, malloc(total))
		buf[0] = 76   # L
		buf[1] = 83   # S
		buf[2] = 77   # M
		buf[3] = 88   # X
		store_le32(buf + 4, lsm_export_version)
		store_le32(buf + 8, keys.length)
	int off = 12
	i = 0
	while (i < keys.length):
		char* k = keys[i]
		char* v = vals[i]
		if (read_ok == 1):
			int klen = strlen(k)
			store_le32(buf + off, klen)
			off = off + 4
			mem_copy(buf + off, k, klen)
			off = off + klen
			store_le32(buf + off, vlens[i])
			off = off + 4
			if (vlens[i] > 0): mem_copy(buf + off, v, vlens[i])
			off = off + vlens[i]
		free(k)
		free(v)
		i = i + 1
	if (read_ok == 0):
		len_out[0] = 0
		return 0
	len_out[0] = total
	return buf


# Installs a new generation holding exactly the given records (keys
# strictly ascending, already validated) — header: "Generations". The
# new table is built and the new manifest published before anything
# live changes; a failure before that switch leaves l untouched.
int lsm_install_generation(lsm* l, char* blob, list[int] koff, list[int] klen, list[int] voff, list[int] vlen):
	if (l.failed): return 0
	int count = koff.length
	list[int] seqs = new list[int]
	char* path = 0
	sstable* t = 0
	if (count > 0):
		int seq = l.next_seq
		l.next_seq = l.next_seq + 1
		path = lsm_table_path(l.prefix, seq)
		sstable_writer* w = sstable_writer_new_with_ops(l.ops, path)
		if (cast(int, w) == 0):
			free(path)
			return 0
		int i = 0
		while (i < count):
			char* key = mem_dup(blob + koff[i], klen[i])
			sstable_writer_add(w, key, blob + voff[i], vlen[i], 0)
			free(key)
			i = i + 1
		if (sstable_writer_finish(w) == 0):
			storage_unlink(l.ops, path)
			free(path)
			return 0
		t = sstable_open_with_ops(l.ops, path)
		if (cast(int, t) == 0):
			storage_unlink(l.ops, path)
			free(path)
			return 0
		seqs.push(seq)
	int new_epoch = l.epoch + 1
	fs_replace_report rep
	int status = lsm_publish_manifest(l.manifest, new_epoch, seqs, &rep)
	if (status != IO_OK && rep.renamed == 0):
		# the old generation is still the live one
		if (count > 0):
			sstable_close(t)
			storage_unlink(l.ops, path)
			free(path)
		return 0
	# the manifest names the new generation: switch everything to it
	list[sstable*] old_tables = l.tables
	list[char*] old_paths = l.table_paths
	l.tables = new list[sstable*]
	l.table_paths = new list[char*]
	if (count > 0):
		l.tables.push(t)
		l.table_paths.push(path)
	memtable_clear(l.mem)
	l.epoch = new_epoch
	if (status != IO_OK):
		# The rename is visible but its durability is unknown. Preserve
		# the old data WAL and files; recovery may still select them.
		lsm_free_tables(old_tables, old_paths)
		return lsm_fail(l)
	fs_replace_report drep
	int dstatus = lsm_publish_data_wal(l.log, new_epoch, &drep)
	int i = 0
	while (i < old_paths.length):
		if (status == IO_OK): storage_unlink(l.ops, old_paths[i])
		i = i + 1
	lsm_free_tables(old_tables, old_paths)
	if (status != IO_OK || dstatus != IO_OK): return lsm_fail(l)
	return 1


# Wipes l to an empty tree: installs an empty generation (header) —
# the manifest switch comes first, the old table files are unlinked
# only once it is durable, and next_seq is left untouched so a table
# path is never reused. Returns 0 on any I/O failure (before the
# switch, l is unchanged).
int lsm_clear(lsm* l):
	list[int] none = new list[int]
	return lsm_install_generation(l, cast(char*, 0), none, none, none, none)


# Rebuilds l from an lsm_export blob: validates the ENTIRE buffer
# first (magic, version, every record's lengths in bounds, keys free of
# NUL and strictly ascending) so a malformed blob leaves l untouched,
# then installs it as a new generation (header: "Generations"). Returns
# 0 on a malformed blob or an I/O failure; either way, unless the
# failure came after the manifest switch (lsm_failed(l) is then set),
# l still holds its old generation intact. This is the receiver-side
# half of the raft snapshot handoff: kv_state.w's kv_install_snapshot
# calls this with the blob raft_take_pending_snapshot hands the state
# machine.
int lsm_import(lsm* l, char* blob, int len):
	if (len < 12): return 0
	if ((blob[0] & 255) != 76 || (blob[1] & 255) != 83 || (blob[2] & 255) != 77 || (blob[3] & 255) != 88):
		return 0
	if (load_le32(blob + 4) != lsm_export_version): return 0
	int count = load_le32(blob + 8)
	if (count < 0): return 0
	list[int] key_off = new list[int]
	list[int] key_len = new list[int]
	list[int] val_off = new list[int]
	list[int] val_len = new list[int]
	int off = 12
	int i = 0
	while (i < count):
		if (len - off < 4): return 0
		int klen = load_le32(blob + off)
		if (klen < 0 || klen > len - off - 4): return 0
		int k = 0
		while (k < klen):
			if (blob[off + 4 + k] == 0): return 0
			k = k + 1
		if (i > 0):
			# strictly ascending: memcmp order on NUL-free keys is strcmp order
			int prev_off = key_off[i - 1]
			int prev_len = key_len[i - 1]
			int c = 0
			k = 0
			while (c == 0 && k < prev_len && k < klen):
				c = (blob[prev_off + k] & 255) - (blob[off + 4 + k] & 255)
				k = k + 1
			if (c == 0): c = prev_len - klen
			if (c >= 0): return 0
		key_off.push(off + 4)
		key_len.push(klen)
		off = off + 4 + klen
		if (len - off < 4): return 0
		int vlen = load_le32(blob + off)
		if (vlen < 0 || vlen > len - off - 4): return 0
		val_off.push(off + 4)
		val_len.push(vlen)
		off = off + 4 + vlen
		i = i + 1
	if (off != len): return 0
	return lsm_install_generation(l, blob, key_off, key_len, val_off, val_len)


# ---- stats ----------------------------------------------------------------------

int lsm_sstable_count(lsm* l):
	return l.tables.length


int lsm_memtable_count(lsm* l):
	return memtable_count(l.mem)


int lsm_memtable_bytes(lsm* l):
	return memtable_bytes(l.mem)


int lsm_epoch(lsm* l):
	return l.epoch


# Raw record total across every tier — shadowing and tombstones NOT
# resolved (compaction shrinks this; reads do not).
int lsm_total_entries(lsm* l):
	int total = memtable_count(l.mem)
	for i in range(l.tables.length):
		sstable* t = l.tables[i]
		total = total + sstable_count(t)
	return total
