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
	char* buf = malloc(full)
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
	char* blob = malloc(4)
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
