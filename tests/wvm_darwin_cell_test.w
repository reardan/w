# Native no-skip Hypervisor cell acceptance test; sign before execution.
# wbuild: binary=wvm_darwin_cell_test arch=arm64_darwin tag=tests_darwin
import lib.vmm.darwin_cell
import lib.assert

char* darwin_test_image
int darwin_test_image_length


darwin_cell* darwin_test_ready(char* mode):
	darwin_cell* cell = darwin_cell_new()
	asserts(c"cell allocation", cell != 0)
	assert_equal(1, darwin_cell_elf_load(cell, darwin_test_image, darwin_test_image_length))
	char*[3] args
	args[0] = c"fixture"
	args[1] = mode
	args[2] = c"payload"
	assert_equal(1, darwin_cell_stack(cell, 3, &args[0]))
	return cell


void darwin_test_mode(char* mode, int status, char* output):
	darwin_cell* cell = darwin_test_ready(mode)
	cell.input = c"private stdin"
	cell.input_length = 13
	int timeout = 2000
	if (status == 124): timeout = 30
	int start = dhv_now_ms()
	darwin_cell_run(cell, timeout)
	assert_equal(status, cell.status)
	if (output != 0): asserts(c"captured output", string_equals(cell.output, output))
	if (status == 139):
		asserts(c"fault has guest PC", cell.fault_pc > 0)
		asserts(c"fault diagnostic", cell.error != 0)
	if (status == 124): asserts(c"CPU-only guest deadline bounded", dhv_now_ms() - start < 2000)
	assert_equal(0, cell.vm_created)
	assert_equal(0, cell.cpu_created)
	darwin_cell_free(cell)


void darwin_test_rejected(char* image, int length):
	darwin_cell* cell = darwin_cell_new()
	assert_equal(0, darwin_cell_elf_load(cell, image, length))
	assert_equal(0, cell.loaded)
	assert_equal(0, cell.vm_created)
	asserts(c"image rejection diagnostic", cell.error != 0)
	darwin_cell_free(cell)


int main(int argc, int argv):
	char* path = c"bin/wvm_darwin_fixture"
	if (argc > 1): path = (cast(char**, argv))[1]
	int fd = open(path, 0, 0)
	asserts(c"fixture exists", fd >= 0)
	darwin_test_image_length = seek(fd, 0, 2)
	asserts(c"fixture bounded", darwin_test_image_length >= 64 && darwin_test_image_length <= 67108864)
	assert_equal(0, seek(fd, 0, 0))
	darwin_test_image = cast(char*, malloc(darwin_test_image_length))
	int done = 0
	while (done < darwin_test_image_length):
		int n = read(fd, darwin_test_image + done, darwin_test_image_length - done)
		asserts(c"read fixture", n > 0)
		done = done + n
	close(fd)
	assert_equal(0, dhv_probe())
	darwin_test_mode(c"hello", 7, c"hello from an ARM64 cell\n")
	darwin_test_mode(c"argv", 0, c"cell argv OK\n")
	darwin_test_mode(c"alloc", 0, c"cell allocator containers FP OK\n")
	darwin_test_mode(c"deny", 0, c"cell denials OK\n")
	darwin_test_mode(c"invalid-buffer", 0, c"cell denials OK\n")
	darwin_test_mode(c"pages", 0, c"cell page boundaries OK\n")
	darwin_test_mode(c"memory", 0, c"cell memory OK\n")
	darwin_test_mode(c"input", 0, c"private stdin")
	darwin_test_mode(c"exit", 37, c"")
	darwin_test_mode(c"monitor", 139, c"")
	darwin_test_mode(c"readonly", 139, c"")
	darwin_test_mode(c"unmapped", 139, c"")
	darwin_test_mode(c"nx", 139, c"")
	darwin_test_mode(c"hvc", 139, c"")
	darwin_test_mode(c"spin", 124, c"")
	darwin_test_mode(c"output", 125, c"")
	# Cancellation/output failures cannot leave a VM alive in this process.
	for i in range(3): darwin_test_mode(c"hello", 7, c"hello from an ARM64 cell\n")
	darwin_cell* bounded = darwin_test_ready(c"hello")
	bounded.output_limit = 3
	darwin_cell_run(bounded, 1000)
	assert_equal(125, bounded.status)
	assert_equal(0, bounded.output_bytes)
	darwin_cell_free(bounded)
	darwin_cell* calls = darwin_test_ready(c"hello")
	calls.syscall_limit = 1
	darwin_cell_run(calls, 1000)
	assert_equal(125, calls.status)
	asserts(c"syscall quota", calls.error != 0)
	darwin_cell_free(calls)
	# Validate malformed images without creating a VM or copying segments.
	darwin_test_rejected(darwin_test_image, 63)
	char* corrupt = cast(char*, malloc(darwin_test_image_length))
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	corrupt[0] = 0
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	corrupt[18] = 62 # x64
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	corrupt[16] = 3 # PIE/dynamic ET_DYN
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	corrupt[5] = 2 # big endian
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	save_int64(corrupt + 24, 4096) # privileged entry
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	save_int64(corrupt + 32, -1) # wrapping phoff
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	int phoff = load_int64(corrupt + 32)
	save_int32(corrupt + phoff, 3) # interpreter
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	save_int64(corrupt + phoff + 8, -1)
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	save_int64(corrupt + phoff + 40, -1)
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	save_int64(corrupt + phoff + 16, DARWIN_CELL_RAM_SIZE - 4096)
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	save_int32(corrupt + phoff, 7) # TLS requires unsupported thread ABI
	darwin_test_rejected(corrupt, darwin_test_image_length)
	mem_copy[char](corrupt, darwin_test_image, darwin_test_image_length)
	corrupt[7] = 9 # FreeBSD ABI
	darwin_test_rejected(corrupt, darwin_test_image_length)
	free(corrupt)
	free(darwin_test_image)
	assert_equal(0, dhv_probe())
	println(c"Darwin EL0 cells OK: ELF, allocator/containers/FP, buffers, permissions, denial, deadlines, quotas")
	return 0
