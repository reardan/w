# Bounded, reference-counted snapshot backing. Temporary files are unlinked
# immediately: a process crash reclaims partial staging without directory scans.
# Durable ownership belongs to raft_wal's atomic rewrite, never this scratch file.
import libs.standard.distributed.storage_io
import lib.sha256
import lib.bytes
import lib.mem

const int SNAPSHOT_FILE_LIMIT = 268435456
const int SNAPSHOT_FILE_CHUNK = 32768

struct snapshot_file:
	file_ops* ops
	int fd
	int refs
	int length
	int sealed
	int hash
	int failed
	int hash_dirty
	int hash_tail_len
	int* hash_state
	int* hash_schedule
	char* hash_tail

snapshot_file* snapshot_file_new(file_ops* ops, char* prefix):
	char* path = fs_replace_temp_path(prefix, getpid(), fs_replace_sequence)
	fs_replace_sequence = fs_replace_sequence + 1
	int fd = storage_open(ops, path, FILE_OPS_READ_WRITE | FILE_OPS_CREATE | FILE_OPS_EXCLUSIVE, 384)
	if (fd < 0):
		free(path)
		return 0
	int removed = storage_unlink(ops, path)
	free(path)
	if (removed < 0):
		storage_close(ops, fd)
		return 0
	snapshot_file* s = new snapshot_file()
	s.ops = ops
	s.fd = fd
	s.refs = 1
	s.hash_state = cast(int*, malloc(8 * __word_size__))
	s.hash_schedule = cast(int*, malloc(64 * __word_size__))
	s.hash_tail = malloc(128)
	for i in range(8): s.hash_state[i] = sha256_be32(sha256_h0_table() + i * 4)
	return s

snapshot_file* snapshot_file_retain(snapshot_file* s):
	if (cast(int, s) != 0): s.refs = s.refs + 1
	return s

void snapshot_file_free(snapshot_file* s):
	if (cast(int, s) == 0): return
	s.refs = s.refs - 1
	if (s.refs != 0): return
	storage_close(s.ops, s.fd)
	free(s.hash_state)
	free(s.hash_schedule)
	free(s.hash_tail)
	free(s)

int snapshot_file_read(snapshot_file* s, int offset, char* data, int length):
	if (s.failed || offset < 0 || length < 0 || offset > s.length || length > s.length - offset): return 0
	if (storage_seek(s.ops, s.fd, offset, 0) != offset || storage_read(s.ops, s.fd, data, length) != length):
		s.failed = 1
		return 0
	return 1

void snapshot_file_hash_update(snapshot_file* s, char* data, int length):
	int offset = 0
	if (s.hash_tail_len > 0):
		int take = 64 - s.hash_tail_len
		if (take > length): take = length
		mem_copy(s.hash_tail + s.hash_tail_len, data, take)
		s.hash_tail_len = s.hash_tail_len + take
		offset = take
		if (s.hash_tail_len == 64):
			sha256_block_w(s.hash_state, s.hash_tail, s.hash_schedule)
			s.hash_tail_len = 0
	while (length - offset >= 64):
		sha256_block_w(s.hash_state, data + offset, s.hash_schedule)
		offset = offset + 64
	if (offset < length):
		s.hash_tail_len = length - offset
		mem_copy(s.hash_tail, data + offset, s.hash_tail_len)


int snapshot_file_append(snapshot_file* s, char* data, int length):
	if (s.failed || s.sealed || length < 0 || length > SNAPSHOT_FILE_LIMIT - s.length): return 0
	if (storage_seek(s.ops, s.fd, s.length, 0) != s.length || storage_write(s.ops, s.fd, data, length) != length):
		s.failed = 1
		return 0
	snapshot_file_hash_update(s, data, length)
	s.length = s.length + length
	return 1

# Sequential appends maintain SHA-256 incrementally; finishing a received
# snapshot processes at most two SHA blocks, never a whole-file reread.
# Export changes its count header once and marks hash_dirty to rebuild in
# the storage owner before offering the resulting immutable source to Raft.
int snapshot_file_seal(snapshot_file* s):
	if (s.failed): return 0
	if (s.sealed): return 1
	if (s.hash_dirty):
		for i in range(8): s.hash_state[i] = sha256_be32(sha256_h0_table() + i * 4)
		s.hash_tail_len = 0
		char* buf = malloc(SNAPSHOT_FILE_CHUNK)
		int offset = 0
		int ok = 1
		while (ok && offset < s.length):
			int take = s.length - offset
			if (take > SNAPSHOT_FILE_CHUNK): take = SNAPSHOT_FILE_CHUNK
			ok = snapshot_file_read(s, offset, buf, take)
			if (ok): snapshot_file_hash_update(s, buf, take)
			offset = offset + take
		free(buf)
		if (ok == 0): return 0
	int rem = s.hash_tail_len
	char* tail = s.hash_tail
	for i in range(rem, 128): tail[i] = 0
	tail[rem] = 128
	int blocks = 1
	if (rem >= 56): blocks = 2
	sha256_put_be32(tail + blocks * 64 - 8, s.length >> 29)
	sha256_put_be32(tail + blocks * 64 - 4, s.length << 3)
	sha256_block_w(s.hash_state, tail, s.hash_schedule)
	if (blocks == 2): sha256_block_w(s.hash_state, tail + 64, s.hash_schedule)
	sha256_put_be32(tail, s.hash_state[0])
	s.hash = load_le32(tail)
	s.sealed = 1
	return 1
