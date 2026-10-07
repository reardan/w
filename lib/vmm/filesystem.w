# Opt-in directory capability for x64 cells. Guest descriptors never name
# host descriptors. Paths are relative to the configured root (including
# guest absolute paths); symlinks and mount crossings are intentionally denied.
# Existing inodes are pinned and type-checked BEFORE an ordinary open, so
# opening a device/FIFO cannot cause host side effects or block the watchdog.
import lib.vmm.memory

struct cell_filesystem:
	int root
	int writable
	int* descriptors


int cell_fs_resolve(int dir, char* path, int flags, int mode):
	char[24] how
	save_int64(&how[0], flags | 524288) # O_CLOEXEC
	save_int64(&how[8], mode)
	save_int64(&how[16], 15) # BENEATH | NO_SYMLINKS | NO_MAGICLINKS | NO_XDEV
	return syscall7(437, dir, cast(int, path), cast(int, &how[0]), 24, 0, 0)


void cell_fs_free(vm_cell* cell):
	cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
	if (fs == 0): return
	for i in range(61):
		if (fs.descriptors[i] >= 0): close(fs.descriptors[i])
	close(fs.root)
	free(fs.descriptors)
	free(fs)
	cell.fs_state = 0


int cell_fs_configure(vm_cell* cell, char* root, int writable):
	if (__word_size__ != 8 || cell.started || cell.fs_state != 0): return cell_fail(cell, c"filesystem must be configured once before execution on x64")
	int fd = open(root, 2686976, 0) # O_PATH | O_DIRECTORY | O_CLOEXEC
	if (fd < 0): return cell_fail(cell, c"cannot open filesystem root")
	int probe = cell_fs_resolve(fd, c".", 2162688, 0)
	if (probe < 0):
		close(fd)
		return cell_fail(cell, c"filesystem confinement requires Linux openat2")
	close(probe)
	cell_filesystem* fs = cast(cell_filesystem*, malloc(sizeof(cell_filesystem)))
	fs.root = fd
	fs.writable = writable != 0
	fs.descriptors = cast(int*, malloc(61 * sizeof(int)))
	for i in range(61): fs.descriptors[i] = -1
	cell.fs_state = cast(void*, fs)
	cell.fs_cleanup = cast(void*, cell_fs_free)
	return 1


int cell_fs_descriptor(cell_filesystem* fs, int fd):
	if (fd < 3 || fd > 63): return -9
	return fs.descriptors[fd - 3]


int cell_fs_path(vm_cell* cell, int address, char* path):
	for i in range(4096):
		if (cell_range(cell, address + i, 1, 0) == 0): return -14
		path[i] = cell.ram[address + i]
		if (path[i] == 0):
			if (i == 0): return -2
			return 0
	return -36


# Select a capability and strip leading slashes to give / guest-root meaning.
int cell_fs_base(cell_filesystem* fs, int dir, char* path):
	if (path[0] == 47):
		int skip = 0
		while (path[skip] == 47): skip = skip + 1
		int pos = 0
		while (path[skip] != 0):
			path[pos] = path[skip]
			pos = pos + 1
			skip = skip + 1
		path[pos] = 0
		if (pos == 0):
			path[0] = 46
			path[1] = 0
		return fs.root
	if (dir == -100): return fs.root
	return cell_fs_descriptor(fs, dir)


int cell_fs_pin(cell_filesystem* fs, int dir, char* path):
	int base = cell_fs_base(fs, dir, path)
	if (base < 0): return -9
	return cell_fs_resolve(base, path, 2097152, 0) # O_PATH


int cell_fs_kind(int fd):
	char[144] st
	int result = syscall(5, fd, cast(int, &st[0]), 0)
	if (result < 0): return result
	return load_int32(&st[24]) & 61440


int cell_fs_open(cell_filesystem* fs, int dir, char* path, int flags, int mode):
	# Only documented ordinary-file flags; no O_TMPFILE, O_ASYNC, direct I/O.
	int allowed = 3 | 64 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 32768 | 65536 | 131072 | 524288 | 1048576
	if (flags < 0 || (flags & ~allowed) != 0 || (flags & 3) == 3): return -22
	if (fs.writable == 0 && ((flags & 3) != 0 || (flags & (64 | 512)) != 0)): return -30
	int slot = -1
	for i in range(61):
		if (slot == -1 && fs.descriptors[i] == -1): slot = i
	if (slot == -1): return -24
	int base = cell_fs_base(fs, dir, path)
	if (base < 0): return -9
	int pinned = cell_fs_resolve(base, path, 2097152, 0)
	int fd = -1
	if (pinned == -2 && (flags & 64)):
		# Exclusive creation never opens a racing preexisting special inode.
		fd = cell_fs_resolve(base, path, flags | 128 | 131072 | 2048, mode & 511)
		if (fd < 0): return fd
	else:
		if (pinned < 0): return pinned
		int kind = cell_fs_kind(pinned)
		if (kind != 32768 && kind != 16384):
			close(pinned)
			return -13
		if ((flags & (64 | 128)) == (64 | 128)):
			close(pinned)
			return -17
		# Reopen only the pinned regular file/directory. This host-controlled
		# proc path never incorporates a guest pathname or descriptor.
		string_builder* proc = string_new()
		string_append(proc, c"/proc/self/fd/")
		string_append_int(proc, pinned)
		fd = open(proc.data, (flags & ~(64 | 128 | 131072)) | 524288 | 2048, 0)
		string_free(proc)
		close(pinned)
		if (fd < 0): return fd
	fs.descriptors[slot] = fd
	return slot + 3


# Resolve a parent without following links; *name points into the owned path
# buffer. Final components cannot escape (including mkdir/unlink/rename).
int cell_fs_parent(cell_filesystem* fs, int dir, char* path, char** name):
	int base = cell_fs_base(fs, dir, path)
	if (base < 0): return -9
	int last = -1
	int length = 0
	while (path[length] != 0):
		if (path[length] == 47): last = length
		length = length + 1
	*name = path + last + 1
	if ((*name)[0] == 0 || strcmp(*name, c".") == 0 || strcmp(*name, c"..") == 0): return -13
	if (last == -1): return cell_fs_resolve(base, c".", 2162688, 0)
	path[last] = 0
	return cell_fs_resolve(base, path, 2162688, 0)


int cell_fs_syscall(vm_cell* cell):
	cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
	if (fs == 0): return -4096
	char* regs = cell.regs
	int nr = load_int64(regs)
	int a = load_int64(regs + 40)
	int b = load_int64(regs + 32)
	int c = load_int64(regs + 24)
	int d = load_int64(regs + 80)
	int e = load_int64(regs + 64)
	if (nr == 0 || nr == 1 || nr == 3 || nr == 5 || nr == 8 || nr == 17 || nr == 18 || nr == 74 || nr == 75 || nr == 77 || nr == 217):
		if (a < 3 || a > 63): return -4096
		int fd = cell_fs_descriptor(fs, a)
		if (fd < 0): return -9
		if (nr == 3):
			fs.descriptors[a - 3] = -1
			return close(fd)
		if (nr == 8): return syscall(8, fd, b, c)
		if (nr == 74 || nr == 75 || nr == 77):
			if (fs.writable == 0): return -30
			return syscall(nr, fd, b, 0)
		if (nr == 5):
			if (cell_range(cell, b, 144, 1) == 0): return -14
			return syscall(5, fd, cast(int, cell.ram + b), 0)
		int writing = nr == 1 || nr == 18
		if (writing && fs.writable == 0): return -30
		if (cell_range(cell, b, c, writing == 0) == 0): return -14
		if (c > 1048576): c = 1048576
		return syscall7(nr, fd, cast(int, cell.ram + b), c, d, 0, 0)
	if (nr != 2 && nr != 4 && nr != 6 && nr != 82 && nr != 83 && nr != 84 && nr != 85 && nr != 87 && nr != 257 && nr != 258 && nr != 262 && nr != 263 && nr != 264 && nr != 316 && nr != 332): return -4096
	int dir = -100
	int address = a
	if (nr >= 257):
		dir = a
		address = b
	char[4096] path
	int result = cell_fs_path(cell, address, &path[0])
	if (result < 0): return result
	if (nr == 2): return cell_fs_open(fs, dir, &path[0], b, c)
	if (nr == 85): return cell_fs_open(fs, dir, &path[0], 577, b)
	if (nr == 257): return cell_fs_open(fs, dir, &path[0], c, d)
	if (nr == 4 || nr == 6 || nr == 262 || nr == 332):
		int buffer = b
		int size = 144
		if (nr == 262):
			buffer = c
			if (d != 0 && d != 256): return -22
		if (nr == 332):
			buffer = e
			size = 256
			if (c != 0 && c != 256): return -22
		if (cell_range(cell, buffer, size, 1) == 0): return -14
		int pinned = cell_fs_pin(fs, dir, &path[0])
		if (pinned < 0): return pinned
		if (nr == 332): result = syscall7(332, pinned, cast(int, c""), 4096, d, cast(int, cell.ram + buffer), 0)
		else: result = syscall(5, pinned, cast(int, cell.ram + buffer), 0)
		close(pinned)
		return result
	if (fs.writable == 0): return -30
	char* name = 0
	int parent = cell_fs_parent(fs, dir, &path[0], &name)
	if (parent < 0): return parent
	if (nr == 83 || nr == 258):
		int mode = b
		if (nr == 258): mode = c
		result = syscall(258, parent, cast(int, name), mode & 511)
	if (nr == 84 || nr == 87 || nr == 263):
		int flags = 0
		if (nr == 84): flags = 512
		if (nr == 263): flags = c
		if (flags != 0 && flags != 512): result = -22
		else: result = syscall(263, parent, cast(int, name), flags)
	if (nr == 82 || nr == 264 || nr == 316):
		int new_dir = -100
		int new_address = b
		if (nr != 82):
			new_dir = c
			new_address = d
		char[4096] new_path
		result = cell_fs_path(cell, new_address, &new_path[0])
		if (result == 0):
			char* new_name = 0
			int new_parent = cell_fs_parent(fs, new_dir, &new_path[0], &new_name)
			if (new_parent < 0): result = new_parent
			else:
				if (nr == 316 && e != 0 && e != 1 && e != 2): result = -22
				else:
					int flags = 0
					if (nr == 316): flags = e
					result = syscall7(316, parent, cast(int, name), new_parent, cast(int, new_name), flags, 0)
				close(new_parent)
	close(parent)
	return result
