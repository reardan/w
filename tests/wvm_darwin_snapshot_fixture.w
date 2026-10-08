# Native, signed, no-skip Hypervisor snapshot test. Invoked by the Darwin
# VM gate; deliberately not an implicit Linux *_test.w target.
import lib.vmm.darwin_snapshot
import lib.vmm.darwin_hv
import lib.assert
import lib.process

c_lib "/usr/lib/libSystem.B.dylib"
extern int snapshot_getrlimit(int resource, int* limits) = "getrlimit"
extern int snapshot_setrlimit(int resource, int* limits) = "setrlimit"


int snapshot_resident_pages(char* address, int length):
	int count = length / getpagesize()
	char* vector = cast(char*, malloc(count))
	assert_equal(0, sys_mincore(cast(int, address), length, cast(int, vector)))
	int resident = 0
	for index in range(count):
		if (vector[index] & 1): resident = resident + 1
	free(vector)
	return resident


void snapshot_guest_write(darwin_clone* clone, int value):
	assert_equal(0, hv_vm_create(0))
	int before = snapshot_resident_pages(clone.ram, clone.length)
	assert_equal(0, hv_vm_map(clone.ram, 0x100000, clone.length, 7))
	int after = snapshot_resident_pages(clone.ram, clone.length)
	int cpu = 0
	dhv_exit* state = 0
	assert_equal(0, hv_vcpu_create(&cpu, &state, 0))
	assert_equal(0, hv_vcpu_set_reg(cpu, dhv_reg_pc, 0x100000))
	assert_equal(0, hv_vcpu_set_reg(cpu, dhv_reg_cpsr, 0x3c5))
	assert_equal(0, hv_vcpu_set_reg(cpu, 0, value))
	assert_equal(0, hv_vcpu_set_reg(cpu, 1, 0x100000 + clone.granule))
	assert_equal(0, hv_vcpu_set_vtimer_mask(cpu, 1))
	assert_equal(0, hv_vcpu_run(cpu))
	assert_equal(dhv_exit_exception, cast(int, state.reason))
	assert_equal(0x16, state.syndrome >> 26)
	assert_equal(value, load_int64(clone.ram + clone.granule))
	string_builder* evidence = string_from(c"snapshot resident pages before=")
	string_append_int(evidence, before)
	string_append(evidence, c" registered=")
	string_append_int(evidence, after)
	string_append(evidence, c" after_guest_write=")
	string_append_int(evidence, snapshot_resident_pages(clone.ram, clone.length))
	string_append(evidence, c" total=")
	string_append_int(evidence, clone.length / clone.granule)
	string_append(evidence, c" (residency only; sharing/pinning unproven)\n")
	write(1, evidence.data, evidence.length)
	string_free(evidence)
	assert_equal(0, hv_vcpu_destroy(cpu))
	assert_equal(0, hv_vm_unmap(0x100000, clone.length))
	assert_equal(0, hv_vm_destroy())


int snapshot_worker(int value):
	darwin_clone* clone = darwin_clone_from_fd(3)
	asserts(c"worker owns clone from inherited descriptor", clone != 0)
	close(3)
	assert_equal(0, load_int64(clone.ram + clone.granule))
	assert_strings_equal(c"metadata survives exec", clone.metadata)
	for round in range(3):
		snapshot_guest_write(clone, value + round)
		int template_value = -1
		assert_equal(8, pread(clone.fd, cast(char*, &template_value), 8, clone.ram_offset + clone.granule))
		assert_equal(0, template_value)
		asserts(c"quiescent clone resets", darwin_clone_reset(clone))
		assert_equal(0, load_int64(clone.ram + clone.granule))
	darwin_clone_free(clone)
	return 0


int snapshot_spawn(char* self, darwin_backing* backing, char* value):
	int child = fork()
	asserts(c"fork worker before parent initializes HV", child >= 0)
	if (child == 0):
		assert_equal(3, dup2(backing.fd, 3))
		assert_equal(0, sys_fcntl(3, 2, 0))
		for fd in range(4, 1024): close(fd)
		char** args = strv_new(4)
		args[0] = self
		args[1] = c"worker"
		args[2] = value
		args[3] = 0
		char** env = strv_new(1)
		env[0] = 0
		execve(self, args, env)
		exit(125)
	return child


int snapshot_descriptor_count():
	int count = 0
	for fd in range(1024):
		if (sys_fcntl(fd, 1, 0) >= 0): count = count + 1
	return count


void snapshot_rejection_tests(darwin_clone* source):
	char[64] directory
	strcpy(directory, c"/tmp/wvm-invalid.XXXXXX")
	asserts(c"private negative fixture directory", mkdtemp(directory) != 0)
	string_builder* path = string_from(directory)
	string_append(path, c"/backing")
	int fd = open(path.data, 2 | 64 | 128, 384)
	asserts(c"create malformed backing", fd >= 0)
	assert_equal(0, ftruncate(fd, source.mapping_length))
	int[16] header
	assert_equal(128, pread(source.fd, cast(char*, &header[0]), 128, 0))
	assert_equal(128, write(fd, cast(char*, &header[0]), 128))
	int readonly = open(path.data, 0, 0)
	asserts(c"reopen fixture", readonly >= 0)
	asserts(c"writable descriptors rejected", darwin_clone_from_fd(fd) == 0)
	int descriptors = snapshot_descriptor_count()
	for field in range(16):
		int saved = header[field]
		header[field] = -1
		assert_equal(0, seek(fd, 0, 0))
		assert_equal(128, write(fd, cast(char*, &header[0]), 128))
		asserts(c"corrupt or reserved header field rejected", darwin_clone_from_fd(readonly) == 0)
		header[field] = saved
	assert_equal(0, seek(fd, 0, 0))
	assert_equal(128, write(fd, cast(char*, &header[0]), 128))
	assert_equal(0, ftruncate(fd, source.mapping_length - 1))
	asserts(c"truncated RAM rejected", darwin_clone_from_fd(readonly) == 0)
	assert_equal(0, ftruncate(fd, 127))
	asserts(c"truncated header rejected", darwin_clone_from_fd(readonly) == 0)
	assert_equal(descriptors, snapshot_descriptor_count())
	close(readonly)
	close(fd)
	assert_equal(0, unlink(path.data))
	assert_equal(0, rmdir(directory))
	string_free(path)


# Real EMFILE failures exercise cleanup after directory creation, after
# writable-map capture/reopen and when duplicating a clone handle.
void snapshot_acquisition_failures(darwin_clone* source):
	int descriptors = snapshot_descriptor_count()
	int first_free = 3
	while (sys_fcntl(first_free, 1, 0) >= 0): first_free = first_free + 1
	int[2] original
	int[2] limited
	assert_equal(0, darwin_snapshot_c_int(snapshot_getrlimit(8, &original[0])))
	limited[1] = original[1]
	for capacity in range(2):
		limited[0] = first_free + capacity
		assert_equal(0, darwin_snapshot_c_int(snapshot_setrlimit(8, &limited[0])))
		darwin_backing* failed = darwin_backing_create(source.ram, source.granule * 2, 0, 0)
		int restore = darwin_snapshot_c_int(snapshot_setrlimit(8, &original[0]))
		assert_equal(0, restore)
		asserts(c"descriptor exhaustion rejects capture cleanly", failed == 0)
		assert_equal(descriptors, snapshot_descriptor_count())
	limited[0] = first_free
	assert_equal(0, darwin_snapshot_c_int(snapshot_setrlimit(8, &limited[0])))
	darwin_clone* failed_clone = darwin_clone_from_fd(source.fd)
	assert_equal(0, darwin_snapshot_c_int(snapshot_setrlimit(8, &original[0])))
	asserts(c"descriptor exhaustion rejects clone cleanly", failed_clone == 0)
	assert_equal(descriptors, snapshot_descriptor_count())
	int backup = sys_fcntl(source.fd, 0, 0)
	asserts(c"preserve source handle during failure injection", backup >= 0)
	char* old_address = source.address
	source.ram[source.granule] = 99
	assert_equal(0, close(source.fd))
	asserts(c"failed remap preserves old clone", darwin_clone_reset(source) == 0)
	asserts(c"failed remap retains old address", old_address == source.address)
	assert_equal(99, cast(int, source.ram[source.granule]))
	assert_equal(source.fd, dup2(backup, source.fd))
	close(backup)
	asserts(c"recovered remap", darwin_clone_reset(source))
	assert_equal(0, cast(int, source.ram[source.granule]))
	assert_equal(descriptors, snapshot_descriptor_count())


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc == 3 && strcmp(args[1], c"worker") == 0): return snapshot_worker(atoi(args[2]))
	int initial_descriptors = snapshot_descriptor_count()
	int length = 16777216
	int source = mmap(0, length, 3, 34)
	asserts(c"allocate source RAM", darwin_backing_map_failed(source) == 0)
	# Actual guest STR x0,[x1]; HVC #0. This gate tests backing, not EL0.
	save_i(cast(char*, source), cast(int, 0xf9000020), 4)
	save_i(cast(char*, source) + 4, cast(int, 0xd4000002), 4)
	darwin_backing* backing = darwin_backing_create(cast(char*, source), length, c"metadata survives exec", 23)
	asserts(c"capture immutable backing", backing != 0)
	assert_equal(0, munmap(source, length))
	asserts(c"backing is read only", write(backing.fd, c"x", 1) < 0)
	darwin_clone* sibling = darwin_backing_clone(backing)
	asserts(c"parent owns independent sibling", sibling != 0)
	int first = snapshot_spawn(args[0], backing, c"42")
	int second = snapshot_spawn(args[0], backing, c"87")
	darwin_backing_free(backing)
	int status = 0
	assert_equal(first, wait4(first, &status, 0, 0))
	assert_equal(0, status)
	assert_equal(second, wait4(second, &status, 0, 0))
	assert_equal(0, status)
	assert_equal(0, load_int64(sibling.ram + sibling.granule))
	asserts(c"sibling reset survives template and worker destruction", darwin_clone_reset(sibling))
	assert_equal(0, load_int64(sibling.ram + sibling.granule))
	snapshot_rejection_tests(sibling)
	snapshot_acquisition_failures(sibling)
	for round in range(32):
		sibling.ram[sibling.granule] = 99
		asserts(c"repeated reset", darwin_clone_reset(sibling))
		assert_equal(0, cast(int, sibling.ram[sibling.granule]))
	darwin_clone_free(sibling)
	assert_equal(initial_descriptors, snapshot_descriptor_count())
	asserts(c"invalid descriptor rejected", darwin_clone_from_fd(-1) == 0)
	asserts(c"invalid capture length rejected", darwin_backing_create(c"x", 1, 0, 0) == 0)
	println(c"PASS Darwin actual guest snapshot CoW, exec workers, source deletion and reset")
	return 0
