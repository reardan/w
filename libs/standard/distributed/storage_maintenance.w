/*
Bounded maintenance and pinned read generations for the single-writer LSM.
Acquire views and publish mutations on the store's serialized owner.
Each view opens independent descriptors and copies the memtable, so a
compaction/snapshot can unlink old files without invalidating the view.
The OS reclaims unlinked inodes after the final view closes. A view is
read-only; never pass its tree to mutation APIs. No shared seek cursors.

max_bytes bounds retained file bytes plus copied memtable bytes; callers
also cap the number of admitted views (or charge this amount to their
service byte budget). It is a space admission bound, not an RSS claim.
*/
import libs.standard.distributed.lsm


struct lsm_view:
	lsm* tree
	int retained_bytes


# Retained input bytes, checked without overflowing the caller's budget.
int lsm_maintenance_bytes(lsm* l, int max_bytes):
	if (max_bytes < 0 || l.failed): return -1
	int total = memtable_bytes(l.mem)
	if (total > max_bytes): return -1
	for i in range(l.tables.length):
		int size = storage_size(l.ops, l.tables[i].fd)
		if (size < 0 || size > max_bytes - total): return -1
		total = total + size
	return total


# Refuses before creating any temporary file if its conservative bound
# exceeds max_temp_bytes. Keep the store serialized for the whole call.
int lsm_compact_bounded(lsm* l, int max_temp_bytes):
	int input = lsm_maintenance_bytes(l, max_temp_bytes)
	if (input < 0): return 0
	int count = 0
	for i in range(l.tables.length):
		int entries = sstable_count(l.tables[i])
		if (entries > 2147483647 - count): return 0
		count = count + entries
	# Charge a whole output header/filter on top of input bytes,
	# including word rounding. Clamp before count * 10 can overflow.
	int bits = 1 << 20
	if (count < 104858): bits = sstable_bloom_bits(count)
	int overhead = 28 + ((bits + 31) >> 5) * 4
	if (overhead > max_temp_bytes - input): return 0
	return lsm_compact(l)


void lsm_view_free(lsm_view* view):
	lsm* tree = view.tree
	for i in range(tree.tables.length): sstable_close(tree.tables[i])
	tree.tables.free()
	memtable_free(tree.mem)
	free(tree)
	free(view)


lsm_view* lsm_view_new(lsm* live, int max_retained_bytes):
	int retained = lsm_maintenance_bytes(live, max_retained_bytes)
	if (retained < 0): return 0
	lsm* tree = new lsm()
	tree.ops = live.ops
	tree.tables = new list[sstable*]
	tree.mem = memtable_new()
	tree.failed = 0
	lsm_view* view = new lsm_view(tree, retained)
	for i in range(live.table_paths.length):
		sstable* table = sstable_open_with_ops(live.ops, live.table_paths[i])
		if (cast(int, table) == 0):
			lsm_view_free(view)
			return 0
		tree.tables.push(table)
	for i in range(memtable_count(live.mem)):
		char* key = memtable_key_at(live.mem, i)
		if (memtable_is_tombstone_at(live.mem, i)): memtable_delete(tree.mem, key)
		else:
			int len = 0
			char* value = memtable_value_at(live.mem, i, &len)
			memtable_put(tree.mem, key, value, len)
	return view


# Incremental orphan reclamation after recovery or an unlink failure.
# candidates are full paths from the caller's directory listing; only
# exact <prefix>.sst<digits> names not referenced by the live manifest
# are eligible. Single owner, no concurrent pending table publication.
# -1 = an I/O failed (retry later), otherwise number removed this pass. At most max_files candidates are
# examined; the caller advances its directory-list cursor by that amount.
int lsm_reclaim(lsm* l, list[char*] candidates, int max_files):
	if (l.failed || max_files < 0): return -1
	char* stem = strjoin(l.prefix, c".sst")
	int stem_len = strlen(stem)
	int removed = 0
	int failed = 0
	for i in range(candidates.length):
		if (i >= max_files): break
		char* path = candidates[i]
		int length = strlen(path)
		if (length <= stem_len || mem_starts_with(path, length, 0, stem) == 0): continue
		int eligible = 1
		for j in range(stem_len, length):
			if (path[j] < '0' || path[j] > '9'): eligible = 0
		for j in range(l.table_paths.length):
			if (strcmp(path, l.table_paths[j]) == 0): eligible = 0
		if (eligible):
			if (storage_unlink(l.ops, path) < 0): failed = 1
			else: removed = removed + 1
	free(stem)
	io_result r
	if (removed > 0 && storage_sync_parent(l.ops, l.prefix, &r) != IO_OK): failed = 1
	if (failed): return -1
	return removed
