# Test-only syscall interception, imported by the private import root
# built by tools/mac/test_fs_durability.py. Production has no hooks.
int fs_fault_stage
int fs_fault_kill
int fs_fault_errno
int fs_fault_sync_count


int fs_fault_event(int stage):
	if (stage != fs_fault_stage): return 0
	if (fs_fault_kill):
		# SIGKILL the current process without running cleanup.
		syscall(37, syscall(20, 0, 0, 0), 9, 0)
	return 0 - fs_fault_errno


int fs_fault_fullsync(int fd):
	fs_fault_sync_count = fs_fault_sync_count + 1
	int before = 1
	if (fs_fault_sync_count == 2): before = 5
	int ret = fs_fault_event(before)
	if (ret < 0): return ret
	ret = syscall(92, fd, 51, 0)  # real Darwin F_FULLFSYNC
	if (ret < 0): return ret
	return fs_fault_event(before + 1)


int fs_fault_rename(char* from, char* to):
	int ret = fs_fault_event(3)
	if (ret < 0): return ret
	ret = syscall(128, from, to, 0)  # real Darwin rename
	if (ret < 0): return ret
	return fs_fault_event(4)
