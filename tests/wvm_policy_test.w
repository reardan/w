# wbuild: target=wvm_policy_test tag=tests dep=wv2 dep=wvm_policy_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_policy_test.w -o bin/wvm_policy_test"
# wbuild: step="bin/wvm_policy_test" timeout=30000
import lib.testing
import lib.vmm.snapshot
import lib.file
import lib.ci_skip


vm_cell* policy_template(char* mode):
	char* image = file_read_text(c"bin/wvm_policy_fixture")
	int fd = open(c"bin/wvm_policy_fixture", 0, 0)
	asserts(c"policy fixture", image != 0 && fd >= 0)
	int length = file_size(fd)
	close(fd)
	vm_cell* cell = cell_new()
	asserts(c"policy load", cell_elf_load(cell, image, length))
	free(image)
	char*[2] args
	args[0] = c"fixture"
	args[1] = mode
	asserts(c"policy stack", cell_stack(cell, 2, &args[0]))
	return cell


void test_private_filesystem_limits_and_cleanup():
	char* root = c"bin/wvm_policy_root"
	assert_equal(0, mkdir(root, 448))
	asserts(c"write lower", file_write_text(c"bin/wvm_policy_root/hello", c"lower"))
	vm_cell* cell = cell_new()
	assert_equal(0, cell_fs_configure_private(cell, root, 4, 2, 5000))
	assert_equal(0, cast(int, cell.fs_state))
	asserts(c"bounded private copy", cell_fs_configure_private(cell, root, 12, 2, 5000))
	cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
	char* path = strjoin(fs.private_copy.path, c"")
	assert_equal(5, fs.private_copy.bytes)
	int guest = cell_fs_open(fs, -100, c"new", 194, 384)
	asserts(c"create second entry", guest >= 3)
	int fd = cell_fs_descriptor(fs, guest)
	assert_equal(7, cell_fs_write(fs, fd, c"1234567", 7, 0, 0))
	assert_equal(-28, cell_fs_write(fs, fd, c"x", 1, 0, 0))
	assert_equal(-28, cell_fs_truncate(fs, fd, 8))
	assert_equal(-28, cell_fs_open(fs, -100, c"third", 194, 384))
	assert_equal(0, cell_fs_truncate(fs, fd, 0))
	assert_equal(-28, cell_fs_write(fs, fd, c"x", 1, 0, 1))
	assert_equal(0, syscall(263, fs.root, cast(int, c"new"), 0))
	assert_equal(-28, cell_fs_truncate(fs, fd, 1))
	cell_free(cell)
	assert_equal(-2, open(path, 65536, 0))
	free(path)
	char* lower = file_read_text(c"bin/wvm_policy_root/hello")
	assert_strings_equal(c"lower", lower)
	free(lower)
	assert_equal(0, unlink(c"bin/wvm_policy_root/hello"))
	assert_equal(0, syscall(84, cast(int, root), 0, 0))


void test_private_filesystem_positioned_append_budget():
	char* root = c"bin/wvm_policy_append"
	assert_equal(0, mkdir(root, 448))
	vm_cell* cell = cell_new()
	asserts(c"private append copy", cell_fs_configure_private(cell, root, 8, 4, 5000))
	cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
	int guest = cell_fs_open(fs, -100, c"data", 1218, 384)
	asserts(c"append descriptor", guest >= 3)
	int fd = cell_fs_descriptor(fs, guest)
	assert_equal(4, cell_fs_write(fs, fd, c"1234", 4, 0, 1))
	assert_equal(4, cell_fs_write(fs, fd, c"5678", 4, 0, 1))
	assert_equal(-28, cell_fs_write(fs, fd, c"x", 1, 0, 1))
	assert_equal(8, cell_fs_size(fd))
	cell_free(cell)
	assert_equal(0, syscall(84, cast(int, root), 0, 0))


void test_deterministic_services_and_bounds():
	vm_cell* first = cell_new()
	vm_cell* second = cell_new()
	asserts(c"configure seed", cell_deterministic_configure(first, 123))
	asserts(c"configure matching seed", cell_deterministic_configure(second, 123))
	cell_page_tables(first)
	cell_page_tables(second)
	cell_map(first, CELL_USER_MIN, 4096, 3)
	cell_map(second, CELL_USER_MIN, 4096, 3)
	assert_equal(64, cell_deterministic_random(first, CELL_USER_MIN, 64))
	assert_equal(64, cell_deterministic_random(second, CELL_USER_MIN, 64))
	for i in range(64): assert_equal(cast(int, first.ram[CELL_USER_MIN + i]), cast(int, second.ram[CELL_USER_MIN + i]))
	assert_equal(0, cell_deterministic_clock(first, 1, CELL_USER_MIN))
	assert_equal(0, load_int64(first.ram + CELL_USER_MIN))
	assert_equal(0, load_int64(first.ram + CELL_USER_MIN + 8))
	assert_equal(0, cell_deterministic_clock(first, 0, CELL_USER_MIN))
	assert_equal(1700000000, load_int64(first.ram + CELL_USER_MIN))
	assert_equal(1000000, load_int64(first.ram + CELL_USER_MIN + 8))
	assert_equal(0, cell_fs_configure(first, c"bin", 0))
	assert_equal(0, cell_deterministic_configure(first, -1))
	asserts(c"largest seed", cell_deterministic_configure(second, 2147483646))
	assert_equal(1, cell_deterministic_random(second, CELL_USER_MIN, 1))
	asserts(c"largest seed evolves", second.random_state != 2147483647)
	assert_equal(0, cell_replay_configure(first, c"short", 5))
	first.transcript.length = CELL_TRANSCRIPT_LIMIT
	assert_equal(0, cell_transcript_bytes(first, c"x", 1))
	assert_equal(125, first.status)
	assert_equal(1, first.exited)
	first.transcript.length = 0
	cell_free(first)
	cell_free(second)


void test_deterministic_replay_reset_and_syscall_budget():
	int kvm = kvm_open_system()
	if (kvm < 0):
		test_skip_kvm(c"SKIP: /dev/kvm unavailable (policy unit gates still ran)")
		return
	close(kvm)
	vm_cell* source = policy_template(c"services")
	source.input = c"abc"
	source.input_length = 3
	asserts(c"seed template", cell_deterministic_configure(source, 123))
	cell_snapshot* snapshot = cell_snapshot_create(source)
	asserts(c"policy snapshot", snapshot != 0)
	vm_cell* cell = cell_snapshot_clone(snapshot)
	cell_snapshot_free(snapshot)
	cell_free(source)
	asserts(c"first seeded run", cell_run(cell, 5000))
	assert_equal(0, cell.status)
	assert_equal(51, cell.output.length)
	asserts(c"syscalls recorded", cell.transcript.length >= 72)
	int length = cell.transcript.length
	char* transcript = cast(char*, malloc(length))
	mem_copy[char](transcript, cell.transcript.data, length)
	char[51] output
	mem_copy[char](&output[0], cell.output.data, 51)
	asserts(c"reset seed", cell_snapshot_reset(cell))
	assert_equal(0, cell.clock_ticks)
	assert_equal(124, cell.random_state)
	assert_equal(0, cell.syscall_count)
	assert_equal(0, cell.transcript.length)
	asserts(c"configure replay", cell_replay_configure(cell, transcript, length))
	asserts(c"verified run", cell_run(cell, 5000))
	assert_equal(0, cell.status)
	assert_equal(length, cell.replay_pos)
	for i in range(51): assert_equal(cast(int, output[i]), cast(int, cell.output.data[i]))
	asserts(c"reset replay", cell_snapshot_reset(cell))
	assert_equal(0, cast(int, cell.replay))
	asserts(c"divergent seed", cell_deterministic_configure(cell, 456))
	asserts(c"configure mismatching replay", cell_replay_configure(cell, transcript, length))
	asserts(c"mismatch stops guest", cell_run(cell, 5000))
	assert_equal(125, cell.status)
	asserts(c"reset replay again", cell_snapshot_reset(cell))
	char* trailing = cast(char*, malloc(length + 1))
	mem_copy[char](trailing, transcript, length)
	trailing[length] = 0
	asserts(c"configure trailing transcript", cell_replay_configure(cell, trailing, length + 1))
	asserts(c"incomplete replay stops guest", cell_run(cell, 5000))
	assert_equal(125, cell.status)
	free(trailing)
	asserts(c"reset missing replay", cell_snapshot_reset(cell))
	asserts(c"configure shortened transcript", cell_replay_configure(cell, transcript, length - 1))
	asserts(c"missing record stops guest", cell_run(cell, 5000))
	assert_equal(125, cell.status)
	free(transcript)
	cell_free(cell)
	cell = policy_template(c"budget")
	cell.max_syscalls = 32
	asserts(c"budget terminates guest", cell_run(cell, 5000))
	assert_equal(125, cell.status)
	assert_equal(32, cell.syscall_count)
	assert_strings_equal(c"guest syscall limit exceeded", cell.error)
	cell_free(cell)


void test_private_filesystem_guest_and_reset():
	int kvm = kvm_open_system()
	if (kvm < 0): return
	close(kvm)
	char* root = c"bin/wvm_policy_guest"
	assert_equal(0, mkdir(root, 448))
	asserts(c"guest lower", file_write_text(c"bin/wvm_policy_guest/hello", c"lower"))
	vm_cell* source = policy_template(c"private")
	cell_snapshot* snapshot = cell_snapshot_create(source)
	asserts(c"private base snapshot", snapshot != 0)
	vm_cell* cell = cell_snapshot_clone(snapshot)
	cell_free(source)
	cell_snapshot_free(snapshot)
	for run in range(2):
		asserts(c"per-run private copy", cell_fs_configure_private(cell, root, 128, 128, 5000))
		cell_filesystem* fs = cast(cell_filesystem*, cell.fs_state)
		char* path = strjoin(fs.private_copy.path, c"")
		asserts(c"run private guest", cell_run(cell, 5000))
		assert_equal(0, cell.status)
		assert_strings_equal(c"private OK\n", cell.output.data)
		char* lower = file_read_text(c"bin/wvm_policy_guest/hello")
		assert_strings_equal(c"lower", lower)
		free(lower)
		asserts(c"reset removes private copy", cell_snapshot_reset(cell))
		assert_equal(-2, open(path, 65536, 0))
		free(path)
	cell_free(cell)
	assert_equal(0, unlink(c"bin/wvm_policy_guest/hello"))
	assert_equal(0, syscall(84, cast(int, root), 0, 0))
