# wasm twin of lib/__arch__/x86/statfs.w: no Linux statfs(2) here, so
# callers see a negative errno-style failure -- the same stub
# convention as this directory's syscalls.w statx.


int STATFS_BUF_SIZE():
	return 128


int statfs_fill(char* path, char* buf, int* out):
	return -1
