# Mandatory native Darwin cell snapshot test, run by tools/mac/run_vm_tests.sh.
# argv[1] is the static arm64 tests/wvm_darwin_fixture.w guest binary.
import lib.vmm.darwin_cell_snapshot
import lib.assert
import lib.process


darwin_cell* snapshot_ready_cell(char* image, char* mode):
	darwin_cell* cell = darwin_cell_new()
	asserts(c"new snapshot source", cell != 0)
	asserts(c"load snapshot source", darwin_cell_load(cell, image))
	char** args = strv_new(3)
	args[0] = c"snapshot-guest"
	args[1] = mode
	args[2] = 0
	asserts(c"snapshot source stack", darwin_cell_stack(cell, 2, args))
	free(cast(void*, args))
	return cell


void snapshot_run_clone(darwin_cell* cell):
	if (darwin_cell_run(cell, 3000) == 0):
		println2(cell.error)
		println2(cell.errors.data)
		asserts(c"run cloned guest", 0)
	assert_equal(0, cell.status)
	assert_strings_equal(c"cell allocator containers FP OK\n", cell.output.data)
	asserts(c"live snapshot rejected", darwin_cell_snapshot_create(cell) == 0)
	asserts(c"dirty guest reset", darwin_cell_snapshot_reset(cell))
	assert_equal(0, cell.output.length)
	assert_equal(0, cell.errors.length)
	assert_equal(0, cell.started)
	assert_equal(0, cell.closed_fds)
	assert_equal(0, cell.syscall_count)
	assert_equal(cell.heap_start, cell.heap_end)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	assert_equal(2, argc)
	darwin_cell* source = snapshot_ready_cell(args[1], c"alloc")
	int capture_start = dhv_now_ms()
	darwin_backing* backing = darwin_cell_snapshot_create(source)
	asserts(c"ready snapshot captured", backing != 0)
	print_int(c"Darwin ready-template capture ms=", dhv_now_ms() - capture_start)
	int clone_start = dhv_now_ms()
	darwin_cell* first = darwin_cell_snapshot_clone(backing)
	darwin_cell* sibling = darwin_cell_snapshot_from_fd(backing.fd)
	asserts(c"two private ready clones", first != 0 && sibling != 0)
	print_int(c"Darwin two private-clone restores ms=", dhv_now_ms() - clone_start)
	darwin_cell_free(source)
	darwin_backing_free(backing)
	for round in range(3): snapshot_run_clone(first)
	darwin_cell_free(first)
	for round in range(3): snapshot_run_clone(sibling)
	darwin_cell_free(sibling)
	source = snapshot_ready_cell(args[1], c"input")
	source.input = c"pristine bounded input"
	source.input_length = 22
	backing = darwin_cell_snapshot_create(source)
	asserts(c"snapshot preserves initial input", backing != 0)
	first = darwin_cell_snapshot_clone(backing)
	asserts(c"restore input template", first != 0)
	darwin_cell_free(source)
	darwin_backing_free(backing)
	for round in range(3):
		asserts(c"cloned input run", darwin_cell_run(first, 3000))
		assert_equal(0, first.status)
		assert_strings_equal(c"pristine bounded input", first.output.data)
		asserts(c"input reset", darwin_cell_snapshot_reset(first))
		assert_equal(0, first.input_pos)
	darwin_cell_free(first)
	println(c"PASS Darwin ready cell clones, allocator/FP reset, independent lifetime and stdin")
	return 0
