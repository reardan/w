# Durable Linux x64 daemon workspace ownership. State lives in a private
# sidecar directory and is locked for the daemon lifetime. Workers must
# wait for registry_record(..., pgid) before starting their guest.
# Recovery NEVER signals recorded PIDs: it waits for their process groups
# to disappear, so PID reuse can only defer cleanup, not kill a stranger.
import lib.vmm.workspace
import lib.file

const int REGISTRY_RECORD_SIZE = 256
const int REGISTRY_MAGIC = 1464685105

struct vm_registry:
	char* path
	int directory
	int lock
	int recovered


int registry_digits(char* text, int start, int end):
	if (start >= end): return 0
	for i in range(start, end):
		if (text[i] < '0' || text[i] > '9'): return 0
	return 1


int registry_workspace_name(char* name):
	char* prefix = c"wvm-work-"
	int length = strlen(name)
	if (length < 12 || length > 127): return 0
	for i in range(9):
		if (name[i] != prefix[i]): return 0
	int split = 9
	while (split < length && name[split] != '-'): split = split + 1
	return registry_digits(name, 9, split) && registry_digits(name, split + 1, length)


int registry_channel_name(char* name):
	if (strlen(name) != 44): return 0
	char* prefix = c"wvm-channel-"
	for i in range(12):
		if (name[i] != prefix[i]): return 0
	for i in range(12, 44):
		if ((name[i] < '0' || name[i] > '9') && (name[i] < 'a' || name[i] > 'f')): return 0
	return 1


char* registry_record_name(int id):
	string_builder* name = string_from(c"session-")
	string_append_int(name, id)
	string_append(name, c".record")
	char* result = strjoin(name.data, c"")
	string_free(name)
	return result


int registry_is_record(char* name):
	int length = strlen(name)
	if (length < 16 || strcmp(name + length - 7, c".record") != 0): return 0
	char* prefix = c"session-"
	for i in range(8):
		if (name[i] != prefix[i]): return 0
	return registry_digits(name, 8, length - 7)


# O_NOFOLLOW and owner/mode checks keep records and root paths from
# adopting symlinks or another user's state. Host code shares our uid.
int registry_stat_owned(int fd, int kind, char* st):
	mem_fill[char](st, 0, 144)
	if (syscall(5, fd, cast(int, st), 0) < 0): return 0
	int mode = load_int32(st + 24)
	if ((mode & 61440) != kind || (mode & 63) != 0): return 0
	return load_int32(st + 28) == syscall(102, 0, 0, 0)


int registry_child(vm_registry* registry, char* name, int flags, int mode):
	return workspace_open(registry.directory, name, flags, mode)


void registry_close(vm_registry* registry):
	if (registry == 0): return
	if (registry.lock >= 0): close(registry.lock)
	if (registry.directory >= 0): close(registry.directory)
	free(registry.path)
	free(registry)


int registry_record(vm_registry* registry, int id, char* path, int pgid):
	if (registry == 0 || id < 1 || pgid < 0 || pgid > 2147483647): return 0
	char[256] record
	mem_fill[char](&record[0], 0, REGISTRY_RECORD_SIZE)
	save_int32(&record[0], REGISTRY_MAGIC)
	save_int64(&record[8], pgid)
	if (path != 0):
		int prefix = strlen(registry.path)
		if (strlen(path) <= prefix || path[prefix] != '/'): return 0
		for i in range(prefix):
			if (path[i] != registry.path[i]): return 0
		char* name = path + prefix + 1
		if (registry_workspace_name(name) == 0): return 0
		int dir = registry_child(registry, name, 65536, 0)
		if (dir < 0): return 0
		char[144] st
		int valid = registry_stat_owned(dir, 16384, &st[0])
		close(dir)
		if (valid == 0): return 0
		save_int64(&record[16], load_int64(&st[0])) # device
		save_int64(&record[24], load_int64(&st[8])) # inode
		mem_copy[char](&record[32], name, strlen(name) + 1)
	char* name = registry_record_name(id)
	char* temporary = strjoin(name, c".tmp")
	# A previous interrupted write is ours and has never been published.
	syscall(263, registry.directory, cast(int, temporary), 0)
	int fd = registry_child(registry, temporary, 193, 384)
	int ok = 0
	if (fd >= 0):
		io_result result
		ok = io_write_all(fd, &record[0], REGISTRY_RECORD_SIZE, &result) == IO_OK
		if (syscall(74, fd, 0, 0) < 0): ok = 0
		if (close(fd) < 0): ok = 0
	if (ok): ok = syscall7(264, registry.directory, cast(int, temporary), registry.directory, cast(int, name), 0, 0) == 0
	if (ok): ok = syscall(74, registry.directory, 0, 0) == 0
	if (ok == 0): syscall(263, registry.directory, cast(int, temporary), 0)
	free(temporary)
	free(name)
	return ok


int registry_remove(vm_registry* registry, int id):
	if (registry == 0 || id < 1): return 0
	char* name = registry_record_name(id)
	int status = syscall(263, registry.directory, cast(int, name), 0)
	free(name)
	if (status != 0 && status != -2): return 0
	return syscall(74, registry.directory, 0, 0) == 0


# A zombie has released its file handles but may remain visible forever
# under a container PID 1 which does not reap it. Recognize that case
# without assuming a reused PID/process group belongs to this daemon.
int registry_group_zombies(int pgid):
	list[dir_entry*] processes = dir_read(c"/proc")
	if (processes == 0): return 0
	int matched = 0
	int live = 0
	for dir_entry* process in processes:
		if (registry_digits(process.name, 0, strlen(process.name)) == 0): continue
		char* directory = path_join(c"/proc", process.name)
		char* path = path_join(directory, c"stat")
		char* record = file_read_text(path)
		free(path)
		free(directory)
		if (record == 0): continue # exiting processes may disappear
		int end = -1
		int length = strlen(record)
		for i in range(length):
			if (record[i] == ')'): end = i
		if (end >= 0 && end + 4 < length):
			int state = record[end + 2]
			int offset = end + 4
			while (record[offset] && record[offset] != ' '): offset = offset + 1
			while (record[offset] == ' '): offset = offset + 1
			int group = 0
			while (record[offset] >= '0' && record[offset] <= '9'):
				group = group * 10 + record[offset] - '0'
				offset = offset + 1
			if (group == pgid):
				matched = matched + 1
				if (state != 'Z' && state != 'X'): live = 1
		free(record)
	dir_entries_free(processes)
	return matched > 0 && live == 0


int registry_group_quiet(int pgid, int timeout_ms):
	if (pgid < 0 || pgid > 2147483647 || timeout_ms < 0 || timeout_ms > 10000): return 0
	if (pgid == 0): return 1
	int deadline = time_monotonic_ms() + timeout_ms
	while (1):
		if (syscall(62, 0 - pgid, 0, 0) == -3): return 1
		if (registry_group_zombies(pgid)): return 1
		if (time_monotonic_ms() >= deadline): return 0
		sleep_ms(10)
	return 0


# 1 recovered/absent, 0 invalid or still live. A missing directory is a
# normal crash between removal and journal deletion. Inode mismatches
# fail closed; never delete a different object which reused the name.
int registry_recover_record(vm_registry* registry, char* name):
	int fd = registry_child(registry, name, 0, 0)
	if (fd < 0): return 0
	char[144] st
	int valid = registry_stat_owned(fd, 32768, &st[0])
	char[256] record
	if (valid): valid = load_int64(&st[48]) == REGISTRY_RECORD_SIZE
	int got = read(fd, &record[0], REGISTRY_RECORD_SIZE)
	close(fd)
	if (valid == 0 || got != REGISTRY_RECORD_SIZE || load_int32(&record[0]) != REGISTRY_MAGIC): return 0
	int pgid = load_int64(&record[8])
	if (registry_group_quiet(pgid, 2000) == 0): return 0
	# A bounded NUL scan before treating on-disk bytes as a C string.
	int length = 0
	while (length < 128 && record[32 + length] != 0): length = length + 1
	if (length == 128): return 0
	char* workspace = &record[32]
	if (length > 0):
		if (registry_workspace_name(workspace) == 0): return 0
		int directory = registry_child(registry, workspace, 65536, 0)
		if (directory >= 0):
			valid = registry_stat_owned(directory, 16384, &st[0])
			close(directory)
			if (valid == 0 || load_int64(&st[0]) != load_int64(&record[16]) || load_int64(&st[8]) != load_int64(&record[24])): return 0
			char* path = path_join(registry.path, workspace)
			int removed = dir_remove_all(path)
			free(path)
			if (removed != 0): return 0
			registry.recovered = registry.recovered + 1
		else if (directory != -2): return 0
	if (syscall(263, registry.directory, cast(int, name), 0) != 0): return 0
	return syscall(74, registry.directory, 0, 0) == 0


int registry_recover(vm_registry* registry):
	list[dir_entry*] entries = dir_read(registry.path)
	if (entries == 0): return 0
	int ok = 1
	# First drain every committed worker. Only then are unrecorded work
	# directories safe: the worker start barrier guarantees none ran.
	for dir_entry* entry in entries:
		if (registry_is_record(entry.name)):
			if (registry_recover_record(registry, entry.name) == 0):
				ok = 0
				break
	if (ok):
		for dir_entry* entry in entries:
			if (registry_workspace_name(entry.name) || registry_channel_name(entry.name)):
				int fd = registry_child(registry, entry.name, 65536, 0)
				if (fd == -2): continue
				char[144] st
				int valid = 0
				if (fd >= 0):
					valid = registry_stat_owned(fd, 16384, &st[0])
					close(fd)
				if (valid == 0):
					ok = 0
					continue
				char* path = path_join(registry.path, entry.name)
				if (dir_remove_all(path) != 0): ok = 0
				else: registry.recovered = registry.recovered + 1
				free(path)
	dir_entries_free(entries)
	if (syscall(74, registry.directory, 0, 0) < 0): ok = 0
	return ok


vm_registry* registry_open(char* socket_path):
	if (__word_size__ != 8 || socket_path == 0 || socket_path[0] == 0): return 0
	char* absolute = 0
	if (socket_path[0] == '/'): absolute = strjoin(socket_path, c"")
	else:
		char[4096] cwd
		if (getcwd(&cwd[0], 4096) < 0): return 0
		absolute = path_join(&cwd[0], socket_path)
	vm_registry* registry = new vm_registry()
	mem_fill[char](cast(char*, registry), 0, sizeof(vm_registry))
	registry.path = strjoin(absolute, c".state")
	free(absolute)
	registry.lock = -1
	registry.directory = -1
	int made = mkdir(registry.path, 448)
	if (made != 0 && made != -17):
		registry_close(registry)
		return 0
	registry.directory = open(registry.path, 65536 | 131072 | 524288, 0)
	char[144] st
	if (registry.directory < 0 || registry_stat_owned(registry.directory, 16384, &st[0]) == 0):
		registry_close(registry)
		return 0
	registry.lock = registry_child(registry, c"lock", 66, 384)
	if (registry.lock < 0 || registry_stat_owned(registry.lock, 32768, &st[0]) == 0 || sys_flock(registry.lock, 6) != 0):
		registry_close(registry)
		return 0
	if (registry_recover(registry) == 0):
		registry_close(registry)
		return 0
	return registry
