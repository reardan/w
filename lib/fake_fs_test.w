# wbuild: x64
import lib.testing
import lib.fake_fs


/*
Crash and fault behaviour of the fake filesystem (lib/fake_fs.w). Every
outcome here is a function of the seeds alone; the x64 twin must
reproduce each one.
*/


# Creates path with contents, optionally syncing the file and its directory.
void fs_test_put(file_ops* ops, char* path, char* text, int sync_file, int sync_dir):
	io_result r
	int fd = -1
	assert_equal(IO_OK, file_ops_open(ops, path, FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_TRUNCATE, 420, &fd, &r))
	assert_equal(IO_OK, file_ops_write_all(ops, fd, text, strlen(text), &r))
	assert_equal(strlen(text), r.transferred)
	if (sync_file): assert_equal(IO_OK, file_ops_sync(ops, fd, &r))
	assert_equal(IO_OK, file_ops_close(ops, fd, &r))
	if (sync_dir):
		char* dir = file_ops_parent(path)
		assert_equal(IO_OK, file_ops_sync_dir(ops, dir, &r))
		free(dir)


void test_unsynced_write_is_lost_and_synced_write_kept():
	fake_fs* fs = fake_fs_new(1)
	file_ops* ops = fake_fs_ops(fs)
	fs_test_put(ops, c"lost", c"volatile bytes", 0, 1)
	fs_test_put(ops, c"kept", c"durable bytes", 1, 1)
	# Write-completed: visible before the crash.
	assert1(fake_fs_file_equals(fs, c"lost", c"volatile bytes", 14))
	assert_equal(1, fake_fs_pending_changes(fs, c"lost"))
	assert_equal(0, fake_fs_pending_changes(fs, c"kept"))
	fake_fs_crash(fs, 0)
	# The name was synced, the data was not.
	assert1(fake_fs_exists(fs, c"lost"))
	assert_equal(0, fake_fs_file_size(fs, c"lost"))
	assert1(fake_fs_file_equals(fs, c"kept", c"durable bytes", 13))
	fake_fs_free(fs)


# fsync makes data durable, not the directory entry pointing at it.
void test_synced_file_without_dir_sync_vanishes():
	fake_fs* fs = fake_fs_new(1)
	file_ops* ops = fake_fs_ops(fs)
	fs_test_put(ops, c"orphan", c"data", 1, 0)
	assert_equal(1, fake_fs_pending_meta(fs))
	fake_fs_crash(fs, 0)
	assert_equal(0, fake_fs_exists(fs, c"orphan"))
	fake_fs_free(fs)


void test_rename_needs_dir_sync():
	fake_fs* fs = fake_fs_new(1)
	file_ops* ops = fake_fs_ops(fs)
	io_result r
	fs_test_put(ops, c"state.tmp", c"v2", 1, 1)
	assert_equal(IO_OK, file_ops_rename(ops, c"state.tmp", c"state", &r))
	assert1(fake_fs_exists(fs, c"state"))
	fake_fs_crash(fs, 0)
	# Unsynced rename: the old name is back, the new one never existed.
	assert1(fake_fs_exists(fs, c"state.tmp"))
	assert_equal(0, fake_fs_exists(fs, c"state"))
	assert_equal(IO_OK, file_ops_rename(ops, c"state.tmp", c"state", &r))
	assert_equal(IO_OK, file_ops_sync_dir(ops, c".", &r))
	fake_fs_crash(fs, 0)
	assert_equal(0, fake_fs_exists(fs, c"state.tmp"))
	assert1(fake_fs_file_equals(fs, c"state", c"v2", 2))
	fake_fs_free(fs)


# An unsynced rename may or may not survive a seeded crash: over a range
# of seeds both outcomes occur, and never anything else.
void test_seeded_crash_may_keep_unsynced_rename():
	int kept = 0
	int lost = 0
	for seed in range(1, 41):
		fake_fs* fs = fake_fs_new(1)
		file_ops* ops = fake_fs_ops(fs)
		io_result r
		fs_test_put(ops, c"a.tmp", c"payload", 1, 1)
		assert_equal(IO_OK, file_ops_rename(ops, c"a.tmp", c"a", &r))
		prng* rng = prng_new(seed)
		fake_fs_crash(fs, rng)
		prng_free(rng)
		if (fake_fs_exists(fs, c"a")):
			assert_equal(0, fake_fs_exists(fs, c"a.tmp"))
			assert1(fake_fs_file_equals(fs, c"a", c"payload", 7))
			kept = kept + 1
		else:
			assert1(fake_fs_file_equals(fs, c"a.tmp", c"payload", 7))
			lost = lost + 1
		fake_fs_free(fs)
	assert1(kept > 0)
	assert1(lost > 0)


# Torn writes keep a sector-aligned prefix of the first unkept write.
void test_torn_write_keeps_sector_prefix():
	int torn = 0
	for seed in range(1, 61):
		fake_fs* fs = fake_fs_new(1)
		fake_fs_set_sector(fs, 4)
		file_ops* ops = fake_fs_ops(fs)
		fs_test_put(ops, c"log", c"AB", 1, 1)
		io_result r
		int fd = -1
		assert_equal(IO_OK, file_ops_open(ops, c"log", FILE_OPS_WRITE | FILE_OPS_APPEND, 0, &fd, &r))
		# Bytes 2..17: sector boundaries at 4, 8, 12, 16.
		assert_equal(IO_OK, file_ops_write_all(ops, fd, c"cdefghijklmnopqr", 16, &r))
		prng* rng = prng_new(seed)
		fake_fs_crash(fs, rng)
		prng_free(rng)
		int size = fake_fs_file_size(fs, c"log")
		assert1((size == 2) || (size == 4) || (size == 8) || (size == 12) || (size == 16) || (size == 18))
		assert1(fake_fs_file_equals(fs, c"log", c"ABcdefghijklmnopqr", size))
		if ((size != 2) && (size != 18)): torn = torn + 1
		# The descriptor did not survive the crash.
		assert_equal(IO_IO_ERROR, file_ops_write(ops, fd, c"x", 1, &r))
		assert_equal(FAKE_FS_EBADF, r.native_error)
		fake_fs_free(fs)
	assert1(torn > 0)


# A small storage workload under rate faults, then a seeded crash.
void fs_test_workload(fake_fs* fs, int crash_seed):
	file_ops* ops = fake_fs_ops(fs)
	io_result r
	assert_equal(IO_OK, file_ops_mkdir(ops, c"db", 493, &r))
	char* block = cast(char*, malloc(300))
	for i in range(300): block[i] = 'a' + (i % 26)
	for round in range(4):
		int fd = -1
		int flags = FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_APPEND
		while (file_ops_open(ops, c"db/wal", flags, 420, &fd, &r) != IO_OK): continue
		while (file_ops_write_all(ops, fd, block, 300, &r) != IO_OK): continue
		if (round % 2 == 0): file_ops_sync(ops, fd, &r)
		file_ops_close(ops, fd, &r)
		if (round == 1):
			file_ops_rename(ops, c"db/wal", c"db/wal.old", &r)
			file_ops_sync_dir(ops, c"db", &r)
	free(block)
	prng* rng = prng_new(crash_seed)
	fake_fs_crash(fs, rng)
	prng_free(rng)


void test_same_seed_same_schedule_and_crash():
	int[4] trace
	int[4] state
	for i in range(4):
		fake_fs* fs = fake_fs_new(100 + i / 2)
		fake_fs_set_faults(fs, (1 << FAKE_FS_OP_WRITE) | (1 << FAKE_FS_OP_OPEN), 300, 150, 50, 0, 0)
		fs_test_workload(fs, 7 + i / 2)
		trace[i] = fake_fs_trace_hash(fs)
		state[i] = fake_fs_state_hash(fs)
		fake_fs_free(fs)
	assert_equal(trace[0], trace[1])
	assert_equal(state[0], state[1])
	assert_equal(trace[2], trace[3])
	assert_equal(state[2], state[3])
	assert1(trace[0] != trace[2])
	# Observed once on x86 and frozen: the x64 twin must match exactly.
	assert_equal(1242189896, trace[0])
	assert_equal(1931543872, state[0])
	assert_equal(42673958, trace[2])
	assert_equal(640189865, state[2])


# Different crash seeds over the same state reach different outcomes.
void test_different_seeds_can_differ():
	list[int] seen = new list[int]
	for seed in range(1, 21):
		fake_fs* fs = fake_fs_new(5)
		fs_test_workload(fs, seed)
		int h = fake_fs_state_hash(fs)
		if ((h in seen) == 0): seen.push(h)
		fake_fs_free(fs)
	assert1(seen.length >= 3)
	list_free[int](seen)


# Short writes and EINTR are absorbed by write_all; EAGAIN is returned.
void test_short_and_interrupted_writes():
	fake_fs* fs = fake_fs_new(42)
	file_ops* ops = fake_fs_ops(fs)
	io_result r
	int fd = -1
	assert_equal(IO_OK, file_ops_open(ops, c"f", FILE_OPS_READ_WRITE | FILE_OPS_CREATE, 420, &fd, &r))
	fake_fs_set_faults(fs, (1 << FAKE_FS_OP_WRITE) | (1 << FAKE_FS_OP_READ), 400, 300, 0, 0, 0)
	char* data = cast(char*, malloc(1000))
	for i in range(1000): data[i] = i % 251
	assert_equal(IO_OK, file_ops_write_all(ops, fd, data, 1000, &r))
	assert_equal(1000, r.transferred)
	assert1(fake_fs_op_count(fs) > 3)
	assert1(fake_fs_file_equals(fs, c"f", data, 1000))
	file_ops_close(ops, fd, &r)
	assert_equal(IO_OK, file_ops_open(ops, c"f", FILE_OPS_READ, 0, &fd, &r))
	char* back = cast(char*, malloc(1200))
	assert_equal(IO_OK, file_ops_read_to_end(ops, fd, back, 1200, &r))
	assert_equal(1000, r.transferred)
	assert1(mem_eq[char](back, data, 1000))
	file_ops_close(ops, fd, &r)
	# EAGAIN surfaces with the confirmed prefix.
	fake_fs_set_faults(fs, 0, 0, 0, 0, 0, 0)
	assert_equal(IO_OK, file_ops_open(ops, c"g", FILE_OPS_WRITE | FILE_OPS_CREATE, 420, &fd, &r))
	fake_fs_fail_nth(fs, FAKE_FS_OP_WRITE, 1, FAKE_FS_EAGAIN)
	assert_equal(IO_WOULD_BLOCK, file_ops_write_all(ops, fd, data, 10, &r))
	assert_equal(0, r.transferred)
	assert_equal(FAKE_FS_EAGAIN, r.native_error)
	assert_equal(0, fake_fs_file_size(fs, c"g"))
	free(back)
	free(data)
	fake_fs_free(fs)


void test_fail_nth_and_capacity():
	fake_fs* fs = fake_fs_new(3)
	file_ops* ops = fake_fs_ops(fs)
	io_result r
	int fd = -1
	assert_equal(IO_OK, file_ops_open(ops, c"f", FILE_OPS_WRITE | FILE_OPS_CREATE, 420, &fd, &r))
	fake_fs_fail_nth(fs, FAKE_FS_OP_WRITE, 2, FAKE_FS_EIO)
	assert_equal(IO_OK, file_ops_write(ops, fd, c"one", 3, &r))
	assert_equal(IO_IO_ERROR, file_ops_write(ops, fd, c"two", 3, &r))
	assert_equal(FAKE_FS_EIO, r.native_error)
	assert_equal(IO_OK, file_ops_write(ops, fd, c"six", 3, &r))
	assert1(fake_fs_file_equals(fs, c"f", c"onesix", 6))
	# Any-kind rule: the very next operation fails.
	fake_fs_fail_nth(fs, FAKE_FS_OP_ANY, 1, FAKE_FS_EINTR)
	assert_equal(IO_INTERRUPTED, file_ops_sync(ops, fd, &r))
	assert_equal(1, fake_fs_pending_changes(fs, c"f") >= 1)
	# Capacity: 10 bytes in all; 6 used.
	fake_fs_set_capacity(fs, 10)
	assert_equal(IO_OK, file_ops_write(ops, fd, c"abcdefgh", 8, &r))
	assert_equal(4, r.transferred)
	assert_equal(IO_NO_SPACE, file_ops_write(ops, fd, c"z", 1, &r))
	assert_equal(FAKE_FS_ENOSPC, r.native_error)
	assert_equal(IO_NO_SPACE, file_ops_write_all(ops, fd, c"zz", 2, &r))
	assert1(fake_fs_file_equals(fs, c"f", c"onesixabcd", 10))
	file_ops_close(ops, fd, &r)
	fake_fs_free(fs)


# A failed fsync drops the unsynced data for good (Linux semantics):
# readable now, gone after a crash even though a later sync succeeded.
void test_failed_sync_loses_data():
	fake_fs* fs = fake_fs_new(9)
	file_ops* ops = fake_fs_ops(fs)
	io_result r
	fs_test_put(ops, c"f", c"base", 1, 1)
	int fd = -1
	assert_equal(IO_OK, file_ops_open(ops, c"f", FILE_OPS_WRITE | FILE_OPS_APPEND, 0, &fd, &r))
	assert_equal(IO_OK, file_ops_write_all(ops, fd, c"-lost", 5, &r))
	fake_fs_fail_nth(fs, FAKE_FS_OP_SYNC, 1, FAKE_FS_EIO)
	assert_equal(IO_IO_ERROR, file_ops_sync(ops, fd, &r))
	assert_equal(IO_OK, file_ops_write_all(ops, fd, c"-kept", 5, &r))
	assert_equal(IO_OK, file_ops_datasync(ops, fd, &r))
	assert1(fake_fs_file_equals(fs, c"f", c"base-lost-kept", 14))
	fake_fs_crash(fs, 0)
	assert1(fake_fs_file_equals(fs, c"f", c"base\0\0\0\0\0-kept", 14))
	fake_fs_free(fs)


void test_namespace_errors_and_directory_rename():
	fake_fs* fs = fake_fs_new(2)
	file_ops* ops = fake_fs_ops(fs)
	io_result r
	int fd = -1
	assert_equal(IO_IO_ERROR, file_ops_open(ops, c"missing", FILE_OPS_READ, 0, &fd, &r))
	assert_equal(FAKE_FS_ENOENT, r.native_error)
	assert_equal(-1, fd)
	assert_equal(IO_IO_ERROR, file_ops_open(ops, c"nodir/f", FILE_OPS_WRITE | FILE_OPS_CREATE, 420, &fd, &r))
	assert_equal(FAKE_FS_ENOENT, r.native_error)
	assert_equal(IO_OK, file_ops_mkdir(ops, c"d", 493, &r))
	assert_equal(IO_IO_ERROR, file_ops_mkdir(ops, c"d", 493, &r))
	assert_equal(FAKE_FS_EEXIST, r.native_error)
	fs_test_put(ops, c"d/f", c"x", 1, 1)
	int excl = FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_EXCLUSIVE
	assert_equal(IO_IO_ERROR, file_ops_open(ops, c"d/f", excl, 420, &fd, &r))
	assert_equal(FAKE_FS_EEXIST, r.native_error)
	assert_equal(IO_OK, file_ops_rename(ops, c"d", c"e", &r))
	assert1(fake_fs_file_equals(fs, c"e/f", c"x", 1))
	assert_equal(0, fake_fs_exists(fs, c"d/f"))
	fake_fs_crash(fs, 0)
	# The unsynced directory rename is undone.
	assert1(fake_fs_file_equals(fs, c"d/f", c"x", 1))
	assert_equal(IO_OK, file_ops_rename(ops, c"d", c"e", &r))
	assert_equal(IO_OK, file_ops_mkdir(ops, c"e/sub", 493, &r))
	# Syncing "." through a directory descriptor commits the rename but
	# not the later mkdir inside "e".
	int root = -1
	assert_equal(IO_OK, file_ops_open(ops, c".", FILE_OPS_READ, 0, &root, &r))
	assert_equal(IO_OK, file_ops_sync(ops, root, &r))
	assert_equal(1, fake_fs_pending_meta(fs))
	assert_equal(IO_OK, file_ops_open(ops, c"e", FILE_OPS_READ, 0, &fd, &r))
	assert_equal(IO_OK, file_ops_sync(ops, fd, &r))
	assert_equal(0, fake_fs_pending_meta(fs))
	fake_fs_crash(fs, 0)
	assert1(fake_fs_file_equals(fs, c"e/f", c"x", 1))
	assert1(fake_fs_exists(fs, c"e/sub"))
	assert_equal(IO_OK, file_ops_unlink(ops, c"e/f", &r))
	assert_equal(IO_IO_ERROR, file_ops_unlink(ops, c"e/f", &r))
	assert_equal(FAKE_FS_ENOENT, r.native_error)
	fake_fs_free(fs)
