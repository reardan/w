# Private workspace copies for Linux x64 sessions. Source traversal is
# descriptor-confined with openat2; symlinks, mount crossings and special
# files fail closed. FICLONE shares extents where supported, never inodes.
# Limits bound preparation, not later guest writes. Stop the VM before destroy.
import lib.mem
import lib.dir
import lib.io
import lib.time
import structures.string

struct vm_workspace:
	char* path
	int bytes
	int entries
	int max_bytes
	int max_entries
	int deadline

int workspace_sequence


int workspace_open(int parent, char* name, int flags, int mode):
	char[24] how
	save_int64(&how[0], flags | 524288)
	save_int64(&how[8], mode)
	save_int64(&how[16], 15) # BENEATH, NO_SYMLINKS, NO_MAGICLINKS, NO_XDEV
	return syscall7(437, parent, cast(int, name), cast(int, &how[0]), 24, 0, 0)


int workspace_destroy(vm_workspace* workspace):
	if (workspace == 0): return 0
	int status = dir_remove_all(workspace.path)
	free(workspace.path)
	free(workspace)
	return status


int workspace_copy_file(vm_workspace* workspace, int source, int destination, int size):
	if (size < 0 || size > workspace.max_bytes - workspace.bytes): return 0
	workspace.bytes = workspace.bytes + size
	int clone_request = 1074041865 # FICLONE: _IOW(0x94, 9, int)
	if (syscall(16, destination, clone_request, source) == 0):
		char[144] st
		if (syscall(5, destination, cast(int, &st[0]), 0) < 0): return 0
		return load_int64(&st[48]) == size
	char[65536] buffer
	int have = 0
	while (have < size):
		if (time_monotonic_ms() >= workspace.deadline): return 0
		int count = size - have
		if (count > 65536): count = 65536
		int got = read(source, &buffer[0], count)
		if (got == -4): continue
		if (got <= 0): return 0
		io_result result
		if (io_write_all(destination, &buffer[0], got, &result) != IO_OK): return 0
		have = have + got
	# Refuse source growth rather than copying unaccounted bytes.
	return read(source, &buffer[0], 1) == 0


int workspace_copy_dir(vm_workspace* workspace, int source, int destination, int depth):
	if (depth > 64): return 0
	char[8192] entries
	while (1):
		if (time_monotonic_ms() >= workspace.deadline): return 0
		int count = syscall(217, source, cast(int, &entries[0]), 8192) # getdents64
		if (count == -4): continue
		if (count < 0): return 0
		if (count == 0): return 1
		int at = 0
		while (at < count):
			if (count - at < 20): return 0
			int record = load_int16(&entries[at + 16])
			if (record < 20 || record > count - at): return 0
			char* name = &entries[at + 19]
			int length = 0
			while (length < record - 19 && name[length] != 0): length = length + 1
			if (length == record - 19): return 0
			at = at + record
			if (strcmp(name, c".") == 0 || strcmp(name, c"..") == 0): continue
			workspace.entries = workspace.entries + 1
			if (workspace.entries > workspace.max_entries): return 0
			# O_PATH pins the inode before a potentially blocking open.
			int pinned = workspace_open(source, name, 2097152, 0)
			if (pinned < 0): return 0
			char[144] st
			mem_fill[char](&st[0], 0, 144)
			int ok = syscall(5, pinned, cast(int, &st[0]), 0) == 0
			int mode = load_int32(&st[24])
			int kind = mode & 61440
			if (kind != 32768 && kind != 16384): ok = 0
			string_builder* proc = string_new()
			string_append(proc, c"/proc/self/fd/")
			string_append_int(proc, pinned)
			int input = -1
			if (ok): input = open(proc.data, 524288 | 2048, 0)
			string_free(proc)
			close(pinned)
			if (input < 0): return 0
			int output = -1
			if (kind == 16384):
				ok = syscall(258, destination, cast(int, name), 448) == 0
				if (ok): output = workspace_open(destination, name, 65536, 0)
				if (output >= 0): ok = workspace_copy_dir(workspace, input, output, depth + 1)
			else:
				output = workspace_open(destination, name, 193, 384 | (mode & 73))
				if (output >= 0): ok = workspace_copy_file(workspace, input, output, load_int64(&st[48]))
			if (output < 0): ok = 0
			if (output >= 0):
				if (close(output) < 0): ok = 0
			close(input)
			if (ok == 0): return 0
	return 0


# Caller owns a stable source tree while preparing it. The destination is
# created under /tmp and never adopts an old path; source must exclude it.
vm_workspace* workspace_create_in(char* source, char* parent, int max_bytes, int max_entries, int timeout_ms):
	if (__word_size__ != 8 || source == 0 || parent == 0): return 0
	if (max_bytes < 1 || max_entries < 1 || timeout_ms < 1 || timeout_ms > 600000): return 0
	int input = open(source, 65536 | 131072 | 524288, 0)
	if (input < 0): return 0
	vm_workspace* workspace = cast(vm_workspace*, malloc(sizeof(vm_workspace)))
	mem_fill[char](cast(char*, workspace), 0, sizeof(vm_workspace))
	workspace.max_bytes = max_bytes
	workspace.max_entries = max_entries
	workspace.deadline = time_monotonic_ms() + timeout_ms
	string_builder* path = string_new()
	int created = 0
	for attempt in range(100):
		workspace_sequence = workspace_sequence + 1
		string_clear(path)
		string_append(path, parent)
		string_append(path, c"/wvm-work-")
		string_append_int(path, getpid())
		string_append_char(path, '-')
		string_append_int(path, workspace_sequence)
		if (mkdir(path.data, 448) == 0):
			created = 1
			break
	workspace.path = strjoin(path.data, c"")
	string_free(path)
	int output = -1
	if (created): output = open(workspace.path, 65536 | 131072 | 524288, 0)
	int ok = 0
	if (output >= 0): ok = workspace_copy_dir(workspace, input, output, 0)
	if (output >= 0): close(output)
	close(input)
	if (ok): return workspace
	if (created): workspace_destroy(workspace)
	else:
		free(workspace.path)
		free(workspace)
	return 0


vm_workspace* workspace_create(char* source, int max_bytes, int max_entries, int timeout_ms):
	return workspace_create_in(source, c"/tmp", max_bytes, max_entries, timeout_ms)
