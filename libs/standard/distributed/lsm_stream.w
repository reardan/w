# Streaming LSMX export/install. No buffers scale with value bytes or snapshot
# size. Fixed budgets also bound the immutable table's eventual in-memory index.
import libs.standard.distributed.lsm
import libs.standard.distributed.snapshot_file

const int LSM_STREAM_VALUE_LIMIT = 1048576
const int LSM_STREAM_KEY_LIMIT = 4096
const int LSM_STREAM_KEYS_LIMIT = 65536
const int LSM_STREAM_INDEX_LIMIT = 4194304
const int LSM_STREAM_TABLE_LIMIT = 1024

snapshot_file* lsm_export_file(lsm* l, char* prefix):
	if (l.failed || l.tables.length > LSM_STREAM_TABLE_LIMIT): return 0
	snapshot_file* s = snapshot_file_new(l.ops, prefix)
	if (cast(int, s) == 0): return 0
	char* header = cast(char*, malloc(12))
	mem_copy(cast(char*, header), c"LSMX", 4)
	store_le32(header + 4, lsm_export_version)
	store_le32(header + 8, 0)
	int ok = snapshot_file_append(s, header, 12)
	int count = 0
	int index_bytes = 0
	lsm_merge* m = lsm_merge_new(l, 1, cast(char*, 0))
	int best = lsm_merge_best(m)
	while (ok && best >= 0):
		char* key = lsm_merge_key_at(l, best, m.cursors[best])
		if (lsm_merge_tombstone_at(l, best, m.cursors[best]) == 0):
			int klen = strlen(key)
			int vlen = 0
			if (best < l.tables.length): vlen = l.tables[best].value_lens[m.cursors[best]]
			else: vlen = l.mem.value_lens[m.cursors[best]]
			index_bytes = index_bytes + klen
			if (klen > LSM_STREAM_KEY_LIMIT || vlen > LSM_STREAM_VALUE_LIMIT || count >= LSM_STREAM_KEYS_LIMIT || index_bytes > LSM_STREAM_INDEX_LIMIT): ok = 0
			if (ok):
				char* value = lsm_merge_value_at(l, best, m.cursors[best], &vlen)
				if (vlen < 0): ok = 0
				else:
					store_le32(header, klen)
					ok = snapshot_file_append(s, header, 4) && snapshot_file_append(s, key, klen)
					store_le32(header, vlen)
					if (ok): ok = snapshot_file_append(s, header, 4) && snapshot_file_append(s, value, vlen)
					free(value)
				count = count + 1
		lsm_merge_advance(m, key)
		best = lsm_merge_best(m)
	m.cursors.free()
	free(m)
	store_le32(header, count)
	if (ok): ok = storage_seek(s.ops, s.fd, 8, 0) == 8 && storage_write(s.ops, s.fd, header, 4) == 4
	free(header)
	s.hash_dirty = 1
	if (ok): ok = snapshot_file_seal(s)
	if (ok): return s
	snapshot_file_free(s)
	return 0

# Read/validate one LSMX record, then stream it directly into the unpublished
# SST. Only previous/current key and a 32KiB value window remain resident.
int lsm_stream_records(snapshot_file* s, file_ops* ops, int fd, int count, bloom_filter* bloom):
	char* header = cast(char*, malloc(9))
	char* buf = cast(char*, malloc(SNAPSHOT_FILE_CHUNK))
	char* previous = 0
	int offset = 12
	int index_bytes = 0
	int ok = 1
	int i = 0
	while (ok && i < count):
		ok = snapshot_file_read(s, offset, header, 4)
		int klen = load_le32(header)
		if (klen < 0 || klen > LSM_STREAM_KEY_LIMIT): ok = 0
		char* key = 0
		if (ok):
			index_bytes = index_bytes + klen
			if (index_bytes > LSM_STREAM_INDEX_LIMIT): ok = 0
		if (ok):
			key = cast(char*, malloc(klen + 1))
			ok = snapshot_file_read(s, offset + 4, key, klen)
			key[klen] = 0
			if (strlen(key) != klen): ok = 0
			if (ok && previous != 0 && strcmp(previous, key) >= 0): ok = 0
		int vlen = 0
		if (ok):
			offset = offset + 4 + klen
			ok = snapshot_file_read(s, offset, header, 4)
			vlen = load_le32(header)
			if (vlen < 0 || vlen > LSM_STREAM_VALUE_LIMIT || vlen > s.length - offset - 4): ok = 0
		if (ok):
			header[0] = 0
			store_le32(header + 1, klen)
			store_le32(header + 5, vlen)
			ok = storage_write(ops, fd, header, 9) == 9 && storage_write(ops, fd, key, klen) == klen
			bloom_add(bloom, key)
			offset = offset + 4
			int remaining = vlen
			while (ok && remaining > 0):
				int take = remaining
				if (take > SNAPSHOT_FILE_CHUNK): take = SNAPSHOT_FILE_CHUNK
				ok = snapshot_file_read(s, offset, buf, take)
				if (ok): ok = storage_write(ops, fd, buf, take) == take
				offset = offset + take
				remaining = remaining - take
		if (previous != 0): free(previous)
		previous = key
		i = i + 1
	if (previous != 0): free(previous)
	free(buf)
	free(header)
	return ok && offset == s.length

int lsm_import_file_checked(lsm* l, snapshot_file* s, char* expected_key, char* expected_value, int expected_len):
	if (l.failed || s.length < 12 || s.length > SNAPSHOT_FILE_LIMIT || snapshot_file_seal(s) == 0): return 0
	char* header = cast(char*, malloc(16))
	if (snapshot_file_read(s, 0, header, 12) == 0):
		free(header)
		return 0
	if (header[0] != 76 || header[1] != 83 || header[2] != 77 || header[3] != 88 || load_le32(header + 4) != lsm_export_version):
		free(header)
		return 0
	int count = load_le32(header + 8)
	if (count < 0 || count > LSM_STREAM_KEYS_LIMIT):
		free(header)
		return 0
	if (count == 0):
		free(header)
		if (s.length != 12 || expected_key != 0): return 0
		return lsm_clear(l)
	int seq = l.next_seq
	l.next_seq = l.next_seq + 1
	char* path = lsm_table_path(l.prefix, seq)
	int fd = storage_open(l.ops, path, FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_EXCLUSIVE, 420)
	if (fd < 0):
		free(header)
		free(path)
		return 0
	bloom_filter* bloom = bloom_new(sstable_bloom_bits(count), sstable_bloom_probes)
	int blen = bloom_serialized_size(bloom)
	char* bdata = cast(char*, malloc(blen))
	bloom_serialize(bloom, bdata)
	mem_copy(cast(char*, header), c"WSST", 4)
	store_le32(header + 4, sstable_version)
	store_le32(header + 8, blen)
	int ok = storage_write(l.ops, fd, header, 12) == 12 && storage_write(l.ops, fd, bdata, blen) == blen
	store_le32(header, count)
	if (ok): ok = storage_write(l.ops, fd, header, 4) == 4
	free(header)
	if (ok): ok = lsm_stream_records(s, l.ops, fd, count, bloom)
	bloom_serialize(bloom, bdata)
	bloom_free(bloom)
	if (ok): ok = storage_seek(l.ops, fd, 12, 0) == 12 && storage_write(l.ops, fd, bdata, blen) == blen
	free(bdata)
	io_result synced
	if (ok): ok = storage_sync(l.ops, fd, &synced) == IO_OK
	if (storage_close(l.ops, fd) < 0): ok = 0
	if (ok): ok = storage_sync_parent(l.ops, path, &synced) == IO_OK
	sstable* table = 0
	if (ok):
		table = sstable_open_with_ops(l.ops, path)
		ok = cast(int, table) != 0
	if (ok && expected_key != 0):
		char* actual = 0
		int length = 0
		ok = sstable_get(table, expected_key, &actual, &length) == 1
		if (ok): ok = length == expected_len && bytes_equal(actual, length, expected_value, expected_len)
		if (actual != 0): free(actual)
	if (ok == 0):
		if (cast(int, table) != 0): sstable_close(table)
		storage_unlink(l.ops, path)
		free(path)
		return 0
	list[int] seqs = new list[int]
	seqs.push(seq)
	int installed = lsm_publish_generation(l, table, path, seqs)
	seqs.free()
	return installed


int lsm_import_file(lsm* l, snapshot_file* s):
	return lsm_import_file_checked(l, s, cast(char*, 0), cast(char*, 0), 0)
