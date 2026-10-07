# Boot-only workspace import. Append a bounded newc archive to the supplied
# initramfs; Linux unpacks concatenated archives before starting PID 1.
# No host filesystem device remains attached to the running guest.
import lib.vmm.workspace


int workspace_image_write(int fd, char* data, int length):
	io_result result
	return io_write_all(fd, data, length, &result) == IO_OK


void workspace_image_hex(string_builder* header, int value):
	char* digits = c"0123456789abcdef"
	for i in range(8):
		string_append_char(header, digits[(value >> ((7 - i) * 4)) & 15])


int workspace_image_entry(int fd, char* name, int mode, int size):
	string_builder* header = string_from(c"070701")
	workspace_image_hex(header, 0)
	workspace_image_hex(header, mode)
	workspace_image_hex(header, 0)
	workspace_image_hex(header, 0)
	workspace_image_hex(header, 1)
	workspace_image_hex(header, 0)
	workspace_image_hex(header, size)
	for i in range(4): workspace_image_hex(header, 0)
	workspace_image_hex(header, strlen(name) + 1)
	workspace_image_hex(header, 0)
	string_append_bytes(header, name, strlen(name) + 1)
	while (header.length % 4): string_append_char(header, 0)
	int ok = workspace_image_write(fd, header.data, header.length)
	string_free(header)
	return ok


int workspace_image_copy(int input, int output, int size, int deadline):
	char[65536] buffer
	int have = 0
	while (have < size):
		if (time_monotonic_ms() >= deadline): return 0
		int length = size - have
		if (length > 65536): length = 65536
		int count = read(input, &buffer[0], length)
		if (count == -4): continue
		if (count <= 0): return 0
		if (workspace_image_write(output, &buffer[0], count) == 0): return 0
		have = have + count
	return read(input, &buffer[0], 1) == 0


# The caller owns an immutable private copy. Still use confined opens and
# validate every directory record: malformed names cannot escape the prefix.
int workspace_image_dir(int source, int output, char* prefix, int depth, int deadline):
	if (depth > 64): return 0
	char[8192] entries
	while (1):
		if (time_monotonic_ms() >= deadline): return 0
		int count = syscall(217, source, cast(int, &entries[0]), 8192)
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
			while (length < record - 19 && name[length] != 0):
				if (name[length] == '/'): return 0
				length = length + 1
			if (length == 0 || length == record - 19): return 0
			at = at + record
			if (strcmp(name, c".") == 0 || strcmp(name, c"..") == 0): continue
			int input = workspace_open(source, name, 2048, 0)
			if (input < 0): return 0
			char[144] st
			mem_fill[char](&st[0], 0, 144)
			int ok = syscall(5, input, cast(int, &st[0]), 0) == 0
			int mode = load_int32(&st[24])
			int kind = mode & 61440
			int size = load_int64(&st[48])
			char* path = path_join(prefix, name)
			if (strlen(path) > 4096): ok = 0
			if (ok && kind == 16384):
				ok = workspace_image_entry(output, path, 16832, 0)
				if (ok): ok = workspace_image_dir(input, output, path, depth + 1, deadline)
			else if (ok && kind == 32768 && size >= 0 && size <= 2147483647):
				ok = workspace_image_entry(output, path, 33152 | (mode & 73), size)
				if (ok): ok = workspace_image_copy(input, output, size, deadline)
				if (ok && size % 4): ok = workspace_image_write(output, c"\0\0\0", 4 - size % 4)
			else: ok = 0
			free(path)
			close(input)
			if (ok == 0): return 0
	return 0


# The destination must not exist. All preparation and cleanup are private to
# the session directory. Caller keeps the file alive until QEMU has booted.
int workspace_image_create(char* initrd, char* source, char* parent, char* destination, int max_bytes, int timeout_ms):
	vm_workspace* workspace = workspace_create_in(source, parent, max_bytes, 100000, timeout_ms)
	if (workspace == 0): return 0
	int input = open(initrd, 524288 | 131072, 0)
	int output = -1
	if (input >= 0): output = open(destination, 524288 | 193, 384)
	int ok = 0
	if (output >= 0):
		char[144] st
		if (syscall(5, input, cast(int, &st[0]), 0) == 0):
			int size = load_int64(&st[48])
			if ((load_int32(&st[24]) & 61440) == 32768 && size >= 0 && size <= 1073741824):
				ok = workspace_image_copy(input, output, size, workspace.deadline)
				if (ok && size % 4): ok = workspace_image_write(output, c"\0\0\0", 4 - size % 4)
		if (ok): ok = workspace_image_entry(output, c"wvm-import", 16832, 0)
		int root = open(workspace.path, 65536 | 131072 | 524288, 0)
		if (root < 0): ok = 0
		if (ok): ok = workspace_image_dir(root, output, c"wvm-import", 0, workspace.deadline)
		if (root >= 0): close(root)
		if (ok): ok = workspace_image_entry(output, c"TRAILER!!!", 0, 0)
		if (close(output) < 0): ok = 0
	if (input >= 0): close(input)
	if (workspace_destroy(workspace) != 0): ok = 0
	if (ok == 0 && output >= 0): unlink(destination)
	return ok
