# wbuild: x64
import lib.testing
import libs.standard.distributed.wal


# Distinct log paths per target so the 32- and 64-bit test binaries
# can run concurrently under wbuild without clobbering each other.
char* wal_test_path(char* name):
	char* prefix = strjoin(c"bin/wal_t", itoa(__word_size__))
	char* mid = strjoin(prefix, c"_")
	char* path = strjoin(mid, name)
	free(mid)
	free(prefix)
	return path


int* wal_test_len_out():
	return cast(int*, malloc(__word_size__))


void test_fresh_log_roundtrip():
	char* path = wal_test_path(c"fresh.log")
	create_file(path, 420)   # start empty even on reruns
	wal* w = wal_open(path)
	assert1(cast(int, w) != 0)
	assert_equal(0, wal_record_count(w))
	assert_equal(8, wal_size(w))
	assert_equal(1, wal_append(w, c"hello", 5))
	assert_equal(1, wal_append(w, c"world!", 6))
	assert_equal(2, wal_record_count(w))
	wal_close(w)
	wal_reader* rd = wal_reader_open(path)
	int* n = wal_test_len_out()
	char* p = wal_read_next(rd, n)
	assert_equal(5, n[0])
	assert_strings_equal(c"hello", p)
	free(p)
	p = wal_read_next(rd, n)
	assert_equal(6, n[0])
	assert_strings_equal(c"world!", p)
	free(p)
	assert_equal(0, cast(int, wal_read_next(rd, n)))
	wal_reader_close(rd)
	free(n)
	free(path)


void test_reopen_recovers_and_appends():
	char* path = wal_test_path(c"reopen.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	wal_append(w, c"one", 3)
	wal_append(w, c"two", 3)
	wal_close(w)
	w = wal_open(path)
	assert_equal(2, wal_record_count(w))
	wal_append(w, c"three", 5)
	wal_close(w)
	w = wal_open(path)
	assert_equal(3, wal_record_count(w))
	wal_close(w)
	free(path)


void test_torn_tail_truncated():
	char* path = wal_test_path(c"torn.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	wal_append(w, c"keepme", 6)
	wal_append(w, c"lostrecord", 10)
	int full = wal_size(w)
	wal_close(w)
	# tear the last record: rewrite the file cut 4 bytes short
	int fd = open(path, 0, 0)
	char* buf = cast(char*, malloc(full))
	assert_equal(full, read_exact(fd, buf, full))
	close(fd)
	fd = create_file(path, 420)
	assert_equal(full - 4, write_all(fd, buf, full - 4))
	close(fd)
	free(buf)
	w = wal_open(path)
	assert_equal(1, wal_record_count(w))
	# appending after recovery overwrites the torn bytes
	assert_equal(1, wal_append(w, c"fresh", 5))
	wal_close(w)
	wal_reader* rd = wal_reader_open(path)
	int* n = wal_test_len_out()
	char* p = wal_read_next(rd, n)
	assert_strings_equal(c"keepme", p)
	free(p)
	p = wal_read_next(rd, n)
	assert_strings_equal(c"fresh", p)
	free(p)
	assert_equal(0, cast(int, wal_read_next(rd, n)))
	wal_reader_close(rd)
	free(n)
	free(path)


void test_corrupt_payload_rejected():
	char* path = wal_test_path(c"corrupt.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	wal_append(w, c"aaaa", 4)
	wal_append(w, c"bbbb", 4)
	wal_close(w)
	# flip one payload byte of the second record:
	# header 8 + rec1 (8+4) + rec2 header 8 => offset of rec2 payload
	int fd = open(path, 2, 0)
	seek(fd, 8 + 12 + 8, 0)
	assert_equal(1, write_all(fd, c"X", 1))
	close(fd)
	w = wal_open(path)
	assert_equal(1, wal_record_count(w))
	wal_close(w)
	free(path)


void test_foreign_file_rejected():
	char* path = wal_test_path(c"foreign.log")
	int fd = create_file(path, 420)
	write_all(fd, c"this is not a wal file at all", 29)
	close(fd)
	assert_equal(0, cast(int, wal_open(path)))
	wal_reader* rd = wal_reader_open(path)
	int* n = wal_test_len_out()
	assert_equal(0, cast(int, wal_read_next(rd, n)))
	wal_reader_close(rd)
	free(n)
	free(path)


void test_empty_and_binary_payloads():
	char* path = wal_test_path(c"binary.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	assert_equal(1, wal_append(w, c"", 0))
	char* blob = cast(char*, malloc(4))
	blob[0] = 0
	blob[1] = 255
	blob[2] = 10
	blob[3] = 200
	assert_equal(1, wal_append(w, blob, 4))
	wal_close(w)
	wal_reader* rd = wal_reader_open(path)
	int* n = wal_test_len_out()
	char* p = wal_read_next(rd, n)
	assert_equal(0, n[0])
	free(p)
	p = wal_read_next(rd, n)
	assert_equal(4, n[0])
	assert_equal(0, p[0] & 255)
	assert_equal(255, p[1] & 255)
	assert_equal(10, p[2] & 255)
	assert_equal(200, p[3] & 255)
	free(p)
	wal_reader_close(rd)
	free(n)
	free(blob)
	free(path)


void test_sync_reaches_stable_storage():
	char* path = wal_test_path(c"sync.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	assert1(cast(int, w) != 0)
	assert_equal(1, wal_append(w, c"durable", 7))
	assert_equal(1, wal_sync(w))
	# syncing with nothing new appended is also fine
	assert_equal(1, wal_sync(w))
	wal_close(w)
	# raw wrapper contract on a plain fd: fsync/fdatasync return 0
	# after real writes, and a negative errno once the fd is closed
	char* raw = wal_test_path(c"sync_raw.bin")
	int fd = create_file(raw, 420)
	assert1(fd >= 0)
	assert_equal(5, write_all(fd, c"bytes", 5))
	assert_equal(0, fsync(fd))
	assert_equal(0, fdatasync(fd))
	close(fd)
	assert1(fsync(fd) < 0)
	free(raw)
	free(path)


void test_reset_empties_log():
	char* path = wal_test_path(c"reset.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	wal_append(w, c"old1", 4)
	wal_append(w, c"old2", 4)
	assert_equal(1, wal_reset(w))
	assert_equal(0, wal_record_count(w))
	assert_equal(8, wal_size(w))
	assert_equal(1, wal_append(w, c"new", 3))
	wal_close(w)
	w = wal_open(path)
	assert_equal(1, wal_record_count(w))
	wal_close(w)
	wal_reader* rd = wal_reader_open(path)
	int* n = wal_test_len_out()
	char* p = wal_read_next(rd, n)
	assert_strings_equal(c"new", p)
	free(p)
	wal_reader_close(rd)
	free(n)
	free(path)


# ---- recovery policy (strict / permissive) ------------------------------------

int wal_test_file_size(char* path):
	int fd = open(path, 0, 0)
	assert1(fd >= 0)
	int size = file_size(fd)
	close(fd)
	return size


int wal_test_exists(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	close(fd)
	return 1


# Overwrites one byte of path at off.
void wal_test_poke(char* path, int off, int value):
	int fd = open(path, 2, 0)
	assert1(fd >= 0)
	char* b = cast(char*, malloc(1))
	b[0] = value
	seek(fd, off, 0)
	assert_equal(1, write_all(fd, b, 1))
	free(b)
	close(fd)


# Rewrites path keeping only its first keep bytes.
void wal_test_cut(char* path, int keep):
	int fd = open(path, 0, 0)
	char* buf = cast(char*, malloc(keep + 1))
	assert_equal(keep, read_exact(fd, buf, keep))
	close(fd)
	fd = create_file(path, 420)
	assert_equal(keep, write_all(fd, buf, keep))
	close(fd)
	free(buf)


# Three 4-byte records: header 8, then 12-byte records at 8, 20, 32.
char* wal_test_three(char* name):
	char* path = wal_test_path(name)
	create_file(path, 420)
	wal* w = wal_open(path)
	assert_equal(1, wal_append(w, c"aaaa", 4))
	assert_equal(1, wal_append(w, c"bbbb", 4))
	assert_equal(1, wal_append(w, c"cccc", 4))
	assert_equal(1, wal_sync(w))
	wal_close(w)
	return path


# A flipped byte in a record that has more records after it is
# corruption inside the durable prefix: strict mode refuses the open and
# reports the bad record's offset; permissive mode keeps the historical
# behaviour (replay the prefix before it, silently).
void test_strict_reports_interior_corruption():
	char* path = wal_test_three(c"interior.log")
	wal_test_poke(path, 20 + 8 + 1, 88)   # rec2 payload byte
	wal_recovery rep
	assert_equal(0, cast(int, wal_open_policy(path, WAL_RECOVER_STRICT, &rep)))
	assert_equal(WAL_ERR_CORRUPT, rep.status)
	assert_equal(WAL_TAIL_CORRUPT, rep.tail)
	assert_equal(WAL_BAD_CHECKSUM, rep.reason)
	assert_equal(20, rep.bad_offset)
	assert_equal(1, rep.records)
	assert_equal(44, rep.file_size)
	assert_equal(0, cast(int, wal_open_policy(path, WAL_RECOVER_STRICT_TRUNCATE, &rep)))
	assert_equal(WAL_ERR_CORRUPT, rep.status)
	assert_equal(44, wal_test_file_size(path))   # never truncated
	wal* w = wal_open_policy(path, WAL_RECOVER_PERMISSIVE, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_OK, rep.status)
	assert_equal(WAL_TAIL_CORRUPT, rep.tail)
	assert_equal(1, wal_record_count(w))
	wal_close(w)
	free(path)
	# an impossible length field mid-file is corruption too
	path = wal_test_three(c"interior_len.log")
	wal_test_poke(path, 20 + 3, 127)      # rec2 length -> huge
	assert_equal(0, cast(int, wal_open_policy(path, WAL_RECOVER_STRICT, &rep)))
	assert_equal(WAL_BAD_LENGTH, rep.reason)
	assert_equal(20, rep.bad_offset)
	free(path)


# Incomplete trailing data is a torn tail, never corruption: a short
# payload or short header at EOF, a bad checksum on a final record
# that ends exactly at EOF, or a bad record followed only by zeros.
void test_torn_tail_classification():
	wal_recovery rep
	# short payload: cut 2 bytes off the last record
	char* path = wal_test_three(c"tail_payload.log")
	wal_test_cut(path, 42)
	wal* w = wal_open_policy(path, WAL_RECOVER_STRICT, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_OK, rep.status)
	assert_equal(WAL_TAIL_TORN, rep.tail)
	assert_equal(WAL_BAD_SHORT_PAYLOAD, rep.reason)
	assert_equal(32, rep.bad_offset)
	assert_equal(2, rep.records)
	assert_equal(0, rep.truncated)
	# strict without truncate leaves the tail and refuses appends
	assert_equal(0, wal_append(w, c"x", 1))
	wal_close(w)
	assert_equal(42, wal_test_file_size(path))
	# strict + truncate cuts it and the log carries on
	w = wal_open_policy(path, WAL_RECOVER_STRICT_TRUNCATE, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(1, rep.truncated)
	assert_equal(32, wal_test_file_size(path))
	assert_equal(1, wal_append(w, c"dd", 2))
	wal_close(w)
	w = wal_open_policy(path, WAL_RECOVER_STRICT, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_TAIL_CLEAN, rep.tail)
	assert_equal(3, rep.records)
	assert_equal(0 - 1, rep.bad_offset)
	wal_close(w)
	free(path)
	# short header: 3 bytes of a fourth record's header
	path = wal_test_three(c"tail_header.log")
	int fd = open(path, 2, 0)
	seek(fd, 44, 0)
	assert_equal(3, write_all(fd, c"abc", 3))
	close(fd)
	w = wal_open_policy(path, WAL_RECOVER_STRICT, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_TAIL_TORN, rep.tail)
	assert_equal(WAL_BAD_SHORT_HEADER, rep.reason)
	assert_equal(44, rep.bad_offset)
	wal_close(w)
	free(path)
	# bad checksum on the final record, ending exactly at EOF
	path = wal_test_three(c"tail_sum.log")
	wal_test_poke(path, 32 + 8, 88)
	w = wal_open_policy(path, WAL_RECOVER_STRICT, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_TAIL_TORN, rep.tail)
	assert_equal(WAL_BAD_CHECKSUM, rep.reason)
	assert_equal(32, rep.bad_offset)
	wal_close(w)
	free(path)
	# a zero-filled extent after the last good record
	path = wal_test_three(c"tail_zero.log")
	char* zeros = cast(char*, malloc(40))
	mem_fill(zeros, 0, 40)
	fd = open(path, 2, 0)
	seek(fd, 44, 0)
	assert_equal(40, write_all(fd, zeros, 40))
	close(fd)
	free(zeros)
	w = wal_open_policy(path, WAL_RECOVER_STRICT_TRUNCATE, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_TAIL_TORN, rep.tail)
	assert_equal(1, rep.truncated)
	assert_equal(3, wal_record_count(w))
	wal_close(w)
	assert_equal(44, wal_test_file_size(path))
	free(path)


# ---- durable replacement ------------------------------------------------------

void wal_test_expect_records(char* path, char* first, int count):
	wal_recovery rep
	wal* w = wal_open_policy(path, WAL_RECOVER_STRICT, &rep)
	assert1(cast(int, w) != 0)
	assert_equal(WAL_TAIL_CLEAN, rep.tail)
	assert_equal(count, wal_record_count(w))
	wal_close(w)
	wal_reader* rd = wal_reader_open(path)
	int n = 0
	char* p = wal_read_next(rd, &n)
	assert_strings_equal(first, p)
	free(p)
	wal_reader_close(rd)


# A rewrite interrupted at every stage leaves the complete old log
# (before the rename) or the complete new log (after it); a leftover
# sibling is an uncommitted rewrite and the next open deletes it.
void test_rewrite_crash_stages():
	char* path = wal_test_three(c"rewrite.log")
	char* sibling = strjoin(path, c".next")
	fs_replace_report rep
	wal_recovery orep
	# crash before the sibling's fsync, then before the rename
	int stage = FS_STAGE_SYNC_FILE
	while (stage <= FS_STAGE_RENAME):
		wal* live = wal_open(path)
		wal* next = wal_rewrite_begin(live)
		assert1(cast(int, next) != 0)
		assert_equal(1, wal_append(next, c"new", 3))
		wal_test_crash_stage = stage
		assert_equal(IO_INTERRUPTED, wal_rewrite_commit(live, next, &rep))
		assert_equal(stage, rep.stage)
		assert_equal(0, rep.renamed)
		assert_equal(3, wal_record_count(live))
		wal_close(live)
		assert_equal(1, wal_test_exists(sibling))
		wal* w = wal_open_policy(path, WAL_RECOVER_STRICT, &orep)
		assert1(cast(int, w) != 0)
		assert_equal(1, orep.stale_sibling)
		wal_close(w)
		assert_equal(0, wal_test_exists(sibling))
		wal_test_expect_records(path, c"aaaa", 3)
		stage = stage + 2
	# crash after the rename, before the directory fsync: the new log
	wal* live2 = wal_open(path)
	wal* next2 = wal_rewrite_begin(live2)
	assert_equal(1, wal_append(next2, c"new", 3))
	wal_test_crash_stage = FS_STAGE_SYNC_DIR
	assert_equal(IO_INTERRUPTED, wal_rewrite_commit(live2, next2, &rep))
	assert_equal(1, rep.renamed)
	assert_equal(1, wal_record_count(live2))
	wal_close(live2)
	assert_equal(0, wal_test_exists(sibling))
	wal_test_expect_records(path, c"new", 1)
	# a full commit: the live handle switches and keeps appending
	wal* live3 = wal_open(path)
	wal* next3 = wal_rewrite_begin(live3)
	assert_equal(1, wal_append(next3, c"newer", 5))
	assert_equal(IO_OK, wal_rewrite_commit(live3, next3, &rep))
	assert_equal(FS_STAGE_NONE, rep.stage)
	assert_equal(1, rep.renamed)
	assert_equal(1, wal_append(live3, c"tail", 4))
	assert_equal(1, wal_sync(live3))
	wal_close(live3)
	wal_test_expect_records(path, c"newer", 2)
	# an aborted rewrite removes its sibling and changes nothing
	wal* live4 = wal_open(path)
	wal* next4 = wal_rewrite_begin(live4)
	assert_equal(1, wal_test_exists(sibling))
	wal_rewrite_abort(next4)
	assert_equal(0, wal_test_exists(sibling))
	wal_close(live4)
	wal_test_expect_records(path, c"newer", 2)
	# a sync failure on the sibling aborts before the rename
	wal* live5 = wal_open(path)
	wal* next5 = wal_rewrite_begin(live5)
	wal_inject_sync_failures(next5, 1)
	assert1(wal_rewrite_commit(live5, next5, &rep) != IO_OK)
	assert_equal(FS_STAGE_SYNC_FILE, rep.stage)
	assert_equal(0, rep.renamed)
	assert_equal(0, wal_test_exists(sibling))
	wal_close(live5)
	wal_test_expect_records(path, c"newer", 2)
	free(sibling)
	free(path)


# A failed fsync poisons the handle: no later sync may report success
# (the kernel may have dropped the dirty pages), and appends stop.
void test_failed_sync_poisons_handle():
	char* path = wal_test_path(c"poison.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	assert_equal(1, wal_append(w, c"one", 3))
	wal_inject_sync_failures(w, 1)
	assert_equal(0, wal_sync(w))
	assert_equal(1, wal_failed(w))
	assert_equal(0, wal_sync(w))
	assert_equal(0, wal_append(w, c"two", 3))
	wal_close(w)
	# reopening recovers whatever reached the file
	w = wal_open(path)
	assert_equal(0, wal_failed(w))
	assert_equal(1, wal_record_count(w))
	wal_close(w)
	free(path)


# Oversized and negative appends are refused with 0, not asserted.
void test_append_refuses_bad_lengths():
	char* path = wal_test_path(c"badlen.log")
	create_file(path, 420)
	wal* w = wal_open(path)
	assert_equal(0, wal_append(w, c"x", 0 - 1))
	assert_equal(0, wal_append(w, c"x", wal_max_record() + 1))
	assert_equal(0, wal_failed(w))
	assert_equal(1, wal_append(w, c"ok", 2))
	wal_close(w)
	free(path)
