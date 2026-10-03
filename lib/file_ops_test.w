# wbuild: x64
import lib.testing
import lib.fake_fs


/*
Real-I/O parity: one small storage scenario (create, write, sync,
rename, directory sync, read back, append, unlink, plus the common
errors) runs against the real adapter on files under bin/ and against
the fake filesystem; every step's status, errno and transfer count and
every byte read must agree.
*/


struct parity_log:
	list[int] values
	char* base


void parity_note(parity_log* log, int status, io_result* r):
	log.values.push(status)
	log.values.push(r.status)
	log.values.push(r.native_error)
	log.values.push(r.transferred)


char* parity_path(parity_log* log, char* name):
	int n = strlen(log.base)
	int m = strlen(name)
	char* out = malloc(n + m + 2)
	mem_copy[char](out, log.base, n)
	out[n] = '/'
	mem_copy[char](&out[n + 1], name, m)
	out[n + m + 1] = 0
	return out


void parity_scenario(file_ops* ops, parity_log* log):
	io_result r
	int fd = -1
	char* tmp = parity_path(log, c"tmp")
	char* final = parity_path(log, c"final")
	char* missing = parity_path(log, c"missing")
	char* text = c"hello parity world"
	char* buf = malloc(64)

	parity_note(log, file_ops_mkdir(ops, log.base, 493, &r), &r)
	parity_note(log, file_ops_open(ops, missing, FILE_OPS_READ, 0, &fd, &r), &r)
	log.values.push(fd)
	parity_note(log, file_ops_open(ops, tmp, FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_TRUNCATE, 420, &fd, &r), &r)
	parity_note(log, file_ops_write_all(ops, fd, text, strlen(text), &r), &r)
	parity_note(log, file_ops_sync(ops, fd, &r), &r)
	parity_note(log, file_ops_close(ops, fd, &r), &r)
	int other = -1
	int excl = FILE_OPS_WRITE | FILE_OPS_CREATE | FILE_OPS_EXCLUSIVE
	parity_note(log, file_ops_open(ops, tmp, excl, 420, &other, &r), &r)
	parity_note(log, file_ops_rename(ops, tmp, final, &r), &r)
	parity_note(log, file_ops_sync_dir(ops, log.base, &r), &r)

	parity_note(log, file_ops_open(ops, final, FILE_OPS_READ, 0, &fd, &r), &r)
	parity_note(log, file_ops_read_to_end(ops, fd, buf, 64, &r), &r)
	for i in range(r.transferred): log.values.push(buf[i])
	parity_note(log, file_ops_read(ops, fd, buf, 8, &r), &r)
	parity_note(log, file_ops_write(ops, fd, c"no", 2, &r), &r)
	parity_note(log, file_ops_close(ops, fd, &r), &r)

	parity_note(log, file_ops_open(ops, final, FILE_OPS_WRITE | FILE_OPS_APPEND, 0, &fd, &r), &r)
	parity_note(log, file_ops_write_all(ops, fd, c"!", 1, &r), &r)
	parity_note(log, file_ops_datasync(ops, fd, &r), &r)
	parity_note(log, file_ops_read(ops, fd, buf, 8, &r), &r)
	parity_note(log, file_ops_close(ops, fd, &r), &r)
	parity_note(log, file_ops_open(ops, final, FILE_OPS_READ, 0, &fd, &r), &r)
	parity_note(log, file_ops_read_exact(ops, fd, buf, 19, &r), &r)
	for i in range(r.transferred): log.values.push(buf[i])
	parity_note(log, file_ops_read_exact(ops, fd, buf, 5, &r), &r)
	parity_note(log, file_ops_close(ops, fd, &r), &r)

	parity_note(log, file_ops_unlink(ops, tmp, &r), &r)
	parity_note(log, file_ops_unlink(ops, final, &r), &r)
	parity_note(log, file_ops_open(ops, final, FILE_OPS_READ, 0, &fd, &r), &r)
	free(buf)
	free(tmp)
	free(final)
	free(missing)


parity_log* parity_log_new(char* base):
	parity_log* log = new parity_log()
	log.values = new list[int]
	log.base = base
	return log


void test_real_and_fake_agree():
	char* base = c"bin/file_ops_parity_x86"
	if (__word_size__ == 8): base = c"bin/file_ops_parity_x64"
	parity_log* real_log = parity_log_new(base)
	# Leftovers from an interrupted earlier run.
	char* p = parity_path(real_log, c"tmp")
	unlink(p)
	free(p)
	p = parity_path(real_log, c"final")
	unlink(p)
	free(p)
	rmdir(base)

	file_ops* real = file_ops_real_new()
	parity_scenario(real, real_log)
	assert_equal(0, rmdir(base))
	free(real)

	fake_fs* fs = fake_fs_new(1)
	io_result r
	assert_equal(IO_OK, file_ops_mkdir(fake_fs_ops(fs), c"bin", 493, &r))
	parity_log* fake_log = parity_log_new(base)
	parity_scenario(fake_fs_ops(fs), fake_log)

	assert_equal(real_log.values.length, fake_log.values.length)
	for i in range(real_log.values.length):
		if (real_log.values[i] != fake_log.values[i]):
			print2(c"parity mismatch at value ")
			println2(itoa(i))
		assert_equal(real_log.values[i], fake_log.values[i])
	# Spot checks that the scenario exercised what it claims.
	assert_equal(IO_IO_ERROR, real_log.values[4])
	assert_equal(2, real_log.values[6])
	assert1(fake_fs_op_count(fs) > 20)
	fake_fs_free(fs)


# The real adapter's sync_dir on a missing directory reports ENOENT.
void test_real_sync_dir_missing():
	file_ops* real = file_ops_real_new()
	io_result r
	assert_equal(IO_IO_ERROR, file_ops_sync_dir(real, c"bin/no_such_dir_for_file_ops", &r))
	assert_equal(2, r.native_error)
	free(real)


void test_parent():
	char* p = file_ops_parent(c"a/b/c")
	assert_strings_equal(c"a/b", p)
	free(p)
	p = file_ops_parent(c"c")
	assert_strings_equal(c".", p)
	free(p)
	p = file_ops_parent(c"/c")
	assert_strings_equal(c"/", p)
	free(p)
