# Single-owner storage cursors. A null ops selects the native adapter;
# injected tables are borrowed and must outlive every handle/reader.
# Count helpers return -1 on error (never confuse EIO with a torn EOF).
import lib.file_ops
import lib.fs


int storage_open(file_ops* ops, char* path, int flags, int mode):
	io_result r
	int fd = -1
	if (cast(int, ops) == 0): file_ops_real_open(0, path, flags, mode, &fd, &r)
	else: file_ops_open(ops, path, flags, mode, &fd, &r)
	return fd


int storage_close(file_ops* ops, int fd):
	io_result r
	int status = IO_OK
	if (cast(int, ops) == 0): status = file_ops_real_close(0, fd, &r)
	else: status = file_ops_close(ops, fd, &r)
	if (status != IO_OK): return -1
	return 0


int storage_seek(file_ops* ops, int fd, int offset, int whence):
	io_result r
	int status = IO_OK
	if (cast(int, ops) == 0): status = file_ops_real_seek(0, fd, offset, whence, &r)
	else: status = file_ops_seek(ops, fd, offset, whence, &r)
	if (status != IO_OK): return -1
	return r.transferred


int storage_size(file_ops* ops, int fd):
	int pos = storage_seek(ops, fd, 0, 1)
	if (pos < 0): return -1
	int size = storage_seek(ops, fd, 0, 2)
	if (storage_seek(ops, fd, pos, 0) < 0): return -1
	return size


int storage_read(file_ops* ops, int fd, char* data, int length):
	io_result r
	int status = IO_OK
	if (cast(int, ops) == 0): status = io_read_exact(fd, data, length, &r)
	else: status = file_ops_read_exact(ops, fd, data, length, &r)
	if (status != IO_OK && status != IO_EOF): return -1
	return r.transferred


int storage_write(file_ops* ops, int fd, char* data, int length):
	io_result r
	int status = IO_OK
	if (cast(int, ops) == 0): status = io_write_all(fd, data, length, &r)
	else: status = file_ops_write_all(ops, fd, data, length, &r)
	if (status != IO_OK): return -1
	return r.transferred


int storage_sync(file_ops* ops, int fd, io_result* r):
	if (cast(int, ops) == 0): return fs_fsync(fd, r)
	return file_ops_sync(ops, fd, r)


int storage_truncate(file_ops* ops, int fd, int length, io_result* r):
	if (cast(int, ops) == 0): return fs_ftruncate(fd, length, r)
	return file_ops_truncate(ops, fd, length, r)


int storage_unlink(file_ops* ops, char* path):
	io_result r
	if (cast(int, ops) == 0): return unlink(path)
	if (file_ops_unlink(ops, path, &r) != IO_OK): return -1
	return 0


int storage_rename(file_ops* ops, char* from, char* to, io_result* r):
	if (cast(int, ops) == 0): return file_ops_real_rename(0, from, to, r)
	return file_ops_rename(ops, from, to, r)


int storage_sync_parent(file_ops* ops, char* path, io_result* r):
	if (cast(int, ops) == 0): return fs_sync_parent_dir(path, r)
	char* parent = file_ops_parent(path)
	int status = file_ops_sync_dir(ops, parent, r)
	free(parent)
	return status
