# Linux x64 cgroup-v2 fleet quotas. Caller supplies a delegated parent with
# cpu, memory and pids enabled in cgroup.subtree_control. The daemon stays
# outside the bounded leaf; gated workers join before doing any guest work.
import lib.process
import lib.file

struct vm_cgroup:
	char* path
	int fd


int vm_cgroup_write(vm_cgroup* group, char* name, char* value):
	int fd = syscall7(257, group.fd, cast(int, name), 655361, 0, 0, 0) # WRONLY|NOFOLLOW|CLOEXEC
	if (fd < 0): return 0
	int length = strlen(value)
	int count = write(fd, value, length)
	close(fd)
	return count == length


int vm_cgroup_number(vm_cgroup* group, char* name, int value):
	string_builder* text = string_new()
	string_append_int(text, value)
	int ok = vm_cgroup_write(group, name, text.data)
	string_free(text)
	return ok


# Process enumeration can become empty before the kernel releases all task
# references. Retry only transient removal errors, without killing workers
# or deleting descendants. A permanently populated group must still fail.
int vm_cgroup_remove(char* path, int timeout_ms):
	if (path == 0 || timeout_ms < 0 || timeout_ms > 10000): return 0
	int deadline = process_monotonic_ms() + timeout_ms
	while (1):
		int status = syscall(84, cast(int, path), 0, 0)
		if (status == 0 || status == -2): return 1
		if (status != -16 && status != -4): return 0
		int remaining = deadline - process_monotonic_ms()
		if (remaining <= 0): return 0
		if (remaining > 10): remaining = 10
		process_sleep_ms(remaining)
	return 0


int vm_cgroup_free(vm_cgroup* group):
	if (group == 0): return 1
	if (group.fd >= 0): close(group.fd)
	int ok = 1
	if (group.path != 0):
		ok = vm_cgroup_remove(group.path, 5000)
		free(group.path)
	free(group)
	return ok


vm_cgroup* vm_cgroup_new(char* parent, int cpu_percent, int memory_mb, int pids):
	if (__word_size__ != 8 || parent == 0): return 0
	if (cpu_percent < 1 || cpu_percent > 12800 || memory_mb < 64 || memory_mb > 1048576 || pids < 1 || pids > 1048576): return 0
	int parent_fd = open(parent, 720896, 0) # DIRECTORY|NOFOLLOW|CLOEXEC
	if (parent_fd < 0): return 0
	char[120] stat
	int status = syscall(138, parent_fd, cast(int, &stat[0]), 0) # fstatfs
	if (status < 0 || load_int64(&stat[0]) != 1667723888): # CGROUP2_SUPER_MAGIC
		close(parent_fd)
		return 0
	string_builder* name = string_new()
	string_append(name, c"wvmd-")
	string_append_int(name, getpid())
	# Exclusive creation avoids sharing another daemon's quota/accounting.
	if (syscall(258, parent_fd, cast(int, name.data), 448) < 0):
		string_free(name)
		close(parent_fd)
		return 0
	vm_cgroup* group = new vm_cgroup()
	char* prefix = strjoin(parent, c"/")
	group.path = strjoin(prefix, name.data)
	free(prefix)
	group.fd = syscall7(257, parent_fd, cast(int, name.data), 720896, 0, 0, 0)
	close(parent_fd)
	string_free(name)
	int ok = group.fd >= 0
	string_builder* quota = string_new()
	string_append_int(quota, cpu_percent * 1000)
	string_append(quota, c" 100000")
	if (ok): ok = vm_cgroup_write(group, c"cpu.max", quota.data)
	string_free(quota)
	if (ok): ok = vm_cgroup_number(group, c"memory.max", memory_mb * 1048576)
	if (ok): ok = vm_cgroup_write(group, c"memory.swap.max", c"0")
	if (ok): ok = vm_cgroup_number(group, c"pids.max", pids)
	if (ok == 0):
		vm_cgroup_free(group)
		return 0
	return group


int vm_cgroup_attach(vm_cgroup* group, int pid):
	if (group == 0 || pid <= 0): return 0
	return vm_cgroup_number(group, c"cgroup.procs", pid)
