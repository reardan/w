# wbuild: target=wvm_layer_test tag=tests dep=wv2 dep=wvm_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_layer_test.w -o bin/wvm_layer_test"
# wbuild: step="bin/wvm_layer_test" timeout=60000
import lib.testing
import lib.vmm.snapshot
import lib.file
import lib.process
import lib.ci_skip

void test_layer_zero_overrides_isolation_and_lifetime():
	int fd = open(c"bin/wvm_fixture", 0, 0)
	asserts(c"fixture", fd >= 0)
	int length = file_size(fd)
	close(fd)
	char* image = file_read_text(c"bin/wvm_fixture")
	vm_cell* ready = cell_new()
	asserts(c"load layer fixture", cell_elf_load(ready, image, length))
	free(image)
	char** args = strv_new(2)
	args[0] = c"fixture"
	args[1] = c"exit"
	asserts(c"stack", cell_stack(ready, 2, args))
	free(cast(void*, args))
	ready.ram[3145728] = 41
	ready.ram[3153920] = 43
	cell_snapshot* base = cell_snapshot_create(ready)
	asserts(c"base snapshot", base != 0)
	cell_free(ready)
	vm_cell* first = cell_snapshot_clone(base)
	asserts(c"base clone", first != 0)
	first.ram[3145728] = 0
	first.ram[3149824] = 42
	cell_snapshot* layer = cell_snapshot_create_layer(first, base)
	asserts(c"changed snapshot", layer != 0)
	assert_equal(2, layer.resident_pages)
	assert_equal(15, sys_fcntl(layer.fd, F_GET_SEALS, 0))
	cell_free(first)
	cell_snapshot_free(base)
	first = cell_snapshot_clone(layer)
	asserts(c"first layered clone", first != 0)
	assert_equal(0, first.ram[3145728])
	assert_equal(42, first.ram[3149824])
	assert_equal(43, first.ram[3153920])
	first.ram[3149824] = 0
	first.ram[3153920] = 44
	cell_snapshot* child = cell_snapshot_create_layer(first, layer)
	asserts(c"nested snapshot", child != 0)
	assert_equal(2, child.resident_pages)
	cell_free(first)
	cell_snapshot_free(layer)
	first = cell_snapshot_clone(child)
	vm_cell* second = cell_snapshot_clone(child)
	asserts(c"two independent nested clones", first != 0 && second != 0)
	cell_snapshot_free(child)
	assert_equal(0, first.ram[3145728])
	assert_equal(0, first.ram[3149824])
	assert_equal(44, first.ram[3153920])
	first.ram[3153920] = 99
	assert_equal(44, second.ram[3153920])
	asserts(c"reset layered mappings", cell_snapshot_reset(first))
	assert_equal(44, first.ram[3153920])
	fd = kvm_open_system()
	if (fd < 0): test_skip_kvm(c"SKIP: KVM unavailable for layered execution; mapping assertions ran")
	else:
		close(fd)
		asserts(c"execute inherited code", cell_run(first, 5000))
		assert_equal(37, first.status)
		asserts(c"reset after execution", cell_snapshot_reset(first))
		asserts(c"rerun layered cell", cell_run(first, 5000))
		assert_equal(37, first.status)
	cell_free(first)
	cell_free(second)
