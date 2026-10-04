# wbuild: target=wvm_cgroup_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wvm_cgroup_test.w -o bin/wvm_cgroup_test"
# wbuild: step="bin/wvm_cgroup_test" timeout=30000
import lib.testing
import lib.vmm.cgroup


void test_cgroup_requires_real_delegation():
	asserts(c"reject regular filesystem", vm_cgroup_new(c"/tmp", 100, 64, 8) == 0)
	asserts(c"reject zero CPU quota", vm_cgroup_new(c"/sys/fs/cgroup", 0, 64, 8) == 0)
	asserts(c"reject missing parent", vm_cgroup_new(c"/no/wvm/cgroup", 100, 64, 8) == 0)


void test_cgroup_delegated_limits():
	char* parent = env_get(c"WVM_TEST_CGROUP")
	if (parent == 0):
		println(c"SKIP: set WVM_TEST_CGROUP to an empty delegated cgroup v2 parent")
		return
	vm_cgroup* group = vm_cgroup_new(parent, 50, 64, 1)
	asserts(c"create real fleet quota", group != 0)
	asserts(c"exclusive fleet leaf", vm_cgroup_new(parent, 50, 64, 1) == 0)
	char* quota_path = strjoin(group.path, c"/cpu.max")
	char* quota = file_read_text(quota_path)
	assert_strings_equal(c"50000 100000\n", quota)
	free(quota)
	free(quota_path)
	int gate_read = -1
	int gate_write = -1
	assert_equal(0, process_make_pipe(&gate_read, &gate_write))
	int pid = fork()
	if (pid == 0):
		close(gate_write)
		char gate
		if (read(gate_read, &gate, 1) != 1): exit(10)
		# The worker counts against pids.max; its child must be denied.
		int child = fork()
		if (child == 0): exit(11)
		if (child != -11): exit(12)
		exit(0)
	asserts(c"fork worker", pid > 0)
	close(gate_read)
	asserts(c"attach before releasing gate", vm_cgroup_attach(group, pid))
	assert_equal(1, write(gate_write, c"!", 1))
	close(gate_write)
	int status = 0
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(0, status)
	# Exercise the real memory controller. The daemon/test remains outside.
	asserts(c"raise task quota", vm_cgroup_number(group, c"pids.max", 8))
	assert_equal(0, process_make_pipe(&gate_read, &gate_write))
	pid = fork()
	if (pid == 0):
		close(gate_write)
		char gate
		if (read(gate_read, &gate, 1) != 1): exit(13)
		int length = 100663296
		int address = mmap(0, length, 3, 34)
		if (address < 0 && address > -4096): exit(14)
		char* ram = cast(char*, address)
		for i in range(length / 4096): ram[i * 4096] = 1
		exit(15)
	asserts(c"fork memory worker", pid > 0)
	close(gate_read)
	asserts(c"attach memory worker", vm_cgroup_attach(group, pid))
	assert_equal(1, write(gate_write, c"!", 1))
	close(gate_write)
	assert_equal(pid, wait4(pid, &status, 0, 0))
	assert_equal(9, status & 127)
	char* path = strclone(group.path)
	vm_cgroup_free(group)
	asserts(c"empty group removed", open(path, 65536, 0) < 0)
	free(path)
