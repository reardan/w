# Native measurement, not a performance assertion. Two exec workers plus
# the template owner are sampled at barriers. Mach region accounting is
# best-effort: HV mappings add references, so shared pages can include
# private guest shadows. Never sum shared fields as unique physical RAM.
import lib.vmm.darwin_snapshot
import lib.vmm.darwin_hv
import lib.assert
import lib.process

c_lib "/usr/lib/libSystem.B.dylib"
extern int memory_mach_task_self_raw() = "mach_task_self"
extern int memory_mach_vm_region_raw(int task, int* address, int* length, int flavor, char* info, int* count, int* object) = "mach_vm_region"
extern int memory_mach_port_deallocate_raw(int task, int name) = "mach_port_deallocate"
extern int memory_proc_pid_rusage_raw(int pid, int flavor, char* buffer) = "proc_pid_rusage"
extern int memory_fstat_raw(int fd, char* stat) = "fstat"


int mach_task_self():
	return memory_mach_task_self_raw() & ((1 << 32) - 1)

int mach_vm_region(int task, int* address, int* length, int flavor, char* info, int* count, int* object):
	return darwin_snapshot_c_int(memory_mach_vm_region_raw(task, address, length, flavor, info, count, object))

int mach_port_deallocate(int task, int name):
	return darwin_snapshot_c_int(memory_mach_port_deallocate_raw(task, name))

int proc_pid_rusage(int pid, int flavor, char* buffer):
	return darwin_snapshot_c_int(memory_proc_pid_rusage_raw(pid, flavor, buffer))


void memory_field(string_builder* record, char* name, int value):
	string_append(record, c",")
	string_append(record, name)
	string_append_char(record, ':')
	string_append_int(record, value)


void memory_record(char* phase, char* mode, char* ram, int dirty_pages, int clones):
	int task = mach_task_self()
	int address = cast(int, ram)
	int length = 0
	int count = 5
	int object = 0
	char[64] top
	mem_fill[char](&top[0], 0, 64)
	assert_equal(0, mach_vm_region(task, &address, &length, 12, &top[0], &count, &object))
	if (object != 0): mach_port_deallocate(task, object)
	int top_length = length
	address = cast(int, ram)
	count = 9
	object = 0
	char[64] extended
	mem_fill[char](&extended[0], 0, 64)
	assert_equal(0, mach_vm_region(task, &address, &length, 13, &extended[0], &count, &object))
	if (object != 0): mach_port_deallocate(task, object)
	char[96] usage
	assert_equal(0, proc_pid_rusage(getpid(), 0, &usage[0]))
	string_builder* record = string_from(c"{\"phase\":\"")
	string_append(record, phase)
	string_append(record, c"\",\"mode\":\"")
	string_append(record, mode)
	string_append_char(record, '"')
	memory_field(record, c"\"pid\"", getpid())
	memory_field(record, c"\"clone_count\"", clones)
	memory_field(record, c"\"dirty_pages_requested\"", dirty_pages)
	memory_field(record, c"\"host_page_bytes\"", getpagesize())
	memory_field(record, c"\"region_bytes\"", top_length)
	memory_field(record, c"\"object_id\"", load_int32(&top[0]) & ((1 << 32) - 1))
	memory_field(record, c"\"references\"", load_int32(&top[4]))
	memory_field(record, c"\"private_resident_pages\"", load_int32(&top[8]))
	memory_field(record, c"\"shared_resident_pages\"", load_int32(&top[12]))
	memory_field(record, c"\"share_mode\"", cast(int, top[16]))
	memory_field(record, c"\"region_resident_pages\"", load_int32(&extended[8]))
	memory_field(record, c"\"shared_now_private_pages\"", load_int32(&extended[12]))
	memory_field(record, c"\"dirty_pages\"", load_int32(&extended[20]))
	memory_field(record, c"\"resident_bytes\"", load_int64(&usage[64]))
	memory_field(record, c"\"footprint_bytes\"", load_int64(&usage[72]))
	memory_field(record, c"\"wired_bytes\"", load_int64(&usage[56]))
	string_append(record, c"}\n")
	assert_equal(record.length, write(1, record.data, record.length))
	string_free(record)


void memory_child_barrier():
	char signal = 0
	assert_equal(1, write(5, c"r", 1))
	assert_equal(1, read(4, &signal, 1))


int memory_worker(char* mode, int dirty_pages, int clones):
	darwin_clone* clone = darwin_clone_from_fd(3)
	asserts(c"measurement clone", clone != 0)
	close(3)
	int length = clone.length
	int page = clone.granule
	char* ram = clone.ram
	int copying = strcmp(mode, c"copy") == 0
	if (copying):
		int address = mmap(0, length, 3, 34)
		asserts(c"full-copy baseline allocation", darwin_backing_map_failed(address) == 0)
		ram = cast(char*, address)
		mem_copy[char](ram, clone.ram, length)
		darwin_clone_free(clone)
		clone = 0
	memory_record(c"before-registration", mode, ram, dirty_pages, clones)
	memory_child_barrier()
	assert_equal(0, hv_vm_create(0))
	assert_equal(0, hv_vm_map(ram, 0x100000, length, 7))
	memory_record(c"registered", mode, ram, dirty_pages, clones)
	if (dirty_pages > 0):
		int cpu = 0
		dhv_exit* state = 0
		assert_equal(0, hv_vcpu_create(&cpu, &state, 0))
		assert_equal(0, hv_vcpu_set_reg(cpu, 31, 0x100000))
		assert_equal(0, hv_vcpu_set_reg(cpu, 34, 0x3c5))
		assert_equal(0, hv_vcpu_set_reg(cpu, 0, getpid()))
		assert_equal(0, hv_vcpu_set_reg(cpu, 1, 0x100000 + page))
		assert_equal(0, hv_vcpu_set_reg(cpu, 2, page))
		assert_equal(0, hv_vcpu_set_reg(cpu, 3, dirty_pages))
		assert_equal(0, hv_vcpu_set_vtimer_mask(cpu, 1))
		assert_equal(0, hv_vcpu_run(cpu))
		assert_equal(0x16, state.syndrome >> 26)
		assert_equal(getpid(), load_int64(ram + dirty_pages * page))
		assert_equal(0, hv_vcpu_destroy(cpu))
	memory_record(c"after-guest-writes", mode, ram, dirty_pages, clones)
	memory_child_barrier()
	assert_equal(0, hv_vm_unmap(0x100000, length))
	assert_equal(0, hv_vm_destroy())
	if (copying): assert_equal(0, munmap(cast(int, ram), length))
	else: darwin_clone_free(clone)
	return 0


int memory_spawn(char* self, int fd, int release, int ready, char* mode, char* dirty, char* count):
	int pid = fork()
	asserts(c"measurement worker fork", pid >= 0)
	if (pid == 0):
		assert_equal(3, dup2(fd, 3))
		assert_equal(0, sys_fcntl(3, 2, 0))
		assert_equal(4, dup2(release, 4))
		assert_equal(5, dup2(ready, 5))
		for n in range(6, 1024): close(n)
		char** args = strv_new(6)
		args[0] = self
		args[1] = c"worker"
		args[2] = mode
		args[3] = dirty
		args[4] = count
		args[5] = 0
		char** env = strv_new(1)
		env[0] = 0
		execve(self, args, env)
		exit(125)
	return pid


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc == 5 && strcmp(args[1], c"worker") == 0): return memory_worker(args[2], atoi(args[3]), atoi(args[4]))
	assert_equal(4, argc)
	int dirty = atoi(args[2])
	int clones = atoi(args[3])
	asserts(c"measurement dirty fraction", dirty >= 0 && dirty <= 1024)
	asserts(c"measurement clone count", clones == 1 || clones == 2)
	asserts(c"measurement mode", strcmp(args[1], c"copy") == 0 || strcmp(args[1], c"cow") == 0)
	int page = getpagesize()
	int length = page * 1025
	int address = mmap(0, length, 3, 34)
	asserts(c"measurement source allocation", darwin_backing_map_failed(address) == 0)
	char* source = cast(char*, address)
	mem_fill[char](source, 7, length)
	# str x0,[x1]; add x1,x1,x2; subs x3,x3,#1; b.ne loop; hvc #0
	save_int32(source, cast(int, 0xf9000020))
	save_int32(source + 4, cast(int, 0x8b020021))
	save_int32(source + 8, cast(int, 0xf1000463))
	save_int32(source + 12, 0x54ffffa1)
	save_int32(source + 16, cast(int, 0xd4000002))
	darwin_backing* backing = darwin_backing_create(source, length, 0, 0)
	asserts(c"measurement backing capture", backing != 0)
	char[144] file_stat
	assert_equal(0, darwin_snapshot_c_int(memory_fstat_raw(backing.fd, &file_stat[0])))
	string_builder* file_record = string_from(c"{\"phase\":\"backing-file\"")
	memory_field(file_record, c"\"logical_bytes\"", load_int64(&file_stat[96]))
	memory_field(file_record, c"\"allocated_bytes\"", load_int64(&file_stat[104]) * 512)
	string_append(file_record, c"}\n")
	assert_equal(file_record.length, write(1, file_record.data, file_record.length))
	string_free(file_record)
	assert_equal(0, munmap(address, length))
	darwin_clone* owner = darwin_backing_clone(backing)
	asserts(c"measurement owner view", owner != 0)
	# Include the warm backing in the template owner's resident accounting.
	int checksum = 0
	for offset in range(0, length, page): checksum = checksum + cast(int, owner.ram[offset])
	asserts(c"template pages touched", checksum != 0)
	int[2] release_fds
	int[2] ready_fds
	assert_equal(0, pipe(&release_fds[0]))
	assert_equal(0, pipe(&ready_fds[0]))
	int release_read = load_int32(cast(char*, &release_fds[0]))
	int release_write = load_int32(cast(char*, &release_fds[0]) + 4)
	int ready_read = load_int32(cast(char*, &ready_fds[0]))
	int ready_write = load_int32(cast(char*, &ready_fds[0]) + 4)
	# Duplicate control sources above destinations so dup2 cannot clobber
	# a pipe when the inherited process starts with extra descriptors.
	int child_release = sys_fcntl(release_read, 0, 20)
	int child_ready = sys_fcntl(ready_write, 0, 20)
	asserts(c"measurement control descriptors", child_release >= 20 && child_ready >= 20)
	int[2] pids
	for child in range(clones): pids[child] = memory_spawn(args[0], backing.fd, child_release, child_ready, args[1], args[2], args[3])
	close(child_release)
	close(child_ready)
	close(release_read)
	close(ready_write)
	for phase in range(2):
		char signal = 0
		for child in range(clones): assert_equal(1, read(ready_read, &signal, 1))
		memory_record(c"template-owner", args[1], owner.ram, dirty, clones)
		for child in range(clones): assert_equal(1, write(release_write, c"r", 1))
	close(release_write)
	close(ready_read)
	for child in range(clones):
		int status = 0
		assert_equal(pids[child], wait4(pids[child], &status, 0, 0))
		assert_equal(0, status)
	assert_equal(7, cast(int, owner.ram[page]))
	darwin_clone_free(owner)
	darwin_backing_free(backing)
	return 0
