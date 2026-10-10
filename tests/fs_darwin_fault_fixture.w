# Run by tools/mac/test_fs_durability.py with a private syscall import
# root. fs_replace_durable itself is compiled without modification.
import lib.fs
import lib.assert
import tests.fs_darwin_fault_hooks


int main(int argc, char** argv):
	if (argc != 5): return 2
	fs_fault_stage = atoi(argv[2])
	fs_fault_kill = atoi(argv[3])
	fs_fault_errno = atoi(argv[4])
	fs_replace_report rep
	int status = fs_replace_durable(argv[1], c"new contents", 12, &rep)
	if (fs_fault_stage == 0):
		assert_equal(IO_OK, status)
		assert_equal(FS_STAGE_NONE, rep.stage)
		assert_equal(1, rep.renamed)
		assert_equal(2, fs_fault_sync_count)
	else:
		# Crash cases must never get here.
		assert_equal(0, fs_fault_kill)
		int expected = io_status_from_errno(fs_fault_errno)
		if (fs_fault_errno == FS_EINVAL): expected = IO_UNSUPPORTED
		assert_equal(expected, status)
		assert_equal(status, rep.status)
		assert_equal(fs_fault_errno, rep.native_error)
		if (fs_fault_stage == 1):
			assert_equal(FS_STAGE_SYNC_FILE, rep.stage)
			assert_equal(0, rep.renamed)
		else if (fs_fault_stage == 3):
			assert_equal(FS_STAGE_RENAME, rep.stage)
			assert_equal(0, rep.renamed)
		else:
			assert_equal(FS_STAGE_SYNC_DIR, rep.stage)
			assert_equal(1, rep.renamed)
	assert_equal(12, rep.transferred)
	return 0
