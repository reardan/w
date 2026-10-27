# Test-only syscall interception, imported by the private import root
# built by tools/linux_fs_qualification.w. Production has no hooks.
# Self-contained: the raw syscall numbers below are the target's own
# (i386, x86-64, generic AArch64), so this module needs nothing that
# the patched syscall adapter defines after importing it.
int fs_fault_stage
int fs_fault_kill
int fs_fault_errno
int fs_fault_sync_count


int fs_fault_event(int stage):
	if (stage != fs_fault_stage): return 0
	if (fs_fault_kill):
		# SIGKILL the current process without running cleanup.
		if (__target_isa__ == 1): syscall(129, syscall(172, 0, 0, 0), 9, 0)
		else if (__word_size__ == 8): syscall(62, syscall(39, 0, 0, 0), 9, 0)
		else: syscall(37, syscall(20, 0, 0, 0), 9, 0)
	return 0 - fs_fault_errno


int fs_fault_real_fsync(int fd):
	if (__target_isa__ == 1): return syscall(82, fd, 0, 0)
	if (__word_size__ == 8): return syscall(74, fd, 0, 0)
	return syscall(118, fd, 0, 0)


int fs_fault_real_rename(char* from, char* to):
	# AArch64 has only renameat: both directories AT_FDCWD (-100).
	if (__target_isa__ == 1): return syscall7(38, -100, from, -100, to, 0, 0)
	if (__word_size__ == 8): return syscall(82, from, to, 0)
	return syscall(38, from, to, 0)


# The first fsync of a replacement is the temp file's, the second the
# parent directory's: events 1/2 and 5/6 surround them.
int fs_fault_fsync(int fd):
	fs_fault_sync_count = fs_fault_sync_count + 1
	int before = 1
	if (fs_fault_sync_count == 2): before = 5
	int ret = fs_fault_event(before)
	if (ret < 0): return ret
	ret = fs_fault_real_fsync(fd)
	if (ret < 0): return ret
	return fs_fault_event(before + 1)


int fs_fault_rename(char* from, char* to):
	int ret = fs_fault_event(3)
	if (ret < 0): return ret
	ret = fs_fault_real_rename(from, to)
	if (ret < 0): return ret
	return fs_fault_event(4)
