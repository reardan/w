# wbuild: binary=wgrind_native arch=x64
import libs.wgrind.execute_linux


int wg_native_image_supported(char* data, int length):
	if (wg_elf64(data, length) == 0): return 0
	int sections = wg_elf_u64(data, 40)
	int count = wg_elf_u16(data, 60)
	if ((wg_elf_u16(data, 58) != 64) || (count == 0) || (wg_elf_range(length, sections, count * 64) == 0)): return 0
	for i in range(count):
		int section = sections + i * 64
		int kind = wg_elf_u32(data, section + 4)
		if (((kind == 2) || (kind == 11)) && (wg_elf_u64(data, section + 32) > 0)): return 1
	# Without symbols, unknown allocator entry points could otherwise look
	# like ordinary zero-defined mmap memory and produce a false clean run.
	return 0


int main(int argc, char** argv):
	int first = 1
	if ((argc > 1) && (strcmp(argv[1], c"--") == 0)): first = 2
	if ((argc <= first) || (strcmp(argv[first], c"--help") == 0)):
		println2(c"usage: wgrind_native [--] executable [arguments...]")
		println2(c"Linux x64 reference executor: scalar instructions, checked OS events")
		println2(c"unsupported instructions/syscalls/signals: incomplete status 100; errors: 99")
		if (argc > first): return 0
		return 2
	char* path = process_which(argv[first])
	if (path == 0): return 127
	# Reject incompatible image formats before launching an unchecked child.
	int length = 0
	char* file = wg_symbol_read_file(path, &length)
	if (file == 0): return 126
	int valid = wg_native_image_supported(file, length)
	free(file)
	if (valid == 0):
		println2(c"wgrind_native: unsupported executable (requires Linux x64 ELF with symbol metadata)")
		return 100
	return wg_native_run(path, argv + first * __word_size__)

# wbuild: target=wgrind_native_test tag=tests dep=wgrind_native dep=wgrind dep=wgrind_native_driver input=tests/wgrind_native_driver.w input=tests/wgrind_native/
# wbuild: step="bin/wgrind_native_driver" expect_stdout="wgrind native executable checks OK"
