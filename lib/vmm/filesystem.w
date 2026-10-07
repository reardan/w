# Opt-in directory capability for x64 cells. Guest descriptors never name
# host descriptors. Paths are relative to the configured root (including
# guest absolute paths); symlinks and mount crossings are intentionally denied.
# Existing inodes are pinned and type-checked BEFORE an ordinary open, so
# opening a device/FIFO cannot cause host side effects or block the watchdog.
import lib.vmm.memory
import lib.vmm.workspace

struct cell_filesystem:
	int root
	int writable
	int* descriptors
	vm_workspace* private_copy


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
	if (fs.private_copy != 0): workspace_destroy(fs.private_copy)
	free(fs)
	cell.fs_state = 0


int cell_fs_configure(vm_cell* cell, char* root, int writable):
	if (cell.deterministic): return cell_fail(cell, c"deterministic services disallow filesystem capabilities")
	if (__word_size__ != 8 || cell.started || cell.fs_state != 0): return cell_fail(cell, c"filesystem must be configured once before execution on x64")
	int fd = open(root, 2686976, 0) # O_PATH | O_DIRECTORY | O_CLOEXEC
	if (fd < 0): return cell_fail(cell, c"cannot open filesystem root")
	int probe = cell_fs_resolve(fd, c".", 2162688, 0)
	if (probe < 0):
		close(fd)
		return cell_fail(cell, c"filesystem confinement requires Linux openat2")
	close(probe)
	cell_filesystem* fs = cast(cell_filesystem*, malloc(sizeof(cell_filesystem)))
	fs.private_copy = 0
	fs.root = fd
	fs.writable = writable != 0
	fs.descriptors = cast(int*, malloc(61 * sizeof(int)))
	for i in range(61): fs.descriptors[i] = -1
	cell.fs_state = cast(void*, fs)
	cell.fs_cleanup = cast(void*, cell_fs_free)
	return 1


# An eager private copy gives ordinary rename/unlink semantics without a
# privileged overlay mount. Logical file growth and inode creation are charged
# monotonically; deletion/truncation do not refund budget, including open but
# unlinked files. This conservative lifetime quota bounds guest writes without
# races or inode accounting tables. Source must be stable during preparation.
int cell_fs_configure_private(vm_cell* cell, char* root, int max_bytes, int max_entries, int timeout_ms):
	if (cell.started || cell.fs_state != 0 || cell.deterministic): return cell_fail(cell, c"private filesystem must be configured before execution")
	if (max_bytes < 1 || max_bytes > 1073741824 || max_entries < 1 || max_entries > 100000):
		return cell_fail(cell, c"private filesystem limits exceed 1 GiB or 100000 entries")
	vm_workspace* workspace = workspace_create(root, max_bytes, max_entries, timeout_ms)
	if (workspace == 0): return cell_fail(cell, c"private filesystem preparation failed")
	if (cell_fs_configure(cell, workspace.path, 1) == 0):
		workspace_destroy(workspace)
		return 0
	cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
	fs.private_copy = workspace
	return 1


int cell_fs_size(int fd):
	char[144] st
	int status = syscall(5, fd, cast(int, &st[0]), 0)
	if (status < 0): return status
	if ((load_int32(&st[24]) & 61440) != 32768): return -21
	return load_int64(&st[48])


int cell_fs_growth(cell_filesystem* fs, int size, int end):
	if (end < 0): return -22
	if (end <= size): return 0
	int growth = end - size
	if (growth > fs.private_copy.max_bytes - fs.private_copy.bytes): return -28
	return growth


int cell_fs_truncate(cell_filesystem* fs, int fd, int length):
	if (fs.private_copy == 0): return syscall(77, fd, length, 0)
	int size = cell_fs_size(fd)
	if (size < 0): return size
	int growth = cell_fs_growth(fs, size, length)
	if (growth < 0): return growth
	int result = syscall(77, fd, length, 0)
	if (result == 0): fs.private_copy.bytes = fs.private_copy.bytes + growth
	return result


int cell_fs_write(cell_filesystem* fs, int fd, char* buffer, int length, int offset, int positioned):
	int nr = 1
	if (positioned): nr = 18
	if (fs.private_copy == 0): return syscall7(nr, fd, cast(int, buffer), length, offset, 0, 0)
	int size = cell_fs_size(fd)
	if (size < 0): return size
	int flags = sys_fcntl(fd, 3, 0)
	if (flags < 0): return flags
	int position = offset
	if (positioned == 0): position = syscall(8, fd, 0, 1)
	# Linux pwrite on O_APPEND also writes at EOF.
	if (flags & 1024): position = size
	if (position < 0): return -22
	if (length == 0): return syscall7(nr, fd, cast(int, buffer), length, offset, 0, 0)
	if (position > fs.private_copy.max_bytes || length > fs.private_copy.max_bytes - position): return -28
	int growth = cell_fs_growth(fs, size, position + length)
	if (growth < 0): return growth
	int result = syscall7(nr, fd, cast(int, buffer), length, offset, 0, 0)
	if (result > 0):
		int end = position + result
		if (end > size): fs.private_copy.bytes = fs.private_copy.bytes + end - size
	return result


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
		if (fs.private_copy != 0 && fs.private_copy.entries >= fs.private_copy.max_entries): return -28
		# Exclusive creation never opens a racing preexisting special inode.
		fd = cell_fs_resolve(base, path, flags | 128 | 131072 | 2048, mode & 511)
		if (fd < 0): return fd
		if (fs.private_copy != 0): fs.private_copy.entries = fs.private_copy.entries + 1
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


# Match the preparation depth cap so cleanup cannot recurse without bound.
int cell_fs_private_depth(cell_filesystem* fs, int parent):
	if (fs.private_copy == 0): return 0
	string_builder* proc = string_from(c"/proc/self/fd/")
	string_append_int(proc, parent)
	char[4096] path
	int length = syscall(89, cast(int, proc.data), cast(int, &path[0]), 4095)
	string_free(proc)
	if (length < 0 || length >= 4095): return -1
	int prefix = strlen(fs.private_copy.path)
	if (length < prefix): return -1
	for i in range(prefix):
		if (path[i] != fs.private_copy.path[i]): return -1
	if (length > prefix && path[prefix] != '/'): return -1
	int depth = 0
	for i in range(prefix, length):
		if (path[i] == '/'): depth = depth + 1
	return depth


# Check a directory move against the same 64-level cleanup bound as mkdir.
# Traversal opens independent directory descriptions, never changing guest
# enumeration offsets. Work is bounded by the entry quota and wall deadline.
int cell_fs_tree_fits(int directory, int remaining, int* entries, int deadline):
	if (remaining < 0): return -36
	char[4096] records
	while (1):
		if (time_monotonic_ms() >= deadline): return -110
		int count = syscall(217, directory, cast(int, &records[0]), 4096)
		if (count == -4): continue
		if (count <= 0): return count
		int at = 0
		while (at < count):
			if (count - at < 20): return -5
			int size = load_int16(&records[at + 16])
			if (size < 20 || size > count - at): return -5
			char* name = &records[at + 19]
			int length = 0
			while (length < size - 19 && name[length] != 0): length = length + 1
			if (length == size - 19): return -5
			at = at + size
			if (strcmp(name, c".") == 0 || strcmp(name, c"..") == 0): continue
			*entries = *entries - 1
			if (*entries < 0): return -28
			int child = cell_fs_resolve(directory, name, 65536, 0)
			if (child == -20): continue # regular file, not a directory
			if (child < 0): return child
			int result = cell_fs_tree_fits(child, remaining - 1, entries, deadline)
			close(child)
			if (result != 0): return result
	return 0


int cell_fs_private_move(cell_filesystem* fs, int parent, char* name, int destination, int deadline):
	if (fs.private_copy == 0): return 0
	int directory = cell_fs_resolve(parent, name, 65536, 0)
	if (directory == -20 || directory == -2): return 0
	if (directory < 0): return directory
	int depth = cell_fs_private_depth(fs, destination)
	if (depth < 0):
		close(directory)
		return -13
	int entries = fs.private_copy.max_entries
	int bound = time_monotonic_ms() + 1000
	if (deadline > 0 && deadline < bound): bound = deadline
	int result = cell_fs_tree_fits(directory, 63 - depth, &entries, bound)
	close(directory)
	return result


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
			if (nr == 77): return cell_fs_truncate(fs, fd, b)
			return syscall(nr, fd, b, 0)
		if (nr == 5):
			if (cell_range(cell, b, 144, 1) == 0): return -14
			return syscall(5, fd, cast(int, cell.ram + b), 0)
		int writing = nr == 1 || nr == 18
		if (writing && fs.writable == 0): return -30
		if (cell_range(cell, b, c, writing == 0) == 0): return -14
		if (c > 1048576): c = 1048576
		if (writing): return cell_fs_write(fs, fd, cell.ram + b, c, d, nr == 18)
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
		int depth = cell_fs_private_depth(fs, parent)
		# Cleanup must always retain host-owner traversal and removal rights.
		if (fs.private_copy != 0 && (mode & 448) != 448): result = -13
		else if (fs.private_copy != 0 && (depth < 0 || depth >= 64)): result = -36
		else if (fs.private_copy != 0 && fs.private_copy.entries >= fs.private_copy.max_entries): result = -28
		else:
			result = syscall(258, parent, cast(int, name), mode & 511)
			if (result == 0 && fs.private_copy != 0): fs.private_copy.entries = fs.private_copy.entries + 1
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
				int allowed = cell_fs_private_move(fs, parent, name, new_parent, cell.deadline_ms)
				if (allowed == 0 && nr == 316 && e == 2): allowed = cell_fs_private_move(fs, new_parent, new_name, parent, cell.deadline_ms)
				if (allowed != 0): result = allowed
				else if (nr == 316 && e != 0 && e != 1 && e != 2): result = -22
				else:
					int flags = 0
					if (nr == 316): flags = e
					result = syscall7(316, parent, cast(int, name), new_parent, cast(int, new_name), flags, 0)
				close(new_parent)
	close(parent)
	return result
