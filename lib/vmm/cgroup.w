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


void vm_cgroup_free(vm_cgroup* group):
	if (group == 0): return
	if (group.fd >= 0): close(group.fd)
	if (group.path != 0):
		syscall(84, cast(int, group.path), 0, 0)
		free(group.path)
	free(group)


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
